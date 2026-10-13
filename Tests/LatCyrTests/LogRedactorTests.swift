import XCTest
@testable import LatCyr

final class LogRedactorTests: XCTestCase {
    func testCyrillic() {
        XCTAssertEqual(LogRedactor.redact("привет"), "[6 cyr]")
    }

    func testCyrillicYo() {
        XCTAssertEqual(LogRedactor.redact("ёлка"), "[4 cyr]")
    }

    func testLatin() {
        XCTAssertEqual(LogRedactor.redact("hello"), "[5 lat]")
    }

    func testMixed() {
        XCTAssertEqual(LogRedactor.redact("hпривет"), "[7 mix]")
    }

    func testNoLetters() {
        XCTAssertEqual(LogRedactor.redact(",.;"), "[3 none]")
    }

    func testEmpty() {
        XCTAssertEqual(LogRedactor.redact(""), "[0 none]")
    }

    func testSymbolsDoNotChangeAlphabet() {
        // Wrong-layout Latin for "ваше" contains ';' — still a Latin word.
        XCTAssertEqual(LogRedactor.redact("dfie;"), "[5 lat]")
    }

    func testLengthCountsCharactersNotScalars() {
        // "e" + combining acute accent is one Character.
        XCTAssertEqual(LogRedactor.redact("e\u{301}"), "[1 lat]")
    }

    func testSensitiveDescriptionIsAlwaysRedacted() {
        XCTAssertEqual("\(Sensitive("секрет"))", "[6 cyr]")
        XCTAssertEqual(String(describing: Sensitive("secret")), "[6 lat]")
    }
}
