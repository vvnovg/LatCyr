import Foundation

/// Shared plain-text line-file I/O for ExceptionStore and HybridAppStore:
/// one value per line, blank lines and `#`-prefixed comments ignored,
/// values lowercased on read.
enum LineFile {
    static func read(_ url: URL) -> Set<String> {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var result: Set<String> = []
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            result.insert(line.lowercased())
        }
        return result
    }

    /// Appends `value` as its own line, creating the parent directory and
    /// file if either is missing.
    static func append(_ value: String, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let line = value + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
