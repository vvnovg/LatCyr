import XCTest
@testable import LatCyr

final class DoubleShiftDetectorTests: XCTestCase {
    private var detector = DoubleShiftDetector()

    /// Feeds a sequence of (input, time) and returns the index of every event that fired.
    private func fired(_ events: [(DoubleShiftDetector.Input, TimeInterval)]) -> [Int] {
        var result: [Int] = []
        for (index, event) in events.enumerated() where detector.feed(event.0, at: event.1) {
            result.append(index)
        }
        return result
    }

    func testQuickDoubleShiftFiresOnSecondRelease() {
        XCTAssertEqual(fired([(.shiftDown, 0), (.shiftUp, 0.1), (.shiftDown, 0.2), (.shiftUp, 0.3)]), [3])
    }

    func testSlowPressDoesNotFire() {
        XCTAssertEqual(fired([(.shiftDown, 0), (.shiftUp, 0.5), (.shiftDown, 0.6), (.shiftUp, 0.7)]), [])
    }

    func testSlowSecondPressDoesNotFire() {
        XCTAssertEqual(fired([(.shiftDown, 0), (.shiftUp, 0.1), (.shiftDown, 0.2), (.shiftUp, 0.6)]), [])
    }

    func testLongGapDoesNotFire() {
        XCTAssertEqual(fired([(.shiftDown, 0), (.shiftUp, 0.1), (.shiftDown, 0.5), (.shiftUp, 0.6)]), [])
    }

    func testLongGapStartsANewPairThatCanFire() {
        // The late press is the first press of a fresh pair.
        XCTAssertEqual(fired([
            (.shiftDown, 0), (.shiftUp, 0.1),
            (.shiftDown, 0.5), (.shiftUp, 0.6), (.shiftDown, 0.7), (.shiftUp, 0.8),
        ]), [5])
    }

    func testShiftForCapitalLetterDoesNotCount() {
        // Shift+G, then a lone Shift: the letter breaks the pair.
        XCTAssertEqual(fired([
            (.shiftDown, 0), (.otherKey, 0.05), (.shiftUp, 0.1),
            (.shiftDown, 0.2), (.shiftUp, 0.3),
        ]), [])
    }

    func testOtherKeyBetweenPressesResets() {
        XCTAssertEqual(fired([(.shiftDown, 0), (.shiftUp, 0.1), (.otherKey, 0.15), (.shiftDown, 0.2), (.shiftUp, 0.3)]), [])
    }

    func testTripleShiftFiresOnce() {
        XCTAssertEqual(fired([
            (.shiftDown, 0), (.shiftUp, 0.1), (.shiftDown, 0.2), (.shiftUp, 0.3),
            (.shiftDown, 0.4), (.shiftUp, 0.5),
        ]), [3])
    }

    func testFourQuickPressesFireTwice() {
        XCTAssertEqual(fired([
            (.shiftDown, 0), (.shiftUp, 0.1), (.shiftDown, 0.2), (.shiftUp, 0.3),
            (.shiftDown, 0.4), (.shiftUp, 0.5), (.shiftDown, 0.6), (.shiftUp, 0.7),
        ]), [3, 7])
    }

    func testStrayReleaseIsIgnored() {
        // A release with no press seen (tap started while Shift was held).
        XCTAssertEqual(fired([(.shiftUp, 0), (.shiftDown, 0.1), (.shiftUp, 0.2), (.shiftDown, 0.3), (.shiftUp, 0.4)]), [4])
    }
}
