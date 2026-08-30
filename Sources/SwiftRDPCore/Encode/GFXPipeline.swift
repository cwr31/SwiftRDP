import Foundation
import CoreVideo
import CoreGraphics

/// RDPEGFX pipeline — H.264 or RemoteFX Progressive over the dynamic Graphics channel.
///
/// Wire path:
///   shared SCKit IOSurface (BGRA canonical; NV12 accepted for direct callers)
///     → GPU pixel transfer when AVC420 needs NV12
///     → single-pass Annex-B access unit (NAL 1/5/7/8)
///     → RFX_AVC420 metablock with tile-aligned regions
///     → ZGFX (uncompressed for AVC payloads) → START / WIRE_TO_SURFACE / END
///
/// The access unit always covers the whole surface: regionRects index into the
/// decoded full frame, so a partial bitstream would make the client sample the
/// wrong pixels. P-frames keep untouched areas nearly free.
///
/// RemoteFX Progressive shares the framing and flow control but runs its own
/// software encoder.
public final class GFXPipeline: @unchecked Sendable {
    public enum FrameSubmission: Equatable {
        case submitted
        case blocked
    }

    public let h264 = H264Encoder()
    /// RFX state is connection-local and is consumed only by this serial queue.
    private let rfxEncoder = RemoteFXEncoder()
    private let rfxQueue = DispatchQueue(
        label: "com.swiftrdp.gfx.rfx",
        qos: .userInitiated
    )
    /// GPU pixel format / scale conversions (capture geometry mismatches only).
    let pixelTransfer = PixelBufferTransfer()
    /// mstsc caches EGFX surfaces by id for the lifetime of the process; reusing
    /// surface 0 on reconnect paints into a stale surface (black screen + live cursor).
    private static let surfaceIDLock = NSLock()
    nonisolated(unsafe) private static var nextSurfaceIDValue: UInt16 = 1

    private static func allocateSurfaceID() -> UInt16 {
        surfaceIDLock.lock()
        defer { surfaceIDLock.unlock() }
        let id = nextSurfaceIDValue
        nextSurfaceIDValue &+= 1
        if nextSurfaceIDValue == 0 { nextSurfaceIDValue = 1 }
        return id
    }

    private var surfaceId: UInt16 = 1
    private var width = 0
    private var height = 0
    private var frameId: UInt32 = 0
    private var running = false
    private var surfacesReady = false
    /// Suppress Output — pause GFX send without teardown.
    private var sendPaused = false
    private var forceIDR = false
    /// Only one forced keyframe may be submitted until it is wired or failed.
    private var keyframeInFlight = false
    /// A submitted picture failed or was not wired; discard dependent P frames.
    private var referenceChainBroken = false
    /// TCP channel or user-space outbound queue high-water mark.
    private var sendBlocked = false
    /// Outstanding frame IDs and their send timestamps for real FRAME_ACK RTT.
    private let ackTracker = FrameAckTracker()
    /// False after FRAME_ACK queueDepth=SUSPEND_FRAME_ACKNOWLEDGEMENT (0xFFFFFFFF).
    private var expectsFrameAcknowledgements = true
    private var consecutiveBackpressure = 0
    private var lastAckTime = Date()
    /// The initial IDR stays tracked until the client acknowledges it.
    private var needsBootstrapIDR = false
    /// Tracks the bootstrap IDR until the client acknowledges it.
    private var bootstrapIDRFrameId: UInt32?
    private var pipelineGeneration: UInt64 = 0
    private var recreateScheduled = false
    private var consecutiveEncodeFailures = 0
    /// Fired only when the encoder/pipeline cannot continue and the Graphics DVC
    /// must be recreated. Missing FRAME_ACK is flow control, not pipeline failure.
    public var onPipelineFailure: (() -> Void)?
    /// Fired when the client advertises no capability compatible with the
    /// configured codec. This is terminal for the Graphics channel, not a
    /// transient encoder failure.
    public var onCapabilityFailure: (() -> Void)?
    /// Encoder slots, FRAME_ACK flow control, or TCP send availability changed. The desktop loop
    /// uses this to resume immediately instead of polling.
    public var onWorkAvailable: (() -> Void)?
    /// A complete video frame was rejected by the transport. Rebuild codec state
    /// before the next capture so the client never depends on a dropped frame.
    public var onVideoFrameDropped: (() -> Void)?
    /// Before the first ACK there is no path estimate. Start conservatively and
    /// let the controller open the window from measured BDP feedback.
    private static let initialFrameAcknowledgementWindow = 2
    /// Controller audio shares the reliable RDP transport with Graphics. Keep
    /// only two video frames in flight while the audio channel is actually
    /// backlogged.
    private static let audioLowLatencyFrameAcknowledgementWindow = 2
    private var frameAcknowledgementWindow = initialFrameAcknowledgementWindow
    /// Client-advertised maximum. A missing hint means the protocol placed no
    /// explicit ceiling; the controller still returns a bounded BDP-derived value.
    private var clientFrameAcknowledgementLimit = Int.max
    private var audioLowLatencyMode = false
    /// ACK watchdog interval. A stalled client is held at its negotiated frame
    /// window; codec changes require a new capability negotiation.
    var frameAcknowledgementTimeout: TimeInterval = 2.0
    /// Non-drop encoder failures are fatal only after a sustained sequence.
    private static let maxEncodeFailures = 12
    /// A dropped picture is encoder backpressure, not a reference-chain failure.
    /// Retry at the next frame boundary without creating a keyframe burst.
    private static let h264DropRetryDelayMaximum: TimeInterval = 0.25
    private var lastH264WireAt = Date.distantPast
    private var h264DropResumeNotBefore = Date.distantPast
    private var audioQueuePressure = false
    /// True when a GFX frame was wired recently (AutoDetect deferral).
    public private(set) var desktopRecentlyHot = false
    private var desktopHotClearTask: Task<Void, Never>?

