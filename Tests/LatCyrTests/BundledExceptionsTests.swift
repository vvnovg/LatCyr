import XCTest
@testable import LatCyr

/// Guards Resources/exceptions.txt itself: it is read by LineFile, the same
/// parser the app uses, so a malformed line (stray characters, a word in
/// the wrong alphabet) shows up here instead of as a silently ignored entry.
final class BundledExceptionsTests: XCTestCase {
    private var bundled: Set<String> {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/exceptions.txt")
        return LineFile.read(url)
    }

    func testFileIsReadable() {
        XCTAssertGreaterThan(bundled.count, 500)
    }

    func testEveryLatinEntryIsCorrectedFromRussianLayout() {
        let exceptions = bundled
        for word in exceptions where word.allSatisfy({ $0.isASCII && $0.isLetter }) {
            for variant in [TextConverter.RussianKeyboardVariant.pc, .apple] {
                let typed = TextConverter.toCyrillic(word, variant: variant)
                XCTAssertTrue(
                    LanguageDetector.isWrongLayout(word: typed, currentLayoutIsRussian: true, exceptions: exceptions, variant: variant),
                    "\(word) typed as \(typed) (\(variant)) is not corrected"
                )
            }
        }
    }

    func testEveryEntryIsASingleWord() {
        for word in bundled {
            XCTAssertNotNil(ExceptionWord.normalized(from: word), "invalid entry: \(word)")
        }
    }

    func testCyrillicEntriesAreNotFlaggedWhenTypedCorrectly() {
        let exceptions = bundled
        for word in exceptions where word.allSatisfy({ $0.isLetter && !$0.isASCII }) {
            for variant in [TextConverter.RussianKeyboardVariant.pc, .apple] {
                XCTAssertFalse(
                    LanguageDetector.isWrongLayout(word: word, currentLayoutIsRussian: true, exceptions: exceptions, variant: variant),
                    "\(word) (\(variant)) is corrected despite being an exception"
                )
            }
        }
    }

    // Documents why these are listed: frequent Russian words the bigram score
    // misreads as a wrong layout. They are fixed here, not by tuning thresholds.
    // («будут» and «также» were the examples until the English model started
    // charging the punctuation keys inside a conversion; they stay listed.)
    func testFrequentRussianWordsMisreadByScoreAreListed() {
        let exceptions = bundled
        for word in ["слышу", "штук", "эффект"] {
            XCTAssertTrue(exceptions.contains(word), "\(word) missing from the bundled exceptions")
            for variant in [TextConverter.RussianKeyboardVariant.pc, .apple] {
                XCTAssertTrue(
                    LanguageDetector.isWrongLayout(word: word, currentLayoutIsRussian: true, exceptions: [], variant: variant),
                    "\(word) (\(variant)) is no longer misread without exceptions; the entry may be unnecessary"
                )
            }
        }
    }

    // The other direction: frequent Russian words the score misses when typed
    // in the English layout. «если» as "tckb" scores 1.34 against the 1.5
    // four-letter threshold, «нет» as "ytn" 2.17 against the 2.5 three-letter
    // one; listed, they are corrected unconditionally.
    func testFrequentRussianWordsMissedInEnglishLayoutAreCorrected() {
        let exceptions = bundled
        for word in ["если", "нет"] {
            XCTAssertTrue(exceptions.contains(word), "\(word) missing from the bundled exceptions")
            for variant in [TextConverter.RussianKeyboardVariant.pc, .apple] {
                let typed = TextConverter.toLatin(word, variant: variant)
                XCTAssertFalse(
                    LanguageDetector.isWrongLayout(word: typed, currentLayoutIsRussian: false, exceptions: [], variant: variant),
                    "\(typed) (\(variant)) is caught without exceptions; the entry may be unnecessary"
                )
                XCTAssertTrue(
                    LanguageDetector.isWrongLayout(word: typed, currentLayoutIsRussian: false, exceptions: exceptions, variant: variant),
                    "\(typed) (\(variant)) is not corrected to \(word)"
                )
            }
        }
    }

    // The reported phrase: «и нет» typed as "b ytn". "b" is too short to be
    // scored and is corrected only carried along with a wrong-layout word
    // after it, so missing "ytn" left both words as typed.
    func testAndNoTypedInEnglishLayoutIsCorrectedWithItsFunctionWord() {
        let exceptions = bundled
        for variant in [TextConverter.RussianKeyboardVariant.pc, .apple] {
            XCTAssertTrue(
                LanguageDetector.isWrongLayout(word: "ytn", currentLayoutIsRussian: false, exceptions: exceptions, variant: variant),
                "ytn (\(variant)) is not corrected"
            )
            XCTAssertTrue(
                LanguageDetector.isCarriableFunctionWord(word: "b", currentLayoutIsRussian: false, exceptions: exceptions, variant: variant),
                "b (\(variant)) is not carried"
            )
        }
    }

    func testFileIsCorrectedFromRussianLayout() {
        // History: under the old letter-frequency score "ашду" rated 0.463 Russian,
        // above its 0.4 threshold; the bigram score catches it on its own now
        // (see LanguageDetectorTests).
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ашду", currentLayoutIsRussian: true, exceptions: bundled, variant: .apple))
    }
}
