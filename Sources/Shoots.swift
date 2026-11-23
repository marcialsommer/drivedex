import Foundation

/// Shoot mode: a named session (e.g. "XP shoot") with one main folder and some backup folders.
/// While a shoot is active on this Mac, every new local drive that gets plugged in (memory cards) is
/// catalogued straight away and added to the shoot. DriveDex then shows, card by card, whether all of
/// its files are on the main drive and on every backup ("safe to format"). DriveDex never copies or
/// changes anything: the copying is done with the Finder or a copy tool.
///
/// Stored in the `shoots` table as JSON (drives referenced by key, so it means the same on every Mac)
/// and shared between Macs as `shoots.json` in the sync folder (newest version of each shoot wins).
enum Shoots {
    static let proxyExts: Set<String> = ["lrv", "lrf", "thm"]

    /// What counts on a memory card when a shoot checks "only photos, videos and audio" (the default): camera RAW
    /// and JPEG/HEIF photos, video files and audio recordings. Everything else (thumbnails, previews such as LRV/LRF,
    /// index and database files, XML/SRT sidecars) is ignored, because people usually don't copy those.
    static let mediaExts: Set<String> = [
        // photos: RAW from all major brands, DNG, JPEG, HEIF, TIFF
        "arw", "srf", "sr2", "cr2", "cr3", "crw", "nef", "nrw", "raf", "orf", "rw2", "rwl", "pef", "srw", "x3f", "3fr",
        "fff", "iiq", "erf", "mef", "mos", "dcr", "kdc", "raw", "gpr", "dng", "jpg", "jpeg", "heic", "heif", "hif", "tif", "tiff",
        // video
        "mp4", "mov", "mxf", "mts", "m2ts", "m4v", "avi", "mkv", "braw", "r3d", "crm", "insv", "insp", "360", "mpg", "mpeg", "3gp",
        // audio recorders
        "wav", "bwf", "aif", "aiff", "flac", "mp3", "m4a",
    ]