    /// True when the single encode/send reservation is occupied.
    public var isEncodeInFlight: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return rfxEncodeInFlight || encodesInFlight >= maxEncodesInFlight
    }

    /// True when the FRAME_ACK window is saturated — capture should poll tightly
    /// instead of sleeping a full frame period.
    public var isAckWindowFull: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard expectsFrameAcknowledgements else { return false }
        return ackTracker.count >= frameAcknowledgementWindow
    }

    var currentFrameAcknowledgementWindow: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return frameAcknowledgementWindow
    }

    /// Requested codec before CAPS negotiation.
    public var preferredCodec: GraphicsCodec = .h264AVC420
    /// Codec selected by the client's advertised capability set.
    public private(set) var activeCodec: GraphicsCodec = .h264AVC420
    public var asyncEncoding = true
    public var targetFPS = 30
    /// `VideoBitrate` (bps) — forwarded to VideoToolbox AverageBitRate.
    public var targetBitrate = 12_500_000
    /// Shared adaptive controller (`VideoTargetController` / GFXPipeline fields).
    public var controller: VideoTargetController?
    /// `selectedCapVersion` / `selectedCapFlags` (from client CAPS_ADVERTISE).
    public private(set) var selectedCapVersion: UInt32 = 0
    public private(set) var selectedCapFlags: UInt32 = 0
    /// Logical surface / wire size (visible desktop).
    /// The surface always matches the negotiated desktop; capture is transferred
    /// to this size before encoding when the host source has a different geometry.
    public var surfaceEncodeSize: (width: Int, height: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (max(width, 1), max(height, 1))
    }
    /// byte+42 — true after first successful surface graph.
    private var graphicsInitialized = false
    private static let capVersion8: UInt32 = 0x0008_0004
    private static let capVersion81: UInt32 = 0x0008_0105
    private static let capVersion10: UInt32 = 0x000A_0002
    private static let capVersion101: UInt32 = 0x000A_0100
    private static let capVersion102: UInt32 = 0x000A_0200
    private static let capVersion103: UInt32 = 0x000A_0301
    private static let capVersion104: UInt32 = 0x000A_0400
    private static let capVersion105: UInt32 = 0x000A_0502
    private static let capVersion106: UInt32 = 0x000A_0600
    private static let capVersion107: UInt32 = 0x000A_0701
    /// MS-RDPEGFX capability flags. The server only confirms sets whose
    /// advertised semantics are implemented by this pipeline.
    private static let capsFlagThinClient: UInt32 = 0x0000_0001
    private static let capsFlagSmallCache: UInt32 = 0x0000_0002
    private static let capsFlagAvc420Enabled: UInt32 = 0x0000_0010
    /// RDPGFX_CAPS_FLAG_AVC_DISABLED — H.264/AVC must not be used on WIRE_TO_SURFACE.
    private static let capsFlagAvcDisabled: UInt32 = 0x0000_0020
    private static let capsFlagAvcThinClient: UInt32 = 0x0000_0040
    /// RDPGFX_CAPS_FLAG_SCALEDMAP_DISABLE — client rejects MAP_SURFACE_TO_SCALED_*.
    private static let capsFlagScaledMapDisable: UInt32 = 0x0000_0080
    private let stateLock = NSRecursiveLock()
    private var encodesInFlight = 0
    /// RFX has one bounded worker operation; newer capture samples are coalesced
    /// by RDPSession while this reservation is active.
    private var rfxEncodeInFlight = false
    /// A single reservation keeps VideoToolbox's reference chain ordered with
    /// the transport queue. New capture samples replace old ones before encode.
    private let maxEncodesInFlight = 1
    private var transport: (any GraphicsTransport)?

    /// Effective encode FPS after backpressure / RDM adaptation.
    public var effectiveFPS: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return constrainedFPSLocked(controller?.targetFPS ?? targetFPS)
    }

    private func constrainedFPSLocked(_ requestedFPS: Int) -> Int {
        let encodeW = max(width, 1)
        let encodeH = max(height, 1)
        return H264Encoder.constrainedFrameRate(
            requestedFPS,
            width: encodeW,
            height: encodeH
        )
    }

    /// Effective bitrate after queue-driven adaptation.
    public var effectiveBitrate: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return controller?.targetBitrate ?? targetBitrate
    }

    public init() {}

    /// Apply the client's TS_FRAME_ACKNOWLEDGE_CAPABILITYSET from Confirm Active.
    public func configureFrameAcknowledgement(maxUnacknowledgedFrameCount: UInt32?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let limit: Int
        if let count = maxUnacknowledgedFrameCount, count > 0 {
            limit = Int(count)
        } else {
            limit = Int.max
        }
        clientFrameAcknowledgementLimit = max(limit, 1)
        applyFrameAckWindowForCodecLocked(advertised: maxUnacknowledgedFrameCount)
    }

    /// Bound Graphics latency while live audio is sent to the RDP controller.
    /// Audio and Graphics still use the same RDP transport, so limiting complete
    /// in-flight Graphics frames is the protocol-safe way to reduce head-of-line
    /// blocking without interleaving bytes from different RDP PDUs.
    public func setAudioLowLatencyMode(_ enabled: Bool) {
        stateLock.lock()
        guard audioLowLatencyMode != enabled else {
            stateLock.unlock()
            return
        }
        audioLowLatencyMode = enabled
        applyFrameAckWindowForCodecLocked()
        let window = frameAcknowledgementWindow
        stateLock.unlock()
        onWorkAvailable?()

        RDPLog.gfx.info(
            "GFX: audio low-latency mode \(enabled ? "enabled" : "disabled") " +
            "window=\(window)"
        )
    }

    /// Audio playback reports actual queued PCM pressure. Keep the video window
    /// tight only for that interval; an enabled but healthy audio channel should
    /// not permanently impose the two-frame latency cap on H.264.
    public func setAudioQueuePressure(_ pressured: Bool) {
        stateLock.lock()
        guard audioQueuePressure != pressured else {
            stateLock.unlock()
            return
        }
        audioQueuePressure = pressured
        if audioLowLatencyMode {
            applyFrameAckWindowForCodecLocked()
        }
        let window = frameAcknowledgementWindow
        stateLock.unlock()
        onWorkAvailable?()

        RDPLog.gfx.info(
            "GFX: audio queue pressure \(pressured ? "active" : "cleared") " +
            "window=\(window)"
        )
    }

    private func effectiveFrameAcknowledgementCeilingLocked() -> Int {
        clientFrameAcknowledgementLimit
    }

    /// Recompute in-flight window after CAPS picks H.264 vs RFX.
    private func applyFrameAckWindowForCodecLocked(advertised: UInt32? = nil) {
        let previousWindow = frameAcknowledgementWindow
        let effectiveCeiling = effectiveFrameAcknowledgementCeilingLocked()
        let audioCapped = audioLowLatencyMode && audioQueuePressure
        let measuredWindow = controller?.recommendedFrameAcknowledgementWindow(
            clientCeiling: effectiveCeiling
        ) ?? min(Self.initialFrameAcknowledgementWindow, effectiveCeiling)
        frameAcknowledgementWindow = audioCapped
            ? min(Self.audioLowLatencyFrameAcknowledgementWindow, measuredWindow)
            : max(1, min(measuredWindow, effectiveCeiling))
        let adv = advertised.map(String.init) ?? "retained"
        guard frameAcknowledgementWindow != previousWindow || advertised != nil else { return }
        RDPLog.gfx.info(
            "GFX: client FrameAcknowledge maxUnacknowledged=\(adv) " +
            "effectiveWindow=\(frameAcknowledgementWindow) " +
            "ceiling=\(clientFrameAcknowledgementLimit)" +
            (audioCapped ? " (audio queue pressure)" : "")
        )
    }

    public func attachController(_ controller: VideoTargetController) {
        stateLock.lock()
        defer { stateLock.unlock() }
        self.controller = controller
        targetFPS = controller.targetFPS
        targetBitrate = controller.targetBitrate
        applyFrameAckWindowForCodecLocked()
    }

    /// Attach the negotiated Graphics transport.
    public func attach(transport: any GraphicsTransport) {
        stateLock.lock()
        self.transport = transport
        activeCodec = preferredCodec
        pipelineGeneration &+= 1
        recreateScheduled = false
        running = false
        surfacesReady = false
        graphicsInitialized = false
        sendPaused = false
        encodesInFlight = 0
        rfxEncodeInFlight = false
        needsBootstrapIDR = false
        bootstrapIDRFrameId = nil
        keyframeInFlight = false
        referenceChainBroken = false
        h264DropResumeNotBefore = .distantPast
        sendBlocked = false
        expectsFrameAcknowledgements = true
        consecutiveBackpressure = 0
        consecutiveEncodeFailures = 0
        frameId = 0
        resetUnacked()
        stateLock.unlock()
        queueRFXReset()
        transport.reset()
        h264.stop()
        RDPLog.gfx.info("GFX: pipeline attached")
    }

    /// Reset codec references in queue order. A generation change makes any
    /// already-running work stale before this reset reaches the encoder.
    private func queueRFXReset() {
        let encoder = rfxEncoder
        rfxQueue.async { encoder.reset() }
    }

    /// Send related Graphics PDUs after releasing `stateLock`.
    @discardableResult
    private func emitGraphics(
        _ pdus: [[UInt8]],
        compress: Bool = true,
        priority: RDPSocket.WritePriority = .control
    ) -> Int? {
        stateLock.lock()
        let transport = self.transport
        stateLock.unlock()
        guard let transport else { return nil }
        return transport.sendGraphicsPDUs(
            pdus,
            compress: compress,
            priority: priority
        )
    }

    /// True after client CAPS_ADVERTISE → CAPS_CONFIRM → CREATE_SURFACE (frames may be sent).
    public var isPipelineReady: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running && surfacesReady
    }

    public var hasPendingForcedFrame: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return needsBootstrapIDR || forceIDR
    }

    var isFrameAcknowledgementSuspended: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !expectsFrameAcknowledgements
    }

    /// Short label for the active GFX codec (menu-bar / status).
    public var encodingLabel: String {
        activeCodec.label
    }

    /// Start the Graphics pipeline, or rebuild its active surface generation.
    ///
    /// Rebuilding is used for resize and output-resume recovery. It invalidates
    /// every in-flight encoder callback, ACK, and reference picture before
    /// creating a fresh surface and bootstrap frame.
    public func start(width: Int, height: Int) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        self.width = width
        self.height = height
        let alreadyConfirmed = surfacesReady
        h264.bitrate = targetBitrate
        let encodeFPS = constrainedFPSLocked(targetFPS)
        h264.expectedFrameRate = encodeFPS
        if encodeFPS < targetFPS {
            RDPLog.gfx.notice(
                "GFX: H.264 FPS limited \(targetFPS)→\(encodeFPS) " +
                "for \(width)x\(height) (H.264 Level 5.2)"
            )
        }
        h264.asyncMode = asyncEncoding
        if activeCodec.isProgressive {
            RDPLog.gfx.info("GFX: RemoteFX Progressive requested; waiting for CAPS")
        } else {
            RDPLog.gfx.info("GFX: waiting for CAPS codec selection (AVC when advertised, otherwise CAPROGRESSIVE)")
        }
        running = true
        sendPaused = false
        // MS-RDPEGFX: wait for client's CAPS_ADVERTISE, then CAPS_CONFIRM + surfaces.
        // Do not send CAPS_ADVERTISE from the server (receive it from the client).
        // "GFX: enabled (client supports drdynvc, …)" is logged at GCC gate (`RDPSession` / ).
        RDPLog.gfx.info("GFX: waiting for client CAPS_ADVERTISE")
        if alreadyConfirmed {
            // Resize is a new surface generation. Old callbacks and ACKs cannot
            // release the new bootstrap window.
            surfacesReady = false
            pipelineGeneration &+= 1
            encodesInFlight = 0
            rfxEncodeInFlight = false
            queueRFXReset()
            needsBootstrapIDR = false
            bootstrapIDRFrameId = nil
            keyframeInFlight = false
            referenceChainBroken = false
            h264DropResumeNotBefore = .distantPast
            consecutiveBackpressure = 0
            consecutiveEncodeFailures = 0
            forceIDR = false
            resetUnacked()
            if !activeCodec.isProgressive {
                do {
                    try h264.start(width: max(width, 1), height: max(height, 1))
                } catch {
                    handleH264InitializationFailure(error)
                    throw error
                }
            }
            completeGraphicsSetup()
        }
    }

    /// Finish pipeline after CAPS_CONFIRM.
    /// RESET → CREATE → MAP → IDR.
    private func completeGraphicsSetup() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard running, transport != nil else { return }
        guard !surfacesReady else { return }

        // Prefer a fresh surface id every setup. mstsc retains surfaces by id and
        // no-ops CreateSurface for an id it already holds (macrdp known quirk).
        // Avoid DeleteSurface of ids we may not own in the client cache.
        surfaceId = Self.allocateSurfaceID()

        let surfaceSize = (max(width, 1), max(height, 1))

        emitGraphics([buildResetGraphics(width: UInt32(width), height: UInt32(height))])
        RDPLog.gfx.info("GFX: RESET_GRAPHICS \(width)x\(height)")

        emitGraphics([buildCreateSurface(
            surfaceId: surfaceId,
            width: UInt16(surfaceSize.0),
            height: UInt16(surfaceSize.1)
        )])
        RDPLog.gfx.info(
            "GFX: CREATE_SURFACE surface=\(surfaceId) \(surfaceSize.0)x\(surfaceSize.1)"
        )

        emitGraphics([buildMapSurfaceToOutput(
            surfaceId: surfaceId, originX: 0, originY: 0
        )])
        RDPLog.gfx.info("GFX: MAP_SURFACE surface=\(surfaceId)")
        graphicsInitialized = true
        lastAckTime = Date()
        needsBootstrapIDR = !activeCodec.isProgressive
        bootstrapIDRFrameId = nil
        forceIDR = false
        keyframeInFlight = false
        referenceChainBroken = false
        h264DropResumeNotBefore = .distantPast
        encodesInFlight = 0
        surfacesReady = true
        RDPLog.gfx.info(
            activeCodec.isProgressive
                ? "GFX: encode bootstrap — first desktop frame will be a full RFX refresh"
                : "GFX: encode bootstrap — first desktop frame will be IDR"
        )
        RDPLog.gfx.info("GFX: pipeline ready (init in one pass)")
        RDPLog.gfx.info("GFX: started \(width)x\(height) surface=\(surfaceId)")
    }

    public func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        running = false
        surfacesReady = false
        graphicsInitialized = false
        sendPaused = false
        frameId = 0
        needsBootstrapIDR = false
        bootstrapIDRFrameId = nil
        keyframeInFlight = false
        referenceChainBroken = false
        h264DropResumeNotBefore = .distantPast
        encodesInFlight = 0
        rfxEncodeInFlight = false
        pipelineGeneration &+= 1
        consecutiveBackpressure = 0
        consecutiveEncodeFailures = 0
        h264.stop()
        let oldTransport = transport
        transport = nil
        activeCodec = preferredCodec
        oldTransport?.reset()
        queueRFXReset()
        resetUnacked()
        RDPLog.gfx.info("GFX: pipeline cleaned up")
        RDPLog.gfx.info("GFX: channel closed")
    }

    /// Suppress Output — pause encode/send without tearing down the pipeline.
    public func pauseSending() {
        stateLock.lock()
        sendPaused = true
        stateLock.unlock()
    }

    public var isSendPaused: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sendPaused
    }

    public func noteDisabled(displayMode: String) {
        // "GFX: disabled (displayMode=…) — bitmap mode,"
        RDPLog.gfx.info("GFX: disabled (displayMode=\(displayMode)) — bitmap mode,")
    }

    public func noteChannelCreateFailed(_ error: String) {
        RDPLog.gfx.error("GFX: channel create failed: \(error)")
    }

    public func noteWriteErrorDuringFrame(_ message: String) {
        RDPLog.gfx.error("GFX: write error during frame send \(message)")
    }

    public func requestForceIDR(reason: String = "") {
        stateLock.lock()
        defer { stateLock.unlock() }
        forceIDR = true
        RDPLog.gfx.info("GFX: force IDR requested (\(reason))")
    }

    /// Pause outbound GFX while the TCP send path is full.
    public func setSendBlocked(_ blocked: Bool) {
        stateLock.lock()
        guard sendBlocked != blocked else {
            stateLock.unlock()
            return
        }
        sendBlocked = blocked
        stateLock.unlock()
        RDPLog.gfx.info(
            "GFX: TCP send path \(blocked ? "blocked" : "writable") — " +
            "encode admission \(blocked ? "paused" : "resumed")"
        )
        onWorkAvailable?()
    }

    private struct EncodeReservation {
        let generation: UInt64
        let requiresIDR: Bool
        let width: Int
        let height: Int
        let useAsync: Bool
        let captureAgeMs: Double
        /// Scale/letterbox time before VT submit (ms); filled by `encodeFrame`.
        var prepMs: Double = 0
    }

    private struct RFXReservation {
        let generation: UInt64
        let width: Int
        let height: Int
        let surfaceId: UInt16
    }

    private enum RFXWork: Sendable {
        case progressive([RemoteFXEncoder.TileOp])
    }

    private func pendingH264FrameRequirement() -> Bool? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard running, surfacesReady, !sendPaused,
              !sendBlocked,
              !activeCodec.isProgressive,
              encodesInFlight < maxEncodesInFlight
        else { return nil }
        applyLiveCaps()
        pollAckWatchdog()
        guard Date() >= h264DropResumeNotBefore else { return nil }
        guard !expectsFrameAcknowledgements || ackTracker.count < frameAcknowledgementWindow else {
            return nil
        }
        guard !referenceChainBroken || !h264.hasPendingFrames else { return nil }
        let forced = needsBootstrapIDR || forceIDR
        guard !forced || (!keyframeInFlight && !h264.hasPendingFrames) else { return nil }
        return forced
    }

    private func reserveH264Encode(captureAgeMs: Double) -> EncodeReservation? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard running, surfacesReady, !sendPaused,
              !sendBlocked else { return nil }
        guard encodesInFlight < maxEncodesInFlight else { return nil }
        applyLiveCaps()
        pollAckWatchdog()
        guard !activeCodec.isProgressive else { return nil }
        guard Date() >= h264DropResumeNotBefore else { return nil }
        guard !expectsFrameAcknowledgements || ackTracker.count < frameAcknowledgementWindow else {
            return nil
        }
        guard !referenceChainBroken || !h264.hasPendingFrames else { return nil }

        // Bootstrap and reference-chain recovery both wait for prior VT work to
        // finish before submitting the next IDR.
        let requiresIDR = needsBootstrapIDR || forceIDR
        guard !requiresIDR || (!keyframeInFlight && !h264.hasPendingFrames) else { return nil }
        encodesInFlight += 1
        if requiresIDR {
            forceIDR = false
            keyframeInFlight = true
            h264.requestForceKeyframe()
            RDPLog.gfx.info("GFX: encoding requested IDR for next wire frame")
        }
        return EncodeReservation(
            generation: pipelineGeneration,
            requiresIDR: requiresIDR,
            width: max(width, 1),
            height: max(height, 1),
            useAsync: asyncEncoding && h264.asyncMode,
            captureAgeMs: captureAgeMs,
            prepMs: 0
        )
    }

    private func releaseEncodeSlot(_ reservation: EncodeReservation) {
        guard pipelineGeneration == reservation.generation else { return }
        encodesInFlight = max(0, encodesInFlight - 1)
        onWorkAvailable?()
    }

    private func releaseEncodeSlotAfterSend(_ reservation: EncodeReservation) {
        stateLock.lock()
        guard pipelineGeneration == reservation.generation else {
            stateLock.unlock()
            return
        }
        encodesInFlight = max(0, encodesInFlight - 1)
        stateLock.unlock()
        onWorkAvailable?()
    }

    private func failEncode(
        _ reservation: EncodeReservation,
        reason: String,
        fatal: Bool = false,
        frameDropped: Bool = false
    ) {
        var shouldRecreate = false
        var failures = 0
        stateLock.lock()
        guard pipelineGeneration == reservation.generation else {
            stateLock.unlock()
            return
        }
        releaseEncodeSlot(reservation)

        if frameDropped {
            if reservation.requiresIDR {
                keyframeInFlight = false
                forceIDR = true
            }
            let fps = max(constrainedFPSLocked(targetFPS), 1)
            let retryDelay = min(
                Self.h264DropRetryDelayMaximum,
                max(1.0 / Double(fps), 1.0 / 60.0)
            )
            h264DropResumeNotBefore = Date().addingTimeInterval(retryDelay)
            stateLock.unlock()

            controller?.noteEncodeDrop()
            RDPLog.gfx.debug(
                "GFX: \(reason); retrying H.264 in " +
                "\(String(format: "%.0f", retryDelay * 1000))ms"
            )
            return
        }

        consecutiveEncodeFailures += 1
        if reservation.requiresIDR { keyframeInFlight = false }
        referenceChainBroken = true
        forceIDR = true
        shouldRecreate = fatal || consecutiveEncodeFailures >= Self.maxEncodeFailures
        failures = consecutiveEncodeFailures
        if shouldRecreate {
            pipelineGeneration &+= 1
            running = false
            surfacesReady = false
            encodesInFlight = 0
            needsBootstrapIDR = false
            bootstrapIDRFrameId = nil
            keyframeInFlight = false
            referenceChainBroken = false
            resetUnacked()
            h264.stop()
            if !recreateScheduled {
                recreateScheduled = true
            } else {
                shouldRecreate = false
            }
        }
        stateLock.unlock()

        if shouldRecreate {
            RDPLog.gfx.error("GFX: encoder failed (\(reason)); requesting Graphics channel recreate")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                self.onPipelineFailure?()
                self.stateLock.lock()
                self.recreateScheduled = false
                self.stateLock.unlock()
            }
        } else {
            RDPLog.gfx.error(
                "GFX: encode failed (\(reason)); retry \(failures)/\(Self.maxEncodeFailures)"
            )
        }
    }

    /// Encode and send one frame from a CVPixelBuffer.
    ///
    /// The access unit covers the coded surface and every submitted frame
    /// refreshes that surface. Capture admission is based on ScreenCaptureKit
    /// frame status; encoder and protocol flow control decide whether it can be
    /// submitted now.
    ///
    /// AVC420 uses NV12 directly when available and otherwise receives a
    /// GPU-transferred buffer in the source format.
    @discardableResult
    public func encodeFrame(
        pixelBuffer: CVPixelBuffer,
        captureUptimeNanoseconds: UInt64 = 0
    ) -> FrameSubmission {
        let signpost = RDPSignpost.beginGFX("EncodeFrame")
        defer { RDPSignpost.endGFX("EncodeFrame", signpost) }
        guard pendingH264FrameRequirement() != nil else { return .blocked }
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let captureAgeMs: Double
        let now = DispatchTime.now().uptimeNanoseconds
        if captureUptimeNanoseconds > 0, now >= captureUptimeNanoseconds {
            captureAgeMs = Double(now - captureUptimeNanoseconds) / 1_000_000
        } else {
            captureAgeMs = 0
        }
        guard var reservation = reserveH264Encode(captureAgeMs: captureAgeMs) else { return .blocked }

        let prepStart = CFAbsoluteTimeGetCurrent()
        // Surface/wire = visible size. AVC420 codes at exactly that size.
        let ew = reservation.width
        let eh = reservation.height
        let codedW = max(h264.width, 1)
        let codedH = max(h264.height, 1)
        let encodePB: CVPixelBuffer
        if sourceWidth == codedW, sourceHeight == codedH {
            // Zero-copy: capture already matches the VT session geometry.
            encodePB = pixelBuffer
        } else {
            // Capture geometry does not match the session: one GPU transfer.
            let scaling: PixelBufferTransfer.Scaling =
                DisplayContentLayout.aspectsDiffer(
                    sourceWidth, sourceHeight, codedW, codedH
                ) ? .letterbox : .fill
            let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
            guard let fitted = pixelTransfer.transfer(
                pixelBuffer, width: codedW, height: codedH,
                pixelFormat: format, scaling: scaling
            ) else {
                failEncode(reservation, reason: "pixel-buffer transfer")
                return .blocked
            }
            encodePB = fitted
        }
        reservation.prepMs = (CFAbsoluteTimeGetCurrent() - prepStart) * 1000

        let left: UInt16 = 0
        let top: UInt16 = 0
        let right = UInt16(ew)
        let bottom = UInt16(eh)

        if reservation.useAsync {
            let t0 = CFAbsoluteTimeGetCurrent()
            stateLock.lock()
            guard pipelineGeneration == reservation.generation, encodesInFlight > 0 else {
                stateLock.unlock()
                return .blocked
            }
            stateLock.unlock()
            let accepted = h264.encodeAsync(
                pixelBuffer: encodePB
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let encoded):
                    self.sendEncodedFrame(
                        encoded,
                        left: left, top: top, right: right, bottom: bottom,
                        encodeMs: (CFAbsoluteTimeGetCurrent() - t0) * 1000,
                        reservation: reservation
                    )
                case .failure(let error):
                    if case .timedOut = error {
                        self.failEncode(reservation, reason: String(describing: error), fatal: true)
                    } else {
                        let frameDropped: Bool
                        if case .frameDropped = error {
                            frameDropped = true
                        } else {
                            frameDropped = false
                        }
                        self.failEncode(
                            reservation,
                            reason: String(describing: error),
                            frameDropped: frameDropped
                        )
                    }
                }
            }
            if !accepted {
                failEncode(reservation, reason: "VideoToolbox rejected submission")
                return .blocked
            }
            return .submitted
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        stateLock.lock()
        guard pipelineGeneration == reservation.generation, encodesInFlight > 0 else {
            stateLock.unlock()
            return .blocked
        }
        stateLock.unlock()
        guard let encoded = h264.encode(
            pixelBuffer: encodePB
        ) else {
            failEncode(reservation, reason: "VideoToolbox returned no sample")
            return .blocked
        }
        sendEncodedFrame(
            encoded,
            left: left, top: top, right: right, bottom: bottom,
            encodeMs: (CFAbsoluteTimeGetCurrent() - t0) * 1000,
            reservation: reservation
        )
        return .submitted
    }

    private func noteDesktopHot() {
        lastH264WireAt = Date()
        desktopRecentlyHot = true
        desktopHotClearTask?.cancel()
        desktopHotClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            self.desktopRecentlyHot = Date().timeIntervalSince(self.lastH264WireAt) < 0.75
            // Avoid NSLock from async Task (Swift 6); Bool write is atomic enough here.
        }
    }

    private func sendEncodedFrame(
        _ encoded: H264Encoder.EncodedAccessUnit,
        left: UInt16, top: UInt16, right: UInt16, bottom: UInt16,
        encodeMs: Double,
        reservation: EncodeReservation
    ) {
        let signpost = RDPSignpost.beginGFX("SendEncodedFrame")
        defer { RDPSignpost.endGFX("SendEncodedFrame", signpost) }
        let postStart = CFAbsoluteTimeGetCurrent()
        let containsIDR = encoded.isIDR
        defer { releaseEncodeSlotAfterSend(reservation) }

        stateLock.lock()
        guard pipelineGeneration == reservation.generation, encodesInFlight > 0 else {
            if pipelineGeneration == reservation.generation {
                if reservation.requiresIDR { keyframeInFlight = false }
                referenceChainBroken = true
                forceIDR = true
            }
            stateLock.unlock()
            return
        }
        if referenceChainBroken, !containsIDR {
            forceIDR = true
            stateLock.unlock()
            return
        }
        guard running, surfacesReady, !sendPaused, !sendBlocked else {
            if reservation.requiresIDR { keyframeInFlight = false }
            referenceChainBroken = true
            forceIDR = true
            stateLock.unlock()
            return
        }
        let snapSurfaceId = surfaceId
        stateLock.unlock()

        let streamBytes = encoded.bytes
        if reservation.requiresIDR, !containsIDR {
            stateLock.lock()
            if pipelineGeneration == reservation.generation {
                keyframeInFlight = false
                referenceChainBroken = true
                forceIDR = true
            }
            stateLock.unlock()
            RDPLog.gfx.error("GFX: forced keyframe produced no IDR; dropping frame and retrying")
            return
        }
        // mac-rdp: fixed QP=22 / quality=100 on the AVC420 metablock.
        let quality: UInt8 = 100
        let maxAnnexBBytes = ZGFXCompressor.maxSegmentUncompressed - 64
        if streamBytes.count > maxAnnexBBytes {
            RDPLog.gfx.debug(
                "GFX: access unit \(streamBytes.count)B > \(maxAnnexBBytes)B — multipart ZGFX"
            )
        }

        // The AVC access unit always describes the complete decoded surface.
        let fullSurfaceRegion = [(left, top, right, bottom)]
        let bitmap = Self.buildAVC420BitmapStream(
            regions: fullSurfaceRegion,
            quality: quality,
            h264AnnexB: streamBytes
        )
        let codec = Codec.avc420

        guard !bitmap.isEmpty else {
            stateLock.lock()
            if pipelineGeneration == reservation.generation {
                if reservation.requiresIDR { keyframeInFlight = false }
                referenceChainBroken = true
                forceIDR = true
            }
            stateLock.unlock()
            RDPLog.gfx.error("GFX: AVC420 stream construction failed")
            return
        }

        // Brief critical section: admit the frame id, then release before ZGFX/TCP.
        stateLock.lock()
        guard pipelineGeneration == reservation.generation else {
            stateLock.unlock()
            return
        }
        if referenceChainBroken, !containsIDR {
            forceIDR = true
            stateLock.unlock()
            return
        }
        guard running, surfacesReady, !sendPaused, !sendBlocked else {
            if reservation.requiresIDR { keyframeInFlight = false }
            referenceChainBroken = true
            forceIDR = true
            stateLock.unlock()
            return
        }
        guard transport != nil else {
            if reservation.requiresIDR { keyframeInFlight = false }
            referenceChainBroken = true
            forceIDR = true
            stateLock.unlock()
            return
        }
        frameId &+= 1
        let outboundFrameId = frameId
        // Build START/END under the lock (tiny); construct the large WIRE PDU off-lock.
        let startPDU = buildStartFrame(frameId: outboundFrameId)
        let endPDU = buildEndFrame(frameId: outboundFrameId)
        stateLock.unlock()

        let wirePDU = buildWireToSurface1(
            surfaceId: snapSurfaceId,
            left: left, top: top, right: right, bottom: bottom,
            codec: codec,
            bitmapData: bitmap
        )
        // Skip ZGFX LZ77 on AVC frames (already compressed). START/END are tiny.
        guard let wireBytes = emitGraphics(
            [startPDU, wirePDU, endPDU],
            compress: false,
            priority: .video
        ) else {
            stateLock.lock()
            if pipelineGeneration == reservation.generation {
                ackTracker.remove(frameId: outboundFrameId)
                if reservation.requiresIDR { keyframeInFlight = false }
                referenceChainBroken = true
                forceIDR = true
            }
            stateLock.unlock()
            RDPLog.gfx.info("GFX: dropping H.264 frame — video queue is full")
            onWorkAvailable?()
            return
        }

        stateLock.lock()
        if expectsFrameAcknowledgements {
            if ackTracker.count == 0 { lastAckTime = Date() }
            ackTracker.track(frameId: outboundFrameId, bytes: wireBytes)
        }
        stateLock.unlock()

        let postEncodeMs = (CFAbsoluteTimeGetCurrent() - postStart) * 1000

        stateLock.lock()
        defer { stateLock.unlock() }
        guard pipelineGeneration == reservation.generation else { return }
        if reservation.requiresIDR { keyframeInFlight = false }

        controller?.noteEncodedFrame(
            bytes: streamBytes.count,
            fps: effectiveFPS,
            encodeMs: encodeMs,
            postEncodeMs: postEncodeMs,
            prepMs: reservation.prepMs,
            captureAgeMs: reservation.captureAgeMs,
            isIDR: containsIDR,
            serverUnacked: ackTracker.count,
            ackWindow: expectsFrameAcknowledgements ? frameAcknowledgementWindow : 0
        )
        // Async H.264 callbacks include the full submit-to-output latency, which
        // is the useful throughput signal for the 4K path.
        controller?.noteEncodePressure()
        consecutiveEncodeFailures = 0
        h264DropResumeNotBefore = .distantPast
        noteDesktopHot()
        noteUnacknowledgedDepth()
        if containsIDR {
            h264.noteIDR()
            referenceChainBroken = false
            if needsBootstrapIDR {
                needsBootstrapIDR = false
                bootstrapIDRFrameId = expectsFrameAcknowledgements ? outboundFrameId : nil
            }
            RDPLog.gfx.info("GFX: IDR sent frame=\(outboundFrameId)")
        }
    }

    /// MS-RDPEGFX 2.2.4.2.1 RFX_AVC420_METABLOCK + H.264 Annex-B bitstream.
    public static func buildAVC420BitmapStream(
        regions: [(UInt16, UInt16, UInt16, UInt16)],
        quality: UInt8,
        h264AnnexB: [UInt8],
        qp: UInt8 = 22
    ) -> [UInt8] {
        guard !regions.isEmpty,
              regions.allSatisfy({ $0.0 < $0.2 && $0.1 < $0.3 })
        else { return [] }
        let regs = regions
        var out: [UInt8] = []
        out.reserveCapacity(4 + regs.count * 10 + h264AnnexB.count)
        // numRegionRects is UINT32 (not UINT16).
        out.appendU32(UInt32(regs.count))
        for r in regs {
            out.appendU16(r.0)
            out.appendU16(r.1)
            out.appendU16(r.2)
            out.appendU16(r.3)
        }
        // MS-RDPEGFX 2.2.4.4.2: p means progressively encoded region,
        // not an H.264 P-picture. This encoder does not use progressive AVC,
        // so both reserved bit r and progressive bit p remain zero.
        let qpVal = qp & 0x3F
        for _ in regs {
            out.append(qpVal)
            out.append(quality)
        }
        // MS-RDPEGFX + mac-rdp: Annex-B start codes on the wire.
        out.append(contentsOf: h264AnnexB)
        return out
    }

    // MARK: - RDPEGFX PDU builders (MS-RDPEGFX 2.2)

    /// Queue one bounded RFX frame. The software encoder and transport send run
    /// off the capture loop; the next submission waits until this one is wired.
    @discardableResult
    public func encodeProgressiveOps(_ ops: [RemoteFXEncoder.TileOp]) -> Bool {
        guard !ops.isEmpty else { return false }
        return enqueueRFX(.progressive(ops))
    }

    private func enqueueRFX(_ work: RFXWork) -> Bool {
        stateLock.lock()
        guard running, surfacesReady, !sendPaused,
              !sendBlocked,
              transport != nil, !rfxEncodeInFlight
        else {
            stateLock.unlock()
            return false
        }
        applyLiveCaps()
        pollAckWatchdog()
        guard !expectsFrameAcknowledgements || ackTracker.count < frameAcknowledgementWindow else {
            stateLock.unlock()
            return false
        }
        let ew = max(width, 1)
        let eh = max(height, 1)
        rfxEncodeInFlight = true
        let reservation = RFXReservation(
            generation: pipelineGeneration,
            width: ew,
            height: eh,
            surfaceId: surfaceId
        )
        let encoder = rfxEncoder
        stateLock.unlock()

        rfxQueue.async { [weak self, encoder] in
            guard let self else { return }
            let encodeStarted = CFAbsoluteTimeGetCurrent()
            let payload: [UInt8]
            let label: String
            switch work {
            case .progressive(let ops):
                payload = encoder.encodeProgressiveLadderFrame(
                    width: UInt16(clamping: reservation.width),
                    height: UInt16(clamping: reservation.height),
                    ops: ops
                )
                label = "progressive"
            }
            let encodeMs = (CFAbsoluteTimeGetCurrent() - encodeStarted) * 1000
            self.sendRFXPayload(
                payload,
                label: label,
                encodeMs: encodeMs,
                reservation: reservation
            )
        }
        return true
    }

    private func sendRFXPayload(
        _ payload: [UInt8],
        label: String,
        encodeMs: Double,
        reservation: RFXReservation
    ) {
        stateLock.lock()
        guard pipelineGeneration == reservation.generation,
              rfxEncodeInFlight,
              running,
              surfacesReady,
              !sendPaused,
              transport != nil
        else {
            if pipelineGeneration == reservation.generation {
                rfxEncodeInFlight = false
            }
            stateLock.unlock()
            return
        }

        frameId &+= 1
        let outboundFrameId = frameId
        let startPDU = buildStartFrame(frameId: outboundFrameId)
        let endPDU = buildEndFrame(frameId: outboundFrameId)
        stateLock.unlock()

        let wirePDU = buildProgressiveWireToSurface(
            surfaceId: reservation.surfaceId,
            bitmapData: payload
        )
        guard let wireBytes = emitGraphics(
            [startPDU, wirePDU, endPDU],
            compress: true,
            priority: .video
        ) else {
            stateLock.lock()
            if pipelineGeneration == reservation.generation {
                ackTracker.remove(frameId: outboundFrameId)
                rfxEncodeInFlight = false
            }
            stateLock.unlock()
            onVideoFrameDropped?()
            RDPLog.gfx.info("GFX: dropping RFX frame — video queue is full")
            onWorkAvailable?()
            return
        }

        stateLock.lock()
        if expectsFrameAcknowledgements {
            if ackTracker.count == 0 { lastAckTime = Date() }
            ackTracker.track(frameId: outboundFrameId, bytes: wireBytes)
        }
        stateLock.unlock()

        stateLock.lock()
        guard pipelineGeneration == reservation.generation else {
            stateLock.unlock()
            return
        }
        rfxEncodeInFlight = false
        controller?.noteEncodedFrame(
            bytes: payload.count,
            fps: effectiveFPS,
            encodeMs: encodeMs,
            serverUnacked: ackTracker.count,
            ackWindow: expectsFrameAcknowledgements ? frameAcknowledgementWindow : 0
        )
        controller?.noteRFXEncodeMs(encodeMs)
        noteUnacknowledgedDepth()
        let frame = outboundFrameId
        let dimensions = "\(reservation.width)x\(reservation.height)"
        stateLock.unlock()
        onWorkAvailable?()

        RDPLog.gfx.debug(
            "GFX: RFX \(label) frame=\(frame) \(dimensions) " +
            "bytes=\(payload.count) encode=\(String(format: "%.1f", encodeMs))ms"
        )
    }

    /// Returns false when backpressure drops the frame.
    /// Flow control decisions live in `VideoTargetController`; this only tracks frame IDs.
    private func hasOutboundFrameCapacity() -> Bool {
        applyLiveCaps()
        if sendBlocked { return false }
        pollAckWatchdog()
        if !expectsFrameAcknowledgements { return true }
        return ackTracker.count < frameAcknowledgementWindow
    }

    /// Timeout / recover when FRAME_ACK stalls — safe to call on every encode tick.
    private func pollAckWatchdog() {
        guard controller != nil, expectsFrameAcknowledgements else { return }
        if sendBlocked { return }
        let depth = ackTracker.count
        guard depth > 0 else { return }
        guard Date().timeIntervalSince(lastAckTime) > frameAcknowledgementTimeout else { return }
        let was = depth
        lastAckTime = Date()
        consecutiveBackpressure += 1
        if consecutiveBackpressure == 1 || consecutiveBackpressure % 15 == 0 {
            RDPLog.gfx.info(
                "GFX: ACK stall — holding \(was) frame(s) until client acknowledgement " +
                "(checks=\(consecutiveBackpressure))"
            )
        }

        // After repeated missing FRAME_ACKs, clear the application frame window
        // and force an IDR.
        if consecutiveBackpressure >= 5 {
            let cleared = ackTracker.reset()
            forceIDR = true
            consecutiveBackpressure = 0
            _ = controller?.noteBackpressureTimeout(
                unackedWas: cleared
            )
            applyLiveCaps()
            RDPLog.gfx.error(
                "GFX: ACK stall recovery — cleared \(cleared) unacked frame(s), forcing IDR"
            )
            onWorkAvailable?()
        }
    }

    private func applyLiveCaps() {
        guard let controller else { return }
        targetFPS = controller.targetFPS
        h264.updateExpectedFrameRate(constrainedFPSLocked(targetFPS))
        if controller.targetBitrate != targetBitrate {
            targetBitrate = controller.targetBitrate
            h264.updateBitrate(targetBitrate)
            RDPLog.gfx.info("Bitrate changed to \(targetBitrate)")
        }
        applyFrameAckWindowForCodecLocked()
    }

    /// apply VideoTargetController caps outside encode (e.g. after TCP backpressure).
    public func applyLiveControllerCaps() {
        stateLock.lock()
        defer { stateLock.unlock() }
        applyLiveCaps()
    }

    // MARK: - Client → server GFX (not ZGFX-wrapped)

    /// Handle inbound Graphics DVC bytes (FRAME_ACK / CAPS_CONFIRM / SUSPEND / CACHE_IMPORT).
    public func handleClientPDU(_ data: [UInt8]) {
        var offset = 0
        while offset < data.count {
            let remaining = data.count - offset
            guard remaining >= 8 else {
                rejectCapability("GFX: truncated PDU header (\(remaining)B)")
                return
            }
            let pduLen = Int(UInt32(data[offset + 4]) | UInt32(data[offset + 5]) << 8
                | UInt32(data[offset + 6]) << 16 | UInt32(data[offset + 7]) << 24)
            guard pduLen >= 8, pduLen <= remaining else {
                rejectCapability(
                    "GFX: invalid PDU length \(pduLen) for \(remaining)B of input"
                )
                return
            }
            handleClientMessage(Array(data[offset..<(offset + pduLen)]))
            offset += pduLen
        }
    }

    private func handleClientMessage(_ data: [UInt8]) {
        guard data.count >= 8 else {
            rejectCapability("GFX: invalid PDU length (\(data.count))")
            return
        }
        let cmd = UInt16(data[0]) | UInt16(data[1]) << 8
        let headerFlags = UInt16(data[2]) | UInt16(data[3]) << 8
        guard headerFlags == 0 else {
            rejectCapability(
                "GFX: command 0x\(String(cmd, radix: 16)) has nonzero flags 0x" +
                "\(String(headerFlags, radix: 16))"
            )
            return
        }
        switch cmd {
        case 0x000D: // RDPGFX_CMDID_FRAMEACKNOWLEDGE (MS-RDPEGFX 2.2.2.13)
            // header(8) + queueDepth(4)@8 + frameId(4)@12 + totalFramesDecoded(4)@16
            guard data.count == 20 else {
                rejectCapability("GFX: invalid FRAME_ACKNOWLEDGE length \(data.count)")
                return
            }
            let clientQueueBytes = UInt32(data[8]) | UInt32(data[9]) << 8
                | UInt32(data[10]) << 16 | UInt32(data[11]) << 24
            let ackFrame = UInt32(data[12]) | UInt32(data[13]) << 8
                | UInt32(data[14]) << 16 | UInt32(data[15]) << 24
            let totalFramesDecoded = UInt32(data[16]) | UInt32(data[17]) << 8
                | UInt32(data[18]) << 16 | UInt32(data[19]) << 24
            let clientQueue: ClientQueueFeedback
            let clientQueueLabel: String
            switch clientQueueBytes {
            case UInt32.max:
                clientQueue = .suspended
                clientQueueLabel = "suspended"
            case 0:
                clientQueue = .unavailable
                clientQueueLabel = "unavailable"
            default:
                clientQueue = .queued(bytes: Int(clientQueueBytes))
                clientQueueLabel = "\(clientQueueBytes)B"
            }
            RDPLog.gfx.debug(
                "GFX: FRAME_ACK frameId=\(ackFrame) clientQueue=\(clientQueueLabel) " +
                "decoded=\(totalFramesDecoded)"
            )
            let wake = onWorkAvailable
            stateLock.lock()
            handleFrameAck(
                ackFrame,
                clientQueue: clientQueue,
                acknowledgementsSuspended: clientQueueBytes == UInt32.max,
                totalFramesDecoded: totalFramesDecoded
            )
            stateLock.unlock()
            wake?()
        case 0x0016: // RDPGFX_CMDID_QOEFRAMEACKNOWLEDGE (MS-RDPEGFX 2.2.2.21)
            // QoE is diagnostic feedback, not a FRAME_ACK. It must never clear the
            // unacknowledged-frame window.
            guard data.count == 20 else {
                rejectCapability("GFX: invalid QOE_FRAME_ACKNOWLEDGE length \(data.count)")
                return
            }
            let ackFrame = UInt32(data[8]) | UInt32(data[9]) << 8
                | UInt32(data[10]) << 16 | UInt32(data[11]) << 24
            let commandDecodeMs = UInt16(data[16]) | UInt16(data[17]) << 8
            let renderMs = UInt16(data[18]) | UInt16(data[19]) << 8
            RDPLog.gfx.debug(
                "GFX: QOE frameId=\(ackFrame) commandDecode=\(commandDecodeMs)ms render=\(renderMs)ms"
            )
            stateLock.lock()
            controller?.noteClientRenderTiming(
                commandDecodeMs: Int(commandDecodeMs),
                renderMs: Int(renderMs)
            )
            applyLiveCaps()
            stateLock.unlock()
        case 0x0010: // CACHE_IMPORT_OFFER
            RDPLog.gfx.info("GFX: CACHE_IMPORT_OFFER (\(data.count)B)")
            // Reply off stateLock — transport writes may block on TCP.
            stateLock.lock()
            let canReply = transport != nil
            stateLock.unlock()
            if canReply {
                emitGraphics([buildCacheImportReply(cacheEntries: [])])
                RDPLog.gfx.info("GFX: CACHE_IMPORT_REPLY sent (0 entries)")
            } else {
                RDPLog.gfx.info("GFX: failed to send CACHE_IMPORT_REPLY: no send path")
            }
        case 0x0012: // CAPS_ADVERTISE — client → server (MS-RDPEGFX 2.2.2.18)
            stateLock.lock()
            handleCapsAdvertise(data)
            stateLock.unlock()
        default:
            RDPLog.gfx.debug("GFX: client cmd=0x\(String(cmd, radix: 16)) (\(data.count)B)")
        }
    }

    /// Client CAPS_ADVERTISE → parse + select → CAPS_CONFIRM.
    private func handleCapsAdvertise(_ data: [UInt8]) {
        // need ≥10B; count @8; sets start @10 (MS-RDPEGFX, no pad).
        guard data.count >= 10 else {
            rejectCapability("GFX: CAPS_ADVERTISE too short (\(data.count)B)")
            return
        }
        let pduLen = Int(UInt32(data[4]) | UInt32(data[5]) << 8
            | UInt32(data[6]) << 16 | UInt32(data[7]) << 24)
        guard pduLen == data.count else {
            rejectCapability(
                "GFX: CAPS_ADVERTISE length mismatch declared=\(pduLen) actual=\(data.count)"
            )
            return
        }

        let capsSetCount = Int(UInt16(data[8]) | UInt16(data[9]) << 8)
        guard let offered = Self.parseCapSets(data, declaredCount: capsSetCount) else {
            rejectCapability("GFX: CAPS_ADVERTISE contains an invalid capability set")
            return
        }
        for (version, flags) in offered {
            RDPLog.gfx.info("GFX: CAPS_ADVERTISE — ver=0x\(String(version, radix: 16)) flags=0x\(String(flags, radix: 16))")
        }

        // MS-RDPEGFX 3.2.5.19: select the highest capability set that this
        // server actually implements. Only this set's flags apply after the
        // CAPS_CONFIRM; lower sets cannot be searched for a different codec.
        let supported = offered.filter {
            Self.supportsCapabilitySet(version: $0.0, flags: $0.1)
        }
        guard let selected = supported.max(by: { $0.0 < $1.0 }) else {
            let head = data.prefix(48).map { String(format: "%02x", $0) }.joined(separator: " ")
            rejectCapability(
                "GFX: CAPS_ADVERTISE — no supported capability set " +
                "count=\(capsSetCount) head=[\(head)]"
            )
            return
        }

        let bestVersion = selected.0
        let bestFlags = selected.1
        let selectedCodec: GraphicsCodec
        // The configured codec is preferred. RFX is selected only when requested
        // or when the client capability set does not permit AVC.
        if preferredCodec.isProgressive {
            guard Self.supportsProgressive(version: bestVersion, flags: bestFlags) else {
                rejectCapability(
                    "GFX: selected capability 0x\(String(bestVersion, radix: 16)) " +
                    "requires a codec this server does not implement"
                )
                return
            }
            selectedCodec = .remoteFXProgressive
        } else if Self.supportsAVC(version: bestVersion, flags: bestFlags) {
            selectedCodec = .h264AVC420
        } else if Self.supportsProgressive(version: bestVersion, flags: bestFlags) {
            selectedCodec = .remoteFXProgressive
            RDPLog.gfx.info(
                "GFX: selected capability disables AVC — using CAPROGRESSIVE " +
                "capVer=0x\(String(bestVersion, radix: 16))"
            )
        } else {
            rejectCapability(
                "GFX: selected capability 0x\(String(bestVersion, radix: 16)) " +
                "has no supported codec"
            )
            return
        }

        // MS-RDPEGFX 3.3.5.19: for 10.3–10.7, a repeated CAPS_ADVERTISE
        // resets the client's complete Graphics channel state. Do not DELETE
        // the old surface after CAPS_CONFIRM because it no longer exists.
        let isProtocolReset = graphicsInitialized || selectedCapVersion != 0
        if isProtocolReset {
            graphicsInitialized = false
            expectsFrameAcknowledgements = true
            recreateScheduled = false
            // RDPGFX_START_FRAME.frameId remains unique for the connection.
            // Clear outstanding frame state below, but never reuse an ID that
            // the client has already decoded before resetting the channel.
            RDPLog.gfx.info(
                "GFX: repeated CAPS_ADVERTISE — protocol state reset; nextFrame=\(frameId &+ 1)"
            )
        }

        // default echoes client flags (v301==0).
        // Clearing AVC_DISABLED while the client advertised it is not the default.
        let confirmFlags = bestFlags

        if selectedCodec.isProgressive {
            guard Self.supportsProgressive(version: bestVersion, flags: confirmFlags) else {
                rejectCapability("GFX: selected capability cannot carry CAPROGRESSIVE")
                return
            }
        } else {
            guard Self.supportsAVC(version: bestVersion, flags: confirmFlags) else {
                rejectCapability("GFX: selected capability cannot carry AVC")
                return
            }
        }
        activeCodec = selectedCodec
        selectedCapVersion = bestVersion
        selectedCapFlags = confirmFlags
        // Keep Demand Active / client desktop size. match client resolution
        // via VirtualDisplay; clamping to the physical panel (e.g. 1920x1088 while
        // the client asked 1424x700) is what triggered "协议错误" on iPad.

        // Fresh session state after CAPS reselect.
        pipelineGeneration &+= 1
        surfacesReady = false
        encodesInFlight = 0
        rfxEncodeInFlight = false
        queueRFXReset()
        needsBootstrapIDR = false
        bootstrapIDRFrameId = nil
        keyframeInFlight = false
        referenceChainBroken = false
        h264DropResumeNotBefore = .distantPast
        resetUnacked()
        lastAckTime = Date()
        forceIDR = false
        consecutiveEncodeFailures = 0
        transport?.reset()
        controller?.resetGraphicsChannel()
        controller?.setRFXAdaptiveMode(activeCodec.isProgressive)
        applyFrameAckWindowForCodecLocked()
        applyLiveCaps()

        if selectedCodec.isProgressive {
            RDPLog.gfx.info("GFX: RemoteFX Progressive codec (from CAPS)")
            h264.stop()
            RDPLog.gfx.info(
                "GFX: RemoteFX Progressive ENABLED — capVer=0x\(String(bestVersion, radix: 16))"
            )
        } else {
            guard startH264Encoder(width: max(width, 1), height: max(height, 1)) else { return }
            RDPLog.gfx.info("GFX: AVC420 enabled ver=0x\(String(bestVersion, radix: 16))")
        }

        controller?.setRFXAdaptiveMode(activeCodec.isProgressive)
        applyFrameAckWindowForCodecLocked()

        emitGraphics([buildCapsConfirm(version: bestVersion, flags: confirmFlags)])
        RDPLog.gfx.info(
            "GFX: CAPS_CONFIRM sent (version=0x\(String(bestVersion, radix: 16)) " +
            "flags=0x\(String(confirmFlags, radix: 16)))"
        )
        completeGraphicsSetup()
    }

    private func rejectCapability(_ reason: String) {
        RDPLog.gfx.error(reason)
        let failure = onCapabilityFailure
        DispatchQueue.global(qos: .userInitiated).async {
            failure?()
        }
    }

    private func startH264Encoder(width: Int, height: Int) -> Bool {
        do {
            try h264.start(width: width, height: height)
            return true
        } catch {
            handleH264InitializationFailure(error)
            return false
        }
    }

    private func handleH264InitializationFailure(_ error: Error) {
        surfacesReady = false
        running = false
        RDPLog.gfx.error("GFX: H264 encoder initialization failed: \(error)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.onPipelineFailure?()
        }
    }

    private static func expectedCapsDataLength(version: UInt32) -> Int? {
        switch version {
        case capVersion8, capVersion81, capVersion10, capVersion102,
             capVersion103, capVersion104, capVersion105, capVersion106,
             capVersion107:
            return 4
        case capVersion101:
            return 16
        default:
            return nil
        }
    }

    private static func hasValidFlags(version: UInt32, flags: UInt32) -> Bool {
        let allowed: UInt32
        switch version {
        case capVersion8:
            allowed = capsFlagThinClient | capsFlagSmallCache
        case capVersion81:
            allowed = capsFlagThinClient | capsFlagSmallCache | capsFlagAvc420Enabled
        case capVersion10, capVersion102:
            allowed = capsFlagSmallCache | capsFlagAvcDisabled
        case capVersion103:
            allowed = capsFlagAvcDisabled | capsFlagAvcThinClient
        case capVersion104, capVersion105, capVersion106:
            allowed = capsFlagSmallCache | capsFlagAvcDisabled | capsFlagAvcThinClient
        case capVersion107:
            allowed = capsFlagSmallCache | capsFlagAvcDisabled
                | capsFlagAvcThinClient | capsFlagScaledMapDisable
        case capVersion101:
            return flags == 0
        default:
            return false
        }
        guard (flags & ~allowed) == 0 else { return false }
        return (flags & capsFlagAvcThinClient) == 0
            || (flags & capsFlagAvcDisabled) == 0
    }

    private static func supportsAVC(version: UInt32, flags: UInt32) -> Bool {
        guard (flags & capsFlagAvcDisabled) == 0 else { return false }
        switch version {
        case capVersion81:
            return (flags & capsFlagAvc420Enabled) != 0
        case capVersion10, capVersion102, capVersion103, capVersion104,
             capVersion105, capVersion106, capVersion107:
            return true
        default:
            return false
        }
    }

    private static func supportsProgressive(version: UInt32, flags: UInt32) -> Bool {
        switch version {
        case capVersion8, capVersion81:
            // MS-RDPEGFX: THINCLIENT requires classic RemoteFX in place of
            // RemoteFX Progressive. This server intentionally has no classic
            // RFX encoder, so such a set is not supported here.
            return (flags & capsFlagThinClient) == 0
        case capVersion10, capVersion102, capVersion103, capVersion104,
             capVersion105, capVersion106, capVersion107:
            return true
        default:
            return false
        }
    }

    private static func supportsCapabilitySet(version: UInt32, flags: UInt32) -> Bool {
        guard version != capVersion101, hasValidFlags(version: version, flags: flags) else {
            return false
        }
        return supportsAVC(version: version, flags: flags)
            || supportsProgressive(version: version, flags: flags)
    }

    /// sets start at offset 10 after capsSetCount.
    private static func parseCapSets(
        _ slice: [UInt8],
        declaredCount: Int
    ) -> [(UInt32, UInt32)]? {
        var offered: [(UInt32, UInt32)] = []
        var seen = Set<UInt32>()
        var offset = 10
        guard declaredCount >= 0 else { return nil }
        for _ in 0..<declaredCount {
            guard offset + 8 <= slice.count else { return nil }
            let version = UInt32(slice[offset]) | UInt32(slice[offset + 1]) << 8
                | UInt32(slice[offset + 2]) << 16 | UInt32(slice[offset + 3]) << 24
            let capsDataLength = Int(UInt32(slice[offset + 4]) | UInt32(slice[offset + 5]) << 8
                | UInt32(slice[offset + 6]) << 16 | UInt32(slice[offset + 7]) << 24)
            offset += 8
            guard capsDataLength >= 0, offset + capsDataLength <= slice.count,
                  seen.insert(version).inserted else {
                return nil
            }
            let capsData = slice[offset..<(offset + capsDataLength)]
            if let expectedLength = expectedCapsDataLength(version: version) {
                guard capsDataLength == expectedLength else { return nil }
                if version == capVersion101 {
                    guard capsData.allSatisfy({ $0 == 0 }) else { return nil }
                }
                let flags: UInt32
                if version == capVersion101 {
                    flags = 0
                } else {
                    flags = UInt32(capsData[capsData.startIndex])
                        | UInt32(capsData[capsData.startIndex + 1]) << 8
                        | UInt32(capsData[capsData.startIndex + 2]) << 16
                        | UInt32(capsData[capsData.startIndex + 3]) << 24
                }
                guard hasValidFlags(version: version, flags: flags) else { return nil }
                offered.append((version, flags))
            }
            offset += capsDataLength
        }
        guard offset == slice.count else { return nil }
        return offered
    }

    private func handleFrameAck(
        _ frameId: UInt32,
        clientQueue: ClientQueueFeedback,
        acknowledgementsSuspended: Bool,
        totalFramesDecoded: UInt32
    ) {
        controller?.noteClientDecodedFrame(totalFramesDecoded: totalFramesDecoded)
        if acknowledgementsSuspended {
            // MS-RDPEGFX 3.2.5.13: clear all unacknowledged frames and stop
            // waiting for FRAME_ACK until the client opts back in.
            let acknowledgedBootstrapIDR = bootstrapIDRFrameId.map {
                FrameAckTracker.isSerialNumberAtOrAfter(frameId, $0)
            } ?? false
            let cleared = ackTracker.reset()
            expectsFrameAcknowledgements = false
            controller?.noteClientQueueSuspended()
            lastAckTime = Date()
            consecutiveBackpressure = 0
            if acknowledgedBootstrapIDR, let idrFrameId = bootstrapIDRFrameId {
                bootstrapIDRFrameId = nil
                RDPLog.gfx.info("GFX: bootstrap IDR ACK received frame=\(idrFrameId)")
            }
            applyLiveCaps()
            RDPLog.gfx.info(
                "GFX: FRAME_ACK suspended by client frame=\(frameId); cleared unacked=\(cleared)"
            )
            return
        }

        let resumed = !expectsFrameAcknowledgements
        expectsFrameAcknowledgements = true
        let sample = ackTracker.acknowledge(upTo: frameId)
        lastAckTime = Date()
        consecutiveBackpressure = 0

        let acknowledgedBootstrapIDR = bootstrapIDRFrameId.map {
            FrameAckTracker.isSerialNumberAtOrAfter(frameId, $0)
        } ?? false
        if acknowledgedBootstrapIDR, let idrFrameId = bootstrapIDRFrameId {
            bootstrapIDRFrameId = nil
            RDPLog.gfx.info("GFX: bootstrap IDR ACK received frame=\(idrFrameId) — opening steady send window")
        }

        if resumed {
            RDPLog.gfx.info("GFX: FRAME_ACK flow resumed at frame=\(frameId)")
        }

        guard let controller else { return }
        controller.exitStallRecoveryIfPossible()
        guard let sample else {
            RDPLog.gfx.debug("GFX: FRAME_ACK frame=\(frameId) has no tracked send sample")
            applyLiveCaps()
            return
        }
        RDPLog.gfx.debug(String(format: "GFX: FRAME_ACK received frameId=%u ackLatency=%.1fms", frameId, sample.latencyMs))
        controller.noteFrameAck(
            clientQueue: clientQueue,
            ackLatencyMs: sample.latencyMs,
            unacked: sample.unacked,
            acknowledgedBytes: sample.acknowledgedBytes,
            acknowledgedFrames: sample.acknowledgedFrameCount,
            acknowledgementIntervalMs: sample.acknowledgementIntervalMs
        )
        applyLiveCaps()
    }

    /// Outstanding Graphics frames waiting for FRAME_ACK (menu / diagnostics).
    public var unackedFrameCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return ackTracker.count
    }

    public func resetUnacked() {
        stateLock.lock()
        defer { stateLock.unlock() }
        let count = ackTracker.reset()
        RDPLog.gfx.info("GFX: reset unacked=\(count)")
        // Keep `consecutiveBackpressure` so a timeout series is not hidden by
        // an unrelated surface or channel bookkeeping reset.
    }

    private func noteUnacknowledgedDepth() {
        let depth = ackTracker.count
        if depth > 1, depth % 30 == 0 {
            RDPLog.gfx.debug("GFX: unacknowledged frame count appears constant (\(depth))")
        }
        pollAckWatchdog()
    }

    // MARK: - Command IDs (MS-RDPEGFX 2.2.1)

    private enum Cmd: UInt16 {
        case wireToSurface1 = 0x0001
        case wireToSurface2 = 0x0002
        case createSurface = 0x0009
        case startFrame = 0x000B
        case endFrame = 0x000C
        case resetGraphics = 0x000E
        case mapSurfaceToOutput = 0x000F
        case cacheImportReply = 0x0011
        case capsConfirm = 0x0013
    }

    public enum Codec: UInt16 {
        case caprogressive = 0x0009
        case avc420 = 0x000B
    }

    private enum PixelFormat: UInt8 {
        case xrgb8888 = 0x20
    }

    private func gfxHeader(cmd: Cmd, payloadLen: Int) -> [UInt8] {
        var h: [UInt8] = []
        h.appendU16(cmd.rawValue)
        h.appendU16(0) // flags
        h.appendU32(UInt32(8 + payloadLen))
        return h
    }

    public func buildCreateSurface(surfaceId: UInt16, width: UInt16, height: UInt16) -> [UInt8] {
        var body: [UInt8] = []
        body.appendU16(surfaceId)
        body.appendU16(width)
        body.appendU16(height)
        body.append(PixelFormat.xrgb8888.rawValue)
        var pdu = gfxHeader(cmd: .createSurface, payloadLen: body.count)
        pdu.append(contentsOf: body)
        return pdu
    }

    public func buildMapSurfaceToOutput(surfaceId: UInt16, originX: UInt32, originY: UInt32) -> [UInt8] {
        var body: [UInt8] = []
        body.appendU16(surfaceId)
        body.appendU16(0) // reserved
        body.appendU32(originX)
        body.appendU32(originY)
        var pdu = gfxHeader(cmd: .mapSurfaceToOutput, payloadLen: body.count)
        pdu.append(contentsOf: body)
        return pdu
    }

    public func buildResetGraphics(width: UInt32, height: UInt32, monitorCount: UInt16 = 1) -> [UInt8] {
        // MS-RDPEGFX / : PDU length is always 340 bytes.
        // Body = width+height+count (12) + MONITOR_DEF×N (20×N) + pad (320 − 20×N).
        let count = min(Int(monitorCount), 16)
        var body: [UInt8] = []
        body.appendU32(width)
        body.appendU32(height)
        body.appendU32(UInt32(count))
        for i in 0..<count {
            if i == 0 {
                body.appendU32(0)
                body.appendU32(0)
                body.appendU32(width &- 1)
                body.appendU32(height &- 1)
                body.appendU32(1) // MONITOR_PRIMARY
            } else {
                body.append(contentsOf: [UInt8](repeating: 0, count: 20))
            }
        }
        let pad = max(320 - 20 * count, 0)
        if pad > 0 {
            body.append(contentsOf: [UInt8](repeating: 0, count: pad))
        }
        var pdu = gfxHeader(cmd: .resetGraphics, payloadLen: body.count)
        pdu.append(contentsOf: body)
        return pdu
    }

    public func buildCacheImportReply(cacheEntries: [UInt64]) -> [UInt8] {
        var body: [UInt8] = []
        body.appendU16(UInt16(cacheEntries.count))
        for e in cacheEntries {
            body.appendU64(e)
        }
        var pdu = gfxHeader(cmd: .cacheImportReply, payloadLen: body.count)
        pdu.append(contentsOf: body)
        return pdu
    }

    public func buildWireToSurface1(
        surfaceId: UInt16,
        left: UInt16, top: UInt16,
        right: UInt16, bottom: UInt16,
        codec: Codec = .avc420,
        bitmapData: [UInt8]
    ) -> [UInt8] {
        // MS-RDPEGFX 2.2.2.1: surfaceId, codecId, pixelFormat, destRect, len, data.
        // No "destRect present" flag byte.
        var body: [UInt8] = []
        body.appendU16(surfaceId)
        body.appendU16(codec.rawValue)
        body.append(PixelFormat.xrgb8888.rawValue)
        body.appendU16(left)
        body.appendU16(top)
        body.appendU16(right)
        body.appendU16(bottom)
        body.appendU32(UInt32(bitmapData.count))
        body.append(contentsOf: bitmapData)
        var pdu = gfxHeader(cmd: .wireToSurface1, payloadLen: body.count)
        pdu.append(contentsOf: body)
        return pdu
    }

    /// CAPROGRESSIVE uses WIRE_TO_SURFACE_2, a codec
    /// context word, and no destination rectangle. The rectangle form above
    /// is WIRE_TO_SURFACE_1.
    public func buildProgressiveWireToSurface(
        surfaceId: UInt16,
        bitmapData: [UInt8]
    ) -> [UInt8] {
        var body: [UInt8] = []
        body.appendU16(surfaceId)
        body.appendU16(Codec.caprogressive.rawValue)
        body.appendU32(0) // codecContextId — match FreeRDP / CONTEXT ctxId
        body.append(PixelFormat.xrgb8888.rawValue)
        body.appendU32(UInt32(bitmapData.count))
        body.append(contentsOf: bitmapData)
        var pdu = gfxHeader(cmd: .wireToSurface2, payloadLen: body.count)
        pdu.append(contentsOf: body)
        return pdu
    }

    public func buildStartFrame(frameId: UInt32, timestamp: UInt32 = 0) -> [UInt8] {
        var body: [UInt8] = []
        body.appendU32(timestamp) // uptime ms first.
        body.appendU32(frameId)
        var pdu = gfxHeader(cmd: .startFrame, payloadLen: body.count)
        pdu.append(contentsOf: body)
        return pdu
    }

    public func buildEndFrame(frameId: UInt32) -> [UInt8] {
        var body: [UInt8] = []
        body.appendU32(frameId)
        var pdu = gfxHeader(cmd: .endFrame, payloadLen: body.count)
        pdu.append(contentsOf: body)
        return pdu
    }

    public func buildCapsConfirm(version: UInt32, flags: UInt32) -> [UInt8] {
        var capsData: [UInt8] = []
        if version == 0x000A_0100 {
            // RDPGFX_CAPSET_VERSION101: 16 reserved bytes, all zero.
            capsData = [UInt8](repeating: 0, count: 16)
        } else {
            capsData.appendU32(flags)
        }
        var capsSet: [UInt8] = []
        capsSet.appendU32(version)
        capsSet.appendU32(UInt32(capsData.count))
        capsSet.append(contentsOf: capsData)
        var body: [UInt8] = []
        body.append(contentsOf: capsSet)
        var pdu = gfxHeader(cmd: .capsConfirm, payloadLen: body.count)
        pdu.append(contentsOf: body)
        return pdu
    }

}
