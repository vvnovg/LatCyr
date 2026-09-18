import XCTest
@testable import LatCyr

final class ExceptionWordTests: XCTestCase {
    func testLatinWord() {
        XCTAssertEqual(ExceptionWord.normalized(from: "http"), "http")
    }

    func testCyrillicWord() {
        XCTAssertEqual(ExceptionWord.normalized(from: "привет"), "привет")
    }

    func testCyrillicYo() {
        XCTAssertEqual(ExceptionWord.normalized(from: "ёлка"), "ёлка")
    }

    func testLowercasesUpperAndMixedCase() {
        XCTAssertEqual(ExceptionWord.normalized(from: "HTTP"), "http")
        XCTAssertEqual(ExceptionWord.normalized(from: "HtTp"), "http")
        XCTAssertEqual(ExceptionWord.normalized(from: "Привет"), "привет")
    }

    func testTrimsSurroundingWhitespaceAndNewline() {
        // Копия строки из терминала обычно несёт хвостовой перевод строки.
        XCTAssertEqual(ExceptionWord.normalized(from: "  http\n"), "http")
        XCTAssertEqual(ExceptionWord.normalized(from: "\thttp\t"), "http")
        // U+00A0 NO-BREAK SPACE — категория Zs, входит в .whitespacesAndNewlines.
        XCTAssertEqual(ExceptionWord.normalized(from: "\u{00A0}http\u{00A0}"), "http")
    }

    func testRejectsMixedScripts() {
        // "hеllo": «е» здесь кириллическая U+0435, а не латинская "e".
        XCTAssertNil(ExceptionWord.normalized(from: "h\u{0435}llo"))
    }

    func testRejectsDigitsAndPunctuation() {
        XCTAssertNil(ExceptionWord.normalized(from: "http2"))
        XCTAssertNil(ExceptionWord.normalized(from: "http."))
        XCTAssertNil(ExceptionWord.normalized(from: "well-known"))
        XCTAssertNil(ExceptionWord.normalized(from: "youtube.com"))
    }

    func testRejectsMultipleWords() {
        XCTAssertNil(ExceptionWord.normalized(from: "hello world"))
    }

    func testRejectsEmptyAndWhitespaceOnly() {
        XCTAssertNil(ExceptionWord.normalized(from: ""))
        XCTAssertNil(ExceptionWord.normalized(from: "   \n"))
    }

    func testUppercaseYoLowercasesToCyrillicYo() {
        // U+0401 (Ё) -> U+0451 (ё) — единственный кириллический регистр,
        // который не является простым сдвигом кодовой точки.
        XCTAssertEqual(ExceptionWord.normalized(from: "Ёлка"), "ёлка")
        XCTAssertEqual(ExceptionWord.normalized(from: "ЁЛКА"), "ёлка")
    }

    func testTrimsCRLF() {
        // Буквальная форма копии из терминала Windows/VS Code.
        XCTAssertEqual(ExceptionWord.normalized(from: "http\r\n"), "http")
    }

    func testStripsInvisibleCharacters() {
        // Веб- и Electron-копии чаще несут эти невидимые символы, чем
        // неразрывный пробел: .whitespacesAndNewlines их не покрывает.
        // U+200B ZERO WIDTH SPACE.
        XCTAssertEqual(ExceptionWord.normalized(from: "\u{200B}http\u{200B}"), "http")
        // U+FEFF ZERO WIDTH NO-BREAK SPACE (BOM).
        XCTAssertEqual(ExceptionWord.normalized(from: "\u{FEFF}http"), "http")
        // U+00AD SOFT HYPHEN.
        XCTAssertEqual(ExceptionWord.normalized(from: "ht\u{00AD}tp"), "http")
    }
}
