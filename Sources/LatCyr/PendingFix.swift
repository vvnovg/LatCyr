import Foundation

/// The last completed word that LatCyr left as typed, remembered at the
/// space after it. A correction of the next word turns it into a
/// PendingFix candidate.
struct PreviousWord {
    let text: String
    let layoutIsRussian: Bool
    let variant: TextConverter.RussianKeyboardVariant
}

/// What double Shift fixes when nothing is selected: the word right before
/// the latest automatic correction.
enum PendingFix {
    /// AX apps: the word's position, re-verified against the live text
    /// before any write.
    case anchored(anchor: TextFieldController.WordAnchor, word: String, variant: TextConverter.RussianKeyboardVariant)
    /// Hybrid apps and terminals: the word and the exact text after it on
    /// screen (space, corrected span, boundary). Valid only while no key has
    /// been pressed since — `keyDownCount` is InputMonitor's count at the
    /// correction.
    case keystroke(word: String, tail: String, keyDownCount: Int, variant: TextConverter.RussianKeyboardVariant)
}
