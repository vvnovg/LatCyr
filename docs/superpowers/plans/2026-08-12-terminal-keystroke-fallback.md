# Terminal Keystroke-Simulation Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make LatCyr's word correction actually apply inside Terminal.app and iTerm2, where the existing Accessibility (AX) text-replacement path silently no-ops.

**Architecture:** Add a new thin system wrapper `KeystrokeSimulator` that (a) recognizes an allowlist of terminal bundle IDs and (b) injects synthetic Backspace + Unicode-string keyboard events via `CGEvent`, tagged so `InputMonitor`'s own event tap ignores them. Wire it into `InputMonitor.applyCorrection` as a fallback that only runs when the AX path fails and the frontmost app is a known terminal.

**Tech Stack:** Swift Package (no Xcode), `CoreGraphics` (`CGEvent`), `AppKit` (`NSWorkspace`).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-12-terminal-keystroke-fallback-design.md`.
- Fallback fires **only** when the AX path in `applyCorrection` fails **and** the frontmost app's bundle ID is in the allowlist `com.apple.Terminal`, `com.googlecode.iterm2`. It must never run unconditionally for arbitrary apps (no AX element ⇒ no way to check `isSecure`/`isOwnApp`, so blind injection elsewhere is unsafe).
- Every synthetic event `KeystrokeSimulator` posts must be tagged via `CGEventField.eventSourceUserData` with `KeystrokeSimulator.eventMarker`, and `InputMonitor.handle(event:)` must skip any event carrying that tag before doing anything else with it.
- The existing invariant "replace before switching layout" (documented in `CLAUDE.md`) applies to the new fallback path too: only call `layoutManager.switchToEnglish()/switchToRussian()` after the injection actually happened.
- `KeystrokeSimulator` is a thin wrapper over system APIs (`CGEvent`, `NSWorkspace`) — per the project's established pattern (`LayoutManager`, `TextFieldController`, `PermissionManager` have no automated tests), it is verified by `swift build` and manual testing, not XCTest. Do not add speculative unit tests for it.
- Commit messages: conventional style (`feat:`, `fix:`, `docs:`), per `CLAUDE.md`.
- Build/verify commands: `swift build`, `swift test`.

---

### Task 1: `KeystrokeSimulator` — terminal detection and event injection

**Files:**
- Create: `Sources/LatCyr/KeystrokeSimulator.swift`

**Interfaces:**
- Produces (used by Task 2):
  - `static let KeystrokeSimulator.eventMarker: Int64` — tag value stamped on every synthetic event this class posts.
  - `var KeystrokeSimulator.isTerminalFrontmost: Bool` — true if the frontmost application's bundle ID is in the terminal allowlist.
  - `func KeystrokeSimulator.correct(deleting count: Int, typing replacement: String)` — posts `count` synthetic Backspace key presses, then one synthetic Unicode-string keystroke carrying `replacement`.

- [ ] **Step 1: Write `KeystrokeSimulator.swift`**

```swift
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
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!` with no errors or warnings about `KeystrokeSimulator.swift`.

- [ ] **Step 3: Commit**

```bash
git add Sources/LatCyr/KeystrokeSimulator.swift
git commit -m "$(cat <<'EOF'
feat: add KeystrokeSimulator for terminal correction fallback

Terminal.app and iTerm2 render text from the PTY, not from an editable
AX string, so AXUIElementSetAttributeValue can report success without
applying anything. KeystrokeSimulator injects synthetic Backspace +
Unicode-string keyboard events instead, tagged via
CGEventField.eventSourceUserData so InputMonitor's own event tap can
recognize and skip them.
EOF
)"
```

---

### Task 2: Wire the fallback into `InputMonitor`

**Files:**
- Modify: `Sources/LatCyr/InputMonitor.swift:8-10` (add `keystrokeSimulator` property)
- Modify: `Sources/LatCyr/InputMonitor.swift:68-70` (skip tagged synthetic events in `handle`)
- Modify: `Sources/LatCyr/InputMonitor.swift:141-163` (`applyCorrection`: try AX first, fall back to `KeystrokeSimulator` in terminals)

**Interfaces:**
- Consumes (from Task 1): `KeystrokeSimulator.eventMarker: Int64`, `KeystrokeSimulator().isTerminalFrontmost: Bool`, `KeystrokeSimulator().correct(deleting:typing:)`.

- [ ] **Step 1: Add the `keystrokeSimulator` property**

In `Sources/LatCyr/InputMonitor.swift`, change:

```swift
    private let layoutManager = LayoutManager()
    private let textFieldController = TextFieldController()
```

to:

```swift
    private let layoutManager = LayoutManager()
    private let textFieldController = TextFieldController()
    private let keystrokeSimulator = KeystrokeSimulator()
