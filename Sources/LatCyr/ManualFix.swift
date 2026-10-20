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
    /// The word is split exactly as the detector splits it
    /// (LanguageDetector.reading): a trailing run of shifted symbols and a
    /// wrapping opener are punctuation, kept as typed — "ntrcn:" becomes
    /// «текст:», not «текстЖ», and remembers «текст».
    ///
    /// The source is not validated with ExceptionWord: a Russian word typed
    /// in the English layout legitimately contains punctuation keys (";" is
    /// "ж", "," is "б"). The *result* is — it must be a clean word in the
    /// other alphabet.
    static func plan(for text: String, variant: TextConverter.RussianKeyboardVariant) -> Plan? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !source.contains(where: \.isWhitespace),
              let reading = LanguageDetector.reading(of: source, variant: variant) else { return nil }
        let core = reading.core
        let cyrillicCount = core.unicodeScalars.filter(isCyrillicLetter).count
        let toLatin: Bool
        if cyrillicCount == core.unicodeScalars.count {
            toLatin = true
        } else if cyrillicCount == 0 {
            toLatin = false
        } else {
            return nil
        }
        let converted = toLatin
            ? TextConverter.toLatin(core, variant: variant)
            : TextConverter.toCyrillic(core, variant: variant)
        guard let exception = ExceptionWord.normalized(from: converted) else { return nil }
        // The result must have changed alphabet: a Latin source whose
        // conversion is still Latin (digits, unmapped symbols) is no fix.
        let resultIsCyrillic = exception.unicodeScalars.allSatisfy(isCyrillicLetter)
        guard resultIsCyrillic != toLatin else { return nil }
        return Plan(replacement: reading.prefix + converted + reading.suffix, exception: exception)
    }

    private static func isCyrillicLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x0410...0x044F).contains(scalar.value) || scalar.value == 0x0401 || scalar.value == 0x0451
    }
}
