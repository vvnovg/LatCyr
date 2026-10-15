import XCTest
import Darwin
@testable import LatCyr

// Flag combinations as measured live on real ttys (see PasswordPrompt).
final class PasswordPromptTests: XCTestCase {
    private let echo = tcflag_t(ECHO)
    private let icanon = tcflag_t(ICANON)

    func testPasswordPromptMode() {
        // sudo, read -s, getpass: echo off, line editing on.
        XCTAssertTrue(PasswordPrompt.isAwaitingPassword(localFlags: icanon))
    }

    func testIdleShellAndTUIAreNotPasswordPrompts() {
        // zsh line editor, vim, less: both off.
        XCTAssertFalse(PasswordPrompt.isAwaitingPassword(localFlags: 0))
    }

    func testCookedModeIsNotPasswordPrompt() {
        // cat, a running command: both on.
        XCTAssertFalse(PasswordPrompt.isAwaitingPassword(localFlags: echo | icanon))
        XCTAssertFalse(PasswordPrompt.isAwaitingPassword(localFlags: echo))
    }

    /// The tty read itself, on a pty this test owns.
    func testReadsModeOfARealTTY() throws {
        var master: Int32 = 0, slave: Int32 = 0
        var name = [CChar](repeating: 0, count: 128)
        guard openpty(&master, &slave, &name, nil, nil) == 0 else { throw XCTSkip("openpty failed") }
        defer { close(master); close(slave) }
        let path = String(cString: name)

        var mode = termios()
        tcgetattr(slave, &mode)
        mode.c_lflag = (mode.c_lflag | icanon) & ~echo
        tcsetattr(slave, TCSANOW, &mode)
        XCTAssertTrue(PasswordPrompt.isAwaitingPassword(ttyPath: path))

        mode.c_lflag |= echo
        tcsetattr(slave, TCSANOW, &mode)
        XCTAssertFalse(PasswordPrompt.isAwaitingPassword(ttyPath: path))
    }

    func testUnreadableTTYIsNotPasswordPrompt() {
        XCTAssertFalse(PasswordPrompt.isAwaitingPassword(ttyPath: "/dev/ttys-does-not-exist"))
    }
}
