import Foundation

/// Owns the logging runtime: wires `Log` to the file, persists level and
/// size, and runs the typed-text capture timer. Main thread only.
final class LogController {
    static let captureDuration: TimeInterval = 30 * 60

    private let settings: LogSettings
    private let fileLogger: FileLogger
    private var captureTimer: Timer?
    /// Called on the main thread when capture switches itself off, so the
    /// menu can drop its checkmark.
    var onCaptureExpired: (() -> Void)?

    init(settings: LogSettings = LogSettings(), fileLogger: FileLogger? = nil) {
        self.settings = settings
        self.fileLogger = fileLogger ?? FileLogger(maxTotalBytes: settings.maxTotalBytes)
    }

    var level: LogLevel { settings.level }
    var maxTotalBytes: Int { settings.maxTotalBytes }
    var isCapturingText: Bool { Log.captureText }
    var logFileURL: URL { fileLogger.currentFileURL }
    var logDirectory: URL { fileLogger.directory }

    /// Call once at launch. `header` is evaluated only when logging is on.
    func start(header: () -> [String]) {
        let fileLogger = self.fileLogger
        Log.sink = { line in fileLogger.write(line) }
        Log.level = settings.level
        fileLogger.setMaxTotalBytes(settings.maxTotalBytes)
        if Log.level != .off {
            writeHeader(header())
        }
    }

    func setLevel(_ newLevel: LogLevel, header: () -> [String]) {
        let old = Log.level
        guard newLevel != old else { return }
        if newLevel < .info { setCapturingText(false) }
        // Logged under the old level: records a switch *down* (including to off).
        Log.info("log level \(old.tag) -> \(newLevel.tag)")
        settings.level = newLevel
        Log.level = newLevel
        if newLevel == .off {
            fileLogger.close()
            return
        }
        if old == .off {
            // close() also clears FileLogger's failure latch, so turning
            // logging back on retries a file that previously failed to open.
            fileLogger.close()
            writeHeader(header())
        }
        // Logged under the new level: records a switch *up* from below info.
        if old < .info {
            Log.info("log level \(old.tag) -> \(newLevel.tag)")
        }
    }

    func setMaxTotalBytes(_ bytes: Int) {
        settings.maxTotalBytes = bytes
        fileLogger.setMaxTotalBytes(settings.maxTotalBytes)
        Log.info("log size limit \(settings.maxTotalBytes / LogSettings.megabyte) MB")
    }

    /// Turning it on (re)starts the 30-minute timer. Refused below `.info`:
    /// at the error level no message carries typed text anyway.
    func setCapturingText(_ requested: Bool) {
        let on = requested && Log.level >= .info
        captureTimer?.invalidate()
        captureTimer = nil
        if on {
            let timer = Timer(timeInterval: Self.captureDuration, repeats: false) { [weak self] _ in
                self?.setCapturingText(false)
                self?.onCaptureExpired?()
            }
            // .common: keep counting while the status menu is open.
            RunLoop.main.add(timer, forMode: .common)
            captureTimer = timer
        }
        guard on != Log.captureText else { return }
        Log.captureText = on
        Log.info(on ? "typed text capture ON for \(Int(Self.captureDuration / 60)) min" : "typed text capture OFF")
    }

    /// Writes the header now and hands it to FileLogger to repeat at the top
    /// of every file a later rotation starts. Handed over first: if the
    /// header's own lines trigger a rotation, the new file gets the fresh
    /// header (once repeated, once as written) rather than a stale one from
    /// an earlier session.
    private func writeHeader(_ lines: [String]) {
        fileLogger.setHeader(Log.repeatedHeaderLines(lines))
        Log.header(lines)
    }

    /// Lets queued lines reach the disk before the app exits.
    func flush() {
        fileLogger.flush()
    }
}
