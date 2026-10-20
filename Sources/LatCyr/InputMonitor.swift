import AppKit
import ApplicationServices
import Carbon
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
    /// One instance for the whole app: its re-entry guard only works per
    /// instance. AppDelegate's "add selection to exceptions" uses it too.
    let clipboardReader = ClipboardReader()
    private lazy var manualFixer = ManualFixer(
        textFieldController: textFieldController, keystrokeSimulator: keystrokeSimulator,
        clipboardReader: clipboardReader, exceptionStore: exceptionStore, layoutManager: layoutManager
    )

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var appActivationObserver: NSObjectProtocol?
    /// See KeyFlowDiagnostics: the only way silence (tap running, no keys)
    /// ever shows up in the log.
    private var keyFlow: KeyFlowDiagnostics?
    private var diagnosticsTimer: Timer?
    private let diagnosticsInterval: TimeInterval = 5
    private(set) var isRunning = false

    init() {
        keystrokeSimulator = KeystrokeSimulator(hybridAppStore: hybridAppStore)
        exceptionStore.load()
        hybridAppStore.load()
        onDoubleShift = { [weak self] in
            self?.fixAndRemember { outcome in
                if case .fixed = outcome { return }
                NSSound.beep()
            }
        }
    }

    // Word buffer state
    private var currentWord = ""
    private var currentLayoutIsRussian = false
    private var currentRussianVariant: TextConverter.RussianKeyboardVariant = .pc
    /// Short function words typed just before the current one, eligible to
    /// be corrected along with it. See CarryBuffer and the CLAUDE.md entry
    /// on why the criterion is contextual rather than score-based.
    private var carry = CarryBuffer()
    /// True when `currentWord` is not a whole token but the *suffix of a
    /// token already on screen* — the residue of a mid-word layout switch
    /// (proactive fix, or the leading-char "/" switch, both of which clear
    /// `currentWord` while a partial word is still displayed). Such a buffer
    /// must never join the carry chain: no anchor or length arithmetic can
    /// tell a fragment apart from a whole short word, and carrying it treats
    /// characters that already sit inside an on-screen token as if they were
    /// a standalone one, corrupting the deletion span of the next
    /// correction (see the terminal reproduction in the finding-1 fix).
    private var currentWordIsFragment = false
    /// The word before the current one, if LatCyr left it as typed and it
    /// ended at a single space. Broken by everything that breaks the carry
    /// chain. See PreviousWord.
    private var previousWord: PreviousWord?
    /// Candidate for fix-and-remember with nothing selected. Replaced by
    /// every successful automatic correction; cleared on app switch.
    private(set) var pendingFix: PendingFix?
    /// Genuine (non-synthetic) keyDowns seen. A keystroke PendingFix is
    /// valid only while this hasn't moved since the correction.
    private(set) var keyDownCount = 0
    private var doubleShift = DoubleShiftDetector()
    /// Called on the main queue when a double Shift is recognised.
    var onDoubleShift: (() -> Void)?

    private static let leftShiftKeyCode: CGKeyCode = 56
    private static let rightShiftKeyCode: CGKeyCode = 60

    /// Delay before applying a correction, letting the app process the
    /// boundary key first. Tunable.
    private let correctionDelay: TimeInterval = 0.05

    /// Keycodes of modifier keys (Cmd, Shift, CapsLock, Option, Control, Fn).
    private let modifierKeyCodes: Set<CGKeyCode> = [55, 56, 57, 58, 59, 60, 61, 62, 63]

    func start() {
        guard !isRunning else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue) | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // .defaultTap, not .listenOnly: a listen-only tap is handed a copy
            // of the event while the system delivers the original to the app
            // in parallel — it never waits for the callback to return. That
            // makes Enter unfixable, and measurably so: with the AX write done
            // synchronously in the callback, Safari's address bar visibly
            // changed to the corrected text while the navigation had already
            // gone to the old one. An active tap lets us swallow the key,
            // correct the word, and re-post the key ourselves.
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<InputMonitor>.fromOpaque(refcon).takeUnretainedValue()
                if monitor.handle(event: event, type: type) { return nil }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.error("event tap creation failed (Input Monitoring permission?)")
            return
        }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        let secureInput = IsSecureEventInputEnabled()
        Log.info("monitor started (secure event input: \(secureInput)\(secureInput ? ", held by \(SecureInputHolder.describeCurrent())" : ""))")
        startDiagnostics(secureInput: secureInput)
        enableAccessibilityIfHybrid(NSWorkspace.shared.frontmostApplication)

        // The word buffer isn't bound to the app it was typed in — a mouse-
        // driven focus change fires no keystroke. Reset it on every app
        // switch so a stale word from another app can't drive a correction
        // (e.g. the terminal fallback) against text it was never typed into.
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            self.enableAccessibilityIfHybrid(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            Log.debug("buffer reset: app activated (word \(Sensitive(self.currentWord)), carry \(self.carry.count))")
            self.currentWord = ""
            self.currentWordIsFragment = false
            self.breakChain()
            self.pendingFix = nil
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
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
        keyFlow = nil
        isRunning = false
        currentWord = ""
        currentWordIsFragment = false
        breakChain()
        pendingFix = nil
        Log.info("monitor stopped")
    }

    // MARK: - Diagnostics

    private func startDiagnostics(secureInput: Bool) {
        keyFlow = KeyFlowDiagnostics(startedAt: Date(), secureInput: secureInput)
        // Polls rather than observes: Secure Event Input has no notification.
        // IsSecureEventInputEnabled is a cheap call; the IORegistry lookup
        // for the holder only runs on a transition.
        let timer = Timer(timeInterval: diagnosticsInterval, repeats: true) { [weak self] _ in
            guard let self, var keyFlow = self.keyFlow else { return }
            let events = keyFlow.tick(now: Date(), secureInput: IsSecureEventInputEnabled())
            self.keyFlow = keyFlow
            events.forEach(self.logKeyFlow)
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        diagnosticsTimer = timer
    }

    private func logKeyFlow(_ event: KeyFlowDiagnostics.Event) {
        switch event {
        case .firstKeyDown(let after):
            Log.info("first keyDown received \(String(format: "%.0f", after))s after start")
        case .secureInputChanged(true):
            // Error, not info: while it lasts LatCyr is deaf, and that must
            // be visible at the "errors only" level too.
            Log.error("secure event input on, held by \(SecureInputHolder.describeCurrent()) — no keys reach LatCyr until it is released")
        case .secureInputChanged(false):
            Log.info("secure event input off")
        case .noKeysSinceStart(let secureInput):
            let cause = secureInput
                ? "secure event input held by \(SecureInputHolder.describeCurrent())"
                : "secure event input off — check the Input Monitoring grant (inputMonitoring=\(CGPreflightListenEventAccess()), accessibility=\(AXIsProcessTrusted()))"
            Log.error("no keyDown received \(Int(KeyFlowDiagnostics.silenceThreshold))s after start: \(cause)")
        }
    }

    // MARK: - Event handling

    /// Everything that breaks the carry chain also breaks "the word right
    /// before": both describe text immediately behind the cursor.
    private func breakChain() {
        carry.reset()
        previousWord = nil
    }

    /// Shift transitions go to the double-Shift detector; any other modifier
    /// breaks a pending pair. Never touches the word buffer or the chain —
    /// modifiers don't type anything.
    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let input: DoubleShiftDetector.Input
        if keyCode == Self.leftShiftKeyCode || keyCode == Self.rightShiftKeyCode,
           flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]).isEmpty {
            input = flags.contains(.maskShift) ? .shiftDown : .shiftUp
        } else {
            input = .otherKey
        }
        guard doubleShift.feed(input, at: Self.seconds(event)) else { return }
        Log.debug("double shift recognised")
        DispatchQueue.main.async { [weak self] in self?.onDoubleShift?() }
    }

    /// CGEvent timestamps are nanoseconds since boot.
    private static func seconds(_ event: CGEvent) -> TimeInterval {
        TimeInterval(event.timestamp) / 1_000_000_000
    }

    /// Returns `true` when the event must be swallowed instead of delivered.
    /// Only ever true for Enter/Tab that ended a wrong-layout word: the key is
    /// re-posted by `applyCorrectionNow` once the text has been fixed.
    private func handle(event: CGEvent, type: CGEventType) -> Bool {
        // The system disables a tap whose callback takes too long, and after
        // certain user input. Both types arrive here regardless of
        // eventsOfInterest, and without re-enabling the tap the app goes
        // silently dead until relaunch — the menu bar item still reads
        // "включено" while nothing is being monitored.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.error("event tap disabled by system (\(type == .tapDisabledByTimeout ? "timeout" : "user input")), re-enabling")
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return false
        }
        if type == .leftMouseDown || type == .rightMouseDown {
            // A click can move the caret or change focus inside the same app
            // without a keyDown or an app activation, so keyDownCount alone
            // can't prove what is on screen after the correction. Drop the
            // blind keystroke candidate; .anchored is re-verified against
            // live text before any write. The caret may have moved, so the
            // chain and the previous word are no longer known to sit right
            // before it. A Shift+click (extending a selection) must not
            // count towards double Shift. O(1), mouse events never swallowed.
            if case .keystroke = pendingFix { pendingFix = nil }
            if !carry.isEmpty { Log.debug("carry reset: mouse down (carry \(carry.count))") }
            breakChain()
            _ = doubleShift.feed(.otherKey, at: Self.seconds(event))
            return false
        }
        if type == .flagsChanged {
            guard event.getIntegerValueField(.eventSourceUserData) != KeystrokeSimulator.eventMarker else { return false }
            handleFlagsChanged(event)
            return false
        }
        guard type == .keyDown else { return false }
        // Ignore our own synthetic keystrokes (KeystrokeSimulator fallback) —
        // otherwise they'd corrupt the word buffer or re-trigger correction.
        guard event.getIntegerValueField(.eventSourceUserData) != KeystrokeSimulator.eventMarker else { return false }
        keyDownCount += 1
        _ = doubleShift.feed(.otherKey, at: Self.seconds(event))
        if keyFlow?.keyDownSeen == false, let first = keyFlow?.recordKeyDown(at: Date()) {
            logKeyFlow(first)
        }
        let flags = event.flags
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        // Skip modifier keys themselves — checked first so a bare Cmd tap
        // (whose own keyDown carries .maskCommand) doesn't fall into the
        // shortcut branch below and needlessly break a valid chain.
        if modifierKeyCodes.contains(keyCode) { return false }
        // Skip shortcuts (Cmd/Ctrl held).
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            // Unlike currentWord, the chain describes text *behind* the
            // current word — exactly what Ctrl+U, Ctrl+W, Cmd+Z, Cmd+X and
            // Cmd+V rewrite. In a terminal there is no anchor to catch a
            // stale chain, so the keystroke fallback would delete the
            // chain's length blind.
            if !carry.isEmpty { Log.debug("carry reset: shortcut (carry \(carry.count))") }
            breakChain()
            return false
        }

        // Backspace (kVK_Delete = 51): shrink the word buffer.
        if keyCode == 51 {
            if currentWord.isEmpty {
                // Deleting past the start of the word eats the separator or
                // the carried word itself, so the chain no longer describes
                // the text in front of the cursor.
                if !carry.isEmpty { Log.debug("carry reset: backspace past word start (carry \(carry.count))") }
                breakChain()
            } else {
                currentWord.removeLast()
            }
            return false
        }

        guard let char = layoutManager.character(forKeyCode: keyCode, flags: flags) else {
            if !currentWord.isEmpty || !carry.isEmpty {
                Log.debug("buffer reset: no character for keyCode \(keyCode) (word \(Sensitive(currentWord)), carry \(carry.count))")
            }
            currentWord = ""
            // An arrow key moves the cursor away from the chain; anything
            // else here is just as opaque. Either way the chain can no
            // longer be assumed to sit right before the cursor, and the
            // buffer's relationship to on-screen text is now lost.
            currentWordIsFragment = false
            breakChain()
            return false
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
            let wrong = !currentWord.isEmpty && (LanguageDetector.isWrongLayout(
                word: currentWord, currentLayoutIsRussian: currentLayoutIsRussian,
                exceptions: exceptionStore.words, variant: currentRussianVariant
            ) || isTerminalCommand())
            if !currentWord.isEmpty {
                Log.debug(boundaryDescription(char, wrong: wrong))
            }
            if currentWord.isEmpty {
                // A boundary with nothing buffered is a second separator
                // (double space, ", "). A chain is only ever carried across
                // exactly one space, so this one is spent.
                if !carry.isEmpty { Log.debug("carry reset: second separator (carry \(carry.count))") }
                breakChain()
                scheduleLeadingCharCheck(char)
            } else if wrong, terminalAwaitsPassword() {
                // Most likely a password, not a word: leave it as typed and
                // drop the chain too — nothing typed here is ours to retype.
                Log.info("correction skipped: a terminal awaits a password")
                breakChain()
            } else if wrong {
                let carried = carry.carried(layoutIsRussian: currentLayoutIsRussian, variant: currentRussianVariant)
                // Only a word typed in the same layout and variant can be
                // the one LatCyr missed right before this correction.
                // A chain dropped for another layout/variant is still on screen
                // between previousWord and this word: no longer adjacent.
                let chainDropped = !carry.isEmpty && carried.isEmpty
                let before = chainDropped ? nil : previousWord.flatMap {
                    $0.layoutIsRussian == currentLayoutIsRussian && $0.variant == currentRussianVariant ? $0 : nil
                }
                breakChain()
                if char.isNewline || char == "\t" {
                    let word = currentWord
                    currentWord = ""
                    // A genuine boundary character was processed; the early
                    // return here is only about correcting synchronously, not
                    // about skipping the boundary bookkeeping.
                    currentWordIsFragment = false
                    return applyCorrectionNow(
                        word: word, carried: carried, wasRussian: currentLayoutIsRussian,
                        variant: currentRussianVariant, keyCode: keyCode, previous: before
                    )
                }
                scheduleRetroactiveCheck(word: currentWord, carried: carried, wasRussian: currentLayoutIsRussian, variant: currentRussianVariant, boundary: char, previous: before)
            } else if char == " ", !currentWordIsFragment, LanguageDetector.isCarriableFunctionWord(
                word: currentWord, currentLayoutIsRussian: currentLayoutIsRussian,
                exceptions: exceptionStore.words, variant: currentRussianVariant
            ) {
                // Not correctable on its own — too short for the heuristic to
                // judge — but a known function word, so the next word gets a
                // chance to take it along. Gated on !currentWordIsFragment:
                // a buffer that is only the tail of an already-displayed
                // token (see the property's doc comment) must never look
                // like a standalone function word, however it happens to
                // convert.
                let linksBefore = carry.count
                carry.append(currentWord, layoutIsRussian: currentLayoutIsRussian, variant: currentRussianVariant)
                // A link evicted at maxWords, or a chain restarted for another
                // layout/variant, is still on screen between previousWord and
                // the span: previousWord is no longer adjacent to it.
                if carry.count != linksBefore + 1 { previousWord = nil }
            } else {
                carry.reset()
                // A word LatCyr left alone, ended by a single space: the
                // candidate for fix-and-remember if the next word gets
                // corrected. A fragment is the tail of an on-screen token,
                // not a word of its own.
                previousWord = (char == " " && !currentWord.isEmpty && !currentWordIsFragment)
                    ? PreviousWord(text: currentWord, layoutIsRussian: currentLayoutIsRussian, variant: currentRussianVariant)
                    : nil
            }
            currentWord = ""
            // A genuine boundary character has now landed on screen, so
            // whatever comes next starts a fresh token — the fragment/whole
            // distinction no longer applies to it, regardless of which
            // branch above ran.
            currentWordIsFragment = false
        } else {
            if !currentWord.isEmpty || !carry.isEmpty {
                Log.debug("buffer reset: non-letter \(char.debugDescription) (word \(Sensitive(currentWord)), carry \(carry.count))")
            }
            currentWord = ""
            currentWordIsFragment = false
            breakChain()
        }
        return false
    }

    /// A short shell command ("св" for "cd") typed in a terminal — too short
    /// for isWrongLayout, see LanguageDetector.terminalCommands. Not for a
    /// fragment: the tail of a token already on screen (after "/" or a
    /// proactive fix) is not a command of its own.
    private func isTerminalCommand() -> Bool {
        // Pure check first: isTerminalFocused may cost an AX read, and this
        // runs inside the event tap callback.
        !currentWordIsFragment
            && LanguageDetector.isTerminalCommand(
                word: currentWord, currentLayoutIsRussian: currentLayoutIsRussian,
                exceptions: exceptionStore.words, variant: currentRussianVariant
            )
            && isTerminalFocused
    }

    /// A terminal is focused and some terminal is waiting for a password —
    /// see PasswordPrompt for why the tty mode, and why all ttys. Checked
    /// only once a correction or a layout switch is about to happen: the tty
    /// scan costs ~1 ms, too much for every keystroke inside the tap.
    private func terminalAwaitsPassword() -> Bool {
        isTerminalFocused && PasswordPrompt.anyTerminalAwaitingPassword()
    }

    /// Debug line for a word boundary. Only ever built inside Log.debug's
    /// autoclosure, so the score computations cost nothing unless debug
    /// logging is on. Scores are the raw per-string bigram model scores
    /// (russianScore/englishScore), not the LLR that isWrongLayout decides on —
    /// close enough to diagnose.
    private func boundaryDescription(_ char: Character, wrong: Bool) -> LogMessage {
        let word = currentWord.lowercased()
        let converted = currentLayoutIsRussian
            ? TextConverter.toLatin(word, variant: currentRussianVariant)
            : TextConverter.toCyrillic(word, variant: currentRussianVariant)
        func score(_ value: Double) -> String { String(format: "%.3f", value) }
        return "boundary \(char.debugDescription) word=\(Sensitive(currentWord)) conv=\(Sensitive(converted)) ru=\(currentLayoutIsRussian) variant=\(currentRussianVariant) wrong=\(wrong) ruScore=\(score(LanguageDetector.russianScore(word))) enScore=\(score(LanguageDetector.englishScore(word))) convRuScore=\(score(LanguageDetector.russianScore(converted))) convEnScore=\(score(LanguageDetector.englishScore(converted))) carry=\(carry.count) fragment=\(currentWordIsFragment)"
    }

    // MARK: - Correction

    /// Fix-and-remember, from double Shift or the menu. Main queue only.
    func fixAndRemember(completion: @escaping (ManualFixer.Outcome) -> Void) {
        // A terminal waiting for a password: whatever we'd retype could be it.
        guard !terminalAwaitsPassword() else {
            Log.info("fix-and-remember skipped: a terminal awaits a password")
            return completion(.refused("password prompt"))
        }
        let requestKeyDowns = keyDownCount
        manualFixer.run(
            pending: pendingFix, keyDownCount: requestKeyDowns,
            currentKeyDownCount: { [weak self] in self?.keyDownCount ?? requestKeyDowns + 1 }
        ) { [weak self] outcome in
            switch outcome {
            case .fixed:
                // Only the candidate this request saw: a newer correction
                // can only have been recorded after a keyDown.
                if self?.keyDownCount == requestKeyDowns { self?.pendingFix = nil }
            case .nothingToFix:
                Log.info("fix-and-remember: nothing selected and no candidate")
            case .invalidWord:
                Log.info("fix-and-remember: not one word in one alphabet")
            case .refused(let reason), .failed(let reason):
                Log.info("fix-and-remember not applied: \(reason)")
            }
            completion(outcome)
        }
    }

    private func scheduleProactiveCheck() {
        let word = currentWord
        let wasRussian = currentLayoutIsRussian
        let variant = currentRussianVariant
        // A dropped (other layout/variant) chain is still on screen, so
        // previousWord is no longer adjacent.
        let chainDropped = !carry.isEmpty
            && carry.carried(layoutIsRussian: currentLayoutIsRussian, variant: currentRussianVariant).isEmpty
        let previous = chainDropped ? nil : previousWord.flatMap {
            $0.layoutIsRussian == currentLayoutIsRussian && $0.variant == currentRussianVariant ? $0 : nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + correctionDelay) { [weak self] in
            self?.performProactiveFix(word: word, wasRussian: wasRussian, variant: variant, previous: previous)
        }
    }

    private func scheduleLeadingCharCheck(_ char: Character) {
        let wasRussian = layoutManager.isRussian
        DispatchQueue.main.asyncAfter(deadline: .now() + correctionDelay) { [weak self] in
            self?.performLeadingCharCheck(char: char, wasRussian: wasRussian)
        }
    }

    private func scheduleRetroactiveCheck(word: String, carried: [String], wasRussian: Bool, variant: TextConverter.RussianKeyboardVariant, boundary: Character, previous: PreviousWord?) {
        // Capture the word's position now, synchronously — not 50ms from
        // now, when applyCorrection actually runs. If the user starts the
        // next word without pausing, a cursor-relative lookup done later
        // would find that new word instead of this one and silently fail
        // to correct it (see WordAnchor's doc comment). nil is fine here:
        // it means no AX-correctable target (e.g. a terminal), and the
        // delayed call still runs so the keystroke fallback gets a chance.
        let (captured, anchorFailure) = captureAnchor(matching: word, variant: variant)
        let resolved = resolveCarry(carried, anchor: captured, variant: variant)
        let keyDownsAtBoundary = keyDownCount
        // Secure Event Input held by another app hides keystrokes from the
        // tap entirely; logging it here lets support spot it next to a miss.
        Log.debug("retroactive scheduled: anchor=\(captured != nil) carried=\(carried.count) keptCarried=\(resolved.carried.count) secureInput=\(IsSecureEventInputEnabled())")
        DispatchQueue.main.asyncAfter(deadline: .now() + correctionDelay) { [weak self] in
            self?.applyCorrection(
                word: word, carried: resolved.carried, wasRussian: wasRussian, variant: variant,
                replacePrefix: false, boundary: boundary, anchor: resolved.anchor, wordAnchor: resolved.wordAnchor,
                anchorFailure: anchorFailure,
                previous: previous, keyDownsAtBoundary: keyDownsAtBoundary
            )
        }
    }

    /// captureWordAnchor, except in hybrid apps, which never get an AX
    /// attempt: AXManualAccessibility (enabled there for terminal-pane
    /// detection) makes their fields look AX-editable, but writes to them
    /// report success without applying — registering the app as hybrid is
    /// the user saying so. They go straight to the keystroke fallback,
    /// exactly as before the tree was enabled.
    private func captureAnchor(
        matching word: String, variant: TextConverter.RussianKeyboardVariant
    ) -> (anchor: TextFieldController.WordAnchor?, failure: TextFieldController.AnchorFailure?) {
        if keystrokeSimulator.isHybridFrontmost { return (nil, .hybridApp) }
        let anchor = textFieldController.captureWordAnchor(matching: word, variant: variant)
        // Read right away: the next captureWordAnchor call overwrites it.
        return (anchor, textFieldController.lastAnchorFailure)
    }

    /// Terminal-only behaviour (leading "/", short commands) applies here:
    /// a known terminal, or the xterm.js pane of a hybrid app (Claude's
    /// terminal, VS Code's). The AX read only happens for hybrid apps, and
    /// callers ask only after a cheap text check already matched.
    private var isTerminalFocused: Bool {
        keystrokeSimulator.isTerminalFrontmost
            || (keystrokeSimulator.isHybridFrontmost && textFieldController.isFocusedTerminalEmulator())
    }

    /// Hybrid apps get AXManualAccessibility on activation, so the terminal
    /// pane check works from the first keystroke — Electron builds the tree
    /// asynchronously, and enabling it lazily would miss the first command
    /// after every app launch. Only hybrid apps: the tree costs the app
    /// memory and CPU, and the user registered these.
    private func enableAccessibilityIfHybrid(_ app: NSRunningApplication?) {
        guard let app, let id = app.bundleIdentifier, hybridAppStore.contains(id),
              !KeystrokeSimulator.terminalBundleIDs.contains(id) else { return }
        // Electron keeps the web app in Contents/Resources/app.asar.
        let isElectron = app.bundleURL.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Resources/app.asar").path)
        } ?? false
        let result = textFieldController.enableManualAccessibility(pid: app.processIdentifier, isElectron: isElectron)
        Log.debug("accessibility tree for \(id): \(result)")
    }

    /// Check the carried chain against the live text and either widen the
    /// anchor to cover it or drop it — synchronously, at the boundary, for
    /// the same reason the anchor itself is captured there: 50ms later the
    /// question would be asked about text the user has since typed.
    ///
    /// A nil anchor is not a rejection. It means there is no AX target at
    /// all (a terminal), so there is nothing to widen and nothing to verify
    /// against — the chain is handed to the keystroke fallback on exactly
    /// the same trust as the word itself already is.
    ///
    /// Returns the original (un-widened) anchor alongside the widened one —
    /// `applyCorrection` retries with it, word alone, if the delayed
    /// re-verification of the widened span fails (see its `wordAnchor` doc).
    private func resolveCarry(
        _ carried: [String], anchor: TextFieldController.WordAnchor?, variant: TextConverter.RussianKeyboardVariant
    ) -> (anchor: TextFieldController.WordAnchor?, carried: [String], wordAnchor: TextFieldController.WordAnchor?) {
        guard let anchor, !carried.isEmpty else { return (anchor, carried, anchor) }
        guard let widened = textFieldController.extendAnchor(anchor, backwardOver: carried, variant: variant) else {
            return (anchor, [], anchor)
        }
        return (widened, carried, anchor)
    }

    /// Correct right now, inside the event callback, and report whether the
    /// key that triggered it should be swallowed.
    ///
    /// Enter and Tab can't use `correctionDelay`: they print nothing to wait
    /// for, and they make the app act immediately (navigate, submit, move
    /// focus). Correcting afterwards is too late — the browser has already
    /// sent the request. Correcting synchronously isn't enough either, since
    /// the key is delivered independently of this callback. So the key is
    /// swallowed (`true` here makes the tap return nil), the word is fixed,
    /// and the key is then re-posted by KeystrokeSimulator, arriving at the
    /// app after the corrected text.
    ///
    /// `boundary: nil` is deliberate: the swallowed key never reaches the
    /// screen, so the keystroke fallback must delete the word alone and retype
    /// the correction alone — the `word.count + 1` arithmetic used for visible
    /// separators would eat one character too many here. That is also what
    /// makes the fallback usable for Enter at all, terminals included.
    ///
    /// If the key can't be re-posted, the correction is reported as failed:
    /// swallowing a key we cannot give back would silently lose the user's
    /// Enter, which is worse than leaving the word uncorrected.
    private func applyCorrectionNow(
        word: String, carried: [String], wasRussian: Bool,
        variant: TextConverter.RussianKeyboardVariant, keyCode: CGKeyCode, previous: PreviousWord?
    ) -> Bool {
        let (captured, anchorFailure) = captureAnchor(matching: word, variant: variant)
        let resolved = resolveCarry(carried, anchor: captured, variant: variant)
        guard applyCorrection(
            word: word, carried: resolved.carried, wasRussian: wasRussian, variant: variant,
            replacePrefix: false, boundary: nil, anchor: resolved.anchor, wordAnchor: resolved.wordAnchor,
            anchorFailure: anchorFailure,
            previous: previous, keyDownsAtBoundary: keyDownCount
        ) else { return false }
        // Hybrid apps are corrected by keystrokes, and Electron terminals
        // take the retyped word in asynchronously — see replay's doc. Native
        // terminals and the AX path were verified with an immediate replay.
        let replayDelay = keystrokeSimulator.isHybridFrontmost ? correctionDelay : 0
        guard keystrokeSimulator.replay(keyCode: keyCode, after: replayDelay) else {
            Log.error("could not re-post swallowed key \(keyCode); key delivered unswallowed")
            return false
        }
        return true
    }

    private func performProactiveFix(word: String, wasRussian: Bool, variant: TextConverter.RussianKeyboardVariant, previous: PreviousWord?) {
        guard word.count == 2 else { return }
        let chars = Array(word)
        guard LanguageDetector.proactiveSwitchSignal(
            first: chars[0], second: chars[1], currentLayoutIsRussian: wasRussian
        ) else { return }
        // Fast-typing guard: if the buffer has grown past the captured word,
        // bail and let the retroactive path handle the full word.
        guard currentWord == word else {
            Log.debug("proactive: signal for \(Sensitive(word)) dropped, buffer moved on")
            return
        }
        guard !terminalAwaitsPassword() else {
            Log.debug("proactive: skipped, a terminal awaits a password")
            return
        }
        // Verify the chain before editing rather than retrying afterwards: a
        // failed edit may already have injected keystrokes in a terminal, and
        // a second attempt would inject them twice. captureWordAnchor works
        // here even mid-word — the cursor sits right after the two typed
        // characters, so it finds exactly this word.
        let pending = carry.carried(layoutIsRussian: wasRussian, variant: variant)
        // The anchor serves two checks: the carried chain, and the word
        // right before the span for fix-and-remember.
        let prefixAnchor = (pending.isEmpty && previous == nil) ? nil : captureAnchor(matching: word, variant: variant).anchor
        let resolved = resolveCarry(pending, anchor: prefixAnchor, variant: variant)
        let carried = pending.isEmpty ? [] : resolved.carried
        // replacePrefix re-derives its position from the live cursor; the
        // anchor goes along only to locate the previous word after success.
        if applyCorrection(word: word, carried: carried, wasRussian: wasRussian, variant: variant, replacePrefix: true,
                           anchor: resolved.anchor, previous: previous, keyDownsAtBoundary: keyDownCount) {
            currentWord = ""
            // Whatever gets typed next is not a fresh token: the word on
            // screen already has its first two characters (now corrected),
            // and any further letters the user types are appended to that
            // same on-screen word, not to a new one. See the property's doc
            // comment — this is the case it exists for.
            currentWordIsFragment = true
            breakChain()
        }
    }

    private func performLeadingCharCheck(char: Character, wasRussian: Bool) {
        // Scope: terminal-only (isTerminalFocused — a known terminal or a
        // hybrid app's xterm.js pane). Outside a terminal there's no strong
        // reason to treat a bare "/" as "the user is about to type a path".
        // The text check goes first: isTerminalFocused may cost an AX read.
        guard LanguageDetector.proactiveSingleCharSwitchSignal(
            first: char, currentLayoutIsRussian: wasRussian
        ) else { return }
        guard isTerminalFocused else { return }
        // A "/" in a password must not switch the layout under the rest of it.
        guard !PasswordPrompt.anyTerminalAwaitingPassword() else {
            Log.info("leading-char switch skipped: a terminal awaits a password")
            return
        }
        // The character itself is already correct on screen (this isn't an
        // ambiguous key — see CLAUDE.md) — only the layout needs fixing, so
        // there's no text to replace and no AX/KeystrokeSimulator involved.
        switchLayout(wasRussian: wasRussian)
        Log.info("leading \(char.debugDescription) in terminal: layout switched")
        // Drop whatever's accumulated since — it started under the layout
        // we just left, and letting it mix with post-switch typing would
        // feed a stale currentLayoutIsRussian into a later correction.
        currentWord = ""
        // The "/" itself is already on screen and correct (see the design
        // note above) — whatever the user types next continues right after
        // it, so the next buffer is again a suffix of an on-screen token,
        // not a fresh one. See currentWordIsFragment's doc comment.
        currentWordIsFragment = true
        breakChain()
    }

    @discardableResult
    private func applyCorrection(
        word: String, carried: [String] = [], wasRussian: Bool, variant: TextConverter.RussianKeyboardVariant, replacePrefix: Bool,
        boundary: Character? = nil, anchor: TextFieldController.WordAnchor? = nil,
        wordAnchor: TextFieldController.WordAnchor? = nil,
        anchorFailure: TextFieldController.AnchorFailure? = nil,
        previous: PreviousWord? = nil,
        keyDownsAtBoundary: Int = 0
    ) -> Bool {
        // One span, one conversion: TextConverter leaves unmapped characters
        // alone and the space key is in neither table, so joining the chain
        // and converting the result handles the separators for free.
        let span = (carried + [word]).joined(separator: " ")
        let converted = wasRussian ? TextConverter.toLatin(span, variant: variant) : TextConverter.toCyrillic(span, variant: variant)

        var axReplaced: Bool
        // Why axReplaced is false, for the not-applied line: "AX failed"
        // alone can't tell a missing target from a rejected write. A closure
        // so nothing is formatted unless that line is actually logged.
        var axFailure: () -> String = { "AX replace rejected or not applied" }
        if replacePrefix {
            // Proactive path: replacePrefix operates on the word still
            // being typed (no boundary yet). It's re-derived from the live
            // cursor at fire time, same as always — the caller already
            // guards `currentWord == word` before scheduling this, so a
            // fast-typing mismatch bails before we get here.
            if keystrokeSimulator.isHybridFrontmost {
                axReplaced = false
                axFailure = { "hybrid app, AX skipped" }
            } else if let element = textFieldController.focusedTextElement(),
               !textFieldController.isOwnApp(element),
               !textFieldController.isSecure(element),
               textFieldController.isEditableText(element) {
                axReplaced = textFieldController.replacePrefix(word, carrying: carried, with: converted, in: element, variant: variant)
            } else {
                axReplaced = false
                axFailure = { "no focused editable element" }
            }
        } else if let anchor {
            // Retroactive path: anchor was captured synchronously when the
            // boundary key landed, so it targets the right word even if the
            // user has since started typing the next one.
            axReplaced = textFieldController.replaceAnchoredWord(anchor, word: span, with: converted)
        } else {
            axReplaced = false
            axFailure = { "no anchor captured (\(anchorFailure.map { "\($0)" } ?? "unknown"))" }
        }

        // The widened-span replacement can fail for a reason that has
        // nothing to do with the word itself — something touched the carried
        // region in the correctionDelay window (app-side autocomplete, an
        // inline suggestion). Before this feature, only the word's own
        // region had to survive that window; retry once against the
        // anchored word alone so carrying can't make a correction that would
        // have succeeded on its own fail outright. Safe to retry:
        // replaceAnchoredWord's mismatch guard runs before any AX write, so
        // the first attempt cannot have partially applied. Scoped to
        // !replacePrefix so it's only ever reached from the anchored
        // (retroactive) branch above — replacePrefix doesn't pass a
        // wordAnchor today, but that invariant lives two functions away
        // (performProactiveFix), not here, so it's enforced locally too.
        if !replacePrefix, !axReplaced, !carried.isEmpty, let wordAnchor {
            let convertedWord = wasRussian ? TextConverter.toLatin(word, variant: variant) : TextConverter.toCyrillic(word, variant: variant)
            axReplaced = textFieldController.replaceAnchoredWord(wordAnchor, word: word, with: convertedWord)
            if axReplaced {
                // Only the word was replaced; the chain stays as typed.
                Log.info("corrected via ax (retroactive, retry, chain dropped): \(Sensitive(word)) -> \(Sensitive(convertedWord)) carried=0")
                // The uncorrected chain stays on screen between the remembered
                // word and the correction, so no word is adjacent to it.
                recordPendingFix(previous: nil, anchor: nil)
                switchLayout(wasRussian: wasRussian)
                return true
            }
            axFailure = { "AX replace rejected or not applied (widened span and word-only retry)" }
        }

        let path = replacePrefix ? "proactive" : "retroactive"
        if axReplaced {
            Log.info("corrected via ax (\(path)): \(Sensitive(span)) -> \(Sensitive(converted)) carried=\(carried.count)")
            // Located now, after the edit and outside the tap callback for
            // the delayed paths: the text before the span is untouched by
            // the replacement, so the span's start still marks it.
            let previousAnchor = previous.flatMap { prev in
                anchor.flatMap { span in
                    textFieldController.previousWordAnchor(
                        before: TextFieldController.WordAnchor(element: span.element, range: span.range.lowerBound..<span.range.lowerBound),
                        word: prev.text, variant: variant)
                }
            }
            recordPendingFix(previous: previous, anchor: previousAnchor)
            switchLayout(wasRussian: wasRussian)
            return true
        }

        // AX replacement didn't take (no element, or the app reported
        // success without applying it — e.g. a terminal's PTY-rendered
        // view). Fall back to simulated keystrokes, restricted to known
        // terminals: without an AX element we can't check isSecure/isOwnApp,
        // so blindly injecting into arbitrary apps would be unsafe.
        guard keystrokeSimulator.usesKeystrokeFallback else {
            logNotApplied("\(axFailure()); this app has no keystroke fallback", proactive: replacePrefix, span: span)
            return false
        }

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
                logNotApplied("keystroke fallback skipped: boundary is Enter/Tab", proactive: replacePrefix, span: span)
                return false
            }
            deleteCount = span.count + 1
            typed = converted + String(boundary)
        } else {
            deleteCount = span.count
            typed = converted
        }
        guard keystrokeSimulator.correct(deleting: deleteCount, typing: typed) else {
            logNotApplied("keystroke fallback failed", proactive: replacePrefix, span: span)
            return false
        }
        // Screen after the previous word is now exactly: space, the corrected
        // span, the boundary — but only if no key landed since the boundary
        // (correctionDelay is 50 ms of the user still typing). Enter/Tab and
        // the proactive path have no visible boundary: no candidate.
        if let previous, let boundary, keyDownCount == keyDownsAtBoundary {
            pendingFix = .keystroke(
                word: previous.text, tail: " " + converted + String(boundary),
                keyDownCount: keyDownCount, variant: previous.variant
            )
            Log.debug("pending fix recorded (keystroke): \(Sensitive(previous.text))")
        } else {
            pendingFix = nil
        }
        Log.info("corrected via keystroke (\(path)): \(Sensitive(span)) -> \(Sensitive(converted)) carried=\(carried.count) deleted=\(deleteCount)")
        switchLayout(wasRussian: wasRussian)
        return true
    }

    /// After an AX correction: the word before it becomes the candidate, or
    /// the old candidate is dropped — a newer correction supersedes it.
    private func recordPendingFix(previous: PreviousWord?, anchor: TextFieldController.WordAnchor?) {
        if let previous, let anchor {
            pendingFix = .anchored(anchor: anchor, word: previous.text, variant: previous.variant)
            Log.debug("pending fix recorded (ax): \(Sensitive(previous.text))")
        } else {
            pendingFix = nil
        }
    }

    /// A retroactive miss is a lost correction (error); a proactive miss
    /// still has the retroactive check at the word boundary behind it (debug).
    private func logNotApplied(_ reason: @autoclosure () -> String, proactive: Bool, span: String) {
        if proactive {
            Log.debug("proactive correction not applied: \(reason()) (span \(Sensitive(span)))")
        } else {
            Log.error("correction not applied: \(reason()) (span \(Sensitive(span)))")
        }
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
