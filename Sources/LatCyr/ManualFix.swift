import Foundation

/// What "fix and remember" does to a word: which way to convert it, the
/// replacement for the text, and the word to add to the exceptions. Pure,
/// unit-tested; ManualFixer does the AX and keystroke work around it.
enum ManualFix {
    struct Plan: Equatable {
        /// Conversion with each letter's case kept — goes into the text.
        let replacement: String
        /// The corrected form, lowercased — goes into ExceptionStore, so the
        /// mistyped form is always corrected from now on and the corrected
        /// one is never touched.
        let exception: String
    }

    /// nil when `text` is not one word in one alphabet.
    ///
    /// The source is not validated with ExceptionWord: a Russian word typed
    /// in the English layout legitimately contains punctuation keys (";" is
    /// "ж", "," is "б"). The *result* is — it must be a clean word in the
    /// other alphabet.
    static func plan(for text: String, variant: TextConverter.RussianKeyboardVariant) -> Plan? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !source.contains(where: \.isWhitespace) else { return nil }
        let cyrillicCount = source.unicodeScalars.filter(isCyrillicLetter).count
        let toLatin: Bool
        if cyrillicCount == source.unicodeScalars.count {
            toLatin = true
        } else if cyrillicCount == 0 {
            toLatin = false
        } else {
            return nil
        }
        let replacement = toLatin
            ? TextConverter.toLatin(source, variant: variant)
            : TextConverter.toCyrillic(source, variant: variant)
        guard let exception = ExceptionWord.normalized(from: replacement) else { return nil }
        // The result must have changed alphabet: a Latin source whose
        // conversion is still Latin (digits, unmapped symbols) is no fix.
        let resultIsCyrillic = exception.unicodeScalars.allSatisfy(isCyrillicLetter)
        guard resultIsCyrillic != toLatin else { return nil }
        return Plan(replacement: replacement, exception: exception)
    }

    private static func isCyrillicLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x0410...0x044F).contains(scalar.value) || scalar.value == 0x0401 || scalar.value == 0x0451
    }
}
