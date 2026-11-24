import AppKit
import UniformTypeIdentifiers
import Foundation
import ServiceManagement

/// Handles calls from the web UI (window.webkit.messageHandlers.api). Runs on a background queue.
enum Bridge {
    static let db = DB()

    static func handle(_ action: String, _ a: [String: Any]) -> Any {
        func int(_ k: String) -> Int? {
            if let i = a[k] as? Int { return i }
            if let s = a[k] as? String { return Int(s) }
            return nil
        }
        func str(_ k: String) -> String { a[k] as? String ?? "" }
        func err(_ m: String) -> [String: Any] { ["error": m] }
        let ok: [String: Any] = ["ok": true]

        switch action {
        case "drives":
            let q = Scanner.shared.queueState()
            return db.drivesList(online: Scanner.onlineMap()).map { d -> [String: Any] in
                var d = d
                if q.queued.contains(d["key"] as? String ?? "") { d["queued"] = true }
                return d
            }

        case "list":
            guard let id = int("drive") else { return [Any]() }
            return db.listFolder(id, str("path"))

        case "search":
            return db.search(q: str("q"), drive: int("drive"), kind: str("kind"), path: str("path"))

        case "updateDrive":
            guard let id = int("id") else { return err("missing id") }
            db.run("UPDATE drives SET label=?, notes=? WHERE id=?",
                   [str("label").trimmingCharacters(in: .whitespacesAndNewlines), str("notes"), id])
            db.touchMeta([id])
            Scanner.shared.exportMeta([id])
            return ok

        case "forget":
            guard let id = int("id") else { return err("missing id") }
            let key = db.row("SELECT key FROM drives WHERE id=?", [id])?["key"] as? String
            let mains = db.mainsBackedUpBy(id)
            db.forget(id)
            if let key = key { Scanner.shared.exportTombstone(key: key) }
            Scanner.shared.recomputeCoverage(mains)
            Scanner.shared.exportMeta(mains)
            return ok

        case "pending":
            return Scanner.shared.pendingDrives()

        case "doneAttention":
            return Settings.doneAttention

        case "setDoneAttention":
            let keys = (a["keys"] as? [Any] ?? []).compactMap { $0 as? String }
            Settings.d.set(Array(keys.prefix(500)), forKey: "doneAttention")
            Scanner.shared.exportPrefs()
            return ok

        case "notACard":   // "It's not a memory card": catalog it as a normal drive from now on
            let k = str("key")
            var nc = Settings.notCardKeys
            if !nc.contains(k) { nc.append(k); Settings.d.set(nc, forKey: "notCardKeys") }
            db.run("UPDATE drives SET is_card=-1 WHERE key=?", [k])   // -1 = the user added this card to their drives (syncs)
            if let id = db.row("SELECT id FROM drives WHERE key=?", [k])?["id"] as? Int { db.touchMeta([id]); Scanner.shared.exportMeta([id]) }
            if Scanner.shared.pendingDrives().contains(where: { $0["key"] as? String == k }) { Scanner.shared.approve(k) }
            return ok

        case "forgetCards":   // forget memory cards that aren't part of any shoot
            let inShoots = Shoots.cardKeys(db)
            var n = 0
            for r in db.rows("SELECT id, key FROM drives WHERE is_card=1") {
                guard let id = r["id"] as? Int, let k = r["key"] as? String, inShoots[k] == nil else { continue }
                db.forget(id); Scanner.shared.exportTombstone(key: k); n += 1
            }
            return ["forgotten": n] as [String: Any]

        case "approveCard":   // a new drive the user added to the active shoot as a memory card
            guard !Shoots.activeID.isEmpty, Shoots.addCard(db, Shoots.activeID, key: str("key"), vol: str("name")) else {
                return err("No shoot is active.")
            }
            Scanner.shared.approve(str("key"))
            return ok

        case "approveDrive":
            Scanner.shared.approve(str("key"))
            return ok

        case "dismissDrive":
            Scanner.shared.dismiss(str("key"))
            return ok

        case "ignoreDrive":
            Scanner.shared.ignore(str("key"))
            return ok

        case "setRole":
            guard let id = int("id") else { return err("missing id") }
            let role = ["main", "backup"].contains(str("role")) ? str("role") : ""
            let affected = db.setRole(id, role)
            db.markChecking(affected)
            db.touchMeta([id])
            Scanner.shared.recomputeCoverage(affected)
            Scanner.shared.exportMeta([id])
            return ok

        case "setBackupOf":
            guard let id = int("id") else { return err("missing id") }
            let mains = (a["mains"] as? [Any] ?? []).compactMap { ($0 as? Int) ?? Int("\($0)") }
            let affected = db.setBackupOf(id, mains)
            db.markChecking(mains)
            db.touchMeta([id] + mains)
            Scanner.shared.recomputeCoverage(affected)
            Scanner.shared.exportMeta([id] + mains)
            return ok

        case "setExcluded":
            guard let id = int("id") else { return err("missing id") }
            db.setExcluded(id, str("path"), a["on"] as? Bool ?? true)
            db.markChecking([id])
            db.touchMeta([id])
            Scanner.shared.recomputeCoverage([id])
            Scanner.shared.exportMeta([id])
            return ok

        case "history":
            guard let id = int("drive") else { return [Any]() }
            return db.history(id)

        case "setReminder":
            guard let id = int("id") else { return err("missing id") }
            db.run("UPDATE drives SET remind_days=? WHERE id=?", [max(0, int("days") ?? 0), id])
            db.touchMeta([id])
            Scanner.shared.exportMeta([id])
            Scanner.shared.checkReminders()
            return ok

        case "setFolderBackup":
            guard let id = int("id"), let main = int("main"), main != id else { return err("Choose another drive.") }
            db.setFolderBackup(driveID: id, path: str("path"), mainID: main, on: a["on"] as? Bool ?? true)
            db.markChecking([main])
            db.touchMeta([id, main])
            Scanner.shared.recomputeCoverage([main])
            Scanner.shared.exportMeta([id, main])
            return ok

        case "setType":
            guard let id = int("id") else { return err("missing id") }
            let t = ["hdd", "ssd", "nas", "other"].contains(str("type")) ? str("type") : ""
            db.run("UPDATE drives SET media_user=? WHERE id=?", [t, id])
            db.touchMeta([id])
            Scanner.shared.exportMeta([id])
            return ok

        case "setBackupSet":
            guard let main = int("main") else { return err("missing drive") }
            let ids = (a["ids"] as? [Any] ?? []).compactMap { ($0 as? Int) ?? Int("\($0)") }
            let changed = db.setBackupSet(mainID: main, backupIDs: ids, on: a["on"] as? Bool ?? true)
            db.markChecking([main])
            db.touchMeta(changed)
            Scanner.shared.recomputeCoverage([main])
            Scanner.shared.exportMeta(changed)
            return ok

        case "setOrder":
            let ids = (a["ids"] as? [Any] ?? []).compactMap { ($0 as? Int) ?? Int("\($0)") }
            for (i, id) in ids.enumerated() { db.run("UPDATE drives SET sort_order=? WHERE id=?", [i, id]) }
            db.touchMeta(ids)
            Scanner.shared.exportMeta(ids)
            return ok

        case "updateStatus":
            return Updater.status()

        case "checkUpdate":
            return Updater.check()

        case "installUpdate":
            do { try Updater.install(); return ok } catch { return err(error.localizedDescription) }

        case "space":
            guard let id = int("id") else { return [String: Any]() }
            return db.spaceInfo(id)

        case "feedback":
            let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            let body = """
                **What happened / what would you like?**


                **Steps to see it (if it's a problem):**


                ---
                DriveDex \(v) (build \(b)) · \(ProcessInfo.processInfo.operatingSystemVersionString)
                """
            var c = URLComponents(string: "https://github.com/marcialsommer/drivedex/issues/new")!
            c.queryItems = [URLQueryItem(name: "title", value: str("kind") == "bug" ? "Problem: " : "Idea: "),
                            URLQueryItem(name: "body", value: body)]
            if let url = c.url { DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
            return ok

        case "openGuide":
            DispatchQueue.main.async {
                if let u = URL(string: "https://github.com/marcialsommer/drivedex/releases/latest/download/DriveDex-Guide.pdf") {
                    NSWorkspace.shared.open(u)
                }
            }
            return ok

        case "stopScan":
            guard let id = int("id"), let key = db.row("SELECT key FROM drives WHERE id=?", [id])?["key"] as? String
            else { return err("missing drive") }
            Scanner.shared.stop(key)
            return ok

        case "stopAll":
            Scanner.shared.stopAll()
            return ok

        case "setCopyOf":
            guard let copy = int("copy"), let main = int("main"), copy != main else { return err("Choose another drive.") }
            db.setCopyOf(copyID: copy, copyPath: str("copyPath"), mainID: main, mainPath: str("mainPath"))
            db.markChecking([main])
            db.touchMeta([main, copy])
            Scanner.shared.recomputeCoverage([main])
            Scanner.shared.exportMeta([main, copy])
            return ok

        case "eject":
            guard let id = int("id"), let key = db.driveKey(id), let v = Scanner.onlineMap()[key] else {
                return err("This drive isn't connected.")
            }
            Scanner.shared.letGo(v.url.standardizedFileURL.path)   // stop reading it first
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: v.url)
                return ok
            } catch {
                return err("Couldn't eject “\(v.name)”: \(error.localizedDescription) Another program may be using it; try again in a moment.")
            }

        // MARK: shoot mode
        case "shoots":
            return ["shoots": Shoots.all(db), "active": Shoots.activeID] as [String: Any]

        case "shootSave":
            guard var s = a["shoot"] as? [String: Any] else { return err("Nothing to save.") }
            if (s["uuid"] as? String ?? "").isEmpty {
                s["uuid"] = UUID().uuidString.lowercased(); s["created"] = Date().timeIntervalSince1970
                s["cards"] = [Any](); s["skipProxies"] = s["skipProxies"] ?? true; s["mediaOnly"] = s["mediaOnly"] ?? true
            } else if let old = Shoots.get(db, s["uuid"] as? String ?? "") {
                s["cards"] = old["cards"] ?? [Any](); s["notCards"] = old["notCards"] ?? [Any]()   // cards are only changed below
            }
            Shoots.put(db, s)
            if a["activate"] as? Bool == true {
                Shoots.activeID = s["uuid"] as? String ?? ""
                Scanner.shared.scanAllConnected(force: false, reason: .mount)
            }
            return ["uuid": s["uuid"] ?? ""] as [String: Any]

        case "shootActivate":
            Shoots.activeID = str("uuid")
            if !str("uuid").isEmpty { Scanner.shared.scanAllConnected(force: false, reason: .mount) }
            return ok

        case "shootDelete":
            guard var s = Shoots.get(db, str("uuid")) else { return ok }
            s["deleted"] = true; s["cards"] = [Any]()
            Shoots.put(db, s)
            if Shoots.activeID == str("uuid") { Shoots.activeID = "" }
            return ok

        case "shootDone":
            guard var s = Shoots.get(db, str("uuid")) else { return err("Shoot not found.") }
            let done = a["done"] as? Bool ?? true
            s["done"] = done
            if done {
                // Keep a record of how each card ended up, in case the cards are formatted and reused.
                let st = Shoots.status(db, str("uuid"))
                var cards = s["cards"] as? [[String: Any]] ?? []
                let res = st["cards"] as? [[String: Any]] ?? []
                for i in cards.indices {
                    if let r = res.first(where: { $0["key"] as? String == cards[i]["key"] as? String }) {
                        cards[i]["final"] = ["state": r["state"] ?? "", "files": r["files"] ?? 0, "bytes": r["bytes"] ?? 0] as [String: Any]
                    }
                }
                s["cards"] = cards
                if Shoots.activeID == str("uuid") { Shoots.activeID = "" }
            }
            Shoots.put(db, s)
            return ok

        case "chooseFolder":   // the Mac's folder window: any connected drive, NAS or the internal drive
            var picked: URL?
            let message = str("message")
            // Start in a given drive (and folder, if it exists yet).
            var startURL: URL? = nil
            if !str("start").isEmpty, let v = Scanner.onlineMap()[str("start")] {
                let sub = v.url.appendingPathComponent(str("path"), isDirectory: true)
                startURL = !str("path").isEmpty && FileManager.default.fileExists(atPath: sub.path) ? sub : v.url
            }
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true; p.canChooseFiles = false
                    p.canCreateDirectories = true; p.allowsMultipleSelection = false
                    p.prompt = "Choose"; p.message = message
                    if let u = startURL { p.directoryURL = u }
                    NSApp.activate(ignoringOtherApps: true)
                    if p.runModal() == .OK { picked = p.url }
                }
            }
            guard let url = picked?.standardizedFileURL else { return ["cancelled": true] as [String: Any] }
            let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume?.standardizedFileURL
            if let vol = volume, vol.path.hasPrefix("/Volumes/"), let v = Scanner.eligible(vol) {
                var rel = String(url.path.dropFirst(vol.path.count))
                while rel.hasPrefix("/") { rel.removeFirst() }
                let label = db.row("SELECT COALESCE(NULLIF(label,''), name) AS n FROM drives WHERE key=?", [v.key])?["n"] as? String
                return ["key": v.key, "path": rel, "name": label ?? v.name] as [String: Any]
            }
            if volume?.path.hasPrefix("/Volumes/") == true {
                return err("DriveDex can't use that drive (it's a disk image, or on the never-scan list in Settings).")
            }
            return ["key": "local:" + SyncFolder.machine, "local": true, "mac": SyncFolder.machine, "path": url.path,
                    "name": SyncFolder.machine + " · internal drive"] as [String: Any]

        case "formatCard":   // erase + format a safe card, keeping (or setting) its name
            switch CardTools.format(db: db, shoot: str("uuid"), key: str("key"), name: str("name"),
                                    allowQuickOnly: a["quick"] as? Bool ?? false, eject: a["eject"] as? Bool ?? true) {
            case .success(let n): return ["name": n] as [String: Any]
            case .failure(let f): return err(f.message)
            }

        case "renameCard":
            switch CardTools.rename(db: db, shoot: str("uuid"), key: str("key"), name: str("name")) {
            case .success(let n): return ["name": n] as [String: Any]
            case .failure(let f): return err(f.message)
            }

        case "speedTest":
            guard let id = int("id") else { return err("missing id") }
            if let e = SpeedTest.shared.start(id: id, write: a["write"] as? Bool ?? false, note: str("note")) { return err(e) }
            return ok

        case "speedState":
            return SpeedTest.shared.state()

        case "resolveRename":   // after a Finder rename: use the drive's new name in DriveDex, or keep DriveDex's name
            guard let id = int("id") else { return err("missing id") }
            if a["use"] as? Bool == true { db.run("UPDATE drives SET label='', renamed_from='' WHERE id=?", [id]) }
            else { db.run("UPDATE drives SET renamed_from='' WHERE id=?", [id]) }
            db.touchMeta([id]); Scanner.shared.exportMeta([id])
            return ok

        case "renameVolume":   // rename the drive itself (Finder name), on the user's request
            guard let id = int("id"), let key = db.driveKey(id), let v = Scanner.onlineMap()[key] else { return err("The drive isn't connected.") }
            guard v.kind != "network" else { return err("Network shares are renamed on the NAS itself.") }
            let name = str("name").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.rangeOfCharacter(from: CharacterSet(charactersIn: ":/")) == nil else { return err("That name can't be used for a drive.") }
            let r = CardTools.diskutil(["rename", v.url.path, name])
            guard r.ok else {
                let last = r.output.split(separator: "\n").last.map(String.init) ?? ""
                return err("macOS couldn't rename the drive" + (v.fs.lowercased().contains("fat") ? " (memory-card formats allow at most 11 characters)" : "") + ". " + last)
            }
            db.run("UPDATE drives SET name=?, label='', renamed_from='' WHERE id=?", [name, id])
            db.touchMeta([id]); Scanner.shared.exportMeta([id])
            return ok

        case "setSchedule":   // per drive: when to rescan, and when to remind
            guard let id = int("id") else { return err("missing id") }
            let allowed = ["", "connect", "hourly", "daily", "weekly", "monthly", "changes", "manual"]
            let sched = allowed.contains(str("schedule")) ? str("schedule") : ""
            db.run("UPDATE drives SET scan_schedule=?, remind_scan_days=? WHERE id=?", [sched, max(0, int("remind") ?? 0), id])
            db.touchMeta([id]); Scanner.shared.exportMeta([id])
            Scanner.shared.refreshWatchers()
            return ok

        case "exportOverview":   // one readable file about all drives, to share with Claude (or keep)
            let depth = max(1, min(4, int("depth") ?? 3))
            let text = db.overviewMarkdown(online: Scanner.onlineMap(), fileNames: a["names"] as? Bool ?? false, depth: depth)
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            let fileName = "DriveDex overview \(df.string(from: Date())).md"
            var target: URL? = nil
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    let p = NSSavePanel()
                    p.nameFieldStringValue = fileName
                    p.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
                    p.canCreateDirectories = true
                    p.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                    NSApp.activate(ignoringOtherApps: true)
                    if p.runModal() == .OK { target = p.url }
                }
            }
            guard let url = target else { return ["cancelled": true] as [String: Any] }
            do { try text.data(using: .utf8)?.write(to: url, options: .atomic) } catch { return err("Couldn't save: \(error.localizedDescription)") }
            return ["path": url.path, "size": text.utf8.count] as [String: Any]

        case "exportLog":   // save a shoot's card log as a spreadsheet file (CSV) where the user chooses
            let rows = (a["rows"] as? [[Any]] ?? []).map { $0.map { "\($0)" } }
            let sep = Locale.current.decimalSeparator == "," ? ";" : ","     // what Excel expects on this Mac
            func cell(_ v: String) -> String {
                v.contains(sep) || v.contains("\"") || v.contains("\n") ? "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : v
            }
            let csv = "\u{FEFF}" + rows.map { $0.map(cell).joined(separator: sep) }.joined(separator: "\r\n") + "\r\n"
            // Start in the shoot's main folder (if it's reachable), so the log ends up with the footage.
            var startDir: URL? = nil
            if let s = Shoots.get(db, str("uuid")), let m = s["main"] as? [String: Any] {
                if let r = Shoots.localRoot(m) { startDir = r }
                else if let v = Scanner.onlineMap()[m["key"] as? String ?? ""] {
                    let p = (m["path"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                    let r = p.isEmpty ? v.url : v.url.appendingPathComponent(p, isDirectory: true)
                    startDir = FileManager.default.fileExists(atPath: r.path) ? r : v.url
                }
            }
            let fileName = str("filename")
            var target: URL? = nil
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    let p = NSSavePanel()
                    p.nameFieldStringValue = fileName
                    p.allowedContentTypes = [.commaSeparatedText]
                    p.canCreateDirectories = true
                    if let d = startDir { p.directoryURL = d }
                    NSApp.activate(ignoringOtherApps: true)
                    if p.runModal() == .OK { target = p.url }
                }
            }
            guard let url = target else { return ["cancelled": true] as [String: Any] }
            do { try csv.data(using: .utf8)?.write(to: url, options: .atomic) } catch { return err("Couldn't save: \(error.localizedDescription)") }
            return ["path": url.path] as [String: Any]

        case "deepStart":
            if let e = DeepCheck.shared.start(shoot: str("uuid"), card: str("key")) { return err(e) }
            return ok

        case "deepStop":
            DeepCheck.shared.stop(str("key"))
            return ok

        case "deepState":
            return DeepCheck.shared.state()

        case "shootStatus":
            return Shoots.status(db, str("uuid"))

        case "shootCard":   // rename, remove ("not a card") or add a catalogued drive as a card
            guard var s = Shoots.get(db, str("uuid")) else { return err("Shoot not found.") }
            var cards = s["cards"] as? [[String: Any]] ?? []
            let key = str("key")
            switch str("op") {
            case "label":
                if let i = cards.firstIndex(where: { $0["key"] as? String == key }) { cards[i]["label"] = str("label") }
            case "remove":
                cards.removeAll { $0["key"] as? String == key }
                var nc = s["notCards"] as? [String] ?? []
                if !nc.contains(key) { nc.append(key) }
                s["notCards"] = nc
            case "addKey":   // any drive (catalogued or not) by key; it's read as a card right away
                let k = str("key")
                guard !k.isEmpty, Shoots.addCard(db, str("uuid"), key: k, vol: str("name")) else { return err("Drive not found.") }
                if Scanner.shared.pendingDrives().contains(where: { $0["key"] as? String == k }) { Scanner.shared.approve(k) }
                else if let v = Scanner.onlineMap()[k] { Scanner.shared.enqueue(v, force: true, approved: true) }
                return ok
            case "add":
                guard let id = int("id"), let k = db.driveKey(id) else { return err("Drive not found.") }
                if !cards.contains(where: { $0["key"] as? String == k }) {
                    let name = db.row("SELECT name FROM drives WHERE id=?", [id])?["name"] as? String ?? ""
                    cards.append(["key": k, "label": "Card \(cards.count + 1)", "vol": name, "added": Date().timeIntervalSince1970,
                                  "mac": SyncFolder.machine])
                }
                s["notCards"] = (s["notCards"] as? [String] ?? []).filter { $0 != k }
            default: return err("Unknown change.")
            }
            s["cards"] = cards
            Shoots.put(db, s)
            return ok

        case "removeLink":
            guard let main = int("main"), let bk = int("backup") else { return err("missing drive") }
            db.removeLink(mainID: main, backupID: bk)
            db.markChecking([main]); db.touchMeta([main, bk])
            Scanner.shared.recomputeCoverage([main]); Scanner.shared.exportMeta([main, bk])
            return ok

        case "linksSnapshot":
            let ids = (a["ids"] as? [Any] ?? []).compactMap { ($0 as? Int) ?? Int("\($0)") }
            return db.linksSnapshot(ids)

        case "linksRestore":
            guard let snap = a["snap"] as? [String: Any] else { return err("Nothing to undo.") }
            let r = db.linksRestore(snap)
            db.markChecking(r.mains); db.touchMeta(r.all)
            Scanner.shared.recomputeCoverage(r.mains); Scanner.shared.exportMeta(r.all)
            return ok

        case "setBackupScope":
            guard let main = int("main"), let bk = int("backup"), main != bk else { return err("Choose another drive.") }
            db.setBackupScope(mainID: main, backupID: bk, path: str("path"))
            db.markChecking([main])
            db.touchMeta([main, bk])
            Scanner.shared.recomputeCoverage([main])
            Scanner.shared.exportMeta([main, bk])
            return ok

        case "folderInfo":
            guard let id = int("drive") else { return [String: Any]() }
            return db.folderInfo(id, str("path"))

        case "scanLog":
            guard let id = int("id") else { return [Any]() }
            return db.scanLog(id)

        case "folderCoverage":
            guard let id = int("drive") else { return [String: Any]() }
            return db.folderCoverage(id, str("path"))

        case "missingFromSet":
            guard let id = int("drive") else { return err("missing drive") }
            return db.missingFromSet(id, setKey: str("set"))

        case "missing":
            guard let id = int("drive") else { return err("missing drive") }
            return db.missingFiles(id, maxCopies: int("max") ?? 0)

        case "syncICloud":
            guard SyncFolder.iCloudAvailable else { return err("iCloud Drive isn't turned on for this Mac (System Settings → Apple Account → iCloud → iCloud Drive).") }
            SyncFolder.set(SyncFolder.iCloudFolder)
            Scanner.shared.syncNow(exportAll: true)
            return settings()

        case "syncChoose":
            let chosen: URL? = DispatchQueue.main.sync { MainActor.assumeIsolated {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.prompt = "Use This Folder"
                panel.message = "Choose a folder that all your Macs can reach (Dropbox, a NAS share…). Pick the same folder on each Mac."
                NSApp.activate(ignoringOtherApps: true)
                return panel.runModal() == .OK ? panel.url : nil
            } }
            guard var url = chosen else { return settings() }
            if url.lastPathComponent != "DriveDex" { url.appendPathComponent("DriveDex", isDirectory: true) }
            SyncFolder.set(url)
            Scanner.shared.syncNow(exportAll: true)
            return settings()

        case "syncOff":
            SyncFolder.set(nil)
            return settings()

        case "syncNow":
            Scanner.shared.syncNow(exportAll: true)
            return ok

        case "rescan", "reveal":
            guard let id = int("id"),
                  let key = db.row("SELECT key FROM drives WHERE id=?", [id])?["key"] as? String,
                  let vol = Scanner.onlineMap()[key]
            else { return err("That drive isn't connected right now.") }
            if action == "rescan" {
                let busy = Scanner.shared.queueState().busy
                Scanner.shared.enqueue(vol, force: true)
                return ["ok": true, "queued": busy]
            }
            let root = vol.url.standardizedFileURL
            let path = str("path")
            let target = path.isEmpty ? root : root.appendingPathComponent(path).standardizedFileURL
            guard target.path.hasPrefix(root.path) else { return err("Bad path.") }
            guard FileManager.default.fileExists(atPath: target.path) else {
                return err("That folder isn't there any more — try rescanning the drive.")
            }
            DispatchQueue.main.async {
                if path.isEmpty { NSWorkspace.shared.open(target) }
                else { NSWorkspace.shared.activateFileViewerSelecting([target]) }
            }
            return ok

        case "scanConnected":
            Scanner.shared.scanAllConnected(force: true)
            return ok

        case "getSettings":
            return settings()

        case "setSettings":
            let d = Settings.d
            if let v = a["rescanAfterHours"] as? Double { d.set(max(0, v), forKey: "rescanAfterHours") }
            if let v = a["periodicRescanHours"] as? Double { d.set(max(1, v), forKey: "periodicRescanHours") }
            if let v = a["includeHidden"] as? Bool { d.set(v, forKey: "includeHidden") }
            if let v = a["skipDiskImages"] as? Bool { d.set(v, forKey: "skipDiskImages") }
            if let v = a["notify"] as? Bool { d.set(v, forKey: "notify") }
            if let v = a["askNew"] as? Bool { d.set(v, forKey: "askNew") }
            if let v = a["showMenuBarIcon"] as? Bool {
                d.set(v, forKey: "showMenuBarIcon")
                DispatchQueue.main.async { MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.statusItem?.isVisible = v } }
            }
            if let v = a["onboarded"] as? Bool { d.set(v, forKey: "onboarded") }
            if let v = a["strictCheck"] as? Bool, v != Settings.strictCheck {
                d.set(v, forKey: "strictCheck")
                let mains = db.rows("SELECT DISTINCT main_id FROM backups").compactMap { $0["main_id"] as? Int }
                db.markChecking(mains)
                Scanner.shared.recomputeCoverage(mains)
                Scanner.shared.exportPrefs()
            }
            if let v = a["ignoreVolumes"] as? [String] {
                let clean = v.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if clean != Settings.ignoreVolumes {
                    d.set(clean, forKey: "ignoreVolumes")
                    Scanner.shared.exportPrefs()
                }
            }
            if let v = a["openAtLogin"] as? Bool {
                do {
                    if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    NSLog("DriveDex login item: %@", error.localizedDescription)
                }
            }
            return settings()

        case "openPrivacy":
            DispatchQueue.main.async {
                if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(u)
                }
            }
            return ok

        case "openLoginItems":
            DispatchQueue.main.async { SMAppService.openSystemSettingsLoginItems() }
            return ok

        default:
            return err("Unknown action \(action)")
        }
    }

    static func settings() -> [String: Any] {
        let status: String
        switch SMAppService.mainApp.status {
        case .enabled: status = "enabled"
        case .requiresApproval: status = "requiresApproval"
        case .notFound: status = "notFound"
        default: status = "off"
        }
        return [
            "rescanAfterHours": Settings.rescanAfterHours,
            "periodicRescanHours": Settings.periodicRescanHours,
            "includeHidden": Settings.includeHidden,
            "skipDiskImages": Settings.skipDiskImages,
            "notify": Settings.notify,
            "askNew": Settings.askNew,
            "strictCheck": Settings.strictCheck,
            "showMenuBarIcon": Settings.showMenuBarIcon,
            "onboarded": Settings.d.bool(forKey: "onboarded"),
            "ignoreVolumes": Settings.ignoreVolumes,
            "openAtLogin": status == "enabled",
            "loginStatus": status,
            "catalogPath": Paths.support.path,
            "syncFolder": SyncFolder.url?.path ?? "",
            "syncIsICloud": SyncFolder.url?.path == SyncFolder.iCloudFolder.path,
            "iCloudAvailable": SyncFolder.iCloudAvailable,
            "lastSync": Settings.d.double(forKey: "lastSync"),
            "syncError": Settings.d.string(forKey: "syncError") ?? "",
            "machine": SyncFolder.machine,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        ]
    }
}
