import Foundation
import SQLite3

private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum Paths {
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DriveDex", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static var db: String { support.appendingPathComponent("catalog.db").path }
}

enum Settings {
    static let d = UserDefaults.standard
    static func registerDefaults() {
        d.register(defaults: [
            "rescanAfterHours": 1.0,
            "periodicRescanHours": 12.0,
            "ignoreVolumes": [String](),
            "includeHidden": false,
            "skipDiskImages": true,
            "notify": true,
        ])
    }
    static var rescanAfterHours: Double { d.double(forKey: "rescanAfterHours") }
    static var periodicRescanHours: Double { max(1, d.double(forKey: "periodicRescanHours")) }
    static var ignoreVolumes: [String] { d.stringArray(forKey: "ignoreVolumes") ?? [] }
    static var includeHidden: Bool { d.bool(forKey: "includeHidden") }
    static var skipDiskImages: Bool { d.bool(forKey: "skipDiskImages") }
    static var notify: Bool { d.bool(forKey: "notify") }
}

struct Entry {
    var driveID: Int, gen: Int, parent: String, name: String, kind: Int, size: Int64, mtime: Double, items: Int
}

/// Thin SQLite wrapper. Each instance must be used from one queue only.
final class DB {
    private var h: OpaquePointer?
    private(set) var hasFTS = false

    init() {
        sqlite3_open_v2(Paths.db, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        sqlite3_busy_timeout(h, 60000)
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("""
        CREATE TABLE IF NOT EXISTS drives(
            id INTEGER PRIMARY KEY, key TEXT UNIQUE, name TEXT, label TEXT DEFAULT '', notes TEXT DEFAULT '',
            kind TEXT, mount_path TEXT, source TEXT, fs TEXT,
            total_bytes INTEGER, free_bytes INTEGER, used_bytes INTEGER,
            file_count INTEGER DEFAULT 0, dir_count INTEGER DEFAULT 0, catalog_bytes INTEGER DEFAULT 0,
            gen INTEGER DEFAULT 0, first_seen REAL, last_seen REAL, last_scan REAL, scan_seconds REAL,
            status TEXT DEFAULT 'new', status_detail TEXT DEFAULT '');
        CREATE TABLE IF NOT EXISTS entries(
            id INTEGER PRIMARY KEY, drive_id INTEGER, gen INTEGER, parent TEXT, name TEXT,
            is_dir INTEGER, size INTEGER, mtime REAL, items INTEGER);
        CREATE INDEX IF NOT EXISTS entries_parent ON entries(drive_id, gen, parent);
        """)
        hasFTS = exec("CREATE VIRTUAL TABLE IF NOT EXISTS names USING fts5(name, tokenize='trigram')")
        if !hasFTS { exec("CREATE INDEX IF NOT EXISTS entries_name ON entries(name)") }
    }

    deinit { sqlite3_close(h) }

    @discardableResult
    func exec(_ sql: String) -> Bool {
        let rc = sqlite3_exec(h, sql, nil, nil, nil)
        if rc != SQLITE_OK { NSLog("DriveDex SQL error: %@ — %@", String(cString: sqlite3_errmsg(h)), sql) }
        return rc == SQLITE_OK
    }

    private func prepare(_ sql: String, _ args: [Any?]) -> OpaquePointer? {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &s, nil) == SQLITE_OK else {
            NSLog("DriveDex SQL error: %@ — %@", String(cString: sqlite3_errmsg(h)), sql)
            return nil
        }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            guard let a = arg else { sqlite3_bind_null(s, idx); continue }
            switch a {
            case let v as Int: sqlite3_bind_int64(s, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(s, idx, v)
            case let v as Double: sqlite3_bind_double(s, idx, v)
            case let v as Bool: sqlite3_bind_int64(s, idx, v ? 1 : 0)
            case let v as String: sqlite3_bind_text(s, idx, v, -1, TRANSIENT)
            default: sqlite3_bind_null(s, idx)
            }
        }
        return s
    }

