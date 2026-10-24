import Foundation

/// Shared plain-text line-file I/O for ExceptionStore and HybridAppStore:
/// one value per line, blank lines and `#`-prefixed comments ignored,
/// values lowercased on read.
enum LineFile {
    static func read(_ url: URL) -> Set<String> {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var result: Set<String> = []
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            result.insert(line.lowercased())
        }
        return result
    }

    /// Appends `value` as its own line, creating the parent directory and
    /// file if either is missing. A file whose last line has no newline (saved
    /// by hand in an editor) gets one first: otherwise the value was glued to
    /// that line — «jdbcесли», seen live, made neither word an exception.
    static func append(_ value: String, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let line = value + "\n"
        if !FileManager.default.fileExists(atPath: url.path) {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        } else if let handle = try? FileHandle(forUpdating: url) {
            let end = handle.seekToEndOfFile()
            var needsNewline = false
            if end > 0 {
                handle.seek(toFileOffset: end - 1)
                needsNewline = handle.readData(ofLength: 1) != Data("\n".utf8)
                handle.seekToEndOfFile()
            }
            handle.write(Data(((needsNewline ? "\n" : "") + line).utf8))
            try? handle.close()
        }
    }
}
