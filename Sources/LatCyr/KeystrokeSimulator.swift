import AppKit
import CoreGraphics

/// Fallback for apps where AX-based text replacement doesn't take effect
/// (Terminal.app, iTerm2: the visible text is a PTY render, not an
/// editable AX string — AXUIElementSetAttributeValue can report success
/// without applying anything). Simulates real keystrokes instead: delete
/// the mistyped word with synthetic Backspace presses, then type the
/// correction as a single synthetic Unicode-string keystroke.
final class KeystrokeSimulator {
    /// Tag stamped on every synthetic event this class posts, via
    /// CGEventField.eventSourceUserData. InputMonitor's own event tap
    /// checks for this tag and skips these events, so injected keystrokes
    /// never corrupt InputMonitor's word buffer or re-trigger correction.
    static let eventMarker: Int64 = 0x4C_43_59_52 // "LCYR"

    /// kVK_Delete — physical Backspace key.
    private static let backspaceKeyCode: CGKeyCode = 51

    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
    ]

    /// Whether the frontmost application is a known terminal that doesn't
    /// support AX-based text replacement.
    var isTerminalFrontmost: Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return Self.terminalBundleIDs.contains(id)
    }

    /// Delete `count` characters immediately before the cursor, then type
    /// `replacement`, via tagged synthetic keyboard events.
    func correct(deleting count: Int, typing replacement: String) {
        for _ in 0..<count {
            postKeyPress(keyCode: Self.backspaceKeyCode)
        }
        postUnicodeString(replacement)
    }

    // MARK: - Private

    private func postKeyPress(keyCode: CGKeyCode) {
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: isDown) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
            event.post(tap: .cgSessionEventTap)
        }
    }

    private func postUnicodeString(_ string: String) {
        let utf16 = Array(string.utf16)
        guard !utf16.isEmpty else { return }
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: isDown) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            event.post(tap: .cgSessionEventTap)
        }
    }
}
