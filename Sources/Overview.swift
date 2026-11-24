import Foundation

/// "Export overview for Claude": one readable Markdown file describing the user's drives, backups, folder
/// structure, what takes up space and duplicates across drives, made from the catalog (nothing is read from
/// the drives). Folder names only by default; file names only for duplicates, and only if the user asks.
extension DB {
    private func gb(_ b: Int64) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file; f.allowsNonnumericFormatting = false   // "0 KB", not "Zero KB"
        return f.string(fromByteCount: b)
    }
    private func i64(_ v: Any?) -> Int64 { (v as? Int).map(Int64.init) ?? (v as? NSNumber)?.int64Value ?? Int64(v as? Double ?? 0) }
    private func when(_ t: Any?) -> String {
        guard let s = t as? Double, s > 0 else { return "never" }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        let days = Int((Date().timeIntervalSince1970 - s) / 86400)
        return f.string(from: Date(timeIntervalSince1970: s)) + (days > 1 ? " (\(days) days ago)" : days == 1 ? " (yesterday)" : " (today)")
    }
    private func md(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ") }

    private static let categories: [(String, Set<String>)] = [
        ("Video", ["mov", "mp4", "mxf", "braw", "r3d", "avi", "mkv", "mts", "m2ts", "m4v", "crm", "insv", "360", "mpg", "mpeg", "3gp", "lrv", "lrf"]),
        ("RAW photos", ["arw", "srf", "sr2", "cr2", "cr3", "crw", "nef", "nrw", "raf", "orf", "rw2", "rwl", "pef", "srw", "x3f", "3fr", "fff", "iiq", "dng", "gpr"]),
        ("Photos (JPEG, HEIF, TIFF, PSD)", ["jpg", "jpeg", "heic", "heif", "hif", "png", "tif", "tiff", "psd", "psb", "webp"]),
        ("Audio", ["wav", "bwf", "aif", "aiff", "flac", "mp3", "m4a", "aac"]),
        ("Project files", ["prproj", "drp", "aep", "lrcat", "cocatalog", "fcpxml", "xml", "edl", "aaf", "omf", "ptx", "logicx", "band"]),
        ("Archives & disk images", ["zip", "rar", "7z", "dmg", "iso", "tar", "gz", "sparseimage", "sparsebundle"]),
    ]

    /// Builds the overview. `fileNames`: list duplicate files by name. `depth`: folder levels per drive (1–4).
    func overviewMarkdown(online: [String: VolumeInfo], fileNames: Bool, depth: Int) -> String {
        let all = drivesList(online: online)
        let cards = all.filter { ($0["is_card"] as? Int) == 1 || $0["card"] != nil }
        let drives = all.filter { d in !cards.contains { ($0["id"] as? Int) == (d["id"] as? Int) } }
        let byID = Dictionary(uniqueKeysWithValues: all.compactMap { d in (d["id"] as? Int).map { ($0, d) } })
        let name = { (id: Int) -> String in (byID[id]?["display"] as? String) ?? "?" }
        var o: [String] = []
        let df = DateFormatter(); df.dateStyle = .long; df.timeStyle = .short

        o.append("# DriveDex overview")
        o.append("")
        o.append("Exported \(df.string(from: Date())) on \(SyncFolder.machine) from DriveDex, a Mac app that catalogs drives (file and folder names, sizes and dates; it never reads file contents) and checks whether main drives are backed up. A file counts as backed up when a backup has a file with the same name and size. Use this to give advice on storage, drive naming, where things should live, duplicates and backup strategy. Sizes are decimal (1 TB = 1000 GB).")
        o.append("")
        let usedTotal = drives.reduce(Int64(0)) { $0 + i64($1["used_bytes"]) }
        let capTotal = drives.reduce(Int64(0)) { $0 + i64($1["total_bytes"]) }
        let filesTotal = drives.reduce(0) { $0 + ($1["file_count"] as? Int ?? 0) }
        o.append("**\(drives.count) drives** · \(gb(usedTotal)) used of \(gb(capTotal)) · \(filesTotal.formatted()) files catalogued" +
                 (cards.isEmpty ? "" : " · \(cards.count) memory cards (left out below)"))
        o.append("")

        // Drives
        o.append("## Drives")
        o.append("")
        o.append("| Drive | Type | Role | Capacity | Used | Free | Files | Last catalogued | Last connected | Location note |")
        o.append("|---|---|---|---|---|---|---|---|---|---|")
        for d in drives {
            let total = i64(d["total_bytes"]), used = i64(d["used_bytes"])
            let role = (d["role"] as? String) == "main" ? "Main files" : (d["role"] as? String) == "backup" ? "Backup" : "—"
            let seen = (d["online"] as? Bool) == true ? "connected now" : when(d["last_seen"]) + ((d["last_seen_on"] as? String).map { " on \($0)" } ?? "")
            o.append("| \(md(d["display"] as? String ?? "?")) | \((d["type"] as? String ?? "").uppercased()) | \(role) | \(total > 0 ? gb(total) : "?") | \(gb(used)) | \(total > 0 ? gb(max(0, total - used)) : "?") | \((d["file_count"] as? Int ?? 0).formatted()) | \(when(d["last_scan"])) | \(seen) | \(md((d["notes"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? "")) |")
        }
        o.append("")

        // Backups
        o.append("## Backups")
        o.append("")
        let mains = drives.filter { ($0["role"] as? String) == "main" }
        if mains.isEmpty { o.append("No drives are marked as main files yet."); o.append("") }
        for m in mains {
            let id = m["id"] as? Int ?? 0
            let cb = i64(m["cov_bytes"]), none = i64(m["cov_none_bytes"]), one = i64(m["cov_one_bytes"]), two = i64(m["cov_two_bytes"])
            o.append("### \(md(m["display"] as? String ?? "?"))")
            if cb > 0 {
                let p = { (x: Int64) in String(format: "%.1f%%", 100 * Double(x) / Double(cb)) }
                o.append("- Data on 2+ backups: \(gb(two)) (\(p(two))) · on 1 backup: \(gb(one)) (\(p(one))) · on no backup: \(gb(none)) (\(p(none)))")
            }
            let bs = m["backup_status"] as? [[String: Any]] ?? []
            if bs.isEmpty { o.append("- No backup assigned.") }
            for b in bs {
                let members = (b["members"] as? [[String: Any]] ?? []).map { mem -> String in
                    let p = mem["path"] as? String ?? ""
                    return name(mem["id"] as? Int ?? 0) + (p.isEmpty ? "" : " (folder \(p))")
                }
                let n = b["n"] as? Int, have = b["have"] as? Int ?? 0
                let src = b["source"] as? String ?? ""
                let state = n == nil ? "not checked yet" : (n! - have) <= 0 ? "complete" : "missing \((n! - have).formatted()) file\(n! - have == 1 ? "" : "s") (\(gb(i64(b["missing_bytes"]))))"
                o.append("- Backup\(members.count > 1 ? " set across \(members.count) drives" : ""): \(members.joined(separator: " + "))" +
                         (src.isEmpty ? "" : ", holds only the folder “\(src)”") + " · \(state) · last in sync: \(when(b["last_in_sync"])) · its catalog: \(when(b["backup_scan"]))")
            }
            if let rd = m["remind_days"] as? Int, rd > 0 { o.append("- Reminder when a backup is older than \(rd) days.") }
            let ex = m["excluded"] as? [String] ?? []
            if !ex.isEmpty { o.append("- Excluded from the backup check: " + ex.map { "“\($0)”" }.joined(separator: ", ")) }
            o.append("")
            _ = id
        }

        // Folders and content per drive
        o.append("## Folders and content")
        o.append("")
        o.append("Folder sizes include everything inside. “items” = entries directly inside. Small folders are left out.")
        o.append("")
        for d in drives {
            guard let id = d["id"] as? Int, let gen = d["gen"] as? Int, gen > 0 else { continue }
            let used = max(i64(d["used_bytes"]), 1)
            o.append("### \(md(d["display"] as? String ?? "?"))")
            o.append("")
            // What takes the space
            var cat: [String: (Int, Int64)] = [:], libs: (Int, Int64) = (0, 0)
            for r in rows("SELECT name, size, is_dir FROM entries WHERE drive_id=? AND gen=? AND is_dir <> 1", [id, gen]) {
                let size = i64(r["size"])
                if (r["is_dir"] as? Int) == 2 { libs.0 += 1; libs.1 += size; continue }
                let ext = ((r["name"] as? String ?? "") as NSString).pathExtension.lowercased()
                let c = DB.categories.first { $0.1.contains(ext) }?.0 ?? "Other files"
                let v = cat[c] ?? (0, 0)
                cat[c] = (v.0 + 1, v.1 + size)
            }
            if libs.0 > 0 { cat["Libraries & bundles (Final Cut, Photos…)"] = libs }
            let parts = cat.sorted { $0.value.1 > $1.value.1 }.filter { $0.value.1 > 0 }
                .map { "\($0.key): \(gb($0.value.1)) (\($0.value.0.formatted()))" }
            if !parts.isEmpty { o.append("Content: " + parts.joined(separator: " · ")); o.append("") }
            // Folder tree
            let minBytes = max(Int64(2_000_000_000), used / 200)
            func walk(_ path: String, _ level: Int) {
                let kids = rows("SELECT name, size, items, is_dir FROM entries WHERE drive_id=? AND gen=? AND parent=? AND is_dir >= 1 ORDER BY size DESC LIMIT ?",
                                [id, gen, path, level == 1 ? 60 : 25])
                var shown = 0, restBytes: Int64 = 0, rest = 0
                for k in kids {
                    let size = i64(k["size"]), n = k["name"] as? String ?? ""
                    if level > 1 && size < minBytes { rest += 1; restBytes += size; continue }
                    shown += 1
                    let lib = (k["is_dir"] as? Int) == 2 ? " (library/bundle)" : ""
                    let child = path.isEmpty ? n : path + "/" + n
                    o.append(String(repeating: "  ", count: level - 1) + "- \(md(n))\(lib) — \(gb(size))" + ((k["items"] as? Int).map { $0 > 0 ? " · \($0) item\($0 == 1 ? "" : "s")" : "" } ?? ""))
                    if level < depth && (k["is_dir"] as? Int) == 1 && size >= minBytes { walk(child, level + 1) }
                }
                if rest > 0 { o.append(String(repeating: "  ", count: level - 1) + "- … \(rest) smaller folder\(rest == 1 ? "" : "s") (\(gb(restBytes)))") }
            }
            walk("", 1)
            o.append("")
        }

        // Duplicates across drives (large files only), skipping copies that are this drive's backup links.
        o.append("## Large files on more than one drive")
        o.append("")
        o.append("Files of 1 GB or more with the same name and size on several drives. Expected for backups; elsewhere they may be duplicates.")
        o.append("")
        let ids = drives.compactMap { $0["id"] as? Int }
        if !ids.isEmpty {
            let list = ids.map(String.init).joined(separator: ",")
            let groups = rows("""
                SELECT e.nkey AS k, e.size AS size, MIN(e.name) AS name, GROUP_CONCAT(DISTINCT e.drive_id) AS ds, COUNT(DISTINCT e.drive_id) AS c
                FROM entries e JOIN drives d ON d.id = e.drive_id AND d.gen = e.gen
                WHERE e.drive_id IN (\(list)) AND e.is_dir <> 1 AND e.size >= 1000000000
                GROUP BY e.nkey, e.size HAVING c >= 2 ORDER BY e.size * c DESC LIMIT 5000
                """)
            var bySet: [String: (Int, Int64)] = [:]
            var top: [String] = []
            for g in groups {
                let ds = (g["ds"] as? String ?? "").split(separator: ",").compactMap { Int($0) }.sorted()
                let set = ds.map(name).joined(separator: " + ")
                let size = i64(g["size"])
                let v = bySet[set] ?? (0, 0)
                bySet[set] = (v.0 + 1, v.1 + size)
                if fileNames && top.count < 40 { top.append("- \(md(g["name"] as? String ?? "?")) (\(gb(size))) on \(set)") }
            }
            if bySet.isEmpty { o.append("None found.") }
            for (set, v) in bySet.sorted(by: { $0.value.1 > $1.value.1 }).prefix(25) {
                o.append("- \(set): \(v.0.formatted()) file\(v.0 == 1 ? "" : "s"), \(gb(v.1)) each copy")
            }
            if !top.isEmpty { o.append(""); o.append("Biggest examples:"); o.append(contentsOf: top) }
        }
        o.append("")
        return o.joined(separator: "\n")
    }
}
