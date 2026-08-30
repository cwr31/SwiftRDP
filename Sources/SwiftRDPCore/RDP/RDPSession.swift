import Foundation
import NIOCore
import CoreVideo
import CoreGraphics

final class RDPPulseSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        lock.lock()
        generation &+= 1
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume()
    }

    func wait(timeoutNanoseconds: UInt64) async {
        guard timeoutNanoseconds > 0 else { return }
        let observed = currentGeneration()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.waitForSignal(after: observed) }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    private func currentGeneration() -> UInt64 {
        lock.lock()
        let value = generation
        lock.unlock()
        return value
    }

    private func waitForSignal(after observed: UInt64) async {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                lock.lock()
                let ready = generation != observed || Task.isCancelled
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
    private static let tcpBackpressureLogThresholdMs = 50.0
    private let networkAutoDetect = NetworkAutoDetect()
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

    /// Aspect-fit content rect inside the RDP desktop (mouse / encode letterbox).
    var captureContentLayout = DisplayContentLayout(
        desktopWidth: 1024,
        desktopHeight: 768,
        contentWidth: 1024,
        contentHeight: 768,
        offsetX: 0,
        offsetY: 0
    )
    var captureTask: Task<Void, Never>?
    var captureRestartTask: Task<Void, Never>?
    private let captureTargetLock = NSLock()
    private var appliedCaptureFPS = 0
    /// Wakes the desktop loop for capture frames, encoder slots, FRAME_ACKs, and
    /// TCP send availability changes.
    let captureWake = RDPPulseSignal()
    /// Last SCK sample submitted to H.264. Pending refresh requests may resubmit it.
    var lastH264CaptureSequence: UInt64 = 0
    /// Last capture sample accepted by the progressive RemoteFX path.
    var lastRFXCaptureSequence: UInt64 = 0

    lazy var vcRouter = VirtualChannelRouter(config: config)
    public let gfx = GFXPipeline()
    public let cursor: CursorTracker
    public let videoController: VideoTargetController
    public var info = SessionInfo()
    public let desktopComposition = DesktopComposition()
    let virtualDisplay = VirtualDisplayManager()
    var gfxReady = false
    /// GFX enabled when client has drdynvc + dynvc-gfx and Display Mode is H.264/RemoteFX.
    var gfxPipelineEnabled = false
    /// True once Graphics DVC CREATE_RSP succeeded. A capability failure may
    /// still disable Graphics and use the negotiated RDP bitmap path.
    var graphicsChannelEverOpened = false
    /// Coalesces CLOSE-driven recreate so we do not CREATE inline in the close handler.
    var graphicsRecreatePending = false
    var graphicsCloseCount = 0
    /// Client advertised Surface Commands in Confirm Active.
    private var clientSurfaceCommands = false
    var capsTimeoutTask: Task<Void, Never>?
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
    /// Throttle empty-dirty full-grid tile-diff (VirtualDisplay often omits dirtyRects).
    var rfxLastHashScanNs: UInt64 = 0
    /// Last source/destination geometry logged for RFX scaling.
    var rfxLoggedScaleGeometry: (sourceWidth: Int, sourceHeight: Int, width: Int, height: Int)?
    /// Pause RFX encode while DISP/rebind restarts capture + GFX surfaces.
    var rfxSuspendEncodeForResize = false
    /// Bumps on each `scheduleCaptureRestart` so stale tasks cannot clear the suspend gate.
    var captureRestartGeneration: UInt64 = 0
    /// Throttle explicit Bitmap frames so we don't fill the TCP window.
    var lastBitmapSendNs: UInt64 = 0
    static let bitmapSendMinIntervalNs: UInt64 = 200_000_000
    /// Transport state is observed by the capture task and updated by NIO callbacks.
    private let transportStateLock = NSLock()
    private var channelWritableValue = true
    private var videoOutboundQueueBlockedValue = false
    private var unwritableSinceValue: Date?

    /// Queue admission is expressed as time at the estimated socket drain rate.
    /// byte floors only keep tiny control PDUs from toggling the gate.
    func videoOutboundQueueWatermarks() -> (high: Int, low: Int, limit: Int) {
        let bitrate = Double(videoController.serverQueueDrainBitrate)
        func bytes(for milliseconds: Double) -> Int {
            max(1, Int((bitrate * milliseconds / 8_000).rounded(.up)))
        }
        let high = max(32 * 1024, bytes(for: VideoTargetController.serverQueueBudgetMs))
        let low = max(8 * 1024, bytes(for: VideoTargetController.serverQueueResumeMs))
        let limit = max(high, bytes(for: VideoTargetController.serverQueueLimitMs))
        return (high, min(low, high), limit)
    }

    var videoOutboundQueueLimitBytes: Int {
        videoOutboundQueueWatermarks().limit
    }

    /// TCP send-buffer backpressure (NIO writability) — pause GFX/bitmap when unwritable.
    var channelWritable: Bool {
        transportStateLock.lock()
        defer { transportStateLock.unlock() }
        return channelWritableValue
    }

    /// GFX must stop before the outbound queue becomes unbounded.
    var graphicsWritable: Bool {
        transportStateLock.lock()
        defer { transportStateLock.unlock() }
        return channelWritableValue && !videoOutboundQueueBlockedValue
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
    let geometryDVC = GeometryDVChannel()
    var lastActivity = Date()
    var idleWatchTask: Task<Void, Never>?

    public var clipboard: ClipboardSync? { vcRouter.channel(named: "cliprdr") as? ClipboardSync }
    public var dvc: DynamicVCManager { vcRouter.dynamicVC }

    public var onWrite: (([UInt8]) -> Void)? {
        get { socket.onWrite }
        set { socket.onWrite = newValue }
    }
    public var onClose: (() -> Void)? {
        get { socket.onClose }
        set { socket.onClose = newValue }
    }
    public var tlsCompleted = false
    public var wantsTLS = false
    public var needsCredSSP: Bool { selectedProtocol == X224.protocolHybrid || selectedProtocol == X224.protocolHybridEx }

    public init(config: ServerConfig, serverPublicKeyDER: [UInt8] = []) {
        self.config = config
        self.cursor = CursorTracker(scale: config.remotePointerScale)
        self.audioPlaybackDestinationValue = config.audioPlaybackDestination
        self.serverPublicKeyDER = serverPublicKeyDER
        self.videoController = VideoTargetController(
            bitrate: config.videoBitrate,
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
            serverName: config.serverName,
            ntlmStoreURL: config.ntlmURL
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
        gfx.setAudioLowLatencyMode(config.audioPlaybackDestination.sendsToController)
        if let audio = vcRouter.channel(named: "rdpsnd") as? AudioPlayback {
            audio.onFlowControlChanged = { [weak self] pressured in
                self?.gfx.setAudioQueuePressure(pressured)
            }
        }
        self.input.onUserActivity = { [weak self] in
            self?.lastActivity = Date()
            let display = self?.sessionManager?.sharedVirtualDisplay ?? self?.virtualDisplay
            display?.noteUserActivity()
        }
    }

    /// Apply a live video-quality change from Settings without reconnecting.
    public func applyVideoBitrate(_ bps: Int) {
        let resolved = ServerConfig.normalizedVideoBitrate(bps)
        let decreasing = resolved < videoController.targetBitrate
        videoController.updateConfiguredBitrate(resolved)
        gfx.applyLiveControllerCaps()
        if decreasing {
            gfx.requestForceIDR()
        }
        RDPLog.rdp.info("RDPSession: live video bitrate → \(resolved)")
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
        sharedCapture?.updateCaptureFPS(fps: fps)
    }

    func updateSharedCaptureAudio() {
        sharedCapture?.updateAudio(enabled: sendsAudioToController)
    }

    deinit {
        captureTask?.cancel()
        captureRestartTask?.cancel()
        idleWatchTask?.cancel()
        sharedCapture?.detach()
        if sessionManager == nil {
            virtualDisplay.destroy()
        }
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
            if credSSP != nil {
                RDPLog.rdp.info("TLS-only path — will verify username/password at Client Info")
            } else {
                RDPLog.rdp.info("connecting WITHOUT NLA (TLS only)")
            }
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
        // Prefer classic HYBRID (0x2) over HYBRID_EX (0x8) for broader client compatibility.
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

        // CredSSP TSRequest is raw ASN.1 SEQUENCE (0x30), not TPKT.
        if buffer.first == 0x30 || buffer.starts(with: Array("NTLMSSP\0".utf8)) {
            let data = takeCredSSPMessage()
            guard !data.isEmpty else { return }
            do {
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
                if let failResp = credSSP.encodeErrorResponse(ntStatus: status) {
                    RDPLog.auth.info(
                        "CredSSP: sent errorCode=0x\(String(status, radix: 16)) (client will abort NLA)"
                    )
                    write(failResp)
                }
                let failedUser = ntlm.authenticatedUser
                sessionManager?.noteAuthenticationFailure(
                    session: self,
                    userName: failedUser,
                    detail: "NLA/CredSSP authentication failed"
                )
                socket.close()
                phase = .terminated
            }
            return
        }

        // Incomplete ASN.1, or unexpected post-Challenge bytes (log once per buffer shape).
        let head = buffer.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " ")
        RDPLog.rdp.debug(
            "CredSSP: waiting for next TSRequest (buffered \(buffer.count)B head=[\(head)] " +
            "state=\(credSSP.state))"
        )
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

    /// Consume one ASN.1 SEQUENCE or raw NTLM blob from buffer.
    private func takeCredSSPMessage() -> [UInt8] {
        if buffer.starts(with: Array("NTLMSSP\0".utf8)) {
            let data = buffer
            buffer.removeAll(keepingCapacity: true)
            return data
        }
        guard buffer.first == 0x30 else { return [] }
        var o = 1
        guard let len = BER.decodeLength(buffer, offset: &o) else { return [] }
        let total = o + len
        guard buffer.count >= total else { return [] }
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
        if let core = client.core {
            clientWidth = Int(core.desktopWidth)
            clientHeight = Int(core.desktopHeight)
            applyDesktopSizePolicy(reason: "Connect-Initial")
            info.clientName = core.clientName
            info.width = clientWidth
            info.height = clientHeight
            RDPLog.rdp.info("Client \(core.clientName) \(clientWidth)x\(clientHeight) earlyCapabilityFlags=0x\(String(core.earlyCapabilityFlags, radix: 16))")
        }
        var names: [String] = []
        if let net = client.net {
            names = vcRouter.filterAcceptedChannelNames(net.channels.map(\.name))
            RDPLog.rdp.info("Client channels: \(net.channels.map(\.name).joined(separator: ", "))")
            RDPLog.rdp.info("SC_NET channels: \(names.joined(separator: ", "))")
        }

        skipChannelJoin = client.supportsSkipChannelJoin
        clientEarlyCapabilityFlags = client.core?.earlyCapabilityFlags ?? 0
        clientSupportsNetCharAutoDetect =
            (clientEarlyCapabilityFlags & GCC.csSupportNetCharAutoDetect) != 0
        if clientSupportsNetCharAutoDetect {
            RDPLog.rdp.info("Client supports Network Characteristics Auto-Detect")
        }
        if let core = client.core {
            // Prefer client-reported color depth when present (`clientBpp`).
            let depth = Int(core.colorDepth)
            if depth == 8 || depth == 15 || depth == 16 || depth == 24 || depth == 32 {
                clientBpp = depth == 32 ? 24 : depth
            }
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
        let clientRdpVersion = client.core?.version ?? 0
        let negotiatedRdpVersion = GCC.negotiateRdpVersion(clientVersion: clientRdpVersion)
        RDPLog.rdp.info(
            "SC_CORE: clientVersion=0x\(String(clientRdpVersion, radix: 16)) " +
            "negotiated=0x\(String(negotiatedRdpVersion, radix: 16)) " +
            "(max=0x\(String(GCC.rdpVersionMax, radix: 16)))"
        )
        let gccOut = GCC.buildServerUserData(
            selectedProtocol: selectedProtocol,
            channelNames: names,
            ioChannel: ioChannelId,
            advertiseSkipChannelJoin: skipChannelJoin,
            clientRequestedProtocols: clientRequestedProtocols,
            clientRdpVersion: clientRdpVersion,
            advertiseMsgChannel: client.hasMsgChannel,
            msgChannelId: msgChannelId
        )
        // user channel + I/O + each static VC from GCC::CS_NET
        expectedJoins = 2 + names.count

        // Wire virtual channel outbound path
        vcRouter.sendToChannel = { [weak self] channelId, payload in
            _ = self?.writeVC(channelId: channelId, payload: payload)
        }
        vcRouter.sendToChannelBatch = { [weak self] channelId, payloads, priority in
            self?.writeVCBatch(channelId: channelId, payloads: payloads, priority: priority)
        }

        // GFX gate: drdynvc ∧ dynvc-gfx capability ∧ Display Mode H.264/RemoteFX
        let hasDrdynvc = names.contains { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == "drdynvc" }
        let clientDynvcGfx = ((client.core?.earlyCapabilityFlags ?? 0) & GCC.csSupportDynvcGfx) != 0
        let modeAllowsGfx = config.displayMode == .h264 || config.displayMode == .rfx
        gfxPipelineEnabled = config.gfxEnabled && hasDrdynvc && clientDynvcGfx && modeAllowsGfx

        if gfxPipelineEnabled {
            let modeLabel = config.displayMode == .rfx ? "RemoteFX" : "H.264"
            RDPLog.rdp.info("GFX: enabled (client supports drdynvc, mode=\(modeLabel))")
            attachGraphicsChannelHandlers()
            // MS-RDPEDYC: server CREATE_REQ after CAPS. Priority 0 = REAL_TIME.
            vcRouter.dynamicVC.onCapsExchanged = { [weak self] in
                guard let self, self.gfxPipelineEnabled else { return }
                self.requestGraphicsCreate(reason: .capsExchanged, delay: 0, countAsStorm: false, coalesce: false)
            }
            if vcRouter.dynamicVC.hasCompletedCapsExchange {
                vcRouter.dynamicVC.onCapsExchanged?()
            }
        } else {
            gfx.noteDisabled(displayMode: config.displayMode.rawValue)
        }

        // DVC surface — register regardless of GFX so client CreateReq succeeds.
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
        if let autoRsp = AutoDetectPDU.parseClientResponse(from: payload) {
            networkAutoDetect.handleClientResponse(autoRsp)
            return
        }
        RDPLog.rdp.debug("MCS msg-channel PDU (\(payload.count)B) flags=0x\(payload.prefix(2).map { String(format: "%02x", $0) }.joined())")
    }

    /// NIO's private queue is separate from Channel.isWritable. Stop TCP GFX at
    /// the estimated socket drain budget and resume after the lower budget.
    func setNIOOutboundQueueBytes(_ bytes: Int) {
        let normalized = max(bytes, 0)
        let watermarks = videoOutboundQueueWatermarks()
        videoController.noteServerQueue(bytes: normalized)
        transportStateLock.lock()
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

        guard isBlocked != wasBlocked else { return }
        let delayMs = Double(normalized) * 8_000
            / Double(videoController.serverQueueDrainBitrate)
        RDPLog.rdp.info(
            "NIO: video outbound queue \(isBlocked ? "high" : "low") watermark " +
            "(\(normalized)B, \(Int(delayMs))ms/\(Int(VideoTargetController.serverQueueBudgetMs))ms)"
        )
        updateGFXTCPBackpressure()
        signalCaptureWake()
    }

    /// Apply TCP backpressure to the Graphics encoder.
    func updateGFXTCPBackpressure() {
        gfx.setSendBlocked(!graphicsWritable)
    }

    @discardableResult
    private func writeVC(channelId: UInt16, payload: [UInt8]) -> Bool {
        let mcs = MCS.buildSendDataIndication(userId: mcsUserId, channelId: channelId, data: payload)
        let channelName = channelMap[channelId]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let priority: RDPSocket.WritePriority = channelName == "rdpsnd" ? .audio : .control
        return writeX224Data(mcs, priority: priority)
    }

    @discardableResult
    private func writeVCBatch(
        channelId: UInt16,
        payloads: [[UInt8]],
        priority: RDPSocket.WritePriority
    ) -> Int? {
        guard !payloads.isEmpty else { return 0 }
        var combined: [UInt8] = []
        combined.reserveCapacity(payloads.reduce(0) { $0 + $1.count + 64 })
        for payload in payloads {
            let mcs = MCS.buildSendDataIndication(
                userId: mcsUserId,
                channelId: channelId,
                data: payload
            )
            combined.append(contentsOf: X224.buildData(mcs))
        }
        guard write(combined, priority: priority) else { return nil }
        return combined.count
    }

    private func handleIOChannel(_ payload: [UInt8]) {
        if !clientInfoReceived {
            let flags = payload.count >= 2 ? UInt16(payload[0]) | UInt16(payload[1]) << 8 : 0
            let info = stripSecurityHeader(payload)
            RDPLog.rdp.debug("I/O pre-info: \(payload.count)B flags=0x\(String(flags, radix: 16)) body=\(info.count)B")

            // Security exchange (optional with TLS) — ignore and wait for Client Info
            if flags & 0x0001 != 0 { // SEC_EXCHANGE_PKT
                RDPLog.rdp.info("Security Exchange packet ignored (TLS)")
                return
            }

            // Client Info always carries SEC_INFO_PKT (0x0040), including under Enhanced RDP Security.
            if flags & 0x0040 != 0 || looksLikeClientInfo(info) {
                let creds = parseClientInfoCredentials(info)
                self.info.userName = creds.user
                let arc = parseAutoReconnectCookie(info)
                var autoReconnected = false
                if let arc, let manager = sessionManager,
                   manager.validateAutoReconnectCookie(logonId: arc.logonId, cookie: arc.cookie) {
                    autoReconnected = true
                    self.info.logonId = arc.logonId
                    credSSPAuthenticated = true
                    RDPLog.rdp.info("Client Info: auto-reconnect accepted logonId=\(arc.logonId)")
                }
                // CredSSP already authenticated: Client Info password is often empty.
                // TLS-only fallback (mobile RD Client): enforce password here.
                if !autoReconnected, config.nlaEnabled && !config.password.isEmpty && !credSSPAuthenticated {
                    let userOk = creds.user.lowercased() == config.username.lowercased()
                        || config.username == "*"
                    let passOk = creds.password == config.password
                    if !userOk || !passOk {
                        let failedUser = creds.user.isEmpty ? "?" : creds.user
                        RDPLog.rdp.error(
                            "Client Info auth failed for user=\(failedUser) " +
                            "(TLS fallback; user \(userOk ? "ok" : "mismatch"), " +
                            "password \(passOk ? "ok" : "mismatch"), body=\(info.count)B)"
                        )
                        sessionManager?.noteAuthenticationFailure(
                            session: self,
                            userName: failedUser == "?" ? "" : failedUser,
                            detail: "TLS Client Info authentication failed"
                        )
                        socket.close()
                        phase = .terminated
                        return
                    }
                    credSSPAuthenticated = true
                    RDPLog.rdp.info("Client Info: authenticated user=\(creds.user) via TLS fallback")
                } else if !autoReconnected {
                    RDPLog.rdp.info("Client Info: user=\(creds.user) (\(info.count) bytes)")
                }
                clientInfoReceived = true
                clientInfoAutoDetect = Self.clientInfoHasAutoDetect(info)
                beginAfterClientInfo()
                return
            }
            RDPLog.rdp.debug("I/O pre-info: unrecognized — still waiting for Client Info")
            return
        }

        let data = sharePayload(from: payload)
        guard data.count >= 6 else { return }
        let pduType = UInt16(data[2]) | UInt16(data[3]) << 8
        let typeLow = pduType & 0x0F

        // Confirm Active (MS-RDPBCGR PDUTYPE_CONFIRMACTIVEPDU = 0x3 | version 0x10 → 0x13)
        if typeLow == SharePDU.pduTypeConfirmActive || (pduType & 0xFF) == 0x13 {
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
        sendSaveSessionInfo()
        write(FastPathOutput.pointerDefault())
        RDPLog.rdp.info("Sent Fast-Path Pointer Default")
        RDPLog.rdp.info("RDP connection fully established! (licensed=true)")
        phase = .active
        guard sessionManager?.promoteSession(self) != false else {
            RDPLog.rdp.info("SessionManager: session was replaced before activation — closing")
            terminate()
            return
        }
        vcRouter.dynamicVC.sendServerCapsIfNeeded()
        startContinuousAutoDetectIfNeeded()
        startDesktop()
    }

    /// Optional Connect-Time Auto-Detection (MS-RDPBCGR) before licensing when the
    /// client advertised netchar support and we have an MCS message channel.
    private func beginAfterClientInfo() {
        let canProbe = msgChannelId != 0
            && (clientSupportsNetCharAutoDetect || clientInfoAutoDetect)
        wireNetworkAutoDetectCallbacks()
        if canProbe {
            awaitingConnectTimeAutoDetect = true
            RDPLog.rdp.phase("Connect-Time Auto-Detection")
            networkAutoDetect.beginConnectTime()
            return
        }
        finishAfterClientInfo()
    }

    private func finishAfterClientInfo() {
        awaitingConnectTimeAutoDetect = false
        sendLicenseValid()
        sendDemandActive()
        startDeferredVCHandshakes()
        phase = .capabilities
    }

    private func wireNetworkAutoDetectCallbacks() {
        networkAutoDetect.onSend = { [weak self] pdu in
            guard let self, self.msgChannelId != 0 else { return }
            self.writeVC(channelId: self.msgChannelId, payload: pdu)
        }
        networkAutoDetect.onConnectTimeFinished = { [weak self] in
            guard let self, self.awaitingConnectTimeAutoDetect else { return }
            self.finishAfterClientInfo()
        }
        networkAutoDetect.onMetricsUpdated = { [weak self] metrics in
            guard let self else { return }
            self.info.autoDetectRTTMs = metrics.averageRTTMs > 0
                ? metrics.averageRTTMs
                : metrics.baseRTTMs
            self.info.autoDetectBandwidthKbps = metrics.bandwidthKbps
            // Classify LAN from baseRTT (connect-time / min). Average RTT often
            // includes GFX encode+ACK delay and falsely flips sessions to WAN.
            let base = metrics.baseRTTMs > 0 ? metrics.baseRTTMs : metrics.averageRTTMs
            self.videoController.seedFromAutoDetect(
                bandwidthKbps: metrics.bandwidthKbps,
                rttMs: base
            )
            self.gfx.applyLiveControllerCaps()
            self.gfx.targetFPS = max(self.videoController.targetFPS, 1)
        }
    }

    private func startContinuousAutoDetectIfNeeded() {
        guard msgChannelId != 0,
              clientSupportsNetCharAutoDetect || clientInfoAutoDetect
        else { return }
        wireNetworkAutoDetectCallbacks()
        networkAutoDetect.shouldDeferContinuousBandwidth = { [weak self] in
            guard let self else { return false }
            return self.gfx.desktopRecentlyHot || !self.graphicsWritable
        }
        networkAutoDetect.startContinuous()
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
            lastH264CaptureSequence = 0

            guard gfxReady else {
                signalCaptureWake()
                return
            }
            do {
                try gfx.start(width: clientWidth, height: clientHeight)
                updateGFXTCPBackpressure()
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
        (vcRouter.channel(named: "disp") as? GeometryTracking)?.startHandshakeIfNeeded()
    }

    /// Share / I/O payload under Enhanced RDP Security (TLS/NLA): no SEC_* header after Client Info.
    /// only strip the 4-byte security header when Standard RDP Security encrypts,
    /// or for the initial Client Info / License packets that still carry SEC flags.
    ///
    /// Bug fixed: treating Share Control `totalLength` as SEC flags (e.g. length≥0x40 / 0x200)
    /// incorrectly dropped 4 bytes, corrupting Confirm Active → never reached Active → black screen.
    /// Some clients still prefix a 4-byte SEC header after Client Info — detect Share Control at
    /// offset 0 or 4 instead of blindly trusting/stripping.
    private func sharePayload(from payload: [UInt8]) -> [UInt8] {
        if clientInfoReceived {
            if Self.looksLikeShareControl(payload, at: 0) { return payload }
            if payload.count > 4, Self.looksLikeShareControl(payload, at: 4) {
                return Array(payload[4...])
            }
            return payload
        }
        return stripSecurityHeader(payload)
    }

    private static func looksLikeShareControl(_ data: [UInt8], at offset: Int) -> Bool {
        guard data.count >= offset + 6 else { return false }
        let pduType = UInt16(data[offset + 2]) | UInt16(data[offset + 3]) << 8
        let low = pduType & 0x0F
        // Wire type is usually (PDU_TYPE_* | 0x10) → 0x11 / 0x13 / 0x17 …
        return low == SharePDU.pduTypeDemandActive
            || low == SharePDU.pduTypeConfirmActive
            || low == SharePDU.pduTypeData
            || low == SharePDU.pduTypeDeactivateAll
            || (pduType & 0xFF) == 0x13
            || (pduType & 0xFF) == 0x17
    }

    private func stripSecurityHeader(_ payload: [UInt8]) -> [UInt8] {
        guard payload.count > 4 else { return payload }
        let flags = UInt16(payload[0]) | UInt16(payload[1]) << 8
        // Client Info / Security Exchange / License always use a 4-byte basic security header.
        // Never apply looksLikeShareControl here: some clients leave flagsHi as 0x0013/0x0017,
        // which falsely skips the strip and then parseClientInfoCredentials reads the SEC
        // header as CodePage → empty user + garbage password → false "password mismatch".
        let definitiveSEC: UInt16 = 0x0001 | 0x0040 | 0x0080 // EXCHANGE | INFO | LICENSE
        if flags & definitiveSEC != 0 {
            return Array(payload[4...])
        }
        // Weaker hints (ENCRYPT / SECURE_CHECKSUM) can collide with Share totalLength.
        let weakHints: UInt16 = 0x0008 | 0x0200
        if flags & weakHints != 0 {
            if Self.looksLikeShareControl(payload, at: 0) {
                return payload
            }
            return Array(payload[4...])
        }
        return payload
    }

    private func looksLikeClientInfo(_ data: [UInt8]) -> Bool {
        data.count >= 18
    }

    private func parseClientInfoCredentials(_ data: [UInt8]) -> (user: String, password: String) {
        // [MS-RDPBCGR] 2.2.1.11.1.1: CodePage(4)+flags(4)+cbDomain(2)+cbUserName(2)
        // +cbPassword(2)+cbAlternateShell(2)+cbWorkingDir(2), then strings.
        // cb* is the character-data size EXCLUDING the mandatory null terminator that
        // follows each field (UTF-16LE null = 2 bytes, ANSI null = 1 byte).
        guard data.count >= 18 else { return ("?", "") }
        let flags = UInt32(data[4]) | UInt32(data[5]) << 8 | UInt32(data[6]) << 16 | UInt32(data[7]) << 24
        let cbDomain = Int(UInt16(data[8]) | UInt16(data[9]) << 8)
        let cbUser = Int(UInt16(data[10]) | UInt16(data[11]) << 8)
        let cbPassword = Int(UInt16(data[12]) | UInt16(data[13]) << 8)
        let unicode = (flags & 0x0000_0001) != 0 // INFO_UNICODE
        let nullLen = unicode ? 2 : 1
        var offset = 18

        func readField(cb: Int) -> String? {
            guard cb >= 0, offset + cb + nullLen <= data.count else { return nil }
            let bytes = Array(data[offset ..< (offset + cb)])
            offset += cb + nullLen
            let raw: String?
            if unicode {
                raw = String(bytes: bytes, encoding: .utf16LittleEndian)
            } else {
                raw = String(bytes: bytes, encoding: .ascii)
            }
            return raw?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
        }

        // Domain must be consumed (often cbDomain=0 + null) so UserName starts at the right offset.
        guard readField(cb: cbDomain) != nil,
              let user = readField(cb: cbUser),
              let password = readField(cb: cbPassword) else {
            return ("?", "")
        }
        return (user.isEmpty ? "?" : user, password)
    }

    private func sendSaveSessionInfo() {
        if let manager = sessionManager {
            let issued = manager.issueAutoReconnectCookie()
            info.logonId = issued.logonId
            writeIO(SharePDU.buildSaveSessionInfoLogonExtended(
                shareId: shareId,
                logonId: issued.logonId,
                autoReconnectCookie: issued.cookie
            ))
            RDPLog.rdp.info("Sent Save Session Info PDU (LOGON_EXTENDED + ARC logonId=\(issued.logonId))")
        } else {
            writeIO(SharePDU.buildSaveSessionInfoPlainNotify(shareId: shareId))
            RDPLog.rdp.info("Sent Save Session Info PDU (PLAIN_NOTIFY)")
        }
    }

    /// Parse ARC_CS_PRIVATE_PACKET from Client Info extended info (when present).
    private func parseAutoReconnectCookie(_ data: [UInt8]) -> (logonId: UInt32, cookie: [UInt8])? {
        guard data.count >= 18 else { return nil }
        let flags = UInt32(data[4]) | UInt32(data[5]) << 8 | UInt32(data[6]) << 16 | UInt32(data[7]) << 24
        let unicode = (flags & 0x0000_0001) != 0
        let nullLen = unicode ? 2 : 1
        let cbDomain = Int(UInt16(data[8]) | UInt16(data[9]) << 8)
        let cbUser = Int(UInt16(data[10]) | UInt16(data[11]) << 8)
        let cbPassword = Int(UInt16(data[12]) | UInt16(data[13]) << 8)
        let cbAlt = Int(UInt16(data[14]) | UInt16(data[15]) << 8)
        let cbDir = Int(UInt16(data[16]) | UInt16(data[17]) << 8)
        var offset = 18
        for cb in [cbDomain, cbUser, cbPassword, cbAlt, cbDir] {
            guard offset + cb + nullLen <= data.count else { return nil }
            offset += cb + nullLen
        }
        // ExtraInfo follows fixed strings when INFO_AUTODETECT / extended present.
        // Scan remaining bytes for ARC_CS_PRIVATE_PACKET signature: cbLen=0x1C, Version=1.
        let remaining = Array(data[offset...])
        var i = 0
        while i + 28 <= remaining.count {
            let cbLen = UInt32(remaining[i]) | UInt32(remaining[i + 1]) << 8
                | UInt32(remaining[i + 2]) << 16 | UInt32(remaining[i + 3]) << 24
            let version = UInt32(remaining[i + 4]) | UInt32(remaining[i + 5]) << 8
                | UInt32(remaining[i + 6]) << 16 | UInt32(remaining[i + 7]) << 24
            if cbLen == 0x1C, version == 1 {
                let logonId = UInt32(remaining[i + 8]) | UInt32(remaining[i + 9]) << 8
                    | UInt32(remaining[i + 10]) << 16 | UInt32(remaining[i + 11]) << 24
                let cookie = Array(remaining[(i + 12)..<(i + 28)])
                return (logonId, cookie)
            }
            i += 1
        }
        return nil
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
        // Basic Settings clamp: [200, 8192]
        clientWidth = min(max(w, 200), 8192)
        clientHeight = min(max(h, 200), 8192)
        applyDesktopSizePolicy(reason: "Demand Active")
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

    /// Resolve session desktop size from auto host-display mode.
    /// Physical: always 1:1 Retina panel pixels (never keep a mismatched client desktop).
    /// Virtual: keep the client/DISP coordinate space. A virtual-display override
    /// only changes the capture source and must never rewrite the negotiated RDP size.
    func applyDesktopSizePolicy(reason: String) {
        if usesVirtualDisplay {
            return
        }
        let phys = VirtualDisplayManager.physicalDisplayPixelSize(
            preferredIdentity: config.selectedDisplayIdentity
        )
        guard phys.width > 0, phys.height > 0 else { return }
        let w = phys.width & ~1
        let h = phys.height & ~1
        if w != clientWidth || h != clientHeight {
            RDPLog.rdp.info(
                "Display: \(reason) physical mirror \(clientWidth)x\(clientHeight) → \(w)x\(h)"
            )
        }
        clientWidth = w
        clientHeight = h
    }

    /// Auto mode: Virtual Display when no usable physical panel.
    var usesVirtualDisplay: Bool {
        sessionManager?.usesVirtualDisplay
            ?? (DisplayTopology.preferredMode(policy: config.hostDisplayPolicy) == .virtualMatchClient)
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
        transportStateLock.unlock()

        if writable {
            if let since {
                let delayMs = Date().timeIntervalSince(since) * 1000
                RDPLog.rdp.info(String(format: "NIO: channel writable=true (delay %.0fms)", delayMs))
                if delayMs >= Self.tcpBackpressureLogThresholdMs {
                    RDPLog.rdp.info(String(format: "NIO: TCP backpressure (%.0fms) — GFX send gate handles pause", delayMs))
                }
            } else if !wasWritable {
                RDPLog.rdp.info("NIO: channel writable=true")
            }
        } else if wasWritable {
            RDPLog.rdp.info("NIO: channel writable=false (TCP send buffer full) — GFX send paused")
        }
        updateGFXTCPBackpressure()
        if wasWritable != writable {
            signalCaptureWake()
        }
    }

    func hideHostCursorIfNeeded() {
        guard !hostCursorHidden else { return }
        if let sessionManager {
            sessionManager.retainHostCursorHidden()
        } else {
            CGDisplayHideCursor(CGMainDisplayID())
            RDPLog.rdp.info("Cursor: host cursor hidden (client System Pointer)")
        }
        hostCursorHidden = true
    }

    func showHostCursorIfNeeded() {
        guard hostCursorHidden else { return }
        if let sessionManager {
            sessionManager.releaseHostCursorHidden()
        } else {
            CGDisplayShowCursor(CGMainDisplayID())
        }
        hostCursorHidden = false
    }

    /// Settings changed prevent-system / prevent-display sleep.
    public func reapplyPowerAssertions() {
        let display = sessionManager?.sharedVirtualDisplay ?? virtualDisplay
        display.reapplyWakeAssertions()
    }

    public func terminate() {
        // Idempotent — NIO channelInactive / socket.close can re-enter.
        guard phase != .terminated else { return }
        if phase == .credssp, let credSSP, credSSP.state == .challengeSent {
            RDPLog.rdp.info(
                "CredSSP: session closed after Challenge with no Authenticate " +
                "(client likely abandoned NLA / fell back to TLS)"
            )
        }
        phase = .terminated
        networkAutoDetect.stop()
        awaitingConnectTimeAutoDetect = false
        resetRFXPending()
        captureTask?.cancel()
        captureRestartTask?.cancel()
        captureRestartTask = nil
        idleWatchTask?.cancel()
        capsTimeoutTask?.cancel()
        capsTimeoutTask = nil
        sharedCapture?.detach()
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
