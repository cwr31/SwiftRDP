import Foundation
import NIOCore
import CoreVideo
import CoreGraphics

final class RDPPulseSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        lock.lock()
        let waiter = self.waiter
        self.waiter = nil
        pending = waiter == nil
        lock.unlock()
        waiter?.resume()
    }

    func wait(timeoutNanoseconds: UInt64) async {
        guard timeoutNanoseconds > 0 else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.waitForSignal() }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    private func waitForSignal() async {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                lock.lock()
                let cancelled = Task.isCancelled
                let ready = pending || cancelled
                if !cancelled { pending = false }
                if !ready {
                    waiter = continuation
                }
                lock.unlock()
                if ready {
                    continuation.resume()
                }
            }
        }, onCancel: {
            cancelWaiter()
        })
    }

    private func cancelWaiter() {
        lock.lock()
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume()
    }
}

/// Per-connection RDP state machine (self-implemented MS-RDPBCGR path).
/// Phase names aligned with runtime logs for easier side-by-side debugging.
public final class RDPSession: @unchecked Sendable {
    public enum Phase: String {
        case connectionInitiation // X.224
        case tls
        case credssp
        case basicSettings        // MCS Connect
        case channelConnection
        case secureSettings       // Client Info
        case licensing
        case capabilities
        case connectionFinalization
        case active
        case terminated

    }

    public let id = UUID()
    public private(set) var phase: Phase = .connectionInitiation
    public let config: ServerConfig
    private let videoQualityLock = NSLock()
    private var videoQualityValue: VideoQualitySettings
    private let audioPlaybackLock = NSLock()
    private var audioPlaybackDestinationValue: AudioPlaybackDestination
    /// Back-pointer for session registry.
    public weak var sessionManager: SessionManager?

    private var buffer: [UInt8] = []
    private var selectedProtocol: UInt32 = X224.protocolSSL
    /// Echoed in GCC SC_CORE (must be client's X.224 requestedProtocols, not selected).
    private var clientRequestedProtocols: UInt32 = 0
    private var mcsUserId: UInt16 = 1002
    private var ioChannelId: UInt16 = 1003
    /// MCS message channel (SC_MCS_MSGCHANNEL) — assigned as `1004 + channelCount`.
    private var msgChannelId: UInt16 = 0
    private(set) var mainEventLoop: EventLoop?
    private var autoReconnectRefresh: Scheduled<Void>?
    private var multitransportNegotiated = false
    private var multitransportTunnel: MultitransportTunnel?
    private var multitransportClientReady = false
    private var multitransportChannelID: UInt32?
    private var softSyncTimeout: Scheduled<Void>?
    private static let tcpBackpressureLogThresholdMs = 50.0
    private var networkAutoDetect: NetworkAutoDetect?
    private var clientSupportsNetCharAutoDetect = false
    private var clientInfoAutoDetect = false
    /// True while Optional Connect-Time Auto-Detection is in progress (license deferred).
    private var awaitingConnectTimeAutoDetect = false
    /// `clientCoreData` earlyCapabilityFlags (monitor layout, dynvc gfx, …).
    private var clientEarlyCapabilityFlags: UInt16 = 0
    private var channelMap: [UInt16: String] = [:]
    var shareId: UInt32 = 0
    var clientWidth = 1024
    var clientHeight = 768
    /// `clientBpp` from Client Core / Client Info.
    private var clientBpp: Int = 24
    private var joinedChannels = Set<UInt16>()
    private var expectedJoins = 0
    private var skipChannelJoin = false
    private var confirmActiveReceived = false
    private var clientInfoReceived = false
    /// Connection Finalization (MS-RDPBCGR 1.3.1.1): wait for client Sync / Control / FontList.
    private var clientSynchronizeReceived = false
    private var clientControlCooperateReceived = false
    private var clientControlRequestReceived = false
    private var clientFontListReceived = false
    private var connectionFinalizationComplete = false
    /// Refresh Rect areas pending merge into the next encode dirty set.
    var pendingRefreshRects: [CGRect] = []
    private var serverPublicKeyDER: [UInt8]
    private var credSSPAuthenticated = false
    /// `outputSuppressed` — Suppress Output PDU pauses encode.
    var outputSuppressed = false
    /// late Channel Join absorption cap during Secure Settings.
    private var lateChannelJoinAbsorbed = 0

    private var credSSP: CredSSP?
    private let ntlm: NTLMServer
    public let mouse: MouseHandler
    public let keyboard: KeyboardHandler
    public let touch: TouchInput
    let input: InputInjector

    var captureTask: Task<Void, Never>?
    var captureRestartTask: Task<Void, Never>?
    private let captureTargetLock = NSLock()
    private var appliedCaptureFPS = 0
    /// Wakes the desktop loop for capture frames, encoder slots, FRAME_ACKs, and
    /// TCP send availability changes.
    let captureWake = RDPPulseSignal()
    /// Capture-consumption telemetry only; GFX tracks successful AVC output.
    var lastH264AccountedSequence: UInt64 = 0
    /// Last capture sample accepted by the progressive RemoteFX path.
    var lastRFXCaptureSequence: UInt64 = 0
    /// Damage is inspected once per capture sample, even when no tile needs sending.
    var lastRFXDamageSequence: UInt64 = 0

    lazy var vcRouter = VirtualChannelRouter(config: config)
    public let gfx = GFXPipeline()
    public let cursor: CursorTracker
    public let videoController: VideoTargetController
    public var info = SessionInfo()
    var gfxReady = false
    /// GFX enabled when client has drdynvc + dynvc-gfx and Display Mode is H.264/RemoteFX.
    var gfxPipelineEnabled = false
    /// True once Graphics DVC CREATE_RSP succeeded. A capability failure may
    /// still disable Graphics and use the negotiated RDP bitmap path.
    var graphicsChannelEverOpened = false
    /// Coalesces CLOSE-driven recreate so we do not CREATE inline in the close handler.
    var graphicsRecreateTask: Scheduled<Void>?
    var graphicsCloseCount = 0
    /// Client advertised Surface Commands in Confirm Active.
    private var clientSurfaceCommands = false
    var capsTimeoutTask: Scheduled<Void>?
    /// Force one full-frame bitmap pass after an explicit refresh request.
    var forceBitmapFullRefresh = false
    /// RFX: invalidate tile hashes so the next encode re-sends the full surface.
    var rfxNeedsFullRefresh = true
    /// Spread TILE_SIMPLE bootstrap across ticks until the FIRST queue drains.
    var rfxBootstrapSimplePending = false
    /// RFX tiles waiting to send (64×64 origins as `(x<<32)|y`). Removed only after encode succeeds.
    var rfxPendingKeys = Set<UInt64>()
    /// Tiles waiting for progressive quality upgrades (FIRST already sent).
    var rfxUpgradeKeys = Set<UInt64>()
    /// Per-tile progressive quality stage (`(x<<32)|y` → stage).
    var rfxTileStages: [UInt64: RemoteFXEncoder.TileQualityStage] = [:]
    /// Last successfully sent RFX tile content hashes (row-major, 64×64 grid).
    var rfxTileHashes: [UInt64] = []
    var rfxHashCols = 0
    var rfxHashRows = 0
    /// Pause all video submission while capture and GFX surfaces are rebuilt.
    var captureResizePending = false
    /// Bumps on each `scheduleCaptureRestart` so stale tasks cannot clear the suspend gate.
    var captureRestartGeneration: UInt64 = 0
    /// Throttle explicit Bitmap frames so we don't fill the TCP window.
    var lastBitmapSendNs: UInt64 = 0
    static let bitmapSendMinIntervalNs: UInt64 = 200_000_000
    /// Transport state is observed by the capture task and updated by NIO callbacks.
    private let transportStateLock = NSLock()
    private var channelWritableValue = true
    private var videoOutboundQueueBlockedValue = false
    private var videoFrameQueueFullValue = false
    private var graphicsUsesUDPValue = false
    private var udpConfirmedValue = false
    private var udpQueueBlockedValue = false
    private var udpFramesFullValue = false
    private var tcpQueuedBytesValue = 0
    private var unwritableSinceValue: Date?

    /// Queue admission is expressed as time at the estimated socket drain rate.
    /// byte floors only keep tiny control PDUs from toggling the gate.
    func videoOutboundQueueWatermarks() -> (high: Int, low: Int, limit: Int) {
        let bitrate = Double(videoController.serverQueueDrainBitrate)
        func bytes(for milliseconds: Double) -> Int {
            max(1, Int((bitrate * milliseconds / 8_000).rounded(.up)))
        }
        let high = max(4 * 1024, bytes(for: VideoTargetController.serverQueueBudgetMs))
        let low = max(2 * 1024, bytes(for: VideoTargetController.serverQueueResumeMs))
        let limit = max(high, bytes(for: VideoTargetController.serverQueueLimitMs))
        return (high, min(low, high), limit)
    }

