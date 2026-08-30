import Foundation
@preconcurrency import ScreenCaptureKit
import CoreGraphics
import CoreVideo
import CoreMedia
import AudioToolbox
import AppKit

/// ScreenCaptureKit capture with generation-scoped stream ownership.
public final class ScreenCapturer: NSObject, @unchecked Sendable {
    private struct CaptureConfiguration {
        let width: Int
        let height: Int
        let fps: Int
        let selectedDisplayID: UInt32?
        let capturesAudio: Bool
    }

    private struct RunTicket {
        let generation: UInt64
        let drain: Task<Void, Never>
        let configuration: CaptureConfiguration
    }

    private struct StreamList: @unchecked Sendable {
        let values: [SCStream]
    }

    private let lock = NSLock()
    private let captureQueue = DispatchQueue(label: "com.macrdp.capture", qos: .userInitiated)
    private var lifecycleGeneration: UInt64 = 0
    private var wantsCapture = false
    private var activeStream: SCStream?
    private var activeStreamGeneration: UInt64 = 0
    private var pendingStream: SCStream?
    private var pendingStreamGeneration: UInt64 = 0
    private var operationTask: Task<Void, Error>?
    private var drainTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var configurationUpdateTask: Task<Void, Never>?
    private var configurationUpdateGeneration: UInt64 = 0
    private let displayLifecycle = DisplayCaptureLifecycle()
    private var firstSampleGeneration: UInt64?
    private var streamStartedAtNanoseconds: UInt64 = 0
    private var targetWidth: Int
    private var targetHeight: Int
    private var captureFPS = 30
    private var selectedDisplayIDValue: UInt32?
    private var activeDisplayIDValue: CGDirectDisplayID = 0
    private var preferPixelBufferOnlyValue = false
    private var capturesAudioValue = false
    /// Pixel format of the live SCStream (NV12 preferred, BGRA fallback).
    private var activePixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    public var onFatalError: ((Error) -> Void)?
    public var onAudioPCM: (([Int16], Int, Int) -> Void)?
    /// Fired when the resolved capture display id changes (wake / resize / restart).
    public var onCaptureDisplayChanged: (() -> Void)?
    public let frameHub: FrameHub

    private var lastDisplayWakeRestartNs: UInt64 = 0
    /// Minimum interval between SCK restarts triggered by built-in panel sleep/wake.
    private static let displayWakeRestartMinIntervalNs: UInt64 = 8_000_000_000
    /// Do not let one pixel format consume the RDP client's startup budget when
    /// ScreenCaptureKit accepts the stream but never delivers a sample.
    private static let firstSampleTimeoutNs: UInt64 = 1_000_000_000
    private static let firstSamplePollNs: UInt64 = 25_000_000

    public init(width: Int = 0, height: Int = 0, frameHub: FrameHub = FrameHub()) {
        targetWidth = width
        targetHeight = height
        self.frameHub = frameHub
    }

