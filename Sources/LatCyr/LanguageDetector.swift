import Foundation

/// Pure heuristic detector: decides whether a word was typed in the wrong
/// keyboard layout by scoring how "Russian-looking" and "English-looking"
/// the word and its converted counterpart are.
public enum LanguageDetector {
    // MARK: - Letter sets

    private static let russianVowels: Set<Character> = ["а", "е", "ё", "и", "о", "у", "ы", "э", "ю", "я"]
    private static let russianConsonants: Set<Character> = [
        "б", "в", "г", "д", "ж", "з", "й", "к", "л", "м", "н",
        "п", "р", "с", "т", "ф", "х", "ц", "ч", "ш", "щ",
    ]
    private static let englishVowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
    private static let englishConsonants: Set<Character> = [
        "b", "c", "d", "f", "g", "h", "j", "k", "l", "m", "n",
        "p", "q", "r", "s", "t", "v", "w", "x", "z",
    ]

    // MARK: - Letter frequencies (normalized to 0...1)

    private static let russianFreq: [Character: Double] = [
        "о": 1.0, "е": 0.78, "а": 0.73, "и": 0.68, "н": 0.61, "т": 0.58,
        "с": 0.50, "р": 0.43, "в": 0.41, "л": 0.40, "к": 0.32, "м": 0.29,
        "д": 0.28, "п": 0.26, "у": 0.24, "я": 0.18, "ы": 0.17, "ь": 0.16,
        "г": 0.16, "з": 0.15, "б": 0.15, "ч": 0.13, "й": 0.11, "х": 0.08,
        "ж": 0.08, "ш": 0.06, "ю": 0.05, "ц": 0.04, "щ": 0.03, "э": 0.03,
        "ф": 0.02, "ъ": 0.004, "ё": 0.004,
    ]

    private static let englishFreq: [Character: Double] = [
        "e": 1.0, "t": 0.72, "a": 0.65, "o": 0.59, "i": 0.55, "n": 0.53,
        "s": 0.50, "h": 0.48, "r": 0.47, "d": 0.34, "l": 0.31, "c": 0.22,
        "u": 0.22, "m": 0.19, "w": 0.19, "f": 0.17, "g": 0.16, "y": 0.16,
        "p": 0.15, "b": 0.12, "v": 0.08, "k": 0.06, "j": 0.012, "x": 0.012,
        "q": 0.008, "z": 0.008,
    ]

    // MARK: - Thresholds

    public static let russianThreshold = 0.4
    public static let englishThreshold = 0.35
    public static let diffThreshold = 0.1
    public static let minWordLength = 3
    private static let runPenalty = 0.15

    // MARK: - Proactive signals

    /// Latin letters that, as the first two chars of a word typed in the
    /// English layout, strongly indicate the user means Russian.
    private static let strongRussianSignals: Set<Character> = ["j", "f", "b", "y", "z", "v", "k"]
    /// Cyrillic letters that, as the first two chars typed in the Russian
    /// layout, strongly indicate the user means English.
    private static let strongEnglishSignals: Set<Character> = ["ф", "щ", "ш"]
    /// English 2-letter prefixes that must never trigger a proactive switch.
    private static let excludedEnglishPrefixes: Set<String> = ["by"]
    /// The single leading character that, before any letter has been typed
    /// while the Russian layout is active, strongly indicates an absolute
    /// path is about to follow (terminal use only — see InputMonitor).
    private static let leadingPathSignal: Character = "/"

    // MARK: - Scoring

    /// How Russian-looking a Cyrillic word is, 0...1.
    public static func russianScore(_ word: String) -> Double {
        score(word, vowels: russianVowels, consonants: russianConsonants, freq: russianFreq)
    }

    /// How English-looking a Latin word is, 0...1.
    public static func englishScore(_ word: String) -> Double {
        score(word, vowels: englishVowels, consonants: englishConsonants, freq: englishFreq)
    }

    private static func score(
        _ word: String,
        vowels: Set<Character>,
        consonants: Set<Character>,
        freq: [Character: Double]
    ) -> Double {
        let chars = Array(word.lowercased())
        guard !chars.isEmpty else { return 0 }

        var vowelCount = 0
        var consonantRun = 0
        var maxConsonantRun = 0
        var freqSum = 0.0
        var freqCount = 0

        for ch in chars {
            if vowels.contains(ch) {
                vowelCount += 1
                consonantRun = 0
            } else if consonants.contains(ch) {
                consonantRun += 1
                maxConsonantRun = max(maxConsonantRun, consonantRun)
            }
            if let f = freq[ch] {
                freqSum += f
                freqCount += 1
            }
        }

        let vowelRatio = Double(vowelCount) / Double(chars.count)
        let vowelComponent = 1.0 - min(abs(vowelRatio - 0.4) / 0.3, 1.0)
        let freqComponent = freqCount > 0 ? freqSum / Double(freqCount) : 0
        let runPenaltyValue = maxConsonantRun >= 4 ? runPenalty : 0

        let result = 0.4 * vowelComponent + 0.6 * freqComponent - runPenaltyValue
        return max(0, min(result, 1))
    }

    // MARK: - Decisions

    /// Decide whether `word` (typed in the current layout) was meant to be
    /// typed in the other layout. `exceptions` overrides the score
    /// heuristic unconditionally: a word that is itself an exception is
    /// never flagged; a word whose conversion is an exception is always
    /// flagged — regardless of `russianThreshold`/`englishThreshold`/`diffThreshold`.
    public static func isWrongLayout(
        word: String, currentLayoutIsRussian: Bool, exceptions: Set<String>,
        variant: TextConverter.RussianKeyboardVariant
    ) -> Bool {
        let lower = word.lowercased()
        guard lower.count >= minWordLength else { return false }
        guard lower.allSatisfy({ $0.isLetter || TextConverter.ambiguousLetterSymbols(for: variant).contains($0) }) else { return false }

        if exceptions.contains(lower) { return false }

        let converted = currentLayoutIsRussian ? TextConverter.toLatin(lower, variant: variant) : TextConverter.toCyrillic(lower, variant: variant)
        if exceptions.contains(converted) { return true }

        if currentLayoutIsRussian {
            let russian = russianScore(lower)
            let english = englishScore(converted)
            return english > englishThreshold && russian < russianThreshold
                && english - russian > diffThreshold
        } else {
            let english = englishScore(lower)
            let russian = russianScore(converted)
            return russian > russianThreshold && english < englishThreshold
                && russian - english > diffThreshold
        }
    }

    /// Decide whether to switch layout immediately based on the first two
    /// characters of a word.
    public static func proactiveSwitchSignal(
        first: Character,
        second: Character,
        currentLayoutIsRussian: Bool
    ) -> Bool {
        let f = Character(first.lowercased())
        let s = Character(second.lowercased())

        if currentLayoutIsRussian {
            return strongEnglishSignals.contains(f) && strongEnglishSignals.contains(s)
        } else {
            guard strongRussianSignals.contains(f) && strongRussianSignals.contains(s) else { return false }
            return !excludedEnglishPrefixes.contains("\(f)\(s)")
        }
    }

    /// Decide whether to switch layout immediately based on a single
    /// leading character, before any letter has started the word — e.g.
    /// "/" while the Russian layout is active, since an absolute path is
    /// the overwhelmingly common reason to start typing with "/" and paths
    /// are always Latin.
    public static func proactiveSingleCharSwitchSignal(
        first: Character,
        currentLayoutIsRussian: Bool
    ) -> Bool {
        currentLayoutIsRussian && first == leadingPathSignal
    }
}
