import AppKit
import DiskArbitration
import Foundation
import IOKit
import UserNotifications

struct VolumeInfo {
    var url: URL
    var key: String
    var name: String
    var kind: String      // "drive", "internal", "network"
    var fs: String
    var source: String
    var total: Int?
    var free: Int?
    var isDiskImage: Bool
    var media: String = ""   // "hdd", "ssd", "nas" or "" when unknown
}

private let skipNames: Set<String> = [
    ".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", ".DocumentRevisions-V100",
    ".DS_Store", ".apdisk", ".VolumeIcon.icns", ".com.apple.timemachine.donotpresent",
    "#recycle", "@eaDir", "#snapshot", "@Recycle", "@Recently-Snapshot", ".@__thumb",
    "$RECYCLE.BIN", "System Volume Information", "Thumbs.db", "desktop.ini",
]
private let packageExts: Set<String> = [
    "app", "bundle", "framework", "plugin", "kext", "fcpbundle", "fcpxbundle", "photoslibrary",
    "imovielibrary", "tvlibrary", "musiclibrary", "aplibrary", "logicx", "band", "rtfd", "pages",
    "numbers", "key", "sparsebundle", "cocatalog", "lrdata", "dvdmedia", "xcodeproj", "xcworkspace",
]
private let entryKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
private let entryKeySet = Set(entryKeys)

enum ScanError: Error {
    case disconnected
    case cannotRead(Error)

    var message: String {
        switch self {
        case .disconnected: return "The drive was disconnected during the scan."
        case .cannotRead(let e):
            let ns = e as NSError
            let denied = (ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError)
                || (ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES)))
            return denied ? "macOS blocked access to this drive. Use “Open Privacy Settings” and allow DriveDex."
                          : ns.localizedDescription
        }
    }
}

private final class ScanJob {
    let id: Int, gen: Int, mount: URL, includeHidden: Bool
    var files = 0, dirs = 0, errors = 0
    var batch: [Entry] = []
    var lastProgress = Date()
    init(id: Int, gen: Int, mount: URL, includeHidden: Bool) {
        self.id = id; self.gen = gen; self.mount = mount; self.includeHidden = includeHidden
    }
}

final class Scanner {
    static let shared = Scanner()

    let queue = DispatchQueue(label: "drivedex.scan", qos: .utility)
    lazy var db = DB()                   // only touched on `queue`
    var syncTimer: Timer?
    private let lock = NSLock()
    private var pending = Set<String>()
    private var cancelled = Set<String>()
    private var pendingNew: [String: VolumeInfo] = [:]   // new drives waiting for the user's OK
    private var timer: Timer?

    // MARK: - volumes

