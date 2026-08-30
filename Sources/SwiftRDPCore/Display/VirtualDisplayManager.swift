import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import ObjectiveC
import Dispatch
import Darwin
import SwiftRDPObjC

/// Headless virtual display via private `CGVirtualDisplay` (runtime lookup only).
///
/// Used when the Mac has no physical panel. Physical-display machines capture the
/// panel directly and never create a virtual display.
public final class VirtualDisplayManager: @unchecked Sendable {
    public private(set) var active = false
    public private(set) var requestedWidth = 0
    public private(set) var requestedHeight = 0
    /// “Looks like” logical size when `preferHiDPI`; equals requested size otherwise.
    public private(set) var logicalWidth = 0
    public private(set) var logicalHeight = 0
    /// When true, virtual display exposes Retina-style scaled modes (2× framebuffer).
    public private(set) var preferHiDPI = false

    /// CGDirectDisplayID of the private virtual display, or 0 if none is active.
    public private(set) var displayID: CGDirectDisplayID = 0

    private var systemWakeAssertionID: IOPMAssertionID = 0
    private var displayWakeAssertionID: IOPMAssertionID = 0
    private var wakeAssertionActive = false
    private var userActivityAssertionID: IOPMAssertionID = 0
    private var keepAwakeTask: Task<Void, Never>?
    private var virtualDisplayObject: NSObject?
    private let lifecycleLock = NSLock()
    private let windowServerQueue = DispatchQueue(
        label: "com.swiftrdp.window-server",
        qos: .userInitiated
    )
    private var pendingOfflineDisplayID: CGDirectDisplayID = 0

    private struct CreatedDisplay: @unchecked Sendable {
        let object: NSObject
        let id: CGDirectDisplayID
    }

    private enum ApplySettingsResult: Sendable {
        case success
        case failure
        case exception(String)
    }

    private final class WindowServerResult<Value>: @unchecked Sendable {
        let lock = NSLock()
        var value: Value?
    }

    private final class ObjectiveCObject: @unchecked Sendable {
        let value: NSObject

        init(_ value: NSObject) {
            self.value = value
        }
    }

    /// Shared power policy (Settings → Prevent system / display sleep).
    private static let powerPolicyLock = NSLock()
    nonisolated(unsafe) private static var preventSystemSleepValue = true
    nonisolated(unsafe) private static var preventDisplaySleepValue = false

    public static var preventSystemSleep: Bool {
        powerPolicyLock.lock()
        defer { powerPolicyLock.unlock() }
        return preventSystemSleepValue
    }

    public static var preventDisplaySleep: Bool {
        powerPolicyLock.lock()
        defer { powerPolicyLock.unlock() }
        return preventDisplaySleepValue
    }

    public init() {}

    /// Keep the built-in panel awake only when mirroring an awake physical display.
    /// Clamshell + virtual capture must not fight lid sleep (avoids periodic backlight flicker).
    static func effectivePreventDisplaySleep() -> Bool {
        if Self.preventDisplaySleep { return true }
        return DisplayTopology.hasAwakeBuiltInDisplay()
    }

    /// Update Settings-driven power assertions. Live-applied to this manager when active.
    public static func setPowerPolicy(preventSystemSleep: Bool, preventDisplaySleep: Bool) {
        powerPolicyLock.lock()
        preventSystemSleepValue = preventSystemSleep
        preventDisplaySleepValue = preventDisplaySleep
        powerPolicyLock.unlock()
    }

