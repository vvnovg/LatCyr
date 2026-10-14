import AppKit
import Carbon

/// Logging submenu, Finder shortcuts and the log header. A separate file
/// to keep AppDelegate's own menu code readable.
extension AppDelegate {
    /// Environment lines written at the top of every logging session —
    /// what support would otherwise have to ask the user for first.
    /// Exception *words* are user data, so only their count is logged.
    func logHeader() -> [String] {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return [
            "=== LatCyr \(version) (\(build)) ===",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "log: level=\(logController.level.tag) maxTotal=\(logController.maxTotalBytes / LogSettings.megabyte)MB",
            "permissions: accessibility=\(permissionManager.hasAccessibility) inputMonitoring=\(permissionManager.hasInputMonitoring)",
            // While another app holds Secure Event Input (a password field,
            // some terminals' "Secure Keyboard Entry"), the tap sees no keys.
            "secure event input: \(IsSecureEventInputEnabled() ? "true, held by \(SecureInputHolder.describeCurrent())" : "false")",
            "input sources: \(LayoutManager().enabledInputSourceIDs().joined(separator: ", "))",
            "hybrid apps: \(inputMonitor.hybridAppStore.bundleIDs.sorted().joined(separator: ", "))",
            "exceptions: \(inputMonitor.exceptionStore.words.count) words",
        ]
    }

    func buildRevealExceptionsItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Показать файл исключений в Finder",
            action: #selector(revealExceptionsFile),
            keyEquivalent: ""
        )
        item.target = self
        return item
    }

    func buildLoggingMenuItem() -> NSMenuItem {
        let submenu = NSMenu()

        for level in LogLevel.allCases {
            let item = NSMenuItem(title: level.title, action: #selector(selectLogLevel(_:)), keyEquivalent: "")
            item.target = self
            item.tag = level.rawValue
            item.state = logController.level == level ? .on : .off
            submenu.addItem(item)
        }

        submenu.addItem(.separator())

        for bytes in LogSettings.allowedMaxTotalBytes {
            let item = NSMenuItem(
                title: "Макс. размер: \(bytes / LogSettings.megabyte) МБ",
                action: #selector(selectLogSize(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = bytes
            item.state = logController.maxTotalBytes == bytes ? .on : .off
            submenu.addItem(item)
        }

        submenu.addItem(.separator())

        let revealItem = NSMenuItem(title: "Показать лог в Finder", action: #selector(revealLog), keyEquivalent: "")
        revealItem.target = self
        submenu.addItem(revealItem)

        let parent = NSMenuItem(title: "Логирование", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    @objc func selectLogLevel(_ sender: NSMenuItem) {
        guard let level = LogLevel(rawValue: sender.tag) else { return }
        logController.setLevel(level, header: logHeader)
        rebuildMenu()
    }

    @objc func selectLogSize(_ sender: NSMenuItem) {
        logController.setMaxTotalBytes(sender.tag, header: logHeader)
        rebuildMenu()
    }

    @objc func revealLog() {
        reveal(logController.logFileURL, orDirectory: logController.logDirectory)
    }

    @objc func revealExceptionsFile() {
        let url = ExceptionStore.defaultDynamicURL
        reveal(url, orDirectory: url.deletingLastPathComponent())
    }

    /// Selects `file` in Finder; if it doesn't exist yet, opens the
    /// directory it would live in instead (creating it if needed).
    private func reveal(_ file: URL, orDirectory directory: URL) {
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }
}
