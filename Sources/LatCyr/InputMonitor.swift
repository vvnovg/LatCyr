import ApplicationServices
import CoreGraphics
import Foundation

/// Intercepts keyDown events via CGEventTap, tracks the current word, and
/// triggers layout correction (proactive on the 2nd char, retroactive on
/// word boundary).
final class InputMonitor {
    private let layoutManager = LayoutManager()
    private let textFieldController = TextFieldController()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
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
    }

    func stop() {
        guard isRunning else { return }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
        currentWord = ""
    }

    // MARK: - Event handling

    private func handle(event: CGEvent, type: CGEventType) {
        guard type == .keyDown else { return }
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

        if char.isLetter {
            if currentWord.isEmpty {
                currentLayoutIsRussian = layoutManager.isRussian
            }
            currentWord.append(char)
            if currentWord.count == 2 {
                scheduleProactiveCheck()
            }
        } else if isWordBoundary(char) {
            scheduleRetroactiveCheck()
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

    private func scheduleRetroactiveCheck() {
        let word = currentWord
        let wasRussian = currentLayoutIsRussian
        DispatchQueue.main.asyncAfter(deadline: .now() + correctionDelay) { [weak self] in
            self?.performRetroactiveFix(word: word, wasRussian: wasRussian)
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

    private func performRetroactiveFix(word: String, wasRussian: Bool) {
        guard LanguageDetector.isWrongLayout(word: word, currentLayoutIsRussian: wasRussian) else { return }
        applyCorrection(word: word, wasRussian: wasRussian, replacePrefix: false)
    }

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

    private func isWordBoundary(_ char: Character) -> Bool {
        char.isWhitespace || char.isPunctuation || char.isNewline || char.isNumber || char.isSymbol
    }
}