    /// Create or resize a virtual display matching the requested pixel size.
    public func createMatching(
        width: Int,
        height: Int,
        preferHiDPI: Bool = false,
        logicalWidth: Int? = nil,
        logicalHeight: Int? = nil
    ) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        let pixelWidth = max(width & ~1, 2)
        let pixelHeight = max(height & ~1, 2)
        guard pixelWidth <= VirtualDisplayParameters.maxPixelWidth,
              pixelHeight <= VirtualDisplayParameters.maxPixelHeight else {
            RDPLog.display.error(
                "VirtualDisplay: rejected \(pixelWidth)x\(pixelHeight); " +
                "maximum is \(VirtualDisplayParameters.maxPixelWidth)x" +
                "\(VirtualDisplayParameters.maxPixelHeight)"
            )
            return
        }
        let useHiDPI = preferHiDPI
        let logicalW = max((logicalWidth ?? (useHiDPI ? pixelWidth / 2 : pixelWidth)) & ~1, 2)
        let logicalH = max((logicalHeight ?? (useHiDPI ? pixelHeight / 2 : pixelHeight)) & ~1, 2)
        let expectedScale = useHiDPI ? 2 : 1
        guard logicalW * expectedScale == pixelWidth,
              logicalH * expectedScale == pixelHeight else {
            RDPLog.display.error(
                "VirtualDisplay: invalid mode pixels \(pixelWidth)x\(pixelHeight) " +
                "logical \(logicalW)x\(logicalH) HiDPI=\(useHiDPI)"
            )
            return
        }

        if virtualDisplayObject != nil, active,
           self.preferHiDPI == useHiDPI,
           self.logicalWidth == logicalW,
           self.logicalHeight == logicalH,
           self.requestedWidth == pixelWidth,
           self.requestedHeight == pixelHeight {
            verifyRequestedMode(context: "noop")
            return
        }

        if virtualDisplayObject != nil, active {
            let previous = (
                requestedWidth,
                requestedHeight,
                self.logicalWidth,
                self.logicalHeight,
                self.preferHiDPI
            )
            self.requestedWidth = pixelWidth
            self.requestedHeight = pixelHeight
            self.logicalWidth = logicalW
            self.logicalHeight = logicalH
            self.preferHiDPI = useHiDPI
            if applyVirtualDisplayMode() {
                verifyRequestedMode(context: "mode switch")
                return
            }
            if updateExistingModes(pixelWidth: pixelWidth, pixelHeight: pixelHeight) {
                restoreRequestedModeIfNeeded(context: "in-place mode update")
                return
            }
            (
                self.requestedWidth,
                self.requestedHeight,
                self.logicalWidth,
                self.logicalHeight,
                self.preferHiDPI
            ) = previous
            RDPLog.display.error("VirtualDisplay: in-place mode update failed; keeping existing display")
            return
        }

        self.requestedWidth = pixelWidth
        self.requestedHeight = pixelHeight
        self.logicalWidth = logicalW
        self.logicalHeight = logicalH
        self.preferHiDPI = useHiDPI
        let hiDPITag = useHiDPI ? " HiDPI \(logicalW)x\(logicalH)" : ""
        RDPLog.display.info(
            "VirtualDisplay: create requested \(pixelWidth)x\(pixelHeight)\(hiDPITag)"
        )

        acquireWakeAssertion()
        waitForPendingDisplayOffline()

