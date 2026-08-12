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
}
