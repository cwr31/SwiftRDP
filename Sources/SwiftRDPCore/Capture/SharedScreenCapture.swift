import CoreGraphics
import CoreVideo
import Foundation

/// One client-sized ScreenCaptureKit stream owned by the current RDP session.
///
/// Native capture fits the selected source into the negotiated desktop before
/// publishing NV12 frames. Codec state, pacing, acknowledgements and transport
/// remain session-local.
public final class SharedScreenCapture: @unchecked Sendable {
    public struct Target: Equatable, Sendable {
        public let displayID: UInt32?
        public let width: Int
        public let height: Int

        public init(displayID: UInt32?, width: Int, height: Int) {
            self.displayID = displayID
            self.width = max(width, 2) & ~1
            self.height = max(height, 2) & ~1
        }
    }

    private struct Observer {
        let owner: UUID
        let onFrameAvailable: () -> Void
        let onAudio: (([Int16], Int, Int) -> Void)?
        let onDisplayChanged: (() -> Void)?
        let onFatalError: ((Error) -> Void)?
    }

    private struct StartOperation {
        let generation: UInt64
        let task: Task<Void, Error>
    }

    private struct StopOperation {
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private let lock = NSLock()
    public let frameHub: FrameHub
    private let capturer: ScreenCapturer
    private var observer: Observer?
    private var requestedFPS = 1
    private var requestedAudio = false
    private var configuredFPS = 0
    private var configuredAudio = false
    private var target: Target?
    private var lifecycleGeneration: UInt64 = 0
    private var startOperation: StartOperation?
    private var stopOperation: StopOperation?

    public init() {
        let frameHub = FrameHub()
        let capturer = ScreenCapturer(frameHub: frameHub)
        self.frameHub = frameHub
        self.capturer = capturer

        frameHub.onFrameAvailable = { [weak self] in
            self?.notifyFrameAvailable()
        }
        capturer.onAudioPCM = { [weak self] samples, rate, channels in
            self?.notifyAudio(samples: samples, rate: rate, channels: channels)
        }
        capturer.onCaptureDisplayChanged = { [weak self] in
            self?.notifyDisplayChanged()
        }
        capturer.onFatalError = { [weak self] error in
            self?.notifyFatalError(error)
        }
    }

    public var selectedDisplayID: UInt32? {
        capturer.selectedDisplayID
    }

    public var activeDisplayID: CGDirectDisplayID {
        capturer.activeDisplayID
    }

    public var size: (Int, Int) {
        capturer.size
    }

    public var contentLayout: DisplayContentLayout? {
        capturer.contentLayout
    }

    public var isRunning: Bool {
        capturer.isCaptureAuthorized
    }

    public func currentFrame() -> CapturedFrame? {
        frameHub.currentFrame()
    }

    public func currentFrameSnapshot() -> FrameHub.Snapshot? {
        frameHub.currentFrameSnapshot()
    }

    @discardableResult
    public func markFrameDelivered(sequence: UInt64, after previousSequence: UInt64) -> UInt64 {
        frameHub.markDelivered(sequence: sequence, after: previousSequence)
    }

    public var captureStatistics: FrameHub.Statistics {
        frameHub.statistics
    }

    public func attach(
        owner: UUID,
        captureFPS: Int,
        capturesAudio: Bool,
        onFrameAvailable: @escaping () -> Void,
        onAudio: (([Int16], Int, Int) -> Void)? = nil,
        onDisplayChanged: (() -> Void)? = nil,
        onFatalError: ((Error) -> Void)? = nil
    ) {
        lock.lock()
        observer = Observer(
            owner: owner,
            onFrameAvailable: onFrameAvailable,
            onAudio: onAudio,
            onDisplayChanged: onDisplayChanged,
            onFatalError: onFatalError
        )
        requestedFPS = Self.clampFPS(captureFPS)
        requestedAudio = capturesAudio
        applyConfigurationLocked()
        lock.unlock()
    }

    public func updateCaptureFPS(owner: UUID, fps: Int) {
        lock.lock()
        guard observer?.owner == owner else {
            lock.unlock()
            return
        }
        requestedFPS = Self.clampFPS(fps)
        applyConfigurationLocked()
        lock.unlock()
    }

    public func updateAudio(owner: UUID, enabled: Bool) {
        lock.lock()
        guard observer?.owner == owner else {
            lock.unlock()
            return
        }
        requestedAudio = enabled
        applyConfigurationLocked()
        lock.unlock()
    }