    @discardableResult
    func run(_ sql: String, _ args: [Any?] = []) -> Int {
        guard let s = prepare(sql, args) else { return 0 }
        sqlite3_step(s)
        sqlite3_finalize(s)
        return Int(sqlite3_changes(h))
    }

    var lastID: Int { Int(sqlite3_last_insert_rowid(h)) }

    func rows(_ sql: String, _ args: [Any?] = []) -> [[String: Any]] {
        guard let s = prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(s) }
        var out: [[String: Any]] = []
        let n = sqlite3_column_count(s)
        while sqlite3_step(s) == SQLITE_ROW {
            var r: [String: Any] = [:]
            for i in 0..<n {
                let name = String(cString: sqlite3_column_name(s, i))
                switch sqlite3_column_type(s, i) {
                case SQLITE_INTEGER: r[name] = Int(sqlite3_column_int64(s, i))
                case SQLITE_FLOAT: r[name] = sqlite3_column_double(s, i)
                case SQLITE_TEXT: r[name] = String(cString: sqlite3_column_text(s, i))
                default: r[name] = NSNull()
                }
            }
            out.append(r)
        }
        return out
    }

    func row(_ sql: String, _ args: [Any?] = []) -> [String: Any]? { rows(sql, args).first }

    func insert(_ batch: [Entry]) {
        guard !batch.isEmpty else { return }
        exec("BEGIN")
        if let s = prepare("INSERT INTO entries(drive_id,gen,parent,name,is_dir,size,mtime,items) VALUES(?,?,?,?,?,?,?,?)", []) {
            for e in batch {
                sqlite3_reset(s)
                sqlite3_bind_int64(s, 1, Int64(e.driveID))
                sqlite3_bind_int64(s, 2, Int64(e.gen))
                sqlite3_bind_text(s, 3, e.parent, -1, TRANSIENT)
                sqlite3_bind_text(s, 4, e.name, -1, TRANSIENT)
                sqlite3_bind_int64(s, 5, Int64(e.kind))
                sqlite3_bind_int64(s, 6, e.size)
                sqlite3_bind_double(s, 7, e.mtime)
                sqlite3_bind_int64(s, 8, Int64(e.items))
                sqlite3_step(s)
            }
            sqlite3_finalize(s)
        }
        exec("COMMIT")
    }

    // MARK: - drives

    func upsertDrive(_ v: VolumeInfo) -> Int {
        let now = Date().timeIntervalSince1970
        var used: Int? = nil
        if let t = v.total, let f = v.free { used = t - f }
        if let r = row("SELECT id FROM drives WHERE key=?", [v.key]), let id = r["id"] as? Int {
            run("""
                UPDATE drives SET name=?, mount_path=?, kind=?, source=?, fs=?, total_bytes=?, free_bytes=?,
                used_bytes=?, last_seen=? WHERE id=?
                """, [v.name, v.url.path, v.kind, v.source, v.fs, v.total, v.free, used, now, id])
            return id
        }
        run("""
            INSERT INTO drives(key,name,mount_path,kind,source,fs,total_bytes,free_bytes,used_bytes,first_seen,last_seen)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            """, [v.key, v.name, v.url.path, v.kind, v.source, v.fs, v.total, v.free, used, now, now])
        return lastID
    }

    func setStatus(_ id: Int, _ status: String, _ detail: String) {
        run("UPDATE drives SET status=?, status_detail=? WHERE id=?", [status, detail, id])
    }

    func deleteGen(_ id: Int, _ gen: Int) {
        if hasFTS { run("DELETE FROM names WHERE rowid IN (SELECT id FROM entries WHERE drive_id=? AND gen=?)", [id, gen]) }
        run("DELETE FROM entries WHERE drive_id=? AND gen=?", [id, gen])
    }

    func finishScan(id: Int, gen: Int, files: Int, dirs: Int, bytes: Int64, seconds: Double, detail: String) {
        if hasFTS {
            run("INSERT INTO names(rowid, name) SELECT id, name FROM entries WHERE drive_id=? AND gen=?", [id, gen])
        }
        run("""
            UPDATE drives SET gen=?, last_scan=?, scan_seconds=?, file_count=?, dir_count=?, catalog_bytes=?,
            status='ok', status_detail=? WHERE id=?
            """, [gen, Date().timeIntervalSince1970, seconds, files, dirs, bytes, detail, id])
        if hasFTS { run("DELETE FROM names WHERE rowid IN (SELECT id FROM entries WHERE drive_id=? AND gen<>?)", [id, gen]) }
        run("DELETE FROM entries WHERE drive_id=? AND gen<>?", [id, gen])
    }

    /// Clean up after a crash / quit in the middle of a scan.
    func recoverInterruptedScans() {
        run("DELETE FROM entries WHERE gen > (SELECT gen FROM drives WHERE drives.id = entries.drive_id)")
        run("UPDATE drives SET status='ok', status_detail='' WHERE status='scanning'")
    }

    func forget(_ id: Int) {
        if hasFTS { run("DELETE FROM names WHERE rowid IN (SELECT id FROM entries WHERE drive_id=?)", [id]) }
        run("DELETE FROM entries WHERE drive_id=?", [id])
        run("DELETE FROM drives WHERE id=?", [id])
    }

    func drivesList(online: [String: VolumeInfo]) -> [[String: Any]] {
        rows("SELECT * FROM drives ORDER BY COALESCE(NULLIF(label,''), name) COLLATE NOCASE").map { r in
            var d = r
            let key = r["key"] as? String ?? ""
            let label = r["label"] as? String ?? ""
            d["online"] = online[key] != nil
            if let v = online[key] { d["mount_path"] = v.url.path }
            d["display"] = label.isEmpty ? (r["name"] as? String ?? "") : label
            return d
        }
    }

    func listFolder(_ id: Int, _ path: String) -> [[String: Any]] {
        guard let d = row("SELECT gen FROM drives WHERE id=?", [id]), let gen = d["gen"] as? Int else { return [] }
        return rows("""
            SELECT id,name,is_dir,size,mtime,items FROM entries WHERE drive_id=? AND gen=? AND parent=?
            ORDER BY (is_dir=1) DESC, name COLLATE NOCASE
            """, [id, gen, path])
    }

    func search(q: String, drive: Int?, kind: String, limit: Int = 500) -> [String: Any] {
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if terms.isEmpty { return ["results": [Any](), "per_drive": [Any]()] }
        var wh: [String] = []
        var args: [Any?] = []
        var from = "entries e"
        let fts = hasFTS ? terms.filter { $0.count >= 3 } : []
        if !fts.isEmpty {
            from = "names JOIN entries e ON e.id = names.rowid"
            wh.append("names MATCH ?")
            args.append(fts.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " "))
        }
        for t in terms where !fts.contains(t) {
            wh.append("e.name LIKE ? ESCAPE '\\'")
            let esc = t.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            args.append("%" + esc + "%")
        }
        if let drive = drive { wh.append("e.drive_id = ?"); args.append(drive) }
        if kind == "folders" { wh.append("e.is_dir = 1") } else if kind == "files" { wh.append("e.is_dir <> 1") }
        let base = "FROM \(from) JOIN drives d ON d.id = e.drive_id AND d.gen = e.gen WHERE " + wh.joined(separator: " AND ")
        let results = rows("""
            SELECT e.id, e.drive_id, e.parent, e.name, e.is_dir, e.size, e.mtime, e.items,
                   COALESCE(NULLIF(d.label,''), d.name) AS drive \(base)
            ORDER BY (lower(e.name) = lower(?)) DESC, e.is_dir = 1 DESC, e.name COLLATE NOCASE LIMIT ?
            """, args + [query, limit])
        let perDrive = rows("""
            SELECT e.drive_id, COALESCE(NULLIF(d.label,''), d.name) AS drive, COUNT(*) AS n \(base)
            GROUP BY e.drive_id ORDER BY n DESC
            """, args)
        return ["results": results, "per_drive": perDrive]
    }
}
