import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import SwiftRDPCore

/// Screen Recording + Accessibility status and System Settings deep-links.
enum PermissionGate {
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    static var isScreenRecordingTrusted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static var allGranted: Bool {
        isAccessibilityTrusted && isScreenRecordingTrusted
    }

    /// Ask macOS to show the Screen Recording prompt (once per install until granted/denied).
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Ask macOS to show Accessibility prompt / open the pane.
    static func requestAccessibility(prompt: Bool = true) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func openScreenRecordingSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.Privacy.ScreenCapture",
        ]
        for s in urls {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
    }

    static func openAccessibilitySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.Privacy.Accessibility",
        ]
        for s in urls {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
    }

    /// First-launch / menu-bar gate: prompt missing permissions and optionally open Settings.
    @MainActor
    static func checkOnLaunch(openSettingsIfMissing: Bool = true) {
        let screenOK = isScreenRecordingTrusted
        let axOK = isAccessibilityTrusted
        RDPLog.app.info("Permissions: ScreenRecording=\(screenOK) Accessibility=\(axOK)")

        if !screenOK {
            _ = requestScreenRecording()
        }
        if !axOK {
            requestAccessibility(prompt: true)
        }

        guard openSettingsIfMissing, (!screenOK || !axOK) else { return }

        let alert = NSAlert()
        alert.messageText = L10n.t(.permissionsAlertTitle)
        alert.informativeText = L10n.t(.permissionsAlertBody)
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.t(.openSettings))
        alert.addButton(withTitle: L10n.t(.later))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            SettingsCoordinator.shared.open(section: .permissions)
        }
    }
}
