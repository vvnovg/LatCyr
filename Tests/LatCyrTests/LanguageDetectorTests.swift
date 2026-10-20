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
    // both directions. "kfc" typed correctly under the English layout is a
    // false positive of the raw bigram score (LLR 2.74: its conversion
    // "лас" reads better as Russian than "kfc" does as English) — exactly
    // what the whitelist half fixes.
    func testExceptionWordNeverConverted() {
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "kfc", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "kfc", currentLayoutIsRussian: false, exceptions: ["kfc"], variant: .pc))
    }

    // "usb" mistyped as "гыи" under the Russian layout (toLatin("гыи") ==
    // "usb"): its LLR is 0.89, below the three-letter threshold, so the
    // ordinary score does not catch it — exactly what the forced-correction
    // half fixes.
    func testExceptionWordAlwaysCorrected() {
        XCTAssertEqual(TextConverter.toLatin("гыи", variant: .pc), "usb")
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "гыи", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "гыи", currentLayoutIsRussian: true, exceptions: ["usb"], variant: .pc))
    }

    // Same two behaviors, mirrored for a Cyrillic exception word — proves
    // the check isn't hardcoded to Latin-only exceptions.
    func testCyrillicExceptionWordSymmetric() {
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "щщщ", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "щщщ", currentLayoutIsRussian: true, exceptions: ["щщщ"], variant: .pc))

        XCTAssertEqual(TextConverter.toCyrillic("dep", variant: .pc), "вуз")
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "dep", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "dep", currentLayoutIsRussian: false, exceptions: ["вуз"], variant: .pc))
    }

    // The Russian keyboard variant gates which punctuation keys count as
    // letters (LanguageDetector's own guard, not just TextConverter) —
    // "`" is a letter-producing key only under .pc, "\" only under .apple.
    // "gj`k" (.pc) and "gj\k" (.apple) are "пошёл" typed under the English
    // layout: LLR 4.93 in its own variant — a genuine wrong-layout hit once
    // the guard admits the "ё" key; under the other variant the guard
    // rejects the word before it is scored.
    func testRussianVariantGatesAmbiguousLetterGuard() {
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "gj`k", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "gj`k", currentLayoutIsRussian: false, exceptions: [], variant: .apple))

        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "gj\\k", currentLayoutIsRussian: false, exceptions: [], variant: .apple))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "gj\\k", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
    }

    // Proactive: English layout → Russian
    func testProactiveSwitchToRussian() {
        XCTAssertTrue(LanguageDetector.proactiveSwitchSignal(first: "j", second: "y", currentLayoutIsRussian: false)) // он
        XCTAssertTrue(LanguageDetector.proactiveSwitchSignal(first: "v", second: "f", currentLayoutIsRussian: false)) // ма
        XCTAssertFalse(LanguageDetector.proactiveSwitchSignal(first: "b", second: "y", currentLayoutIsRussian: false)) // by — excluded
        XCTAssertFalse(LanguageDetector.proactiveSwitchSignal(first: "v", second: "v", currentLayoutIsRussian: false)) // vv — excluded
        XCTAssertFalse(LanguageDetector.proactiveSwitchSignal(first: "V", second: "V", currentLayoutIsRussian: false)) // case-insensitive
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
    // corrected whole, dot included. "фьфящтюву" is "amazon.de" typed under the
    // Russian layout. The English model skips the dot (it is not in its
    // alphabet); the Russian side is scored whole. Under the old
    // letter-frequency score the "ю" from the "." key held the word just over
    // the threshold, which is why scoring used to filter punctuation out.
    func testDomainWithPunctuationDetected() {
        XCTAssertEqual(TextConverter.toLatin("фьфящтюву", variant: .pc), "amazon.de")
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "фьфящтюву", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
    }

    // Domains that already scored correctly must keep doing so: skipping the
    // dot shortens the English side, and a shorter word must not drift below
    // its threshold.
    func testDomainsThatAlreadyWorkedStillDetected() {
        XCTAssertEqual(TextConverter.toLatin("пщщпдуюсщь", variant: .pc), "google.com")
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "пщщпдуюсщь", currentLayoutIsRussian: true, exceptions: [], variant: .pc))

        XCTAssertEqual(TextConverter.toLatin("еюьу", variant: .pc), "t.me")
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "еюьу", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
    }

    // The mirror case: a Cyrillic letter that merely *converts* to punctuation
    // is still a real letter of a correctly typed Russian word. Skipping the
    // conversion's punctuation must not turn any of these into a false positive.
    func testCorrectRussianWordsWhoseConversionHasPunctuationNotTouched() {
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "пою", currentLayoutIsRussian: true, exceptions: [], variant: .pc))   // gj.
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "мою", currentLayoutIsRussian: true, exceptions: [], variant: .pc))   // vj.
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "съел", currentLayoutIsRussian: true, exceptions: [], variant: .pc))  // c]tk
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "т.е.", currentLayoutIsRussian: true, exceptions: [], variant: .pc))  // n/t/
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "т.к.", currentLayoutIsRussian: true, exceptions: [], variant: .pc))  // n/r/
    }

    // "ё" sits on a different physical key in each Russian variant ("`" under
    // .pc, "\" under .apple), but both convert to punctuation, and the English
    // model skips both — and "объём" stays untouched either way.
    func testPunctuationFilteringHoldsForBothVariants() {
        XCTAssertEqual(TextConverter.toLatin("объём", variant: .pc), "j,]`v")
        XCTAssertEqual(TextConverter.toLatin("объём", variant: .apple), "j,]\\v")
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "объём", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "объём", currentLayoutIsRussian: true, exceptions: [], variant: .apple))
    }

    // Punctuation in the original is skipped by the English model, while the
    // conversion's letters are scored in full: under the English layout ","
    // and "]" are the "б" and "ъ" keys, so these words must behave exactly as
    // they did before.
    func testPunctuationInOriginalOnlyStillDetected() {
        XCTAssertEqual(TextConverter.toCyrillic("j,]trn", variant: .pc), "объект")
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "j,]trn", currentLayoutIsRussian: false, exceptions: [], variant: .pc))

        XCTAssertEqual(TextConverter.toCyrillic("ghbdtn,", variant: .pc), "приветб")
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ghbdtn,", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
    }

    // A buffer of punctuation keys alone has no letter for the current
    // layout's model to score — its side sits at the probability floor and
    // any conversion looks infinitely better. Code fences, ellipses and
    // Python docstring quotes must never be "corrected" into «ёёё» or «ююю».
    func testPunctuationOnlyBuffersNotTouched() {
        for (word, variant) in [("...", TextConverter.RussianKeyboardVariant.pc), ("....", .pc), ("```", .pc), ("\\\\\\", .apple),
                                ("'''", .pc), (",,,", .pc), (";;;", .pc), ("[[]]", .pc), ("[];", .pc), ("...", .apple)] {
            XCTAssertFalse(LanguageDetector.isWrongLayout(word: word, currentLayoutIsRussian: false, exceptions: [], variant: variant),
                           "\(word) (\(variant)) wrongly corrected")
            XCTAssertNil(LanguageDetector.wrongLayoutLLR(word: word, currentLayoutIsRussian: false, variant: variant))
        }
    }

    // "нщгегиуюсщь" is "youtube.com". Under the old letter-frequency score
    // it read as plausible Russian (н, е, и, у, с are all high-frequency
    // letters); the bigram model catches it on its own now (LLR 2.76). The
    // domain rule stays as an unconditional safeguard, like the exception
    // list: domains are always Latin.
    func testDomainNameOverridesScoreHeuristic() {
        XCTAssertEqual(TextConverter.toLatin("нщгегиуюсщь", variant: .pc), "youtube.com")
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "нщгегиуюсщь", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
        XCTAssertGreaterThan(LanguageDetector.wrongLayoutLLR(word: "нщгегиуюсщь", currentLayoutIsRussian: true, variant: .pc)!, LanguageDetector.llrThresholds.longer)
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

    // Scores are mean natural-log bigram probabilities now: negative,
    // closer to zero is more plausible. Only the ordering is meaningful.
    func testScores() {
        XCTAssertGreaterThan(LanguageDetector.russianScore("привет"), LanguageDetector.russianScore("руддщ") + 1)
        XCTAssertGreaterThan(LanguageDetector.englishScore("hello"), LanguageDetector.englishScore("ghbdtn") + 1)
    }

    // A short function word is never corrected on its own — "d" is one
    // character, far below minWordLength — but must be recognised as
    // carriable, so the word that follows can take it along.
    func testCarriableFunctionWordBothDirections() {
        XCTAssertEqual(TextConverter.toCyrillic("d", variant: .pc), "в")
        XCTAssertTrue(LanguageDetector.isCarriableFunctionWord(word: "d", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
        XCTAssertTrue(LanguageDetector.isCarriableFunctionWord(word: "yf", currentLayoutIsRussian: false, exceptions: [], variant: .pc))  // на
        XCTAssertTrue(LanguageDetector.isCarriableFunctionWord(word: "yfl", currentLayoutIsRussian: false, exceptions: [], variant: .pc)) // над
        XCTAssertTrue(LanguageDetector.isCarriableFunctionWord(word: "D", currentLayoutIsRussian: false, exceptions: [], variant: .pc))   // case-insensitive

        XCTAssertEqual(TextConverter.toLatin("шт", variant: .pc), "in")
        XCTAssertTrue(LanguageDetector.isCarriableFunctionWord(word: "шт", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
        XCTAssertEqual(TextConverter.toLatin("еру", variant: .pc), "the")
        XCTAssertTrue(LanguageDetector.isCarriableFunctionWord(word: "еру", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
    }

    // Anything that isn't in the curated list stays out, however short.
    func testNonFunctionWordNotCarriable() {
        XCTAssertFalse(LanguageDetector.isCarriableFunctionWord(word: "ujhjl", currentLayoutIsRussian: false, exceptions: [], variant: .pc)) // город
        XCTAssertFalse(LanguageDetector.isCarriableFunctionWord(word: "abc", currentLayoutIsRussian: false, exceptions: [], variant: .pc))   // фис
        XCTAssertFalse(LanguageDetector.isCarriableFunctionWord(word: "hello", currentLayoutIsRussian: false, exceptions: [], variant: .pc)) // рудды
        XCTAssertFalse(LanguageDetector.isCarriableFunctionWord(word: "d1", currentLayoutIsRussian: false, exceptions: [], variant: .pc))    // digit
        XCTAssertFalse(LanguageDetector.isCarriableFunctionWord(word: "", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
    }

    // "об" is typed as "j," — the comma is a letter key under the Russian
    // layout, so the same ambiguous-symbol guard as isWrongLayout is needed
    // or the word fails the "letters only" check.
    func testCarriableWordWithAmbiguousSymbol() {
        XCTAssertEqual(TextConverter.toCyrillic("j,", variant: .pc), "об")
        XCTAssertTrue(LanguageDetector.isCarriableFunctionWord(word: "j,", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
    }

    // A user exception beats the list, exactly as it beats the score
    // heuristic in isWrongLayout.
    func testExceptionOverridesCarry() {
        XCTAssertFalse(LanguageDetector.isCarriableFunctionWord(word: "d", currentLayoutIsRussian: false, exceptions: ["d"], variant: .pc))
    }

    // The direction that could bite: a legitimate one-letter Russian word
    // standing before English text. "и цщкду" is "и world" — "и" converts to
    // "b", which is not an English function word, so it is left alone. The
    // list being per-target-language is what makes this free.
    func testLegitimateRussianWordBeforeEnglishNotCarried() {
        XCTAssertEqual(TextConverter.toLatin("и", variant: .pc), "b")
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "цщкду", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isCarriableFunctionWord(word: "и", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
    }

    // The motivating misses: frequent English words typed under the Russian
    // layout whose Cyrillic form is made of frequent Russian letters. The
    // letter-frequency score held all of them over the old 0.4 threshold
    // ("ашду" 0.463, "ершы" 0.483, "ащк" 0.527); letter pairs give them
    // away. No exceptions — the bundled list must not be what catches them.
    func testFrequentEnglishWordsCaughtWithoutExceptions() {
        for typed in ["ашду", "ершы", "ащк", "цшер", "фку", "ерфе"] { // file this for with are that
            for variant in [TextConverter.RussianKeyboardVariant.pc, .apple] {
                XCTAssertTrue(LanguageDetector.isWrongLayout(word: typed, currentLayoutIsRussian: true, exceptions: [], variant: variant),
                              "\(typed) (\(variant)) not corrected")
            }
        }
    }

    // Correct Russian words built from rare pairs (щ, ъ, ы, э). These are
    // where a bigram model is most likely to misfire.
    func testRussianWordsWithRarePairsNotTouched() {
        for word in ["шею", "щука", "съезд", "объект", "этот", "мысль", "вообще", "подъезд",
                     "взгляд", "чувство", "следующий", "объявление", "здравствуйте"] {
            for variant in [TextConverter.RussianKeyboardVariant.pc, .apple] {
                XCTAssertFalse(LanguageDetector.isWrongLayout(word: word, currentLayoutIsRussian: true, exceptions: [], variant: variant),
                               "\(word) (\(variant)) wrongly corrected")
            }
        }
    }

    // The most frequent Russian words whose letters sit on punctuation keys
    // (б, ю, ж, ё) or map to English vowels (у, ы, е). Scoring them with
    // those letters cut out ("был" as "ыл", "ещё" as "ещ") flagged them —
    // the original is scored whole. Several were also false positives of
    // the old letter-frequency score ("уже", "еще", "хочу", "ему", "буду").
    func testFrequentRussianWordsNotTouched() {
        for word in ["был", "быть", "была", "были", "уже", "ещё", "еще", "тут", "лучше",
                     "хочу", "ему", "буду", "друг", "будет", "может", "между"] {
            for variant in [TextConverter.RussianKeyboardVariant.pc, .apple] {
                XCTAssertFalse(LanguageDetector.isWrongLayout(word: word, currentLayoutIsRussian: true, exceptions: [], variant: variant),
                               "\(word) (\(variant)) wrongly corrected")
            }
        }
    }

    // Short English and command-line tokens typed correctly. Several are
    // barely English as letter sequences — exactly why thresholds must not
    // simply be lowered.
    func testShortEnglishTokensNotTouched() {
        for word in ["the", "and", "npm", "git", "ssh", "sudo", "grep", "brew", "http", "www", "usb", "json", "yaml", "mkdir", "chmod"] {
            for variant in [TextConverter.RussianKeyboardVariant.pc, .apple] {
                XCTAssertFalse(LanguageDetector.isWrongLayout(word: word, currentLayoutIsRussian: false, exceptions: [], variant: variant),
                               "\(word) (\(variant)) wrongly corrected")
            }
        }
    }

    // The score half alone: guards still apply, exceptions and domains do not.
    func testWrongLayoutLLR() {
        XCTAssertNil(LanguageDetector.wrongLayoutLLR(word: "gh", currentLayoutIsRussian: false, variant: .pc))
        XCTAssertNil(LanguageDetector.wrongLayoutLLR(word: "ghbdtn1", currentLayoutIsRussian: false, variant: .pc))
        let wrong = LanguageDetector.wrongLayoutLLR(word: "ghbdtn", currentLayoutIsRussian: false, variant: .pc)!
        let right = LanguageDetector.wrongLayoutLLR(word: "hello", currentLayoutIsRussian: false, variant: .pc)!
        XCTAssertGreaterThan(wrong, LanguageDetector.llrThresholds.longer)
        XCTAssertLessThan(right, LanguageDetector.llrThresholds.longer)
    }

    // Explicit thresholds override the defaults — the evaluation tool
    // sweeps them to draw its grid.
    func testExplicitThresholds() {
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ghbdtn", currentLayoutIsRussian: false, exceptions: [], variant: .pc, thresholds: .uniform(-100)))
        XCTAssertFalse(LanguageDetector.isWrongLayout(word: "ghbdtn", currentLayoutIsRussian: false, exceptions: [], variant: .pc, thresholds: .uniform(100)))
    }

    // A three-letter word gives the model four transitions to judge, so its
    // LLR is noisy ("тут" scores well above many genuine misses) and needs
    // the widest margin; the margin narrows as words get longer.
    func testThresholdsByLength() {
        let t = LanguageDetector.LLRThresholds(threeLetters: 3, fourLetters: 2, longer: 1)
        XCTAssertEqual(t.threshold(forLength: 3), 3)
        XCTAssertEqual(t.threshold(forLength: 4), 2)
        XCTAssertEqual(t.threshold(forLength: 5), 1)
        XCTAssertEqual(t.threshold(forLength: 12), 1)

        let chosen = LanguageDetector.llrThresholds
        XCTAssertGreaterThanOrEqual(chosen.threeLetters, chosen.fourLetters)
        XCTAssertGreaterThanOrEqual(chosen.fourLetters, chosen.longer)
    }

    // MARK: - Short terminal commands

    func testShortTerminalCommandsTypedInRussianLayout() {
        for variant in [TextConverter.RussianKeyboardVariant.pc, .apple] {
            XCTAssertEqual(TextConverter.toLatin("св", variant: variant), "cd")
            for word in ["св", "ды", "кь", "ьм", "сз", "Св"] {
                XCTAssertTrue(LanguageDetector.isTerminalCommand(word: word, currentLayoutIsRussian: true, exceptions: [], variant: variant), word)
            }
        }
    }

    // Commands are Latin: under the English layout "cd" is already right,
    // and nothing typed there is a Cyrillic command.
    func testShortTerminalCommandsOnlyFromRussianLayout() {
        XCTAssertFalse(LanguageDetector.isTerminalCommand(word: "cd", currentLayoutIsRussian: false, exceptions: [], variant: .pc))
        XCTAssertFalse(LanguageDetector.isTerminalCommand(word: "cd", currentLayoutIsRussian: true, exceptions: [], variant: .pc))
    }

    func testShortRussianWordsAreNotTerminalCommands() {
        for word in ["да", "не", "по", "за", "от", "на", "с", "в", "я", "ва"] {
            XCTAssertFalse(LanguageDetector.isTerminalCommand(word: word, currentLayoutIsRussian: true, exceptions: [], variant: .pc), word)
        }
    }

    func testTerminalCommandExceptionWins() {
        XCTAssertFalse(LanguageDetector.isTerminalCommand(word: "св", currentLayoutIsRussian: true, exceptions: ["св"], variant: .pc))
    }

    // No entry may be the Latin form of a Russian function word: those are
    // exactly the short words a Russian speaker types on their own.
    func testTerminalCommandsDoNotCollideWithRussianFunctionWords() {
        for command in LanguageDetector.terminalCommandsForTesting {
            for variant in [TextConverter.RussianKeyboardVariant.pc, .apple] {
                let cyrillic = TextConverter.toCyrillic(command, variant: variant)
                XCTAssertFalse(LanguageDetector.isCarriableFunctionWord(word: command, currentLayoutIsRussian: false, exceptions: [], variant: variant),
                               "\(command) -> \(cyrillic)")
            }
        }
    }

    // MARK: - wrongLayoutReading (shifted letter keys)

    private func reading(_ token: String, russian: Bool = false, exceptions: Set<String> = [],
                         variant: TextConverter.RussianKeyboardVariant = .pc) -> LanguageDetector.Reading? {
        LanguageDetector.wrongLayoutReading(token: token, currentLayoutIsRussian: russian,
                                            exceptions: exceptions, variant: variant)
    }

    func testLeadingShiftedSymbolIsCapital() {
        XCTAssertEqual(reading("{jhjij"), .init(prefix: "", core: "{jhjij", suffix: ""))
        XCTAssertEqual(reading(":fkm"), .init(prefix: "", core: ":fkm", suffix: ""))
        XCTAssertEqual(reading("<skj"), .init(prefix: "", core: "<skj", suffix: ""))
        XCTAssertEqual(reading("\"njn"), .init(prefix: "", core: "\"njn", suffix: ""))
    }

    func testTrailingShiftedSymbolsAreAlwaysPunctuation() {
        XCTAssertEqual(reading("ghbdtn:"), .init(prefix: "", core: "ghbdtn", suffix: ":"))
        XCTAssertEqual(reading("ghbdtn\"}"), .init(prefix: "", core: "ghbdtn", suffix: "\"}"))
    }

    func testWrappedTokenOpeningSymbolIsPunctuation() {
        XCTAssertEqual(reading("\"ghbdtn\""), .init(prefix: "\"", core: "ghbdtn", suffix: "\""))
        XCTAssertEqual(reading("{jhjij}"), .init(prefix: "{", core: "jhjij", suffix: "}"))
    }

    func testUnclosedQuoteIsCapitalKnownLimitation() {
        // The first of several quoted words has no closing quote in its token.
        XCTAssertEqual(reading("\"ghbdtn"), .init(prefix: "", core: "\"ghbdtn", suffix: ""))
    }

    func testMismatchedPairIsNotWrapping() {
        // "{" opens, but the tail holds a quote, not "}": "{" stays a capital.
        XCTAssertEqual(reading("{jhjij\""), .init(prefix: "", core: "{jhjij", suffix: "\""))
    }

    func testEnglishWithShiftedSymbolsUntouched() {
        XCTAssertNil(reading("\"hello\""))
        XCTAssertNil(reading("foo:bar"))
        XCTAssertNil(reading("hello:"))
    }

    func testOnlyShiftedSymbolsIsNil() {
        XCTAssertNil(reading("\"::"))
    }

    func testThreeLetterCapitalNeedsException() {
        // "это" scores 1.75 against the 2.5 three-letter threshold.
        XCTAssertNil(reading("\"nj"))
        // The conversion "Это" is compared with exceptions lowercased.
        XCTAssertEqual(reading("\"nj", exceptions: ["это"]), .init(prefix: "", core: "\"nj", suffix: ""))
    }

    func testRussianLayoutShiftedPunctuation() {
        // Russian layout: Ж is a letter (converted to ":"); a real ":" or quote
        // typed with Shift+6 / Shift+2 is punctuation.
        XCTAssertEqual(reading("руддщ:", russian: true), .init(prefix: "", core: "руддщ", suffix: ":"))
        XCTAssertEqual(reading("\"руддщ\"", russian: true), .init(prefix: "\"", core: "руддщ", suffix: "\""))
        XCTAssertEqual(reading("цщкдвЖ", russian: true), .init(prefix: "", core: "цщкдвЖ", suffix: ""))
    }

    func testPlainWordUnchanged() {
        XCTAssertEqual(reading("ghbdtn"), .init(prefix: "", core: "ghbdtn", suffix: ""))
        XCTAssertNil(reading("hello"))
    }
}
