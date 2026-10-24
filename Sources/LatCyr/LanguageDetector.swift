import Foundation

/// Pure heuristic detector: decides whether a word was typed in the wrong
/// keyboard layout by scoring how "Russian-looking" and "English-looking"
/// the word and its converted counterpart are.
public enum LanguageDetector {
    // MARK: - Thresholds

    /// Minimum log-likelihood ratio (see `wrongLayoutLLR`) at which a word
    /// is read as typed in the wrong layout, by the length of the word as
    /// typed. A three-letter word gives the model only four transitions to
    /// judge, so its LLR is noisy and needs the widest margin.
    public struct LLRThresholds: Equatable {
        public var threeLetters: Double
        public var fourLetters: Double
        public var longer: Double

        public init(threeLetters: Double, fourLetters: Double, longer: Double) {
            self.threeLetters = threeLetters
            self.fourLetters = fourLetters
            self.longer = longer
        }

        public static func uniform(_ value: Double) -> LLRThresholds {
            LLRThresholds(threeLetters: value, fourLetters: value, longer: value)
        }

        public func threshold(forLength length: Int) -> Double {
            length <= 3 ? threeLetters : length == 4 ? fourLetters : longer
        }
    }

    /// Chosen on a grid by scripts/eval-detector — the rule, the grid and
    /// the numbers are in docs/superpowers/specs/2026-10-13-bigram-scoring-design.md,
    /// §6–§7. Do not tune them to rescue individual words: every step
    /// trades caught words against false positives across tens of thousands
    /// of real ones. Individual words belong in the exception list.
    public static let llrThresholds = LLRThresholds(threeLetters: 2.50, fourLetters: 1.50, longer: 1.00)
    public static let minWordLength = 3

    // MARK: - Proactive signals

    /// Latin letters that, as the first two chars of a word typed in the
    /// English layout, strongly indicate the user means Russian.
    private static let strongRussianSignals: Set<Character> = ["j", "f", "b", "y", "z", "v", "k"]
    /// Cyrillic letters that, as the first two chars typed in the Russian
    /// layout, strongly indicate the user means English.
    private static let strongEnglishSignals: Set<Character> = ["ф", "щ", "ш"]
    /// English 2-letter prefixes that must never trigger a proactive switch.
    ///
    /// "by" is a real English word. "vv" is not, but it opens initials,
    /// logins and abbreviations ("vvnovg") often enough to matter, and the
    /// Russian prefix it would produce ("мм") starts essentially nothing —
    /// so excluding it costs no real detection. Note that the exception
    /// *word* list cannot cover such cases: it is only consulted on the
    /// retroactive path, which never runs when the proactive one has already
    /// rewritten the word's first two characters.
    private static let excludedEnglishPrefixes: Set<String> = ["by", "vv"]
    /// The single leading character that, before any letter has been typed
    /// while the Russian layout is active, strongly indicates an absolute
    /// path is about to follow (terminal use only — see InputMonitor).
    private static let leadingPathSignal: Character = "/"

    // MARK: - Scoring

    /// How Russian-looking a Cyrillic word is: the mean natural-log
    /// probability of its letter pairs, word boundaries included, under the
    /// Russian bigram model. Always negative; closer to zero is more Russian.
    public static func russianScore(_ word: String) -> Double {
        BigramModel.russian.averageLogProb(word)
    }

    /// How English-looking a Latin word is, on the same scale as `russianScore`.
    ///
    /// The punctuation keys are Russian letters under the English layout
    /// (б ю ж э ъ х ё), so a Latin token may carry them — typed as such
    /// («хуже» as "[e;t"), or as the conversion of a Russian word. The
    /// model charges the floor for any symbol it is given (see
    /// BigramModel.averageLogProb); what English spelling puts next to a
    /// word is removed first, so it costs nothing, exactly as the tables
    /// built from bare words assume:
    ///
    /// - a trailing run of symbols — "the," "file." "x;" "a]" "code`": the
    ///   everyday ends of English tokens; charging them corrected "the," into
    ///   «еруб» (5–20% of English words with a comma, a dot or brackets);
    /// - a leading run except "," and ";" — a quote, "[link", "`code",
    ///   ".gitignore"; no English token starts with a comma or a semicolon,
    ///   while Russian words start with б and ж («был» is ",sk");
    /// - the apostrophe anywhere ("don't", "it's"): the one symbol English
    ///   uses inside a word, and FrequencyWords splits "don't" into "don"
    ///   and "'t", so there is no data to score it with.
    ///
    /// Everything else inside the word stays and costs the floor: "[e;t"
    /// («хуже») scores "e;t", not the perfectly English "et" that skipping
    /// every symbol made of it. The dot inside "amazon.de" is charged the
    /// same way; domains are caught by looksLikeDomain, not by the score.
    public static func englishScore(_ word: String) -> Double {
        BigramModel.english.averageLogProb(englishSpellingStripped(word))
    }

