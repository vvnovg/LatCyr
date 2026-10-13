import Foundation

/// How much goes into the log file. Each level includes everything below it.
enum LogLevel: Int, Comparable, CaseIterable {
    case off = 0, error, info, debug

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Tag written into each log line.
    var tag: String {
        switch self {
        case .off: return "OFF"
        case .error: return "ERROR"
        case .info: return "INFO"
        case .debug: return "DEBUG"
        }
    }

    /// Menu title.
    var title: String {
        switch self {
        case .off: return "Выключено"
        case .error: return "Только ошибки"
        case .info: return "Информация"
        case .debug: return "Отладка"
        }
    }
}

/// Persisted logging settings: level and total size cap. The "capture typed
/// text" flag is deliberately not here — it must never survive a restart.
struct LogSettings {
    static let megabyte = 1024 * 1024
    static let allowedMaxTotalBytes = [10 * megabyte, 50 * megabyte, 100 * megabyte]
    static let defaultMaxTotalBytes = 100 * megabyte

    private static let levelKey = "logLevel"
    private static let maxTotalBytesKey = "logMaxTotalBytes"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// A missing key reads as 0, which is `.off` — the required default.
    var level: LogLevel {
        get { LogLevel(rawValue: defaults.integer(forKey: Self.levelKey)) ?? .off }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.levelKey) }
    }

    /// Anything outside the allowed set (missing key, hand-edited plist,
    /// a value from a future version) reads as the 100 MB ceiling.
    var maxTotalBytes: Int {
        get {
            let stored = defaults.integer(forKey: Self.maxTotalBytesKey)
            return Self.allowedMaxTotalBytes.contains(stored) ? stored : Self.defaultMaxTotalBytes
        }
        nonmutating set {
            let value = Self.allowedMaxTotalBytes.contains(newValue) ? newValue : Self.defaultMaxTotalBytes
            defaults.set(value, forKey: Self.maxTotalBytesKey)
        }
    }
}
