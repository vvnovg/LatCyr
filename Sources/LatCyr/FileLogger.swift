import Foundation

/// Thin wrapper over the log files on disk. Every file operation runs on a
/// private serial queue: the event tap is an active tap, so the system
/// waits for its callback on every keystroke — a disk write there would
/// stall typing. Callers only format a line and enqueue it.
final class FileLogger {
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LatCyr")
    }

    let directory: URL
    private let queue = DispatchQueue(label: "com.latcyr.log", qos: .utility)

    // State below is touched only on `queue`.
    private var handle: FileHandle?
    /// Kept in memory so a write never needs a stat.
    private var currentSize = 0
    private var maxTotalBytes: Int
    /// Set when the file can't be opened or written. There is nowhere to
    /// report the logger's own failure, so it goes quiet until `close()`
    /// clears the latch and allows a retry. LogController calls `close()`
    /// only on transitions to/from `.off`, so a failure silences logging
    /// until logging is turned off and back on.
    private var failed = false
    /// Formatted header, see `setHeader`.
    private var header = Data()
    /// Set by `rotate()`: the next write starts a fresh current file and
    /// puts the header in front of its own line.
    private var headerPending = false

    init(directory: URL = FileLogger.defaultDirectory, maxTotalBytes: Int) {
        self.directory = directory
        self.maxTotalBytes = maxTotalBytes
    }

    var currentFileURL: URL { url(forIndex: 0) }

    func write(_ line: String) {
        let data = Data((line + "\n").utf8)
        queue.async { [self] in
            guard openIfNeeded() else { return }
            let perFile = LogRotation.perFileLimit(totalLimit: maxTotalBytes)
            if LogRotation.shouldRotate(currentSize: currentSize, incoming: data.count, perFileLimit: perFile) {
                rotate()
                // Files written under an older, larger limit may still be
                // around; drop whatever no longer fits before new data lands.
                enforceLimits()
                guard openIfNeeded() else { return }
            }
            if headerPending {
                headerPending = false
                // Header bytes count toward the file like any other: if the
                // header and this line together don't fit the per-file
                // limit, the header is skipped rather than break the cap.
                if currentSize == 0, !header.isEmpty, header.count + data.count <= perFile {
                    do {
                        try handle?.write(contentsOf: header)
                        currentSize += header.count
                    } catch {
                        closeHandle()
                        failed = true
                        return
                    }
                }
            }
            do {
                try handle?.write(contentsOf: data)
                currentSize += data.count
            } catch {
                closeHandle()
                failed = true
            }
        }
    }

    /// Lines (already formatted) written at the top of every file a
    /// rotation starts. The header LogController writes at launch and on
    /// off -> on lands only in the file current at that moment; without this,
    /// after a few rotations no file left on disk would say which version,
    /// permissions or input sources produced it.
    func setHeader(_ lines: [String]) {
        let data = Data(lines.map { $0 + "\n" }.joined().utf8)
        queue.async { [self] in
            header = data
        }
    }

    /// Applies a new total cap right away, deleting what no longer fits —
    /// lowering 100 MB to 10 MB must free the disk now, not after a while.
    func setMaxTotalBytes(_ bytes: Int) {
        queue.async { [self] in
            maxTotalBytes = bytes
            enforceLimits()
        }
    }

    /// Closes the current file (it reopens lazily on the next write) and
    /// clears the failure latch. Existing files are kept: they may not have
    /// been sent to support yet.
    func close() {
        queue.async { [self] in
            closeHandle()
            failed = false
        }
    }

    /// Blocks until every queued operation has run. For app termination and tests.
    func flush() {
        queue.sync {}
    }

    // MARK: - Private (queue only)

    private func url(forIndex index: Int) -> URL {
        directory.appendingPathComponent(index == 0 ? "latcyr.log" : "latcyr.\(index).log")
    }

    private func openIfNeeded() -> Bool {
        if handle != nil { return true }
        if failed { return false }
        let fileManager = FileManager.default
        let url = currentFileURL
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: url.path) {
                fileManager.createFile(atPath: url.path, contents: nil)
            }
            let opened = try FileHandle(forWritingTo: url)
            currentSize = Int(try opened.seekToEnd())
            handle = opened
            return true
        } catch {
            failed = true
            return false
        }
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
    }

    /// The one deliberate exception to the total cap: a single line longer
    /// than the per-file limit is written whole into a fresh file
    /// (`LogRotation.shouldRotate` never rotates an empty file), so that file
    /// can exceed `perFile` until the next rotation. If it exceeds
    /// `maxTotal - perFile`, the next rotation may delete it outright:
    /// `enforceLimits` reserves a full `perFile` for the new current file and
    /// drops rotated files, oldest first, until the rest fits.
    private func rotate() {
        closeHandle()
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: url(forIndex: LogRotation.fileCount - 1))
        for index in stride(from: LogRotation.fileCount - 2, through: 0, by: -1) {
            let from = url(forIndex: index)
            if fileManager.fileExists(atPath: from.path) {
                try? fileManager.moveItem(at: from, to: url(forIndex: index + 1))
            }
        }
        currentSize = 0
        headerPending = true
    }

    private func enforceLimits() {
        let perFile = LogRotation.perFileLimit(totalLimit: maxTotalBytes)
        if fileSize(forIndex: 0) > perFile { rotate() }
        var rotated: [Int: Int] = [:]
        for index in 1..<LogRotation.fileCount where FileManager.default.fileExists(atPath: url(forIndex: index).path) {
            rotated[index] = fileSize(forIndex: index)
        }
        // Reserve a full per-file budget for the current file: it will grow to
        // that size, and the cap must hold then, not only at this moment.
        let doomed = LogRotation.filesToDelete(currentSize: max(fileSize(forIndex: 0), perFile), rotated: rotated, totalLimit: maxTotalBytes)
        for index in doomed {
            try? FileManager.default.removeItem(at: url(forIndex: index))
        }
    }

    private func fileSize(forIndex index: Int) -> Int {
        if index == 0, handle != nil { return currentSize }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url(forIndex: index).path)
        return (attrs?[.size] as? NSNumber)?.intValue ?? 0
    }
}
