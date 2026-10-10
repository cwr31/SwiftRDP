import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import IOKit.pwr_mgt
import SwiftRDPCore

@MainActor
final class RemoteSessionSecurityController {
    private static let activityIntervalNs: UInt64 = 25_000_000_000
    private static let unlockCheckIntervalNs: UInt64 = 200_000_000
    private static let unlockCheckCount = 8

    private var activeSessionID: UUID?
    private var activityTask: Task<Void, Never>?
    private var userActivityAssertionID: IOPMAssertionID = 0
    private var attemptedUnlockSessionID: UUID?

    func update(enabled: Bool, sessionID: UUID?) {
        let accessibilityOK = PermissionGate.isAccessibilityTrusted
        guard enabled, let sessionID, accessibilityOK else {
            if enabled, !accessibilityOK {
                RDPLog.app.info("Remote session security skipped (Accessibility permission missing)")
            }
            stop()
            return
        }

        if activeSessionID == sessionID { return }
        stop()
        activeSessionID = sessionID
        declareRemoteActivity()
        postStationaryMouseEvent()
        activityTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.activityIntervalNs)
                guard !Task.isCancelled, let self,
                      self.activeSessionID == sessionID else { return }
                self.declareRemoteActivity()
                self.postStationaryMouseEvent()
            }
        }

        guard attemptedUnlockSessionID != sessionID else { return }
        attemptedUnlockSessionID = sessionID
        Task { [weak self] in
            await self?.unlockIfLoginWindowIsFocused(sessionID: sessionID)
        }
    }

    func sessionEnded(_ sessionID: UUID) {
        if activeSessionID == sessionID { stop() }
        if attemptedUnlockSessionID == sessionID {
            attemptedUnlockSessionID = nil
        }
    }

    private func stop() {
        activityTask?.cancel()
        activityTask = nil
        activeSessionID = nil
        if userActivityAssertionID != 0 {
            IOPMAssertionRelease(userActivityAssertionID)
            userActivityAssertionID = 0
        }
    }

    private func declareRemoteActivity() {
        var assertionID = userActivityAssertionID
        let result = IOPMAssertionDeclareUserActivity(
            "SwiftRDP active remote session" as CFString,
            kIOPMUserActiveRemote,
            &assertionID
        )
        guard result == kIOReturnSuccess else {
            RDPLog.app.debug("Remote session activity declaration failed: \(result)")
            return
        }
        userActivityAssertionID = assertionID
    }

    private func postStationaryMouseEvent() {
        guard let current = CGEvent(source: nil),
              let source = CGEventSource(stateID: .privateState),
              let event = CGEvent(
                mouseEventSource: source,
                mouseType: .mouseMoved,
                mouseCursorPosition: current.location,
                mouseButton: .left
              ) else { return }
        source.localEventsSuppressionInterval = 0
        event.post(tap: .cghidEventTap)
    }

    private func unlockIfLoginWindowIsFocused(sessionID: UUID) async {
        guard PermissionGate.isAccessibilityTrusted,
              let password = HostUnlockCredentialStore.load() else {
            RDPLog.app.info("Remote session auto-unlock skipped (credential or Accessibility permission missing)")
            return
        }

        for attempt in 0..<Self.unlockCheckCount {
            guard !Task.isCancelled, activeSessionID == sessionID else { return }
            if let field = focusedLoginWindowSecureField(), setPassword(password, in: field) {
                guard submitPassword() else {
                    RDPLog.app.error("Remote session auto-unlock could not submit the password")
                    return
                }
                RDPLog.app.info("Remote session auto-unlock submitted to the focused login window")
                return
            }
            guard attempt + 1 < Self.unlockCheckCount else { break }
            try? await Task.sleep(nanoseconds: Self.unlockCheckIntervalNs)
        }

        RDPLog.app.debug("Remote session auto-unlock skipped (no focused login-window password field)")
    }

    private func focusedLoginWindowSecureField() -> AXUIElement? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              (session[kCGSessionOnConsoleKey as String] as? Bool) == true,
              (session[kCGSessionUserIDKey as String] as? NSNumber)?.uint32Value == getuid(),
              let loginWindow = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.loginwindow"
              ).first else { return nil }

        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        let focused = unsafeDowncast(focusedValue, to: AXUIElement.self)

        var focusedPID: pid_t = 0
        guard AXUIElementGetPid(focused, &focusedPID) == .success,
              focusedPID == loginWindow.processIdentifier else { return nil }

        var subroleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXSubroleAttribute as CFString,
            &subroleValue
        ) == .success,
        (subroleValue as? String) == (kAXSecureTextFieldSubrole as String) else { return nil }
        return focused
    }

    private func setPassword(_ password: String, in field: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(
            field,
            kAXValueAttribute as CFString,
            password as CFTypeRef
        ) == .success
    }

    private func submitPassword() -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false) else { return false }
        source.localEventsSuppressionInterval = 0
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
