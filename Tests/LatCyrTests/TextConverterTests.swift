import XCTest
@testable import LatCyr

final class TextConverterTests: XCTestCase {
    func testToCyrillicBasic() {
        XCTAssertEqual(TextConverter.toCyrillic("ghbdtn"), "привет")
    }

    func testToLatinBasic() {
        XCTAssertEqual(TextConverter.toLatin("руддщ"), "hello")
    }

    func testToCyrillicPreservesCase() {
        XCTAssertEqual(TextConverter.toCyrillic("Ghbdtn"), "Привет")
        XCTAssertEqual(TextConverter.toCyrillic("GHBDTN"), "ПРИВЕТ")
    }

    func testToLatinPreservesCase() {
        XCTAssertEqual(TextConverter.toLatin("Руддщ"), "Hello")
        XCTAssertEqual(TextConverter.toLatin("РУДДЩ"), "HELLO")
    }

    func testDigitsAndSymbolsUntouched() {
        XCTAssertEqual(TextConverter.toCyrillic("ghbdtn123"), "привет123")
        XCTAssertEqual(TextConverter.toLatin("привет!"), "ghbdtn!")
    }

    func testAllLettersRoundTrip() {
        let latin = "qwertyuiop[]asdfghjkl;'zxcvbnm,./"
        let cyrillic = "йцукенгшщзхъфывапролджэячсмитьбю."
        XCTAssertEqual(TextConverter.toCyrillic(latin), cyrillic)
        XCTAssertEqual(TextConverter.toLatin(cyrillic), latin)
    }
}
