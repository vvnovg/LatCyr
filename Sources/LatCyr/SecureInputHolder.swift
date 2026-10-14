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

    /// "pid 123 (com.example.app)" for the log — a bundle ID or process
    /// name, never anything the user typed.
    static func describeCurrent() -> String {
        guard let pid = currentPID() else { return "holder unknown" }
        if let app = NSRunningApplication(processIdentifier: pid) {
            let name = app.bundleIdentifier ?? app.localizedName ?? "?"
            return "pid \(pid) (\(name))"
        }
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? "pid \(pid) (\(String(cString: buffer)))" : "pid \(pid)"
    }
}
