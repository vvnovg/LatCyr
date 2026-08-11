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
    private let keystrokeSimulator = KeystrokeSimulator()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var appActivationObserver: NSObjectProtocol?
    private(set) var isRunning = false

    // Word buffer state
    private var currentWord = ""
    private var currentLayoutIsRussian = false

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

        if char.isLetter || TextConverter.ambiguousLetterSymbols.contains(char) {
            if currentWord.isEmpty {
                currentLayoutIsRussian = layoutManager.isRussian
            }
            currentWord.append(char)
            if currentWord.count == 2 {
                scheduleProactiveCheck()
            }
        } else if isWordBoundary(char) {
            scheduleRetroactiveCheck(boundary: char)
            currentWord = ""
        } else {
            currentWord = ""
        }
    }

    // MARK: - Correction

    private func scheduleProactiveCheck() {
        let word = currentWord
        let wasRussian = currentLayoutIsRussian
        DispatchQueue.main.asyncAfter(deadline: .now() + correctionDelay) { [weak self] in
            self?.performProactiveFix(word: word, wasRussian: wasRussian)
        }
    }

    private func scheduleRetroactiveCheck(boundary: Character) {
        let word = currentWord
        let wasRussian = currentLayoutIsRussian
        DispatchQueue.main.asyncAfter(deadline: .now() + correctionDelay) { [weak self] in
            self?.performRetroactiveFix(word: word, wasRussian: wasRussian, boundary: boundary)
        }
    }

    private func performProactiveFix(word: String, wasRussian: Bool) {
        guard word.count == 2 else { return }
        let chars = Array(word)
        guard LanguageDetector.proactiveSwitchSignal(
            first: chars[0], second: chars[1], currentLayoutIsRussian: wasRussian
        ) else { return }
        // Fast-typing guard: if the buffer has grown past the captured word,
        // bail and let the retroactive path handle the full word.
        guard currentWord == word else { return }
        if applyCorrection(word: word, wasRussian: wasRussian, replacePrefix: true) {
            currentWord = ""
        }
    }

    private func performRetroactiveFix(word: String, wasRussian: Bool, boundary: Character) {
        guard LanguageDetector.isWrongLayout(word: word, currentLayoutIsRussian: wasRussian) else { return }
        applyCorrection(word: word, wasRussian: wasRussian, replacePrefix: false, boundary: boundary)
    }

    @discardableResult
    private func applyCorrection(word: String, wasRussian: Bool, replacePrefix: Bool, boundary: Character? = nil) -> Bool {
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

        let deleteCount: Int
        let typed: String
        if let boundary {
            // correctionDelay deliberately let the app process the boundary
            // key before this runs, so it's already on screen and the
            // cursor sits after it — deleting must eat the boundary too,
            // and the retyped text must put it back.
            guard !boundary.isNewline else {
                // Enter already submitted the line to the shell; by now
                // focus may have moved to a fresh prompt or a program the
                // command launched. Injecting keystrokes there is unsafe.
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
