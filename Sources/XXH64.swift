import Foundation

/// xxHash64 (seed 0): a fast fingerprint of a file's contents, the same one Hedge / OffShoot store in their
/// MHL files ("xxh64"). Fed in pieces with `update`, then `digest()`. Checked against the official
/// implementation by `Tests/main.swift` on every build: keep this file free of other dependencies.
struct XXH64 {
    private static let p1: UInt64 = 0x9E37_79B1_85EB_CA87
    private static let p2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    private static let p3: UInt64 = 0x1656_67B1_9E37_79F9
    private static let p4: UInt64 = 0x85EB_CA77_C2B2_AE63
    private static let p5: UInt64 = 0x27D4_EB2F_1656_67C5

    private var v1: UInt64, v2: UInt64, v3: UInt64, v4: UInt64
    private var total: UInt64 = 0
    private var mem = [UInt8](repeating: 0, count: 32)
    private var memSize = 0
    private let seed: UInt64

    init(seed: UInt64 = 0) {
        self.seed = seed
        v1 = seed &+ XXH64.p1 &+ XXH64.p2
        v2 = seed &+ XXH64.p2
        v3 = seed
        v4 = seed &- XXH64.p1
    }

    @inline(__always) private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 { (x << r) | (x >> (64 - r)) }
    @inline(__always) private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        rotl(acc &+ input &* p2, 31) &* p1
    }
    @inline(__always) private static func merge(_ acc: UInt64, _ v: UInt64) -> UInt64 {
        (acc ^ round(0, v)) &* p1 &+ p4
    }
    @inline(__always) private static func le64(_ p: UnsafeRawPointer, _ o: Int) -> UInt64 {
        UInt64(littleEndian: p.loadUnaligned(fromByteOffset: o, as: UInt64.self))
    }
    @inline(__always) private static func le32(_ p: UnsafeRawPointer, _ o: Int) -> UInt32 {
        UInt32(littleEndian: p.loadUnaligned(fromByteOffset: o, as: UInt32.self))
    }

    @inline(__always) private mutating func stripe(_ p: UnsafeRawPointer, _ o: Int) {
        v1 = XXH64.round(v1, XXH64.le64(p, o))
        v2 = XXH64.round(v2, XXH64.le64(p, o + 8))
        v3 = XXH64.round(v3, XXH64.le64(p, o + 16))
        v4 = XXH64.round(v4, XXH64.le64(p, o + 24))
    }

    mutating func update(_ buf: UnsafeRawBufferPointer) {
        guard let base = buf.baseAddress, buf.count > 0 else { return }
        let len = buf.count
        total &+= UInt64(len)
        let filled = memSize   // read before touching `mem` (no overlapping access)
        if filled + len < 32 {
            mem.withUnsafeMutableBytes { m in m.baseAddress!.advanced(by: filled).copyMemory(from: base, byteCount: len) }
            memSize = filled + len
            return
        }
        var p = 0
        if filled > 0 {
            let need = 32 - filled
            mem.withUnsafeMutableBytes { m in m.baseAddress!.advanced(by: filled).copyMemory(from: base, byteCount: need) }
            let block = mem
            block.withUnsafeBytes { b in stripe(b.baseAddress!, 0) }
            p = need
            memSize = 0
        }
        while len - p >= 32 {
            stripe(base, p)
            p += 32
        }
        let rest = len - p
        if rest > 0 {
            mem.withUnsafeMutableBytes { m in m.baseAddress!.copyMemory(from: base.advanced(by: p), byteCount: rest) }
        }
        memSize = rest
    }

    mutating func update(_ data: Data) { data.withUnsafeBytes { update($0) } }

    func digest() -> UInt64 {
        var h: UInt64
        if total >= 32 {
            h = XXH64.rotl(v1, 1) &+ XXH64.rotl(v2, 7) &+ XXH64.rotl(v3, 12) &+ XXH64.rotl(v4, 18)
            h = XXH64.merge(h, v1); h = XXH64.merge(h, v2); h = XXH64.merge(h, v3); h = XXH64.merge(h, v4)
        } else {
            h = seed &+ XXH64.p5
        }
        h &+= total
        let n = memSize
        mem.withUnsafeBytes { b in
            let p = b.baseAddress!
            var i = 0
            while n - i >= 8 {
                h ^= XXH64.round(0, XXH64.le64(p, i))
                h = XXH64.rotl(h, 27) &* XXH64.p1 &+ XXH64.p4
                i += 8
            }
            if n - i >= 4 {
                h ^= UInt64(XXH64.le32(p, i)) &* XXH64.p1
                h = XXH64.rotl(h, 23) &* XXH64.p2 &+ XXH64.p3
                i += 4
            }
            while i < n {
                h ^= UInt64(b[i]) &* XXH64.p5
                h = XXH64.rotl(h, 11) &* XXH64.p1
                i += 1
            }
        }
        h ^= h >> 33; h = h &* XXH64.p2
        h ^= h >> 29; h = h &* XXH64.p3
        h ^= h >> 32
        return h
    }

    /// As written in MHL files: 16 lowercase hex digits.
    static func hex(_ v: UInt64) -> String {
        let s = String(v, radix: 16)
        return String(repeating: "0", count: 16 - s.count) + s
    }
}
