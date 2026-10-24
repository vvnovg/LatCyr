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

    // A selection is an explicit choice: every word in it is fixed, and each
    // corrected word is remembered. Live case: "tltn rhsif" selected in Claude
    // Desktop was refused as "not one word".
    func testSeveralSelectedWordsAreFixedTogether() {
        XCTAssertEqual(ManualFix.plan(for: "tltn rhsif", variant: .apple),
                       .init(replacement: "едет крыша", exceptions: ["едет", "крыша"]))
        XCTAssertEqual(ManualFix.plan(for: "Ghbdtn vbh", variant: .pc),
                       .init(replacement: "Привет мир", exceptions: ["привет", "мир"]))
        XCTAssertEqual(ManualFix.plan(for: "ашду ыныеуь", variant: .pc),
                       .init(replacement: "file system", exceptions: ["file", "system"]))
    }

    func testSeparatorsBetweenWordsAreKept() {
        XCTAssertEqual(ManualFix.plan(for: "tltn  rhsif", variant: .pc)?.replacement, "едет  крыша")
        XCTAssertEqual(ManualFix.plan(for: "tltn\trhsif", variant: .pc)?.replacement, "едет\tкрыша")
        XCTAssertEqual(ManualFix.plan(for: " tltn rhsif\n", variant: .pc)?.replacement, "едет крыша")
    }

    // Tokens without a letter (a dash, a number) stay as typed and add no
    // exception; punctuation keys inside a word are still its letters.
    func testTokensWithoutLettersStayAsTyped() {
        XCTAssertEqual(ManualFix.plan(for: "tltn rhsif - ye;ty", variant: .apple),
                       .init(replacement: "едет крыша - нужен", exceptions: ["едет", "крыша", "нужен"]))
        XCTAssertEqual(ManualFix.plan(for: "ckjdj 2 hfpf", variant: .pc)?.replacement, "слово 2 раза")
    }

    func testRepeatedWordIsRememberedOnce() {
        XCTAssertEqual(ManualFix.plan(for: "lf lf", variant: .pc)?.exceptions, ["да"])
    }

    // One direction for the whole selection: a word already in the target
    // alphabet would otherwise be flipped back ("едет rhsif" → "tltn крыша").
    func testRejectsSelectionInBothAlphabets() {
        XCTAssertNil(ManualFix.plan(for: "едет rhsif", variant: .pc))
    }

    // Any word that can't be fixed refuses the whole selection rather than
    // fixing part of it.
    func testRejectsSelectionWithAnUnfixableWord() {
        XCTAssertNil(ManualFix.plan(for: "tltn r2d2", variant: .pc))
        XCTAssertNil(ManualFix.plan(for: "tltn ubаrf", variant: .pc))
    }

    // Double Shift is easy to press by accident; a whole selected paragraph
    // is not converted and does not flood the exceptions.
    func testRejectsTooManyWords() {
        let words = Array(repeating: "lf", count: ManualFix.maxWords)
        XCTAssertNotNil(ManualFix.plan(for: words.joined(separator: " "), variant: .pc))
        XCTAssertNil(ManualFix.plan(for: (words + ["lf"]).joined(separator: " "), variant: .pc))
    }

    func testRejectsOnlyTokensWithoutLetters() {
        XCTAssertNil(ManualFix.plan(for: "- 2", variant: .pc))
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

    // MARK: - Shifted letter keys: the detector's split

    func testTrailingShiftedSymbolStaysPunctuation() {
        XCTAssertEqual(ManualFix.plan(for: "ntrcn:", variant: .pc), .init(replacement: "текст:", exception: "текст"))
    }

    func testWrappingQuotesStayPunctuation() {
        XCTAssertEqual(ManualFix.plan(for: "\"vjq\"", variant: .pc), .init(replacement: "\"мой\"", exception: "мой"))
    }

    func testLeadingShiftedSymbolIsCapitalLetter() {
        XCTAssertEqual(ManualFix.plan(for: "{jhjij", variant: .pc), .init(replacement: "Хорошо", exception: "хорошо"))
    }

    func testOnlyShiftedSymbolsIsRejected() {
        XCTAssertNil(ManualFix.plan(for: "\"::", variant: .pc))
    }
}
