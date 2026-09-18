import Foundation

/// Short function words seen since the last reset, waiting to be corrected
/// together with the next word that turns out to be wrong-layout.
///
/// A pure value type on purpose: *what* may be carried is LanguageDetector's
/// decision, *whether the chain is still valid* is this type's, and neither
/// touches a system API — so both stay unit-tested, unlike the AX and event
/// tap wrappers that use them.
struct CarryBuffer {
    /// Ceiling on the chain length. It bounds how many characters the
    /// terminal keystroke fallback deletes blind: that path has no readback
    /// to verify against, so an unbounded chain would grow unverified
    /// deletion without limit.
    static let maxWords = 3

    private var words: [String] = []
    private var layoutIsRussian = false
    private var variant: TextConverter.RussianKeyboardVariant = .pc

    /// Append a word to the chain. A word typed under a different layout or
    /// Russian variant starts a fresh chain instead of extending the old
    /// one: the user may have switched by hand between the two words, and
    /// then the earlier links describe text in the other layout.
    mutating func append(
        _ word: String, layoutIsRussian: Bool,
        variant: TextConverter.RussianKeyboardVariant
    ) {
        if !words.isEmpty, layoutIsRussian != self.layoutIsRussian || variant != self.variant {
            words.removeAll()
        }
        self.layoutIsRussian = layoutIsRussian
        self.variant = variant
        words.append(word)
        // Drop from the front, never the back: the chain has to stay
        // contiguous with the word that follows it.
        if words.count > Self.maxWords {
            words.removeFirst(words.count - Self.maxWords)
        }
    }

    mutating func reset() {
        words.removeAll()
    }

    /// The chain in typing order, or nothing when it belongs to a different
    /// layout or Russian variant than the correction about to be applied.
    func carried(
        layoutIsRussian: Bool, variant: TextConverter.RussianKeyboardVariant
    ) -> [String] {
        guard layoutIsRussian == self.layoutIsRussian, variant == self.variant else { return [] }
        return words
    }
}
