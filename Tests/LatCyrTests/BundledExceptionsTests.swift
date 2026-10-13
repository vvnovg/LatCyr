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
    func testFrequentRussianWordsMisreadByScoreAreListed() {
        let exceptions = bundled
        for word in ["будут", "также"] {
            XCTAssertTrue(exceptions.contains(word), "\(word) missing from the bundled exceptions")
            for variant in [TextConverter.RussianKeyboardVariant.pc, .apple] {
                XCTAssertTrue(
                    LanguageDetector.isWrongLayout(word: word, currentLayoutIsRussian: true, exceptions: [], variant: variant),
                    "\(word) (\(variant)) is no longer misread without exceptions; the entry may be unnecessary"
                )
            }
        }
    }

    func testFileIsCorrectedFromRussianLayout() {
        // History: under the old letter-frequency score "ашду" rated 0.463 Russian,
        // above its 0.4 threshold; the bigram score catches it on its own now
        // (see LanguageDetectorTests).
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ашду", currentLayoutIsRussian: true, exceptions: bundled, variant: .apple))
    }
}