    var videoOutboundQueueLimitBytes: Int {
        videoOutboundQueueWatermarks().limit
    }

    /// TCP send-buffer writability, used by bitmap and graphics that are on TCP.
    var channelWritable: Bool {
        transportStateLock.lock()
        defer { transportStateLock.unlock() }
        return channelWritableValue
    }

    /// GFX must stop before the outbound queue becomes unbounded.
    var graphicsWritable: Bool {
        transportStateLock.lock()
        defer { transportStateLock.unlock() }
        if graphicsUsesUDPValue { return !udpQueueBlockedValue && !udpFramesFullValue }
        return channelWritableValue && !videoOutboundQueueBlockedValue && !videoFrameQueueFullValue
    }

    func setVideoFrameQueueFull(_ full: Bool) {
        transportStateLock.lock()
        videoFrameQueueFullValue = full
        transportStateLock.unlock()
    }

    public var transportLabel: String {
        transportStateLock.withLock { udpConfirmedValue ? "TCP + UDP2" : "TCP" }
    }

    func noteMainEventLoop(_ loop: EventLoop) {
        guard mainEventLoop == nil else { return }
        mainEventLoop = loop
        networkAutoDetect = NetworkAutoDetect(eventLoop: loop)
    }

    /// Protocol state and DVC lifecycle belong to the main TCP event loop.
    func executeOnSessionLoop(_ body: @escaping @Sendable (RDPSession) -> Void) {
        if let loop = mainEventLoop, !loop.inEventLoop {
            loop.execute { [weak self] in if let self { body(self) } }
        } else {
            body(self)
        }
    }

    func withSessionState<Value: Sendable>(
        _ body: @escaping @Sendable (RDPSession) throws -> Value
    ) async throws -> Value {
        if let loop = mainEventLoop, !loop.inEventLoop {
            return try await loop.submit { try body(self) }.get()
        }
        return try body(self)
    }

    func setGraphicsUsesUDP(_ enabled: Bool) {
        let tcpBytes = transportStateLock.withLock { () -> Int? in
            guard graphicsUsesUDPValue != enabled else { return nil }
            graphicsUsesUDPValue = enabled
            if !enabled { udpConfirmedValue = false }
            udpQueueBlockedValue = false; udpFramesFullValue = false
            return tcpQueuedBytesValue
        }
        guard let tcpBytes else { return }
        videoController.resetNetworkPathMeasurements()
        videoController.noteServerQueue(bytes: enabled ? 0 : tcpBytes)
        updateGraphicsBackpressure()
    }
    var hostCursorHidden = false

    static let graphicsDVCName = "Microsoft::Windows::RDS::Graphics"

    /// Non-mutating view of the desktop send path (safe for status UI).
    var graphicsPathState: GraphicsPathState {
        guard gfxPipelineEnabled else { return .bitmapOnly }
        if gfxReady {
            return gfx.isPipelineReady ? .encodingGFX : .negotiatingSurfaces
        }
        if graphicsChannelEverOpened { return .recovering }
        return .awaitingGraphicsDVC
    }

    /// Live encoding path for status UI (actual codec once negotiating finishes).
    public var encodingLabel: String {
        switch graphicsPathState {
        case .encodingGFX:
            return gfx.encodingLabel
        case .bitmapOnly:
            return "Bitmap"
        case .awaitingGraphicsDVC, .negotiatingSurfaces, .recovering:
            switch config.displayMode {
            case .h264: return "H.264…"
            case .rfx: return "RemoteFX…"
            case .bitmap: return "Bitmap"
            }
        }
    }

    /// Record TCP peer for menu / diagnostics (called from NIO channelActive).
    public func notePeerHost(_ host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        info.peerAddress = trimmed
    }

    public let socket = RDPSocket()
    let displayControl = DisplayControlChannel()
    var lastActivity = Date()
    var idleWatchTask: Task<Void, Never>?

    public var clipboard: ClipboardSync? { vcRouter.channel(named: "cliprdr") as? ClipboardSync }
    public var dvc: DynamicVCManager { vcRouter.dynamicVC }

    public var onClose: (() -> Void)? {
        get { socket.onClose }
        set { socket.onClose = newValue }
    }
    public var tlsCompleted = false
    public var wantsTLS = false
    public var needsCredSSP: Bool { selectedProtocol == X224.protocolHybrid || selectedProtocol == X224.protocolHybridEx }

    public init(config: ServerConfig, serverPublicKeyDER: [UInt8] = []) {
        self.config = config
        self.videoQualityValue = config.videoQuality
        self.cursor = CursorTracker(scale: config.remotePointerScale)
        self.audioPlaybackDestinationValue = config.audioPlaybackDestination
        self.serverPublicKeyDER = serverPublicKeyDER
        self.videoController = VideoTargetController(
            bitrate: config.videoQuality.bitrateCeiling,
            fps: config.fps,
            adaptationPriority: config.videoAdaptationPriority
        )
        let mouse = MouseHandler()
        let keyboard = KeyboardHandler()
        let touch = TouchInput()
        self.mouse = mouse
        self.keyboard = keyboard
        self.touch = touch
        self.input = InputInjector(mouse: mouse, keyboard: keyboard, touch: touch)
        self.ntlm = NTLMServer(
            username: config.username,
            password: config.password,
            serverName: config.serverName
        )
        // empty password → connect WITHOUT NLA (TLS only).
        let useNLA = config.nlaEnabled && !config.password.isEmpty
        if useNLA {
            self.credSSP = CredSSP(ntlm: ntlm, serverPublicKeyDER: serverPublicKeyDER)
        } else if config.nlaEnabled && config.password.isEmpty {
            RDPLog.rdp.info("CredSSP: no password configured — connecting WITHOUT authentication")
        }
        RDPLog.verbose = config.devLog
        gfx.attachController(videoController)
        gfx.onStateChanged = { [weak self] in
            self?.executeOnSessionLoop { session in
                session.signalCaptureWake()
                session.sessionManager?.noteSessionStateChanged(session)
            }
        }
        gfx.setAudioLowLatencyMode(config.audioPlaybackDestination.sendsToController)
        if let audio = vcRouter.channel(named: "rdpsnd") as? AudioPlayback {
            audio.onFlowControlChanged = { [weak self] pressured in
                self?.gfx.setAudioQueuePressure(pressured)
            }
        }
        self.input.onUserActivity = { [weak self] in
            self?.lastActivity = Date()
            self?.sessionManager?.sharedVirtualDisplay.noteUserActivity()
        }
    }

    /// Apply a live video-quality change from Settings without reconnecting.
    public func applyVideoQuality(_ quality: VideoQualitySettings) {
        videoQualityLock.lock()
        guard videoQualityValue != quality else {
            videoQualityLock.unlock()
            return
        }
        let resolved = quality.bitrateCeiling
        let bitrateChanged = resolved != videoQualityValue.bitrateCeiling
        let increasing = resolved > videoQualityValue.bitrateCeiling
        videoQualityValue = quality
        if bitrateChanged {
            videoController.updateConfiguredBitrate(resolved)
        }
        videoQualityLock.unlock()
        if bitrateChanged {
            gfx.applyLiveControllerCaps()
            if increasing {
                gfx.requestStaticRefinement()
            }
        }
        sessionManager?.noteSessionStateChanged(self)
        RDPLog.rdp.info("RDPSession: live video quality → \(quality.mode.rawValue) (\(resolved)bps)")
    }

    public var videoQuality: VideoQualitySettings {
        videoQualityLock.withLock { videoQualityValue }
    }

    /// Apply a live FPS change from Settings / menu bar without reconnecting.
    public func applyVideoFPS(_ fps: Int) {
        videoController.updateConfiguredFPS(fps)
        gfx.applyLiveControllerCaps()
        applyCaptureTargetFPS()
        RDPLog.rdp.info("RDPSession: live video FPS → \(videoController.configuredFPS)")
    }

    /// Apply a live adaptation-priority change from Settings / menu bar without reconnecting.
    public func applyVideoAdaptationPriority(_ priority: VideoAdaptationPriority) {
        videoController.updateAdaptationPriority(priority)
        RDPLog.rdp.info("RDPSession: live adaptation priority → \(priority.rawValue)")
    }

    public func applyRemotePointerScale(_ scale: Double) {
        cursor.setScale(scale)
    }

