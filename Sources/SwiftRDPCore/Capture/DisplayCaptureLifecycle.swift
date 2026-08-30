import AppKit
import Foundation
import IOKit.pwr_mgt

/// Session-scoped display wake (UU-style WakeUpActivity for built-in panel capture).
enum DisplayWake {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var displayAssertionID: IOPMAssertionID = 0
    nonisolated(unsafe) private static var captureSessionActive = false
    /// When false (virtual / clamshell capture), do not hold or nudge the built-in panel awake.
    nonisolated(unsafe) private static var keepBuiltInPanelAwake = false

    /// Hold the built-in panel awake for the duration of an authorized capture run.
    static func beginCaptureSession(keepBuiltInPanelAwake: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !captureSessionActive else {
            applyKeepBuiltInPanelAwakeLocked(keepBuiltInPanelAwake)
            return
        }
        captureSessionActive = true
        applyKeepBuiltInPanelAwakeLocked(keepBuiltInPanelAwake)
    }

    static func setKeepBuiltInPanelAwake(_ keepAwake: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard captureSessionActive else { return }
        applyKeepBuiltInPanelAwakeLocked(keepAwake)
    }

    static func endCaptureSession() {
        lock.lock()
        defer { lock.unlock() }
        guard captureSessionActive else { return }
        captureSessionActive = false
        keepBuiltInPanelAwake = false
        releaseDisplayAssertionLocked()
    }

    /// Nudge the panel awake on sleep notifications and during recovery.
    static func wakeIfNeeded() {
        lock.lock()
        let shouldWake = keepBuiltInPanelAwake
            && DisplayTopology.hasAwakeBuiltInDisplay()
            && captureSessionActive
        lock.unlock()
        guard shouldWake else { return }
        declareUserActivity()
        lock.lock()
        defer { lock.unlock() }
        guard keepBuiltInPanelAwake,
              DisplayTopology.hasAwakeBuiltInDisplay(),
              captureSessionActive else { return }
        ensureDisplayAssertionLocked(reason: "wake nudge")
    }

    private static func applyKeepBuiltInPanelAwakeLocked(_ keepAwake: Bool) {
        keepBuiltInPanelAwake = keepAwake
        if keepAwake, DisplayTopology.hasAwakeBuiltInDisplay() {
            ensureDisplayAssertionLocked(reason: "capture session")
        } else {
            releaseDisplayAssertionLocked()
        }
    }

    private static func declareUserActivity() {
        var activityID: IOPMAssertionID = 0
        if IOPMAssertionDeclareUserActivity(
            "SwiftRDP wake display" as CFString,
            kIOPMUserActiveLocal,
            &activityID
        ) == kIOReturnSuccess, activityID != 0 {
            IOPMAssertionRelease(activityID)
        }
    }

    private static func ensureDisplayAssertionLocked(reason: String) {
        guard displayAssertionID == 0 else { return }
        var id: IOPMAssertionID = 0
        guard IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "SwiftRDP capture session" as CFString,
            &id
        ) == kIOReturnSuccess, id != 0 else { return }
        displayAssertionID = id
        RDPLog.capture.info("DisplayWake: prevent display sleep on (id=\(id), \(reason))")
    }

    private static func releaseDisplayAssertionLocked() {
        guard displayAssertionID != 0 else { return }
        let id = displayAssertionID
        IOPMAssertionRelease(id)
        displayAssertionID = 0
        RDPLog.capture.info("DisplayWake: prevent display sleep off (id=\(id))")
    }
}

/// NSWorkspace sleep/wake → nudge panel awake / restart SCK.
final class DisplayCaptureLifecycle: @unchecked Sendable {
    private weak var capturer: ScreenCapturer?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    func start(monitoring capturer: ScreenCapturer) {
        self.capturer = capturer
        DispatchQueue.main.async { [weak self] in self?.registerObservers() }
    }

    func stop() {
        capturer = nil
        DispatchQueue.main.async { [weak self] in self?.unregisterObservers() }
    }

    private func registerObservers() {
        guard sleepObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let capturer = self?.capturer, capturer.isCaptureAuthorized else { return }
            guard capturer.capturesAwakePhysicalPanel else {
                RDPLog.capture.debug(
                    "DisplayCaptureLifecycle: display did sleep — ignored (virtual/clamshell capture)"
                )
                return
            }
            RDPLog.capture.info("DisplayCaptureLifecycle: display did sleep — waking panel")
            DisplayWake.wakeIfNeeded()
        }
        wakeObserver = center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let capturer = self?.capturer, capturer.isCaptureAuthorized else { return }
            guard capturer.capturesAwakePhysicalPanel else {
                RDPLog.capture.debug(
                    "DisplayCaptureLifecycle: display did wake — ignored (virtual/clamshell capture)"
                )
                return
            }
            RDPLog.capture.info("DisplayCaptureLifecycle: display did wake — restart capture")
            capturer.noteDisplayWake()
        }
        RDPLog.capture.info("ScreenCapturer: display sleep/wake notifications registered")
    }

    private func unregisterObservers() {
        let center = NSWorkspace.shared.notificationCenter
        if let sleepObserver {
            center.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
        if let wakeObserver {
            center.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }
}
