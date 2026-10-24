import XCTest
@testable import LatCyr

final class TextConverterTests: XCTestCase {
    func testToCyrillicBasic() {
        XCTAssertEqual(TextConverter.toCyrillic("ghbdtn", variant: .pc), "привет")
    }

    func testToLatinBasic() {
        XCTAssertEqual(TextConverter.toLatin("руддщ", variant: .pc), "hello")
    }

    func testToCyrillicPreservesCase() {
        XCTAssertEqual(TextConverter.toCyrillic("Ghbdtn", variant: .pc), "Привет")
        XCTAssertEqual(TextConverter.toCyrillic("GHBDTN", variant: .pc), "ПРИВЕТ")
    }

    func testToLatinPreservesCase() {
        XCTAssertEqual(TextConverter.toLatin("Руддщ", variant: .pc), "Hello")
        XCTAssertEqual(TextConverter.toLatin("РУДДЩ", variant: .pc), "HELLO")
    }

    func testDigitsAndSymbolsUntouched() {
        XCTAssertEqual(TextConverter.toCyrillic("ghbdtn123", variant: .pc), "привет123")
        XCTAssertEqual(TextConverter.toLatin("привет!", variant: .pc), "ghbdtn!")
    }

    func testAllLettersRoundTripPC() {
        let latin = "`qwertyuiop[]asdfghjkl;'zxcvbnm,./"
        let cyrillic = "ёйцукенгшщзхъфывапролджэячсмитьбю."
        XCTAssertEqual(TextConverter.toCyrillic(latin, variant: .pc), cyrillic)
        XCTAssertEqual(TextConverter.toLatin(cyrillic, variant: .pc), latin)
    }

    func testYoCasePC() {
        XCTAssertEqual(TextConverter.toCyrillic("~", variant: .pc), "Ё")
        XCTAssertEqual(TextConverter.toLatin("Ё", variant: .pc), "~")
    }

    // "Russian" (Apple's own layout, not "Russian - PC"): the 26 letters +
    // [/] are identical to .pc, but ё/Ё live on \/| instead of `/~, and `
    // and / pass through unchanged — verified against a real Mac with
    // "Russian" active (see docs/superpowers/specs/2026-08-13-russian-keyboard-variant-design.md).
    func testAllLettersRoundTripApple() {
        let latin = "qwertyuiop[]asdfghjkl;'zxcvbnm,.\\"
        let cyrillic = "йцукенгшщзхъфывапролджэячсмитьбюё"
        XCTAssertEqual(TextConverter.toCyrillic(latin, variant: .apple), cyrillic)
        XCTAssertEqual(TextConverter.toLatin(cyrillic, variant: .apple), latin)
    }

    func testYoCaseApple() {
        XCTAssertEqual(TextConverter.toCyrillic("|", variant: .apple), "Ё")
        XCTAssertEqual(TextConverter.toLatin("Ё", variant: .apple), "|")
    }

    // The two variants' overlay keys must not leak into each other.
    func testVariantsDoNotCrossContaminate() {
        // Under .pc, "\" isn't mapped — stays "\" (no ё).
        XCTAssertEqual(TextConverter.toCyrillic("\\", variant: .pc), "\\")
        // Under .apple, "`" isn't mapped — stays "`" (no ё).
        XCTAssertEqual(TextConverter.toCyrillic("`", variant: .apple), "`")
        // Under .apple, "/" isn't remapped at all (unlike .pc, where it's ".").
        XCTAssertEqual(TextConverter.toCyrillic("/", variant: .apple), "/")
        XCTAssertEqual(TextConverter.toCyrillic("/", variant: .pc), ".")
    }

    // MARK: - applyingCase

    func testApplyingCaseKeepsAutoCapitalisedFirstLetter() {
        // macOS auto-capitalised the typed "d"; the buffer conversion is lowercase.
        XCTAssertEqual(TextConverter.applyingCase(of: "D ckexft", to: "в случае"), "В случае")
    }

    func testApplyingCaseMirrorsEveryLetter() {
        XCTAssertEqual(TextConverter.applyingCase(of: "ghbDTN", to: "привет"), "приВЕТ")
        XCTAssertEqual(TextConverter.applyingCase(of: "ПРИвет", to: "GHBDTN"), "GHBdtn")
    }

    func testApplyingCaseLeavesNonLetterPositionsAlone() {
        // "<" and "," are the б key; they carry no case on screen.
        XCTAssertEqual(TextConverter.applyingCase(of: "<s", to: "Бы"), "Бы")
        XCTAssertEqual(TextConverter.applyingCase(of: ",s", to: "бы"), "бы")
        XCTAssertEqual(TextConverter.applyingCase(of: "z ns", to: "Я ты"), "я ты")
    }

    func testApplyingCaseHandlesYo() {
        XCTAssertEqual(TextConverter.applyingCase(of: "`ж", to: "ёж"), "ёж")
        XCTAssertEqual(TextConverter.applyingCase(of: "Tot", to: "еще"), "Еще")
    }

    func testApplyingCaseReturnsReplacementWhenLengthsDiffer() {
        XCTAssertEqual(TextConverter.applyingCase(of: "Ab", to: "абв"), "абв")
    }

    func testApplyingCaseKeepsCharacterThatWouldWiden() {
        XCTAssertEqual(TextConverter.applyingCase(of: "A", to: "ß"), "ß")
    }

    // MARK: - Shifted punctuation keys (capital Б Ю Ж Э Х Ъ)

