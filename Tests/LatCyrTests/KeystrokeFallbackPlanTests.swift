import XCTest
@testable import LatCyr

final class KeystrokeFallbackPlanTests: XCTestCase {
    // The boundary key has landed on screen by the time the fallback runs,
    // so it is deleted along with the span and typed back.
    func testNothingTypedSinceBoundary() {
        let plan = KeystrokeFallbackPlan(span: "ghbdtn", converted: "привет", boundary: " ", tail: "", convertedTail: "")
        XCTAssertEqual(plan.deleteCount, 7)
        XCTAssertEqual(plan.typed, "привет ")
    }

    // A letter typed during correctionDelay sits after the boundary. It was
    // typed under the same wrong layout as the span, so it is deleted and
    // retyped converted — not eaten ("ghbdtn v" → "gпривет ").
    func testTailTypedDuringDelayIsDeletedAndRetypedConverted() {
        let plan = KeystrokeFallbackPlan(span: "ghbdtn", converted: "привет", boundary: " ", tail: "v", convertedTail: "м")
        XCTAssertEqual(plan.deleteCount, 8)
        XCTAssertEqual(plan.typed, "привет м")
    }

    func testCarriedSpanWithTail() {
        let plan = KeystrokeFallbackPlan(span: "d ghbdtn", converted: "в привет", boundary: ",", tail: "rj", convertedTail: "ко")
        XCTAssertEqual(plan.deleteCount, 11)
        XCTAssertEqual(plan.typed, "в привет,ко")
    }

    // The tail is known only when every keyDown since the boundary went
    // into the word buffer: then the buffer is exactly the screen's tail.
    func testTailIsTheBufferWhenEveryKeySinceBoundaryWentIntoIt() {
        XCTAssertEqual(KeystrokeFallbackPlan.tail(buffer: "v", keyDownsSinceBoundary: 1, keyDownsInBuffer: 1), "v")
        XCTAssertEqual(KeystrokeFallbackPlan.tail(buffer: "vb", keyDownsSinceBoundary: 2, keyDownsInBuffer: 2), "vb")
    }

    func testNoKeysSinceBoundaryMeansEmptyTail() {
        XCTAssertEqual(KeystrokeFallbackPlan.tail(buffer: "", keyDownsSinceBoundary: 0, keyDownsInBuffer: 0), "")
    }

    // A letter typed and erased again: two keyDowns, both in the buffer's
    // history, and the screen tail is empty — still known.
    func testTypedAndErasedTailIsEmptyButKnown() {
        XCTAssertEqual(KeystrokeFallbackPlan.tail(buffer: "", keyDownsSinceBoundary: 2, keyDownsInBuffer: 2), "")
    }

    // A second boundary, an arrow key, a shortcut or a Backspace past the
    // word's start resets the buffer (or leaves it) without describing what
    // it did to the screen: the fallback must not delete blind.
    func testKeyOutsideTheBufferMakesTailUnknown() {
        XCTAssertNil(KeystrokeFallbackPlan.tail(buffer: "", keyDownsSinceBoundary: 1, keyDownsInBuffer: 0))
        XCTAssertNil(KeystrokeFallbackPlan.tail(buffer: "v", keyDownsSinceBoundary: 2, keyDownsInBuffer: 1))
        XCTAssertNil(KeystrokeFallbackPlan.tail(buffer: "", keyDownsSinceBoundary: 3, keyDownsInBuffer: 0))
    }
}
