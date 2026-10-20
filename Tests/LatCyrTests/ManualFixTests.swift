import XCTest
@testable import LatCyr

final class ManualFixTests: XCTestCase {
    func testLatinTypedRussianWordBecomesCyrillic() {
        XCTAssertEqual(ManualFix.plan(for: "ubarf", variant: .pc), .init(replacement: "гифка", exception: "гифка"))
        XCTAssertEqual(ManualFix.plan(for: "ubarf", variant: .apple), .init(replacement: "гифка", exception: "гифка"))
    }

    func testPunctuationKeysThatAreRussianLetters() {
        // ";" is the ж key, "," the б key.
        XCTAssertEqual(ManualFix.plan(for: "ckj;yj", variant: .pc)?.replacement, "сложно")
        XCTAssertEqual(ManualFix.plan(for: ",s", variant: .pc)?.replacement, "бы")
    }

    func testCyrillicTypedEnglishWordBecomesLatin() {
        XCTAssertEqual(ManualFix.plan(for: "пше", variant: .pc), .init(replacement: "git", exception: "git"))
    }

    func testCaseIsKeptInReplacementAndLoweredInException() {
        XCTAssertEqual(ManualFix.plan(for: "Ubarf", variant: .pc), .init(replacement: "Гифка", exception: "гифка"))
        XCTAssertEqual(ManualFix.plan(for: "Пше", variant: .pc), .init(replacement: "Git", exception: "git"))
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(ManualFix.plan(for: " ubarf\n", variant: .pc)?.replacement, "гифка")
    }

    func testRejectsSeveralWords() {
        XCTAssertNil(ManualFix.plan(for: "ubarf yflj", variant: .pc))
    }

    func testRejectsMixedAlphabets() {
        // Cyrillic "а" inside a Latin word.
        XCTAssertNil(ManualFix.plan(for: "ubаrf", variant: .pc))
    }

    func testRejectsDigits() {
        XCTAssertNil(ManualFix.plan(for: "ubar1", variant: .pc))
    }

    func testRejectsResultWithPunctuation() {
        // "ж" converts to ";" — not a valid Latin word.
        XCTAssertNil(ManualFix.plan(for: "жук", variant: .pc))
    }

    func testRejectsEmpty() {
        XCTAssertNil(ManualFix.plan(for: "", variant: .pc))
        XCTAssertNil(ManualFix.plan(for: "  ", variant: .pc))
    }
}
