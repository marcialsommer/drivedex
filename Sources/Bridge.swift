import AppKit
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

        case "approveDrive":
            Scanner.shared.approve(str("key"))
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
