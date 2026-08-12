import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let inputMonitor = InputMonitor()
    private let permissionManager = PermissionManager()
    private let textFieldController = TextFieldController()

    private var statusItem: NSStatusItem?
    private var enabled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        if permissionManager.isFullyAuthorized {
            setEnabled(true)
            rebuildMenu() // menu was built with enabled=false; refresh to show "включено"
        } else {
            promptForPermissions()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        inputMonitor.stop()
    }

    // MARK: - Menu

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "character.cursor.ibeam", accessibilityDescription: "LatCyr")
        }
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let toggleItem = NSMenuItem(
            title: enabled ? "LatCyr включено" : "LatCyr выключено",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.state = enabled ? .on : .off
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let addExceptionItem = NSMenuItem(
            title: "Добавить выделенное в исключения",
            action: #selector(addSelectedWordToExceptions),
            keyEquivalent: ""
        )
        addExceptionItem.target = self
        menu.addItem(addExceptionItem)

        let addHybridAppItem = NSMenuItem(
            title: "Добавить текущее приложение как гибридное",
            action: #selector(addCurrentAppAsHybrid),
            keyEquivalent: ""
        )
        addHybridAppItem.target = self
        menu.addItem(addHybridAppItem)

        menu.addItem(.separator())

        let header = NSMenuItem(title: "Разрешения:", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let accItem = NSMenuItem(
            title: permissionManager.hasAccessibility ? "  ✓ Accessibility" : "  ✗ Accessibility",
            action: nil,
            keyEquivalent: ""
        )
        accItem.isEnabled = false
        menu.addItem(accItem)

        let imItem = NSMenuItem(
            title: permissionManager.hasInputMonitoring ? "  ✓ Input Monitoring" : "  ✗ Input Monitoring",
            action: nil,
            keyEquivalent: ""
        )
        imItem.isEnabled = false
        menu.addItem(imItem)

        let openSettingsItem = NSMenuItem(title: "Открыть настройки разрешений…", action: #selector(openPermissions), keyEquivalent: "")
        openSettingsItem.target = self
        menu.addItem(openSettingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Выход", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        setEnabled(!enabled)
        rebuildMenu()
    }

    @objc private func openPermissions() {
        permissionManager.openAccessibilitySettings()
    }

    @objc private func addSelectedWordToExceptions() {
        guard let raw = textFieldController.selectedText() else {
            showAlert(message: "Не удалось прочитать выделение. В терминалах и некоторых приложениях это не поддерживается.")
            return
        }
        guard let word = normalizedExceptionWord(from: raw) else {
            showAlert(message: "Выделите слово на одном языке — русском или английском.")
            return
        }
        if inputMonitor.exceptionStore.add(word) {
            showAlert(message: "Добавлено в исключения: \(word)")
        } else {
            showAlert(message: "Уже в списке исключений: \(word)")
        }
    }

    @objc private func addCurrentAppAsHybrid() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            showAlert(message: "Не удалось определить текущее приложение.")
            return
        }
        let name = app.localizedName ?? bundleID
        let alreadyKnown = bundleID == Bundle.main.bundleIdentifier
            || KeystrokeSimulator.terminalBundleIDs.contains(bundleID)
            || inputMonitor.hybridAppStore.contains(bundleID)
        guard !alreadyKnown else {
            showAlert(message: "Уже поддерживается: \(name) (\(bundleID))")
            return
        }
        inputMonitor.hybridAppStore.add(bundleID)
        showAlert(message: "Добавлено как гибридное: \(name) (\(bundleID))")
    }

    /// Accepts a word consisting entirely of one alphabet — Latin or
    /// Cyrillic (а-я plus ё), lowercased and trimmed. Rejects everything
    /// else: empty selection, digits, punctuation, mixed scripts.
    private func normalizedExceptionWord(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        let isLatin = lower.unicodeScalars.allSatisfy { ("a"..."z").contains($0) }
        let isCyrillic = lower.unicodeScalars.allSatisfy { (0x0430...0x044F).contains($0.value) || $0.value == 0x0451 }
        guard isLatin || isCyrillic else { return nil }
        return lower
    }

    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "LatCyr"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func setEnabled(_ value: Bool) {
        // Never report "включено" while the monitor cannot actually run.
        if value && !permissionManager.isFullyAuthorized {
            promptForPermissions()
            return
        }
        enabled = value
        if value {
            inputMonitor.start()
        } else {
            inputMonitor.stop()
        }
    }

    private func rebuildMenu() {
        statusItem?.menu = buildMenu()
    }

    private func promptForPermissions() {
        let alert = NSAlert()
        alert.messageText = "LatCyr требует разрешения"
        alert.informativeText = "Для работы нужны разрешения Accessibility и Input Monitoring. Откройте настройки, включите LatCyr в обоих списках и перезапустите приложение."
        alert.addButton(withTitle: "Открыть настройки")
        alert.addButton(withTitle: "Позже")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            permissionManager.openAccessibilitySettings()
        }
    }
}