    public func applyAudioPlaybackDestination(_ destination: AudioPlaybackDestination) {
        audioPlaybackLock.lock()
        guard audioPlaybackDestinationValue != destination else {
            audioPlaybackLock.unlock()
            return
        }
        audioPlaybackDestinationValue = destination
        audioPlaybackLock.unlock()

        let sendsToController = destination.sendsToController
        gfx.setAudioLowLatencyMode(sendsToController)
        let audio = vcRouter.channel(named: "rdpsnd") as? AudioPlayback
        if sendsToController {
            audio?.setPlaybackEnabled(true)
        } else {
            gfx.setAudioQueuePressure(false)
            audio?.setPlaybackEnabled(false)
        }
        updateSharedCaptureAudio()
        sessionManager?.noteSessionStateChanged(self)
        RDPLog.rdp.info("RDPSession: live audio playback → \(destination.rawValue)")
    }

    public var audioPlaybackDestination: AudioPlaybackDestination {
        audioPlaybackLock.lock()
        defer { audioPlaybackLock.unlock() }
        return audioPlaybackDestinationValue
    }

    var sendsAudioToController: Bool {
        audioPlaybackLock.lock()
        defer { audioPlaybackLock.unlock() }
        return audioPlaybackDestinationValue.sendsToController
    }

    var sharedCapture: SharedScreenCapture? {
        sessionManager?.sharedScreenCapture
    }

    func applyCaptureTargetFPS() {
        let fps = max(videoController.targetFPS, 1)
        captureTargetLock.lock()
        guard fps != appliedCaptureFPS else {
            captureTargetLock.unlock()
            return
        }
        appliedCaptureFPS = fps
        captureTargetLock.unlock()
        sharedCapture?.updateCaptureFPS(owner: id, fps: fps)
    }

    func updateSharedCaptureAudio() {
        sharedCapture?.updateAudio(owner: id, enabled: sendsAudioToController)
    }

    deinit {
        captureTask?.cancel()
        captureRestartTask?.cancel()
        idleWatchTask?.cancel()
        sharedCapture?.detach(owner: id)
        gfx.stop()
        vcRouter.closeAll()
    }

    // MARK: - Entry

    public func receive(_ data: [UInt8]) {
        guard phase != .terminated else { return }
        // IdleTimeout tracks input only (see input.onUserActivity) — not every TCP/GFX ACK.
        // "NIOTransport: inbound buffer exceeded 10MB, closing"
        let maxInbound = 10 * 1024 * 1024
        if buffer.count + data.count > maxInbound {
            RDPLog.rdp.info("NIOTransport: inbound buffer exceeded 10MB, closing")
            terminate()
            return
        }
        buffer.append(contentsOf: data)
        processBuffer()
    }

    /// Drain bytes that arrived while `phase ==.tls` (typically TLS ClientHello that
    /// shared a TCP segment with X.224 CR, or arrived before NIOSSL was installed).
    /// style atomic upgrade reinjects these into the SSL handler.
    public func takeTLSLeftover() -> [UInt8] {
        guard phase == .tls, !buffer.isEmpty else { return [] }
        let leftover = buffer
        buffer.removeAll(keepingCapacity: true)
        return leftover
    }

    public func notifyTLSCompleted() {
        tlsCompleted = true
        RDPLog.rdp.phase("TLS Handshake")
        if needsCredSSP && credSSP != nil {
            phase = .credssp
            RDPLog.rdp.phase("CredSSP/NLA Handshake")
        } else {
            phase = .basicSettings
            RDPLog.rdp.info("connecting WITHOUT NLA (TLS only)")
        }
        processBuffer()
    }

    @discardableResult
    func write(
        _ bytes: [UInt8],
        priority: RDPSocket.WritePriority = .control
    ) -> Bool {
        socket.write(bytes, priority: priority)
    }

    @discardableResult
    func writeX224Data(
        _ mcsPayload: [UInt8],
        priority: RDPSocket.WritePriority = .control
    ) -> Bool {
        write(X224.buildData(mcsPayload), priority: priority)
    }

    private func processBuffer() {
        switch phase {
        case .connectionInitiation:
            processX224()
        case .credssp:
            processCredSSP()
        case .basicSettings, .channelConnection, .secureSettings, .licensing, .capabilities, .connectionFinalization, .active:
            processTPKTStream()
        case .tls, .terminated:
            break
        }
    }

    // MARK: - X.224

    private func processX224() {
        RDPLog.rdp.phase("Connection Initiation")
        guard let payload = TPKT.unwrap(from: &buffer) else { return }
        guard let cr = X224.parseConnectionRequest(payload) else {
            RDPLog.rdp.error("Invalid X.224 Connection Request: \(payload.hexPreview())")
            return
        }
        RDPLog.rdp.info("X.224 CR cookie=\(cr.cookie ?? "-") requestedProtocols=0x\(String(cr.requestedProtocols, radix: 16))")

        clientRequestedProtocols = cr.requestedProtocols
        // HYBRID and HYBRID_EX both use CredSSP; EX adds early authorization.
        let nlaAvailable = credSSP != nil
        if nlaAvailable {
            if cr.requestedProtocols & X224.protocolHybrid != 0 {
                selectedProtocol = X224.protocolHybrid
            } else if cr.requestedProtocols & X224.protocolHybridEx != 0 {
                selectedProtocol = X224.protocolHybridEx
            } else {
                // Require NLA — do not accept TLS-only fallback (matches Windows Server).
                RDPLog.rdp.error(
                    "NLA required; client requestedProtocols=0x\(String(cr.requestedProtocols, radix: 16)) " +
                    "has no HYBRID — sending HYBRID_REQUIRED_BY_SERVER"
                )
                write(X224.buildNegotiationFailure(
                    failureCode: X224.failureHybridRequiredByServer,
                    srcRef: cr.srcRef
                ))
                socket.close()
                phase = .terminated
                return
            }
        } else if cr.requestedProtocols & X224.protocolSSL != 0 {
            selectedProtocol = X224.protocolSSL
        } else {
            // PROTOCOL_RDP (cleartext) only — this host requires Enhanced Security (TLS).
            RDPLog.rdp.error(
                "TLS required; client requestedProtocols=0x\(String(cr.requestedProtocols, radix: 16)) " +
                "— sending SSL_REQUIRED_BY_SERVER"
            )
            write(X224.buildNegotiationFailure(
                failureCode: X224.failureSSLRequiredByServer,
                srcRef: cr.srcRef
            ))
            socket.close()
            phase = .terminated
            return
        }

        let cc = X224.buildConnectionConfirm(selectedProtocol: selectedProtocol, srcRef: cr.srcRef)
        write(cc)
        wantsTLS = true
        phase = .tls
        switch selectedProtocol {
        case X224.protocolHybrid:
            info.securityLabel = "NLA"
        case X224.protocolHybridEx:
            info.securityLabel = "NLA-EX"
        case X224.protocolSSL:
            info.securityLabel = "TLS"
        default:
            info.securityLabel = "RDP"
        }
        RDPLog.rdp.info(
            "X.224 CC selectedProtocol=0x\(String(selectedProtocol, radix: 16)) " +
            "flags=0x\(String(X224.negFlagsDefault, radix: 16)) — awaiting TLS"
        )
        // CC is flushed by NIOInboundHandler before TLS install in the same read turn.
    }

    // MARK: - CredSSP

    private func processCredSSP() {
        guard let credSSP else {
            phase = .basicSettings
            return
        }
        guard !buffer.isEmpty else { return }

        do {
            guard let data = try takeCredSSPMessage() else { return }
            let (resp, done) = try credSSP.handle(clientData: data)
            if !resp.isEmpty { write(resp) }
            if done {
                RDPLog.rdp.info("CredSSP: Authentication successful for user=\(ntlm.authenticatedUser.isEmpty ? config.username : ntlm.authenticatedUser)")
                finishCredSSPSuccess()
                // MCS Connect-Initial may already be buffered after authInfo.
                if !buffer.isEmpty {
                    processTPKTStream()
                }
            } else if !buffer.isEmpty {
                // Another CredSSP PDU may follow in the same read.
                processCredSSP()
            }
        } catch {
            RDPLog.rdp.error("CredSSP failed: \(error)")
            // MS-CSSP: send TSRequest.errorCode (NTSTATUS) so the client fails immediately
            // instead of hanging on "配置远程电脑" until TCP close / handshake timeout.
            let status = CredSSP.ntStatus(for: error)
            RDPLog.auth.info(
                "CredSSP: sent errorCode=0x\(String(status, radix: 16)) (client will abort NLA)"
            )
            write(credSSP.encodeErrorResponse(ntStatus: status))
            let failedUser = ntlm.authenticatedUser
            sessionManager?.noteAuthenticationFailure(
                session: self,
                userName: failedUser,
                detail: "NLA/CredSSP authentication failed"
            )
            socket.close()
            phase = .terminated
        }
    }