```

- [ ] **Step 2: Skip tagged synthetic events in `handle`**

Change:

```swift
    private func handle(event: CGEvent, type: CGEventType) {
        guard type == .keyDown else { return }
        let flags = event.flags
```

to:

```swift
    private func handle(event: CGEvent, type: CGEventType) {
        guard type == .keyDown else { return }
        // Ignore our own synthetic keystrokes (KeystrokeSimulator fallback) —
        // otherwise they'd corrupt the word buffer or re-trigger correction.
        guard event.getIntegerValueField(.eventSourceUserData) != KeystrokeSimulator.eventMarker else { return }
        let flags = event.flags
```

- [ ] **Step 3: Restructure `applyCorrection` to try AX first, then the terminal fallback**

Replace:

```swift
    @discardableResult
    private func applyCorrection(word: String, wasRussian: Bool, replacePrefix: Bool) -> Bool {
        let converted = wasRussian ? TextConverter.toLatin(word) : TextConverter.toCyrillic(word)
        guard let element = textFieldController.focusedTextElement(),
              !textFieldController.isOwnApp(element),
              !textFieldController.isSecure(element),
              textFieldController.isEditableText(element) else { return false }

        let replaced: Bool
        if replacePrefix {
            replaced = textFieldController.replacePrefix(word, with: converted, in: element)
        } else {
            replaced = textFieldController.replaceLastWord(word, with: converted, in: element)
        }
        guard replaced else { return false }

        if wasRussian {
            layoutManager.switchToEnglish()
        } else {
            layoutManager.switchToRussian()
        }
        return true
    }
```

with:

```swift
    @discardableResult
    private func applyCorrection(word: String, wasRussian: Bool, replacePrefix: Bool) -> Bool {
        let converted = wasRussian ? TextConverter.toLatin(word) : TextConverter.toCyrillic(word)

        if let element = textFieldController.focusedTextElement(),
           !textFieldController.isOwnApp(element),
           !textFieldController.isSecure(element),
           textFieldController.isEditableText(element) {
            let replaced: Bool
            if replacePrefix {
                replaced = textFieldController.replacePrefix(word, with: converted, in: element)
            } else {
                replaced = textFieldController.replaceLastWord(word, with: converted, in: element)
            }
            if replaced {
                switchLayout(wasRussian: wasRussian)
                return true
            }
        }

        // AX replacement didn't take (no element, or the app reported
        // success without applying it — e.g. a terminal's PTY-rendered
        // view). Fall back to simulated keystrokes, restricted to known
        // terminals: without an AX element we can't check isSecure/isOwnApp,
        // so blindly injecting into arbitrary apps would be unsafe.
        guard keystrokeSimulator.isTerminalFrontmost else { return false }
        keystrokeSimulator.correct(deleting: word.count, typing: converted)
        switchLayout(wasRussian: wasRussian)
        return true
    }

    private func switchLayout(wasRussian: Bool) {
        if wasRussian {
            layoutManager.switchToEnglish()
        } else {
            layoutManager.switchToRussian()
        }
    }
```

- [ ] **Step 4: Build and run the test suite**

Run: `swift build && swift test`
Expected: `Build complete!`, then `Executed 16 tests, with 0 failures`.

- [ ] **Step 5: Manual test — Terminal.app**

1. `./scripts/package-app.sh && open dist/LatCyr.app`
2. Grant Accessibility + Input Monitoring to `dist/LatCyr.app` in System Settings → Privacy & Security if not already granted (re-packaging resets grants — see `CLAUDE.md`).
3. Open Terminal.app, switch to the English keyboard layout, and type a Russian word using its Latin-key positions (e.g. type `ndj.` — the physical keys for «твою») followed by a space.
4. Expected: the mistyped Latin text is deleted and replaced with the correct Cyrillic word, and the keyboard layout switches to Russian. Confirm normal typing (new words, real Backspace) after the correction still behaves correctly — the buffer must not be left in a corrupted state by the injected events.

- [ ] **Step 6: Manual test — iTerm2**

Repeat Step 5's test in iTerm2 (if installed). If iTerm2 isn't installed, note this in the task report as untested rather than skipping silently.

- [ ] **Step 7: Commit**

```bash
git add Sources/LatCyr/InputMonitor.swift
git commit -m "$(cat <<'EOF'
feat: fall back to keystroke simulation for terminal correction

InputMonitor.applyCorrection now tries the existing AX-based replacement
first; if that fails and the frontmost app is Terminal.app or iTerm2, it
falls back to KeystrokeSimulator (synthetic Backspace + Unicode-string
keystrokes) instead of silently giving up. handle() ignores
KeystrokeSimulator's own tagged synthetic events so they don't corrupt
the word buffer.
EOF
)"
```
