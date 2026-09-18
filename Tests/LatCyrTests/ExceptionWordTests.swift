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
}