    /// After CredSSP succeeds, HYBRID_EX requires Early User Authorization Result before MCS.
    private func finishCredSSPSuccess() {
        credSSPAuthenticated = true
        if selectedProtocol == X224.protocolHybridEx {
            // MS-RDPBCGR Early User Authorization Result PDU: 4-byte LE success (0)
            write([0x00, 0x00, 0x00, 0x00])
            RDPLog.rdp.info("CredSSP: sent Early User Authorization Result (SUCCESS)")
        }
        phase = .basicSettings
    }

    /// Consume a complete TSRequest; incomplete TLS reads stay buffered.
    private func takeCredSSPMessage() throws -> [UInt8]? {
        guard buffer.first == 0x30 else { throw CredSSP.CredSSPError.parseFailed }
        guard buffer.count >= 2 else { return nil }
        if buffer[1] & 0x80 != 0 {
            let lengthBytes = Int(buffer[1] & 0x7F)
            guard lengthBytes > 0, lengthBytes <= MemoryLayout<Int>.size else {
                throw CredSSP.CredSSPError.parseFailed
            }
            guard buffer.count >= 2 + lengthBytes else { return nil }
        }
        var o = 1
        guard let len = BER.decodeLength(buffer, offset: &o), len >= 0, len <= 10 * 1024 * 1024 - o else {
            throw CredSSP.CredSSPError.parseFailed
        }
        let total = o + len
        guard buffer.count >= total else { return nil }
        let msg = Array(buffer[0..<total])
        buffer.removeFirst(total)
        return msg
    }

    // MARK: - TPKT / MCS / Share

    private func processTPKTStream() {
        while true {
            // Fast-path input: fpInputHeader action bits == FASTPATH_INPUT_ACTION_FASTPATH (0).
            // Under TLS, flags are usually 0 — first byte is often 0x04/0x08/… NOT 0x8x.
            // (Bit 0x80 on length1 is separate; do not require it on the header byte.)
            if let first = buffer.first, (first & 0x03) == 0 {
                if buffer.count < 2 { return }
                let len: Int
                let headerLen: Int
                if buffer[1] & 0x80 != 0 {
                    guard buffer.count >= 3 else { return }
                    len = (Int(buffer[1] & 0x7F) << 8) | Int(buffer[2])
                    headerLen = 3
                } else {
                    len = Int(buffer[1])
                    headerLen = 2
                }
                guard len >= headerLen, buffer.count >= len else { return }
                let fp = Array(buffer[0..<len])
                buffer.removeFirst(len)
                handleFastPath(fp)
                continue
            }

            guard let tpdu = TPKT.unwrap(from: &buffer) else { return }
            guard let user = X224.parseData(tpdu) else {
                RDPLog.rdp.debug("Non-data X.224: \(tpdu.hexPreview())")
                continue
            }
            handleMCS(user)
        }
    }

    private func handleFastPath(_ data: [UInt8]) {
        input.handleFastPath(data)
    }

    private func handleMCS(_ data: [UInt8]) {
        if data.first == 0x7F || data.first == 0x65 {
            handleConnectInitial(data)
            return
        }
        // One X.224 Data may contain consecutive MCS Domain PDUs (e.g. ErectDomain + AttachUser).
        var offset = 0
        var handled = false
        while offset < data.count {
            let slice = Array(data[offset...])
            guard let pdu = MCS.parseDomainPDU(slice) else {
                if !handled {
                    RDPLog.rdp.debug("Unhandled MCS blob \(data.hexPreview())")
                }
                break
            }
            handled = true
            let consumed = MCS.domainPDULength(slice) ?? slice.count
            handleDomain(pdu)
            offset += max(consumed, 1)
        }
    }

    private func handleConnectInitial(_ data: [UInt8]) {
        RDPLog.rdp.phase("Basic Settings Exchange")
        guard let ci = MCS.parseConnectInitial(data) else {
            RDPLog.rdp.error("MCS Connect-Initial parse failed — Expected MCS Connect Initial (7F65), got: \(data.hexPreview())")
            return
        }
        RDPLog.rdp.info("MCS Connect Initial: length=\(data.count)")
        let client = GCC.parseClientData(fromGCCUserData: ci.userData)
        guard let core = client.core else {
            RDPLog.rdp.error("GCC: missing Client Core Data")
            terminate()
            return
        }
        guard let negotiatedRdpVersion = GCC.negotiateRdpVersion(clientVersion: core.version) else {
            RDPLog.rdp.error("GCC: unsupported client version 0x\(String(core.version, radix: 16))")
            terminate()
            return
        }
        clientWidth = Int(core.desktopWidth)
        clientHeight = Int(core.desktopHeight)
        info.clientName = core.clientName
        info.width = clientWidth
        info.height = clientHeight
        RDPLog.rdp.info("Client \(core.clientName) \(clientWidth)x\(clientHeight) earlyCapabilityFlags=0x\(String(core.earlyCapabilityFlags, radix: 16))")
        var names: [String] = []
        if let net = client.net {
            names = vcRouter.filterAcceptedChannelNames(net.channels.map(\.name))
            RDPLog.rdp.info("Client channels: \(net.channels.map(\.name).joined(separator: ", "))")
            RDPLog.rdp.info("SC_NET channels: \(names.joined(separator: ", "))")
        }

        skipChannelJoin = client.supportsSkipChannelJoin
        clientEarlyCapabilityFlags = core.earlyCapabilityFlags
        clientSupportsNetCharAutoDetect =
            (clientEarlyCapabilityFlags & GCC.csSupportNetCharAutoDetect) != 0
        if clientSupportsNetCharAutoDetect {
            RDPLog.rdp.info("Client supports Network Characteristics Auto-Detect")
        }
        let depth = Int(core.colorDepth)
        if depth == 8 || depth == 15 || depth == 16 || depth == 24 || depth == 32 {
            clientBpp = depth == 32 ? 24 : depth
        }
        channelMap[ioChannelId] = "I/O"
        var cid: UInt16 = 1004
        for n in names {
            channelMap[cid] = n
            cid += 1
        }
        msgChannelId = client.hasMsgChannel ? cid : 0
        if !names.isEmpty {
            let mapDesc = names.enumerated()
                .map { "\(1004 + $0.offset)=\($0.element)" }
                .joined(separator: ", ")
            RDPLog.rdp.info("SC_NET ids: \(mapDesc)")
        }
        let hasDrdynvc = names.contains { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == "drdynvc" }
        let clientDynvcGfx = (core.earlyCapabilityFlags & GCC.csSupportDynvcGfx) != 0
        let modeAllowsGfx = config.displayMode == .h264 || config.displayMode == .rfx
        gfxPipelineEnabled = config.gfxEnabled && hasDrdynvc && clientDynvcGfx && modeAllowsGfx
        multitransportNegotiated = gfxPipelineEnabled && client.hasMsgChannel
            && client.multitransportFlags & MultitransportPDU.capabilities == MultitransportPDU.capabilities
            && sessionManager?.multitransportListener != nil
        RDPLog.rdp.info(
            "SC_CORE: clientVersion=0x\(String(core.version, radix: 16)) " +
            "negotiated=0x\(String(negotiatedRdpVersion, radix: 16)) " +
            "(max=0x\(String(GCC.rdpVersionMax, radix: 16)))"
        )
        let gccOut = GCC.buildServerUserData(
            selectedProtocol: selectedProtocol,
            channelNames: names,
            ioChannel: ioChannelId,
            advertiseSkipChannelJoin: skipChannelJoin,
            clientRequestedProtocols: clientRequestedProtocols,
            rdpVersion: negotiatedRdpVersion,
            advertiseMsgChannel: client.hasMsgChannel,
            msgChannelId: msgChannelId,
            multitransportFlags: multitransportNegotiated ? MultitransportPDU.capabilities : 0
        )
        // user channel + I/O + each static VC from GCC::CS_NET
        expectedJoins = 2 + names.count

        // Wire virtual channel outbound path
        vcRouter.sendToChannelBatch = { [weak self] channelId, payloads, priority, onWritten in
            self?.writeVCBatch(channelId: channelId, payloads: payloads, priority: priority, onWritten: onWritten)
        }

        // GFX gate: drdynvc ∧ dynvc-gfx capability ∧ Display Mode H.264/RemoteFX
        if gfxPipelineEnabled {
            let modeLabel = config.displayMode == .rfx ? "RemoteFX" : "H.264"
            RDPLog.rdp.info("GFX: enabled (client supports drdynvc, mode=\(modeLabel))")
            attachGraphicsChannelHandlers()
        } else {
            gfx.noteDisabled(displayMode: config.displayMode.rawValue)
        }

        // Resize and touch channels do not depend on the chosen graphics codec.
        registerStandardDVCs()

        let cr = MCS.buildConnectResponse(userData: gccOut)
        writeX224Data(cr)
        RDPLog.rdp.info("Sent MCS Connect Response")

        if skipChannelJoin {
            RDPLog.rdp.info("Both sides support SKIP_CHANNELJOIN — skipping channel join phase")
            vcRouter.bindAll(from: channelMap)
            phase = .secureSettings
            RDPLog.rdp.phase("Secure Settings Exchange")
        } else {
            phase = .channelConnection
            RDPLog.rdp.phase("Channel Connection")
            RDPLog.rdp.info("Expecting channel joins for \(expectedJoins) channels")
        }
    }

