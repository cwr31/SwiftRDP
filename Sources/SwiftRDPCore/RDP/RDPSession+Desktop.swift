import Foundation
import NIOCore
import CoreVideo
import CoreGraphics
@preconcurrency import Accelerate

/// Desktop streaming path: capture loop, GFX/bitmap push, DISP resize, idle watch.
/// Kept as an `RDPSession` extension so handshake stays in `RDPSession.swift`.
extension RDPSession {

    func startDesktop() {
        guard let manager = sessionManager,
              let sharedCapture else {
            RDPLog.rdp.error("Display: cannot start without a SessionManager")
            terminate()
            return
        }
        manager.refreshHostDisplayMode(reason: "startDesktop")
        configureHostDisplay(manager)
        let target: SharedScreenCapture.Target
        do {
            target = try captureTarget(for: manager)
        } catch {
            RDPLog.rdp.error("Display: capture target unavailable: \(error)")
            terminate()
            return
        }
        hideHostCursorIfNeeded()

        sharedCapture.attach(
            owner: id,
            captureFPS: max(videoController.targetFPS, 1),
            capturesAudio: sendsAudioToController,
            onFrameAvailable: { [weak self] in
                self?.videoController.noteCaptureFrame()
                self?.signalCaptureWake()
            },
            onAudio: { [weak self] samples, rate, channels in
                guard let self, self.sendsAudioToController else { return }
                (self.vcRouter.channel(named: "rdpsnd") as? AudioPlayback)?.enqueuePCM(
                    samples,
                    sampleRate: rate,
                    channels: channels
                )
            },
            onDisplayChanged: { [weak self] in
                self?.syncInputMapping(reason: "capture display changed")
            },
            onFatalError: { [weak self] error in
                RDPLog.rdp.error("Capture became unavailable: \(error). Closing session.")
                self?.terminate()
            }
        )
        resetRFXPending()
        info.width = clientWidth
        info.height = clientHeight
        info.licensed = true
        input.keyboard.resetModifiers()
        cursor.onSendFastPath = { [weak self] pdu in
            self?.write(pdu)
        }
        mouse.onPointerMoved = { [weak self] _, _ in
            self?.cursor.requestRefresh()
        }
        cursor.start()
        syncInputMapping(reason: "startDesktop")
        armDVCCapsTimeoutWatchdog()

        captureTask = Task { [weak self] in
            do {
                try await sharedCapture.start(target: target)
                try Task.checkCancellation()
                self?.executeOnSessionLoop { session in
                    guard session.phase == .active else { return }
                    session.syncInputMapping(reason: "capture started")
                }
            } catch is CancellationError {
                return
            } catch {
                RDPLog.rdp.error("Capture failed: \(error). Closing session instead of serving a black desktop.")
                self?.terminate()
                return
            }
            // Capture + input loop: wake on new frames and retain FPS pacing.
            RDPLog.rdp.info("Display: desktop encode loop started")
            var pacer = VideoFramePacer()
            while let self, !Task.isCancelled, self.phase == .active {
                self.applyCaptureTargetFPS()
                self.gfx.targetFPS = max(self.videoController.targetFPS, 1)
                let fps = self.gfx.effectiveFPS
                let periodNs = 1_000_000_000 / UInt64(fps)
                let tickStart = DispatchTime.now().uptimeNanoseconds
                let remaining = pacer.remainingWaitNanoseconds(fps: fps, now: tickStart)
                if remaining > 0 {
                    await self.waitForCaptureWake(timeoutNs: remaining)
                    continue
                }

                let encoded = self.pushFrameReturningEncoded()

                let elapsed = DispatchTime.now().uptimeNanoseconds &- tickStart
                if encoded {
                    pacer.noteSubmission(at: tickStart)
                    if elapsed < periodNs {
                        await self.waitForCaptureWake(timeoutNs: periodNs - elapsed)
                    }
                } else if self.gfx.isEncodeWindowFull || self.gfx.isAckWindowFull {
                    // VT completion and FRAME_ACK signal this path directly. Keep a
                    // bounded timeout for TCP send availability and ACK watchdogs.
                    await self.waitForCaptureWake(timeoutNs: 100_000_000)
                } else {
                    // Idle AVC work has an explicit retry/refinement deadline.
                    // Capture, ACK and transport callbacks wake other progress.
                    let next = self.gfx.nextFrameWaitNanoseconds
                    let waitNs = self.gfx.activeCodec.isProgressive
                        ? (elapsed < periodNs ? periodNs - elapsed : periodNs)
                        : (next.flatMap { $0 > 0 ? $0 : nil } ?? 1_000_000_000)
                    await self.waitForCaptureWake(timeoutNs: waitNs)
                }
            }
        }

        startIdleWatchIfNeeded()
    }

    /// Open implemented dynamic channels after the DRDYNVC capability exchange.
    func registerStandardDVCs() {
        vcRouter.dynamicVC.onCreate(name: DisplayControlChannel.dvcName) { [weak self] channelId, send in
            guard let self else { return }
            self.displayControl.attach(send: send)
            self.displayControl.onResize = { [weak self] w, h in
                self?.handleDesktopResize(width: w, height: h)
            }
            self.vcRouter.dynamicVC.setDataHandler(channelId: channelId) { [weak self] data in
                self?.displayControl.handle(data)
            }
        }
        vcRouter.dynamicVC.onCreate(name: TouchInput.dvcName) { [weak self] channelId, send in
            guard let self else { return }
            self.touch.onUserActivity = { [weak self] in
                self?.lastActivity = Date()
                self?.sessionManager?.sharedVirtualDisplay.noteUserActivity()
            }
            self.touch.attach(send: send)
            self.vcRouter.dynamicVC.setDataHandler(channelId: channelId) { [weak self] data in
                self?.touch.handle(data)
            }
        }
        vcRouter.dynamicVC.onCapsExchanged = { [weak self] in
            guard let self, phase != .terminated else { return }
            if gfxPipelineEnabled {
                requestGraphicsCreate(reason: .capsExchanged, delay: 0, countAsStorm: false, coalesce: false)
            }
            dvc.createChannel(name: DisplayControlChannel.dvcName)
            dvc.createChannel(name: TouchInput.dvcName)
        }
        if vcRouter.dynamicVC.hasCompletedCapsExchange {
            vcRouter.dynamicVC.onCapsExchanged?()
        }
    }

