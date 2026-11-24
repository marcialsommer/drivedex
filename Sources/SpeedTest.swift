import Foundation

/// Disk speed test for a connected drive (on the user's request only).
/// Read: reads the largest existing files from the catalog for up to ~15 s (caching off). Nothing is written.
/// Write (optional): writes a hidden temporary file of up to 2 GB for up to ~15 s, flushes it to the disk, deletes it.
/// One test at a time; results are kept per drive in `drives.speed_json` (last 20, synced with the drive's info).
final class SpeedTest {
    static let shared = SpeedTest()
    private let queue = DispatchQueue(label: "drivedex.speed", qos: .userInitiated)
    private lazy var db = DB()                       // only touched on `queue`
    private let lock = NSLock()
    private var live: [Int: [String: Any]] = [:]     // drive id -> progress

    func state() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: Any] = [:]
        for (k, v) in live { out[String(k)] = v }
        return out
    }

    private func set(_ id: Int, _ v: [String: Any]) { lock.lock(); live[id, default: [:]].merge(v) { _, n in n }; lock.unlock() }

    func start(id: Int, write: Bool, note: String = "") -> String? {
        lock.lock()
        if !live.isEmpty { lock.unlock(); return "A speed test is already running." }
        live[id] = ["phase": "starting", "write": write]
        lock.unlock()
        queue.async { self.run(id: id, write: write, note: note) }
        return nil
    }

    private struct Fail: Error { let message: String }

    private func run(id: Int, write: Bool, note: String) {
        defer { lock.lock(); live.removeValue(forKey: id); lock.unlock() }
        guard let key = db.driveKey(id), let v = Scanner.onlineMap()[key] else { save(id, ["error": "The drive isn't connected."]); return }
        var result: [String: Any] = ["at": Date().timeIntervalSince1970, "mac": SyncFolder.machine]
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { result["note"] = String(n.prefix(120)) }      // how it was connected (cable, hub…)
        do {
            set(id, ["phase": "read"])
            let (rb, rs) = try readTest(id: id, mount: v.url)
            result["read_mbs"] = rs > 0 ? Double(rb) / rs / 1_000_000 : 0
            result["read_mb"] = rb / 1_000_000
            if write {
                set(id, ["phase": "write"])
                let (wb, ws) = try writeTest(id: id, mount: v.url, free: Int64(v.free ?? 0))
                result["write_mbs"] = ws > 0 ? Double(wb) / ws / 1_000_000 : 0
                result["write_mb"] = wb / 1_000_000
            }
        } catch let f as Fail {
            result["error"] = f.message
        } catch {
            result["error"] = error.localizedDescription
        }
        save(id, result)
    }

    private func ejecting(_ mount: URL) -> Bool {
        Scanner.shared.isEjecting(mount) || !FileManager.default.fileExists(atPath: mount.path)
    }

    /// Reads the drive's largest files (from the catalog) straight from the disk.
    private func readTest(id: Int, mount: URL) throws -> (Int64, Double) {
        guard let gen = db.row("SELECT gen FROM drives WHERE id=?", [id])?["gen"] as? Int else { throw Fail(message: "The drive hasn't been catalogued yet.") }
        let rows = db.rows("SELECT parent, name, size FROM entries WHERE drive_id=? AND gen=? AND is_dir = 0 AND size >= 20000000 ORDER BY size DESC LIMIT 40", [id, gen])
        guard !rows.isEmpty else { throw Fail(message: "No large files on this drive to measure reading with.") }
        let size = 8 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buf.deallocate() }
        let t0 = Date()
        var total: Int64 = 0
        outer: for r in rows {
            let parent = r["parent"] as? String ?? "", name = r["name"] as? String ?? ""
            let url = (parent.isEmpty ? mount : mount.appendingPathComponent(parent, isDirectory: true)).appendingPathComponent(name)
            let fd = open(url.path, O_RDONLY)
            if fd < 0 { continue }
            _ = fcntl(fd, F_NOCACHE, 1)
            defer { close(fd) }
            while true {
                let n = read(fd, buf, size)
                if n <= 0 { break }
                total += Int64(n)
                let el = Date().timeIntervalSince(t0)
                set(id, ["phase": "read", "seconds": el, "bytes": total])
                if ejecting(mount) { throw Fail(message: "Stopped: the drive was ejected.") }
                if el >= 15 || total >= 6_000_000_000 { break outer }
            }
        }
        let secs = Date().timeIntervalSince(t0)
        guard total >= 50_000_000 else { throw Fail(message: "Couldn't read enough data to measure (the files may have moved since the last scan).") }
        return (total, secs)
    }

    /// Writes a temporary file at the top of the drive, flushes it to the disk and deletes it.
    private func writeTest(id: Int, mount: URL, free: Int64) throws -> (Int64, Double) {
        let target: Int64 = 2_000_000_000
        guard free > target + 5_000_000_000 else { throw Fail(message: "Not enough free space for the write test (it needs about 7 GB free).") }
        let url = mount.appendingPathComponent(".DriveDex-speedtest-\(UUID().uuidString).tmp")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw Fail(message: "DriveDex couldn't write to this drive (\(String(cString: strerror(errno)))).") }
        defer { close(fd); unlink(url.path) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let size = 8 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buf.deallocate() }
        // Pseudo-random data, so drives that compress can't cheat.
        var x: UInt64 = 0x9E37_79B9_7F4A_7C15
        let words = buf.bindMemory(to: UInt64.self, capacity: size / 8)
        for i in 0..<(size / 8) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; words[i] = x }
        let t0 = Date()
        var total: Int64 = 0
        while total < target {
            let n = write(fd, buf, size)
            if n <= 0 { throw Fail(message: "Writing stopped: \(String(cString: strerror(errno))).") }
            total += Int64(n)
            let el = Date().timeIntervalSince(t0)
            set(id, ["phase": "write", "seconds": el, "bytes": total])
            if ejecting(mount) { throw Fail(message: "Stopped: the drive was ejected.") }
            if el >= 15 { break }
        }
        _ = fcntl(fd, F_FULLFSYNC)      // make sure it's really on the disk before stopping the clock
        return (total, Date().timeIntervalSince(t0))
    }

    private func save(_ id: Int, _ r: [String: Any]) {
        var list: [[String: Any]] = []
        if let s = db.row("SELECT speed_json FROM drives WHERE id=?", [id])?["speed_json"] as? String,
           let d = s.data(using: .utf8), let a = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] { list = a }
        list.insert(r, at: 0)
        if let data = try? JSONSerialization.data(withJSONObject: Array(list.prefix(20))), let json = String(data: data, encoding: .utf8) {
            db.run("UPDATE drives SET speed_json=? WHERE id=?", [json, id])
            db.touchMeta([id]); Scanner.shared.exportMeta([id])
        }
    }
}
