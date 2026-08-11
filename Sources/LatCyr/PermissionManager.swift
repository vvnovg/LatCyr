import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Checks and helps grant Accessibility and Input Monitoring permissions.
final class PermissionManager {
    /// Whether the app has Accessibility permission.
    var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Whether the app has Input Monitoring permission.
    var hasInputMonitoring: Bool {
        CGPreflightListenEventAccess()
    }

    /// Whether all required permissions are granted.
    var isFullyAuthorized: Bool {
        hasAccessibility && hasInputMonitoring
    }

    /// Open the Accessibility pane in System Settings.
    func openAccessibilitySettings() {
        openSettingsPane(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// Open the Input Monitoring pane in System Settings.
    func openInputMonitoringSettings() {
        openSettingsPane(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private func openSettingsPane(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
