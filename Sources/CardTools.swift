import DiskArbitration
import Foundation

/// Formatting and renaming memory cards (Shoot mode only, always on the user's request).
/// This is the only place DriveDex writes to a disk, so every step checks first that the target really is
/// one memory card: a removable/ejectable disk of at most 2 TB with exactly one mounted volume, which is a card
/// of the shoot and none of the shoot's main or backup drives.
enum CardTools {
    struct Failure: Error { let message: String }

    /// Card names: exFAT and FAT32 allow at most 11 characters and no " * / : < > ? \ |.
    static func checkName(_ raw: String) -> Result<String, Failure> {
        let n = raw.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return .failure(Failure(message: "Give the card a name.")) }
        if n.count > 11 { return .failure(Failure(message: "Card names can have at most 11 characters (a limit of memory card formats).")) }
        if n.rangeOfCharacter(from: CharacterSet(charactersIn: "\"*/:<>?\\|")) != nil || n.unicodeScalars.contains(where: { $0.value < 32 }) {
            return .failure(Failure(message: "Card names can't contain \" * / : < > ? \\ |"))
        }
        return .success(n)
    }

    struct DiskInfo { let part: String; let whole: String; let removable: Bool; let wholeSize: Int64 }

    static func diskInfo(_ volume: URL) -> DiskInfo? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume as CFURL),
              let desc = DADiskCopyDescription(disk) as NSDictionary?,
              let part = desc[kDADiskDescriptionMediaBSDNameKey as String] as? String,
              let wholeDisk = DADiskCopyWholeDisk(disk), let wb = DADiskGetBSDName(wholeDisk),
              let wdesc = DADiskCopyDescription(wholeDisk) as NSDictionary? else { return nil }
        let removable = (wdesc[kDADiskDescriptionMediaRemovableKey as String] as? Bool ?? false)
            || (wdesc[kDADiskDescriptionMediaEjectableKey as String] as? Bool ?? false)
        let size = (wdesc[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value ?? 0
        return DiskInfo(part: part, whole: String(cString: wb), removable: removable, wholeSize: size)
    }

    /// Volumes mounted from the same physical disk as `volume` (other than `volume` itself).
    static func otherVolumes(onSameDiskAs volume: URL, whole: String) -> [String] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        return urls.filter { $0.standardizedFileURL.path != volume.standardizedFileURL.path }
            .filter { diskInfo($0)?.whole == whole }
            .map { $0.lastPathComponent }
    }

    @discardableResult
    static func diskutil(_ args: [String]) -> (ok: Bool, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (false, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }

    /// Finds the card (by drive key) and checks it's safe to touch. Returns its mount and disk.
    static func target(db: DB, shoot uuid: String, key: String) -> Result<(VolumeInfo, DiskInfo, [String: Any]), Failure> {
        guard let s = Shoots.get(db, uuid), s["deleted"] as? Bool != true else { return .failure(Failure(message: "The shoot doesn't exist any more.")) }
        guard (s["cards"] as? [[String: Any]] ?? []).contains(where: { $0["key"] as? String == key }) else {
            return .failure(Failure(message: "That card isn't part of this shoot."))
        }
        if Shoots.destKeys(s).contains(key) { return .failure(Failure(message: "That's one of the shoot's main or backup drives.")) }
        guard let v = Scanner.onlineMap()[key] else { return .failure(Failure(message: "The card isn't connected.")) }
        guard v.kind == "drive", !v.isDiskImage, let d = diskInfo(v.url) else {
            return .failure(Failure(message: "DriveDex couldn't identify this card's disk."))
        }
        guard d.removable else { return .failure(Failure(message: "This isn't a removable memory card, so DriveDex won't touch it.")) }
        guard d.wholeSize > 0, d.wholeSize <= 2_200_000_000_000 else { return .failure(Failure(message: "This disk is too big to be a memory card.")) }
        let others = otherVolumes(onSameDiskAs: v.url, whole: d.whole)
        guard others.isEmpty else {
            return .failure(Failure(message: "This disk also holds \(others.joined(separator: ", ")). DriveDex only formats plain memory cards."))
        }
        return .success((v, d, s))
    }

    /// Erases the card and formats it (exFAT; FAT32 up to 32 GB, like cameras do) with the given name.
    static func format(db: DB, shoot uuid: String, key: String, name rawName: String, allowQuickOnly: Bool, eject: Bool) -> Result<String, Failure> {
        let name: String
        switch checkName(rawName) { case .failure(let f): return .failure(f); case .success(let n): name = n }
        let v: VolumeInfo, d: DiskInfo
        switch target(db: db, shoot: uuid, key: key) { case .failure(let f): return .failure(f); case .success(let t): v = t.0; d = t.1 }

        // Only a card whose files are all on the main drive and every backup (checked again now).
        let st = Shoots.status(db, uuid)
        guard let card = (st["cards"] as? [[String: Any]] ?? []).first(where: { $0["key"] as? String == key }) else {
            return .failure(Failure(message: "Couldn't check the card."))
        }
        let deep = card["deep"] as? [String: Any]
        let deepOK = card["deep_valid"] as? Bool == true && deep?["state"] as? String == "verified"
        let deepBad = card["deep_valid"] as? Bool == true && deep?["state"] as? String == "problems"
        if deepBad { return .failure(Failure(message: "The deep check found problems on this card. It isn't safe to format.")) }
        guard card["state"] as? String == "safe" else {
            return .failure(Failure(message: "This card isn't safe to format yet: not all of its files are on the main drive and every backup."))
        }
        if !deepOK && !allowQuickOnly { return .failure(Failure(message: "Run a deep check first, or confirm formatting after the quick check only.")) }

        // Let go of the card, then erase it.
        DeepCheck.shared.stop(key)
        Scanner.shared.stop(key)
        Scanner.shared.letGo(v.url.standardizedFileURL.path)
        let fs = d.wholeSize <= 34_400_000_000 ? "MS-DOS FAT32" : "ExFAT"
        let label = fs == "ExFAT" ? name : name.uppercased()
        let r = diskutil(["eraseDisk", fs, label, "MBRFormat", "/dev/" + d.whole])
        guard r.ok else {
            return .failure(Failure(message: "Formatting failed: " + (r.output.split(separator: "\n").last.map(String.init) ?? "unknown error")))
        }
        // Remember it in the shoot (the card gets a new identity, so this row is now a record).
        if var s = Shoots.get(db, uuid) {
            var cards = s["cards"] as? [[String: Any]] ?? []
            if let i = cards.firstIndex(where: { $0["key"] as? String == key }) {
                cards[i]["formatted"] = ["at": Date().timeIntervalSince1970, "name": label, "mac": SyncFolder.machine,
                                         "deep": deepOK] as [String: Any]
            }
            s["cards"] = cards
            Shoots.put(db, s)
        }
        if eject { diskutil(["eject", "/dev/" + d.whole]) }
        return .success(label)
    }

    /// Renames a card without erasing anything.
    static func rename(db: DB, shoot uuid: String, key: String, name rawName: String) -> Result<String, Failure> {
        let name: String
        switch checkName(rawName) { case .failure(let f): return .failure(f); case .success(let n): name = n }
        let v: VolumeInfo
        switch target(db: db, shoot: uuid, key: key) { case .failure(let f): return .failure(f); case .success(let t): v = t.0 }
        let r = diskutil(["rename", v.url.path, name])
        guard r.ok else { return .failure(Failure(message: "Renaming failed: " + (r.output.split(separator: "\n").last.map(String.init) ?? ""))) }
        if var s = Shoots.get(db, uuid) {
            var cards = s["cards"] as? [[String: Any]] ?? []
            if let i = cards.firstIndex(where: { $0["key"] as? String == key }) { cards[i]["vol"] = name; cards[i]["label"] = name }
            s["cards"] = cards
            Shoots.put(db, s)
        }
        db.run("UPDATE drives SET name=? WHERE key=?", [name, key])
        return .success(name)
    }
}