    private let shiftedPairs: [(String, String)] = [
        ("<", "Б"), (">", "Ю"), (":", "Ж"), ("\"", "Э"), ("{", "Х"), ("}", "Ъ"),
    ]

    func testShiftedKeysConvertBothWaysInBothVariants() {
        for variant in [TextConverter.RussianKeyboardVariant.pc, .apple] {
            for (latin, cyrillic) in shiftedPairs {
                XCTAssertEqual(TextConverter.toCyrillic(latin, variant: variant), cyrillic, "\(latin) \(variant)")
                XCTAssertEqual(TextConverter.toLatin(cyrillic, variant: variant), latin, "\(cyrillic) \(variant)")
            }
        }
    }

    func testLowercasePunctuationPairsUnchanged() {
        for variant in [TextConverter.RussianKeyboardVariant.pc, .apple] {
            XCTAssertEqual(TextConverter.toLatin("б", variant: variant), ",", "\(variant)")
            XCTAssertEqual(TextConverter.toLatin("Б", variant: variant), "<", "\(variant)")
            XCTAssertEqual(TextConverter.toCyrillic(",", variant: variant), "б", "\(variant)")
            XCTAssertEqual(TextConverter.toCyrillic("<", variant: variant), "Б", "\(variant)")
        }
    }

    // Ё sits on the shifted key of each variant's ё key, alongside the new
    // pairs; both cases survive a round trip.
    func testYoOnItsShiftedKeyRoundTripsPerVariant() {
        let cases: [(TextConverter.RussianKeyboardVariant, String, String)] = [
            (.pc, "~", "`"), (.apple, "|", "\\"),
        ]
        for (variant, shifted, plain) in cases {
            XCTAssertEqual(TextConverter.toLatin(TextConverter.toCyrillic(shifted, variant: variant), variant: variant), shifted, "\(variant)")
            XCTAssertEqual(TextConverter.toCyrillic(TextConverter.toLatin("Ё", variant: variant), variant: variant), "Ё", "\(variant)")
            XCTAssertEqual(TextConverter.toLatin("ё", variant: variant), plain, "\(variant)")
            XCTAssertEqual(TextConverter.toCyrillic("\(shifted)<\(plain)", variant: variant), "ЁБё", "\(variant)")
        }
    }

    func testShiftedWordsBothDirections() {
        XCTAssertEqual(TextConverter.toLatin("БвшмЮ", variant: .pc), "<div>")
        XCTAssertEqual(TextConverter.toLatin("цщкдвЖ", variant: .apple), "world:")
        XCTAssertEqual(TextConverter.toCyrillic("{jhjij", variant: .pc), "Хорошо")
    }

    func testShiftedSymbolsAreAmbiguousLetterSymbols() {
        for variant in [TextConverter.RussianKeyboardVariant.pc, .apple] {
            let shifted = TextConverter.shiftedLetterSymbols(for: variant)
            XCTAssertTrue(shifted.isSubset(of: TextConverter.ambiguousLetterSymbols(for: variant)))
            XCTAssertTrue(shifted.isSuperset(of: ["<", ">", ":", "\"", "{", "}"]))
        }
        XCTAssertTrue(TextConverter.shiftedLetterSymbols(for: .pc).contains("~"))
        XCTAssertFalse(TextConverter.shiftedLetterSymbols(for: .pc).contains("|"))
        XCTAssertTrue(TextConverter.shiftedLetterSymbols(for: .apple).contains("|"))
        XCTAssertFalse(TextConverter.shiftedLetterSymbols(for: .apple).contains("~"))
    }

    // The punctuation key that ends a word typed in the English layout but
    // meant as Russian was pressed for the Russian layout too: Shift+6 is the
    // comma of «Russian». Pairs read from the system layouts with
    // UCKeyTranslate (ABC against Russian and RussianWin), shifted digit row
    // and the "/" key only — the ` and § keys depend on the keyboard type.
    func testRussianReadingOfBoundaryPerVariant() {
        let apple: [Character: Character] = ["@": "\"", "#": "№", "$": "%", "^": ",", "%": ":", "&": ".", "*": ";"]
        let pc: [Character: Character] = ["@": "\"", "#": "№", "$": ";", "^": ":", "&": "?", "/": ".", "?": ",", "|": "/"]
        for (typed, meant) in apple {
            XCTAssertEqual(TextConverter.russianReading(ofBoundary: typed, variant: .apple), meant, "\(typed) (apple)")
        }
        for (typed, meant) in pc {
            XCTAssertEqual(TextConverter.russianReading(ofBoundary: typed, variant: .pc), meant, "\(typed) (pc)")
        }
    }

    // Keys that print the same in both layouts, and keys the other variant
    // leaves alone, keep the boundary as typed.
    func testRussianReadingOfBoundaryKeepsSharedKeys() {
        for ch: Character in [" ", "!", "(", ")", "-", "_", "=", "+", "1", "0", "\n", "\t"] {
            XCTAssertEqual(TextConverter.russianReading(ofBoundary: ch, variant: .apple), ch)
            XCTAssertEqual(TextConverter.russianReading(ofBoundary: ch, variant: .pc), ch)
        }
        for ch: Character in ["/", "?", "|"] {
            XCTAssertEqual(TextConverter.russianReading(ofBoundary: ch, variant: .apple), ch)
        }
        for ch: Character in ["%", "*"] {
            XCTAssertEqual(TextConverter.russianReading(ofBoundary: ch, variant: .pc), ch)
        }
    }
}