    private func handleDomain(_ pdu: MCS.DomainPDU) {
        switch pdu {
        case .erectDomain:
            RDPLog.rdp.debug("MCS ErectDomain")
            // Windows App may pipeline AttachUser in the same TCP segment as a second TPKT;
            // also tolerate concatenated MCS PDUs in one X.224 Data (ErectDomain + AttachUser).
        case .attachUserRequest:
            RDPLog.rdp.info("Sent MCS Attach User Confirm (userId=\(mcsUserId))")
            writeX224Data(MCS.buildAttachUserConfirm(userId: mcsUserId))
        case .channelJoinRequest(let userId, let channelId):
            RDPLog.rdp.info("Channel Join user=\(userId) ch=\(channelId) (\(channelMap[channelId] ?? "?"))")
            // Secure Settings: absorb up to 16 late MCS Channel Join Requests.
            if phase == .secureSettings || phase == .licensing || phase == .capabilities {
                lateChannelJoinAbsorbed += 1
                if lateChannelJoinAbsorbed > 16 {
                    RDPLog.rdp.error("Channel Join absorb limit (16) exceeded — abnormal client")
                    terminate()
                    return
                }
            }
            writeX224Data(MCS.buildChannelJoinConfirm(userId: userId, channelId: channelId))
            joinedChannels.insert(channelId)
            if let name = channelMap[channelId], name != "I/O" {
                vcRouter.bind(channelId: channelId, name: name)
            }
            // enter Secure Settings only after all MCS channel joins complete.
            if !skipChannelJoin, joinedChannels.count >= expectedJoins {
                phase = .secureSettings
                RDPLog.rdp.phase("Secure Settings Exchange")
                RDPLog.rdp.info("All \(expectedJoins) channels joined — waiting for Client Info")
            }
        case .sendDataRequest(_, let channelId, let payload):
            handleSendData(channelId: channelId, payload: payload)
        case .disconnect:
            terminate()
        }
    }

    private func handleSendData(channelId: UInt16, payload: [UInt8]) {
        if channelId == ioChannelId || channelMap[channelId] == "I/O" || channelId == 1003 {
            handleIOChannel(payload)
        } else if msgChannelId != 0, channelId == msgChannelId {
            handleMessageChannel(payload)
        } else {
            vcRouter.handle(channelId: channelId, payload: payload)
        }
    }

    private func handleMessageChannel(_ payload: [UInt8]) {
        if let response = MultitransportPDU.response(payload),
           let tunnel = multitransportTunnel, response.requestID == tunnel.requestID {
            if response.result == 0 {
                multitransportClientReady = true
                maybeSwitchGraphicsToUDP()
            } else {
                RDPLog.rdp.notice("UDP2 declined by client: result=0x\(String(response.result, radix: 16))")
                stopMultitransport(recreateGraphics: true)
            }
            return
        }
        if let autoRsp = AutoDetectPDU.parseClientResponse(from: payload) {
            networkAutoDetect?.handleClientResponse(autoRsp)
            return
        }
        RDPLog.rdp.debug("MCS msg-channel PDU (\(payload.count)B) flags=0x\(payload.prefix(2).map { String(format: "%02x", $0) }.joined())")
    }

    /// NIO's private queue is separate from Channel.isWritable. Stop TCP GFX at
    /// the estimated socket drain budget and resume after the lower budget.
    func setNIOOutboundQueueBytes(_ bytes: Int) {
        let normalized = max(bytes, 0)
        let watermarks = videoOutboundQueueWatermarks()
        transportStateLock.lock()
        tcpQueuedBytesValue = normalized
        let usesUDP = graphicsUsesUDPValue
        let wasBlocked = videoOutboundQueueBlockedValue
        if wasBlocked {
            if normalized <= watermarks.low {
                videoOutboundQueueBlockedValue = false
            }
        } else if normalized >= watermarks.high {
            videoOutboundQueueBlockedValue = true
        }
        let isBlocked = videoOutboundQueueBlockedValue
        transportStateLock.unlock()

        guard !usesUDP else { return }
        videoController.noteServerQueue(bytes: normalized)

        guard isBlocked != wasBlocked else { return }
        let delayMs = Double(normalized) * 8_000
            / Double(videoController.serverQueueDrainBitrate)
        RDPLog.rdp.info(
            "NIO: video outbound queue \(isBlocked ? "high" : "low") watermark " +
            "(\(normalized)B, \(Int(delayMs))ms/\(Int(VideoTargetController.serverQueueBudgetMs))ms)"
        )
        updateGraphicsBackpressure()
        signalCaptureWake()
    }

    /// Apply the active transport’s backpressure to the Graphics encoder.
    func updateGraphicsBackpressure() {
        gfx.setSendBlocked(!graphicsWritable)
    }

    @discardableResult
    private func writeVCBatch(
        channelId: UInt16,
        payloads: [[UInt8]],
        priority: RDPSocket.WritePriority,
        onWritten: RDPSocket.WriteCompletion?
    ) -> Int? {
        guard !payloads.isEmpty else { return 0 }
        var packets: [[UInt8]] = []
        packets.reserveCapacity(payloads.count)
        for payload in payloads {
            let mcs = MCS.buildSendDataIndication(
                userId: mcsUserId,
                channelId: channelId,
                data: payload
            )
            packets.append(X224.buildData(mcs))
        }
        guard socket.writeBatch(packets, priority: priority, onWritten: onWritten) else { return nil }
        return packets.reduce(0) { $0 + $1.count }
    }

