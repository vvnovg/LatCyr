import XCTest
@testable import LatCyr

final class LanguageDetectorTests: XCTestCase {
    // Russian typed in English layout → detect
    func testRussianTypedInEnglishLayout() {
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ghbdtn", currentLayoutIsRussian: false, exceptions: [], variant: .pc)) // привет
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "vbh", currentLayoutIsRussian: false, exceptions: [], variant: .pc))     // мир
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ntcn", currentLayoutIsRussian: false, exceptions: [], variant: .pc))    // тест
    }

    // Words containing letters typed via a punctuation key (ё, х, ъ, ж, э,
    // б, ю share a physical key with `, [, ], ;, ', ,, .) must still be
    // detected as a whole, not cut short at the punctuation character.
    func testWordWithAmbiguousPunctuationLetter() {
        XCTAssertEqual(TextConverter.toCyrillic("ndj.", variant: .pc), "твою")
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ndj.", currentLayoutIsRussian: false, exceptions: [], variant: .pc)) // твою
    }

    // English typed in Russian layout → detect
    func testEnglishTypedInRussianLayout() {
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "руддщ", currentLayoutIsRussian: true, exceptions: [], variant: .pc))   // hello
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "цщкду", currentLayoutIsRussian: true, exceptions: [], variant: .pc))   // world
    }

    // Correct words → never touch
    func testCorrectWordsNotTouched() {
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "hello", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "the", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "world", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "привет", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "мир", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "тест", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "следующий", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "здравствуйте", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
    }

    // Short words → never touch
    func testShortWordsNotTouched() {
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "vb", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "gh", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
    }

    // Words with digits → never touch
    func testWordsWithDigitsNotTouched() {
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "ghbdtn123", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "привет1", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
    }

    // Exception words — a Latin exception overrides the score heuristic in
    // both directions. "sdd" typed correctly under the English layout is a
    // real false positive of the plain heuristic (short, consonant-heavy
    // acronyms score ambiguously) — exactly what the whitelist half fixes.
    func testExceptionWordNeverConverted() {
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "sdd", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "sdd", currentLayoutIsRussian: false, exceptions: ["sdd"], variant: .pc))
    }

    // "ssl" mistyped as "ыыд" under the Russian layout (toLatin("ыыд") ==
    // "ssl"): both scores are too low for the ordinary heuristic to catch
    // it — exactly what the forced-correction half fixes.
    func testExceptionWordAlwaysCorrected() {
        XCTAssertEqual(TextConverter.toLatin("ыыд", variant: .pc), "ssl")
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "ыыд", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ыыд", currentLayoutIsRussian: true, exceptions: ["ssl"], variant: .pc))
    }

    // Same two behaviors, mirrored for a Cyrillic exception word — proves
    // the check isn't hardcoded to Latin-only exceptions.
    func testCyrillicExceptionWordSymmetric() {
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ффф", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "ффф", currentLayoutIsRussian: true, exceptions: ["ффф"], variant: .pc))

        XCTAssertEqual(TextConverter.toCyrillic("dep", variant: .pc), "вуз")
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "dep", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "dep", currentLayoutIsRussian: false, exceptions: ["вуз"], variant: .pc))
    }

    // The Russian keyboard variant gates which punctuation keys count as
    // letters (LanguageDetector's own guard, not just TextConverter) —
    // "`" is a letter-producing key only under .pc, "\" only under .apple.
    // Hand-verified: englishScore("h`c") ≈ 0.21 (< 0.35), russianScore of
    // its .pc conversion "рёс" ≈ 0.498 (> 0.4), diff ≈ 0.29 (> 0.1) — a
    // genuine wrong-layout hit once the guard admits the backtick.
    func testRussianVariantGatesAmbiguousLetterGuard() {
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "h`c", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "h`c", currentLayoutIsRussian: false, exceptions: [], variant: .apple))

        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "h\\c", currentLayoutIsRussian: false, exceptions: [], variant: .apple))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "h\\c", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
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

    // A word whose conversion contains punctuation — a domain name — must be
    // scored on its letters alone. "фьфящтюву" is "amazon.de" typed under the
    // Russian layout: the "ю" comes from the "." key but is a Russian vowel
    // with its own frequency weight, and counting it puts russianScore at
    // 0.424 — just over the 0.4 threshold, so the whole correction was
    // dropped. Scored without it the word sits at 0.323 and is corrected in
    // full, dot included.
    func testDomainWithPunctuationDetected() {
        XCTAssertEqual(TextConverter.toLatin("фьфящтюву", variant: .pc), "amazon.de")
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "фьфящтюву", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
    }

    // Domains that already scored correctly must keep doing so: filtering
    // shortens the scored word, and a shorter word must not drift back over
    // a threshold.
    func testDomainsThatAlreadyWorkedStillDetected() {
        XCTAssertEqual(TextConverter.toLatin("пщщпдуюсщь", variant: .pc), "google.com")
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "пщщпдуюсщь", currentLayoutIsRussian: true, exceptions: [], variant: .pc))

        XCTAssertEqual(TextConverter.toLatin("еюьу", variant: .pc), "t.me")
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "еюьу", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
    }

    // The mirror case: a Cyrillic letter that merely *converts* to punctuation
    // is still a real letter of a correctly typed Russian word. Filtering must
    // not turn any of these into a false positive.
    func testCorrectRussianWordsWhoseConversionHasPunctuationNotTouched() {
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "пою", currentLayoutIsRussian: true, exceptions: [], variant: .pc))   // gj.
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "мою", currentLayoutIsRussian: true, exceptions: [], variant: .pc))   // vj.
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "съел", currentLayoutIsRussian: true, exceptions: [], variant: .pc))  // c]tk
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "т.е.", currentLayoutIsRussian: true, exceptions: [], variant: .pc))  // n/t/
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "т.к.", currentLayoutIsRussian: true, exceptions: [], variant: .pc))  // n/r/
    }

    // "ё" sits on a different physical key in each Russian variant ("`" under
    // .pc, "\" under .apple), but both convert to punctuation, so both must be
    // filtered out of scoring — and "объём" stays untouched either way.
    func testPunctuationFilteringHoldsForBothVariants() {
        XCTAssertEqual(TextConverter.toLatin("объём", variant: .pc), "j,]`v")
        XCTAssertEqual(TextConverter.toLatin("объём", variant: .apple), "j,]\\v")
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "объём", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "объём", currentLayoutIsRussian: true, exceptions: [], variant: .apple))
    }

    // Filtering is driven by the conversion, never by the original: under the
    // English layout "," and "]" are the "б" and "ъ" keys, so these words must
    // behave exactly as they did before.
    func testPunctuationInOriginalOnlyStillDetected() {
        XCTAssertEqual(TextConverter.toCyrillic("j,]trn", variant: .pc), "объект")
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "j,]trn", currentLayoutIsRussian: false, exceptions: [], variant: .pc))

        XCTAssertEqual(TextConverter.toCyrillic("ghbdtn,", variant: .pc), "приветб")
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ghbdtn,", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
    }

    // Some domains score as plausible Russian even after punctuation
    // filtering: "нщгегиуюсщь" is "youtube.com", but its filtered form is
    // made of high-frequency Russian letters (н, е, и, у, с) and scores
    // 0.468 — above russianThreshold. A conversion that reads as a domain
    // name is an unconditional signal instead: domains are always Latin.
    func testDomainNameOverridesScoreHeuristic() {
        XCTAssertEqual(TextConverter.toLatin("нщгегиуюсщь", variant: .pc), "youtube.com")
        XCTAssertGreaterThan(LanguageDetector.russianScore("нщгегиусщь"), LanguageDetector.russianThreshold)
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "нщгегиуюсщь", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
    }

    // Real Russian words whose conversion superficially resembles a domain.
    // "воюем" -> "dj.tv" and "клюву" -> "rk.de" are why the rule needs both
    // a curated TLD list and a minimum first-label length — a generic
    // "any 2+ letters after a dot" rule would corrupt all of these.
    func testRussianWordsResemblingDomainsNotTouched() {
        XCTAssertEqual(TextConverter.toLatin("воюем", variant: .pc), "dj.tv")
        XCTAssertEqual(TextConverter.toLatin("горюем", variant: .pc), "ujh.tv")
        XCTAssertEqual(TextConverter.toLatin("клюву", variant: .pc), "rk.de")
        XCTAssertEqual(TextConverter.toLatin("моюся", variant: .pc), "vj.cz")

        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "воюем", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "горюем", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "клюву", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "моюся", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
    }

    // Scores
    func testScores() {
        XCTAssertGreaterThan(LanguageDetector.russianScore("привет"), 0.4)
        XCTAssertLessThan(LanguageDetector.russianScore("руддщ"), 0.4)
        XCTAssertGreaterThan(LanguageDetector.englishScore("hello"), 0.35)
        XCTAssertLessThan(LanguageDetector.englishScore("ghbdtn"), 0.35)
    }
}
