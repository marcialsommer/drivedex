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
            "askNew": true,
        ])
    }
    static var rescanAfterHours: Double { d.double(forKey: "rescanAfterHours") }
    static var periodicRescanHours: Double { max(1, d.double(forKey: "periodicRescanHours")) }
    static var ignoreVolumes: [String] { d.stringArray(forKey: "ignoreVolumes") ?? [] }
    static var includeHidden: Bool { d.bool(forKey: "includeHidden") }
    static var skipDiskImages: Bool { d.bool(forKey: "skipDiskImages") }
    static var notify: Bool { d.bool(forKey: "notify") }
    static var askNew: Bool { d.bool(forKey: "askNew") }
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
        // v1.1: drive roles + backup coverage
        addColumn("drives", "role", "TEXT DEFAULT ''")
        for c in ["cov_files", "cov_none", "cov_one", "cov_two", "cov_none_bytes"] { addColumn("drives", c, "INTEGER") }
        addColumn("drives", "cov_state", "TEXT DEFAULT ''")
        addColumn("entries", "copies", "INTEGER")
        addColumn("drives", "meta_updated", "REAL")
        exec("CREATE TABLE IF NOT EXISTS backups(main_id INTEGER, backup_id INTEGER, PRIMARY KEY(main_id, backup_id))")
        exec("CREATE TABLE IF NOT EXISTS excluded(drive_id INTEGER, path TEXT, PRIMARY KEY(drive_id, path))")
        addColumn("drives", "cov_excluded", "INTEGER")
        // v1.4: folder backup locations, per-backup status, history, reminders
        addColumn("backups", "backup_path", "TEXT DEFAULT ''")
        for c in ["cov_n", "cov_have", "cov_missing_bytes"] { addColumn("backups", c, "INTEGER") }
        exec("""
            CREATE TABLE IF NOT EXISTS backup_history(
                id INTEGER PRIMARY KEY, main_id INTEGER, backup_id INTEGER, at REAL,
                n INTEGER, have INTEGER, missing_bytes INTEGER, main_scan REAL, backup_scan REAL);
            CREATE INDEX IF NOT EXISTS backup_history_pair ON backup_history(main_id, backup_id, at);
            """)
        addColumn("drives", "remind_days", "INTEGER DEFAULT 0")
        // v1.5: drive type (auto-detected + user override)
        addColumn("drives", "media", "TEXT DEFAULT ''")
        addColumn("drives", "media_user", "TEXT DEFAULT ''")
        // v1.6: backup sets (a backup split across several drives/folders)
        addColumn("backups", "grp", "TEXT DEFAULT ''")
        addColumn("backup_history", "grp", "TEXT")
        addColumn("backup_history", "label", "TEXT")
        exec("CREATE INDEX IF NOT EXISTS entries_name_size ON entries(name, size)")
        hasFTS = exec("CREATE VIRTUAL TABLE IF NOT EXISTS names USING fts5(name, tokenize='trigram')")
        if !hasFTS { exec("CREATE INDEX IF NOT EXISTS entries_name ON entries(name)") }
    }

    deinit { sqlite3_close(h) }

    private func addColumn(_ table: String, _ column: String, _ type: String) {
        let cols = rows("PRAGMA table_info(\(table))").compactMap { $0["name"] as? String }
        if !cols.contains(column) { exec("ALTER TABLE \(table) ADD COLUMN \(column) \(type)") }
    }

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
                used_bytes=?, last_seen=?, media=CASE WHEN ?='' THEN media ELSE ? END WHERE id=?
                """, [v.name, v.url.path, v.kind, v.source, v.fs, v.total, v.free, used, now, v.media, v.media, id])
            return id
        }
        run("""
            INSERT INTO drives(key,name,mount_path,kind,source,fs,total_bytes,free_bytes,used_bytes,first_seen,last_seen,media)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            """, [v.key, v.name, v.url.path, v.kind, v.source, v.fs, v.total, v.free, used, now, now, v.media])
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
        run("DELETE FROM backups WHERE main_id=? OR backup_id=?", [id, id])
        run("DELETE FROM excluded WHERE drive_id=?", [id])
        run("DELETE FROM backup_history WHERE main_id=? OR backup_id=?", [id, id])
        if hasFTS { run("DELETE FROM names WHERE rowid IN (SELECT id FROM entries WHERE drive_id=?)", [id]) }
        run("DELETE FROM entries WHERE drive_id=?", [id])
        run("DELETE FROM drives WHERE id=?", [id])
    }

    func drivesList(online: [String: VolumeInfo]) -> [[String: Any]] {
        var backupOf: [Int: [Int]] = [:], backedUpBy: [Int: [Int]] = [:], excl: [Int: [String]] = [:]
        for r in rows("SELECT drive_id, path FROM excluded ORDER BY path") {
            if let id = r["drive_id"] as? Int, let p = r["path"] as? String { excl[id, default: []].append(p) }
        }
        var folderBackups: [Int: [[String: Any]]] = [:]
        for r in rows("SELECT main_id, backup_id, COALESCE(backup_path,'') AS path FROM backups") {
            guard let m = r["main_id"] as? Int, let b = r["backup_id"] as? Int else { continue }
            let path = r["path"] as? String ?? ""
            if path.isEmpty { backupOf[b, default: []].append(m) }
            else { folderBackups[b, default: []].append(["main": m, "path": path]) }
            backedUpBy[m, default: []].append(b)
        }
        return rows("SELECT * FROM drives ORDER BY COALESCE(NULLIF(label,''), name) COLLATE NOCASE").map { r in
            var d = r
            let key = r["key"] as? String ?? ""
            let label = r["label"] as? String ?? ""
            d["online"] = online[key] != nil
            if let v = online[key] { d["mount_path"] = v.url.path }
            d["display"] = label.isEmpty ? (r["name"] as? String ?? "") : label
            let mu = r["media_user"] as? String ?? "", ma = r["media"] as? String ?? ""
            d["type"] = !mu.isEmpty ? mu : (!ma.isEmpty ? ma : ((r["kind"] as? String) == "network" ? "nas" : ""))
            d["type_auto"] = mu.isEmpty
            let id = r["id"] as? Int ?? -1
            d["backup_of"] = backupOf[id] ?? []
            d["backed_up_by"] = backedUpBy[id] ?? []
            d["excluded"] = excl[id] ?? []
            d["folder_backups"] = folderBackups[id] ?? []
            if !(backedUpBy[id] ?? []).isEmpty { d["backup_status"] = backupStatus(id) }
            return d
        }
    }

    func listFolder(_ id: Int, _ path: String) -> [[String: Any]] {
        guard let d = row("SELECT gen FROM drives WHERE id=?", [id]), let gen = d["gen"] as? Int else { return [] }
        return rows("""
            SELECT id,name,is_dir,size,mtime,items,copies FROM entries WHERE drive_id=? AND gen=? AND parent=?
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

    // MARK: - backups

    func mainsBackedUpBy(_ id: Int) -> [Int] {
        rows("SELECT main_id FROM backups WHERE backup_id=?", [id]).compactMap { $0["main_id"] as? Int }
    }

    /// Returns the main drives whose coverage must be recomputed.
    func setRole(_ id: Int, _ role: String) -> [Int] {
        var affected: [Int] = []
        if role != "backup" {
            affected += rows("SELECT main_id FROM backups WHERE backup_id=? AND COALESCE(backup_path,'')=''", [id])
                .compactMap { $0["main_id"] as? Int }
            run("DELETE FROM backups WHERE backup_id=? AND COALESCE(backup_path,'')=''", [id])
        }
        if role == "main" {
            affected.append(id)
        } else {
            run("DELETE FROM backups WHERE main_id=?", [id])
            clearCoverage(id)
        }
        run("UPDATE drives SET role=? WHERE id=?", [role, id])
        return affected
    }

    /// Marks `backupID` as a backup of exactly `mains`. Returns the mains to recompute.
    func setBackupOf(_ backupID: Int, _ mains: [Int]) -> [Int] {
        var keepSet: [Int: String] = [:]
        let oldRows = rows("SELECT main_id, COALESCE(grp,'') AS grp FROM backups WHERE backup_id=? AND COALESCE(backup_path,'')=''", [backupID])
        for r in oldRows { if let m = r["main_id"] as? Int { keepSet[m] = r["grp"] as? String ?? "" } }
        let old = oldRows.compactMap { $0["main_id"] as? Int }
        run("DELETE FROM backups WHERE backup_id=? AND COALESCE(backup_path,'')=''", [backupID])
        run("DELETE FROM backups WHERE main_id=?", [backupID])
        clearCoverage(backupID)
        run("UPDATE drives SET role='backup' WHERE id=?", [backupID])
        for m in mains where m != backupID {
            run("INSERT OR REPLACE INTO backups(main_id, backup_id, backup_path, grp) VALUES(?,?,'',?)", [m, backupID, keepSet[m] ?? ""])
            run("UPDATE drives SET role='main' WHERE id=?", [m])
        }
        return Array(Set(old + mains))
    }

    /// Use a folder on `driveID` as the backup location of `mainID` (on == false removes it).
    func setFolderBackup(driveID: Int, path: String, mainID: Int, on: Bool) {
        if on {
            run("INSERT OR REPLACE INTO backups(main_id, backup_id, backup_path) VALUES(?,?,?)", [mainID, driveID, path])
            run("UPDATE drives SET role='main' WHERE id=?", [mainID])
        } else {
            run("DELETE FROM backups WHERE main_id=? AND backup_id=? AND backup_path=?", [mainID, driveID, path])
        }
    }

    /// Identifies a backup set: locations sharing a `grp` belong together; otherwise each location is its own set.
    /// Built from drive keys so it means the same thing on every Mac.
    static func setKey(_ b: [String: Any]) -> String {
        let g = b["grp"] as? String ?? ""
        return g.isEmpty ? "k:" + (b["key"] as? String ?? "") : "g:" + g
    }

    private func sqlQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }

    /// Combine backup locations of a main drive into one set (or split them apart with `on == false`).
    /// Returns the backup drive ids whose shared info changed.
    func setBackupSet(mainID: Int, backupIDs: [Int], on: Bool) -> [Int] {
        if on {
            // Reuse an existing set name if one of them already has one.
            var g = ""
            for b in backupIDs {
                if let x = row("SELECT grp FROM backups WHERE main_id=? AND backup_id=?", [mainID, b])?["grp"] as? String, !x.isEmpty { g = x; break }
            }
            if g.isEmpty { g = UUID().uuidString.lowercased().prefix(8).description }
            for b in backupIDs { run("UPDATE backups SET grp=? WHERE main_id=? AND backup_id=?", [g, mainID, b]) }
        } else {
            for b in backupIDs { run("UPDATE backups SET grp='' WHERE main_id=? AND backup_id=?", [mainID, b]) }
        }
        return backupIDs
    }

    /// SQL condition matching rows `b` of entries inside one backup location (whole drive or a folder).
    private func scopeSQL(_ bk: [String: Any]) -> String {
        let id = bk["id"] as? Int ?? -1, gen = bk["gen"] as? Int ?? -1
        let path = bk["path"] as? String ?? ""
        if path.isEmpty { return "(b.drive_id=\(id) AND b.gen=\(gen))" }
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
        return "(b.drive_id=\(id) AND b.gen=\(gen) AND (b.parent=\(q(path)) OR (b.parent >= \(q(path + "/")) AND b.parent < \(q(path + "0")))))"
    }

    /// Status of each backup set of a main drive.
    func backupStatus(_ mainID: Int) -> [[String: Any]] {
        let rs = rows("""
            SELECT b.backup_id AS id, COALESCE(b.backup_path,'') AS path, COALESCE(b.grp,'') AS grp, d.key AS key,
                   b.cov_n AS n, b.cov_have AS have, b.cov_missing_bytes AS missing_bytes, d.last_scan AS backup_scan
            FROM backups b JOIN drives d ON d.id = b.backup_id WHERE b.main_id=?
            ORDER BY COALESCE(NULLIF(d.label,''), d.name) COLLATE NOCASE
            """, [mainID])
        var order: [String] = []
        var sets: [String: [[String: Any]]] = [:]
        for r in rs {
            let k = Self.setKey(r)
            if sets[k] == nil { order.append(k) }
            sets[k, default: []].append(r)
        }
        return order.map { k in
            let m = sets[k] ?? []
            let first = m.first ?? [:]
            let lastSync = row("""
                SELECT MAX(backup_scan) AS t FROM backup_history WHERE main_id=? AND n > 0 AND have = n
                AND COALESCE(grp, 'k:'||(SELECT key FROM drives WHERE id=backup_id))=?
                """, [mainID, k])?["t"] ?? NSNull()
            return [
                "set": k, "id": first["id"] ?? NSNull(), "path": first["path"] ?? "",
                "members": m.map { ["id": $0["id"] ?? NSNull(), "path": $0["path"] ?? "", "backup_scan": $0["backup_scan"] ?? NSNull()] },
                "n": first["n"] ?? NSNull(), "have": first["have"] ?? NSNull(), "missing_bytes": first["missing_bytes"] ?? NSNull(),
                "backup_scan": m.compactMap({ $0["backup_scan"] as? Double }).min().map { $0 as Any } ?? NSNull(),
                "last_in_sync": lastSync,
            ]
        }
    }

    func history(_ mainID: Int, limit: Int = 60) -> [[String: Any]] {
        rows("""
            SELECT h.backup_id, COALESCE(h.label, NULLIF(d.label,''), d.name) AS backup, h.at, h.n, h.have, h.missing_bytes,
                   h.main_scan, h.backup_scan
            FROM backup_history h LEFT JOIN drives d ON d.id = h.backup_id
            WHERE h.main_id=? ORDER BY h.at DESC LIMIT ?
            """, [mainID, limit])
    }

    /// Backups older than their main drive's reminder interval.
    func dueReminders() -> [(main: String, backup: String, days: Int, key: String)] {
        let now = Date().timeIntervalSince1970
        return rows("""
            SELECT m.id AS mid, b.backup_id AS bid, m.remind_days AS rd, COALESCE(NULLIF(m.label,''), m.name) AS mname,
                   COALESCE(NULLIF(d.label,''), d.name) AS bname, d.last_scan AS bscan
            FROM drives m JOIN backups b ON b.main_id = m.id JOIN drives d ON d.id = b.backup_id
            WHERE m.remind_days > 0
            """).compactMap { r in
            guard let rd = r["rd"] as? Int, rd > 0 else { return nil }
            let age = now - (r["bscan"] as? Double ?? 0)
            guard age > Double(rd) * 86400 else { return nil }
            return (r["mname"] as? String ?? "", r["bname"] as? String ?? "", Int(age / 86400),
                    "\(r["mid"] as? Int ?? 0)-\(r["bid"] as? Int ?? 0)")
        }
    }

    func excludedPaths(_ id: Int) -> [String] {
        rows("SELECT path FROM excluded WHERE drive_id=?", [id]).compactMap { $0["path"] as? String }
    }

    func setExcluded(_ id: Int, _ path: String, _ on: Bool) {
        if on { run("INSERT OR IGNORE INTO excluded(drive_id, path) VALUES(?,?)", [id, path]) }
        else { run("DELETE FROM excluded WHERE drive_id=? AND path=?", [id, path]) }
    }

    func markChecking(_ ids: [Int]) {
        for id in ids { run("UPDATE drives SET cov_state='checking' WHERE id=?", [id]) }
    }

    func clearCoverage(_ id: Int) {
        run("UPDATE entries SET copies=NULL WHERE drive_id=? AND copies IS NOT NULL", [id])
        run("""
            UPDATE drives SET cov_files=NULL, cov_none=NULL, cov_one=NULL, cov_two=NULL, cov_none_bytes=NULL,
            cov_state='' WHERE id=?
            """, [id])
    }

    /// For every file on a main drive, count how many of its backup drives hold a file with the same name and size.
    @discardableResult
    func recomputeCoverage(_ mainID: Int) -> Bool {
        guard let d = row("SELECT gen FROM drives WHERE id=?", [mainID]), let gen = d["gen"] as? Int else { return false }
        var historyGrew = false
        let bks = rows("""
            SELECT d.id AS id, d.gen AS gen, COALESCE(b.backup_path,'') AS path, COALESCE(b.grp,'') AS grp,
                   d.key AS key, COALESCE(NULLIF(d.label,''), d.name) AS name, COALESCE(d.last_scan, 0) AS scan
            FROM backups b JOIN drives d ON d.id = b.backup_id WHERE b.main_id=?
            ORDER BY COALESCE(NULLIF(d.label,''), d.name) COLLATE NOCASE
            """, [mainID])
        if bks.isEmpty { clearCoverage(mainID); return false }
        run("UPDATE drives SET cov_state='checking' WHERE id=?", [mainID])
        let cond = bks.map { scopeSQL($0) }.joined(separator: " OR ")
        // Locations in the same backup set count as one backup together.
        let setOf = "CASE " + bks.map { "WHEN b.drive_id=\($0["id"] as? Int ?? -1) THEN \(sqlQuote(Self.setKey($0)))" }.joined(separator: " ") + " END"
        exec("BEGIN")
        run("""
            UPDATE entries SET copies = (
                SELECT COUNT(DISTINCT \(setOf)) FROM entries b
                WHERE b.name = entries.name AND b.size = entries.size AND b.is_dir <> 1 AND (\(cond)))
            WHERE drive_id = ? AND gen = ? AND is_dir <> 1
            """, [mainID, gen])
        for p in excludedPaths(mainID) {
            run("""
                UPDATE entries SET copies = -1 WHERE drive_id=? AND gen=? AND is_dir <> 1
                AND (parent = ? OR (parent >= ? AND parent < ?))
                """, [mainID, gen, p, p + "/", p + "0"])
        }
        let s = row("""
            SELECT SUM(copies>=0) AS n, SUM(copies=0) AS c0, SUM(copies=1) AS c1, SUM(copies>=2) AS c2,
                   SUM(CASE WHEN copies=0 THEN size ELSE 0 END) AS nb, SUM(copies=-1) AS ex
            FROM entries WHERE drive_id=? AND gen=? AND is_dir <> 1
            """, [mainID, gen]) ?? [:]
        run("""
            UPDATE drives SET cov_files=?, cov_none=?, cov_one=?, cov_two=?, cov_none_bytes=?, cov_excluded=?,
            cov_state='ok' WHERE id=?
            """, [s["n"] as? Int ?? 0, s["c0"] as? Int ?? 0, s["c1"] as? Int ?? 0, s["c2"] as? Int ?? 0,
                  s["nb"] as? Int ?? 0, s["ex"] as? Int ?? 0, mainID])
        // How complete is each backup set? Keep a history of changes.
        let mainScan = row("SELECT last_scan FROM drives WHERE id=?", [mainID])?["last_scan"] as? Double ?? 0
        var order: [String] = []
        var sets: [String: [[String: Any]]] = [:]
        for b in bks {
            let k = Self.setKey(b)
            if sets[k] == nil { order.append(k) }
            sets[k, default: []].append(b)
        }
        for k in order {
            let members = sets[k] ?? []
            let scope = members.map { scopeSQL($0) }.joined(separator: " OR ")
            let r = row("""
                SELECT COUNT(*) AS n, SUM(f) AS have, SUM(CASE WHEN f THEN 0 ELSE size END) AS mb FROM (
                    SELECT entries.size AS size, EXISTS(SELECT 1 FROM entries b WHERE b.name = entries.name
                        AND b.size = entries.size AND b.is_dir <> 1 AND (\(scope))) AS f
                    FROM entries WHERE drive_id=? AND gen=? AND is_dir <> 1 AND copies >= 0)
                """, [mainID, gen]) ?? [:]
            let n = r["n"] as? Int ?? 0, have = r["have"] as? Int ?? 0, mb = r["mb"] as? Int ?? 0
            for m in members {
                run("UPDATE backups SET cov_n=?, cov_have=?, cov_missing_bytes=? WHERE main_id=? AND backup_id=?",
                    [n, have, mb, mainID, m["id"] as? Int ?? -1])
            }
            // A set is only as current as its oldest member's catalog.
            let backupScan = members.map { $0["scan"] as? Double ?? 0 }.min() ?? 0
            let label = members.map { $0["name"] as? String ?? "?" }.joined(separator: " + ")
            let firstID = members.first?["id"] as? Int ?? -1
            let last = row("""
                SELECT n, have, main_scan, backup_scan FROM backup_history
                WHERE main_id=? AND COALESCE(grp, 'k:'||(SELECT key FROM drives WHERE id=backup_id))=? ORDER BY at DESC LIMIT 1
                """, [mainID, k])
            let changed = last == nil || last?["n"] as? Int != n || last?["have"] as? Int != have
                || last?["backup_scan"] as? Double != backupScan || last?["main_scan"] as? Double != mainScan
            if changed {
                run("""
                    INSERT INTO backup_history(main_id, backup_id, at, n, have, missing_bytes, main_scan, backup_scan, grp, label)
                    VALUES(?,?,?,?,?,?,?,?,?,?)
                    """, [mainID, firstID, Date().timeIntervalSince1970, n, have, mb, mainScan, backupScan, k, label])
                historyGrew = true
            }
        }
        exec("COMMIT")
        return historyGrew
    }

    func mainsNeedingCoverage() -> [Int] {
        rows("SELECT DISTINCT main_id FROM backups b JOIN drives d ON d.id=b.main_id WHERE d.cov_state='checking' OR d.cov_files IS NULL")
            .compactMap { $0["main_id"] as? Int }
    }

    /// Backup status of each child (file or folder) of `path`: {name: {n, none, one}}.
    func folderCoverage(_ id: Int, _ path: String) -> [String: Any] {
        guard let d = row("SELECT gen FROM drives WHERE id=?", [id]), let gen = d["gen"] as? Int else { return [:] }
        let agg = "SUM(copies=0) AS none, SUM(copies=1) AS one, SUM(copies>=0) AS n, SUM(copies=-1) AS ex"
        let sql: String
        let args: [Any?]
        if path.isEmpty {
            sql = """
                SELECT CASE WHEN parent='' THEN name ELSE substr(parent, 1, instr(parent||'/', '/')-1) END AS child, \(agg)
                FROM entries WHERE drive_id=? AND gen=? AND is_dir <> 1 AND copies IS NOT NULL GROUP BY child
                """
            args = [id, gen]
        } else {
            let start = path.unicodeScalars.count + 2
            sql = """
                SELECT CASE WHEN parent=? THEN name ELSE substr(parent, ?, instr(substr(parent, ?)||'/', '/')-1) END AS child, \(agg)
                FROM entries WHERE drive_id=? AND gen=? AND is_dir <> 1 AND copies IS NOT NULL
                  AND (parent=? OR (parent >= ? AND parent < ?)) GROUP BY child
                """
            args = [path, start, start, id, gen, path, path + "/", path + "0"]
        }
        var out: [String: Any] = [:]
        for r in rows(sql, args) {
            guard let c = r["child"] as? String else { continue }
            out[c] = ["n": r["n"] as? Int ?? 0, "none": r["none"] as? Int ?? 0, "one": r["one"] as? Int ?? 0,
                      "ex": r["ex"] as? Int ?? 0]
        }
        return out
    }

    /// Files on a main drive that one particular backup set doesn't have.
    func missingFromSet(_ mainID: Int, setKey: String, limit: Int = 3000) -> [String: Any] {
        guard let d = row("SELECT gen FROM drives WHERE id=?", [mainID]), let gen = d["gen"] as? Int else { return [:] }
        let members = rows("""
            SELECT d.id AS id, d.gen AS gen, COALESCE(b.backup_path,'') AS path, COALESCE(b.grp,'') AS grp, d.key AS key
            FROM backups b JOIN drives d ON d.id = b.backup_id WHERE b.main_id=?
            """, [mainID]).filter { Self.setKey($0) == setKey }
        guard !members.isEmpty else { return ["total": 0, "bytes": 0, "rows": [Any](), "folders": [Any]()] }
        let scope = members.map { scopeSQL($0) }.joined(separator: " OR ")
        let base = """
            FROM entries WHERE drive_id=? AND gen=? AND is_dir <> 1 AND copies >= 0 AND NOT EXISTS(
                SELECT 1 FROM entries b WHERE b.name = entries.name AND b.size = entries.size AND b.is_dir <> 1 AND (\(scope)))
            """
        let args: [Any?] = [mainID, gen]
        let total = row("SELECT COUNT(*) AS n, SUM(size) AS bytes \(base)", args) ?? [:]
        return [
            "total": total["n"] as? Int ?? 0,
            "bytes": total["bytes"] as? Int ?? 0,
            "rows": rows("SELECT id, parent, name, is_dir, size, mtime, copies \(base) ORDER BY parent, name LIMIT ?", args + [limit]),
            "folders": rows("SELECT parent, COUNT(*) AS n, SUM(size) AS bytes \(base) GROUP BY parent ORDER BY n DESC LIMIT 20", args),
        ]
    }

    /// Files on a main drive with at most `maxCopies` backups.
    func missingFiles(_ id: Int, maxCopies: Int, limit: Int = 3000) -> [String: Any] {
        guard let d = row("SELECT gen FROM drives WHERE id=?", [id]), let gen = d["gen"] as? Int else { return [:] }
        let base = "FROM entries WHERE drive_id=? AND gen=? AND is_dir <> 1 AND copies >= 0 AND copies <= ?"
        let args: [Any?] = [id, gen, maxCopies]
        let total = row("SELECT COUNT(*) AS n, SUM(size) AS bytes \(base)", args) ?? [:]
        return [
            "total": total["n"] as? Int ?? 0,
            "bytes": total["bytes"] as? Int ?? 0,
            "rows": rows("SELECT id, parent, name, is_dir, size, mtime, copies \(base) ORDER BY parent, name LIMIT ?", args + [limit]),
            "folders": rows("SELECT parent, COUNT(*) AS n, SUM(size) AS bytes \(base) GROUP BY parent ORDER BY n DESC LIMIT 20", args),
        ]
    }

    // MARK: - sync between Macs

    func touchMeta(_ ids: [Int]) {
        let now = Date().timeIntervalSince1970
        for id in ids { run("UPDATE drives SET meta_updated=? WHERE id=?", [now, id]) }
    }

    /// Editable, user-facing info about a drive, shared between Macs.
    func metaDict(_ id: Int) -> [String: Any]? {
        guard let d = row("SELECT key, name, label, notes, role, meta_updated, remind_days, media_user FROM drives WHERE id=?", [id]),
              let key = d["key"] as? String else { return nil }
        let mains = rows("SELECT d.key AS key FROM backups b JOIN drives d ON d.id=b.main_id WHERE b.backup_id=? AND COALESCE(b.backup_path,'')=''", [id])
            .compactMap { $0["key"] as? String }
        let folders: [[String: Any]] = rows("SELECT d.key AS key, b.backup_path AS path FROM backups b JOIN drives d ON d.id=b.main_id WHERE b.backup_id=? AND COALESCE(b.backup_path,'')<>''", [id])
            .compactMap { r in
                guard let k = r["key"] as? String, let p = r["path"] as? String else { return nil }
                return ["main": k, "path": p]
            }
        return [
            "key": key, "name": d["name"] as? String ?? "", "label": d["label"] as? String ?? "",
            "notes": d["notes"] as? String ?? "", "role": d["role"] as? String ?? "",
            "backup_of": mains, "folder_backups": folders, "excluded": excludedPaths(id),
            "sets": Dictionary(rows("SELECT d.key AS key, b.grp AS grp FROM backups b JOIN drives d ON d.id=b.main_id WHERE b.backup_id=? AND COALESCE(b.grp,'')<>''", [id])
                .compactMap { r -> (String, String)? in
                    guard let k = r["key"] as? String, let g = r["grp"] as? String else { return nil }
                    return (k, g)
                }, uniquingKeysWith: { a, _ in a }),
            "remind_days": d["remind_days"] as? Int ?? 0, "media_user": d["media_user"] as? String ?? "",
            "updated": d["meta_updated"] as? Double ?? 0, "format": 1,
        ]
    }

    /// Writes one drive's catalog into a standalone SQLite file.
    func exportDrive(_ id: Int, to path: String, machine: String) -> Bool {
        guard let d = row("SELECT * FROM drives WHERE id=?", [id]), let gen = d["gen"] as? Int, gen > 0,
              d["last_scan"] as? Double != nil else { return false }
        run("ATTACH DATABASE ? AS x", [path])
        defer { exec("DETACH DATABASE x") }
        guard exec("""
            CREATE TABLE x.entries(parent TEXT, name TEXT, is_dir INTEGER, size INTEGER, mtime REAL, items INTEGER);
            CREATE TABLE x.info(k TEXT PRIMARY KEY, v);
            """) else { return false }
        exec("BEGIN")
        run("INSERT INTO x.entries SELECT parent, name, is_dir, size, mtime, items FROM entries WHERE drive_id=? AND gen=?", [id, gen])
        for k in ["key", "name", "kind", "source", "fs", "total_bytes", "free_bytes", "used_bytes", "file_count",
                  "dir_count", "catalog_bytes", "last_scan", "scan_seconds", "first_seen", "media"] {
            run("INSERT INTO x.info(k, v) VALUES(?, ?)", [k, d[k]])
        }
        run("INSERT INTO x.info(k, v) VALUES('machine', ?)", [machine])
        run("INSERT INTO x.info(k, v) VALUES('format', 1)")
        exec("COMMIT")
        return true
    }

    /// Imports a drive catalog written by another Mac if it is newer than ours. Returns the local drive id if imported.
    func importDrive(from path: String) -> Int? {
        run("ATTACH DATABASE ? AS y", [path])
        defer { exec("DETACH DATABASE y") }
        var info: [String: Any] = [:]
        for r in rows("SELECT k, v FROM y.info") { if let k = r["k"] as? String { info[k] = r["v"] } }
        guard let key = info["key"] as? String, let remoteScan = info["last_scan"] as? Double else { return nil }
        let local = row("SELECT id, gen, last_scan, status FROM drives WHERE key=?", [key])
        if let l = local {
            if let ls = l["last_scan"] as? Double, ls >= remoteScan - 1 { return nil }
            if l["status"] as? String == "scanning" { return nil }
        }
        let id: Int, gen: Int
        if let l = local, let lid = l["id"] as? Int {
            id = lid
            gen = (l["gen"] as? Int ?? 0) + 1
        } else {
            run("INSERT INTO drives(key, name, kind, source, fs, first_seen, last_seen) VALUES(?,?,?,?,?,?,?)",
                [key, info["name"], info["kind"], info["source"], info["fs"], info["first_seen"], info["last_scan"]])
            id = lastID
            gen = 1
        }
        exec("BEGIN")
        run("INSERT INTO entries(drive_id, gen, parent, name, is_dir, size, mtime, items) SELECT ?, ?, parent, name, is_dir, size, mtime, items FROM y.entries", [id, gen])
        exec("COMMIT")
        let machine = info["machine"] as? String ?? "another Mac"
        finishScan(id: id, gen: gen, files: info["file_count"] as? Int ?? 0, dirs: info["dir_count"] as? Int ?? 0,
                   bytes: Int64(info["catalog_bytes"] as? Int ?? 0), seconds: info["scan_seconds"] as? Double ?? 0,
                   detail: "Scanned on \(machine)")
        run("""
            UPDATE drives SET last_scan=?, total_bytes=COALESCE(?, total_bytes), free_bytes=COALESCE(?, free_bytes),
            used_bytes=COALESCE(?, used_bytes), name=COALESCE(?, name),
            media=CASE WHEN COALESCE(?, '')='' THEN media ELSE ? END WHERE id=?
            """, [remoteScan, info["total_bytes"], info["free_bytes"], info["used_bytes"], info["name"],
                  info["media"], info["media"], id])
        return id
    }

    enum MetaResult { case unknownDrive, unchanged, applied([Int]) }

    /// Applies names/notes/roles/backup assignments from another Mac if newer than ours.
    func applyMeta(_ m: [String: Any]) -> MetaResult {
        guard let key = m["key"] as? String, let updated = m["updated"] as? Double else { return .unchanged }
        guard let l = row("SELECT id, meta_updated, last_scan FROM drives WHERE key=?", [key]), let id = l["id"] as? Int
        else { return .unknownDrive }
        if (l["meta_updated"] as? Double ?? 0) >= updated { return .unchanged }
        if m["forgotten"] as? Bool == true {
            // Ignore the tombstone if the drive was scanned again after it was forgotten.
            if (l["last_scan"] as? Double ?? 0) > updated { return .unchanged }
            let mains = mainsBackedUpBy(id)
            forget(id)
            return .applied(mains)
        }
        let role = m["role"] as? String ?? ""
        run("UPDATE drives SET label=?, notes=?, role=?, meta_updated=? WHERE id=?",
            [m["label"] as? String ?? "", m["notes"] as? String ?? "", role, updated, id])
        var affected = mainsBackedUpBy(id)
        run("DELETE FROM backups WHERE backup_id=?", [id])
        for mk in m["backup_of"] as? [String] ?? [] {
            if let mid = row("SELECT id FROM drives WHERE key=?", [mk])?["id"] as? Int {
                run("INSERT OR REPLACE INTO backups(main_id, backup_id, backup_path) VALUES(?,?,'')", [mid, id])
                affected.append(mid)
            }
        }
        for f in m["folder_backups"] as? [[String: Any]] ?? [] {
            if let mk = f["main"] as? String, let path = f["path"] as? String,
               let mid = row("SELECT id FROM drives WHERE key=?", [mk])?["id"] as? Int {
                run("INSERT OR REPLACE INTO backups(main_id, backup_id, backup_path) VALUES(?,?,?)", [mid, id, path])
                affected.append(mid)
            }
        }
        if let sets = m["sets"] as? [String: String] {
            for (mk, g) in sets {
                if let mid = row("SELECT id FROM drives WHERE key=?", [mk])?["id"] as? Int {
                    run("UPDATE backups SET grp=? WHERE main_id=? AND backup_id=?", [g, mid, id])
                }
            }
        }
        if let rd = m["remind_days"] as? Int { run("UPDATE drives SET remind_days=? WHERE id=?", [rd, id]) }
        if let mu = m["media_user"] as? String { run("UPDATE drives SET media_user=? WHERE id=?", [mu, id]) }
        if let ex = m["excluded"] as? [String] {
            run("DELETE FROM excluded WHERE drive_id=?", [id])
            for p in ex { setExcluded(id, p, true) }
        }
        if role == "main" { affected.append(id) } else if role != "backup" { clearCoverage(id) }
        return .applied(affected)
    }

    // MARK: - history sync

    func driveKey(_ id: Int) -> String? { row("SELECT key FROM drives WHERE id=?", [id])?["key"] as? String }

    func historyForSync(_ mainID: Int) -> [[String: Any]] {
        rows("""
            SELECT d.key AS backup, h.at, h.n, h.have, h.missing_bytes AS mb, h.main_scan AS ms, h.backup_scan AS bs,
                   COALESCE(h.grp, 'k:'||d.key) AS grp, h.label AS label
            FROM backup_history h JOIN drives d ON d.id = h.backup_id
            WHERE h.main_id=? ORDER BY h.at DESC LIMIT 300
            """, [mainID])
    }

    /// Adds history entries recorded on another Mac. Returns how many were new.
    func mergeHistory(mainKey: String, _ entries: [[String: Any]]) -> Int {
        guard let mid = row("SELECT id FROM drives WHERE key=?", [mainKey])?["id"] as? Int else { return 0 }
        var added = 0
        for e in entries {
            guard let bk = e["backup"] as? String,
                  let bid = row("SELECT id FROM drives WHERE key=?", [bk])?["id"] as? Int else { continue }
            let n = e["n"] as? Int ?? 0, have = e["have"] as? Int ?? 0
            let ms = e["ms"] as? Double ?? 0, bs = e["bs"] as? Double ?? 0
            let grp = e["grp"] as? String ?? ("k:" + bk)
            let exists = row("""
                SELECT 1 AS x FROM backup_history WHERE main_id=? AND COALESCE(grp, 'k:'||(SELECT key FROM drives WHERE id=backup_id))=?
                AND n=? AND have=? AND ABS(COALESCE(main_scan,0)-?) < 0.01 AND ABS(COALESCE(backup_scan,0)-?) < 0.01
                """, [mid, grp, n, have, ms, bs]) != nil
            if exists { continue }
            run("""
                INSERT INTO backup_history(main_id, backup_id, at, n, have, missing_bytes, main_scan, backup_scan, grp, label)
                VALUES(?,?,?,?,?,?,?,?,?,?)
                """, [mid, bid, e["at"] as? Double ?? 0, n, have, e["mb"] as? Int ?? 0, ms, bs, grp, e["label"]])
            added += 1
        }
        return added
    }
}