    private func handleIOChannel(_ payload: [UInt8]) {
        if !clientInfoReceived {
            // Enhanced Security still requires the basic security header on Client Info.
            guard payload.count > 4,
                  (UInt16(payload[0]) | UInt16(payload[1]) << 8) & 0x0040 != 0 else {
                RDPLog.rdp.error("Expected Client Info with SEC_INFO_PKT")
                terminate()
                return
            }
            let info = Array(payload.dropFirst(4))
            guard !needsCredSSP || credSSPAuthenticated,
                  let userName = Self.parseClientInfoUserName(info) else {
                RDPLog.rdp.error("Client Info rejected: invalid packet or incomplete NLA")
                terminate()
                return
            }
            self.info.userName = credSSPAuthenticated ? ntlm.authenticatedUser : userName
            let arc = AutoReconnectPDU.parseClientPacket(fromClientInfo: info)
            if let arc, let user = sessionManager?.validateAutoReconnect(
                logonID: arc.logonID, securityVerifier: arc.securityVerifier) {
                self.info.logonId = arc.logonID
                self.info.userName = user
                credSSPAuthenticated = true
                RDPLog.rdp.info("Client Info: auto-reconnect accepted logonId=\(arc.logonID)")
            }
            RDPLog.rdp.info("Client Info: user=\(self.info.userName) (\(info.count) bytes)")
            clientInfoReceived = true
            clientInfoAutoDetect = Self.clientInfoHasAutoDetect(info)
            beginAfterClientInfo()
            return
        }

        // Share Control PDUs have no security header after Client Info under TLS/NLA.
        let data = payload
        guard data.count >= 6 else { return }
        let pduType = UInt16(data[2]) | UInt16(data[3]) << 8
        let typeLow = pduType & 0x0F

        // Confirm Active (MS-RDPBCGR PDUTYPE_CONFIRMACTIVEPDU = 0x3 | version 0x10 → 0x13)
        if typeLow == SharePDU.pduTypeConfirmActive {
            RDPLog.rdp.info("Received Confirm Active PDU shareId=\(shareId)")
            confirmActiveReceived = true
            let clientCapabilities = SharePDU.parseConfirmActiveCapabilities(data)
            clientSurfaceCommands = clientCapabilities.hasSurfaceCommands
            cursor.setMaximumDimension(clientCapabilities.maximumPointerDimension)
            gfx.configureFrameAcknowledgement(
                maxUnacknowledgedFrameCount: clientCapabilities.maxUnacknowledgedFrameCount
            )
            RDPLog.rdp.info(
                "Confirm Active: pointerMax=\(clientCapabilities.maximumPointerDimension) " +
                "largeFlags=\(clientCapabilities.largePointerSupportFlags ?? 0) " +
                "multifragmentMax=\(clientCapabilities.multifragmentMaxRequestSize ?? 0)"
            )
            if clientSurfaceCommands {
                RDPLog.rdp.debug("Confirm Active: clientSurfaceCommands=1")
            }
            RDPLog.rdp.phase("Connection Finalization")
            phase = .connectionFinalization
            // Wait for client Synchronize / Control / Font List before server replies.
            maybeCompleteConnectionFinalization()
            return
        }

        if typeLow != SharePDU.pduTypeData {
            // Log share-control PDUs that are neither Confirm Active nor Data (helps black-screen triage).
            let head = data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
            RDPLog.rdp.debug("I/O share PDU type=0x\(String(pduType, radix: 16)) low=\(typeLow) len=\(data.count) head=[\(head)]")
        }

        if let parsed = SharePDU.parseDataPDU(data) {
            switch parsed.pduType2 {
            case SharePDU.pdutype2Input:
                input.handleSlowPathInput(parsed.payload)
            case SharePDU.pdutype2Synchronize:
                RDPLog.rdp.info("Received Synchronize PDU")
                clientSynchronizeReceived = true
                maybeCompleteConnectionFinalization()
            case SharePDU.pdutype2Control:
                handleClientControl(parsed.payload)
            case SharePDU.pdutype2Fontlist:
                RDPLog.rdp.info("Received Font List PDU")
                clientFontListReceived = true
                maybeCompleteConnectionFinalization()
            case SharePDU.pdutype2SuppressOutput:
                handleSuppressOutput(parsed.payload)
            case SharePDU.pdutype2RefreshRect:
                handleRefreshRect(parsed.payload)
            case SharePDU.pdutype2ShutdownRequest:
                handleShutdownRequest()
            default:
                RDPLog.rdp.debug("Data PDU type2=0x\(String(parsed.pduType2, radix: 16))")
            }
        }
    }

    private func handleClientControl(_ payload: [UInt8]) {
        guard payload.count >= 2 else { return }
        let action = UInt16(payload[0]) | UInt16(payload[1]) << 8
        switch action {
        case SharePDU.ctrlActionCooperate:
            RDPLog.rdp.info("Received Control Cooperate PDU")
            clientControlCooperateReceived = true
            maybeCompleteConnectionFinalization()
        case SharePDU.ctrlActionRequestControl:
            RDPLog.rdp.info("Received Control Request Control PDU")
            clientControlRequestReceived = true
            maybeCompleteConnectionFinalization()
        default:
            RDPLog.rdp.debug("Client Control action=0x\(String(action, radix: 16))")
        }
    }

    /// MS-RDPBCGR Connection Finalization: reply only after client Sync + Cooperate + Request + FontList.
    private func maybeCompleteConnectionFinalization() {
        guard phase == .connectionFinalization, !connectionFinalizationComplete else { return }
        guard confirmActiveReceived,
              clientSynchronizeReceived,
              clientControlCooperateReceived,
              clientControlRequestReceived,
              clientFontListReceived
        else { return }

        connectionFinalizationComplete = true
        writeIO(SharePDU.buildSynchronize(shareId: shareId))
        RDPLog.rdp.info("Sent Synchronize PDU")
        writeIO(SharePDU.buildControl(shareId: shareId, action: SharePDU.ctrlActionCooperate))
        RDPLog.rdp.info("Sent Control Cooperate PDU")
        writeIO(SharePDU.buildControl(shareId: shareId, action: SharePDU.ctrlActionGrantedControl))
        RDPLog.rdp.info("Sent Control Granted PDU")
        writeIO(SharePDU.buildFontMap(shareId: shareId))
        RDPLog.rdp.info("Sent Font Map PDU")
        phase = .active
        guard sessionManager?.promoteSession(self) != false else {
            RDPLog.rdp.info("SessionManager: session was replaced before activation — closing")
            terminate()
            return
        }
        sendSaveSessionInfo()
        guard phase == .active else { return }
        write(FastPathOutput.pointerDefault())
        RDPLog.rdp.info("Sent Fast-Path Pointer Default")
        RDPLog.rdp.info("RDP connection fully established! (licensed=true)")
        vcRouter.dynamicVC.sendServerCapsIfNeeded()
        maybeSwitchGraphicsToUDP()
        startContinuousAutoDetectIfNeeded()
        startDesktop()
    }

    /// Optional Connect-Time Auto-Detection (MS-RDPBCGR) before licensing when the
    /// client advertised netchar support and we have an MCS message channel.
    private func beginAfterClientInfo() {
        let canProbe = msgChannelId != 0
            && (clientSupportsNetCharAutoDetect || clientInfoAutoDetect)
            && networkAutoDetect != nil
        wireNetworkAutoDetectCallbacks()
        if canProbe {
            awaitingConnectTimeAutoDetect = true
            RDPLog.rdp.phase("Connect-Time Auto-Detection")
            networkAutoDetect?.beginConnectTime()
            return
        }
        finishAfterClientInfo()
    }

    private func finishAfterClientInfo() {
        awaitingConnectTimeAutoDetect = false
        sendLicenseValid()
        beginMultitransportIfNegotiated()
        sendDemandActive()
        startDeferredVCHandshakes()
        phase = .capabilities
    }

    private func wireNetworkAutoDetectCallbacks() {
        guard let networkAutoDetect else { return }
        networkAutoDetect.onSend = { [weak self] pdu in
            guard let self, phase != .terminated, msgChannelId != 0 else { return }
            writeVCBatch(channelId: msgChannelId, payloads: [pdu], priority: .control, onWritten: nil)
        }
        networkAutoDetect.onConnectTimeFinished = { [weak self] in
            guard let self, phase != .terminated, awaitingConnectTimeAutoDetect else { return }
            finishAfterClientInfo()
        }
        networkAutoDetect.onMetricsUpdated = { [weak self] metrics in
            guard let self, phase != .terminated else { return }
            info.autoDetectRTTMs = metrics.averageRTTMs > 0
                ? metrics.averageRTTMs
                : metrics.baseRTTMs
            info.autoDetectBandwidthKbps = metrics.bandwidthKbps
            if !transportStateLock.withLock({ graphicsUsesUDPValue }) {
                videoController.updateAutoDetect(metrics)
            }
            gfx.applyLiveControllerCaps()
            gfx.targetFPS = max(videoController.targetFPS, 1)
        }
        networkAutoDetect.onConnectionUnresponsive = { [weak self] in
            guard let self, phase == .active else { return }
            RDPLog.rdp.info("AutoDetect: three consecutive RTT probes unanswered — closing session")
            terminate()
        }
    }

    private func startContinuousAutoDetectIfNeeded() {
        guard msgChannelId != 0,
              clientSupportsNetCharAutoDetect || clientInfoAutoDetect
        else { return }
        wireNetworkAutoDetectCallbacks()
        networkAutoDetect?.startContinuous()
    }

    private func beginMultitransportIfNegotiated() {
        guard multitransportNegotiated, let loop = mainEventLoop,
              let listener = sessionManager?.multitransportListener else { return }
        do {
            let tunnel = try listener.prepare(mainLoop: loop,
                onReady: { [weak self] in self?.maybeSwitchGraphicsToUDP() },
                onData: { [weak self] bytes in
                    guard let self, self.multitransportChannelID != nil else { return }
                    if !self.vcRouter.dynamicVC.handleMultitransport(pdu: bytes) {
                        self.stopMultitransport(recreateGraphics: true)
                    }
                },
                onState: { [weak self] state in self?.updateUDPGraphicsState(state) },
                onFailure: { [weak self] in self?.stopMultitransport(recreateGraphics: true) })
            multitransportTunnel = tunnel
            writeVCBatch(channelId: msgChannelId, payloads: [tunnel.initiatePDU], priority: .control, onWritten: nil)
            RDPLog.rdp.info("Requesting reliable UDP2 multitransport with Soft-Sync")
        } catch { RDPLog.rdp.info("Multitransport unavailable; continuing on TCP") }
    }

