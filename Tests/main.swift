// Checks XXH64 against values from the official xxHash library (python-xxhash 3.5), for many sizes and
// many ways of splitting the data into pieces. Run by build.sh before the app is built; a failure stops the build.
import Foundation

let expected: [(Int, UInt64)] = [
    (0, 17241709254077376921),
    (1, 12208272383309036471),
    (3, 6261856666793576441),
    (4, 14271086647985540868),
    (7, 12663836542954871438),
    (8, 4442176141076628448),
    (15, 12549904796550154919),
    (31, 5365180931665220769),
    (32, 10184845083914585149),
    (33, 7118499008196474468),
    (63, 6643383451930527103),
    (64, 8915644864283660670),
    (100, 17266991381171192145),
    (1000, 11049950332057828661),
    (100003, 14065797991923052507),
]
func sample(_ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) } }
var failures = 0
for (n, want) in expected {
    let d = sample(n)
    for chunks in [[n], [1, 1, 1, max(0, n - 3)], [17, 5, 40, 1000, 999_999]] {
        var x = XXH64()
        var p = 0
        for c in chunks {
            let e = min(d.count, p + c)
            if p < e { d[p..<e].withUnsafeBytes { x.update($0) } }
            p = e
        }
        if p < d.count { d[p...].withUnsafeBytes { x.update($0) } }
        if x.digest() != want {
            print("::error title=XXH64 self-test::size \(n) pieces \(chunks): got \(XXH64.hex(x.digest())) want \(XXH64.hex(want))")
            failures += 1
        }
    }
}
print(failures == 0 ? "XXH64 self-test passed (\(expected.count * 3) cases)" : "XXH64 self-test FAILED")
exit(failures == 0 ? 0 : 1)
