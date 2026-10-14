import Foundation

/// Decides when to log that the event tap is running but receiving no keys.
/// Pure: InputMonitor feeds it keyDowns and periodic ticks with the current
/// Secure Event Input state, and logs the events it returns.
///
/// Why it exists: with Secure Event Input held by another app (or with an
/// Input Monitoring grant that belongs to an older build) the tap is created
/// fine, the menu reads "включено", and the log shows nothing but app
/// switches — silence is the only symptom.
struct KeyFlowDiagnostics: Equatable {
    /// How long after start the absence of keys is worth an error line.
    static let silenceThreshold: TimeInterval = 60

    enum Event: Equatable {
        /// The first keyDown since start, `after` seconds in.
        case firstKeyDown(after: TimeInterval)
        case secureInputChanged(Bool)
        /// No keyDown for `silenceThreshold` since start. Reported once.
        case noKeysSinceStart(secureInput: Bool)
    }

    private let startedAt: Date
    private var secureInput: Bool
    private(set) var keyDownSeen = false
    private var silenceReported = false

    init(startedAt: Date, secureInput: Bool) {
        self.startedAt = startedAt
        self.secureInput = secureInput
    }

    /// Called from the event tap on every real keyDown; non-nil only the
    /// first time, so the hot path costs one Bool check afterwards.
    mutating func recordKeyDown(at now: Date) -> Event? {
        guard !keyDownSeen else { return nil }
        keyDownSeen = true
        return .firstKeyDown(after: now.timeIntervalSince(startedAt))
    }

    mutating func tick(now: Date, secureInput newSecureInput: Bool) -> [Event] {
        var events: [Event] = []
        if newSecureInput != secureInput {
            secureInput = newSecureInput
            events.append(.secureInputChanged(newSecureInput))
        }
        if !keyDownSeen, !silenceReported, now.timeIntervalSince(startedAt) >= Self.silenceThreshold {
            silenceReported = true
            events.append(.noKeysSinceStart(secureInput: newSecureInput))
        }
        return events
    }
}
