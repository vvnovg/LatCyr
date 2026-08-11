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

    /// Whether the element is a secure (password) field.
    func isSecure(_ element: AXUIElement) -> Bool {
        guard let role = role(of: element) else { return false }
        return role == "AXSecureTextField"
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

    /// Replace the word immediately before the cursor with `replacement`.
    func replaceLastWord(_ word: String, with replacement: String, in element: AXUIElement) -> Bool {
        guard let text = text(of: element),
              let range = selectedRange(of: element) else { return false }
        let cursor = range.location + range.length
        let utf16 = Array(text.utf16)
        guard cursor >= 0, cursor <= utf16.count else { return false }

        var end = cursor
        while end > 0 && isBoundary(utf16[end - 1]) { end -= 1 }
        var start = end
        while start > 0 && !isBoundary(utf16[start - 1]) { start -= 1 }
        guard start < end else { return false }

        let actualWord = String(utf16CodeUnits: Array(utf16[start..<end]), count: end - start)
        guard actualWord.lowercased() == word.lowercased() else { return false }

        return replace(range: start..<end, with: replacement, in: element, utf16: utf16)
    }

    /// Replace the first `prefix.count` characters of the current word with
    /// `replacement` (used by the proactive path).
    func replacePrefix(_ prefix: String, with replacement: String, in element: AXUIElement) -> Bool {
        guard let text = text(of: element),
              let range = selectedRange(of: element) else { return false }
        let cursor = range.location + range.length
        let utf16 = Array(text.utf16)
        guard cursor >= 0, cursor <= utf16.count else { return false }

        var start = cursor
        while start > 0 && !isBoundary(utf16[start - 1]) { start -= 1 }
        let prefixEnd = start + prefix.utf16.count
        guard prefixEnd <= utf16.count else { return false }

        let actualPrefix = String(utf16CodeUnits: Array(utf16[start..<prefixEnd]), count: prefix.utf16.count)
        guard actualPrefix.lowercased() == prefix.lowercased() else { return false }

        return replace(range: start..<prefixEnd, with: replacement, in: element, utf16: utf16)
    }

    // MARK: - Private

    private func replace(range: Range<Int>, with replacement: String, in element: AXUIElement, utf16: [UInt16]) -> Bool {
        let newText = String(utf16CodeUnits: Array(utf16[0..<range.lowerBound]), count: range.lowerBound)
            + replacement
            + String(utf16CodeUnits: Array(utf16[range.upperBound..<utf16.count]), count: utf16.count - range.upperBound)
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, newText as CFTypeRef) == .success else { return false }
        let newCursor = range.lowerBound + replacement.utf16.count
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

    private func setCursor(_ position: Int, in element: AXUIElement) -> Bool {
        var range = CFRange(location: position, length: 0)
        guard let axValue = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axValue) == .success
    }

    private func isBoundary(_ unit: UInt16) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return true }
        let ch = Character(scalar)
        return ch.isWhitespace || ch.isPunctuation || ch.isSymbol || ch.isNewline
    }
}