    public var selectedDisplayID: UInt32? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return selectedDisplayIDValue
        }
        set {
            lock.lock()
            selectedDisplayIDValue = newValue
            let syncWake = wantsCapture
            lock.unlock()
            if syncWake {
                DisplayWake.setKeepBuiltInPanelAwake(capturesAwakePhysicalPanel)
            }
        }
    }

    public var activeDisplayID: CGDirectDisplayID {
        lock.lock()
        defer { lock.unlock() }
        return activeDisplayIDValue
    }

    public var preferPixelBufferOnly: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return preferPixelBufferOnlyValue
        }
        set {
            lock.lock()
            preferPixelBufferOnlyValue = newValue
            lock.unlock()
        }
    }

    public var capturesAudio: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return capturesAudioValue
        }
        set {
            let stream = locked { () -> SCStream? in
                guard capturesAudioValue != newValue else { return nil }
                capturesAudioValue = newValue
                guard wantsCapture else { return nil }
                return activeStream
            }
            guard let stream else { return }
            RDPLog.capture.info("ScreenCapturer: capturesAudio=\(newValue)")
            scheduleLiveConfigurationUpdate(stream: stream, reason: "audio")
        }
    }

    public var size: (Int, Int) {
        lock.lock()
        defer { lock.unlock() }
        return (targetWidth, targetHeight)
    }

    /// True while an authorized capture run is active (including between restarts).
    var isCaptureAuthorized: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wantsCapture
    }

    /// True when capture targets an online awake physical panel (built-in or external).
    /// Virtual displays and asleep built-in panels (clamshell) return false.
    var capturesAwakePhysicalPanel: Bool {
        lock.lock()
        let selected = selectedDisplayIDValue
        let active = activeDisplayIDValue
        lock.unlock()
        return Self.capturesAwakePhysicalPanel(selected: selected, active: active)
    }

    /// Same check for callers that already hold `lock` — `NSLock` is not
    /// recursive, so the public accessor would self-deadlock there.
    private var capturesAwakePhysicalPanelLocked: Bool {
        Self.capturesAwakePhysicalPanel(
            selected: selectedDisplayIDValue,
            active: activeDisplayIDValue
        )
    }

    private static func capturesAwakePhysicalPanel(
        selected: UInt32?,
        active: CGDirectDisplayID
    ) -> Bool {
        let targetID: CGDirectDisplayID
        if let selected, selected != 0 {
            targetID = CGDirectDisplayID(selected)
        } else if active != 0 {
            targetID = active
        } else {
            return DisplayTopology.hasUsablePhysicalDisplay()
        }
        return DisplayTopology.physicalDisplayIDs().contains(targetID)
    }

    /// Retune the live capture cadence in place without restarting the stream.
    public func setCaptureFPS(_ fps: Int) {
        let clamped = max(1, min(fps, 60))
        let stream = locked { () -> SCStream? in
            guard clamped != captureFPS else { return nil }
            captureFPS = clamped
            guard wantsCapture else { return nil }
            return activeStream
        }
        guard let stream else { return }
        RDPLog.capture.debug("ScreenCapturer: captureFPS=\(clamped)")
        scheduleLiveConfigurationUpdate(stream: stream, reason: "fps")
    }

    /// Keep only the newest live retune in flight. ScreenCaptureKit applies
    /// configuration asynchronously, so overlapping updates can otherwise make
    /// an old controller target arrive after a newer one.
    private func scheduleLiveConfigurationUpdate(stream: SCStream, reason: String) {
        let configuration = liveConfiguration()
        lock.lock()
        configurationUpdateGeneration &+= 1
        let generation = configurationUpdateGeneration
        configurationUpdateTask?.cancel()
        let task = Task { [weak self, stream] in
            do {
                try await stream.updateConfiguration(configuration)
            } catch is CancellationError {
                return
            } catch {
                RDPLog.capture.error(
                    "ScreenCapturer: \(reason) update failed: \(error)"
                )
            }
            guard let self else { return }
            self.locked {
                if self.configurationUpdateGeneration == generation {
                    self.configurationUpdateTask = nil
                }
            }
        }
        configurationUpdateTask = task
        lock.unlock()
    }

    /// Stream configuration for the current target geometry / FPS / audio state.
    private func liveConfiguration() -> SCStreamConfiguration {
        let snapshot = locked {
            (
                width: targetWidth,
                height: targetHeight,
                fps: captureFPS,
                audio: capturesAudioValue,
                pixelFormat: activePixelFormat
            )
        }
        return Self.makeStreamConfiguration(
            width: snapshot.width,
            height: snapshot.height,
            fps: snapshot.fps,
            capturesAudio: snapshot.audio,
            pixelFormat: snapshot.pixelFormat
        )
    }

    /// Starts a new explicitly-authorized capture run.
    public func start(width: Int? = nil, height: Int? = nil) async throws {
        try Task.checkCancellation()
        guard beginOperation(authorize: true, width: width, height: height) != nil else {
            throw CancellationError()
        }
        try await awaitCurrentAuthorizedOperation()
    }

    /// Replace the live stream (resize or display rebind).
    public func restart(width: Int, height: Int) async throws {
        try await restartIfRunning(width: width, height: height, reason: "resize")
    }

    func restartIfRunning(
        width: Int? = nil,
        height: Int? = nil,
        reason: String
    ) async throws {
        try Task.checkCancellation()
        let snapshot: (Int, Int)? = locked {
            guard wantsCapture else { return nil }
            return (width ?? targetWidth, height ?? targetHeight)
        }
        guard let (w, h) = snapshot else { throw CancellationError() }
        cancelRecoveryLocked()
        guard let operation = beginOperation(authorize: false, width: w, height: h) else {
            throw CancellationError()
        }
        try await awaitOperation(operation)
        RDPLog.capture.info("ScreenCapturer: restarted capture (\(reason))")
    }

    /// Display woke — proactively restart SCK before it reports display-unavailable.
    /// Ignored for virtual-display / clamshell capture to avoid sleep↔wake flicker loops.
    func noteDisplayWake() {
        guard isCaptureAuthorized else { return }
        guard capturesAwakePhysicalPanel else {
            RDPLog.capture.debug(
                "ScreenCapturer: ignoring display wake (capture target is not an awake physical panel)"
            )
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let last = lastDisplayWakeRestartNs
        if last != 0, now &- last < Self.displayWakeRestartMinIntervalNs {
            lock.unlock()
            RDPLog.capture.debug("ScreenCapturer: ignoring display wake (debounced)")
            return
        }
        lastDisplayWakeRestartNs = now
        lock.unlock()
        DisplayWake.wakeIfNeeded()
        Task { [weak self] in
            do {
                try await self?.restartIfRunning(reason: "display wake")
            } catch is CancellationError {
                return
            } catch {
                RDPLog.capture.error("ScreenCapturer: display wake restart failed: \(error)")
                self?.scheduleRecovery(reason: "display wake", delayNs: 200_000_000)
            }
        }
    }

    /// Invalidates every start/restart token, then waits for all owned streams to stop.
    public func stopAndWait() async {
        displayLifecycle.stop()
        let drain: Task<Void, Never> = locked {
            lifecycleGeneration &+= 1
            wantsCapture = false
            cancelRecoveryLocked()
            configurationUpdateGeneration &+= 1
            configurationUpdateTask?.cancel()
            configurationUpdateTask = nil
            let operation = operationTask
            operation?.cancel()
            operationTask = nil
            let streams = Self.uniqueStreams([activeStream, pendingStream].compactMap { $0 })
            activeStream = nil
            activeStreamGeneration = 0
            pendingStream = nil
            pendingStreamGeneration = 0
            frameHub.clearLatestFrame()
            firstSampleGeneration = nil
            let drain = Self.makeDrain(
                previous: drainTask,
                operation: operation,
                streams: streams
            )
            drainTask = drain
            return drain
        }
        await drain.value
        DisplayWake.endCaptureSession()
    }

    // MARK: - Lifecycle

    private func beginOperation(
        authorize: Bool,
        width: Int?,
        height: Int?
    ) -> Task<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }

        lifecycleGeneration &+= 1
        let beginWakeSession: Bool
        if authorize {
            wantsCapture = true
            displayLifecycle.start(monitoring: self)
            beginWakeSession = true
        } else {
            beginWakeSession = false
        }
        guard wantsCapture else { return nil }
        if let width { targetWidth = width }
        if let height { targetHeight = height }
        let previousOperation = operationTask
        previousOperation?.cancel()
        operationTask = nil

        let streams = Self.uniqueStreams([activeStream, pendingStream].compactMap { $0 })
        activeStream = nil
        activeStreamGeneration = 0
        pendingStream = nil
        pendingStreamGeneration = 0
        frameHub.clearLatestFrame()
        firstSampleGeneration = nil
        let drain = Self.makeDrain(
            previous: drainTask,
            operation: previousOperation,
            streams: streams
        )
        drainTask = drain
        let ticket = RunTicket(
            generation: lifecycleGeneration,
            drain: drain,
            configuration: CaptureConfiguration(
                width: targetWidth,
                height: targetHeight,
                fps: captureFPS,
                selectedDisplayID: selectedDisplayIDValue,
                capturesAudio: capturesAudioValue
            )
        )
        let operation = Task { [weak self] in
            guard let self else { throw CancellationError() }
            do {
                await drain.value
                try Task.checkCancellation()
                try await self.startWithRetries(ticket)
            } catch {
                await self.abortRunIfCurrent(ticket.generation)
                throw error
            }
        }
        operationTask = operation
        // `lock` is still held here (deferred unlock) — use the non-locking variant.
        if beginWakeSession {
            DisplayWake.beginCaptureSession(keepBuiltInPanelAwake: capturesAwakePhysicalPanelLocked)
        } else if wantsCapture {
            DisplayWake.setKeepBuiltInPanelAwake(capturesAwakePhysicalPanelLocked)
        }
        return operation
    }

    private func awaitOperation(_ operation: Task<Void, Error>) async throws {
        try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    /// Await the live authorized capture run, following display-wake restarts that
    /// supersede the initial `start()` operation without abandoning the caller.
    private func awaitCurrentAuthorizedOperation() async throws {
        while true {
            try Task.checkCancellation()
            let operation: Task<Void, Error>? = locked {
                guard wantsCapture else { return nil }
                return operationTask
            }
            guard let operation else { throw CancellationError() }
            do {
                try await awaitOperation(operation)
                return
            } catch is CancellationError {
                let stillAuthorized = locked { wantsCapture }
                guard stillAuthorized else { throw CancellationError() }
                RDPLog.capture.info(
                    "ScreenCapturer: capture run superseded — awaiting replacement"
                )
            }
        }
    }

    private func startWithRetries(_ ticket: RunTicket) async throws {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                try ensureCurrent(ticket.generation)
                try await startStream(ticket)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                RDPLog.capture.error("ScreenCapturer: start attempt \(attempt) failed: \(error)")
                guard attempt < 3 else { break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        throw lastError ?? CaptureError.noDisplay
    }

    private func startStream(_ ticket: RunTicket) async throws {
        RDPLog.capture.info(
            "ScreenCapturer: resolving displays" +
            (ticket.configuration.selectedDisplayID.map { " (want id=\($0))" } ?? "")
        )
        let content = try await shareableContentPreferring(
            displayID: ticket.configuration.selectedDisplayID,
            generation: ticket.generation
        )
        try ensureCurrent(ticket.generation)
        guard let display = resolveDisplay(
            from: content,
            selectedDisplayID: ticket.configuration.selectedDisplayID
        ) else {
            throw CaptureError.noDisplay
        }

        let width = ticket.configuration.width > 0 ? ticket.configuration.width : display.width
        let height = ticket.configuration.height > 0 ? ticket.configuration.height : display.height
        try updateResolvedDisplay(
            displayID: display.displayID,
            width: width,
            height: height,
            generation: ticket.generation
        )

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let pixelFormats = [
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_32BGRA,
        ]
        var started = false
        var lastStartError: Error?
        for pixelFormat in pixelFormats {
            let config = Self.makeStreamConfiguration(
                width: width,
                height: height,
                fps: ticket.configuration.fps,
                capturesAudio: ticket.configuration.capturesAudio,
                pixelFormat: pixelFormat
            )
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
                guard installPending(stream, generation: ticket.generation) else {
                    try? await stream.stopCapture()
                    throw CancellationError()
                }
                try await stream.startCapture()
                guard promotePending(stream, generation: ticket.generation) else {
                    _ = takePending(stream, generation: ticket.generation)
                    try? await stream.stopCapture()
                    throw CancellationError()
                }
                locked { activePixelFormat = pixelFormat }
                if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
                    RDPLog.capture.info("ScreenCapturer: stream pixelFormat=NV12 full-range BT.709")
                } else {
                    RDPLog.capture.info("ScreenCapturer: stream pixelFormat=BGRA (NV12 unavailable)")
                }
                started = true
                do {
                    try await waitForFirstSample(generation: ticket.generation)
                } catch {
                    _ = takeActive(generation: ticket.generation)
                    try? await stream.stopCapture()
                    throw error
                }
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastStartError = error
                _ = takePending(stream, generation: ticket.generation)
                try? await stream.stopCapture()
                RDPLog.capture.info(
                    "ScreenCapturer: pixelFormat 0x\(String(pixelFormat, radix: 16)) " +
                    "start failed (\(error.localizedDescription)); trying fallback"
                )
            }
        }
        guard started else {
            throw lastStartError ?? CaptureError.noDisplay
        }
        try ensureCurrent(ticket.generation)
        RDPLog.capture.info(
            "ScreenCapturer: capturing display id=\(display.displayID) " +
            "\(width)x\(height) @\(ticket.configuration.fps)fps"
        )
    }

    /// `SCShareableContent` can hang indefinitely right after CGVirtualDisplay create/mirror.
    /// Bound the wait and poll until the selected display appears (or fall back).
    private func shareableContentPreferring(
        displayID: UInt32?,
        generation: UInt64
    ) async throws -> SCShareableContent {
        var lastError: Error?
        // ~2s total: VirtualDisplay often takes a beat to show up in SCK.
        for attempt in 1...4 {
            try ensureCurrent(generation)
            do {
                let content = try await fetchShareableContent(timeoutNs: 800_000_000)
                if let displayID,
                   content.displays.contains(where: { $0.displayID == displayID }) {
                    if attempt > 1 {
                        RDPLog.capture.info(
                            "ScreenCapturer: selected display id=\(displayID) ready after attempt \(attempt)"
                        )
                    }
                    return content
                }
                if displayID == nil {
                    return content
                }
                RDPLog.capture.info(
                    "ScreenCapturer: display id=\(displayID!) not in SCK yet " +
                    "(attempt \(attempt), displays=\(content.displays.map(\.displayID)))"
                )
                // Last attempt: return whatever we have so resolveDisplay can fall back.
                if attempt == 4 { return content }
            } catch {
                lastError = error
                RDPLog.capture.error(
                    "ScreenCapturer: SCShareableContent attempt \(attempt) failed: \(error)"
                )
                if attempt == 4 { throw error }
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw lastError ?? CaptureError.shareableContentTimedOut
    }

    private func fetchShareableContent(timeoutNs: UInt64) async throws -> SCShareableContent {
        try await withThrowingTaskGroup(of: SCShareableContent.self) { group in
            group.addTask {
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNs)
                throw CaptureError.shareableContentTimedOut
            }
            guard let content = try await group.next() else {
                throw CaptureError.shareableContentTimedOut
            }
            group.cancelAll()
            return content
        }
    }

    private func waitForFirstSample(generation: UInt64) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + Self.firstSampleTimeoutNs
        while DispatchTime.now().uptimeNanoseconds < deadline {
            try ensureCurrent(generation)
            let received = locked { firstSampleGeneration == generation }
            if received { return }
            try await Task.sleep(nanoseconds: Self.firstSamplePollNs)
        }
        throw CaptureError.firstFrameTimedOut
    }

    private func cancelRecoveryLocked() {
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    private func abortRunIfCurrent(_ generation: UInt64) async {
        let drain: Task<Void, Never>? = locked { () -> Task<Void, Never>? in
            guard lifecycleGeneration == generation else { return nil }
            lifecycleGeneration &+= 1
            wantsCapture = false
            cancelRecoveryLocked()
            displayLifecycle.stop()
            operationTask = nil
            let streams = Self.uniqueStreams([activeStream, pendingStream].compactMap { $0 })
            activeStream = nil
            pendingStream = nil
            frameHub.clearLatestFrame()
            firstSampleGeneration = nil
            let task = Self.makeDrain(previous: drainTask, operation: nil, streams: streams)
            drainTask = task
            return task
        }
        await drain?.value
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func ensureCurrent(_ generation: UInt64) throws {
        try Task.checkCancellation()
        lock.lock()
        let current = wantsCapture && lifecycleGeneration == generation
        lock.unlock()
        if !current { throw CancellationError() }
    }

    private func installPending(_ stream: SCStream, generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard wantsCapture, lifecycleGeneration == generation, pendingStream == nil else { return false }
        pendingStream = stream
        pendingStreamGeneration = generation
        streamStartedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        return true
    }

    private func takePending(_ stream: SCStream, generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pendingStream === stream, pendingStreamGeneration == generation else { return false }
        pendingStream = nil
        pendingStreamGeneration = 0
        return true
    }

    private func promotePending(_ stream: SCStream, generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard wantsCapture, lifecycleGeneration == generation,
              pendingStream === stream, pendingStreamGeneration == generation else { return false }
        pendingStream = nil
        pendingStreamGeneration = 0
        activeStream = stream
        activeStreamGeneration = generation
        return true
    }

    private func takeActive(generation: UInt64) -> SCStream? {
        lock.lock()
        defer { lock.unlock() }
        guard activeStreamGeneration == generation else { return nil }
        let stream = activeStream
        activeStream = nil
        activeStreamGeneration = 0
        return stream
    }

    private func updateResolvedDisplay(
        displayID: CGDirectDisplayID,
        width: Int,
        height: Int,
        generation: UInt64
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard wantsCapture, lifecycleGeneration == generation else { throw CancellationError() }
        targetWidth = width
        targetHeight = height
        let changed = activeDisplayIDValue != displayID
        activeDisplayIDValue = displayID
        selectedDisplayIDValue = UInt32(displayID)
        if changed {
            let handler = onCaptureDisplayChanged
            if handler != nil {
                DispatchQueue.main.async { handler?() }
            }
        }
    }

    private func resolveDisplay(
        from content: SCShareableContent,
        selectedDisplayID: UInt32?
    ) -> SCDisplay? {
        let awakeIDs = Set(DisplayTopology.physicalDisplayIDs().map(\.self))

        if let selectedDisplayID,
           let match = content.displays.first(where: { $0.displayID == selectedDisplayID }) {
            if awakeIDs.isEmpty || awakeIDs.contains(selectedDisplayID) {
                RDPLog.capture.info("ScreenCapturer: using selected display id=\(selectedDisplayID)")
                return match
            }
            RDPLog.capture.info(
                "ScreenCapturer: selected display id=\(selectedDisplayID) unavailable; picking awake display"
            )
        } else if let selectedDisplayID {
            RDPLog.capture.info("ScreenCapturer: display id=\(selectedDisplayID) not found; using first display")
        }

        if !awakeIDs.isEmpty,
           let awake = content.displays.first(where: { awakeIDs.contains($0.displayID) }) {
            RDPLog.capture.info("ScreenCapturer: using awake display id=\(awake.displayID)")
            return awake
        }
        return content.displays.first
    }

    static func isDisplaySleepError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        if message.contains("找不到") {
            return message.contains("显示器") || message.contains("窗口")
        }
        if message.contains("could not find") || message.contains("cannot find") {
            return message.contains("display") || message.contains("window")
        }
        if message.contains("display") && message.contains("sleep") { return true }
        if message.contains("no display") { return true }
        return false
    }

    private func handleStreamStopped(_ stream: SCStream, error: Error) {
        lock.lock()
        guard wantsCapture, activeStream === stream else {
            lock.unlock()
            return
        }
        activeStream = nil
        activeStreamGeneration = 0
        lock.unlock()

        if Self.isDisplaySleepError(error) {
            RDPLog.capture.info(
                "ScreenCapturer: stream stopped (display unavailable): \(error.localizedDescription)"
            )
        } else {
            RDPLog.capture.error("ScreenCapturer: stream stopped: \(error.localizedDescription)")
        }
        if capturesAwakePhysicalPanel {
            DisplayWake.wakeIfNeeded()
        }
        let delayNs: UInt64 = Self.isDisplaySleepError(error) ? 1_500_000_000 : 200_000_000
        scheduleRecovery(reason: "stream stopped", delayNs: delayNs)
    }

    private func scheduleRecovery(reason: String, delayNs: UInt64) {
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNs)
                try await self?.runRecovery(reason: reason)
            } catch is CancellationError {
                return
            } catch {
                RDPLog.capture.error("ScreenCapturer: recovery failed: \(error)")
                self?.onFatalError?(error)
            }
        }
    }

    private func runRecovery(reason: String) async throws {
        if capturesAwakePhysicalPanel {
            DisplayWake.wakeIfNeeded()
        }
        var lastError: Error = CaptureError.noDisplay
        for attempt in 1...6 {
            guard locked({ wantsCapture }) else { return }
            guard locked({ activeStream == nil }) else { return }
            if attempt > 1 {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            locked { recoveryTask = nil }
            do {
                try await restartIfRunning(reason: "\(reason) #\(attempt)")
                RDPLog.capture.info("ScreenCapturer: recovered (\(reason))")
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                RDPLog.capture.info("ScreenCapturer: recovery attempt \(attempt) failed: \(error)")
            }
        }
        throw lastError
    }

    private static func makeDrain(
        previous: Task<Void, Never>?,
        operation: Task<Void, Error>?,
        streams: [SCStream]
    ) -> Task<Void, Never> {
        let streamList = StreamList(values: streams)
        return Task {
            operation?.cancel()
            if let previous { await previous.value }
            if !streamList.values.isEmpty {
                RDPLog.capture.info("ScreenCapturer: stopping \(streamList.values.count) managed stream(s)")
                for stream in streamList.values {
                    do {
                        try await stream.stopCapture()
                    } catch {
                        RDPLog.capture.debug("ScreenCapturer: stopCapture failed: \(error.localizedDescription)")
                    }
                }
            }
            if let operation { _ = await operation.result }
        }
    }

    private static func uniqueStreams(_ streams: [SCStream]) -> [SCStream] {
        var result: [SCStream] = []
        for stream in streams where !result.contains(where: { $0 === stream }) {
            result.append(stream)
        }
        return result
    }

    private static func makeStreamConfiguration(
        width: Int,
        height: Int,
        fps: Int,
        capturesAudio: Bool,
        pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    ) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        // Scale panel → configured size in SCKit (GPU) when sizes differ.
        config.scalesToFit = true
        // MS-RDPEGFX AVC uses full-range BT.709. Keep capture and H.264 VUI aligned.
        config.pixelFormat = pixelFormat
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.colorSpaceName = CGColorSpace.itur_709
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
        // The encode loop always takes the newest sample. Keep a small queue so a
        // slow callback cannot turn burst tolerance into latency.
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = capturesAudio
        if capturesAudio {
            config.sampleRate = 48_000
            config.channelCount = 2
        }
        return config
    }

    public enum CaptureError: Error {
        case noDisplay
        case firstFrameTimedOut
        case shareableContentTimedOut
    }
}

