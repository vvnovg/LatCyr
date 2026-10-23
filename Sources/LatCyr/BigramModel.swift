import Foundation

/// Letter-bigram model of one language: how plausible a word's letter
/// *pairs* are, word boundaries included.
///
/// Single-letter frequency cannot tell "ашду" (the keys of "file" under the
/// Russian layout) from a Russian word — а, ш, д and у are all ordinary
/// Russian letters. Pairs can: "аш" opens few Russian words and "ду" rarely
/// ends one. The tables live in the generated BigramTables.swift; see
/// scripts/gen-bigrams.swift.
public struct BigramModel {
    /// Probability the generator clamps every cell to from below, so an
    /// impossible pair costs a large but finite penalty, never -infinity.
    public static let floorProbability = 1e-7
    public static let floorLogProb = log(floorProbability)

    private let index: [Character: Int]
    private let size: Int
    private let logProbs: [Float]

    /// - Parameters:
    ///   - alphabet: the model's letters, lowercase, in table order.
    ///   - logProbs: row-major `(alphabet.count + 2)²` natural-log
    ///     probabilities. Index 0 is the word-start marker, 1...N the
    ///     letters in `alphabet` order, N+1 the word-end marker; the row is
    ///     the first character of a pair, the column the second.
    public init(alphabet: String, logProbs: [Float]) {
        let letters = Array(alphabet)
        size = letters.count + 2
        precondition(logProbs.count == size * size, "bigram table must have (alphabet.count + 2)² cells")
        var index: [Character: Int] = [:]
        for (i, letter) in letters.enumerated() { index[letter] = i + 1 }
        self.index = index
        self.logProbs = logProbs
    }

    /// Mean natural-log probability over every transition of "^word$".
    ///
    /// Lowercases and folds "ё" into "е" (the tables are built the same way).
    /// A character outside the alphabet is an impossible symbol of the
    /// language: it keeps its position, and both transitions through it
    /// cost the floor. Skipping such characters instead, as the old
    /// letter-frequency score did, joined their neighbours directly and
    /// scored "[e;t" («хуже» typed under the English layout) as the
    /// perfectly English "et" — the letters х, ж, б, ю, э, ъ and ё sit on
    /// punctuation keys, so a word made of them looked English on the typed
    /// side and lost. Whatever a caller wants let through (the apostrophe
    /// of "don't", for the English model) it strips before scoring. An empty
    /// word scores `floorLogProb`.
    public func averageLogProb(_ word: String) -> Double {
        let positions = word.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .map { index[$0] ?? Self.unknown }
        guard !positions.isEmpty else { return Self.floorLogProb }

        var previous = 0
        var sum = 0.0
        for position in positions + [size - 1] {
            sum += previous == Self.unknown || position == Self.unknown
                ? Self.floorLogProb
                : Double(logProbs[previous * size + position])
            previous = position
        }
        return sum / Double(positions.count + 1)
    }

    /// Position of a character outside the alphabet.
    private static let unknown = -1
}
