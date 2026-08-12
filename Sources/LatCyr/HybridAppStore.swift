import Foundation

/// User-registered bundle identifiers of apps whose visible text is a
/// rendered view rather than an editable AX string (VS Code's integrated
/// terminal, other Electron-based apps, etc.) — the same problem the
/// hardcoded terminal list in KeystrokeSimulator solves, extended here by
/// the user via the menu instead of a code change.
final class HybridAppStore {
    private(set) var bundleIDs: Set<String> = []

    private let dynamicURL: URL

    init(dynamicURL: URL = HybridAppStore.defaultDynamicURL) {
        self.dynamicURL = dynamicURL
    }

    static var defaultDynamicURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LatCyr/hybrid-apps.txt")
    }

    func load() {
        bundleIDs = LineFile.read(dynamicURL)
    }

    func contains(_ bundleID: String) -> Bool {
        bundleIDs.contains(bundleID.lowercased())
    }

    @discardableResult
    func add(_ bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        guard !bundleIDs.contains(lower) else { return false }
        bundleIDs.insert(lower)
        LineFile.append(lower, to: dynamicURL)
        return true
    }
}
