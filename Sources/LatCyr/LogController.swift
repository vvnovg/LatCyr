import Foundation

/// Owns the logging runtime: wires `Log` to the file, persists level and
/// size. Main thread only.
final class LogController {
    private let settings: LogSettings
    private let fileLogger: FileLogger

    init(settings: LogSettings = LogSettings(), fileLogger: FileLogger? = nil) {
        self.settings = settings
        self.fileLogger = fileLogger ?? FileLogger(maxTotalBytes: settings.maxTotalBytes)
    }

    var level: LogLevel { settings.level }
    var maxTotalBytes: Int { settings.maxTotalBytes }
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
        } else {
            // Level changed while on: the repeated header names the level.
            fileLogger.setHeader(Log.repeatedHeaderLines(header()))
        }
        // Logged under the new level: records a switch *up* from below info.
        if old < .info {
            Log.info("log level \(old.tag) -> \(newLevel.tag)")
        }
    }

    func setMaxTotalBytes(_ bytes: Int, header: () -> [String]) {
        settings.maxTotalBytes = bytes
        // The repeated header names the size limit; refresh only the stored
        // copy, no extra header block goes into the current file.
        if Log.level != .off {
            fileLogger.setHeader(Log.repeatedHeaderLines(header()))
        }
        fileLogger.setMaxTotalBytes(settings.maxTotalBytes)
        Log.info("log size limit \(settings.maxTotalBytes / LogSettings.megabyte) MB")
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
