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

    /// Safety cap on blind, unverified deletion: this class has no readback
    /// like the AX path does, so a runaway count must be refused rather than
    /// injected.
    private static let maxDeleteCount = 64

    /// Not private: AppDelegate checks this list before offering to
    /// register an app as hybrid, so it doesn't suggest adding one that's
    /// already covered.
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
    ]

    private let hybridAppStore: HybridAppStore

    init(hybridAppStore: HybridAppStore) {
        self.hybridAppStore = hybridAppStore
    }

    /// Whether the frontmost application is a known terminal or a
    /// user-registered hybrid app — either way, AX-based text replacement
    /// doesn't work and keystroke injection is the only option.
    var usesKeystrokeFallback: Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return Self.terminalBundleIDs.contains(id) || hybridAppStore.contains(id)
    }

    /// Delete `count` characters immediately before the cursor, then type
    /// `replacement`, via tagged synthetic keyboard events. Returns `false`
    /// if `count` is out of range or any event fails to *construct*, so the
    /// caller (InputMonitor) never switches the keyboard layout on top of a
    /// definitely-failed injection. `CGEvent.post` itself is void and
    /// reports nothing, so a `true` return means the events were
    /// successfully posted, not that the target app visibly applied them.
    @discardableResult
    func correct(deleting count: Int, typing replacement: String) -> Bool {
        guard count >= 0, count <= Self.maxDeleteCount else { return false }
        for _ in 0..<count {
            guard postKeyPress(keyCode: Self.backspaceKeyCode) else { return false }
        }
        return postUnicodeString(replacement)
    }

    // MARK: - Private

    private func postKeyPress(keyCode: CGKeyCode) -> Bool {
        // Build both events before posting either, so a construction
        // failure on keyUp never leaves an unpaired keyDown posted.
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        down.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }

    private func postUnicodeString(_ string: String) -> Bool {
        let utf16 = Array(string.utf16)
        guard !utf16.isEmpty else { return true }
        // virtualKey: 0 is a placeholder carrier for keyboardSetUnicodeString,
        // which overrides the delivered character with the Unicode payload;
        // an app that reads the keycode instead would see whatever key 0
        // maps to under the layout active at that moment — not a concern
        // for Terminal.app/iTerm2, which read the Unicode string.
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            return false
        }
        down.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }
}