    /// `word` without the symbols English spelling allows around and
    /// inside a word — see englishScore.
    static func englishSpellingStripped(_ word: String) -> String {
        let chars = Array(word.lowercased())
        let isLetter: (Character) -> Bool = { $0.isASCII && $0.isLetter }
        guard let first = chars.firstIndex(where: isLetter), let last = chars.lastIndex(where: isLetter) else { return "" }
        let leading = chars[..<first].filter { leadingSymbolsCharged.contains($0) }
        let inner = chars[first...last].filter { $0 != "'" }
        return String(leading + inner)
    }

    /// Leading symbols englishScore keeps for the model to charge: no
    /// English token starts with them.
    private static let leadingSymbolsCharged: Set<Character> = [",", ";"]

    // MARK: - Decisions

    /// Top-level domains recognised in a conversion. Deliberately a curated
    /// list rather than "any 2+ letters after a dot": "верблюды" converts to
    /// "dth,k.ls" and "воюем" to "dj.tv", so a generic rule would read real
    /// Russian words as domains. TLDs that collide with common Russian
    /// endings are left out for the same reason — "tv" is "-юем" (воюем,
    /// горюем) and "cz" is "-юся".
    private static let knownTLDs: Set<String> = [
        "com", "org", "net", "info", "io", "me", "co", "app", "dev", "ai", "xyz",
        "ru", "de", "uk", "fr", "it", "es", "pl", "nl", "se", "fi", "ua", "by", "kz",
    ]

    /// Shortest first label accepted as a domain. "клюву" converts to "rk.de",
    /// a valid-looking domain with a 2-character name, «июля» to "b.kz";
    /// real sites the user types by hand are longer.
    private static let minDomainLabelLength = 3

    /// Real domains shorter than the label rule allows, by hand. "t.me"
    /// («еюьу») is not caught by the score either: its dot is charged, and
    /// LLR 1.48 sits just under the four-letter threshold.
    private static let knownShortDomains: Set<String> = ["t.me"]

