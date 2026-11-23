import AppKit
import Foundation

/// In-app updates from the GitHub "latest" release. The app downloads the update itself (not through a
/// browser), so macOS doesn't flag it as downloaded from the internet and doesn't ask for "Open Anyway" again.
enum Updater {
    static let releaseAPI = URL(string: "https://api.github.com/repos/marcialsommer/drivedexloo/releases/latest")!

    static var currentBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }
    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    struct Release { let build: Int; let version: String; let zip: URL }

    enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    /// Blocking network call; never run on the main thread.
    static func fetchLatest() throws -> Release? {
        var req = URLRequest(url: releaseAPI, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("DriveDex-Updater", forHTTPHeaderField: "User-Agent")
        let data = try fetch(req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let name = json["name"] as? String ?? ""
        guard let build = firstMatch(#"build (\d+)"#, in: name).flatMap(Int.init),
              let assets = json["assets"] as? [[String: Any]],
              let zipURL = assets.first(where: { $0["name"] as? String == "DriveDex.zip" })?["browser_download_url"] as? String,
              let zip = URL(string: zipURL) else { return nil }
        let version = firstMatch(#"DriveDex ([0-9][0-9.]*)"#, in: name) ?? "build \(build)"
        return Release(build: build, version: version, zip: zip)
    }

    /// Checks GitHub and remembers the result. Returns the status shown in the app.
    @discardableResult
    static func check() -> [String: Any] {
        do {
            if let r = try fetchLatest() {
                Settings.d.set(r.build, forKey: "updateBuild")
                Settings.d.set(r.version, forKey: "updateVersion")
                Settings.d.set(r.zip.absoluteString, forKey: "updateZip")
            }
            Settings.d.set(Date().timeIntervalSince1970, forKey: "updateChecked")
            Settings.d.set("", forKey: "updateError")
        } catch {
            Settings.d.set("Couldn't check for updates: \(error.localizedDescription)", forKey: "updateError")
        }
        return status()
    }

    static func status() -> [String: Any] {
        let b = Settings.d.integer(forKey: "updateBuild")
        return [
            "available": b > currentBuild && currentBuild > 0,
            "version": Settings.d.string(forKey: "updateVersion") ?? "",
            "current": currentVersion,
            "currentBuild": currentBuild,
            "checked": Settings.d.double(forKey: "updateChecked"),
            "error": Settings.d.string(forKey: "updateError") ?? "",
        ]
    }

    /// Daily background check; notifies once per new build.
    static func checkInBackgroundIfDue(notify: (String) -> Void) {
        let last = Settings.d.double(forKey: "updateChecked")
        guard Date().timeIntervalSince1970 - last > 20 * 3600 else { return }
        let s = check()
        let b = Settings.d.integer(forKey: "updateBuild")
        if s["available"] as? Bool == true && Settings.d.integer(forKey: "updateNotified") != b {
            Settings.d.set(b, forKey: "updateNotified")
            notify("DriveDex \(s["version"] as? String ?? "") is available. Open DriveDex and click Install & Relaunch.")
        }
    }

    /// Downloads the latest build, swaps it in place of the running app and relaunches. Blocking.
    static func install() throws {
        guard let zipString = Settings.d.string(forKey: "updateZip"), let zip = URL(string: zipString) else {
            throw UpdateError.message("No update found. Click Check for Updates first.")
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("DriveDex-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let zipFile = work.appendingPathComponent("DriveDex.zip")
        try fetch(URLRequest(url: zip, timeoutInterval: 120)).write(to: zipFile)

        let unzip = work.appendingPathComponent("unzipped", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", zipFile.path, unzip.path])
        let newApp = unzip.appendingPathComponent("DriveDex.app")
        guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError.message("The downloaded update doesn't look like DriveDex.")
        }
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        let dest = URL(fileURLWithPath: Bundle.main.bundlePath)
        let old = work.appendingPathComponent("DriveDex-old.app")
        do {
            try fm.moveItem(at: dest, to: old)
        } catch {
            throw UpdateError.message("DriveDex couldn't replace itself in \(dest.deletingLastPathComponent().path). \(error.localizedDescription)")
        }
        do {
            try fm.moveItem(at: newApp, to: dest)
        } catch {
            try? fm.moveItem(at: old, to: dest)   // put the old version back
            throw UpdateError.message("Installing the update failed: \(error.localizedDescription)")
        }
        // Relaunch the new version once this one has quit.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1.5; /usr/bin/open \"$0\"", dest.path]
        try p.run()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    // MARK: - helpers

    private static func fetch(_ req: URLRequest) throws -> Data {
        final class Box: @unchecked Sendable { var result: Result<Data, Error> = .failure(UpdateError.message("No response")) }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { box.result = .failure(err) }
            else if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                box.result = .failure(UpdateError.message("Server answered \(http.statusCode)"))
            } else { box.result = .success(data ?? Data()) }
            sem.signal()
        }.resume()
        sem.wait()
        return try box.result.get()
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw UpdateError.message("\(tool) failed (\(p.terminationStatus))") }
    }

    private static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}
