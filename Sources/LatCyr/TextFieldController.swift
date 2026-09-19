import ApplicationServices
import Foundation

/// Wraps the Accessibility (AX) API: focused text field, reading text,
/// replacing words.
final class TextFieldController {
    /// The focused text element, if any.
    func focusedTextElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var app: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &app) == .success,
              let appRaw = app else { return nil }
        let appElement = unsafeBitCast(appRaw, to: AXUIElement.self)
        var element: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &element) == .success,
              let elementRaw = element else { return nil }
        return unsafeBitCast(elementRaw, to: AXUIElement.self)
    }

    /// Whether the element is a secure (password) field. Checked by role
    /// *or* subrole: native AppKit password fields report
    /// kAXSecureTextFieldRole as their role, but WebKit and Chromium
    /// commonly expose an `input[type=password]` as role AXTextField with
    /// subrole AXSecureTextField instead — missing the subrole would leave
    /// browser and Electron password fields undetected.
    func isSecure(_ element: AXUIElement) -> Bool {
        role(of: element) == "AXSecureTextField" || subrole(of: element) == "AXSecureTextField"
    }

    /// Whether the element belongs to this app (anti-loop guard).
    func isOwnApp(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return false }
        return pid == getpid()
    }

    /// Whether the element exposes editable text (has a value and a range).
    func isEditableText(_ element: AXUIElement) -> Bool {
        text(of: element) != nil && selectedRange(of: element) != nil
    }

    /// The currently selected text in the focused element, if any. Returns
    /// nil for secure fields (anti password-leak) and whenever there's
    /// nothing to read (no focused element, no selection, or an app whose
    /// visible content isn't a real AX value — e.g. a terminal).
    func selectedText() -> String? {
        guard let element = focusedTextElement(), !isSecure(element) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let raw = value else { return nil }
        let text = unsafeBitCast(raw, to: CFString.self) as String
        return text.isEmpty ? nil : text
    }

    /// Whether the focused element is a secure field (password). Separate from
    /// selectedText(), whose nil answer merges "no AX selection here" with
    /// "secure field" — the clipboard fallback must distinguish them, because
    /// posting a synthetic Cmd+C at a password field is exactly what the
    /// secure-field guard exists to prevent.
    func isFocusedElementSecure() -> Bool {
        guard let element = focusedTextElement() else { return false }
        return isSecure(element)
    }

    /// Where a word sits in a text field, captured at a moment in time.
    /// `range` is fixed (UTF-16 offsets); the cursor may since have moved
    /// past it as the user kept typing — `replaceAnchoredWord` re-reads the
    /// live cursor when it applies the edit.
    struct WordAnchor {
        let element: AXUIElement
        let range: Range<Int>
    }

    /// Capture the position of the word immediately before the cursor, for
    /// later use with `replaceAnchoredWord`. Capture early (right when the
    /// boundary key is seen) rather than at correction time: `correctionDelay`
    /// means correction happens ~50ms later, and if the user has since
    /// started the next word without pausing, a cursor-relative lookup done
    /// *then* would find the new word instead — silently failing to correct
    /// the one this anchor is for. Returns nil if there's no AX-correctable
    /// target (no focused element, own app, secure field, or the text right
    /// before the cursor doesn't match `word` — e.g. a terminal, whose
    /// visible content isn't a real AX value).
    func captureWordAnchor(matching word: String, variant: TextConverter.RussianKeyboardVariant) -> WordAnchor? {
        guard let element = focusedTextElement(),
              !isOwnApp(element),
              !isSecure(element),
              isEditableText(element),
              let text = text(of: element),
              let range = selectedRange(of: element) else { return nil }
        let cursor = range.location + range.length
        let utf16 = Array(text.utf16)
        guard cursor >= 0, cursor <= utf16.count else { return nil }

        var end = cursor
        while end > 0 && isBoundary(utf16[end - 1], variant: variant) { end -= 1 }
        var start = end
        while start > 0 && !isBoundary(utf16[start - 1], variant: variant) { start -= 1 }
        guard start < end else { return nil }

        let actualWord = String(utf16CodeUnits: Array(utf16[start..<end]), count: end - start)
        guard actualWord.lowercased() == word.lowercased() else { return nil }

        return WordAnchor(element: element, range: start..<end)
    }

    /// Replace the word at `anchor` with `replacement`. Re-verifies the
    /// text at `anchor.range` still matches `word` (something else may have
    /// edited it since capture) and replaces using the *current* cursor
    /// position, so the delta shift lands correctly even if the user has
    /// typed more text after the anchored word in the meantime.
    func replaceAnchoredWord(_ anchor: WordAnchor, word: String, with replacement: String) -> Bool {
        guard let text = text(of: anchor.element),
              let liveRange = selectedRange(of: anchor.element) else { return false }
        let utf16 = Array(text.utf16)
        guard anchor.range.upperBound <= utf16.count else { return false }

        let actualWord = String(utf16CodeUnits: Array(utf16[anchor.range]), count: anchor.range.count)
        guard actualWord.lowercased() == word.lowercased() else { return false }

        let cursor = liveRange.location + liveRange.length
        return replace(range: anchor.range, with: replacement, in: anchor.element, utf16: utf16, cursor: cursor)
    }

    /// Widen `anchor` backwards over `words` — the chain of short function
    /// words typed immediately before the anchored one — so the whole span
    /// can be replaced in a single edit.
    ///
    /// One edit rather than two is not a stylistic preference: two edits
    /// would have the second computing its offsets against a snapshot the
    /// first had already invalidated.
    ///
    /// Returns nil when the live text doesn't match — the caller then
    /// corrects the anchored word alone, exactly as it did before carrying
    /// existed. That fallback is what keeps the feature strictly additive.
    func extendAnchor(_ anchor: WordAnchor, backwardOver words: [String], variant: TextConverter.RussianKeyboardVariant) -> WordAnchor? {
        guard !words.isEmpty, let text = text(of: anchor.element) else { return nil }
        let utf16 = Array(text.utf16)
        guard anchor.range.upperBound <= utf16.count,
              let start = extendRange(anchor.range, backwardOver: words, in: utf16, variant: variant) else { return nil }
        return WordAnchor(element: anchor.element, range: start..<anchor.range.upperBound)
    }

    /// Replace the first `prefix.count` characters of the current word with
    /// `replacement` (used by the proactive path). When `carried` is
    /// non-empty, `replacement` is the conversion of the whole span
    /// (carried words + prefix, single-space separated) and the replaced
    /// range starts at the first carried word instead of at the prefix.
    func replacePrefix(
        _ prefix: String, carrying carried: [String] = [], with replacement: String,
        in element: AXUIElement, variant: TextConverter.RussianKeyboardVariant
    ) -> Bool {
        guard let text = text(of: element),
              let range = selectedRange(of: element) else { return false }
        let cursor = range.location + range.length
        let utf16 = Array(text.utf16)
        guard cursor >= 0, cursor <= utf16.count else { return false }

        var start = cursor
        while start > 0 && !isBoundary(utf16[start - 1], variant: variant) { start -= 1 }
        let prefixEnd = start + prefix.utf16.count
        guard prefixEnd <= utf16.count else { return false }

        let actualPrefix = String(utf16CodeUnits: Array(utf16[start..<prefixEnd]), count: prefix.utf16.count)
        guard actualPrefix.lowercased() == prefix.lowercased() else { return false }

        var spanStart = start
        if !carried.isEmpty {
            guard let widened = extendRange(start..<prefixEnd, backwardOver: carried, in: utf16, variant: variant) else { return false }
            spanStart = widened
        }
        return replace(range: spanStart..<prefixEnd, with: replacement, in: element, utf16: utf16, cursor: cursor)
    }

    // MARK: - Private

    /// UTF-16 code unit for the space character. The only separator a chain
    /// is allowed to span: it is identical in both layouts, so converting
    /// the joined span never has to decide anything about separators.
    private static let spaceUTF16: UInt16 = 32

    private func replace(range: Range<Int>, with replacement: String, in element: AXUIElement, utf16: [UInt16], cursor: Int) -> Bool {
        let newText = String(utf16CodeUnits: Array(utf16[0..<range.lowerBound]), count: range.lowerBound)
            + replacement
            + String(utf16CodeUnits: Array(utf16[range.upperBound..<utf16.count]), count: utf16.count - range.upperBound)
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, newText as CFTypeRef) == .success else { return false }
        // Some apps (terminals, some Electron/web-based editors) report
        // .success for a value write without actually applying it — their
        // AX bridge accepts the call but the underlying view keeps its own
        // state. Read the value back to confirm the write really landed;
        // otherwise the caller would switch the layout on top of text that
        // was never corrected.
        guard text(of: element) == newText else { return false }
        // Preserve the cursor's position relative to the text: shift it by the
        // length change of the replaced range. This keeps the cursor after any
        // trailing whitespace (e.g. the space that triggered the correction),
        // so the next word is not inserted before it.
        let newCursor = cursor + (replacement.utf16.count - range.count)
        return setCursor(newCursor, in: element)
    }

    private func text(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let raw = value else { return nil }
        let cfString = unsafeBitCast(raw, to: CFString.self)
        return cfString as String
    }

    private func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let raw = value else { return nil }
        let axValue = unsafeBitCast(raw, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        AXValueGetValue(axValue, .cfRange, &range)
        return range
    }

    private func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success,
              let raw = value else { return nil }
        let cfString = unsafeBitCast(raw, to: CFString.self)
        return cfString as String
    }

    private func subrole(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success,
              let raw = value else { return nil }
        let cfString = unsafeBitCast(raw, to: CFString.self)
        return cfString as String
    }

    private func setCursor(_ position: Int, in element: AXUIElement) -> Bool {
        var range = CFRange(location: position, length: 0)
        guard let axValue = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axValue) == .success
    }

    private func isBoundary(_ unit: UInt16, variant: TextConverter.RussianKeyboardVariant) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return true }
        let ch = Character(scalar)
        if TextConverter.ambiguousLetterSymbols(for: variant).contains(ch) { return false }
        return ch.isWhitespace || ch.isPunctuation || ch.isSymbol || ch.isNewline || ch.isNumber
    }

    /// The lower bound `range` reaches when widened backwards over `words`,
    /// each preceded by exactly one space, or nil if the text doesn't match.
    /// Not private: exercised directly by ExtendRangeTests, since it's a pure
    /// function over a `[UInt16]` array and needs no AX call.
    ///
    /// After the loop matches every link, the resulting start must itself
    /// sit at a real word boundary — mirroring the same check
    /// `captureWordAnchor` makes for the anchored word. Without it, a
    /// candidate can match the *tail* of a longer on-screen word: e.g. a
    /// stale carried word "ш" is a suffix of "наш", and the space before
    /// "наш" would otherwise satisfy the loop's own separator check, widening
    /// the range into the middle of that word instead of stopping before it.
    func extendRange(_ range: Range<Int>, backwardOver words: [String], in utf16: [UInt16], variant: TextConverter.RussianKeyboardVariant) -> Int? {
        var start = range.lowerBound
        for word in words.reversed() {
            guard start > 0, utf16[start - 1] == Self.spaceUTF16 else { return nil }
            start -= 1
            let length = word.utf16.count
            guard length > 0, start >= length else { return nil }
            let candidate = String(utf16CodeUnits: Array(utf16[(start - length)..<start]), count: length)
            guard candidate.lowercased() == word.lowercased() else { return nil }
            start -= length
        }
        guard start == 0 || isBoundary(utf16[start - 1], variant: variant) else { return nil }
        return start
    }
}
