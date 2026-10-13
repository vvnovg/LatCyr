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

    func testTotalCapHoldsOnWritesAfterLimitIsLowered() {
        let logger = FileLogger(directory: dir, maxTotalBytes: 500)
        for _ in 0..<50 { logger.write(line9) } // fills all five files exactly
        logger.setMaxTotalBytes(200)            // 40 per file now
        for i in 0..<100 {
            logger.write(line9)
            logger.flush()
            let found = files()
            let total = found.values.reduce(0, +)
            XCTAssertLessThanOrEqual(total, 200, "after write \(i): \(found)")
            XCTAssertLessThanOrEqual(found.count, 5, "after write \(i): \(found)")
        }
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

    func testRotatedCurrentFileBeginsWithHeader() throws {
        let logger = FileLogger(directory: dir, maxTotalBytes: 500) // 100 per file
        logger.setHeader(["H1", "H2"])                              // 6 bytes
        for _ in 0..<15 { logger.write(line9) }                     // forces a rotation
        logger.flush()
        let current = try String(contentsOf: dir.appendingPathComponent("latcyr.log"), encoding: .utf8)
        XCTAssertTrue(current.hasPrefix("H1\nH2\n" + line9 + "\n"), current)
        XCTAssertNotNil(files()["latcyr.1.log"])
    }

    func testHeaderIsWrittenAfterRotationCausedByLoweringLimit() throws {
        let logger = FileLogger(directory: dir, maxTotalBytes: 500)
        logger.setHeader(["H"])
        for _ in 0..<5 { logger.write(line9) }   // 50 bytes, no rotation
        logger.setMaxTotalBytes(200)             // 40 per file: current is rotated away
        logger.write("a")
        logger.flush()
        let current = try String(contentsOf: dir.appendingPathComponent("latcyr.log"), encoding: .utf8)
        XCTAssertEqual(current, "H\na\n")
    }

    func testRotationWhileLoggingOffDoesNotWriteHeaderTwiceOnReenable() throws {
        let logger = FileLogger(directory: dir, maxTotalBytes: 500)
        logger.setHeader(["H"])
        for _ in 0..<5 { logger.write(line9) }
        logger.setMaxTotalBytes(200)   // rotates, headerPending = true
        logger.close()                 // logging switched off
        // off -> on, as LogController does it: close, setHeader, then the
        // header block itself written as ordinary lines.
        logger.close()
        logger.setHeader(["H"])
        logger.write("H")
        logger.write("a")
        logger.flush()
        let current = try String(contentsOf: dir.appendingPathComponent("latcyr.log"), encoding: .utf8)
        XCTAssertEqual(current, "H\na\n")
    }

    func testTotalCapHoldsWithRepeatedHeader() {
        let logger = FileLogger(directory: dir, maxTotalBytes: 500) // 100 per file
        logger.setHeader(["header-line-1", "header-line-2"])       // 28 bytes
        for i in 0..<200 {
            logger.write(line9)
            logger.flush()
            let found = files()
            XCTAssertLessThanOrEqual(found.values.reduce(0, +), 500, "after write \(i): \(found)")
            XCTAssertTrue(found.values.allSatisfy { $0 <= 100 }, "after write \(i): \(found)")
        }
    }

    func testHeaderSkippedWhenItWouldNotFitWithTheLine() throws {
        let logger = FileLogger(directory: dir, maxTotalBytes: 50) // 10 per file
        logger.setHeader(["HEADER"])                               // 7 bytes
        logger.write(line9)
        logger.write(line9)                                        // rotates; 7 + 10 > 10
        logger.flush()
        let current = try String(contentsOf: dir.appendingPathComponent("latcyr.log"), encoding: .utf8)
        XCTAssertEqual(current, line9 + "\n")
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
