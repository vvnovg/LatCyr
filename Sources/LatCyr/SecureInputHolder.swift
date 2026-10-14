import AppKit
import IOKit

/// Who holds Secure Event Input. While any process holds it, macOS delivers
/// no keys to event taps — LatCyr looks enabled but sees nothing. The holder
/// is the process to name to the user: a password manager, a terminal with
/// "Secure Keyboard Entry", or a loginwindow that never released it.
enum SecureInputHolder {
    static let pidKey = "kCGSSessionSecureInputPID"
    static let onConsoleKey = "kCGSSessionOnConsoleKey"

    /// Pure: picks the holder's PID out of the IORegistry root's
    /// `IOConsoleUsers` array. With fast user switching there is one entry
    /// per session; the one on console is ours, others are a fallback.
    static func pid(fromConsoleUsers users: [[String: Any]]) -> Int32? {
        func pid(_ user: [String: Any]) -> Int32? {
            (user[pidKey] as? NSNumber).map { $0.int32Value }
        }
        let onConsole = users.filter { ($0[onConsoleKey] as? NSNumber)?.boolValue == true }
        return onConsole.lazy.compactMap(pid).first ?? users.lazy.compactMap(pid).first
    }

    /// The holder's PID as the IORegistry reports it right now.
    static func currentPID() -> Int32? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let property = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0),
              let users = property.takeRetainedValue() as? [[String: Any]]
        else { return nil }
        return pid(fromConsoleUsers: users)
    }

    /// "pid 123 (com.example.app) — <hint>" for the log: a bundle ID or
    /// process name, never anything the user typed, plus what to do about it.
    static func describeCurrent() -> String {
        guard let pid = currentPID() else { return "holder unknown" }
        let name = processName(pid)
        let exists = name != nil || kill(pid, 0) == 0 || errno != ESRCH
        let label = name.map { "pid \(pid) (\($0))" } ?? "pid \(pid)"
        return "\(label) — \(hint(holderName: name, exists: exists))"
    }

    /// Pure: what the user should do, by who holds it. Learned the hard way:
    /// a system password prompt left hidden behind other windows showed up
    /// as "loginwindow" and looked like a stuck lock screen.
    static func hint(holderName name: String?, exists: Bool) -> String {
        guard exists else {
            return "process no longer exists, stale secure input: log out and back in to reset"
        }
        let systemPrompts = ["loginwindow", "com.apple.loginwindow", "SecurityAgent", "com.apple.SecurityAgent"]
        if let name, systemPrompts.contains(name) {
            return "likely an open system password prompt, possibly hidden behind other windows: "
                + "press F3 (Mission Control) to find it, then close it or enter the password"
        }
        return "likely a focused password field in that app: close it or quit the app; "
            + "in Terminal/iTerm turn off Secure Keyboard Entry; press F3 (Mission Control) to find hidden windows"
    }

    private static func processName(_ pid: Int32) -> String? {
        if let app = NSRunningApplication(processIdentifier: pid) {
            return app.bundleIdentifier ?? app.localizedName
        }
        var buffer = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }
}
