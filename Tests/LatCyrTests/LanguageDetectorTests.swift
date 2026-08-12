import XCTest
@testable import LatCyr

final class LanguageDetectorTests: XCTestCase {
    // Russian typed in English layout → detect
    func testRussianTypedInEnglishLayout() {
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ghbdtn", currentLayoutIsRussian: false, exceptions: [])) // привет
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "vbh", currentLayoutIsRussian: false, exceptions: []))     // мир
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ntcn", currentLayoutIsRussian: false, exceptions: []))    // тест
    }

    // Words containing letters typed via a punctuation key (ё, х, ъ, ж, э,
    // б, ю share a physical key with `, [, ], ;, ', ,, .) must still be
    // detected as a whole, not cut short at the punctuation character.
    func testWordWithAmbiguousPunctuationLetter() {
        XCTAssertEqual(TextConverter.toCyrillic("ndj.", variant: .pc), "твою")
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ndj.", currentLayoutIsRussian: false, exceptions: [])) // твою
    }

    // English typed in Russian layout → detect
    func testEnglishTypedInRussianLayout() {
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "руддщ", currentLayoutIsRussian: true, exceptions: []))   // hello
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "цщкду", currentLayoutIsRussian: true, exceptions: []))   // world
    }

    // Correct words → never touch
    func testCorrectWordsNotTouched() {
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "hello", currentLayoutIsRussian: false, exceptions: []))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "the", currentLayoutIsRussian: false, exceptions: []))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "world", currentLayoutIsRussian: false, exceptions: []))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "привет", currentLayoutIsRussian: true, exceptions: []))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "мир", currentLayoutIsRussian: true, exceptions: []))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "тест", currentLayoutIsRussian: true, exceptions: []))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "следующий", currentLayoutIsRussian: true, exceptions: []))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "здравствуйте", currentLayoutIsRussian: true, exceptions: []))
    }

    // Short words → never touch
    func testShortWordsNotTouched() {
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "vb", currentLayoutIsRussian: false, exceptions: []))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "gh", currentLayoutIsRussian: false, exceptions: []))
    }

    // Words with digits → never touch
    func testWordsWithDigitsNotTouched() {
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "ghbdtn123", currentLayoutIsRussian: false, exceptions: []))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "привет1", currentLayoutIsRussian: true, exceptions: []))
    }

    // Exception words — a Latin exception overrides the score heuristic in
    // both directions. "sdd" typed correctly under the English layout is a
    // real false positive of the plain heuristic (short, consonant-heavy
    // acronyms score ambiguously) — exactly what the whitelist half fixes.
    func testExceptionWordNeverConverted() {
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "sdd", currentLayoutIsRussian: false, exceptions: []))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "sdd", currentLayoutIsRussian: false, exceptions: ["sdd"]))
    }

    // "ssl" mistyped as "ыыд" under the Russian layout (toLatin("ыыд") ==
    // "ssl"): both scores are too low for the ordinary heuristic to catch
    // it — exactly what the forced-correction half fixes.
    func testExceptionWordAlwaysCorrected() {
        XCTAssertEqual(TextConverter.toLatin("ыыд", variant: .pc), "ssl")
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "ыыд", currentLayoutIsRussian: true, exceptions: []))
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ыыд", currentLayoutIsRussian: true, exceptions: ["ssl"]))
    }

    // Same two behaviors, mirrored for a Cyrillic exception word — proves
    // the check isn't hardcoded to Latin-only exceptions.
    func testCyrillicExceptionWordSymmetric() {
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ффф", currentLayoutIsRussian: true, exceptions: []))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "ффф", currentLayoutIsRussian: true, exceptions: ["ффф"]))

        XCTAssertEqual(TextConverter.toCyrillic("dep", variant: .pc), "вуз")
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "dep", currentLayoutIsRussian: false, exceptions: []))
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "dep", currentLayoutIsRussian: false, exceptions: ["вуз"]))
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

    // Proactive: leading "/" while Russian is active signals an about-to-be-
    // typed path (terminal-only scope is enforced in InputMonitor, not here).
    func testProactiveSingleCharSwitchToEnglish() {
        XCTAssertTrue(LanguageDetector.proactiveSingleCharSwitchSignal(first: "/", currentLayoutIsRussian: true))
        XCTAssertFalse(LanguageDetector.proactiveSingleCharSwitchSignal(first: "/", currentLayoutIsRussian: false))
        XCTAssertFalse(LanguageDetector.proactiveSingleCharSwitchSignal(first: "a", currentLayoutIsRussian: true))
    }

    // Scores
    func testScores() {
        XCTAssertGreaterThan(LanguageDetector.russianScore("привет"), 0.4)
        XCTAssertLessThan(LanguageDetector.russianScore("руддщ"), 0.4)
        XCTAssertGreaterThan(LanguageDetector.englishScore("hello"), 0.35)
        XCTAssertLessThan(LanguageDetector.englishScore("ghbdtn"), 0.35)
    }
}
