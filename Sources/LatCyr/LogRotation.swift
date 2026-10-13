import Foundation

/// Size-based rotation decisions, kept apart from the file I/O in
/// FileLogger so the part that guards the user's disk is unit-tested.
/// Files: latcyr.log (index 0, current), latcyr.1.log … latcyr.4.log
/// (higher index = older).
enum LogRotation {
    static let fileCount = 5

    static func perFileLimit(totalLimit: Int) -> Int {
        totalLimit / fileCount
    }

    /// Whether to rotate before appending `incoming` bytes. An empty file
    /// never rotates: a single line longer than the per-file limit is
    /// written whole into a fresh file rather than rotating forever.
    static func shouldRotate(currentSize: Int, incoming: Int, perFileLimit: Int) -> Bool {
        currentSize > 0 && currentSize + incoming > perFileLimit
    }

    /// Rotated files to delete so the total fits `totalLimit`, oldest first.
    /// Needed beyond normal rotation when the user lowers the limit: files
    /// written under the old, larger per-file limit would otherwise stay.
    static func filesToDelete(currentSize: Int, rotated: [Int: Int], totalLimit: Int) -> [Int] {
        var total = currentSize + rotated.values.reduce(0, +)
        var result: [Int] = []
        for index in rotated.keys.sorted(by: >) {
            guard total > totalLimit else { break }
            result.append(index)
            total -= rotated[index] ?? 0
        }
        return result
    }
}