    /// Whether the conversion reads as a domain name. Domain names are always
    /// Latin, so this is an unconditional wrong-layout signal — the same
    /// standing as the exception list, and for the same reason: the frequency
    /// heuristic could not see it. "нщгегиуюсщь" converts to "youtube.com",
    /// yet н, е, и, у and с are all high-frequency Russian letters. The
    /// bigram model charges the dot inside the conversion, so it is barely
    /// above its threshold here (LLR 1.07); the rule is what catches
    /// domains, unconditionally, like the exceptions, because domains are
    /// always Latin.
    ///
    /// The ASCII check does the heavy lifting against false positives: any
    /// Cyrillic in the conversion (i.e. the English→Russian direction, where
    /// a domain reading is meaningless) or any stray punctuation — "боюся"
    /// converts to ",j.cz" — disqualifies the word outright.
    private static func looksLikeDomain(_ converted: String) -> Bool {
        if knownShortDomains.contains(converted) { return true }
        guard converted.contains(".") else { return false }
        guard converted.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-")
        }) else { return false }

        let labels = converted.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ !$0.isEmpty }),
              let tld = labels.last, knownTLDs.contains(String(tld)),
              let first = labels.first, first.count >= minDomainLabelLength else { return false }
        return true
    }

    /// Decide whether `word` (typed in the current layout) was meant to be
    /// typed in the other layout. `exceptions` overrides the score
    /// unconditionally: a word that is itself an exception is never flagged;
    /// a word whose conversion is an exception is always flagged —
    /// regardless of `thresholds`. So does a conversion that reads as a
    /// domain name (`looksLikeDomain`).
    ///
    /// `thresholds` defaults to `llrThresholds`; scripts/eval-detector passes
    /// others to sweep its grid.
    public static func isWrongLayout(
        word: String, currentLayoutIsRussian: Bool, exceptions: Set<String>,
        variant: TextConverter.RussianKeyboardVariant,
        thresholds: LLRThresholds = LanguageDetector.llrThresholds
    ) -> Bool {
        let lower = word.lowercased()
        guard isScorable(lower, currentLayoutIsRussian: currentLayoutIsRussian, variant: variant) else { return false }

        if exceptions.contains(lower) { return false }

        // Lowercased: the shifted keys convert to capitals ("\"" → "Э"),
        // and exceptions are stored lowercase.
        let converted = convert(lower, currentLayoutIsRussian: currentLayoutIsRussian, variant: variant).lowercased()
        if exceptions.contains(converted) { return true }
        if looksLikeDomain(converted) { return true }

        return layoutLLR(original: lower, converted: converted, currentLayoutIsRussian: currentLayoutIsRussian)
            // Length counts the word as typed, punctuation keys included
            // (the same unit as minWordLength).
            > thresholds.threshold(forLength: lower.count)
    }

    /// How a typed token splits for correction: `core` is converted, `prefix`
    /// and `suffix` are punctuation left as typed. See wrongLayoutReading.
    public struct Reading: Equatable {
        public let prefix: String
        public let core: String
        public let suffix: String
    }

    /// Opening shifted symbols and the closer that makes them a pair.
    private static let wrappingPairs: [Character: Character] = ["\"": "\"", "{": "}", "<": ">"]

    /// The reading of `token` if it is a wrong-layout word, or nil: the
    /// split of `reading(of:variant:)`, judged by `isWrongLayout` on its core.
    public static func wrongLayoutReading(
        token: String, currentLayoutIsRussian: Bool,
        exceptions: Set<String>, variant: TextConverter.RussianKeyboardVariant
    ) -> Reading? {
        guard let reading = reading(of: token, variant: variant) else { return nil }
        return isWrongLayout(word: reading.core, currentLayoutIsRussian: currentLayoutIsRussian,
                             exceptions: exceptions, variant: variant) ? reading : nil
    }

    /// How `token` splits into punctuation and a convertible core, without
    /// judging whether it is a wrong-layout word; nil only when nothing but
    /// shifted symbols is left. Shared by detection and fix-and-remember
    /// (ManualFix), so both convert the same part of a token.
    ///
    /// The Shift layer of the letter keys (TextConverter.shiftedLetterSymbols:
    /// "<" Б, ":" Ж, "\"" Э …) is read by position, not by score. A trailing
    /// run is always punctuation — no word ends in a capital, while "word:"
    /// and a closing quote are everyday. A leading one is a capital
    /// («Хорошо», «Этот»), unless the token is wrapped — opens with "\"",
    /// "{" or "<" and its tail holds the matching closer — and then it is
    /// punctuation ("\"привет\""). Comparing the LLR of both readings does
    /// not work: the mean per letter pair favours the word without its first
    /// letter ("{орошо" over «Хорошо», "\"тот" over «Этот»). In the middle a
    /// symbol stays a letter, like ";" in "ckj;yj" («сложно»).
    public static func reading(of token: String, variant: TextConverter.RussianKeyboardVariant) -> Reading? {
        let shifted = TextConverter.shiftedLetterSymbols(for: variant)
        var body = Substring(token)
        var suffixStart = body.endIndex
        while suffixStart > body.startIndex, shifted.contains(body[body.index(before: suffixStart)]) {
            suffixStart = body.index(before: suffixStart)
        }
        let suffix = String(body[suffixStart...])
        body = body[..<suffixStart]
        guard !body.isEmpty else { return nil }

        var prefix = ""
        if let first = body.first, body.count > 1,
           let closer = wrappingPairs[first], suffix.contains(closer) {
            prefix = String(first)
            body = body.dropFirst()
        }
        return Reading(prefix: prefix, core: String(body), suffix: suffix)
    }

    /// The score half of `isWrongLayout` on its own: how much more plausible
    /// the conversion is in the target language than the word as typed is in
    /// the current one, in mean natural-log probability per letter pair.
    /// Positive means the conversion reads better. `nil` when the word fails
    /// the length or character guards; exceptions and domains are not
    /// consulted.
    public static func wrongLayoutLLR(
        word: String, currentLayoutIsRussian: Bool,
        variant: TextConverter.RussianKeyboardVariant
    ) -> Double? {
        let lower = word.lowercased()
        guard isScorable(lower, currentLayoutIsRussian: currentLayoutIsRussian, variant: variant) else { return nil }
        let converted = convert(lower, currentLayoutIsRussian: currentLayoutIsRussian, variant: variant)
        return layoutLLR(original: lower, converted: converted, currentLayoutIsRussian: currentLayoutIsRussian)
    }

    /// Whether `lower` is a word the models can judge: long enough, and made
    /// of letters plus — under the English layout only — the punctuation-key
    /// symbols that are Russian letters there (ambiguousLetterSymbols). Under
    /// the Russian layout those keys *type* Russian letters, so a "," or ":"
    /// that arrives is real punctuation from another key, never part of the
    /// word: «хуже,» is not a five-character word to be scored against a
    /// lower threshold than «хуже» (InputMonitor ends the word there too).
    private static func isScorable(
        _ lower: String, currentLayoutIsRussian: Bool, variant: TextConverter.RussianKeyboardVariant
    ) -> Bool {
        // A buffer with no letter (a code fence, an ellipsis) scores the
        // probability floor on the original side, so any conversion looks
        // infinitely better; such buffers are never scorable.
        //
        // Every letter must be one the active layout types: Cyrillic under the
        // Russian layout, Latin under the English one. Both alphabets in one
        // buffer mean the layout was switched mid-word, so the buffer does not
        // describe text typed under one layout, and its length may not match
        // the screen either: the key read under the old layout can print
        // nothing ("шлюз ", switch, "LLM" buffered as "ДLLM", three letters
        // shown). Corrected, it scored LLR 7.9 — the other model floors on the
        // foreign letters — and the keystroke fallback deleted one character
        // too many, the space before the word.
        let symbols = currentLayoutIsRussian ? [] : TextConverter.ambiguousLetterSymbols(for: variant)
        let typedByLayout: (Character) -> Bool = currentLayoutIsRussian ? isCyrillic : { $0.isASCII }
        return lower.count >= minWordLength
            && lower.contains(where: { $0.isLetter })
            && lower.allSatisfy({ ($0.isLetter && typedByLayout($0)) || symbols.contains($0) })
    }

    /// Cyrillic block (U+0400–U+04FF): the letters a Russian layout types, ё included.
    private static func isCyrillic(_ char: Character) -> Bool {
        char.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) }
    }

    private static func convert(
        _ lower: String, currentLayoutIsRussian: Bool,
        variant: TextConverter.RussianKeyboardVariant
    ) -> String {
        currentLayoutIsRussian
            ? TextConverter.toLatin(lower, variant: variant)
            : TextConverter.toCyrillic(lower, variant: variant)
    }

    /// One formula for both directions: target-language plausibility of the
    /// conversion minus current-language plausibility of the original.
    ///
    /// Neither side is filtered, and both are scored whole. б, ю, ж, х, э,
    /// ъ and ё sit on punctuation keys: in a Russian word they are letters
    /// of the Russian model, and in its Latin spelling ("[e;t" for «хуже»,
    /// ",sk" for «был») they are symbols the English model charges the
    /// floor for — on whichever side that spelling is, typed or converted.
    /// Cutting them out, as the old letter-frequency score could afford to,
    /// left fragments no Russian word is made of — "был" scored as "ыл",
    /// "ещё" as "ещ" — and flagged the most frequent words of the language;
    /// skipping them in the English model alone made the Latin spelling
    /// look English instead («хуже» scored as "et" and was missed, «хужеб»
    /// as "et" and was corrected). The dot of a domain («фьфящтюву» →
    /// "amazon.de") is charged the same way; domains are caught by
    /// looksLikeDomain, not by the score.
    private static func layoutLLR(original: String, converted: String, currentLayoutIsRussian: Bool) -> Double {
        currentLayoutIsRussian
            ? englishScore(converted) - russianScore(original)
            : russianScore(converted) - englishScore(original)
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

    // MARK: - Carrying short function words

    /// Short function words — prepositions, conjunctions, particles and the
    /// most common short pronouns — recognised as the *conversion* of a word
    /// that is to be corrected together with the wrong-layout word after it.
    ///
    /// Curated rather than derived, for the same reason as knownTLDs: there
    /// is no heuristic left to lean on. A one- or two-letter word carries no
    /// frequency signal, so a score over it is noise, and lowering
    /// minWordLength or llrThresholds to admit such words would start
    /// converting real short English ones ("the", "and", "cd", "npm").
    ///
    /// Several of the Latin keystrokes that produce an entry here are real
    /// English tokens in their own right: "c" (с), "r" (к), "e" (у), "bp"
    /// (из), "kb" (ли), "vs" (мы), "ds" (вы), "ns" (ты). That is precisely
    /// why this list is never consulted on its own — isCarriableFunctionWord
    /// is only ever reached once the *following* word has been confirmed
    /// wrong-layout, and "vs ujhjl" is not a sequence real English text
    /// produces.
    ///
    /// When adding a word, check it the way a TLD is checked: convert it to
    /// the other layout and ask whether the result appears in real text as a
    /// standalone token directly before a word of the other language.
    private static let russianFunctionWords: Set<String> = [
        "в", "во", "и", "а", "но", "да", "к", "ко", "с", "со", "о", "об",
        "у", "за", "на", "по", "до", "из", "от", "для", "над", "под",
        "при", "про", "без", "не", "ни", "то", "так", "как", "что", "же",
        "ли", "бы", "вот", "я", "мы", "вы", "ты", "он", "мне",
    ]

    /// The English half. Keeping the rule per-target-language is what makes
    /// the Russian→English direction safe for free: "и цщкду" ("и world")
    /// converts "и" to "b", and "b" is not an English function word, so a
    /// genuine one-letter Russian word standing before English text is
    /// never swept up.
    private static let englishFunctionWords: Set<String> = [
        "a", "i", "an", "the", "in", "on", "at", "to", "of", "is", "it",
        "be", "or", "and", "but", "not", "no", "so", "we", "he", "my", "do",
        "if", "as", "up", "us", "me", "by", "for",
    ]

    /// Whether `word`, left uncorrected on its own, should be corrected
    /// together with the wrong-layout word that follows it.
    ///
    /// Deliberately has no score component — see russianFunctionWords. The
    /// signal the word itself cannot supply comes from the caller's context
    /// instead, and the list bounds what that context is allowed to sweep up.
    public static func isCarriableFunctionWord(
        word: String, currentLayoutIsRussian: Bool,
        exceptions: Set<String>, variant: TextConverter.RussianKeyboardVariant
    ) -> Bool {
        let lower = word.lowercased()

        // Same guard as isWrongLayout: "об" is typed as "j,", and the comma
        // is a letter key under the Russian layout.
        guard !lower.isEmpty,
              lower.allSatisfy({ $0.isLetter || TextConverter.ambiguousLetterSymbols(for: variant).contains($0) }) else {
            return false
        }

        // User exceptions are sacrosanct
        guard !exceptions.contains(lower) else { return false }

        // Check against the function word list for the target language
        // Lowercased, as in isWrongLayout: the shifted keys convert to
        // capitals ("<s" → «Бы»).
        let converted = (currentLayoutIsRussian ?
            TextConverter.toLatin(lower, variant: variant) :
            TextConverter.toCyrillic(lower, variant: variant)).lowercased()

        if currentLayoutIsRussian {
            // User typed in Russian, target is English
            return englishFunctionWords.contains(converted)
        } else {
            // User typed in English, target is Russian
            return russianFunctionWords.contains(converted)
        }
    }

    // MARK: - Short terminal commands

    /// Shell commands too short for the score to judge — every one is below
    /// minWordLength, so isWrongLayout never sees them, and exceptions can't
    /// help either: the length guard runs before they are consulted.
    /// Longer commands are left to the score and the bundled exceptions.
    ///
    /// Only consulted with a terminal frontmost (InputMonitor), like the
    /// leading "/": there a bare "св" is "cd", elsewhere nothing says so.
    ///
    /// Every entry's Cyrillic form is checked not to be a Russian word —
    /// with NSSpellChecker and scripts/eval-data/ru-dict.txt — the same way
    /// a TLD is. "df" is left out for that reason: "ва" passes the spell
    /// checker. All entries use letter keys only, so the form is the same
    /// under both Russian variants.
    private static let terminalCommands: Set<String> = [
        "cd", "ls", "ll", "rm", "mv", "cp", "ps", "ln", "du", "go", "vi", "su", "ip",
    ]

    /// Whether `word`, typed under the Russian layout, is one of
    /// `terminalCommands` typed in the wrong layout. Russian → English only:
    /// commands are always Latin. A user exception for the word as typed
    /// wins, as everywhere else.
    public static func isTerminalCommand(
        word: String, currentLayoutIsRussian: Bool,
        exceptions: Set<String>, variant: TextConverter.RussianKeyboardVariant
    ) -> Bool {
        let lower = word.lowercased()
        // Cyrillic letters only: Latin passes through toLatin unchanged, so
        // an already-correct "cd" would otherwise match its own entry.
        guard currentLayoutIsRussian, !lower.isEmpty, lower.allSatisfy({ ("а"..."я").contains($0) || $0 == "ё" }),
              !exceptions.contains(lower)
        else { return false }
        return terminalCommands.contains(TextConverter.toLatin(lower, variant: variant))
    }

    /// Exposed for tests: the list itself, to check every entry's Cyrillic
    /// form against the Russian function words.
    static var terminalCommandsForTesting: Set<String> { terminalCommands }
}