    func maybeSwitchGraphicsToUDP() {
        guard phase == .active, multitransportClientReady, multitransportChannelID == nil,
              let tunnel = multitransportTunnel, tunnel.isReady,
              let channel = vcRouter.dynamicVC.channelId(forName: Self.graphicsDVCName),
              let loop = mainEventLoop else { return }
        vcRouter.dynamicVC.sendMultitransportBatch = { [weak tunnel] messages, priority, onWritten in
            tunnel?.send(messages, priority: priority, onWritten: onWritten)
        }
        vcRouter.dynamicVC.onSoftSyncResponse = { [weak self, weak tunnel] tunnels in
            guard let self, let tunnel, self.multitransportTunnel === tunnel,
                  tunnels.count <= 1, tunnels.allSatisfy({ $0 == MultitransportPDU.reliableUDP }) else { return }
            self.softSyncTimeout?.cancel(); self.softSyncTimeout = nil
            if tunnels.contains(MultitransportPDU.reliableUDP) { tunnel.enableInbound() }
            self.transportStateLock.withLock { self.udpConfirmedValue = true }
            RDPLog.rdp.info("Soft-Sync complete: graphics=UDP2/TLS, input/control=TCP")
        }
        guard vcRouter.dynamicVC.switchToMultitransport(channelId: channel, onTCPFlushed: { [weak tunnel] _ in
            tunnel?.enableOutbound()
        }) else { stopMultitransport(recreateGraphics: false); return }
        multitransportChannelID = channel
        setGraphicsUsesUDP(true)
        tunnel.setTargetBitrate(videoController.serverQueueDrainBitrate)
        softSyncTimeout = loop.scheduleTask(in: .seconds(10)) { [weak self] in
            self?.stopMultitransport(recreateGraphics: true)
        }
    }

    func updateUDPGraphicsState(_ state: MultitransportTunnel.State) {
        let watermarks = videoOutboundQueueWatermarks()
        let active = transportStateLock.withLock { () -> Bool in
            guard graphicsUsesUDPValue else { return false }
            udpFramesFullValue = state.framesFull
            if udpQueueBlockedValue { udpQueueBlockedValue = state.queuedBytes > watermarks.low }
            else { udpQueueBlockedValue = state.queuedBytes >= watermarks.high }
            return true
        }
        guard active else { return }
        videoController.noteServerQueue(bytes: state.queuedBytes)
        videoController.updateTransportRTT(nanoseconds: state.rttNanoseconds, measuredAt: state.rttMeasuredAt)
        multitransportTunnel?.setTargetBitrate(videoController.serverQueueDrainBitrate)
        gfx.applyLiveControllerCaps()
        updateGraphicsBackpressure()
        signalCaptureWake()
    }

    func stopMultitransport(recreateGraphics: Bool) {
        guard let tunnel = multitransportTunnel else { return }
        multitransportTunnel = nil
        softSyncTimeout?.cancel(); softSyncTimeout = nil
        let used = multitransportChannelID != nil
        multitransportChannelID = nil
        multitransportClientReady = false
        vcRouter.dynamicVC.resetMultitransport()
        vcRouter.dynamicVC.sendMultitransportBatch = nil
        vcRouter.dynamicVC.onSoftSyncResponse = nil
        tunnel.close()
        setGraphicsUsesUDP(false)
        if used, phase != .terminated {
            RDPLog.rdp.info("UDP2 tunnel ended; graphics transport returned to TCP")
        }
        if recreateGraphics && used { vcRouter.dynamicVC.closeChannel(name: Self.graphicsDVCName) }
    }

    /// INFO_AUTODETECT (0x8000) in Client Info flags.
    private static func clientInfoHasAutoDetect(_ data: [UInt8]) -> Bool {
        guard data.count >= 8 else { return false }
        let flags = UInt32(data[4]) | UInt32(data[5]) << 8 | UInt32(data[6]) << 16 | UInt32(data[7]) << 24
        return (flags & 0x0000_8000) != 0
    }

    /// AllowDisplayUpdates byte — pause/resume GFX + invalidate tiles.
    private func handleSuppressOutput(_ payload: [UInt8]) {
        let allow = payload.first ?? 1
        let wasSuppressed = outputSuppressed
        outputSuppressed = (allow == 0)
        if outputSuppressed {
            cursor.setOutputSuppressed(true)
            RDPLog.rdp.info("Suppress Output: pausing display updates")
            gfx.pauseSending()
        } else if wasSuppressed {
            cursor.setOutputSuppressed(false)
            RDPLog.rdp.info("suppress-output lift")
            forceBitmapFullRefresh = true
            pendingRefreshRects.removeAll(keepingCapacity: true)

            guard gfxReady else {
                signalCaptureWake()
                return
            }
            do {
                try gfx.start(width: clientWidth, height: clientHeight)
                updateGraphicsBackpressure()
                resetRFXPending()
                RDPLog.rdp.info(
                    "GFX: output resume rebuilt surface generation \(clientWidth)x\(clientHeight)"
                )
            } catch {
                RDPLog.rdp.error("GFX: output resume rebuild failed: \(error)")
            }
            signalCaptureWake()
        }
    }

    /// Refresh Rect PDU (MS-RDPBCGR 2.2.11.2.1) — invalidate listed inclusive rectangles.
    private func handleRefreshRect(_ payload: [UInt8]) {
        // numberOfAreas (1) + pad3Octets (3) + TS_RECTANGLE16[numberOfAreas]
        guard payload.count >= 4 else {
            RDPLog.rdp.error("Refresh Rect: PDU too short (\(payload.count))")
            return
        }
        let count = Int(payload[0])
        var rects: [CGRect] = []
        var o = 4
        for _ in 0..<count {
            guard o + 8 <= payload.count else { break }
            let left = Int(UInt16(payload[o]) | UInt16(payload[o + 1]) << 8)
            let top = Int(UInt16(payload[o + 2]) | UInt16(payload[o + 3]) << 8)
            let right = Int(UInt16(payload[o + 4]) | UInt16(payload[o + 5]) << 8)
            let bottom = Int(UInt16(payload[o + 6]) | UInt16(payload[o + 7]) << 8)
            o += 8
            guard right >= left, bottom >= top else { continue }
            rects.append(CGRect(
                x: left,
                y: top,
                width: right - left + 1,
                height: bottom - top + 1
            ))
        }
        if rects.isEmpty {
            RDPLog.rdp.info("Refresh Rect: no valid areas — full refresh")
            forceBitmapFullRefresh = true
            gfx.requestForceIDR(reason: "refresh rect (empty)")
            return
        }
        let desktop = CGRect(x: 0, y: 0, width: clientWidth, height: clientHeight)
        let coversFull = rects.contains { $0.integral == desktop.integral }
            || rects.reduce(CGRect.null) { $0.union($1) }.integral.contains(desktop.integral)
        if coversFull {
            RDPLog.rdp.info("Refresh Rect: full desktop (\(rects.count) area(s))")
            forceBitmapFullRefresh = true
            gfx.requestForceIDR(reason: "refresh rect (full)")
        } else {
            RDPLog.rdp.info("Refresh Rect: \(rects.count) area(s)")
            pendingRefreshRects.append(contentsOf: rects)
            gfx.requestForceIDR(reason: "refresh rect")
        }
    }

    /// A logged-on session denies host shutdown and remains connected until the
    /// client sends an MCS Disconnect Provider Ultimatum (MS-RDPBCGR 1.3.1.4.1).
    func handleShutdownRequest() {
        RDPLog.rdp.info("Received Shutdown Request → sending Denied; awaiting client disconnect")
        writeIO(SharePDU.buildShutdownDenied(shareId: shareId))
    }

    /// style: start static VC handshakes only after Client Info + License + Demand Active.
    private func startDeferredVCHandshakes() {
        (vcRouter.channel(named: "cliprdr") as? ClipboardSync)?.startHandshakeIfNeeded()
        (vcRouter.channel(named: "rdpsnd") as? AudioPlayback)?.startHandshakeIfNeeded()
    }

