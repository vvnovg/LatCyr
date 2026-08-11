import XCTest
@testable import LatCyr

final class LanguageDetectorTests: XCTestCase {
    // Russian typed in English layout → detect
    func testRussianTypedInEnglishLayout() {
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ghbdtn", currentLayoutIsRussian: false)) // привет
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "vbh", currentLayoutIsRussian: false))     // мир
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ntcn", currentLayoutIsRussian: false))    // тест
    }

    // Words containing letters typed via a punctuation key (ё, х, ъ, ж, э,
    // б, ю share a physical key with `, [, ], ;, ', ,, .) must still be
    // detected as a whole, not cut short at the punctuation character.
    func testWordWithAmbiguousPunctuationLetter() {
        XCTAssertEqual(TextConverter.toCyrillic("ndj."), "твою")
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ndj.", currentLayoutIsRussian: false)) // твою
    }

    // English typed in Russian layout → detect
    func testEnglishTypedInRussianLayout() {
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "руддщ", currentLayoutIsRussian: true))   // hello
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "цщкду", currentLayoutIsRussian: true))   // world
    }

    // Correct words → never touch
    func testCorrectWordsNotTouched() {
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "hello", currentLayoutIsRussian: false))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "the", currentLayoutIsRussian: false))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "world", currentLayoutIsRussian: false))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "привет", currentLayoutIsRussian: true))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "мир", currentLayoutIsRussian: true))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "тест", currentLayoutIsRussian: true))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "следующий", currentLayoutIsRussian: true))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "здравствуйте", currentLayoutIsRussian: true))
    }

    // Short words → never touch
    func testShortWordsNotTouched() {
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "vb", currentLayoutIsRussian: false))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "gh", currentLayoutIsRussian: false))
    }

    // Words with digits → never touch
    func testWordsWithDigitsNotTouched() {
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "ghbdtn123", currentLayoutIsRussian: false))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "привет1", currentLayoutIsRussian: true))
    }

    // Proactive: English layout → Russian
    func testProactiveSwitchToRussian() {
        XCTAssertTrue(LanguageDetector.proactiveSwitchSignal(first: "j", second: "y", currentLayoutIsRussian: false)) // он
        XCTAssertTrue(LanguageDetector.proactiveSwitchSignal(first: "v", second: "f", currentLayoutIsRussian: false)) // ма
        XCTAssertFalse(LanguageDetector.proactiveSwitchSignal(first: "b", second: "y", currentLayoutIsRussian: false)) // by — excluded
        XCTAssertFalse(LanguageDetector.proactiveSwitchSignal(first: "h", second: "e", currentLayoutIsRussian: false)) // he — not strong
    }

    // Proactive: Russian layout → English
    func testProactiveSwitchToEnglish() {
        XCTAssertTrue(LanguageDetector.proactiveSwitchSignal(first: "ф", second: "ш", currentLayoutIsRussian: true))
        XCTAssertFalse(LanguageDetector.proactiveSwitchSignal(first: "а", second: "п", currentLayoutIsRussian: true))
    }

    // Scores
    func testScores() {
        XCTAssertGreaterThan(LanguageDetector.russianScore("привет"), 0.4)
        XCTAssertLessThan(LanguageDetector.russianScore("руддщ"), 0.4)
        XCTAssertGreaterThan(LanguageDetector.englishScore("hello"), 0.35)
        XCTAssertLessThan(LanguageDetector.englishScore("ghbdtn"), 0.35)
    }
}