        if createVirtualDisplay(pixelWidth: pixelWidth, pixelHeight: pixelHeight) {
            active = true
            restoreRequestedModeIfNeeded(context: "create")
        } else {
            active = false
            self.preferHiDPI = false
            self.logicalWidth = 0
            self.logicalHeight = 0
            RDPLog.display.info(
                "VirtualDisplay: create failed \(pixelWidth)x\(pixelHeight) " +
                "(private CGVirtualDisplay API unavailable)"
            )
        }
    }

    public func destroy() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        destroyLocked()
    }

    @discardableResult
    func destroyIf(_ shouldDestroy: () -> Bool) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard shouldDestroy() else { return false }
        destroyLocked()
        return true
    }

    private func destroyLocked() {
        tearDownVirtualDisplay()
        releaseWakeAssertion()
        active = false
        requestedWidth = 0
        requestedHeight = 0
        logicalWidth = 0
        logicalHeight = 0
        preferHiDPI = false
        RDPLog.display.debug("VirtualDisplay: destroyed")
    }

    private func tearDownVirtualDisplay() {
        let oldDisplayID = displayID
        guard virtualDisplayObject != nil || oldDisplayID != 0 else {
            return
        }
        RDPLog.display.debug("VirtualDisplay: destroy id=\(oldDisplayID)")
        virtualDisplayObject = nil
        displayID = 0
        pendingOfflineDisplayID = oldDisplayID
    }

    private func waitForPendingDisplayOffline() {
        let oldDisplayID = pendingOfflineDisplayID
        guard oldDisplayID != 0 else { return }
        pendingOfflineDisplayID = 0

        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            var count: UInt32 = 0
            let result = CGGetOnlineDisplayList(0, nil, &count)
            if result != .success || count == 0 {
                return
            }
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return }
            if !ids.prefix(Int(count)).contains(oldDisplayID) {
                return
            }
            usleep(50_000)
        }
        RDPLog.display.info("VirtualDisplay: old display id=\(oldDisplayID) stayed online during teardown")
    }

    // MARK: - Power assertions (Settings: prevent system / display sleep)

    public func acquireWakeAssertion() {
        wakeAssertionActive = true
        syncWakeAssertions()
        noteUserActivity()
    }

    public func releaseWakeAssertion() {
        wakeAssertionActive = false
        keepAwakeTask?.cancel()
        keepAwakeTask = nil
        releaseUserActivityAssertion()
        releaseSystemWakeAssertion()
        releaseDisplayWakeAssertion()
        RDPLog.display.info("Display: power assertions released")
    }

    public func reapplyWakeAssertions() {
        if Self.preventSystemSleep || Self.effectivePreventDisplaySleep() {
            wakeAssertionActive = true
            syncWakeAssertions()
            noteUserActivity()
        } else if wakeAssertionActive {
            syncWakeAssertions()
        } else {
            releaseSystemWakeAssertion()
            releaseDisplayWakeAssertion()
            keepAwakeTask?.cancel()
            keepAwakeTask = nil
            releaseUserActivityAssertion()
        }
        RDPLog.display.info(
            "Display: power policy system=\(Self.preventSystemSleep) " +
            "display=\(Self.effectivePreventDisplaySleep()) active=\(wakeAssertionActive) " +
            "sysID=\(systemWakeAssertionID) dispID=\(displayWakeAssertionID)"
        )
    }

    private func syncWakeAssertions() {
        guard wakeAssertionActive else { return }
        let keepDisplayAwake = Self.effectivePreventDisplaySleep()

        if Self.preventSystemSleep {
            ensureSystemWakeAssertion()
        } else {
            releaseSystemWakeAssertion()
        }

        if keepDisplayAwake {
            ensureDisplayWakeAssertion()
        } else {
            releaseDisplayWakeAssertion()
        }

        if Self.preventSystemSleep || keepDisplayAwake {
            startKeepAwakeTickle()
        } else {
            keepAwakeTask?.cancel()
            keepAwakeTask = nil
            releaseUserActivityAssertion()
            wakeAssertionActive = false
            RDPLog.display.info("Display: power assertions released (policy off)")
        }
    }

    private func ensureSystemWakeAssertion() {
        guard systemWakeAssertionID == 0 else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "SwiftRDP prevent system sleep" as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            systemWakeAssertionID = id
            RDPLog.display.info("Display: prevent system sleep on (id=\(id))")
        } else {
            RDPLog.display.info("Display: prevent system sleep failed: \(result)")
        }
    }

    private func ensureDisplayWakeAssertion() {
        guard displayWakeAssertionID == 0 else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "SwiftRDP prevent display sleep" as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            displayWakeAssertionID = id
            RDPLog.display.info("Display: prevent display sleep on (id=\(id))")
        } else {
            RDPLog.display.info("Display: prevent display sleep failed: \(result)")
        }
    }

    private func releaseSystemWakeAssertion() {
        guard systemWakeAssertionID != 0 else { return }
        IOPMAssertionRelease(systemWakeAssertionID)
        systemWakeAssertionID = 0
    }

    private func releaseDisplayWakeAssertion() {
        guard displayWakeAssertionID != 0 else { return }
        IOPMAssertionRelease(displayWakeAssertionID)
        displayWakeAssertionID = 0
    }

    private func releaseUserActivityAssertion() {
        guard userActivityAssertionID != 0 else { return }
        IOPMAssertionRelease(userActivityAssertionID)
        userActivityAssertionID = 0
    }

    public func noteUserActivity() {
        guard wakeAssertionActive,
              Self.preventSystemSleep || Self.effectivePreventDisplaySleep() else { return }
        if DisplayTopology.hasAwakeBuiltInDisplay() {
            DisplayWake.wakeIfNeeded()
        }
        var id: IOPMAssertionID = 0
        let kind = Self.effectivePreventDisplaySleep() ? kIOPMUserActiveLocal : kIOPMUserActiveRemote
        let result = IOPMAssertionDeclareUserActivity(
            "SwiftRDP remote session" as CFString,
            kind,
            &id
        )
        guard result == kIOReturnSuccess else { return }
        releaseUserActivityAssertion()
        userActivityAssertionID = id
    }

    private func startKeepAwakeTickle() {
        keepAwakeTask?.cancel()
        keepAwakeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                self?.noteUserActivity()
            }
        }
    }

    // MARK: - Private CGVirtualDisplay bridging (runtime lookup only)

    private func runWindowServer<Value>(
        timeout: DispatchTimeInterval = .seconds(10),
        operation: @escaping @Sendable () -> Value
    ) -> Value? {
        let result = WindowServerResult<Value>()
        let semaphore = DispatchSemaphore(value: 0)
        windowServerQueue.async {
            let value = operation()
            result.lock.lock()
            result.value = value
            result.lock.unlock()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            RDPLog.display.error("VirtualDisplay: WindowServer operation timed out")
            return nil
        }
        result.lock.lock()
        let value = result.value
        result.lock.unlock()
        return value
    }

    private func createVirtualDisplay(pixelWidth: Int, pixelHeight: Int) -> Bool {
        guard pixelWidth > 0, pixelHeight > 0 else { return false }

        guard
            let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor"),
            let settingsClass = NSClassFromString("CGVirtualDisplaySettings"),
            let modeClass = NSClassFromString("CGVirtualDisplayMode"),
            let displayClass = NSClassFromString("CGVirtualDisplay")
        else {
            RDPLog.display.info("VirtualDisplay: private class unavailable")
            return false
        }

        guard let result = (runWindowServer { () -> CreatedDisplay? in
            var result: CreatedDisplay?
            let exceptionReason = MHRDPCatchObjCException {
                result = Self.createVirtualDisplayUnsafe(
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                    preferHiDPI: self.preferHiDPI,
                    logicalWidth: self.logicalWidth,
                    logicalHeight: self.logicalHeight,
                    descriptorClass: descriptorClass,
                    settingsClass: settingsClass,
                    modeClass: modeClass,
                    displayClass: displayClass
                )
            }
            if let exceptionReason {
                RDPLog.display.info("VirtualDisplay: create failed (ok=false) — \(exceptionReason)")
            }
            return result
        }) else { return false }
        guard let created = result else { return false }
        virtualDisplayObject = created.object
        displayID = created.id
        return true
    }

    private func updateExistingModes(pixelWidth: Int, pixelHeight: Int) -> Bool {
        guard pixelWidth > 0, pixelHeight > 0, let display = virtualDisplayObject else { return false }
        let displayBox = ObjectiveCObject(display)
        guard
            let settingsClass = NSClassFromString("CGVirtualDisplaySettings"),
            let modeClass = NSClassFromString("CGVirtualDisplayMode")
        else { return false }

        let result = runWindowServer { () -> ApplySettingsResult in
            var ok = false
            let reason = MHRDPCatchObjCException {
                guard let settings = ObjCRuntimeBridge.allocInit(settingsClass) else { return }
                settings.setValue(Self.makeVirtualDisplayModes(
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                    modeClass: modeClass
                ), forKey: "modes")
                settings.setValue(true, forKey: "hiDPI")
                ok = ObjCRuntimeBridge.applySettings(displayBox.value, settings: settings)
            }
            if let reason { return .exception(reason) }
            return ok ? .success : .failure
        }
        guard let result else { return false }
        if case let .exception(reason) = result {
            RDPLog.display.info("VirtualDisplay: terminated by system — state reset (id=\(displayID)) reason=\(reason)")
            tearDownVirtualDisplay()
            active = false
            return false
        }
        if case .success = result { return true }
        return false
    }

    private static func makeVirtualDisplayModes(
        pixelWidth: Int,
        pixelHeight: Int,
        modeClass: AnyClass
    ) -> [NSObject] {
        var modes: [NSObject] = []
        var seen = Set<String>()
        let refreshRate = 60.0
        func appendMode(_ w: Int, _ h: Int) {
            guard w >= 2, h >= 2,
                  w <= VirtualDisplayParameters.maxPixelWidth,
                  h <= VirtualDisplayParameters.maxPixelHeight,
                  seen.insert("\(w)x\(h)").inserted else { return }
            guard
                let allocatedMode = ObjCRuntimeBridge.allocUnmanaged(modeClass),
                let mode = ObjCRuntimeBridge.initMode(
                    allocatedMode,
                    width: UInt32(w),
                    height: UInt32(h),
                    refreshRate: refreshRate
                )
            else { return }
            modes.append(mode)
        }
        appendMode(pixelWidth, pixelHeight)
        for (width, height) in DisplayTopology.virtualPresets {
            appendMode(width, height)
            appendMode(width * 2, height * 2)
        }
        return modes
    }

    private static func createVirtualDisplayUnsafe(
        pixelWidth: Int,
        pixelHeight: Int,
        preferHiDPI: Bool,
        logicalWidth: Int,
        logicalHeight: Int,
        descriptorClass: AnyClass,
        settingsClass: AnyClass,
        modeClass: AnyClass,
        displayClass: AnyClass
    ) -> CreatedDisplay? {
        guard let descriptor = ObjCRuntimeBridge.allocInit(descriptorClass) else {
            RDPLog.display.info("VirtualDisplay: private class unavailable")
            return nil
        }

        let ppi = 110.0
        let mm = CGSize(
            width: 25.4 * Double(VirtualDisplayParameters.maxPixelWidth) / ppi,
            height: 25.4 * Double(VirtualDisplayParameters.maxPixelHeight) / ppi
        )
        descriptor.setValue(VirtualDisplayIdentity.displayName as NSString, forKey: "name")
        descriptor.setValue(NSValue(size: NSSize(width: mm.width, height: mm.height)), forKey: "sizeInMillimeters")
        descriptor.setValue(NSNumber(value: UInt32(VirtualDisplayParameters.maxPixelWidth)), forKey: "maxPixelsWide")
        descriptor.setValue(NSNumber(value: UInt32(VirtualDisplayParameters.maxPixelHeight)), forKey: "maxPixelsHigh")
        descriptor.setValue(NSNumber(value: VirtualDisplayIdentity.vendorID), forKey: "vendorID")
        descriptor.setValue(NSNumber(value: VirtualDisplayIdentity.productID), forKey: "productID")
        descriptor.setValue(NSNumber(value: VirtualDisplayIdentity.serialNumber), forKey: "serialNumber")
        descriptor.setValue(NSValue(point: NSPoint(x: 0.6797, y: 0.3203)), forKey: "redPrimary")
        descriptor.setValue(NSValue(point: NSPoint(x: 0.2559, y: 0.6983)), forKey: "greenPrimary")
        descriptor.setValue(NSValue(point: NSPoint(x: 0.1494, y: 0.0557)), forKey: "bluePrimary")
        descriptor.setValue(NSValue(point: NSPoint(x: 0.3125, y: 0.3291)), forKey: "whitePoint")
        descriptor.setValue(
            DispatchQueue.global(qos: .userInitiated),
            forKey: "queue"
        )

        var ok = false
        defer {
            if !ok { RDPLog.display.info("VirtualDisplay: create failed (ok=\(ok))") }
        }

        guard
            let allocatedDisplay = ObjCRuntimeBridge.allocUnmanaged(displayClass),
            let display = ObjCRuntimeBridge.initWithDescriptor(allocatedDisplay, descriptor: descriptor)
        else { return nil }

        guard let settings = ObjCRuntimeBridge.allocInit(settingsClass) else { return nil }
        settings.setValue(Self.makeVirtualDisplayModes(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            modeClass: modeClass
        ), forKey: "modes")
        settings.setValue(true, forKey: "hiDPI")

        guard ObjCRuntimeBridge.applySettings(display, settings: settings) else { return nil }
        guard let idNumber = display.value(forKey: "displayID") as? NSNumber else { return nil }

        let displayID = idNumber.uint32Value
        ok = displayID != 0
        if ok {
            VirtualDisplayColorProfile.apply(to: displayID)
            let hiDPITag = preferHiDPI ? " HiDPI \(logicalWidth)x\(logicalHeight)" : ""
            RDPLog.display.info(
                "VirtualDisplay: created \(displayID) \(pixelWidth)x\(pixelHeight)\(hiDPITag)"
            )
        }
        return ok ? CreatedDisplay(object: display, id: displayID) : nil
    }

    @discardableResult
    private func applyVirtualDisplayMode() -> Bool {
        let displayID = self.displayID
        guard displayID != 0 else { return false }
        let requestedWidth = self.requestedWidth
        let requestedHeight = self.requestedHeight
        let logicalWidth = self.logicalWidth
        let logicalHeight = self.logicalHeight
        let preferHiDPI = self.preferHiDPI
        let description = self.modeDescription

        return runWindowServer {
            let listOptions = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
            guard let modes = CGDisplayCopyAllDisplayModes(displayID, listOptions) as? [CGDisplayMode] else {
                return false
            }
            let target = modes.first { mode in
                guard mode.isUsableForDesktopGUI() else { return false }
                let pw = mode.pixelWidth > 0 ? mode.pixelWidth : mode.width
                let ph = mode.pixelHeight > 0 ? mode.pixelHeight : mode.height
                if preferHiDPI {
                    return mode.width == logicalWidth
                        && mode.height == logicalHeight
                        && DisplayTopology.isHiDPIMode(mode)
                }
                return pw == requestedWidth
                    && ph == requestedHeight
                    && !DisplayTopology.isHiDPIMode(mode)
            }
            guard let target else {
                RDPLog.display.info(
                    "VirtualDisplay: no usable CG mode on id=\(displayID) " +
                    "(wanted \(description))"
                )
                return false
            }
            let pw = target.pixelWidth > 0 ? target.pixelWidth : target.width
            let ph = target.pixelHeight > 0 ? target.pixelHeight : target.height
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
            let err = CGConfigureDisplayWithDisplayMode(config, displayID, target, nil)
            guard err == .success else {
                CGCancelDisplayConfiguration(config)
                RDPLog.display.info(
                    "VirtualDisplay: CGConfigureDisplayWithDisplayMode \(description) " +
                    "failed err=\(err.rawValue)"
                )
                return false
            }
            let complete = CGCompleteDisplayConfiguration(config, .forSession)
            guard complete == .success else {
                RDPLog.display.info(
                    "VirtualDisplay: CGCompleteDisplayConfiguration \(description) " +
                    "failed err=\(complete.rawValue)"
                )
                return false
            }
            RDPLog.display.info(
                "VirtualDisplay: CG mode → \(description) pixels \(pw)x\(ph) id=\(displayID)"
            )
            return true
        } ?? false
    }

    private var modeDescription: String {
        if preferHiDPI {
            return "\(logicalWidth)x\(logicalHeight) HiDPI"
        }
        return "\(requestedWidth)x\(requestedHeight)"
    }

    static func modeMatchesRequest(
        modeWidth: Int,
        modeHeight: Int,
        modePixelWidth: Int,
        modePixelHeight: Int,
        modeIsHiDPI: Bool,
        requestedPixelWidth: Int,
        requestedPixelHeight: Int,
        requestedLogicalWidth: Int,
        requestedLogicalHeight: Int,
        preferHiDPI: Bool
    ) -> Bool {
        modePixelWidth == requestedPixelWidth
            && modePixelHeight == requestedPixelHeight
            && modeWidth == requestedLogicalWidth
            && modeHeight == requestedLogicalHeight
            && modeIsHiDPI == preferHiDPI
    }

    private func currentModeMatchesRequest() -> Bool {
        let displayID = self.displayID
        let requestedWidth = self.requestedWidth
        let requestedHeight = self.requestedHeight
        let logicalWidth = self.logicalWidth
        let logicalHeight = self.logicalHeight
        let preferHiDPI = self.preferHiDPI
        guard displayID != 0 else { return false }
        return runWindowServer {
            guard let mode = CGDisplayCopyDisplayMode(displayID) else { return false }
            let pixelWidth = mode.pixelWidth > 0 ? mode.pixelWidth : mode.width
            let pixelHeight = mode.pixelHeight > 0 ? mode.pixelHeight : mode.height
            return Self.modeMatchesRequest(
                modeWidth: mode.width,
                modeHeight: mode.height,
                modePixelWidth: pixelWidth,
                modePixelHeight: pixelHeight,
                modeIsHiDPI: DisplayTopology.isHiDPIMode(mode),
                requestedPixelWidth: requestedWidth,
                requestedPixelHeight: requestedHeight,
                requestedLogicalWidth: logicalWidth,
                requestedLogicalHeight: logicalHeight,
                preferHiDPI: preferHiDPI
            )
        } ?? false
    }

    private func isRequestedModeMismatch() -> Bool {
        guard requestedWidth > 0, requestedHeight > 0, displayID != 0 else { return false }
        return !currentModeMatchesRequest()
    }

    @discardableResult
    public func restoreRequestedMode(context: String) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return restoreRequestedModeIfNeeded(context: context)
    }

    @discardableResult
    private func restoreRequestedModeIfNeeded(context: String) -> Bool {
        guard requestedWidth > 0, requestedHeight > 0, displayID != 0 else { return false }
        guard isRequestedModeMismatch() else {
            verifyRequestedMode(context: context)
            return false
        }
        let actual = pixelSize(of: displayID)
        RDPLog.display.info(
            "VirtualDisplay: restore after \(context) — " +
            "actual \(actual.width)x\(actual.height) wanted \(requestedWidth)x\(requestedHeight)"
        )
        for attempt in 1...4 {
            if !applyVirtualDisplayMode() {
                _ = updateExistingModes(pixelWidth: requestedWidth, pixelHeight: requestedHeight)
            }
            usleep(150_000)
            if currentModeMatchesRequest() {
                RDPLog.display.info(
                    "VirtualDisplay: mode ok \(self.modeDescription) " +
                    "pixels \(self.requestedWidth)x\(self.requestedHeight) " +
                    "(restored attempt \(attempt))"
                )
                return true
            }
        }
        verifyRequestedMode(context: "\(context) restore-incomplete")
        return false
    }

    private func verifyRequestedMode(context: String) {
        guard requestedWidth > 0, requestedHeight > 0, displayID != 0 else { return }
        let actual = pixelSize(of: displayID)
        if currentModeMatchesRequest() {
            RDPLog.display.info(
                "VirtualDisplay: mode ok \(self.modeDescription) " +
                "pixels \(actual.width)x\(actual.height) (\(context))"
            )
        } else {
            RDPLog.display.info(
                "VirtualDisplay: mode mismatch after \(context) — " +
                "actual pixels \(actual.width)x\(actual.height) wanted \(self.modeDescription) " +
                "pixels \(self.requestedWidth)x\(self.requestedHeight)"
            )
        }
    }

    private func pixelSize(of displayID: CGDirectDisplayID) -> (width: Int, height: Int) {
        runWindowServer { Self.readPixelSize(of: displayID) } ?? (0, 0)
    }

    private static func readPixelSize(of displayID: CGDirectDisplayID) -> (width: Int, height: Int) {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return (0, 0) }
        let w = mode.pixelWidth > 0 ? mode.pixelWidth : mode.width
        let h = mode.pixelHeight > 0 ? mode.pixelHeight : mode.height
        return (w, h)
    }

    public static func physicalDisplayPixelSize(
        preferredIdentity: String = ""
    ) -> (width: Int, height: Int) {
        guard let displayID = DisplayTopology.physicalDisplayID(preferredIdentity: preferredIdentity) else {
            return (0, 0)
        }
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return (0, 0) }
        let pw = mode.pixelWidth
        let ph = mode.pixelHeight
        if pw > 0, ph > 0 {
            return (pw, ph)
        }
        return (mode.width, mode.height)
    }
}

