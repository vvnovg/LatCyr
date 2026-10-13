import AppKit

/// A log message. Its own string interpolation is the one place that may
/// print a `Sensitive` value unredacted — and only while typed-text capture
/// is on. Everything else interpolates as `String(describing:)`.
struct LogMessage: ExpressibleByStringInterpolation {
    let text: String

    init(stringLiteral value: String) {
        text = value
    }

    init(stringInterpolation: Interpolation) {
        text = stringInterpolation.result
    }

    struct Interpolation: StringInterpolationProtocol {
        var result = ""
        /// Read once per message, so a message is never half raw, half redacted.
        private let captureText = Log.captureText

        init(literalCapacity: Int, interpolationCount: Int) {
            result.reserveCapacity(literalCapacity * 2)
        }

        mutating func appendLiteral(_ literal: String) {
            result += literal
        }

        /// Non-generic, so it wins over the generic overload below.
        mutating func appendInterpolation(_ value: Sensitive) {
            result += captureText ? value.text : value.description
        }

        mutating func appendInterpolation<T>(_ value: T) {
            result += String(describing: value)
        }
    }
}

/// One line of the log file. Pure: the caller supplies the time and app.
enum LogLine {
    static func format(date: Date, level: LogLevel, app: String, message: String, timeZone: TimeZone = .current) -> String {
        // One event per line — support greps these files.
        let escaped = message
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\(timestamp(date, timeZone: timeZone)) \(level.tag) [\(app)] \(escaped)"
    }

    /// Building an ISO8601DateFormatter is expensive and this runs inside the
    /// event tap callback at debug level, so the common case is cached.
    private static var cachedFormatter = makeFormatter(timeZone: .current)

    private static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = cachedFormatter.timeZone == timeZone ? cachedFormatter : makeFormatter(timeZone: timeZone)
        return formatter.string(from: date)
    }

    private static func makeFormatter(timeZone: TimeZone) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = timeZone
        return formatter
    }
}

/// Logging facade. All callers in this app run on the main thread, so the
/// static state needs no synchronization; file I/O happens behind `sink`
/// (FileLogger's own queue), never here.
enum Log {
    static var level: LogLevel = .off
    /// Typed-text capture. Never persisted — LogController owns its timer.
    static var captureText = false
    /// Receives fully formatted lines. nil means nowhere to write.
    static var sink: ((String) -> Void)?
    /// Overridable for tests.
    static var frontmostAppID: () -> String = {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"
    }

    /// `@autoclosure`: below the current level the message is never built,
    /// which is what makes debug calls in the event tap free when logging is off.
    static func error(_ message: @autoclosure () -> LogMessage) { emit(.error, message) }
    static func info(_ message: @autoclosure () -> LogMessage) { emit(.info, message) }
    static func debug(_ message: @autoclosure () -> LogMessage) { emit(.debug, message) }

    /// Environment lines at the top of each logging session. Written at any
    /// level except `.off`: version and permissions matter to support even
    /// when the user only logs errors.
    static func header(_ lines: [String]) {
        guard level != .off, let sink else { return }
        let date = Date()
        let app = frontmostAppID()
        for line in lines {
            sink(LogLine.format(date: date, level: .info, app: app, message: line))
        }
    }

    private static func emit(_ messageLevel: LogLevel, _ message: () -> LogMessage) {
        guard messageLevel <= level, let sink else { return }
        sink(LogLine.format(date: Date(), level: messageLevel, app: frontmostAppID(), message: message().text))
    }
}
