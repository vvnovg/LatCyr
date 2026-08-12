import Foundation

/// Owns the merged set of exception words: never converted when typed
/// correctly, always converted when typed in the wrong layout — regardless
/// of LanguageDetector's score thresholds (see isWrongLayout). Bundled
/// defaults ship inside the .app; user additions go to a separate file
/// that survives repackaging (package-app.sh re-signs and drops TCC
/// permissions on every run, but never touches Application Support).
final class ExceptionStore {
    private(set) var words: Set<String> = []

    private let bundledURL: URL?
    private let dynamicURL: URL

    init(
        bundledURL: URL? = Bundle.main.resourceURL?.appendingPathComponent("exceptions.txt"),
        dynamicURL: URL = ExceptionStore.defaultDynamicURL
    ) {
        self.bundledURL = bundledURL
        self.dynamicURL = dynamicURL
    }

    static var defaultDynamicURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LatCyr/exceptions.txt")
    }

    /// Reads both files (whichever exist) into `words`. Call once at
    /// startup — later edits go through `add`, not another `load`.
    func load() {
        var merged: Set<String> = []
        if let bundledURL { merged.formUnion(LineFile.read(bundledURL)) }
        merged.formUnion(LineFile.read(dynamicURL))
        words = merged
    }

    func contains(_ word: String) -> Bool {
        words.contains(word.lowercased())
    }

    /// Adds `word` to the dynamic file and to `words`. Returns false if it
    /// was already present (from either file) — no duplicate line written.
    @discardableResult
    func add(_ word: String) -> Bool {
        let lower = word.lowercased()
        guard !words.contains(lower) else { return false }
        words.insert(lower)
        LineFile.append(lower, to: dynamicURL)
        return true
    }
}