    static func volumeInfo(_ url: URL) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeUUIDStringKey, .volumeIsLocalKey, .volumeIsInternalKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey,
            .volumeIsRootFileSystemKey, .volumeURLForRemountingKey,
        ]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        if v.volumeIsRootFileSystem == true { return nil }
        let name = v.volumeName ?? url.lastPathComponent
        var info = VolumeInfo(url: url, key: "", name: name, kind: v.volumeIsInternal == true ? "internal" : "drive",
                              fs: v.volumeLocalizedFormatDescription ?? "", source: "",
                              total: v.volumeTotalCapacity, free: v.volumeAvailableCapacity, isDiskImage: false)
        if v.volumeIsLocal == false {
            var share = url.path
            if let remount = v.volumeURLForRemounting, var c = URLComponents(url: remount, resolvingAgainstBaseURL: false) {
                c.user = nil
                c.password = nil
                share = c.string ?? remount.absoluteString
            }
            info.kind = "network"
            info.media = "nas"
            info.source = share
            info.key = "net:" + share.lowercased()
            return info
        }
        if let session = DASessionCreate(kCFAllocatorDefault),
           let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
           let desc = DADiskCopyDescription(disk) as NSDictionary? {
            let proto = (desc[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let model = (desc[kDADiskDescriptionDeviceModelKey as String] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let media = desc[kDADiskDescriptionMediaNameKey as String] as? String ?? ""
            info.isDiskImage = proto == "Disk Image" || proto == "Virtual Interface" || model.contains("Disk Image")
            info.media = Scanner.mediumType(disk)
            info.source = [model.trimmingCharacters(in: .whitespaces), proto].filter { !$0.isEmpty }.joined(separator: " · ")
            if info.source.isEmpty { info.source = media }
        }
        if let uuid = v.volumeUUIDString { info.key = "uuid:" + uuid } else { info.key = "name:" + name }
        return info
    }

    /// Asks the I/O Registry whether the disk behind a volume is solid state or rotational.
    /// Many USB enclosures don't report this; then "" is returned.
    static func mediumType(_ disk: DADisk) -> String {
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return "" }
        defer { IOObjectRelease(media) }
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard let value = IORegistryEntrySearchCFProperty(media, kIOServicePlane, "Device Characteristics" as CFString,
                                                          kCFAllocatorDefault, options),
              let dict = value as? [String: Any], let type = dict["Medium Type"] as? String else { return "" }
        switch type {
        case "Solid State": return "ssd"
        case "Rotational": return "hdd"
        default: return ""
        }
    }

    /// Volumes under /Volumes that DriveDex should catalog.
    static func eligible(_ url: URL) -> VolumeInfo? {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/Volumes/") else { return nil }
        let folder = url.lastPathComponent
        if folder.hasPrefix(".") { return nil }
        let ignore = Settings.ignoreVolumes
        if ignore.contains(folder) { return nil }
        guard var v = volumeInfo(url) else { return nil }
        // App installers (.dmg with an "Applications" shortcut) are never worth cataloguing.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.appendingPathComponent("Applications").path)) == "/Applications" {
            v.isDiskImage = true
        }
        if v.isDiskImage && Settings.skipDiskImages { return nil }
        if ignore.contains(v.name) { return nil }
        return v
    }

    static func connectedVolumes() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { eligible($0) }
    }

    static func onlineMap() -> [String: VolumeInfo] {
        var m: [String: VolumeInfo] = [:]
        for v in connectedVolumes() { m[v.key] = v }
        return m
    }

    // MARK: - lifecycle

    func start() {
        queue.async {
            self.db.recoverInterruptedScans()
            for id in self.db.mainsNeedingCoverage() { self.recompute(id) }
        }
        startSync()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: nil) { [weak self] n in
            guard let url = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            // Give the drive a moment to settle before reading it.
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if let v = Scanner.eligible(url) { self?.enqueue(v, force: false) }
            }
        }
        nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: nil) { [weak self] n in
            guard let self = self, let url = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            let path = url.standardizedFileURL.path
            self.lock.lock()
            self.cancelled.insert(path)
            self.pendingNew = self.pendingNew.filter { $0.value.url.standardizedFileURL.path != path }
            self.lock.unlock()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.scanAllConnected(force: false)
            self?.checkReminders()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { [weak self] in self?.checkReminders() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in self?.scanAllConnected(force: false) }
    }

    func scanAllConnected(force: Bool) {
        DispatchQueue.global(qos: .utility).async {
            for v in Scanner.connectedVolumes() { self.enqueue(v, force: force) }
        }
    }

    /// New drives that are connected but not catalogued yet because DriveDex is waiting for the user's OK.
    func pendingDrives() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return pendingNew.values.sorted { $0.name < $1.name }.map {
            ["key": $0.key, "name": $0.name, "kind": $0.kind, "total": $0.total ?? 0, "used": ($0.total ?? 0) - ($0.free ?? 0)]
        }
    }

    func approve(_ key: String) {
        lock.lock(); let v = pendingNew.removeValue(forKey: key); lock.unlock()
        if let v = v { enqueue(v, force: true, approved: true) }
    }

    func ignore(_ key: String) {
        lock.lock(); let v = pendingNew.removeValue(forKey: key); lock.unlock()
        guard let v = v else { return }
        var names = Settings.ignoreVolumes
        if !names.contains(v.name) {
            names.append(v.name)
            Settings.d.set(names, forKey: "ignoreVolumes")
            exportPrefs()
        }
    }

    func enqueue(_ v: VolumeInfo, force: Bool, approved: Bool = false) {
        lock.lock()
        if pending.contains(v.key) { lock.unlock(); return }
        pending.insert(v.key)
        lock.unlock()
        queue.async {
            defer { self.lock.lock(); self.pending.remove(v.key); self.lock.unlock() }
            self.scan(v, force: force, approved: approved)
        }
    }

    /// Recompute backup coverage for these main drives (in the background).
    func recomputeCoverage(_ ids: [Int]) {
        guard !ids.isEmpty else { return }
        queue.async { for id in Set(ids) { self.recompute(id) } }
    }

    /// Notify (at most about once a day per backup) when a backup is older than its main drive's reminder interval.
    func checkReminders() {
        queue.async {
            var last = Settings.d.dictionary(forKey: "remindedAt") as? [String: Double] ?? [:]
            let now = Date().timeIntervalSince1970
            for r in self.db.dueReminders() where now - (last[r.key] ?? 0) > 20 * 3600 {
                self.notify("Backup reminder: “\(r.backup)” (backup of \(r.main)) was last updated \(r.days) days ago. Time to connect or swap it.", force: true)
                last[r.key] = now
            }
            Settings.d.set(last, forKey: "remindedAt")
        }
    }

    private func isCancelled(_ mount: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled.contains(mount.standardizedFileURL.path)
    }

    // MARK: - scanning

    private func scan(_ v: VolumeInfo, force: Bool, approved: Bool) {
        if !approved && Settings.askNew && db.row("SELECT id FROM drives WHERE key=?", [v.key]) == nil {
            lock.lock()
            let isNew = pendingNew[v.key] == nil
            pendingNew[v.key] = v
            lock.unlock()
            if isNew { notify("New drive “\(v.name)” connected. Open DriveDex to add it to your catalog.", force: true) }
            return
        }
        let id = db.upsertDrive(v)
        guard let d = db.row("SELECT * FROM drives WHERE id=?", [id]) else { return }
        let lastScan = d["last_scan"] as? Double ?? 0
        let hours = v.kind == "network" ? Settings.periodicRescanHours : Settings.rescanAfterHours
        if !force && Date().timeIntervalSince1970 - lastScan < hours * 3600 { return }

        let oldGen = d["gen"] as? Int ?? 0
        let gen = oldGen + 1
        let labelText = d["label"] as? String ?? ""
        let label = labelText.isEmpty ? v.name : labelText
        lock.lock(); cancelled.remove(v.url.standardizedFileURL.path); lock.unlock()

        let job = ScanJob(id: id, gen: gen, mount: v.url, includeHidden: Settings.includeHidden)
        db.setStatus(id, "scanning", "starting")
        let t0 = Date()
        do {
            let (total, _) = try walk(job, "", v.url, depth: 0)
            flush(job)
            if isCancelled(v.url) || !FileManager.default.fileExists(atPath: v.url.path) { throw ScanError.disconnected }
            let secs = Date().timeIntervalSince(t0)
            let detail = job.errors > 0 ? "\(job.errors) folders couldn't be read" : ""
            db.finishScan(id: id, gen: gen, files: job.files, dirs: job.dirs, bytes: total, seconds: secs, detail: detail)
            let summary = "\(label): \(job.files.formatted()) files, \(job.dirs.formatted()) folders, " +
                ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            notify(oldGen == 0 ? "Catalogued new drive \(summary)" : "Updated \(summary)")
            var mains = db.mainsBackedUpBy(id)
            if db.row("SELECT role FROM drives WHERE id=?", [id])?["role"] as? String == "main" { mains.append(id) }
            for m in Set(mains) { recompute(m) }
            exportToSync([id])
        } catch {
            job.batch.removeAll()
            db.deleteGen(id, gen)
            let msg = (error as? ScanError)?.message ?? error.localizedDescription
            db.setStatus(id, "error", msg)
            notify("Couldn't scan \(label): \(msg)")
        }
    }

    private func flush(_ job: ScanJob) {
        db.insert(job.batch)
        job.batch.removeAll(keepingCapacity: true)
        if Date().timeIntervalSince(job.lastProgress) > 2 {
            job.lastProgress = Date()
            db.setStatus(job.id, "scanning", "\(job.files.formatted()) files, \(job.dirs.formatted()) folders so far")
        }
    }

    /// Returns (total size, number of direct children).
    private func walk(_ job: ScanJob, _ rel: String, _ url: URL, depth: Int) throws -> (Int64, Int) {
        if isCancelled(job.mount) { throw ScanError.disconnected }
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: entryKeys, options: [])
        } catch {
            if rel.isEmpty { throw ScanError.cannotRead(error) }
            job.errors += 1
            return (0, 0)
        }
        var total: Int64 = 0
        var children = 0
        for item in items {
            let name = item.lastPathComponent
            if skipNames.contains(name) || name.hasPrefix("._") || (!job.includeHidden && name.hasPrefix(".")) { continue }
            guard let v = try? item.resourceValues(forKeys: entryKeySet) else { job.errors += 1; continue }
            if v.isSymbolicLink == true { continue }
            children += 1
            var size: Int64 = 0, kind = 0, count = 0
            if v.isDirectory == true {
                if v.isPackage == true || packageExts.contains(item.pathExtension.lowercased()) {
                    size = packageSize(item); kind = 2; job.files += 1
                } else {
                    kind = 1; job.dirs += 1
                    if depth < 200 {
                        (size, count) = try walk(job, rel.isEmpty ? name : rel + "/" + name, item, depth: depth + 1)
                    }
                }
            } else {
                size = Int64(v.fileSize ?? 0); job.files += 1
            }
            total += size
            job.batch.append(Entry(driveID: job.id, gen: job.gen, parent: rel, name: name, kind: kind, size: size,
                                   mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0, items: count))
            if job.batch.count >= 5000 { flush(job) }
        }
        return (total, children)
    }

    private func packageSize(_ url: URL) -> Int64 {
        var t: Int64 = 0
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [],
                                                      errorHandler: { _, _ in true }) else { return 0 }
        for case let u as URL in en {
            t += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return t
    }

    private func notify(_ text: String, force: Bool = false) {
        guard Settings.notify || force else { return }
        let c = UNMutableNotificationContent()
        c.title = "DriveDex"
        c.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