extension ScreenCapturer: SCStreamDelegate, SCStreamOutput {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        handleStreamStopped(stream, error: error)
    }

    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        if type == .audio {
            guard let pcm = Self.extractPCM(from: sampleBuffer) else { return }
            let callback = locked { onAudioPCM }
            callback?(pcm.samples, pcm.sampleRate, pcm.channels)
            return
        }
        guard type == .screen,
              Self.isNewFrame(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let captureUptimeNanoseconds = Self.captureUptimeNanoseconds(from: sampleBuffer)

        lock.lock()
        let generation: UInt64?
        if activeStream === stream {
            generation = activeStreamGeneration
        } else if pendingStream === stream {
            generation = pendingStreamGeneration
        } else {
            generation = nil
        }
        let pixelBufferOnly = preferPixelBufferOnlyValue
        lock.unlock()
        guard let generation else { return }

        let dirtyRects = Self.extractDirtyRects(from: sampleBuffer)
        if pixelBufferOnly {
            let frame = CapturedFrame(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer),
                bgrBottomUp: [],
                dirtyRects: dirtyRects,
                pixelBuffer: pixelBuffer,
                captureUptimeNanoseconds: captureUptimeNanoseconds
            )
            commit(frame: frame, from: stream, generation: generation)
            return
        }

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_32BGRA else {
            // NV12 / other: keep the pixel buffer for GFX; bitmap path needs BGRA.
            let frame = CapturedFrame(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer),
                bgrBottomUp: [],
                dirtyRects: dirtyRects,
                pixelBuffer: pixelBuffer,
                captureUptimeNanoseconds: captureUptimeNanoseconds
            )
            commit(frame: frame, from: stream, generation: generation)
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let source = base.assumingMemoryBound(to: UInt8.self)
        let rowSize = (width * 3 + 3) & ~3
        var bgr = [UInt8](repeating: 0, count: rowSize * height)
        for y in 0..<height {
            let sourceRow = source.advanced(by: y * stride)
            let destinationRow = (height - 1 - y) * rowSize
            for x in 0..<width {
                let sourceIndex = x * 4
                let destinationIndex = destinationRow + x * 3
                bgr[destinationIndex] = sourceRow[sourceIndex]
                bgr[destinationIndex + 1] = sourceRow[sourceIndex + 1]
                bgr[destinationIndex + 2] = sourceRow[sourceIndex + 2]
            }
        }

        commit(
            frame: CapturedFrame(
                width: width,
                height: height,
                bgrBottomUp: bgr,
                dirtyRects: dirtyRects,
                pixelBuffer: pixelBuffer,
                captureUptimeNanoseconds: captureUptimeNanoseconds
            ),
            from: stream,
            generation: generation
        )
    }

    private func commit(frame: CapturedFrame, from stream: SCStream, generation: UInt64) {
        let firstSampleDelayMs: Double?
        lock.lock()
        let isCurrent = wantsCapture && lifecycleGeneration == generation && (
            (activeStream === stream && activeStreamGeneration == generation) ||
            (pendingStream === stream && pendingStreamGeneration == generation)
        )
        guard isCurrent else {
            lock.unlock()
            return
        }
        if firstSampleGeneration != generation {
            firstSampleGeneration = generation
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = now >= streamStartedAtNanoseconds ? now - streamStartedAtNanoseconds : 0
            firstSampleDelayMs = Double(elapsed) / 1_000_000
        } else {
            firstSampleDelayMs = nil
        }
        frameHub.publish(frame, notify: false)
        lock.unlock()

        if let firstSampleDelayMs {
            RDPLog.capture.info(
                String(
                    format: "ScreenCapturer: first sample %dx%d after %.1fms",
                    frame.width,
                    frame.height,
                    firstSampleDelayMs
                )
            )
        }
        frameHub.notifyFrameAvailable()
    }

    private static func captureUptimeNanoseconds(from sampleBuffer: CMSampleBuffer) -> UInt64 {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.seconds.isFinite, pts.seconds >= 0 else {
            return DispatchTime.now().uptimeNanoseconds
        }
        // ScreenCaptureKit timestamps screen samples in the host-time domain.
        // Normalize the scale before comparing them with DispatchTime.
        let hostTime = CMTimeConvertScale(pts, timescale: 1_000_000_000, method: .quickTime)
        guard hostTime.isValid, hostTime.seconds.isFinite, hostTime.seconds >= 0 else {
            return DispatchTime.now().uptimeNanoseconds
        }
        return UInt64(hostTime.seconds * 1_000_000_000)
    }

    /// `nil` when the sample carried no dirty attachment at all — that is not the
    /// same as "nothing changed", and the encoder must not treat it as static.
    private static func extractDirtyRects(from sampleBuffer: CMSampleBuffer) -> [CGRect]? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]] else {
            return nil
        }
        for attachment in attachments {
            if let rects = attachment[.dirtyRects] as? [CGRect] {
                return rects
            }
            if let rects = attachment[.dirtyRects] as? [NSValue] {
                return rects.compactMap { $0.rectValue }
            }
        }
        return nil
    }

    private static func isNewFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]] else {
            // Some VirtualDisplay streams omit status attachments — accept the buffer.
            return true
        }
        guard let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            return true
        }
        // `.idle` explicitly means that no new frame was generated. `.started`
        // is the first usable sample of a stream; other statuses are incomplete.
        switch status {
        case .complete, .started:
            return true
        default:
            return false
        }
    }

    static func extractPCM(
        from sampleBuffer: CMSampleBuffer
    ) -> (samples: [Int16], sampleRate: Int, channels: Int)? {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        else {
            return nil
        }

        var listSize = 0
        var blockBuffer: CMBlockBuffer?
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard sizeStatus == noErr, listSize > 0 else { return nil }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: listSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let audioBufferList = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let channels = Int(format.mChannelsPerFrame)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard channels > 0, frames > 0 else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let bits = Int(format.mBitsPerChannel)
        guard (isFloat && bits == 32) || (isSignedInteger && bits == 16) else {
            RDPLog.capture.debug(
                "ScreenCapturer: unsupported audio format flags=0x" +
                "\(String(format.mFormatFlags, radix: 16)) bits=\(bits)"
            )
            return nil
        }

        var samples = [Int16](repeating: 0, count: frames * channels)
        if nonInterleaved {
            guard buffers.count >= channels else { return nil }
            for channel in 0..<channels {
                guard let data = buffers[channel].mData else { return nil }
                if isFloat {
                    let source = data.assumingMemoryBound(to: Float.self)
                    for frame in 0..<frames {
                        samples[frame * channels + channel] = int16(from: source[frame])
                    }
                } else {
                    let source = data.assumingMemoryBound(to: Int16.self)
                    for frame in 0..<frames {
                        samples[frame * channels + channel] = Int16(littleEndian: source[frame])
                    }
                }
            }
        } else {
            guard let data = buffers.first?.mData else { return nil }
            let count = frames * channels
            if isFloat {
                let source = data.assumingMemoryBound(to: Float.self)
                for index in 0..<count {
                    samples[index] = int16(from: source[index])
                }
            } else {
                let source = data.assumingMemoryBound(to: Int16.self)
                for index in 0..<count {
                    samples[index] = Int16(littleEndian: source[index])
                }
            }
        }
        return (samples, Int(format.mSampleRate.rounded()), channels)
    }

    private static func int16(from value: Float) -> Int16 {
        let clamped = min(max(value, -1), 1)
        if clamped <= -1 { return Int16.min }
        return Int16((clamped * Float(Int16.max)).rounded())
    }
}