    public func detach(owner: UUID) {
        lock.lock()
        guard observer?.owner == owner else {
            lock.unlock()
            return
        }
        observer = nil
        applyConfigurationLocked()
        lock.unlock()
    }

    public func start(target: Target) async throws {
        let plan = makeStartPlan(target: target)
        guard let operation = plan.operation, let generation = plan.generation else { return }

        do {
            try await operation.value
            applyCurrentConfiguration()
            clearStartOperation(generation: generation)
        } catch {
            clearStartOperation(generation: generation)
            throw error
        }
    }

    public func restart(target: Target) async throws {
        let shouldStart = locked { () -> Bool in
            self.target = target
            let shouldStart = !capturer.isCaptureAuthorized
            if !shouldStart {
                capturer.selectedDisplayID = target.displayID
            }
            return shouldStart
        }

        if shouldStart {
            try await start(target: target)
        } else {
            try await capturer.restart(width: target.width, height: target.height)
            applyCurrentConfiguration()
        }
    }

    public func stopAndWait() async {
        guard let plan = makeStopPlan(requireIdle: false) else { return }

        await plan.task.value
        clearStopOperation(generation: plan.generation)
    }

    /// Stop only when no session is observing the shared source.
    ///
    /// A delayed idle cleanup can overlap a new connection. Keeping the check
    /// inside the shared-capture lock makes the stop/start handoff serializable.
    public func stopIfIdle() async {
        guard let plan = makeStopPlan(requireIdle: true) else { return }

        await plan.task.value
        clearStopOperation(generation: plan.generation)
    }

    private func makeStartPlan(target: Target) -> (operation: Task<Void, Error>?, generation: UInt64?) {
        locked {
            if let existing = startOperation {
                return (existing.task, existing.generation)
            }
            let previousStop = stopOperation?.task
            if previousStop == nil, capturer.isCaptureAuthorized {
                return (nil, nil)
            }

            self.target = target
            capturer.selectedDisplayID = target.displayID
            lifecycleGeneration &+= 1
            let generation = lifecycleGeneration
            let task = Task {
                await previousStop?.value
                frameHub.resetStatistics()
                try await capturer.start(width: target.width, height: target.height)
            }
            startOperation = StartOperation(generation: generation, task: task)
            return (task, generation)
        }
    }

    private func makeStopPlan(requireIdle: Bool) -> StopOperation? {
        locked {
            if requireIdle, observer != nil {
                return nil
            }
            startOperation?.task.cancel()
            if let existing = stopOperation {
                return existing
            }
            lifecycleGeneration &+= 1
            let generation = lifecycleGeneration
            let task = Task {
                await capturer.stopAndWait()
            }
            let operation = StopOperation(generation: generation, task: task)
            stopOperation = operation
            return operation
        }
    }

    private func clearStartOperation(generation: UInt64) {
        locked {
            if startOperation?.generation == generation {
                startOperation = nil
            }
        }
    }

    private func clearStopOperation(generation: UInt64) {
        locked {
            if stopOperation?.generation == generation {
                stopOperation = nil
            }
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Apply while holding the owner lock so a displaced owner's retune cannot
    /// arrive after the replacement session's configuration.
    private func applyConfigurationLocked() {
        guard observer != nil else {
            configuredFPS = 0
            if configuredAudio {
                configuredAudio = false
                capturer.capturesAudio = false
            }
            return
        }
        if configuredFPS != requestedFPS {
            configuredFPS = requestedFPS
            capturer.setCaptureFPS(requestedFPS)
        }
        if configuredAudio != requestedAudio {
            configuredAudio = requestedAudio
            capturer.capturesAudio = requestedAudio
        }
    }

    private func applyCurrentConfiguration() {
        locked {
            guard observer != nil else { return }
            capturer.setCaptureFPS(requestedFPS)
            capturer.capturesAudio = requestedAudio
        }
    }

    private func notifyFrameAvailable() {
        lock.lock()
        let callback = observer?.onFrameAvailable
        lock.unlock()
        callback?()
    }

    private func notifyAudio(samples: [Int16], rate: Int, channels: Int) {
        lock.lock()
        let callback = observer?.onAudio
        lock.unlock()
        callback?(samples, rate, channels)
    }

    private func notifyDisplayChanged() {
        lock.lock()
        let callback = observer?.onDisplayChanged
        lock.unlock()
        callback?()
    }

    private func notifyFatalError(_ error: Error) {
        lock.lock()
        let callback = observer?.onFatalError
        lock.unlock()
        callback?(error)
    }

    private static func clampFPS(_ fps: Int) -> Int {
        max(1, min(fps, 60))
    }
}
