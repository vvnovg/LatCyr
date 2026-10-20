import AppKit

/// Performs fix-and-remember: converts the selected word, or the word right
/// before the latest automatic correction, and adds the corrected form to
/// the exceptions. A thin wrapper over AX, keystrokes and the clipboard —
/// the decisions are ManualFix.plan's and PendingFix's; verified by hand.
final class ManualFixer {
    enum Outcome {
        case fixed(exception: String)
        case nothingToFix
        case invalidWord
        case refused(String)
        case failed(String)
    }

    private let textFieldController: TextFieldController
    private let keystrokeSimulator: KeystrokeSimulator
    private let clipboardReader: ClipboardReader
    private let exceptionStore: ExceptionStore
    private let layoutManager: LayoutManager

    init(
        textFieldController: TextFieldController, keystrokeSimulator: KeystrokeSimulator,
        clipboardReader: ClipboardReader, exceptionStore: ExceptionStore, layoutManager: LayoutManager
    ) {
        self.textFieldController = textFieldController
        self.keystrokeSimulator = keystrokeSimulator
        self.clipboardReader = clipboardReader
        self.exceptionStore = exceptionStore
        self.layoutManager = layoutManager
    }

    /// Main queue only. `pending` and `keyDownCount` are InputMonitor's at
    /// the moment of the request. The password check is the caller's.
    func run(pending: PendingFix?, keyDownCount: Int, completion: @escaping (Outcome) -> Void) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            return completion(.refused("own app"))
        }
        if textFieldController.isFocusedElementSecure() {
            return completion(.refused("secure field"))
        }
        let isTerminal = keystrokeSimulator.isTerminalFrontmost
        let isHybrid = keystrokeSimulator.isHybridFrontmost
        guard isTerminal || isHybrid else {
            return completion(runAX(pending: pending))
        }
        // Keystroke apps: the candidate first — see the plan's note on Cmd+C
        // copying a whole line when nothing is selected.
        if case let .keystroke(word, tail, count, variant) = pending, count == keyDownCount {
            return completion(retype(word: word, tail: tail, variant: variant))
        }
        guard isHybrid else { return completion(.nothingToFix) }
        clipboardReader.copySelection { [weak self] copied in
            guard let self else { return }
            guard let copied, !copied.contains(where: \.isNewline) else { return completion(.nothingToFix) }
            guard let plan = ManualFix.plan(for: copied, variant: self.layoutManager.currentRussianVariant) else {
                return completion(.invalidWord)
            }
            // Typing over a selection replaces it — nothing to delete.
            guard self.keystrokeSimulator.correct(deleting: 0, typing: plan.replacement) else {
                return completion(.failed("keystrokes could not be posted"))
            }
            completion(self.remember(plan, path: "selection-hybrid"))
        }
    }

    // MARK: - Private

    private func runAX(pending: PendingFix?) -> Outcome {
        if let selection = textFieldController.selectionAnchor() {
            guard let plan = ManualFix.plan(for: selection.text, variant: layoutManager.currentRussianVariant) else {
                return .invalidWord
            }
            guard textFieldController.replaceAnchoredWord(selection.anchor, word: selection.text, with: plan.replacement) else {
                return .failed("AX replace rejected or not applied")
            }
            return remember(plan, path: "selection-ax")
        }
        guard case let .anchored(anchor, word, variant) = pending else { return .nothingToFix }
        guard let plan = ManualFix.plan(for: word, variant: variant) else { return .invalidWord }
        // replaceAnchoredWord re-reads the text at the anchor and refuses if
        // it no longer holds `word` — before any write.
        guard textFieldController.replaceAnchoredWord(anchor, word: word, with: plan.replacement) else {
            return .failed("text at the remembered position changed")
        }
        return remember(plan, path: "pending-ax")
    }

    private func retype(word: String, tail: String, variant: TextConverter.RussianKeyboardVariant) -> Outcome {
        guard let plan = ManualFix.plan(for: word, variant: variant) else { return .invalidWord }
        guard keystrokeSimulator.correct(deleting: word.count + tail.count, typing: plan.replacement + tail) else {
            return .failed("keystroke fallback refused or failed")
        }
        return remember(plan, path: "pending-keystroke")
    }

    private func remember(_ plan: ManualFix.Plan, path: String) -> Outcome {
        exceptionStore.add(plan.exception)
        Log.info("fix-and-remember (\(path)): -> \(Sensitive(plan.replacement)), exception added")
        return .fixed(exception: plan.exception)
    }
}
