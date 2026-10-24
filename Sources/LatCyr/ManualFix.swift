import Foundation

/// What "fix and remember" does to a word: which way to convert it, the
/// replacement for the text, and the word to add to the exceptions. Pure,
/// unit-tested; ManualFixer does the AX and keystroke work around it.
enum ManualFix {
    struct Plan: Equatable {
        /// Conversion with each letter's case kept — goes into the text.
        let replacement: String
        /// The corrected forms, lowercased, one per distinct word — go into
        /// ExceptionStore, so each mistyped form is always corrected from now
        /// on and the corrected one is never touched.
        let exceptions: [String]

        init(replacement: String, exceptions: [String]) {
            self.replacement = replacement
            self.exceptions = exceptions
        }

        init(replacement: String, exception: String) {
            self.init(replacement: replacement, exceptions: [exception])
        }
    }

    /// Most words one fix converts. Double Shift is easy to press by
    /// accident; a whole selected paragraph must not be converted and pour
    /// its words into the exceptions.
    static let maxWords = 10

    /// nil when `text` cannot be fixed as a whole: no word, more than
    /// `maxWords`, a word that cannot be converted, or words in both
    /// alphabets.
    ///
    /// A selection is an explicit choice, so every word in it is fixed;
    /// whitespace between words is kept exactly, and a token without a letter
    /// (a dash, a number) stays as typed. One direction for the whole text:
    /// a word already in the target alphabet would otherwise be flipped back.
    /// Any unfixable word refuses the whole text rather than fixing part of it.
    ///
    /// Each word is split exactly as the detector splits it
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
        guard !source.isEmpty else { return nil }
        var replacement = ""
        var exceptions: [String] = []
        var direction: Bool?
        var words = 0
        for token in tokens(of: source) {
            guard token.isWord, token.text.contains(where: \.isLetter) else {
                replacement += token.text
                continue
            }
            words += 1
            guard words <= maxWords, let word = planWord(token.text, variant: variant) else { return nil }
            guard direction == nil || direction == word.toLatin else { return nil }
            direction = word.toLatin
            replacement += word.replacement
            if !exceptions.contains(word.exception) { exceptions.append(word.exception) }
        }
        guard words > 0 else { return nil }
        return Plan(replacement: replacement, exceptions: exceptions)
    }

    /// `text` cut into runs of non-whitespace (words) and of whitespace.
    private static func tokens(of text: String) -> [(text: String, isWord: Bool)] {
        var result: [(text: String, isWord: Bool)] = []
        for char in text {
            let isWord = !char.isWhitespace
            if let last = result.last, last.isWord == isWord {
                result[result.count - 1].text.append(char)
            } else {
                result.append((String(char), isWord))
            }
        }
        return result
    }

    /// One word: its replacement, its exception and which way it converts.
    private static func planWord(
        _ source: String, variant: TextConverter.RussianKeyboardVariant
    ) -> (replacement: String, exception: String, toLatin: Bool)? {
        guard let reading = LanguageDetector.reading(of: source, variant: variant) else { return nil }
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
        return (reading.prefix + converted + reading.suffix, exception, toLatin)
    }

    private static func isCyrillicLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x0410...0x044F).contains(scalar.value) || scalar.value == 0x0401 || scalar.value == 0x0451
    }
}