    static func parseClientInfoUserName(_ data: [UInt8]) -> String? {
        guard data.count >= 18 else { return nil }
        let flags = UInt32(data[4]) | UInt32(data[5]) << 8 | UInt32(data[6]) << 16 | UInt32(data[7]) << 24
        let cbDomain = Int(UInt16(data[8]) | UInt16(data[9]) << 8)
        let cbUser = Int(UInt16(data[10]) | UInt16(data[11]) << 8)
        let unicode = (flags & 0x0000_0010) != 0 // INFO_UNICODE
        let nullLen = unicode ? 2 : 1
        // cb* excludes each field's mandatory null terminator.
        let offset = 18 + cbDomain + nullLen
        let end = offset + cbUser
        guard cbDomain % nullLen == 0, cbUser % nullLen == 0, end + nullLen <= data.count,
              data[(offset - nullLen)..<offset].allSatisfy({ $0 == 0 }),
              data[end..<(end + nullLen)].allSatisfy({ $0 == 0 }) else { return nil }
        return String(bytes: data[offset..<end], encoding: unicode ? .utf16LittleEndian : .ascii)
    }

    private func sendSaveSessionInfo() {
        if let manager = sessionManager {
            guard let issued = manager.issueAutoReconnectCookie(for: self) else {
                terminate()
                return
            }
            info.logonId = issued.logonId
            writeIO(SharePDU.buildSaveSessionInfoLogonExtended(
                shareId: shareId,
                logonId: issued.logonId,
                autoReconnectCookie: issued.cookie
            ))
            RDPLog.rdp.info("Sent Save Session Info PDU (LOGON_EXTENDED + ARC logonId=\(issued.logonId))")
            autoReconnectRefresh?.cancel()
            autoReconnectRefresh = mainEventLoop?.scheduleTask(in: .seconds(3600)) { [weak self] in
                guard let self, phase == .active else { return }
                sendSaveSessionInfo()
            }
        } else {
            writeIO(SharePDU.buildSaveSessionInfoPlainNotify(shareId: shareId))
            RDPLog.rdp.info("Sent Save Session Info PDU (PLAIN_NOTIFY)")
        }
    }

    private func sendLicenseValid() {
        RDPLog.rdp.phase("Licensing")
        // PREAMBLE_VERSION_3_0 only
        // do NOT set EXTENDED_ERROR_MSG_SUPPORTED (mstsc crashes in server mode).
        var err: [UInt8] = []
        err.appendU32(0x0000_0007) // STATUS_VALID_CLIENT
        err.appendU32(0x0000_0002) // ST_NO_TRANSITION
        err.appendU16(0x0004) // bbBlob.wBlobType = BB_ERROR_BLOB
        err.appendU16(0) // bbBlob.wBlobLen

        var lic: [UInt8] = []
        lic.append(0xFF) // ERROR_ALERT
        lic.append(0x03) // PREAMBLE_VERSION_3_0
        lic.appendU16(UInt16(4 + err.count))
        lic.append(contentsOf: err)

        var pkt: [UInt8] = []
        pkt.appendU16(0x0080) // SEC_LICENSE_PKT
        pkt.appendU16(0)
        pkt.append(contentsOf: lic)
        writeIORaw(pkt)
        info.licensed = true
        RDPLog.rdp.info("Sent License Valid Client PDU")
        RDPLog.rdp.info("License: STATUS_VALID_CLIENT (unlicensed Mac host — full RDPELE N/A)")
    }

    private func sendDemandActive() {
        RDPLog.rdp.phase("Capabilities Exchange")
        let w = config.width > 0 ? config.width : clientWidth
        let h = config.height > 0 ? config.height : clientHeight
        // Advertise the same even-sized desktop used by NV12 capture and GFX.
        clientWidth = min(max(w, 200), 8192) & ~1
        clientHeight = min(max(h, 200), 8192) & ~1
        // shareId = 0x10000 + mcs userId; pduSource = mcs userId
        // init uses random(0..0xFFFE)+0x10000 — keep client-compatible stable id.
        shareId = 0x1_0000 + UInt32(mcsUserId)
        let pdu = SharePDU.buildDemandActive(
            shareId: shareId,
            channelId: mcsUserId,
            width: clientWidth,
            height: clientHeight
        )
        writeIO(pdu)
        RDPLog.rdp.info("Sent Demand Active PDU (\(clientWidth)x\(clientHeight)) shareId=0x\(String(shareId, radix: 16))")
        // Monitor Layout when client earlyCapabilityFlags & 0x40.
        if clientEarlyCapabilityFlags & 0x0040 != 0 {
            let layout = SharePDU.buildMonitorLayout(
                shareId: shareId,
                width: clientWidth,
                height: clientHeight
            )
            writeIO(layout)
            RDPLog.rdp.info("Sent Monitor Layout PDU (pduSource=0)")
        }
    }

    func writeIO(_ sharePdu: [UInt8]) {
        // Enhanced RDP Security (TLS/NLA) + ENCRYPTION_METHOD_NONE: Share PDUs have NO security header.
        // (License PDU still uses SEC_LICENSE_PKT via writeIORaw.)
        writeIORaw(sharePdu)
    }

    func writeIORaw(_ payload: [UInt8]) {
        let mcs = MCS.buildSendDataIndication(userId: mcsUserId, channelId: ioChannelId, data: payload)
        writeX224Data(mcs)
    }

    /// One TCP flush for many Share PDUs — avoids hundreds of writeAndFlush per bitmap frame.
    func writeIOBatch(_ sharePdus: [[UInt8]]) {
        guard !sharePdus.isEmpty else { return }
        var combined: [UInt8] = []
        combined.reserveCapacity(sharePdus.reduce(0) { $0 + $1.count + 64 })
        for pdu in sharePdus {
            let mcs = MCS.buildSendDataIndication(userId: mcsUserId, channelId: ioChannelId, data: pdu)
            combined.append(contentsOf: X224.buildData(mcs))
        }
        write(combined)
    }

    func setChannelWritable(_ writable: Bool) {
        transportStateLock.lock()
        let wasWritable = channelWritableValue
        let since: Date?
        if writable {
            since = unwritableSinceValue
            unwritableSinceValue = nil
        } else {
            since = nil
            if wasWritable {
                unwritableSinceValue = Date()
            }
        }
        channelWritableValue = writable
        let usesUDP = graphicsUsesUDPValue
        transportStateLock.unlock()

        if writable {
            if let since {
                let delayMs = Date().timeIntervalSince(since) * 1000
                RDPLog.rdp.info(String(format: "NIO: channel writable=true (delay %.0fms)", delayMs))
                if delayMs >= Self.tcpBackpressureLogThresholdMs {
                    RDPLog.rdp.info(String(format: "NIO: TCP backpressure (%.0fms)", delayMs))
                }
            } else if !wasWritable {
                RDPLog.rdp.info("NIO: channel writable=true")
            }
        } else if wasWritable {
            RDPLog.rdp.info("NIO: TCP channel writable=false (send buffer full)")
        }
        guard !usesUDP else { return }
        updateGraphicsBackpressure()
        if wasWritable != writable {
            signalCaptureWake()
        }
    }

    func hideHostCursorIfNeeded() {
        guard !hostCursorHidden, let sessionManager else { return }
        sessionManager.retainHostCursorHidden()
        hostCursorHidden = true
    }

    func showHostCursorIfNeeded() {
        guard hostCursorHidden else { return }
        sessionManager?.releaseHostCursorHidden()
        hostCursorHidden = false
    }

    /// Settings changed prevent-system / prevent-display sleep.
    public func reapplyPowerAssertions() {
        sessionManager?.sharedVirtualDisplay.reapplyWakeAssertions()
    }

    public func terminate() {
        executeOnSessionLoop { $0.terminateOnSessionLoop() }
    }

    private func terminateOnSessionLoop() {
        // Idempotent — NIO channelInactive / socket.close can re-enter.
        guard phase != .terminated else { return }
        if phase == .credssp, let credSSP, credSSP.state == .challengeSent {
            RDPLog.rdp.info(
                "CredSSP: session closed after Challenge with no Authenticate " +
                "(client likely abandoned NLA / fell back to TLS)"
            )
        }
        phase = .terminated
        stopMultitransport(recreateGraphics: false)
        networkAutoDetect?.stop()
        awaitingConnectTimeAutoDetect = false
        resetRFXPending()
        captureTask?.cancel()
        captureRestartTask?.cancel()
        captureRestartTask = nil
        idleWatchTask?.cancel()
        capsTimeoutTask?.cancel()
        capsTimeoutTask = nil
        graphicsRecreateTask?.cancel()
        graphicsRecreateTask = nil
        autoReconnectRefresh?.cancel()
        autoReconnectRefresh = nil
        sharedCapture?.detach(owner: id)
        // Shared VD and shared capture live on SessionManager and are released
        // after the last active session leaves.
        cursor.stop()
        showHostCursorIfNeeded()
        gfx.stop()
        gfxReady = false
        graphicsChannelEverOpened = false
        vcRouter.closeAll()
        socket.close()
    }

}
