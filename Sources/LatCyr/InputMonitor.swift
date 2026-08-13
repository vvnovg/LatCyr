import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Intercepts keyDown events via CGEventTap, tracks the current word, and
/// triggers layout correction (proactive on the 2nd char, retroactive on
/// word boundary).
final class InputMonitor {
    private let layoutManager = LayoutManager()
    private let textFieldController = TextFieldController()
    private let keystrokeSimulator: KeystrokeSimulator
    /// Exposed (not private) so AppDelegate's menu actions can add words —
    /// adding an exception must work whether or not the monitor is running.
    let exceptionStore = ExceptionStore()
    /// Same reasoning as exceptionStore.
    let hybridAppStore = HybridAppStore()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var appActivationObserver: NSObjectProtocol?
    private(set) var isRunning = false

    init() {
        keystrokeSimulator = KeystrokeSimulator(hybridAppStore: hybridAppStore)
        exceptionStore.load()
        hybridAppStore.load()
    }

    // Word buffer state
    private var currentWord = ""
    private var currentLayoutIsRussian = false
    private var currentRussianVariant: TextConverter.RussianKeyboardVariant = .pc

    /// Delay before applying a correction, letting the app process the
    /// boundary key first. Tunable.
    private let correctionDelay: TimeInterval = 0.05

    /// Keycodes of modifier keys (Cmd, Shift, CapsLock, Option, Control, Fn).
    private let modifierKeyCodes: Set<CGKeyCode> = [55, 56, 57, 58, 59, 60, 61, 62, 63]

