import XCTest
@testable import LatCyr

// The DOM classes below are what the Claude desktop app exposed through AX
// (probed live): its terminal pane's xterm.js input, and its chat box.
final class TerminalEmulatorInputTests: XCTestCase {
    func testXtermInputIsTerminal() {
        XCTAssertTrue(TextFieldController.isTerminalEmulatorInput(domClasses: ["xterm-helper-textarea"]))
    }

    func testChatBoxIsNotTerminal() {
        XCTAssertFalse(TextFieldController.isTerminalEmulatorInput(domClasses: ["tiptap", "ProseMirror", "ProseMirror-focused"]))
    }

    // The xterm *container* classes sit on ancestors, not on the focused
    // input; only the input's own class counts.
    func testContainerClassesAreNotTheInput() {
        XCTAssertFalse(TextFieldController.isTerminalEmulatorInput(domClasses: ["terminal", "xterm", "focus"]))
        XCTAssertFalse(TextFieldController.isTerminalEmulatorInput(domClasses: []))
    }
}
