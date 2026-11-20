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
            return db.drivesList(online: Scanner.onlineMap())

        case "list":
            guard let id = int("drive") else { return [Any]() }
            return db.listFolder(id, str("path"))

        case "search":
            return db.search(q: str("q"), drive: int("drive"), kind: str("kind"))

        case "updateDrive":
            guard let id = int("id") else { return err("missing id") }
            db.run("UPDATE drives SET label=?, notes=? WHERE id=?",
                   [str("label").trimmingCharacters(in: .whitespacesAndNewlines), str("notes"), id])
            return ok

        case "forget":
            guard let id = int("id") else { return err("missing id") }
            db.forget(id)
            return ok

        case "rescan", "reveal":
            guard let id = int("id"),
                  let key = db.row("SELECT key FROM drives WHERE id=?", [id])?["key"] as? String,
                  let vol = Scanner.onlineMap()[key]
            else { return err("That drive isn't connected right now.") }
            if action == "rescan" {
                Scanner.shared.enqueue(vol, force: true)
                return ok
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
            if let v = a["ignoreVolumes"] as? [String] {
                d.set(v.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, forKey: "ignoreVolumes")
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
            "ignoreVolumes": Settings.ignoreVolumes,
            "openAtLogin": status == "enabled",
            "loginStatus": status,
            "catalogPath": Paths.support.path,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        ]
    }
}
