import Foundation
import UserNotifications

/// Deep check (Shoot mode): reads every file on a memory card and each copy of it in the shoot's main and
/// backup folders, and compares xxHash64 fingerprints of the contents. Read-only: it never writes to any drive.
/// Checks run one at a time; a card's result is saved in the shoot (`cards[i]["deep"]`), so it syncs and is
/// shown until the card's contents change.
final class DeepCheck {
    static let shared = DeepCheck()

    private let queue = DispatchQueue(label: "drivedex.deep", qos: .utility)
    private lazy var db = DB()                       // only touched on `queue`
    private let lock = NSLock()
    private var live: [String: [String: Any]] = [:]  // card key -> progress shown in the app
    private var stopKeys = Set<String>()

    private struct Stop: Error { let reason: String }
    private struct ReadFailed: Error { let message: String }

    /// Live progress of queued / running checks, by card key.
    func state() -> [String: [String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return live
    }

    /// Queues a deep check of one card. Returns an error message, or nil.
    func start(shoot uuid: String, card key: String) -> String? {
        lock.lock()
        if live[key] != nil { lock.unlock(); return nil }          // already queued or running
        live[key] = ["phase": "queued", "uuid": uuid]
        stopKeys.remove(key)
        lock.unlock()
        queue.async { self.run(uuid, key) }
        return nil
    }

    func stop(_ key: String) {
        lock.lock(); stopKeys.insert(key); lock.unlock()
    }

    private func setLive(_ key: String, _ values: [String: Any]) {
        lock.lock(); live[key, default: [:]].merge(values) { _, new in new }; lock.unlock()
    }

    private func addDone(_ key: String, _ n: Int) {
        lock.lock()
        let d = (live[key]?["done"] as? Int64 ?? 0) + Int64(n)
        live[key]?["done"] = d
        lock.unlock()
    }

    private func stopReason(_ key: String, _ mounts: [URL]) -> String? {
        lock.lock(); let asked = stopKeys.contains(key); lock.unlock()
        if asked { return "Stopped" }
        if mounts.contains(where: { Scanner.shared.isEjecting($0) || !FileManager.default.fileExists(atPath: $0.path) }) {
            return "Stopped: a drive was ejected or disconnected"
        }
        return nil
    }

    // MARK: - reading

    /// Fingerprint of a file's contents, read straight from the drive (caching off).
    private func fingerprint(_ url: URL, key: String, mounts: [URL]) throws -> UInt64 {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw ReadFailed(message: String(cString: strerror(errno))) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let size = 8 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buf.deallocate() }
        var x = XXH64()
        var sinceCheck = 0
        while true {
            let n = read(fd, buf, size)
            if n < 0 {
                if errno == EINTR { continue }
                throw ReadFailed(message: String(cString: strerror(errno)))
            }
            if n == 0 { break }
            x.update(UnsafeRawBufferPointer(start: buf, count: n))
            addDone(key, n)
            sinceCheck += n
            if sinceCheck >= 64 << 20 {
                sinceCheck = 0
                if let r = stopReason(key, mounts) { throw Stop(reason: r) }
            }
        }
        return x.digest()
    }

    private struct FileItem { let url: URL; let rel: String; let name: String; let size: Int64 }

