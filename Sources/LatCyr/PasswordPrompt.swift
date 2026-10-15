import Darwin

/// Whether a terminal is waiting for a password. A PTY's text has no
/// AXSecureTextField role and a shell never takes Secure Event Input, so
/// the event tap sees a `sudo`/`ssh` password like any other typing — and a
/// password that happens to look like a wrong-layout word would be retyped
/// converted. The tty's own mode tells: everything that reads a password
/// (readpassphrase behind sudo and ssh, `read -s`, Python's getpass) turns
/// echo off and keeps line editing on. Measured live: an idle zsh, vim and
/// less run with both off, `cat` and a running command with both on.
///
/// Terminal.app takes Secure Event Input at a password prompt on its own
/// (verified with sudo), so no keys reach the tap there at all; this is
/// for the terminals that don't — the xterm.js panes of hybrid apps.
///
/// Not covered: a password asked for on the far side of ssh (or docker
/// exec, mosh) — the local tty is then in the remote session's raw mode.
enum PasswordPrompt {
    /// Pure: whether a tty's local mode flags are a password prompt's.
    static func isAwaitingPassword(localFlags: tcflag_t) -> Bool {
        localFlags & tcflag_t(ECHO) == 0 && localFlags & tcflag_t(ICANON) != 0
    }

    /// Whether this tty is waiting for a password. False if it can't be
    /// read. O_NONBLOCK so a pty whose master is gone can't hang the
    /// caller; O_NOCTTY so opening it never makes it ours.
    static func isAwaitingPassword(ttyPath: String) -> Bool {
        let fd = open(ttyPath, O_RDONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var mode = termios()
        guard tcgetattr(fd, &mode) == 0 else { return false }
        return isAwaitingPassword(localFlags: mode.c_lflag)
    }

    /// Whether any of the user's terminals is waiting for a password. All
    /// of them, not the focused one: which tty is behind the focused tab
    /// isn't knowable for every terminal, and tmux panes belong to the tmux
    /// server, not to the terminal app. A prompt pending in another window
    /// therefore pauses corrections in this one too — the safe direction.
    /// ~0.1 ms per tty (measured), so it's only called once a correction is
    /// about to happen, never per keystroke.
    static func anyTerminalAwaitingPassword() -> Bool {
        guard let dir = opendir("/dev") else { return false }
        defer { closedir(dir) }
        let uid = getuid()
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            guard name.hasPrefix("ttys") else { continue }
            let path = "/dev/" + name
            var info = stat()
            guard stat(path, &info) == 0, info.st_uid == uid else { continue }
            if isAwaitingPassword(ttyPath: path) { return true }
        }
        return false
    }
}