/// Minimal Objective-C runtime trampoline for private `CGVirtualDisplay*` selectors.
enum ObjCRuntimeBridge {
    static func allocUnmanaged(_ cls: AnyClass) -> Unmanaged<AnyObject>? {
        let sel = NSSelectorFromString("alloc")
        guard let metaClass = object_getClass(cls),
              let method = class_getInstanceMethod(metaClass, sel)
        else { return nil }
        typealias Fn = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(method_getImplementation(method), to: Fn.self)(cls, sel)
    }

    static func allocInit(_ cls: AnyClass) -> NSObject? {
        guard let allocated = allocUnmanaged(cls) else { return nil }
        let target = allocated.takeUnretainedValue()
        let sel = NSSelectorFromString("init")
        guard let method = class_getInstanceMethod(object_getClass(target), sel) else {
            return allocated.takeRetainedValue() as? NSObject
        }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        return fn(target, sel)?.takeRetainedValue() as? NSObject
    }

    static func initWithDescriptor(_ allocated: Unmanaged<AnyObject>, descriptor: NSObject) -> NSObject? {
        let target = allocated.takeUnretainedValue()
        let sel = NSSelectorFromString("initWithDescriptor:")
        guard let cls = object_getClass(target), let method = class_getInstanceMethod(cls, sel) else {
            _ = allocated.takeRetainedValue()
            return nil
        }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?
        let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        return fn(target, sel, descriptor)?.takeRetainedValue() as? NSObject
    }

    static func initMode(
        _ allocated: Unmanaged<AnyObject>,
        width: UInt32,
        height: UInt32,
        refreshRate: Double
    ) -> NSObject? {
        let target = allocated.takeUnretainedValue()
        let sel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard let cls = object_getClass(target), let method = class_getInstanceMethod(cls, sel) else {
            _ = allocated.takeRetainedValue()
            return nil
        }
        typealias Fn = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>?
        let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        return fn(target, sel, width, height, refreshRate)?.takeRetainedValue() as? NSObject
    }

    static func applySettings(_ target: NSObject, settings: NSObject) -> Bool {
        let sel = NSSelectorFromString("applySettings:")
        guard let cls = object_getClass(target), let method = class_getInstanceMethod(cls, sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        return fn(target, sel, settings)
    }
}