    func start() {
        guard !isRunning else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<InputMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handle(event: event, type: type)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true

        // The word buffer isn't bound to the app it was typed in — a mouse-
        // driven focus change fires no keystroke. Reset it on every app
        // switch so a stale word from another app can't drive a correction
        // (e.g. the terminal fallback) against text it was never typed into.
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.currentWord = ""
        }
    }

    func stop() {
        guard isRunning else { return }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
        }
        eventTap = nil
        runLoopSource = nil
        appActivationObserver = nil
        isRunning = false
        currentWord = ""
    }

    // MARK: - Event handling

    private func handle(event: CGEvent, type: CGEventType) {
        // The system disables a tap whose callback takes too long, and after
        // certain user input. Both types arrive here regardless of
        // eventsOfInterest, and without re-enabling the tap the app goes
        // silently dead until relaunch — the menu bar item still reads
        // "включено" while nothing is being monitored.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        guard type == .keyDown else { return }
        // Ignore our own synthetic keystrokes (KeystrokeSimulator fallback) —
        // otherwise they'd corrupt the word buffer or re-trigger correction.
        guard event.getIntegerValueField(.eventSourceUserData) != KeystrokeSimulator.eventMarker else { return }
        let flags = event.flags
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        // Skip shortcuts (Cmd/Ctrl held).
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { return }
        // Skip modifier keys themselves.
        if modifierKeyCodes.contains(keyCode) { return }

        // Backspace (kVK_Delete = 51): shrink the word buffer.
        if keyCode == 51 {
            if !currentWord.isEmpty { currentWord.removeLast() }
            return
        }

        guard let char = layoutManager.character(forKeyCode: keyCode, flags: flags) else {
            currentWord = ""
            return
        }

        // Read live, not from the stored field: on the very first character
        // of a new word this runs before currentRussianVariant is captured
        // below, and using a stale value here (from the *previous* word)
        // could misclassify a genuinely-ambiguous key if the user switched
        // Russian variants between words.
        if char.isLetter || TextConverter.ambiguousLetterSymbols(for: layoutManager.currentRussianVariant).contains(char) {
            if currentWord.isEmpty {
                currentLayoutIsRussian = layoutManager.isRussian
                currentRussianVariant = layoutManager.currentRussianVariant
            }
            currentWord.append(char)
            if currentWord.count == 2 {
                scheduleProactiveCheck()
            }
        } else if isWordBoundary(char) {
            if currentWord.isEmpty {
                scheduleLeadingCharCheck(char)
            } else if LanguageDetector.isWrongLayout(word: currentWord, currentLayoutIsRussian: currentLayoutIsRussian, exceptions: exceptionStore.words, variant: currentRussianVariant) {
                if char.isNewline || char == "\t" {
                    applyCorrectionNow(word: currentWord, wasRussian: currentLayoutIsRussian, variant: currentRussianVariant, boundary: char)
                } else {
                    scheduleRetroactiveCheck(word: currentWord, wasRussian: currentLayoutIsRussian, variant: currentRussianVariant, boundary: char)
                }
            }
            currentWord = ""
        } else {
            currentWord = ""
        }
    }

    // MARK: - Correction

    private func scheduleProactiveCheck() {
        let word = currentWord
        let wasRussian = currentLayoutIsRussian
        let variant = currentRussianVariant
        DispatchQueue.main.asyncAfter(deadline: .now() + correctionDelay) { [weak self] in
            self?.performProactiveFix(word: word, wasRussian: wasRussian, variant: variant)
        }
    }

    private func scheduleLeadingCharCheck(_ char: Character) {
        let wasRussian = layoutManager.isRussian
        DispatchQueue.main.asyncAfter(deadline: .now() + correctionDelay) { [weak self] in
            self?.performLeadingCharCheck(char: char, wasRussian: wasRussian)
        }
    }

    private func scheduleRetroactiveCheck(word: String, wasRussian: Bool, variant: TextConverter.RussianKeyboardVariant, boundary: Character) {
        // Capture the word's position now, synchronously — not 50ms from
        // now, when applyCorrection actually runs. If the user starts the
        // next word without pausing, a cursor-relative lookup done later
        // would find that new word instead of this one and silently fail
        // to correct it (see WordAnchor's doc comment). nil is fine here:
        // it means no AX-correctable target (e.g. a terminal), and the
        // delayed call still runs so the keystroke fallback gets a chance.
        let anchor = textFieldController.captureWordAnchor(matching: word, variant: variant)
        DispatchQueue.main.asyncAfter(deadline: .now() + correctionDelay) { [weak self] in
            self?.applyCorrection(word: word, wasRussian: wasRussian, variant: variant, replacePrefix: false, boundary: boundary, anchor: anchor)
        }
    }

    /// Correct right now, inside the event callback, skipping correctionDelay.
    /// That delay exists so the app can print the boundary character before we
    /// rewrite the text — but Enter and Tab print nothing, and they trigger an
    /// app action immediately (navigation, form submit, focus change). By the
    /// time a delayed correction fired, the browser has already sent the wrong
    /// request. The tap is installed at .headInsertEventTap, so the work done
    /// here lands before the app ever sees the key.
    ///
    /// AX-only in practice: applyCorrection's keystroke fallback already
    /// refuses Enter and Tab, so nothing is injected into a terminal — that
    /// case stays uncorrected, by design.
    private func applyCorrectionNow(
        word: String, wasRussian: Bool,
        variant: TextConverter.RussianKeyboardVariant, boundary: Character
    ) {
        let anchor = textFieldController.captureWordAnchor(matching: word, variant: variant)
        applyCorrection(
            word: word, wasRussian: wasRussian, variant: variant,
            replacePrefix: false, boundary: boundary, anchor: anchor
        )
    }

    private func performProactiveFix(word: String, wasRussian: Bool, variant: TextConverter.RussianKeyboardVariant) {
        guard word.count == 2 else { return }
        let chars = Array(word)
        guard LanguageDetector.proactiveSwitchSignal(
            first: chars[0], second: chars[1], currentLayoutIsRussian: wasRussian
        ) else { return }
        // Fast-typing guard: if the buffer has grown past the captured word,
        // bail and let the retroactive path handle the full word.
        guard currentWord == word else { return }
        if applyCorrection(word: word, wasRussian: wasRussian, variant: variant, replacePrefix: true) {
            currentWord = ""
        }
    }

    private func performLeadingCharCheck(char: Character, wasRussian: Bool) {
        // Scope: terminal-only. Outside a terminal there's no strong reason
        // to treat a bare "/" as "the user is about to type a path" — this
        // reuses the same allowlist as the AX-replacement fallback.
        guard keystrokeSimulator.isTerminalFrontmost else { return }
        guard LanguageDetector.proactiveSingleCharSwitchSignal(
            first: char, currentLayoutIsRussian: wasRussian
        ) else { return }
        // The character itself is already correct on screen (this isn't an
        // ambiguous key — see CLAUDE.md) — only the layout needs fixing, so
        // there's no text to replace and no AX/KeystrokeSimulator involved.
        switchLayout(wasRussian: wasRussian)
        // Drop whatever's accumulated since — it started under the layout
        // we just left, and letting it mix with post-switch typing would
        // feed a stale currentLayoutIsRussian into a later correction.
        currentWord = ""
    }

    @discardableResult
    private func applyCorrection(
        word: String, wasRussian: Bool, variant: TextConverter.RussianKeyboardVariant, replacePrefix: Bool,
        boundary: Character? = nil, anchor: TextFieldController.WordAnchor? = nil
    ) -> Bool {
        let converted = wasRussian ? TextConverter.toLatin(word, variant: variant) : TextConverter.toCyrillic(word, variant: variant)

        let axReplaced: Bool
        if replacePrefix {
            // Proactive path: replacePrefix operates on the word still
            // being typed (no boundary yet). It's re-derived from the live
            // cursor at fire time, same as always — the caller already
            // guards `currentWord == word` before scheduling this, so a
            // fast-typing mismatch bails before we get here.
            if let element = textFieldController.focusedTextElement(),
               !textFieldController.isOwnApp(element),
               !textFieldController.isSecure(element),
               textFieldController.isEditableText(element) {
                axReplaced = textFieldController.replacePrefix(word, with: converted, in: element, variant: variant)
            } else {
                axReplaced = false
            }
        } else if let anchor {
            // Retroactive path: anchor was captured synchronously when the
            // boundary key landed, so it targets the right word even if the
            // user has since started typing the next one.
            axReplaced = textFieldController.replaceAnchoredWord(anchor, word: word, with: converted)
        } else {
            axReplaced = false
        }

        if axReplaced {
            switchLayout(wasRussian: wasRussian)
            return true
        }

        // AX replacement didn't take (no element, or the app reported
        // success without applying it — e.g. a terminal's PTY-rendered
        // view). Fall back to simulated keystrokes, restricted to known
        // terminals: without an AX element we can't check isSecure/isOwnApp,
        // so blindly injecting into arbitrary apps would be unsafe.
        guard keystrokeSimulator.usesKeystrokeFallback else { return false }

        let deleteCount: Int
        let typed: String
        if let boundary {
            // correctionDelay deliberately let the app process the boundary
            // key before this runs, so it's already on screen and the
            // cursor sits after it — deleting must eat the boundary too,
            // and the retyped text must put it back.
            guard !boundary.isNewline, boundary != "\t" else {
                // Enter already submitted the line to the shell; by now
                // focus may have moved to a fresh prompt or a program the
                // command launched. Tab is consumed by shell completion and
                // echoes nothing (or rewrites the whole line) — either way
                // it isn't the one extra on-screen character this arithmetic
                // assumes. Injecting keystrokes in either case is unsafe.
                return false
            }
            deleteCount = word.count + 1
            typed = converted + String(boundary)
        } else {
            deleteCount = word.count
            typed = converted
        }
        guard keystrokeSimulator.correct(deleting: deleteCount, typing: typed) else { return false }
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

    private func isWordBoundary(_ char: Character) -> Bool {
        char.isWhitespace || char.isPunctuation || char.isNewline || char.isNumber || char.isSymbol
    }
}