    private func startIdleWatchIfNeeded() {
        guard config.idleTimeout > 0 else { return }
        let timeoutSeconds = TimeInterval(config.idleTimeout) * 60
        idleWatchTask?.cancel()
        lastActivity = Date()
        idleWatchTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.phase == .active {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                let idle = Date().timeIntervalSince(self.lastActivity)
                if idle >= timeoutSeconds {
                    RDPLog.rdp.info("IdleTimeout: disconnecting after \(self.config.idleTimeout)m")
                    self.terminate()
                    return
                }
            }
        }
    }

    /// Input uses only the layout and display actually resolved by capture.
    private func syncInputMapping(reason: String) {
        if let loop = mainEventLoop, !loop.inEventLoop {
            executeOnSessionLoop { $0.syncInputMapping(reason: reason) }
            return
        }
        guard let capture = sharedCapture,
              let layout = capture.contentLayout,
              layout.desktopWidth == clientWidth, layout.desktopHeight == clientHeight,
              capture.activeDisplayID != 0 else {
            input.setDesktopMapping(nil)
            return
        }
        let bounds = CGDisplayBounds(capture.activeDisplayID)
        guard bounds.width > 0, bounds.height > 0 else {
            input.setDesktopMapping(nil)
            return
        }
        input.setDesktopMapping(DesktopInputMapping(layout: layout, hostBounds: bounds))
        RDPLog.rdp.info(
            "Input mapping (\(reason)): desktop \(clientWidth)x\(clientHeight) " +
            "content=\(layout.contentRect) host=\(bounds)"
        )
    }

    /// Wake the desktop loop when any producer can make progress.
    func signalCaptureWake() {
        captureWake.signal()
    }

    /// Wait for capture or pipeline progress, with a timeout for periodic pacing.
    func waitForCaptureWake(timeoutNs: UInt64) async {
        await captureWake.wait(timeoutNanoseconds: timeoutNs)
    }

    /// Returns `true` when encode/send work was started this tick.
    @discardableResult
    private func pushFrameReturningEncoded() -> Bool {
        guard !outputSuppressed, !captureResizePending else { return false }

        switch graphicsPathState {
        case .encodingGFX:
            if !graphicsWritable { return false }
            return pushGFXFrame()
        case .negotiatingSurfaces, .awaitingGraphicsDVC, .recovering:
            // Wait for CAPS/surfaces, first CREATE, or recreate — never flood bitmap.
            return false
        case .bitmapOnly:
            pushBitmapIfAllowed()
            return true
        }
    }

    /// Encode one frame on the Graphics pipeline (RFX or H.264).
    /// Returns `true` when encode/send work was started.
    @discardableResult
    private func pushGFXFrame() -> Bool {
        if gfx.activeCodec.isProgressive {
            // Always prefer the newest capture sample (drop stale queued frames).
            guard let snapshot = sharedCapture?.currentFrameSnapshot() else {
                return false
            }
            let encoded = pushRFXFrame(snapshot: snapshot)
            if encoded {
                sharedCapture?.markFrameDelivered(
                    sequence: snapshot.sequence,
                    after: lastRFXCaptureSequence
                )
                lastRFXCaptureSequence = snapshot.sequence
            }
            return encoded
        }
        guard config.displayMode == .h264 || config.displayMode == .rfx else { return false }

        if let snapshot = sharedCapture?.currentFrameSnapshot() {
            guard let pb = snapshot.frame.pixelBuffer else { return false }
            switch gfx.encodeFrame(
                pixelBuffer: pb,
                captureSequence: snapshot.sequence,
                captureUptimeNanoseconds: snapshot.frame.captureUptimeNanoseconds
            ) {
            case .submitted:
                sharedCapture?.markFrameDelivered(
                    sequence: snapshot.sequence,
                    after: lastH264AccountedSequence
                )
                lastH264AccountedSequence = snapshot.sequence
                pendingRefreshRects.removeAll(keepingCapacity: true)
                return true
            case .blocked:
                return false
            }
        }
        return false
    }

    /// Bitmap update path used when Bitmap is selected or Graphics negotiation
    /// finds no codec the client can decode.
    private func pushBitmapIfAllowed() {
        guard graphicsWritable else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if lastBitmapSendNs != 0, now &- lastBitmapSendNs < Self.bitmapSendMinIntervalNs {
            return
        }
        lastBitmapSendNs = now
        pushBitmapFrame(width: clientWidth, height: clientHeight)
    }

    /// Wire Graphics DVC create/close handlers (called once when GFX is enabled).
    func attachGraphicsChannelHandlers() {
        vcRouter.dynamicVC.onCreate(name: Self.graphicsDVCName) { [weak self] channelId, _ in
            guard let self else { return }
            self.gfx.preferredCodec = self.config.displayMode == .rfx
                ? .remoteFXProgressive
                : .h264AVC420
            self.gfx.targetFPS = self.config.fps
            self.gfx.targetBitrate = self.videoQuality.bitrateCeiling
            self.gfx.attachController(self.videoController)
            self.gfx.attach(
                transport: RDPGFXDynamicChannelTransport(
                    sendFrame: { [weak self] payloads, priority, onWritten in
                        self?.vcRouter.dynamicVC.sendDataBatch(
                            channelId: channelId,
                            payloads: payloads,
                            priority: priority,
                            onWritten: onWritten
                        )
                    }
                )
            )
            self.updateGraphicsBackpressure()
            self.gfx.onWorkAvailable = { [weak self] in
                self?.signalCaptureWake()
            }
            self.gfx.onVideoFrameDropped = { [weak self] in
                self?.rfxNeedsFullRefresh = true
                self?.signalCaptureWake()
            }
            self.gfx.onPipelineFailure = { [weak self] in
                self?.executeOnSessionLoop { session in
                    guard session.phase != .terminated else { return }
                    session.vcRouter.dynamicVC.closeChannel(name: Self.graphicsDVCName)
                }
            }
            self.gfx.onCapabilityFailure = { [weak self] in
                self?.executeOnSessionLoop { session in
                    guard session.phase != .terminated else { return }
                    session.handleGraphicsCapabilityFailure()
                }
            }
            self.gfxReady = true
            self.graphicsChannelEverOpened = true
            self.resetRFXPending()
            self.vcRouter.dynamicVC.setDataHandler(channelId: channelId) { [weak self] data in
                self?.gfx.handleClientPDU(data)
            }
            self.vcRouter.dynamicVC.setCloseHandler(channelId: channelId) { [weak self] in
                self?.handleGraphicsChannelClosed()
            }
            do {
                try self.gfx.start(width: self.clientWidth, height: self.clientHeight)
                self.updateGraphicsBackpressure()
                self.graphicsCloseCount = 0
            } catch {
                RDPLog.rdp.error("GFX: start failed \(error)")
                self.gfx.noteChannelCreateFailed("\(error)")
                self.gfxReady = false
            }
            self.maybeSwitchGraphicsToUDP()
        }
    }

    private func handleGraphicsChannelClosed() {
        stopMultitransport(recreateGraphics: false)
        let shouldRecreate = gfxPipelineEnabled
        RDPLog.rdp.info(
            shouldRecreate
                ? "GFX: DVC channel closed by client — recreate"
                : "GFX: DVC closed after capability failure — Bitmap path remains active"
        )
        gfxReady = false
        gfx.stop()
        graphicsChannelEverOpened = true
        forceBitmapFullRefresh = !shouldRecreate
        resetRFXPending()
        if shouldRecreate {
            requestGraphicsCreate(reason: .channelClosed, delay: 0.3, countAsStorm: true, coalesce: true)
        }
    }

    /// Capability rejection is terminal for this Graphics negotiation. It is
    /// not a recoverable DVC close, so stop recreating and continue with the
    /// baseline RDP bitmap update path.
    private func handleGraphicsCapabilityFailure() {
        guard phase != .terminated, gfxPipelineEnabled else { return }
        RDPLog.rdp.error("GFX: no compatible client codec — disabling Graphics and using Bitmap")
        gfxPipelineEnabled = false
        gfxReady = false
        gfx.stop()
        forceBitmapFullRefresh = true
        resetRFXPending()
        vcRouter.dynamicVC.closeChannel(name: Self.graphicsDVCName)
    }

    /// Single entry for Graphics DVC CREATE (CAPS and CLOSE recreation).
    func requestGraphicsCreate(
        reason: GraphicsCreateReason,
        delay: TimeInterval,
        countAsStorm: Bool,
        coalesce: Bool
    ) {
        if let loop = mainEventLoop, !loop.inEventLoop {
            executeOnSessionLoop { session in
                session.requestGraphicsCreate(reason: reason, delay: delay,
                    countAsStorm: countAsStorm, coalesce: coalesce)
            }
            return
        }
        guard gfxPipelineEnabled, phase != .terminated else { return }
        if coalesce, graphicsRecreateTask != nil { return }
        if countAsStorm {
            graphicsCloseCount += 1
            if graphicsCloseCount > 5 {
                RDPLog.rdp.error(
                    "GFX: Graphics CLOSE storm (\(graphicsCloseCount)) — stop recreating " +
                    "(client rejected pipeline)"
                )
                return
            }
        }
        let work: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.graphicsRecreateTask = nil
            // CAPS may fire before phase == .active; allow any non-terminated session.
            guard self.phase != .terminated, self.gfxPipelineEnabled, !self.gfxReady else {
                RDPLog.rdp.info(
                    "GFX: create aborted (\(reason.rawValue), phase=\(self.phase) ready=\(self.gfxReady))"
                )
                return
            }
            RDPLog.rdp.info(
                "GFX: creating Graphics (\(reason.rawValue)" +
                (countAsStorm ? ", attempt \(self.graphicsCloseCount)" : "") + ")"
            )
            self.vcRouter.dynamicVC.createChannel(name: Self.graphicsDVCName, priority: 0)
        }

        if delay <= 0 {
            work()
        } else if let loop = mainEventLoop {
            graphicsRecreateTask?.cancel()
            graphicsRecreateTask = loop.scheduleTask(in: .nanoseconds(Int64(delay * 1_000_000_000)), work)
        }
    }

    private func configureHostDisplay(_ manager: SessionManager) {
        let display = manager.sharedVirtualDisplay
        if manager.usesVirtualDisplay {
            let params = manager.virtualDisplayParameters(
                clientWidth: clientWidth, clientHeight: clientHeight
            )
            display.createMatching(
                width: params.pixelWidth,
                height: params.pixelHeight,
                preferHiDPI: params.preferHiDPI,
                logicalWidth: params.logicalWidth,
                logicalHeight: params.logicalHeight
            )
        } else if display.active {
            display.destroy()
        }
        display.acquireWakeAssertion()
    }

    func captureTarget(for manager: SessionManager) throws -> SharedScreenCapture.Target {
        let displayID = manager.usesVirtualDisplay
            ? manager.sharedVirtualDisplay.displayID
            : DisplayTopology.physicalDisplayID(preferredIdentity: config.selectedDisplayIdentity)
        guard let displayID, displayID != 0 else { throw ScreenCapturer.CaptureError.noDisplay }
        return SharedScreenCapture.Target(
            displayID: displayID, width: clientWidth, height: clientHeight
        )
    }

    func handleDesktopResize(width: Int, height: Int) {
        let w = max(width & ~1, 2)
        let h = max(height & ~1, 2)
        guard w != clientWidth || h != clientHeight else { return }
        clientWidth = w
        clientHeight = h
        info.width = w
        info.height = h
        rebindHostDisplay(reason: "DISP resize")
    }

    /// One path for DISP requests, resolution settings and display topology changes.
    func rebindHostDisplay(reason: String) {
        if let loop = mainEventLoop, !loop.inEventLoop {
            executeOnSessionLoop { $0.rebindHostDisplay(reason: reason) }
            return
        }
        guard phase == .active, let manager = sessionManager else { return }
        configureHostDisplay(manager)
        RDPLog.rdp.info(
            "Display: rebind \(reason) mode=\(manager.hostDisplayMode.rawValue) " +
            "desktop/capture \(clientWidth)x\(clientHeight)"
        )
        scheduleCaptureRestart()
    }

    private func scheduleCaptureRestart() {
        captureRestartTask?.cancel()
        captureRestartGeneration &+= 1
        let generation = captureRestartGeneration
        captureResizePending = true
        input.setDesktopMapping(nil)
        captureRestartTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
                let target = try await self.withSessionState { session -> SharedScreenCapture.Target? in
                    guard session.phase == .active, session.captureRestartGeneration == generation,
                          let manager = session.sessionManager else { return nil }
                    let target = try session.captureTarget(for: manager)
                    // Rebuild surfaces before capture changes geometry; state stays on the TCP loop.
                    if session.gfxReady {
                        try session.gfx.start(width: session.clientWidth, height: session.clientHeight)
                        session.updateGraphicsBackpressure()
                        session.resetRFXPending()
                    }
                    return target
                }
                guard let target else { return }
                try Task.checkCancellation()
                try await self.sharedCapture?.restart(target: target)
                try Task.checkCancellation()
                try await self.withSessionState { session in
                    guard session.phase == .active, session.captureRestartGeneration == generation else { return }
                    session.syncInputMapping(reason: "DISP resize complete")
                    session.captureResizePending = false
                    session.signalCaptureWake()
                    RDPLog.rdp.info("DISP: capture restarted at \(target.width)x\(target.height)")
                }
            } catch is CancellationError {
                return
            } catch {
                self.executeOnSessionLoop { session in
                    guard session.phase == .active, session.captureRestartGeneration == generation else { return }
                    RDPLog.rdp.error("DISP: capture restart failed: \(error)")
                    session.terminate()
                }
            }
        }
    }

    /// RFX Progressive:
    /// 1) Bootstrap / new capture damage enqueue
    /// 2) Strict per-frame op budget (including TILE_SIMPLE full refresh)
    /// 3) Upgrades only after FIRST queue drains and ACK is healthy
    /// 4) Encode overload skip + latest-frame only
    private static let rfxTileSize = 64
    /// Steady-state FIRST/UPGRADE/SIMPLE ops per tick.
    private static let rfxOpBudget = 48
    /// Bootstrap TILE_SIMPLE budget (spread full refresh across ticks).
    private static let rfxBootstrapOpBudget = 64
    /// Estimated client queue delay above which RFX skips sending.
    private static let rfxHighQueueDelayMs = 200.0
    /// Only upgrade when the estimated client queue delay is this low or lower.
    private static let rfxUpgradeQueueDelayMs = 80.0

    func resetRFXPending() {
        lastRFXCaptureSequence = 0
        lastRFXDamageSequence = 0
        rfxPendingKeys.removeAll(keepingCapacity: true)
        rfxUpgradeKeys.removeAll(keepingCapacity: true)
        rfxTileStages.removeAll(keepingCapacity: true)
        rfxTileHashes.removeAll(keepingCapacity: true)
        rfxHashCols = 0
        rfxHashRows = 0
        rfxNeedsFullRefresh = true
        rfxBootstrapSimplePending = false
    }

    /// Returns `true` when an RFX frame was encoded and queued for send.
    @discardableResult
    func pushRFXFrame(snapshot: FrameHub.Snapshot) -> Bool {
        if captureResizePending {
            return false
        }
        // RFX encoding is serialized off the capture loop. Do not repeat dirty
        // hashing or tile extraction while that worker owns the slot.
        if gfx.isEncodeWindowFull {
            return false
        }
        if videoController.consumeRFXSkipFrame() {
            return false
        }
        if gfx.isAckWindowFull {
            return false
        }

        let frame = snapshot.frame
        let surface = gfx.surfaceEncodeSize
        guard frame.width == surface.width, frame.height == surface.height else { return false }
        var captureDirty = snapshot.dirtyRects(after: lastRFXDamageSequence)
        if !pendingRefreshRects.isEmpty {
            captureDirty?.append(contentsOf: pendingRefreshRects)
        }
        if !rfxNeedsFullRefresh, captureDirty?.isEmpty == true,
           rfxPendingKeys.isEmpty, rfxUpgradeKeys.isEmpty {
            lastRFXDamageSequence = snapshot.sequence
            return false
        }

        ensureRFXHashGrid(width: frame.width, height: frame.height)

        let forceSimpleFullQuality = rfxNeedsFullRefresh || rfxBootstrapSimplePending
        if rfxNeedsFullRefresh {
            rfxNeedsFullRefresh = false
            rfxBootstrapSimplePending = true
            rfxUpgradeKeys.removeAll(keepingCapacity: true)
            rfxTileStages.removeAll(keepingCapacity: true)
            for i in rfxTileHashes.indices { rfxTileHashes[i] = 0 }
            let full = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
            enqueueRFXChangedTiles(
                frame: frame,
                keys: Self.rfxTileKeys(from: [full], frameWidth: frame.width, frameHeight: frame.height)
            )
        } else if let captureDirty {
            if !captureDirty.isEmpty {
                enqueueRFXChangedTiles(
                    frame: frame,
                    keys: Self.rfxTileKeys(
                        from: captureDirty, frameWidth: frame.width, frameHeight: frame.height
                    )
                )
            }
        } else {
            enqueueRFXChangedTiles(
                frame: frame,
                keys: Self.rfxAllTileKeys(frameWidth: frame.width, frameHeight: frame.height)
            )
        }
        lastRFXDamageSequence = snapshot.sequence
        pendingRefreshRects.removeAll(keepingCapacity: true)

        let hasWork = !rfxPendingKeys.isEmpty || !rfxUpgradeKeys.isEmpty
        guard hasWork else { return false }

        // An explicit FRAME_ACK suspension is normal protocol flow, not congestion.
        // A stall recovery is a separate server-side response to repeated timeouts.
        let frameAcknowledgementsSuspended = gfx.isFrameAcknowledgementSuspended
        let stallRecovery = videoController.stallRecoveryMode
        if !frameAcknowledgementsSuspended && !stallRecovery,
           let queueDelay = videoController.lastClientQueueDelayMs,
           queueDelay > Self.rfxHighQueueDelayMs {
            return false
        }

        let firstKeys = rfxPendingKeys.sorted { a, b in
            let ay = a & 0xFFFF_FFFF
            let by = b & 0xFFFF_FFFF
            if ay != by { return ay < by }
            return (a >> 32) < (b >> 32)
        }
        // Prefer finishing FIRST paint before upgrades; keep ACK queue shallow when ACKing.
        let clientQueueAllowsUpgrade = videoController.lastClientQueueDelayMs.map {
            $0 <= Self.rfxUpgradeQueueDelayMs
        } ?? true
        let allowUpgrade = firstKeys.isEmpty && (
            frameAcknowledgementsSuspended || stallRecovery || clientQueueAllowsUpgrade
        )
        let upgradeKeys = allowUpgrade
            ? rfxUpgradeKeys.sorted { a, b in
                let ay = a & 0xFFFF_FFFF
                let by = b & 0xFFFF_FFFF
                if ay != by { return ay < by }
                return (a >> 32) < (b >> 32)
            }
            : []

        let budget = forceSimpleFullQuality ? Self.rfxBootstrapOpBudget : Self.rfxOpBudget
        let plannedFirst = Array(firstKeys.prefix(budget))
        let remain = max(0, budget - plannedFirst.count)
        let plannedUpgrade = Array(upgradeKeys.prefix(remain))
        let allKeys = plannedFirst + plannedUpgrade
        guard !allKeys.isEmpty else { return false }

        let tiles = Self.rfxTiles(from: frame, tileKeys: allKeys)
        guard !tiles.isEmpty else { return false }
        var tilesByKey: [UInt64: RemoteFXEncoder.Tile] = [:]
        tilesByKey.reserveCapacity(tiles.count)
        for tile in tiles {
            let key = (UInt64(tile.x) << 32) | UInt64(tile.y)
            tilesByKey[key] = tile
        }
        // Refuse out-of-surface tiles (MS-RDPEGFX WIRE_TO_SURFACE region must fit).
        let maxX = tiles.map { Int($0.x) + Int($0.width) }.max() ?? 0
        let maxY = tiles.map { Int($0.y) + Int($0.height) }.max() ?? 0
        if maxX > frame.width || maxY > frame.height {
            RDPLog.rdp.error(
                "GFX: RFX tiles exceed surface \(frame.width)x\(frame.height) " +
                "(extent \(maxX)x\(maxY), tiles=\(tiles.count)) — dropping frame"
            )
            return false
        }

        let sent: Bool
        var advanced: [(UInt64, RemoteFXEncoder.TileQualityStage)] = []
        if forceSimpleFullQuality ||
            ((frameAcknowledgementsSuspended || stallRecovery) && !plannedFirst.isEmpty) {
            // Bootstrap or recovery dirty tiles: TILE_SIMPLE at full quality
            // (no upgrade debt while feedback is unavailable).
            let simpleTiles = plannedFirst.compactMap { tilesByKey[$0] }
            guard !simpleTiles.isEmpty else { return false }
            let ops = simpleTiles.map { RemoteFXEncoder.TileOp.simple(tile: $0) }
            sent = gfx.encodeProgressiveOps(ops)
            if sent {
                advanced = plannedFirst.map { ($0, .full) }
            }
        } else {
            let built = RemoteFXEncoder.makeTileOps(
                tilesByKey: tilesByKey,
                stages: rfxTileStages,
                firstKeys: plannedFirst,
                upgradeKeys: plannedUpgrade,
                allowUpgrade: allowUpgrade,
                maxOps: budget
            )
            guard !built.ops.isEmpty else { return false }
            sent = gfx.encodeProgressiveOps(built.ops)
            advanced = built.advanced
        }
        guard sent else { return false }

        for (key, stage) in advanced {
            rfxTileStages[key] = stage
            rfxPendingKeys.remove(key)
            switch stage {
            case .coarse, .mid:
                rfxUpgradeKeys.insert(key)
            case .full:
                rfxUpgradeKeys.remove(key)
            case .none:
                break
            }
        }
        if rfxBootstrapSimplePending, rfxPendingKeys.isEmpty {
            rfxBootstrapSimplePending = false
        }

        if let pb = frame.pixelBuffer {
            for (key, stage) in advanced where stage == .full || stage == .coarse {
                let tx = Int(key >> 32)
                let ty = Int(key & 0xFFFF_FFFF)
                let tw = min(Self.rfxTileSize, frame.width - tx)
                let th = min(Self.rfxTileSize, frame.height - ty)
                let idx = Self.rfxHashIndex(key: key, cols: rfxHashCols)
                guard idx < rfxTileHashes.count, tw > 0, th > 0 else { continue }
                // Update hash on FIRST so we don't re-dirty while upgrading.
                if let hash = Self.rfxHashTile(pixelBuffer: pb, x: tx, y: ty, w: tw, h: th) {
                    rfxTileHashes[idx] = hash
                }
            }
        }
        if !rfxPendingKeys.isEmpty || !rfxUpgradeKeys.isEmpty {
            RDPLog.rdp.debug(
                "GFX: RFX pending \(rfxPendingKeys.count) upgrades \(rfxUpgradeKeys.count)"
            )
        }
        return true
    }

    private func ensureRFXHashGrid(width: Int, height: Int) {
        let cols = max(1, (width + Self.rfxTileSize - 1) / Self.rfxTileSize)
        let rows = max(1, (height + Self.rfxTileSize - 1) / Self.rfxTileSize)
        if cols == rfxHashCols, rows == rfxHashRows, rfxTileHashes.count == cols * rows {
            return
        }
        rfxHashCols = cols
        rfxHashRows = rows
        rfxTileHashes = [UInt64](repeating: 0, count: cols * rows)
        rfxPendingKeys.removeAll(keepingCapacity: true)
        rfxUpgradeKeys.removeAll(keepingCapacity: true)
        rfxTileStages.removeAll(keepingCapacity: true)
    }

    /// Compare candidate tiles to last-sent hashes; enqueue every changed tile.
    private func enqueueRFXChangedTiles(
        frame: CapturedFrame,
        keys: [UInt64]
    ) {
        guard !keys.isEmpty else { return }
        guard let pb = frame.pixelBuffer else {
            rfxPendingKeys.formUnion(keys)
            return
        }
        let cols = rfxHashCols
        var changed: [UInt64] = []
        changed.reserveCapacity(min(keys.count, 64))
        for key in keys {
            if rfxPendingKeys.contains(key) { continue }
            let tx = Int(key >> 32)
            let ty = Int(key & 0xFFFF_FFFF)
            let tw = min(Self.rfxTileSize, frame.width - tx)
            let th = min(Self.rfxTileSize, frame.height - ty)
            guard tw > 0, th > 0 else { continue }
            guard let hash = Self.rfxHashTile(pixelBuffer: pb, x: tx, y: ty, w: tw, h: th) else {
                changed.append(key)
                continue
            }
            let idx = Self.rfxHashIndex(key: key, cols: cols)
            if idx >= rfxTileHashes.count || rfxTileHashes[idx] != hash {
                changed.append(key)
            }
        }
        rfxPendingKeys.formUnion(changed)
        for key in changed {
            rfxTileStages[key] = RemoteFXEncoder.TileQualityStage.none
            rfxUpgradeKeys.remove(key)
        }
    }

    private static func rfxHashIndex(key: UInt64, cols: Int) -> Int {
        let tx = Int(key >> 32)
        let ty = Int(key & 0xFFFF_FFFF)
        return (ty / rfxTileSize) * cols + (tx / rfxTileSize)
    }

    private static func rfxAllTileKeys(frameWidth: Int, frameHeight: Int) -> [UInt64] {
        var keys: [UInt64] = []
        var ty = 0
        while ty < frameHeight {
            var tx = 0
            while tx < frameWidth {
                keys.append((UInt64(tx) << 32) | UInt64(ty))
                tx += rfxTileSize
            }
            ty += rfxTileSize
        }
        return keys
    }

    /// Content hash for one 64×64 tile. Include all color planes so a color-only
    /// update cannot be mistaken for an unchanged RFX tile.
    static func rfxHashTile(
        pixelBuffer pb: CVPixelBuffer,
        x: Int,
        y: Int,
        w: Int,
        h: Int
    ) -> UInt64? {
        let format = CVPixelBufferGetPixelFormatType(pb)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        switch format {
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
            let stride = CVPixelBufferGetBytesPerRow(pb)
            return rfxHashBGRALocked(
                src: base.assumingMemoryBound(to: UInt8.self),
                stride: stride, x: x, y: y, w: w, h: h
            )
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
                  let uvBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            return rfxHashNV12Locked(
                ySrc: yBase.assumingMemoryBound(to: UInt8.self),
                yStride: yStride,
                uvSrc: uvBase.assumingMemoryBound(to: UInt8.self),
                uvStride: uvStride,
                yWidth: CVPixelBufferGetWidthOfPlane(pb, 0),
                yHeight: CVPixelBufferGetHeightOfPlane(pb, 0),
                uvWidthBytes: uvStride,
                uvHeight: CVPixelBufferGetHeightOfPlane(pb, 1),
                x: x, y: y, w: w, h: h
            )
        default:
            return nil
        }
    }

    private static func rfxHashBGRALocked(
        src: UnsafePointer<UInt8>,
        stride: Int,
        x: Int,
        y: Int,
        w: Int,
        h: Int
    ) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for row in 0..<h {
            let rowBase = src.advanced(by: (y + row) * stride + x * 4)
            for col in 0..<w {
                let p = rowBase.advanced(by: col * 4)
                hash ^= UInt64(p[0])
                hash = hash &* 0x100000001b3
                hash ^= UInt64(p[1])
                hash = hash &* 0x100000001b3
                hash ^= UInt64(p[2])
                hash = hash &* 0x100000001b3
            }
        }
        return hash
    }

    private static func rfxHashYPlaneLocked(
        src: UnsafePointer<UInt8>,
        stride: Int,
        x: Int,
        y: Int,
        w: Int,
        h: Int
    ) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for row in 0..<h {
            let rowBase = src.advanced(by: (y + row) * stride + x)
            for col in 0..<w {
                hash ^= UInt64(rowBase[col])
                hash = hash &* 0x100000001b3
            }
        }
        return hash
    }

    private static func rfxHashNV12Locked(
        ySrc: UnsafePointer<UInt8>,
        yStride: Int,
        uvSrc: UnsafePointer<UInt8>,
        uvStride: Int,
        yWidth: Int,
        yHeight: Int,
        uvWidthBytes: Int,
        uvHeight: Int,
        x: Int,
        y: Int,
        w: Int,
        h: Int
    ) -> UInt64? {
        guard x >= 0, y >= 0, w > 0, h > 0,
              x + w <= yWidth, y + h <= yHeight,
              x % 2 == 0, y % 2 == 0 else {
            return nil
        }

        var hash = rfxHashYPlaneLocked(
            src: ySrc, stride: yStride, x: x, y: y, w: w, h: h
        )
        // Separate the UV plane from Y so equal byte runs in different planes
        // cannot alias into the same tile fingerprint.
        hash ^= 0x55
        hash = hash &* 0x100000001b3

        let uvX = x
        let uvY = y / 2
        let uvRight = min(((x + w + 1) / 2) * 2, uvWidthBytes)
        let uvBottom = min((y + h + 1) / 2, uvHeight)
        guard uvX >= 0, uvX < uvRight, uvY >= 0, uvY < uvBottom else {
            return nil
        }
        for row in uvY..<uvBottom {
            let rowBase = uvSrc.advanced(by: row * uvStride + uvX)
            for byte in uvX..<uvRight {
                hash ^= UInt64(rowBase[byte - uvX])
                hash = hash &* 0x100000001b3
            }
        }
        return hash
    }

    private static func rfxTileKeys(from rects: [CGRect], frameWidth: Int, frameHeight: Int) -> [UInt64] {
        var seen = Set<UInt64>()
        var keys: [UInt64] = []
        for r in rects {
            let left = max(Int(r.minX), 0)
            let top = max(Int(r.minY), 0)
            let right = min(Int(r.maxX.rounded(.up)), frameWidth)
            let bottom = min(Int(r.maxY.rounded(.up)), frameHeight)
            guard right > left, bottom > top else { continue }
            var ty = (top / rfxTileSize) * rfxTileSize
            while ty < bottom {
                var tx = (left / rfxTileSize) * rfxTileSize
                while tx < right {
                    let key = (UInt64(tx) << 32) | UInt64(ty)
                    if seen.insert(key).inserted { keys.append(key) }
                    tx += rfxTileSize
                }
                ty += rfxTileSize
            }
        }
        return keys
    }

    /// tile budget : unlicensed 128; else by dirty-tile fraction.
    private func bitmapTileBudget(
        dirtyTileCount: Int,
        frameWidth: Int,
        frameHeight: Int,
        maxTile: Int
    ) -> Int {
        let cols = max(1, (frameWidth + maxTile - 1) / maxTile)
        let rows = max(1, (frameHeight + maxTile - 1) / maxTile)
        let grid = max(cols * rows, 1)
        let fraction = Double(dirtyTileCount) / Double(grid)
        if !info.licensed { return 128 }
        // fraction ≤ 0.3 → 512; 0.3 < f ≤ 0.6 → 2048; f > 0.6 → 1024
        if fraction <= 0.3 { return 512 }
        if fraction <= 0.6 { return 2048 }
        return 1024
    }

    /// CAPS timeout → terminate (spec 3.3.2). Bitmap path is only used when there is no Graphics channel.
    func armDVCCapsTimeoutWatchdog() {
        capsTimeoutTask?.cancel()
        guard gfxPipelineEnabled, let loop = mainEventLoop else { return }
        capsTimeoutTask = loop.scheduleTask(in: .nanoseconds(Int64(DynamicVCManager.capsResponseTimeoutNs))) { [weak self] in
            guard let self, phase == .active, !gfxReady,
                  !vcRouter.dynamicVC.hasCompletedCapsExchange else { return }
            RDPLog.rdp.info("DVC: CAPS_RSP timeout (>10s) — terminating session (MS-RDPEDYC 3.3.2)")
            terminate()
        }
    }

    private func pushBitmapFrame(width w: Int, height h: Int) {
        // skip GFX/bitmap send while TCP unwritable.
        guard graphicsWritable else { return }

        // DirtyInfo maxTile=64.
        let bitmapMaxTile = 64
        if let frame = sharedCapture?.currentFrame() {
            var frame = frame
            guard frame.width == w, frame.height == h else { return }
            if frame.bgrBottomUp.isEmpty, let pb = frame.pixelBuffer {
                if let bgra = Self.pixelBufferToBGRBottomUp(pb) {
                    frame = CapturedFrame(
                        width: frame.width, height: frame.height,
                        bgrBottomUp: bgra, dirtyRects: frame.dirtyRects, pixelBuffer: pb
                    )
                }
            }
            guard !frame.bgrBottomUp.isEmpty else { return }

            var frameDirty = frame.dirtyRects ?? []
            if !pendingRefreshRects.isEmpty {
                frameDirty.append(contentsOf: pendingRefreshRects)
                pendingRefreshRects.removeAll(keepingCapacity: true)
            }

            let wantFull = forceBitmapFullRefresh || frameDirty.isEmpty
            if wantFull {
                forceBitmapFullRefresh = false
            }

            let tiles: [DirtyTile]
            let avgPct: Double
            if !wantFull {
                let dirtyFrame = CapturedFrame(
                    width: frame.width,
                    height: frame.height,
                    bgrBottomUp: frame.bgrBottomUp,
                    dirtyRects: frameDirty,
                    pixelBuffer: frame.pixelBuffer
                )
                let dirtyInfo = DirtyInfo.from(frame: dirtyFrame, maxTile: bitmapMaxTile)
                tiles = dirtyInfo.tiles
                avgPct = dirtyInfo.averagePercent
                if tiles.isEmpty { return }
            } else {
                let raw = BitmapEncoder.tiles(frame: frame, maxTile: bitmapMaxTile)
                tiles = raw.map {
                    DirtyTile(x: $0.x, y: $0.y, width: $0.w, height: $0.h, data: $0.data)
                }
                avgPct = 100
            }

            let budget = bitmapTileBudget(
                dirtyTileCount: tiles.count,
                frameWidth: frame.width,
                frameHeight: frame.height,
                maxTile: bitmapMaxTile
            )
            RDPLog.rdp.debug(String(format: " / dirty avg %.0f%% (n=%d)", avgPct, tiles.count))

            // flush threshold 16001.
            var batch: [[UInt8]] = []
            var batchBytes = 4
            for t in tiles.prefix(budget) {
                let pdu = SharePDU.buildBitmapUpdate(
                    shareId: shareId,
                    destLeft: t.x, destTop: t.y,
                    destRight: t.x + t.width - 1, destBottom: t.y + t.height - 1,
                    width: t.width, height: t.height,
                    bgrBottomUp: t.data
                )
                if pdu.isEmpty {
                    RDPLog.rdp.info("Slow-path error: bitmap tile \(t.width)x\(t.height) exceeds UINT16 payload")
                    continue
                }
                if batchBytes + pdu.count >= 16001, !batch.isEmpty {
                    writeIOBatch(batch)
                    batch.removeAll(keepingCapacity: true)
                    batchBytes = 4
                    if !graphicsWritable { return }
                }
                batch.append(pdu)
                batchBytes += pdu.count
            }
            writeIOBatch(batch)
            return
        }

        RDPLog.rdp.debug("Slow-path: no shared capture frame yet \(w)x\(h)")
    }

    private static func pixelBufferToBGRBottomUp(_ pb: CVPixelBuffer) -> [UInt8]? {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else {
            guard let bgra = copyBGRA(from: pb) else { return nil }
            let width = CVPixelBufferGetWidth(pb)
            let height = CVPixelBufferGetHeight(pb)
            let rowSize = (width * 3 + 3) & ~3
            var bgr = [UInt8](repeating: 0, count: rowSize * height)
            bgra.withUnsafeBytes { source in
                guard let sourceBase = source.baseAddress else { return }
                let sourceBytes = sourceBase.assumingMemoryBound(to: UInt8.self)
                for y in 0..<height {
                    let sourceRow = sourceBytes.advanced(by: y * width * 4)
                    let destinationRow = (height - 1 - y) * rowSize
                    for x in 0..<width {
                        let sourceIndex = x * 4
                        let destinationIndex = destinationRow + x * 3
                        bgr[destinationIndex] = sourceRow[sourceIndex]
                        bgr[destinationIndex + 1] = sourceRow[sourceIndex + 1]
                        bgr[destinationIndex + 2] = sourceRow[sourceIndex + 2]
                    }
                }
            }
            return bgr
        }

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let src = base.assumingMemoryBound(to: UInt8.self)
        let rowSize = (w * 3 + 3) & ~3
        var bgr = [UInt8](repeating: 0, count: rowSize * h)
        for y in 0..<h {
            let srcRow = src.advanced(by: y * stride)
            let destY = h - 1 - y
            let destRow = destY * rowSize
            for x in 0..<w {
                let si = x * 4
                let di = destRow + x * 3
                bgr[di] = srcRow[si]
                bgr[di + 1] = srcRow[si + 1]
                bgr[di + 2] = srcRow[si + 2]
            }
        }
        return bgr
    }

    /// Build RFX tiles for 64×64 origins. Small dirty batches stay on the pixel
    /// buffer; full batches pay one packed-BGRA conversion and then slice it.
    private static func rfxTiles(
        from frame: CapturedFrame,
        tileKeys: [UInt64]
    ) -> [RemoteFXEncoder.Tile] {
        var tiles: [RemoteFXEncoder.Tile] = []
        tiles.reserveCapacity(tileKeys.count)

        let directPixelBuffer = frame.pixelBuffer.flatMap {
            tileKeys.count <= 64 && Self.canExtractRFXTilesDirectly(from: $0) ? $0 : nil
        }
        var fullBGRA: [UInt8]? = directPixelBuffer == nil ? Self.fullBGRA(from: frame) : nil

        for key in tileKeys {
            let tx = Int(key >> 32)
            let ty = Int(key & 0xFFFF_FFFF)
            guard tx < frame.width, ty < frame.height else { continue }
            let tw = min(64, frame.width - tx)
            let th = min(64, frame.height - ty)
            var tileBGRA = directPixelBuffer.flatMap {
                Self.extractTileBGRA(from: $0, x: tx, y: ty, w: tw, h: th)
            }
            if tileBGRA == nil {
                if fullBGRA == nil { fullBGRA = Self.fullBGRA(from: frame) }
                tileBGRA = fullBGRA.flatMap {
                    Self.extractTileBGRA(
                        $0, frameWidth: frame.width, frameHeight: frame.height,
                        x: tx, y: ty, w: tw, h: th
                    )
                }
            }
            guard let tileBGRA else { return [] }
            tiles.append(RemoteFXEncoder.Tile(x: tx, y: ty, width: tw, height: th, bgra: tileBGRA))
        }
        return tiles
    }

    private static func canExtractRFXTilesDirectly(from pb: CVPixelBuffer) -> Bool {
        switch CVPixelBufferGetPixelFormatType(pb) {
        case kCVPixelFormatType_32BGRA:
            return true
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return CVPixelBufferGetWidth(pb).isMultiple(of: 2)
                && CVPixelBufferGetHeight(pb).isMultiple(of: 2)
        default:
            return false
        }
    }

    private static func fullBGRA(from frame: CapturedFrame) -> [UInt8]? {
        if let pb = frame.pixelBuffer, let bgra = Self.copyBGRA(from: pb) {
            return bgra
        }
        return Self.bgrBottomUpToBGRA(frame)
    }

    private static func extractTileBGRA(
        from pb: CVPixelBuffer,
        x: Int,
        y: Int,
        w: Int,
        h: Int
    ) -> [UInt8]? {
        switch CVPixelBufferGetPixelFormatType(pb) {
        case kCVPixelFormatType_32BGRA:
            return extractPackedBGRATile(from: pb, x: x, y: y, w: w, h: h)
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return extractNV12TileBGRA(from: pb, x: x, y: y, w: w, h: h, videoRange: true)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return extractNV12TileBGRA(from: pb, x: x, y: y, w: w, h: h, videoRange: false)
        default:
            return nil
        }
    }

    private static func extractPackedBGRATile(
        from pb: CVPixelBuffer,
        x: Int,
        y: Int,
        w: Int,
        h: Int
    ) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let fw = CVPixelBufferGetWidth(pb)
        let fh = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb),
              w > 0, h > 0, x >= 0, y >= 0, x + w <= fw, y + h <= fh else { return nil }
        var out = [UInt8](repeating: 0xFF, count: w * h * 4)
        let src = base.assumingMemoryBound(to: UInt8.self)
        out.withUnsafeMutableBytes { dst in
            guard let dstBase = dst.baseAddress else { return }
            for row in 0..<h {
                let srcOff = (y + row) * stride + x * 4
                let dstOff = row * w * 4
                memcpy(dstBase.advanced(by: dstOff), src.advanced(by: srcOff), w * 4)
            }
        }
        return out
    }

    /// Copy a capture buffer to packed top-down BGRA for RemoteFX.
    /// Handles BGRA and biplanar NV12 (video- or full-range).
    static func copyBGRA(from pb: CVPixelBuffer) -> [UInt8]? {
        let format = CVPixelBufferGetPixelFormatType(pb)
        switch format {
        case kCVPixelFormatType_32BGRA:
            return copyPackedBGRA(from: pb)
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return copyBGRAFromNV12(pb, videoRange: true)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return copyBGRAFromNV12(pb, videoRange: false)
        default:
            RDPLog.rdp.error(
                "RFX: unsupported pixel format 0x\(String(format, radix: 16)) for BGRA copy"
            )
            return nil
        }
    }

    private static func copyPackedBGRA(from pb: CVPixelBuffer) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { dst in
            guard let dstBase = dst.baseAddress else { return }
            let src = base.assumingMemoryBound(to: UInt8.self)
            if stride == w * 4 {
                memcpy(dstBase, src, w * h * 4)
            } else {
                for y in 0..<h {
                    memcpy(dstBase.advanced(by: y * w * 4), src.advanced(by: y * stride), w * 4)
                }
            }
        }
        return out
    }

    /// NV12 (biplanar Y + interleaved CbCr) → packed BGRA via Accelerate.
    /// Misreading the Y plane as BGRA packs ~4 scanlines into one row →
    /// "four grayscale panes side-by-side" on the client.
    private static func copyBGRAFromNV12(_ pb: CVPixelBuffer, videoRange: Bool) -> [UInt8]? {
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        return convertNV12ToBGRA(from: pb, x: 0, y: 0, w: w, h: h, videoRange: videoRange)
    }

    private static func extractNV12TileBGRA(
        from pb: CVPixelBuffer,
        x: Int,
        y: Int,
        w: Int,
        h: Int,
        videoRange: Bool
    ) -> [UInt8]? {
        guard x.isMultiple(of: 2), y.isMultiple(of: 2),
              w.isMultiple(of: 2), h.isMultiple(of: 2) else {
            return nil
        }
        return convertNV12ToBGRA(from: pb, x: x, y: y, w: w, h: h, videoRange: videoRange)
    }

    private static func convertNV12ToBGRA(
        from pb: CVPixelBuffer,
        x: Int,
        y: Int,
        w: Int,
        h: Int,
        videoRange: Bool
    ) -> [UInt8]? {
        let frameWidth = CVPixelBufferGetWidth(pb)
        let frameHeight = CVPixelBufferGetHeight(pb)
        guard w > 0, h > 0,
              x >= 0, y >= 0, x + w <= frameWidth, y + h <= frameHeight,
              CVPixelBufferGetPlaneCount(pb) >= 2 else { return nil }

        var info = vImage_YpCbCrToARGB()
        var pixelRange = videoRange
            ? vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240, YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
            : vImage_YpCbCrPixelRange(Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255, CbCrRangeMax: 255, YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
        // BT.709 matrix — matches ScreenCaptureKit / modern displays.
        let genErr = vImageConvert_YpCbCrToARGB_GenerateConversion(
            kvImage_YpCbCrToARGBMatrix_ITU_R_709_2,
            &pixelRange,
            &info,
            kvImage420Yp8_CbCr8,
            kvImageARGB8888,
            vImage_Flags(kvImageNoFlags)
        )
        guard genErr == kvImageNoError else {
            RDPLog.rdp.error("RFX: NV12→BGRA conversion setup failed (\(genErr))")
            return nil
        }

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }

        var out = [UInt8](repeating: 0, count: w * h * 4)
        let ok = out.withUnsafeMutableBytes { dst -> Bool in
            guard let dstBase = dst.baseAddress else { return false }
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let yOffset = y * yStride + x
            let uvOffset = (y / 2) * uvStride + x
            var yp = vImage_Buffer(
                data: yBase.advanced(by: yOffset),
                height: vImagePixelCount(h),
                width: vImagePixelCount(w),
                rowBytes: yStride
            )
            var cbcr = vImage_Buffer(
                data: uvBase.advanced(by: uvOffset),
                height: vImagePixelCount(h / 2),
                width: vImagePixelCount(w),
                rowBytes: uvStride
            )
            var dest = vImage_Buffer(
                data: dstBase,
                height: vImagePixelCount(h),
                width: vImagePixelCount(w),
                rowBytes: w * 4
            )
            // Destination channel order BGRA (Apple docs: {3,2,1,0} from ARGB).
            var permuteMap: [UInt8] = [3, 2, 1, 0]
            let err = vImageConvert_420Yp8_CbCr8ToARGB8888(
                &yp, &cbcr, &dest, &info, &permuteMap, 0xFF, vImage_Flags(kvImageNoFlags)
            )
            return err == kvImageNoError
        }
        guard ok else {
            RDPLog.rdp.error("RFX: NV12→BGRA convert failed")
            return nil
        }
        return out
    }

    private static func extractTileBGRA(
        _ full: [UInt8],
        frameWidth: Int,
        frameHeight: Int,
        x: Int,
        y: Int,
        w: Int,
        h: Int
    ) -> [UInt8]? {
        guard full.count >= frameWidth * frameHeight * 4,
              w > 0, h > 0, x >= 0, y >= 0,
              x + w <= frameWidth, y + h <= frameHeight else {
            return nil
        }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        full.withUnsafeBytes { source in
            out.withUnsafeMutableBytes { destination in
                guard let sourceBase = source.baseAddress,
                      let destinationBase = destination.baseAddress else { return }
                for row in 0..<h {
                    let sourceOffset = ((y + row) * frameWidth + x) * 4
                    let destinationOffset = row * w * 4
                    memcpy(
                        destinationBase.advanced(by: destinationOffset),
                        sourceBase.advanced(by: sourceOffset),
                        w * 4
                    )
                }
            }
        }
        return out
    }

    private static func bgrBottomUpToBGRA(_ frame: CapturedFrame) -> [UInt8]? {
        let row = (frame.width * 3 + 3) & ~3
        var bgra = [UInt8](repeating: 0, count: frame.width * frame.height * 4)
        for y in 0..<frame.height {
            let srcY = frame.height - 1 - y // convert bottom-up → top-down
            for x in 0..<frame.width {
                let si = srcY * row + x * 3
                let di = (y * frame.width + x) * 4
                guard si + 2 < frame.bgrBottomUp.count else { return nil }
                bgra[di] = frame.bgrBottomUp[si]
                bgra[di + 1] = frame.bgrBottomUp[si + 1]
                bgra[di + 2] = frame.bgrBottomUp[si + 2]
                bgra[di + 3] = 0xFF
            }
        }
        return bgra
    }
}
