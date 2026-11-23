import AppKit
import CryptoKit
import Foundation

/// Shares the catalog between Macs through a common folder (iCloud Drive by default).
/// Each drive is stored as `<id>.entries.db` (its file list, rewritten after each scan) and
/// `<id>.meta.json` (name, notes, role, backup assignments). Each Mac imports whatever is newer.
enum SyncFolder {
    static var iCloudDrive: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }
    static var iCloudAvailable: Bool { FileManager.default.fileExists(atPath: iCloudDrive.path) }
    static var iCloudFolder: URL { iCloudDrive.appendingPathComponent("DriveDex", isDirectory: true) }

    static var url: URL? {
        let p = Settings.d.string(forKey: "syncFolder") ?? ""
        return p.isEmpty ? nil : URL(fileURLWithPath: p, isDirectory: true)
    }

    static func set(_ url: URL?) {
        Settings.d.set(url?.path ?? "", forKey: "syncFolder")
        Settings.d.removeObject(forKey: "syncStamps")
    }

    static func fileID(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    static var machine: String { Host.current().localizedName ?? "a Mac" }
}

extension Scanner {
    func startSync() {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.syncNow() }
        syncNow()
    }

    /// Import anything new from the sync folder. With `exportAll`, first publish every local drive.
    func syncNow(exportAll: Bool = false) {
        queue.async {
            guard let dir = SyncFolder.url else { return }
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if exportAll {
                    let ids = self.db.rows("SELECT id FROM drives").compactMap { $0["id"] as? Int }
                    for id in ids { self.writeEntries(id, dir); self.writeMeta(id, dir) }
                    let mains = self.db.rows("SELECT DISTINCT main_id FROM backups").compactMap { $0["main_id"] as? Int }
                    for id in mains { self.writeHistory(id, dir) }
                    self.writePrefs(dir)
                }
                self.importAll(dir)
                Settings.d.set(Date().timeIntervalSince1970, forKey: "lastSync")
                Settings.d.set("", forKey: "syncError")
            } catch {
                Settings.d.set(error.localizedDescription, forKey: "syncError")
            }
        }
    }

    /// Publish these drives' catalogs + info (after a scan).
    func exportToSync(_ ids: [Int]) {
        guard let dir = SyncFolder.url else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for id in ids { writeEntries(id, dir); writeMeta(id, dir) }
    }

    /// Publish only names/notes/roles (after an edit). Safe to call from any thread.
    func exportMeta(_ ids: [Int]) {
        queue.async {
            guard let dir = SyncFolder.url else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for id in ids { self.writeMeta(id, dir) }
        }
    }

    func exportTombstone(key: String) {
        queue.async {
            guard let dir = SyncFolder.url else { return }
            let m: [String: Any] = ["key": key, "forgotten": true, "updated": Date().timeIntervalSince1970, "format": 1]
            let f = dir.appendingPathComponent(SyncFolder.fileID(key) + ".meta.json")
            if let data = try? JSONSerialization.data(withJSONObject: m) { try? data.write(to: f, options: .atomic) }
            self.rememberStamp(f)
        }
    }

    /// Recompute a main drive's backup coverage and share any new history entries. Runs on `queue`.
    func recompute(_ id: Int) {
        if db.recomputeCoverage(id), let dir = SyncFolder.url { writeHistory(id, dir) }
    }

    /// Share the "never scan these drives" list (last change wins). Safe from any thread.
    func exportPrefs() {
        Settings.d.set(Date().timeIntervalSince1970, forKey: "prefsUpdated")
        queue.async {
            guard let dir = SyncFolder.url else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.writePrefs(dir)
        }
    }

    // MARK: - internals (run on `queue`)

    private func writePrefs(_ dir: URL) {
        let f = dir.appendingPathComponent("prefs.json")
        let mine = Settings.d.double(forKey: "prefsUpdated")
        if let data = try? Data(contentsOf: f), let p = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (p["updated"] as? Double ?? 0) > mine { return }
        let p: [String: Any] = ["ignoreVolumes": Settings.ignoreVolumes, "updated": mine, "format": 1]
        if let data = try? JSONSerialization.data(withJSONObject: p, options: [.prettyPrinted]) {
            try? data.write(to: f, options: .atomic)
            rememberStamp(f)
        }
    }

    private func writeHistory(_ mainID: Int, _ dir: URL) {
        guard let key = db.driveKey(mainID) else { return }
        let f = dir.appendingPathComponent(SyncFolder.fileID(key) + ".history.json")
        // Merge with what other Macs wrote so nobody's entries get lost.
        if let data = try? Data(contentsOf: f), let h = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let entries = h["entries"] as? [[String: Any]] {
            _ = db.mergeHistory(mainKey: key, entries)
        }
        let out: [String: Any] = ["main": key, "entries": db.historyForSync(mainID), "format": 1]
        if let data = try? JSONSerialization.data(withJSONObject: out) {
            try? data.write(to: f, options: .atomic)
            rememberStamp(f)
        }
    }

    private var stamps: [String: Double] {
        get { Settings.d.dictionary(forKey: "syncStamps") as? [String: Double] ?? [:] }
        set { Settings.d.set(newValue, forKey: "syncStamps") }
    }

    private func modDate(_ f: URL) -> Double {
        (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
    }

    private func rememberStamp(_ f: URL) {
        var s = stamps
        s[f.lastPathComponent] = modDate(f)
        stamps = s
    }

    private func writeEntries(_ id: Int, _ dir: URL) {
        guard let key = db.row("SELECT key FROM drives WHERE id=?", [id])?["key"] as? String else { return }
        let fm = FileManager.default
        let final = dir.appendingPathComponent(SyncFolder.fileID(key) + ".entries.db")
        let tmp = fm.temporaryDirectory.appendingPathComponent("drivedex-export-\(UUID().uuidString).db")
        defer { try? fm.removeItem(at: tmp) }
        guard db.exportDrive(id, to: tmp.path, machine: SyncFolder.machine) else { return }
        let staging = dir.appendingPathComponent(".\(SyncFolder.fileID(key)).uploading")
        try? fm.removeItem(at: staging)
        do {
            try fm.copyItem(at: tmp, to: staging)
            if fm.fileExists(atPath: final.path) {
                _ = try fm.replaceItemAt(final, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: final)
            }
            rememberStamp(final)
        } catch {
            try? fm.removeItem(at: staging)
            Settings.d.set("Couldn't write to the sync folder: \(error.localizedDescription)", forKey: "syncError")
        }
    }

    private func writeMeta(_ id: Int, _ dir: URL) {
        guard let m = db.metaDict(id), let key = m["key"] as? String else { return }
        let f = dir.appendingPathComponent(SyncFolder.fileID(key) + ".meta.json")
        // Never overwrite newer info written by another Mac.
        if let data = try? Data(contentsOf: f),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (existing["updated"] as? Double ?? 0) > (m["updated"] as? Double ?? 0) { return }
        if let data = try? JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: f, options: .atomic)
            rememberStamp(f)
        }
    }

    private func importAll(_ dir: URL) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [])) ?? []
        // iCloud may keep files in the cloud only ("Optimize Mac Storage"): ask for them to be downloaded.
        for f in files where f.pathExtension == "icloud" && f.lastPathComponent.hasPrefix(".") {
            let realName = String(f.deletingPathExtension().lastPathComponent.dropFirst())
            try? fm.startDownloadingUbiquitousItem(at: dir.appendingPathComponent(realName))
        }
        var s = stamps
        var affected: [Int] = []
        let visible = files.filter { !$0.lastPathComponent.hasPrefix(".") }

        for f in visible where f.lastPathComponent.hasSuffix(".entries.db") {
            let mod = modDate(f)
            if s[f.lastPathComponent] == mod { continue }
            let local = fm.temporaryDirectory.appendingPathComponent("drivedex-import-\(UUID().uuidString).db")
            defer { try? fm.removeItem(at: local) }
            guard (try? fm.copyItem(at: f, to: local)) != nil else { continue }
            if let id = db.importDrive(from: local.path) {
                affected += db.mainsBackedUpBy(id)
                if db.row("SELECT role FROM drives WHERE id=?", [id])?["role"] as? String == "main" { affected.append(id) }
            }
            s[f.lastPathComponent] = mod
        }

        for f in visible where f.lastPathComponent.hasSuffix(".meta.json") {
            let mod = modDate(f)
            if s[f.lastPathComponent] == mod { continue }
            guard let data = try? Data(contentsOf: f),
                  let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            switch db.applyMeta(m) {
            case .unknownDrive: continue          // its catalog hasn't arrived yet; try again next time
            case .unchanged: break
            case .applied(let ids): affected += ids
            }
            s[f.lastPathComponent] = mod
        }
        for f in visible where f.lastPathComponent.hasSuffix(".history.json") {
            let mod = modDate(f)
            if s[f.lastPathComponent] == mod { continue }
            guard let data = try? Data(contentsOf: f),
                  let h = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let key = h["main"] as? String, let entries = h["entries"] as? [[String: Any]] else { continue }
            if db.row("SELECT id FROM drives WHERE key=?", [key]) == nil { continue }   // drive not here yet
            _ = db.mergeHistory(mainKey: key, entries)
            s[f.lastPathComponent] = mod
        }

        if let f = visible.first(where: { $0.lastPathComponent == "prefs.json" }), s[f.lastPathComponent] != modDate(f) {
            if let data = try? Data(contentsOf: f), let p = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let updated = p["updated"] as? Double, updated > Settings.d.double(forKey: "prefsUpdated") {
                Settings.d.set(p["ignoreVolumes"] as? [String] ?? [], forKey: "ignoreVolumes")
                Settings.d.set(updated, forKey: "prefsUpdated")
            }
            s[f.lastPathComponent] = modDate(f)
        }
        stamps = s
        for id in Set(affected) { recompute(id) }
    }
}
