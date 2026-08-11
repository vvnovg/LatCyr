import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let inputMonitor = InputMonitor()
    private let permissionManager = PermissionManager()

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
