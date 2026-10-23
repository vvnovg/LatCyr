import Foundation

/// What the retroactive keystroke fallback deletes and retypes. Pure, so
/// the arithmetic the fallback runs blind — there is no AX text to verify
/// it against — is under unit tests.
///
/// The fallback fires `correctionDelay` after the boundary key, and a fast
/// typist has kept going: the screen before the cursor is then
/// `span + boundary + tail`, not `span + boundary`. Deleting by the span
/// alone eats the tail and leaves the span's first characters standing
/// ("ghbdtn v" → "gпривет "), while the word buffer, which still holds the
/// tail, over-deletes by its length at the next correction and eats the
/// space before that word ("gпривет rjulf" → "gприветкогда"). So the tail
/// is deleted too and retyped converted: it was typed under the same
/// wrong layout as the span, before the layout was switched.
struct KeystrokeFallbackPlan: Equatable {
    let deleteCount: Int
    let typed: String

    init(span: String, converted: String, boundary: Character, tail: String, convertedTail: String) {
        deleteCount = span.count + 1 + tail.count
        typed = converted + String(boundary) + convertedTail
    }

    /// The text on screen after the boundary, when it is known exactly: the
    /// word buffer, provided every keyDown since the boundary went into it
    /// (a letter appended, a Backspace that removed one). Any other key —
    /// a second boundary, an arrow, a shortcut, a Backspace past the word's
    /// start — changed the screen in a way the buffer does not describe:
    /// nil, and the caller must not inject keystrokes blind.
    static func tail(buffer: String, keyDownsSinceBoundary: Int, keyDownsInBuffer: Int) -> String? {
        keyDownsSinceBoundary == keyDownsInBuffer ? buffer : nil
    }
}
