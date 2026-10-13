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

    func testFileIsCorrectedFromRussianLayout() {
        // The reported case: "ашду" scored 0.463 Russian, above the 0.4 threshold.
        XCTAssertTrue(LanguageDetector.isWrongLayout(word: "ашду", currentLayoutIsRussian: true, exceptions: bundled, variant: .apple))
    }
}
