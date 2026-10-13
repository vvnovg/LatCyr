import XCTest
@testable import LatCyr

final class FileLoggerTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("FileLoggerTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// File name → size in bytes.
    private func files() -> [String: Int] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var result: [String: Int] = [:]
        for name in names {
            let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
            result[name] = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        }
        return result
    }

    /// A 10-byte line including the newline FileLogger appends.
    private let line9 = "123456789"

    func testWritesLinesToCurrentFile() throws {
        let logger = FileLogger(directory: dir, maxTotalBytes: 1000)
        logger.write("a")
        logger.write("b")
        logger.flush()
        let content = try String(contentsOf: dir.appendingPathComponent("latcyr.log"), encoding: .utf8)
        XCTAssertEqual(content, "a\nb\n")
    }

    func testDoesNotCreateDirectoryWithoutWrites() {
        let logger = FileLogger(directory: dir, maxTotalBytes: 1000)
        logger.setMaxTotalBytes(500)
        logger.close()
        logger.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testRotationKeepsAtMostFiveFilesWithinTotal() {
        let logger = FileLogger(directory: dir, maxTotalBytes: 500) // 100 per file
        for _ in 0..<100 { logger.write(line9) }                    // 1000 bytes
        logger.flush()
        let found = files()
        let allowed: Set<String> = ["latcyr.log", "latcyr.1.log", "latcyr.2.log", "latcyr.3.log", "latcyr.4.log"]
        XCTAssertTrue(Set(found.keys).isSubset(of: allowed), "\(found)")
        XCTAssertEqual(found.count, 5)
        XCTAssertTrue(found.values.allSatisfy { $0 <= 100 }, "\(found)")
        XCTAssertLessThanOrEqual(found.values.reduce(0, +), 500)
    }

    func testShrinkingLimitDeletesOldestFiles() {
        let logger = FileLogger(directory: dir, maxTotalBytes: 500)
        for _ in 0..<50 { logger.write(line9) } // fills all five files exactly
        logger.flush()
        XCTAssertEqual(files().values.reduce(0, +), 500)

        logger.setMaxTotalBytes(200)
        logger.flush()
        let found = files()
        XCTAssertLessThanOrEqual(found.values.reduce(0, +), 200, "\(found)")
        XCTAssertNil(found["latcyr.4.log"])
    }

    func testOversizedLineGoesWholeIntoAFreshFile() throws {
        let logger = FileLogger(directory: dir, maxTotalBytes: 50) // 10 per file
        let long = String(repeating: "x", count: 30)
        logger.write(long)
        logger.write("y")
        logger.flush()
        let current = try String(contentsOf: dir.appendingPathComponent("latcyr.log"), encoding: .utf8)
        let rotated = try String(contentsOf: dir.appendingPathComponent("latcyr.1.log"), encoding: .utf8)
        XCTAssertEqual(rotated, long + "\n")
        XCTAssertEqual(current, "y\n")
    }

    func testReopensAfterClose() throws {
        let logger = FileLogger(directory: dir, maxTotalBytes: 1000)
        logger.write("a")
        logger.close()
        logger.write("b")
        logger.flush()
        let content = try String(contentsOf: dir.appendingPathComponent("latcyr.log"), encoding: .utf8)
        XCTAssertEqual(content, "a\nb\n")
    }
}