    /// Whether a file on a card is part of the check, for this shoot.
    static func counts(_ name: String, shoot s: [String: Any]) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        if s["mediaOnly"] as? Bool ?? true { return mediaExts.contains(ext) }
        return !(s["skipProxies"] as? Bool ?? true) || !proxyExts.contains(ext)
    }

    static var activeID: String {
        get { Settings.d.string(forKey: "activeShoot") ?? "" }
        set { Settings.d.set(newValue, forKey: "activeShoot") }
    }

    static func ensureTable(_ db: DB) {
        _ = db.exec("CREATE TABLE IF NOT EXISTS shoots(uuid TEXT PRIMARY KEY, json TEXT, updated REAL)")
    }

    static func all(_ db: DB, includeDeleted: Bool = false) -> [[String: Any]] {
        ensureTable(db)
        return db.rows("SELECT json FROM shoots ORDER BY updated DESC").compactMap { r in
            guard let s = r["json"] as? String, let data = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            if !includeDeleted && o["deleted"] as? Bool == true { return nil }
            return o
        }
    }

    static func get(_ db: DB, _ uuid: String) -> [String: Any]? {
        ensureTable(db)
        guard let s = db.row("SELECT json FROM shoots WHERE uuid=?", [uuid])?["json"] as? String,
              let data = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Saves a shoot (stamping `updated` unless `keepStamp`) and shares it.
    static func put(_ db: DB, _ shoot: [String: Any], keepStamp: Bool = false) {
        ensureTable(db)
        var s = shoot
        guard let uuid = s["uuid"] as? String, !uuid.isEmpty else { return }
        if !keepStamp { s["updated"] = Date().timeIntervalSince1970 }
        guard let data = try? JSONSerialization.data(withJSONObject: s), let json = String(data: data, encoding: .utf8) else { return }
        db.run("INSERT OR REPLACE INTO shoots(uuid, json, updated) VALUES(?,?,?)", [uuid, json, s["updated"] as? Double ?? 0])
        if !keepStamp { Scanner.shared.exportShoots() }
    }

    /// Keys of all drives that are memory cards of some shoot -> name of the newest such shoot.
    static func cardKeys(_ db: DB) -> [String: String] {
        var out: [String: String] = [:]
        for s in all(db).reversed() {
            for c in s["cards"] as? [[String: Any]] ?? [] { if let k = c["key"] as? String { out[k] = s["name"] as? String ?? "" } }
        }
        return out
    }

    /// A destination can also be a folder on a Mac's internal drive: {"local": true, "mac": <computer name>,
    /// "path": <full path>}. It's only checked on that Mac (live); other Macs just show where it is.
    static func localRoot(_ spec: [String: Any]) -> URL? {
        guard spec["local"] as? Bool == true, (spec["mac"] as? String) == SyncFolder.machine,
              let p = spec["path"] as? String, !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    static func localName(_ spec: [String: Any]) -> String { "\(spec["mac"] as? String ?? "Mac") · internal drive" }

    static func destKeys(_ s: [String: Any]) -> [String] {
        var keys: [String] = []
        if let m = s["main"] as? [String: Any], let k = m["key"] as? String { keys.append(k) }
        for b in s["backups"] as? [[String: Any]] ?? [] { if let k = b["key"] as? String { keys.append(k) } }
        return keys
    }

    /// Camera folders that mark a drive as a memory card (photo cameras, Sony, Canon, Panasonic, DJI, GoPro, Blackmagic…).
    static let cardMarkers = ["DCIM", "PRIVATE", "CLIP", "M4ROOT", "XDROOT", "AVCHD", "CONTENTS", "MISC", "CANONMSC", "DJI", "Blackmagic"]

    static func looksLikeCard(_ v: VolumeInfo) -> Bool {
        let fm = FileManager.default
        return cardMarkers.contains { fm.fileExists(atPath: v.url.appendingPathComponent($0).path) }
    }

    /// Adds a drive to a shoot as a memory card (no-op if it's already one).
    static func addCard(_ db: DB, _ uuid: String, key: String, vol: String) -> Bool {
        guard var s = get(db, uuid), s["deleted"] as? Bool != true else { return false }
        var cards = s["cards"] as? [[String: Any]] ?? []
        if !cards.contains(where: { $0["key"] as? String == key }) {
            cards.append(["key": key, "label": "Card \(cards.count + 1)", "vol": vol,
                          "added": Date().timeIntervalSince1970, "mac": SyncFolder.machine])
        }
        s["cards"] = cards
        s["notCards"] = (s["notCards"] as? [String] ?? []).filter { $0 != key }
        put(db, s)
        return true
    }

    /// Called by the scanner before a volume is scanned. Returns the active shoot's name if this drive is one of
    /// its memory cards. A new drive only becomes a card by itself when the shoot has "add cards automatically"
    /// on and the drive looks like a camera card; otherwise DriveDex asks (the normal new-drive notice offers
    /// "Add to <shoot>"). Returns nil for normal drives.
    static func claimCard(_ v: VolumeInfo, db: DB) -> String? {
        let active = activeID
        guard !active.isEmpty, v.kind == "drive", !v.isDiskImage, var s = get(db, active), s["deleted"] as? Bool != true,
              s["done"] as? Bool != true else { return nil }
        if destKeys(s).contains(v.key) { return nil }
        var cards = s["cards"] as? [[String: Any]] ?? []
        if cards.contains(where: { $0["key"] as? String == v.key }) { return s["name"] as? String ?? "" }
        let known = db.row("SELECT id FROM drives WHERE key=?", [v.key]) != nil
        if known && cardKeys(db)[v.key] == nil { return nil }       // a normal drive the user already has
        let notCards = s["notCards"] as? [String] ?? []
        if notCards.contains(v.key) { return nil }                 // the user said "not a card"
        guard s["autoAdd"] as? Bool == true, looksLikeCard(v) else { return nil }   // ask instead
        cards.append(["key": v.key, "label": "Card \(cards.count + 1)", "vol": v.name,
                      "added": Date().timeIntervalSince1970, "mac": SyncFolder.machine])
        s["cards"] = cards
        put(db, s)
        return s["name"] as? String ?? ""
    }

    // MARK: - checking

    private struct Dest {
        let key: String, name: String, path: String, online: Bool
        var live: Bool
        let lastScan: Double?
        var have: Set<String> = []
        var error: String = ""
    }

    private static func fileKey(_ name: String, _ size: Int64) -> String { matchKey(name) + "\u{0}" + String(size) }

    /// Reads the files in a folder on a connected drive (names and sizes only).
    private static func walkLive(_ root: URL, mount: URL, into set: inout Set<String>) -> Bool {
        if Scanner.shared.isEjecting(mount) { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return false }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [],
                                                      errorHandler: { _, _ in true }) else { return false }
        var count = 0
        for case let u as URL in en {
            count += 1
            if count % 200 == 0 && Scanner.shared.isEjecting(mount) { return false }   // being ejected: let go
            let n = u.lastPathComponent
            if n.hasPrefix("._") || n == ".DS_Store" { continue }
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            set.insert(fileKey(n, Int64(v.fileSize ?? 0)))
        }
        return true
    }

    /// Card-by-card status of a shoot. Connected destinations are read live (just the shoot folder);
    /// others from their last catalog.
    static func status(_ db: DB, _ uuid: String) -> [String: Any] {
        guard let s = get(db, uuid) else { return ["error": "This shoot doesn't exist any more."] }
        let online = Scanner.onlineMap()
        var dests: [Dest] = []
        var specs: [[String: Any]] = []
        if let m = s["main"] as? [String: Any] { specs.append(m) }
        specs += s["backups"] as? [[String: Any]] ?? []
        for spec in specs {
            if spec["local"] as? Bool == true {
                let p = spec["path"] as? String ?? ""
                var dest = Dest(key: spec["key"] as? String ?? "", name: localName(spec), path: (p as NSString).abbreviatingWithTildeInPath,
                                online: localRoot(spec) != nil, live: false, lastScan: nil)
                if let root = localRoot(spec) {
                    var set = Set<String>()
                    if walkLive(root, mount: URL(fileURLWithPath: "/"), into: &set) { dest.have = set } else { dest.error = "Folder not found yet" }
                    dest.live = true
                } else {
                    dest.error = "On \(spec["mac"] as? String ?? "another Mac")'s internal drive: checked on that Mac"
                }
                dests.append(dest)
                continue
            }
            let key = spec["key"] as? String ?? "", path = (spec["path"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            let d = db.row("SELECT id, gen, last_scan, COALESCE(NULLIF(label,''), name) AS name FROM drives WHERE key=?", [key])
            var dest = Dest(key: key, name: d?["name"] as? String ?? "?", path: path, online: online[key] != nil,
                            live: false, lastScan: d?["last_scan"] as? Double)
            if let v = online[key] {
                let root = path.isEmpty ? v.url : v.url.appendingPathComponent(path, isDirectory: true)
                var set = Set<String>()
                if walkLive(root, mount: v.url, into: &set) { dest.have = set; dest.live = true }
                else { dest.error = "Folder “\(path)” not found yet" ; dest.live = true }
            } else if let id = d?["id"] as? Int, let gen = d?["gen"] as? Int {
                let sql: String; let args: [Any?]
                if path.isEmpty {
                    sql = "SELECT name, size FROM entries WHERE drive_id=? AND gen=? AND is_dir <> 1"; args = [id, gen]
                } else {
                    sql = "SELECT name, size FROM entries WHERE drive_id=? AND gen=? AND is_dir <> 1 AND (parent=? OR (parent >= ? AND parent < ?))"
                    args = [id, gen, path, path + "/", path + "0"]
                }
                for r in db.rows(sql, args) {
                    dest.have.insert(fileKey(r["name"] as? String ?? "", Int64(r["size"] as? Int ?? 0)))
                }
                if dest.have.isEmpty { dest.error = path.isEmpty ? "Not catalogued yet" : "Folder “\(path)” not in its catalog" }
            } else {
                dest.error = "Drive not catalogued yet"
            }
            dests.append(dest)
        }

        let queued = Scanner.shared.queueState().queued
        let deepLive = DeepCheck.shared.state()
        var cards: [[String: Any]] = []
        var safeCount = 0
        for c in s["cards"] as? [[String: Any]] ?? [] {
            let key = c["key"] as? String ?? ""
            var out = c
            out["online"] = online[key] != nil
            if let l = deepLive[key] { out["deep_live"] = l }
            guard let d = db.row("SELECT id, gen, status, status_detail, last_scan FROM drives WHERE key=?", [key]) else {
                out["state"] = "waiting"; cards.append(out); continue
            }
            out["id"] = d["id"]; out["last_scan"] = d["last_scan"] ?? NSNull()
            let scanning = (d["status"] as? String) == "scanning" || queued.contains(key)
            if scanning { out["state"] = "scanning"; out["detail"] = d["status_detail"] ?? ""; cards.append(out); continue }
            guard let id = d["id"] as? Int, let gen = d["gen"] as? Int, gen > 0 else {
                out["state"] = (d["status"] as? String) == "error" ? "error" : "waiting"
                out["detail"] = d["status_detail"] ?? ""; cards.append(out); continue
            }
            var ignored = 0
            var files: [(name: String, parent: String, size: Int64, key: String)] = []
            for r in db.rows("SELECT name, parent, size FROM entries WHERE drive_id=? AND gen=? AND is_dir <> 1", [id, gen]) {
                let n = r["name"] as? String ?? ""
                if !counts(n, shoot: s) { ignored += 1; continue }
                let size = Int64(r["size"] as? Int ?? 0)
                files.append((n, r["parent"] as? String ?? "", size, fileKey(n, size)))
            }
            let total = files.reduce(Int64(0)) { $0 + $1.size }
            var per: [[String: Any]] = []
            var safe = !files.isEmpty
            for dest in dests {
                let missing = files.filter { !dest.have.contains($0.key) }
                let missBytes = missing.reduce(Int64(0)) { $0 + $1.size }
                if !missing.isEmpty { safe = false }
                per.append(["have": files.count - missing.count, "missing": missing.count, "missing_bytes": missBytes,
                            "sample": missing.prefix(200).map { ["name": $0.name, "parent": $0.parent, "size": $0.size] as [String: Any] }])
            }
            if dests.isEmpty { safe = false }
            // A deep check result still applies while the card holds the same data.
            if let deep = c["deep"] as? [String: Any] {
                out["deep_valid"] = (deep["bytes"] as? NSNumber)?.int64Value == total && (deep["files"] as? NSNumber)?.intValue == files.count
                if out["deep_valid"] as? Bool == true, deep["state"] as? String == "problems" { safe = false }
            }
            if safe { safeCount += 1 }
            out["state"] = files.isEmpty ? "empty" : safe ? "safe" : "copying"
            out["files"] = files.count; out["bytes"] = total; out["dests"] = per; out["ignored"] = ignored
            cards.append(out)
        }
        return [
            "shoot": s,
            "dests": dests.map { ["key": $0.key, "name": $0.name, "path": $0.path, "online": $0.online, "live": $0.live,
                                  "last_scan": $0.lastScan ?? 0, "error": $0.error, "files": $0.have.count] as [String: Any] },
            "cards": cards, "safe": safeCount, "checked": Date().timeIntervalSince1970,
        ]
    }

    // MARK: - sharing between Macs

    static func exportJSON(_ db: DB) -> [String: Any] {
        var m: [String: Any] = [:]
        for s in all(db, includeDeleted: true) { if let u = s["uuid"] as? String { m[u] = s } }
        return ["format": 1, "shoots": m]
    }

    /// Merges shoots from another Mac: the newer version of each shoot wins. Returns true if anything changed.
    @discardableResult
    static func merge(_ db: DB, _ file: [String: Any]) -> Bool {
        var changed = false
        for (uuid, v) in file["shoots"] as? [String: Any] ?? [:] {
            guard let theirs = v as? [String: Any] else { continue }
            let mine = get(db, uuid)
            if (theirs["updated"] as? Double ?? 0) > (mine?["updated"] as? Double ?? 0) {
                put(db, theirs, keepStamp: true); changed = true
            }
        }
        return changed
    }
}

extension Scanner {
    /// Writes all shoots to `shoots.json` in the sync folder (merging what other Macs wrote first).
    func exportShoots() {
        queue.async {
            guard let dir = SyncFolder.url else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.writeShoots(dir)
        }
    }

    func writeShoots(_ dir: URL) {
        let f = dir.appendingPathComponent("shoots.json")
        if let data = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            Shoots.merge(db, o)
        }
        if let data = try? JSONSerialization.data(withJSONObject: Shoots.exportJSON(db), options: [.prettyPrinted]) {
            try? data.write(to: f, options: .atomic)
        }
    }

    func importShoots(_ dir: URL) {
        let f = dir.appendingPathComponent("shoots.json")
        guard let data = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        Shoots.merge(db, o)
    }
}
