import XCTest
@testable import LatCyr

/// `extendRange` is the pure widening step behind `extendAnchor`: given the
/// on-screen text as UTF-16 and a range anchored on the just-corrected word,
/// it walks backward over the carried chain and returns the widened start —
/// or nil if the text doesn't actually match the chain. No AX call is
/// involved, so it's tested directly here rather than only through manual
/// verification.
final class ExtendRangeTests: XCTestCase {
    private let controller = TextFieldController()

    private func utf16(_ s: String) -> [UInt16] { Array(s.utf16) }

    // MARK: - Happy path

    func testSingleCarriedWordAtStartOfText() {
        // "d ujhjl" — anchor covers "ujhjl", carried is ["d"].
        let text = "d ujhjl"
        let units = utf16(text)
        let anchorStart = text.utf16.count - "ujhjl".utf16.count
        let range = anchorStart..<units.count
        let start = controller.extendRange(range, backwardOver: ["d"], in: units, variant: .pc)
        XCTAssertEqual(start, 0)
    }

    func testTwoCarriedWordsAfterOtherTextPlusSeparator() {
        // "hello b d ujhjl" — anchor covers "ujhjl", carried is ["b", "d"].
        let text = "hello b d ujhjl"
        let units = utf16(text)
        let anchorStart = text.utf16.count - "ujhjl".utf16.count
        let range = anchorStart..<units.count
        let start = controller.extendRange(range, backwardOver: ["b", "d"], in: units, variant: .pc)
        // Widened start should sit right after "hello " (before "b").
        let expected = "hello ".utf16.count
        XCTAssertEqual(start, expected)
    }

    func testCaseInsensitiveMatchOfCarriedWord() {
        let text = "D ujhjl"
        let units = utf16(text)
        let anchorStart = text.utf16.count - "ujhjl".utf16.count
        let range = anchorStart..<units.count
        let start = controller.extendRange(range, backwardOver: ["d"], in: units, variant: .pc)
        XCTAssertEqual(start, 0)
    }

    // MARK: - Regression: must not match the suffix of a longer on-screen word

    /// Reproduction: user has "наш world" on screen (a real word "наш", not
    /// a carried "ш"). A stale chain ["ш"] must not widen the anchor into
    /// the middle of "наш" just because its last character matches "ш" and
    /// is preceded by a space.
    func testDoesNotMatchSuffixOfLongerWord() {
        let text = "наш цщкв"
        let units = utf16(text)
        let anchorStart = text.utf16.count - "цщкв".utf16.count
        let range = anchorStart..<units.count
        let start = controller.extendRange(range, backwardOver: ["ш"], in: units, variant: .pc)
        XCTAssertNil(start, "must not widen into the middle of «наш»")
    }

    // MARK: - Mismatches return nil

    func testMissingSeparatorReturnsNil() {
        // "dujhjl" has no space before the anchored word at all.
        let text = "dujhjl"
        let units = utf16(text)
        let anchorStart = text.utf16.count - "ujhjl".utf16.count
        let range = anchorStart..<units.count
        let start = controller.extendRange(range, backwardOver: ["d"], in: units, variant: .pc)
        XCTAssertNil(start)
    }

    func testDoubledSeparatorReturnsNil() {
        // "d  ujhjl" — two spaces between the carried word and the anchor.
        let text = "d  ujhjl"
        let units = utf16(text)
        let anchorStart = text.utf16.count - "ujhjl".utf16.count
        let range = anchorStart..<units.count
        let start = controller.extendRange(range, backwardOver: ["d"], in: units, variant: .pc)
        XCTAssertNil(start)
    }

    func testEmptyCarriedWordReturnsNil() {
        let text = " ujhjl"
        let units = utf16(text)
        let anchorStart = text.utf16.count - "ujhjl".utf16.count
        let range = anchorStart..<units.count
        let start = controller.extendRange(range, backwardOver: [""], in: units, variant: .pc)
        XCTAssertNil(start)
    }

    func testMismatchedCarriedWordReturnsNil() {
        let text = "c ujhjl"
        let units = utf16(text)
        let anchorStart = text.utf16.count - "ujhjl".utf16.count
        let range = anchorStart..<units.count
        let start = controller.extendRange(range, backwardOver: ["d"], in: units, variant: .pc)
        XCTAssertNil(start)
    }
}