    /// Regular files under `root` (hidden files and macOS helper files left out, like a scan).
    private func listFiles(_ root: URL, skipProxies: Bool) -> [FileItem] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let opts: FileManager.DirectoryEnumerationOptions = Settings.includeHidden ? [] : [.skipsHiddenFiles]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: opts,
                                                      errorHandler: { _, _ in true }) else { return [] }
        let rootPath = root.standardizedFileURL.path
        var out: [FileItem] = []
        for case let u as URL in en {
            let n = u.lastPathComponent
            if n.hasPrefix("._") || n == ".DS_Store" || n == ".Spotlight-V100" || n == ".fseventsd" || n == ".Trashes" {
                if n.hasPrefix(".") && n != ".DS_Store" && !n.hasPrefix("._") { en.skipDescendants() }
                continue
            }
            if skipProxies && Shoots.proxyExts.contains(u.pathExtension.lowercased()) { continue }
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let full = u.standardizedFileURL.path
            var rel = full.hasPrefix(rootPath) ? String(full.dropFirst(rootPath.count)) : full
            if rel.hasPrefix("/") { rel.removeFirst() }
            out.append(FileItem(url: u, rel: rel, name: n, size: Int64(v.fileSize ?? 0)))
        }
        return out
    }

    // MARK: - the check

    private func run(_ uuid: String, _ key: String) {
        let t0 = Date()
        defer { lock.lock(); live.removeValue(forKey: key); stopKeys.remove(key); lock.unlock() }
        guard let shoot = Shoots.get(db, uuid) else { return }
        let online = Scanner.onlineMap()
        guard let card = online[key] else {
            save(uuid, key, ["state": "error", "error": "The card isn't connected.", "at": Date().timeIntervalSince1970]); return
        }
        let skipProxies = shoot["skipProxies"] as? Bool ?? true

        // Destinations: the main folder and each backup folder.
        var specs: [[String: Any]] = []
        if let m = shoot["main"] as? [String: Any] { specs.append(m) }
        specs += shoot["backups"] as? [[String: Any]] ?? []
        struct Dest { let name: String; let path: String; let mount: URL?; let root: URL?; var index: [String: [URL]] = [:] }
        var dests: [Dest] = specs.map { spec in
            let k = spec["key"] as? String ?? ""
            let path = (spec["path"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            let name = db.row("SELECT COALESCE(NULLIF(label,''), name) AS n FROM drives WHERE key=?", [k])?["n"] as? String ?? "?"
            guard let v = online[k] else { return Dest(name: name, path: path, mount: nil, root: nil) }
            return Dest(name: name, path: path, mount: v.url, root: path.isEmpty ? v.url : v.url.appendingPathComponent(path, isDirectory: true))
        }
        let mounts = [card.url] + dests.compactMap { $0.mount }

        setLive(key, ["phase": "listing", "started": t0.timeIntervalSince1970])
        let files = listFiles(card.url, skipProxies: skipProxies)
        for i in dests.indices {
            guard let root = dests[i].root else { continue }
            var idx: [String: [URL]] = [:]
            for f in listFiles(root, skipProxies: false) { idx[matchKey(f.name) + "\u{0}" + String(f.size), default: []].append(f.url) }
            dests[i].index = idx
        }
        let cardBytes = files.reduce(Int64(0)) { $0 + $1.size }
        let connected = dests.filter { $0.root != nil }.count
        setLive(key, ["phase": "checking", "total": cardBytes * Int64(1 + connected), "done": Int64(0), "files": files.count])

        var ok = [Int](repeating: 0, count: dests.count)
        var missing = [Int](repeating: 0, count: dests.count)
        var different = [Int](repeating: 0, count: dests.count)
        var problems: [[String: Any]] = []
        var unreadable = 0
        var stoppedReason: String? = nil
        let pLock = NSLock()

        fileLoop: for (n, f) in files.enumerated() {
            if let r = stopReason(key, mounts) { stoppedReason = r; break }
            setLive(key, ["file": f.rel, "index": n + 1])
            let want: UInt64
            do { want = try fingerprint(f.url, key: key, mounts: mounts) }
            catch let s as Stop { stoppedReason = s.reason; break fileLoop }
            catch {
                unreadable += 1
                problems.append(["name": f.name, "parent": (f.rel as NSString).deletingLastPathComponent, "size": f.size,
                                 "dest": -1, "reason": "Couldn't read it on the card: \((error as? ReadFailed)?.message ?? error.localizedDescription)"])
                continue
            }
            // Compare with each destination at the same time (they are usually different drives).
            let fk = matchKey(f.name) + "\u{0}" + String(f.size)
            var stopHere: String? = nil
            DispatchQueue.concurrentPerform(iterations: dests.count) { j in
                guard dests[j].root != nil else { return }
                let cands = dests[j].index[fk] ?? []
                var result = cands.isEmpty ? "missing" : "different"
                var detail = ""
                for c in cands {
                    do { if try fingerprint(c, key: key, mounts: mounts) == want { result = "ok"; break } }
                    catch let s as Stop { pLock.lock(); stopHere = s.reason; pLock.unlock(); return }
                    catch { detail = (error as? ReadFailed)?.message ?? error.localizedDescription }
                }
                pLock.lock()
                switch result {
                case "ok": ok[j] += 1
                case "missing": missing[j] += 1
                default:
                    different[j] += 1
                    if problems.count < 300 {
                        problems.append(["name": f.name, "parent": (f.rel as NSString).deletingLastPathComponent, "size": f.size, "dest": j,
                                         "reason": detail.isEmpty ? "The copy's contents are different" : "Couldn't read the copy: \(detail)"])
                    }
                }
                if result == "missing" && problems.count < 300 {
                    problems.append(["name": f.name, "parent": (f.rel as NSString).deletingLastPathComponent, "size": f.size, "dest": j,
                                     "reason": "No copy with the same name and size"])
                }
                pLock.unlock()
            }
            if let r = stopHere { stoppedReason = r; break }
        }

        let bad = unreadable + different.reduce(0, +) + missing.reduce(0, +)
        let state: String
        if let _ = stoppedReason { state = "stopped" }
        else if files.isEmpty { state = "empty" }
        else if bad > 0 { state = "problems" }
        else if connected < dests.count { state = "partial" }
        else { state = "verified" }
        var destResults: [[String: Any]] = []
        for j in dests.indices {
            destResults.append(["name": dests[j].name, "path": dests[j].path, "connected": dests[j].root != nil,
                                "ok": ok[j], "missing": missing[j], "different": different[j]])
        }
        let result: [String: Any] = [
            "state": state, "at": Date().timeIntervalSince1970, "seconds": Date().timeIntervalSince(t0),
            "mac": SyncFolder.machine, "files": files.count, "bytes": cardBytes, "unreadable": unreadable,
            "dests": destResults, "problems": problems, "stopped": stoppedReason ?? "",
        ]
        save(uuid, key, result)

        let label = ((shoot["cards"] as? [[String: Any]] ?? []).first { $0["key"] as? String == key }?["label"] as? String) ?? card.name
        let msg: String
        switch state {
        case "verified": msg = "\(label): deep check passed. Every file matches on all copies, safe to format."
        case "partial": msg = "\(label): every file matches on the connected copies, but not all of the shoot's drives were connected."
        case "problems": msg = "\(label): deep check found \(bad) problem\(bad == 1 ? "" : "s"). Don't format the card yet."
        case "stopped": msg = "\(label): deep check \(stoppedReason?.lowercased() ?? "stopped")."
        default: msg = "\(label): the card is empty."
        }
        let c = UNMutableNotificationContent()
        c.title = "DriveDex"
        c.body = msg
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    private func save(_ uuid: String, _ key: String, _ result: [String: Any]) {
        guard var s = Shoots.get(db, uuid) else { return }
        var cards = s["cards"] as? [[String: Any]] ?? []
        guard let i = cards.firstIndex(where: { $0["key"] as? String == key }) else { return }
        cards[i]["deep"] = result
        s["cards"] = cards
        Shoots.put(db, s)
    }
}
