import XCTest
@testable import LatCyr

final class LogRotationTests: XCTestCase {
    func testPerFileLimitIsAFifth() {
        XCTAssertEqual(LogRotation.perFileLimit(totalLimit: 100 * 1024 * 1024), 20 * 1024 * 1024)
    }

    func testNoRotationWhenLineFitsExactly() {
        XCTAssertFalse(LogRotation.shouldRotate(currentSize: 90, incoming: 10, perFileLimit: 100))
    }

    func testRotationWhenLineOverflows() {
        XCTAssertTrue(LogRotation.shouldRotate(currentSize: 91, incoming: 10, perFileLimit: 100))
    }

    func testEmptyFileNeverRotatesEvenForAnOversizedLine() {
        XCTAssertFalse(LogRotation.shouldRotate(currentSize: 0, incoming: 500, perFileLimit: 100))
    }

    func testNothingDeletedWithinLimit() {
        XCTAssertEqual(LogRotation.filesToDelete(currentSize: 10, rotated: [1: 10, 2: 10], totalLimit: 100), [])
    }

    func testDeletesOldestFirstUntilWithinLimit() {
        let rotated = [1: 20, 2: 20, 3: 20, 4: 20]
        XCTAssertEqual(LogRotation.filesToDelete(currentSize: 10, rotated: rotated, totalLimit: 50), [4, 3])
    }

    func testDeletesAllRotatedWhenCurrentAloneExceeds() {
        XCTAssertEqual(LogRotation.filesToDelete(currentSize: 60, rotated: [1: 10, 2: 10], totalLimit: 50), [2, 1])
    }

    func testHandlesGapsInIndices() {
        XCTAssertEqual(LogRotation.filesToDelete(currentSize: 0, rotated: [1: 30, 3: 30], totalLimit: 40), [3])
    }
}
