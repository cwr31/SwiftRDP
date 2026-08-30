import Foundation
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
        let display = manager.sharedVirtualDisplay

        // Pick physical vs virtual from current topology (clamshell → virtual when panel asleep).
        sessionManager?.refreshHostDisplayMode(reason: "startDesktop")
        let useVD = usesVirtualDisplay
        let virtualParams = useVD
            ? manager.virtualDisplayParameters(
                clientWidth: clientWidth,
                clientHeight: clientHeight
            )
            : nil

        if useVD, let params = virtualParams {
            display.createMatching(
                width: params.pixelWidth,
                height: params.pixelHeight,
                preferHiDPI: params.preferHiDPI,
                logicalWidth: params.logicalWidth,
                logicalHeight: params.logicalHeight
            )
            RDPLog.rdp.info(
                "Display: Virtual Display source \(params.pixelWidth)x\(params.pixelHeight) " +
                "for RDP desktop \(clientWidth)x\(clientHeight)" +
                (params.preferHiDPI ? " HiDPI \(params.logicalWidth)x\(params.logicalHeight)" : "")
            )
        } else {
            if display.active {
                display.destroy()
            }
            applyDesktopSizePolicy(reason: "startDesktop")
            RDPLog.rdp.info(
                "Display: physical mirror \(clientWidth)x\(clientHeight)"
            )
        }

        display.acquireWakeAssertion()

        let captureW: Int
        let captureH: Int
        let contentLayout: DisplayContentLayout
        if useVD {
            captureW = virtualParams?.pixelWidth ?? clientWidth
            captureH = virtualParams?.pixelHeight ?? clientHeight
            contentLayout = DisplayContentLayout.aspectFit(
                desktopWidth: clientWidth,
                desktopHeight: clientHeight,
                sourceWidth: captureW,
                sourceHeight: captureH
            )
        } else {
            let plan = bindPhysicalMirrorGeometry(reason: "startDesktop")
            captureW = plan.captureWidth
            captureH = plan.captureHeight
            contentLayout = plan.layout
        }

        hideHostCursorIfNeeded()

        if config.asyncEncoding {
            RDPLog.rdp.info("AsyncEncoding: enabled (encode path uses VT async callbacks)")
        }
        gfx.asyncEncoding = config.asyncEncoding

        let displayID: UInt32? = useVD
            ? (display.displayID == 0 ? nil : display.displayID)
            : DisplayTopology.physicalDisplayID(preferredIdentity: config.selectedDisplayIdentity)
        sharedCapture.attach(
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
                self?.syncMouseMapping(reason: "capture display changed")
            },
            onFatalError: { [weak self] error in
                RDPLog.rdp.error("Capture became unavailable: \(error). Closing session.")
                self?.terminate()
            }
        )
        self.captureContentLayout = contentLayout
        resetRFXPending()
        info.width = clientWidth
        info.height = clientHeight
        info.licensed = true
        input.scaleX = 1
        input.scaleY = 1
        input.onUserActivity = { [weak self] in
            self?.lastActivity = Date()
            let display = self?.sessionManager?.sharedVirtualDisplay ?? self?.virtualDisplay
            display?.noteUserActivity()
        }
        input.keyboard.resetModifiers()
        cursor.onSendFastPath = { [weak self] pdu in
            self?.write(pdu)
        }
        mouse.onPointerMoved = { [weak self] _, _ in
            self?.cursor.requestRefresh()
        }
        cursor.start()
        syncMouseMapping(reason: "startDesktop")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.syncMouseMapping(reason: "startDesktop settle")
        }
        armDVCCapsTimeoutWatchdog()

        if let disp = vcRouter.channel(named: "disp") as? GeometryTracking {
            disp.onResize = { [weak self] w, h in
                self?.handleDesktopResize(width: w, height: h)
            }
        }

        captureTask = Task { [weak self] in
            do {
                // Give WindowServer / ScreenCaptureKit a beat after CGVirtualDisplay
                // create+mirror — otherwise SCShareableContent can hang indefinitely.
                if self?.usesVirtualDisplay == true {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    try Task.checkCancellation()
                }
                try await sharedCapture.start(
                    target: SharedScreenCapture.Target(
                        displayID: displayID,
                        width: captureW,
                        height: captureH
                    )
                )
                try Task.checkCancellation()
                self?.syncMouseMapping(reason: "capture started")
            } catch is CancellationError {
                return
            } catch {
                RDPLog.rdp.error("Capture failed: \(error). Closing session instead of serving a black desktop.")
                self?.terminate()
                return
            }
            // Capture + input loop: wake on new frames and retain FPS pacing.
            RDPLog.rdp.info("Display: desktop encode loop started")
            while let self, !Task.isCancelled, self.phase == .active {
                self.applyCaptureTargetFPS()
                self.gfx.targetFPS = max(self.videoController.targetFPS, 1)
                let fps = self.gfx.effectiveFPS
                let periodNs = 1_000_000_000 / UInt64(fps)
                let tickStart = DispatchTime.now().uptimeNanoseconds

                let encoded = self.pushFrameReturningEncoded()

                let elapsed = DispatchTime.now().uptimeNanoseconds &- tickStart
                if encoded {
                    // Pace to target FPS and wake on the next SCKit sample when it
                    // arrives sooner. The pipeline owns one bounded encode slot.
                    if elapsed < periodNs {
                        await self.waitForCaptureWake(timeoutNs: periodNs - elapsed)
                    }
                } else if self.gfx.isEncodeInFlight || self.gfx.isAckWindowFull {
                    // VT completion and FRAME_ACK signal this path directly. Keep a
                    // bounded timeout for TCP send availability and ACK watchdogs.
                    await self.waitForCaptureWake(timeoutNs: 100_000_000)
                } else {
                    // No work yet (pipeline not ready / paused / no frame). Wake on
                    // the next SCKit sample or after one frame period.
                    let waitNs = elapsed < periodNs ? periodNs - elapsed : periodNs
                    await self.waitForCaptureWake(timeoutNs: waitNs)
                }
            }
        }

        startIdleWatchIfNeeded()
    }

    /// Register aligned DVC names ([MS-RDPEDYC] + companion specs).
    func registerStandardDVCs() {
        vcRouter.dynamicVC.onCreate(name: DesktopComposition.channelName) { [weak self] _, send in
            self?.desktopComposition.attach(send: send)
        }
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
        vcRouter.dynamicVC.onCreate(name: GeometryDVChannel.dvcName) { [weak self] channelId, send in
            guard let self else { return }
            self.geometryDVC.attach(send: send)
            self.vcRouter.dynamicVC.setDataHandler(channelId: channelId) { [weak self] data in
                self?.geometryDVC.handle(data)
            }
        }
        vcRouter.dynamicVC.onCreate(name: TouchInput.dvcName) { [weak self] channelId, send in
            guard let self else { return }
            self.touch.scaleX = self.mouse.scaleX
            self.touch.scaleY = self.mouse.scaleY
            self.touch.originX = self.mouse.originX
            self.touch.originY = self.mouse.originY
            self.touch.onUserActivity = { [weak self] in
                self?.lastActivity = Date()
                let display = self?.sessionManager?.sharedVirtualDisplay ?? self?.virtualDisplay
                display?.noteUserActivity()
            }
            self.touch.attach(send: send)
            self.vcRouter.dynamicVC.setDataHandler(channelId: channelId) { [weak self] data in
                self?.touch.handle(data)
            }
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

    /// Resolve the display whose Quartz bounds map RDP desktop coords → host clicks.
    private func mouseMappingDisplayID() -> CGDirectDisplayID {
        let vd = sessionManager?.sharedVirtualDisplay ?? virtualDisplay
        if usesVirtualDisplay {
            if vd.active, vd.displayID != 0 { return vd.displayID }
            if let selected = sharedCapture?.selectedDisplayID, selected != 0 {
                return CGDirectDisplayID(selected)
            }
        } else {
            if let phys = DisplayTopology.physicalDisplayID(
                preferredIdentity: config.selectedDisplayIdentity
            ) {
                return phys
            }
            if let active = sharedCapture?.activeDisplayID, active != 0 {
                return active
            }
            if let selected = sharedCapture?.selectedDisplayID, selected != 0 {
                return CGDirectDisplayID(selected)
            }
        }
        return CGMainDisplayID()
    }

    /// Recompute mouse/touch mapping immediately after layout or capture-target changes.
    private func syncMouseMapping(reason: String, previousLayout: DisplayContentLayout? = nil) {
        if let previousLayout, previousLayout != captureContentLayout {
            mouse.noteDesktopGeometryChanged(
                oldDesktopWidth: previousLayout.desktopWidth,
                oldDesktopHeight: previousLayout.desktopHeight,
                newDesktopWidth: captureContentLayout.desktopWidth,
                newDesktopHeight: captureContentLayout.desktopHeight
            )
        }
        applyMouseScale()
        RDPLog.rdp.debug("Mouse mapping synced (\(reason))")
    }

    /// mouse scale: hostPt = CGDisplayBounds.origin + scale * max(rdp - letterbox, 0).
    private func applyMouseScale() {
        let id = mouseMappingDisplayID()
        let bounds = CGDisplayBounds(id)
        let layout = captureContentLayout
        let contentW = CGFloat(max(layout.contentWidth, 1))
        let contentH = CGFloat(max(layout.contentHeight, 1))
        let sx = bounds.width / contentW
        let sy = bounds.height / contentH
        input.scaleX = sx
        input.scaleY = sy
        // stores Quartz origin directly — do not flip to CGEvent top-left.
        input.originX = bounds.origin.x
        input.originY = bounds.origin.y
        mouse.letterboxOffsetX = CGFloat(layout.offsetX)
        mouse.letterboxOffsetY = CGFloat(layout.offsetY)
        mouse.contentWidth = contentW
        mouse.contentHeight = contentH
        mouse.captureAreaWidth = bounds.width
        mouse.captureAreaHeight = bounds.height
        touch.scaleX = sx
        touch.scaleY = sy
        touch.originX = bounds.origin.x
        touch.originY = bounds.origin.y
        touch.letterboxOffsetX = CGFloat(layout.offsetX)
        touch.letterboxOffsetY = CGFloat(layout.offsetY)
        touch.contentWidth = contentW
        touch.contentHeight = contentH
        RDPLog.rdp.info(
            "Mouse scale (content \(Int(contentW))x\(Int(contentH)) " +
            "+letterbox(\(layout.offsetX),\(layout.offsetY)) in " +
            "\(layout.desktopWidth)x\(layout.desktopHeight) → " +
            "\(Int(bounds.width))x\(Int(bounds.height)) " +
            "origin=(\(Int(bounds.origin.x)),\(Int(bounds.origin.y)))"
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
        guard !outputSuppressed else { return false }

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
            let latest = snapshot.frame
            var dirty = latest.dirtyRects ?? []
            if !pendingRefreshRects.isEmpty {
                dirty.append(contentsOf: pendingRefreshRects)
                pendingRefreshRects.removeAll(keepingCapacity: true)
            }
            let encoded = pushRFXFrame(frame: latest, captureDirty: dirty)
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
            let hasRefresh = !pendingRefreshRects.isEmpty
            guard snapshot.sequence != lastH264CaptureSequence
                    || hasRefresh
                    || gfx.hasPendingForcedFrame
            else { return false }
            guard let pb = snapshot.frame.pixelBuffer else { return false }
            switch gfx.encodeFrame(
                pixelBuffer: pb,
                captureUptimeNanoseconds: snapshot.frame.captureUptimeNanoseconds
            ) {
            case .submitted:
                sharedCapture?.markFrameDelivered(
                    sequence: snapshot.sequence,
                    after: lastH264CaptureSequence
                )
                lastH264CaptureSequence = snapshot.sequence
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
            self.gfx.asyncEncoding = self.config.asyncEncoding
            self.gfx.targetFPS = self.config.fps
            self.gfx.targetBitrate = ServerConfig.normalizedVideoBitrate(self.config.videoBitrate)
            self.gfx.attachController(self.videoController)
            self.gfx.attach(
                transport: RDPGFXDynamicChannelTransport(
                    sendFrame: { [weak self] payloads, priority in
                        self?.vcRouter.dynamicVC.sendDataBatch(
                            channelId: channelId,
                            payloads: payloads,
                            priority: priority
                        )
                    }
                )
            )
            self.updateGFXTCPBackpressure()
            self.gfx.onWorkAvailable = { [weak self] in
                self?.signalCaptureWake()
            }
            self.gfx.onVideoFrameDropped = { [weak self] in
                self?.rfxNeedsFullRefresh = true
                self?.signalCaptureWake()
            }
            self.gfx.onPipelineFailure = { [weak self] in
                self?.vcRouter.dynamicVC.closeChannel(name: Self.graphicsDVCName)
            }
            self.gfx.onCapabilityFailure = { [weak self] in
                self?.handleGraphicsCapabilityFailure()
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
                self.updateGFXTCPBackpressure()
                self.graphicsCloseCount = 0
            } catch {
                RDPLog.rdp.error("GFX: start failed \(error)")
                self.gfx.noteChannelCreateFailed("\(error)")
                self.gfxReady = false
            }
        }
    }

    private func handleGraphicsChannelClosed() {
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
        guard gfxPipelineEnabled, phase != .terminated else { return }
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
        if coalesce {
            if graphicsRecreatePending {
                RDPLog.rdp.info("GFX: create already pending — skip (\(reason.rawValue))")
                return
            }
            graphicsRecreatePending = true
        }

        let work = { [weak self] in
            guard let self else { return }
            if coalesce { self.graphicsRecreatePending = false }
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
        } else {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// After Graphics CLOSE — coalesce and recreate (not inline in the close handler).
    func scheduleGraphicsRecreate() {
        requestGraphicsCreate(reason: .channelClosed, delay: 0.3, countAsStorm: true, coalesce: true)
    }

    /// Bind capture size + mouse letterbox for physical-panel mirror.
    @discardableResult
    func bindPhysicalMirrorGeometry(reason: String) -> (
        captureWidth: Int,
        captureHeight: Int,
        layout: DisplayContentLayout
    ) {
        let phys = VirtualDisplayManager.physicalDisplayPixelSize(
            preferredIdentity: config.selectedDisplayIdentity
        )
        let panelW = max(phys.width & ~1, 2)
        let panelH = max(phys.height & ~1, 2)
        let previousLayout = captureContentLayout
        let plan = DisplayContentLayout.physicalMirrorPlan(
            desktopWidth: clientWidth,
            desktopHeight: clientHeight,
            panelWidth: panelW,
            panelHeight: panelH
        )
        captureContentLayout = plan.layout
        // Defensive: physicalMirrorPlan may force panel geometry on aspect mismatch.
        if clientWidth != plan.layout.desktopWidth || clientHeight != plan.layout.desktopHeight {
            clientWidth = plan.layout.desktopWidth
            clientHeight = plan.layout.desktopHeight
        }
        info.width = clientWidth
        info.height = clientHeight
        // Desktop / surface / capture are all panel-native pixels.
        RDPLog.rdp.info(
            "Display: \(reason) physical 1:1 capture/encode " +
            "\(plan.captureWidth)x\(plan.captureHeight)"
        )
        syncMouseMapping(reason: reason, previousLayout: previousLayout)
        return plan
    }

    /// Client DISP / GeometryTracking resize — Virtual mode follows client;
    /// physical mirror always stays on 1:1 Retina panel pixels.
    private func handleDesktopResize(width: Int, height: Int) {
        let display = sessionManager?.sharedVirtualDisplay ?? virtualDisplay

        if !usesVirtualDisplay {
            let reqW = max(width & ~1, 2)
            let reqH = max(height & ~1, 2)
            let phys = VirtualDisplayManager.physicalDisplayPixelSize(
                preferredIdentity: config.selectedDisplayIdentity
            )
            let panelW = max(phys.width & ~1, 2)
            let panelH = max(phys.height & ~1, 2)
            // Physical policy: ignore client aspect/size and stay on the panel.
            clientWidth = panelW
            clientHeight = panelH
            RDPLog.rdp.info(
                "DISP: physical 1:1 \(panelW)x\(panelH) " +
                "(client asked \(reqW)x\(reqH))"
            )
            let plan = bindPhysicalMirrorGeometry(reason: "DISP")
            scheduleCaptureRestart(
                captureW: plan.captureWidth,
                captureH: plan.captureHeight
            )
            return
        }

        let w = max(width & ~1, 2)
        let h = max(height & ~1, 2)
        let params = sessionManager?.virtualDisplayParameters(
            clientWidth: w,
            clientHeight: h
        ) ?? .native(pixelWidth: w, pixelHeight: h)
        clientWidth = w
        clientHeight = h
        info.width = w
        info.height = h

        display.createMatching(
            width: params.pixelWidth,
            height: params.pixelHeight,
            preferHiDPI: params.preferHiDPI,
            logicalWidth: params.logicalWidth,
            logicalHeight: params.logicalHeight
        )
        display.acquireWakeAssertion()

        let previousLayout = captureContentLayout
        captureContentLayout = DisplayContentLayout.aspectFit(
            desktopWidth: w,
            desktopHeight: h,
            sourceWidth: params.pixelWidth,
            sourceHeight: params.pixelHeight
        )
        syncMouseMapping(reason: "DISP resize", previousLayout: previousLayout)
        scheduleCaptureRestart(
            captureW: params.pixelWidth,
            captureH: params.pixelHeight
        )
    }

    /// Live apply from menu bar (Virtual Display) or after physical mode change.
    func applyHostResolution(width: Int, height: Int) {
        let captureW: Int
        let captureH: Int
        if usesVirtualDisplay {
            let params = sessionManager?.virtualDisplayParameters(
                clientWidth: clientWidth,
                clientHeight: clientHeight
            ) ?? .native(pixelWidth: clientWidth, pixelHeight: clientHeight)
            let previousLayout = captureContentLayout
            captureContentLayout = DisplayContentLayout.aspectFit(
                desktopWidth: clientWidth,
                desktopHeight: clientHeight,
                sourceWidth: params.pixelWidth,
                sourceHeight: params.pixelHeight
            )
            captureW = params.pixelWidth
            captureH = params.pixelHeight
            let display = sessionManager?.sharedVirtualDisplay ?? virtualDisplay
            display.createMatching(
                width: params.pixelWidth,
                height: params.pixelHeight,
                preferHiDPI: params.preferHiDPI,
                logicalWidth: params.logicalWidth,
                logicalHeight: params.logicalHeight
            )
            display.acquireWakeAssertion()
            syncMouseMapping(reason: "menu resolution", previousLayout: previousLayout)
            RDPLog.rdp.info(
                "Display: virtual capture source \(captureW)x\(captureH) " +
                "for RDP desktop \(clientWidth)x\(clientHeight)"
            )
        } else {
            let plan = bindPhysicalMirrorGeometry(reason: "menu")
            captureW = plan.captureWidth
            captureH = plan.captureHeight
        }
        scheduleCaptureRestart(captureW: captureW, captureH: captureH)
    }

    /// Rebind after auto mode flip or physical geometry change.
    func rebindHostDisplay(reason: String) {
        guard phase == .active else { return }
        let display = sessionManager?.sharedVirtualDisplay ?? virtualDisplay
        applyDesktopSizePolicy(reason: reason)

        let captureW: Int
        let captureH: Int
        if usesVirtualDisplay {
            let params = sessionManager?.virtualDisplayParameters(
                clientWidth: clientWidth,
                clientHeight: clientHeight
            ) ?? .native(pixelWidth: clientWidth, pixelHeight: clientHeight)
            info.width = clientWidth
            info.height = clientHeight
            let previousLayout = captureContentLayout
            captureContentLayout = DisplayContentLayout.aspectFit(
                desktopWidth: clientWidth,
                desktopHeight: clientHeight,
                sourceWidth: params.pixelWidth,
                sourceHeight: params.pixelHeight
            )
            captureW = params.pixelWidth
            captureH = params.pixelHeight
            if usesVirtualDisplay {
                display.createMatching(
                    width: params.pixelWidth,
                    height: params.pixelHeight,
                    preferHiDPI: params.preferHiDPI,
                    logicalWidth: params.logicalWidth,
                    logicalHeight: params.logicalHeight
                )
                display.acquireWakeAssertion()
            }
            syncMouseMapping(reason: reason, previousLayout: previousLayout)
        } else {
            let plan = bindPhysicalMirrorGeometry(reason: reason)
            captureW = plan.captureWidth
            captureH = plan.captureHeight
        }

        if !usesVirtualDisplay {
            if display.active { display.destroy() }
            display.acquireWakeAssertion()
        }

        RDPLog.rdp.info(
            "Display: rebind \(reason) mode=\(usesVirtualDisplay ? "virtual" : "physical") " +
            "desktop \(clientWidth)x\(clientHeight) capture \(captureW)x\(captureH)"
        )
        scheduleCaptureRestart(captureW: captureW, captureH: captureH)
    }

    private func scheduleCaptureRestart(captureW: Int, captureH: Int) {
        captureRestartTask?.cancel()
        captureRestartGeneration &+= 1
        let gen = captureRestartGeneration
        rfxSuspendEncodeForResize = true
        captureRestartTask = Task { [weak self] in
            guard let self else { return }
            // Debounce rapid DISP spam (orientation + quality picker).
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, gen == self.captureRestartGeneration else { return }
            do {
                // Resize GFX surface BEFORE capture restart so we never encode a
                // new capture size into a stale CREATE_SURFACE (freezes RFX when
                // NV12→BGRA scale also fails).
                if self.gfxReady {
                    self.gfx.requestForceIDR(reason: "DISP resize")
                    do {
                        try self.gfx.start(width: self.clientWidth, height: self.clientHeight)
                        self.updateGFXTCPBackpressure()
                        self.resetRFXPending()
                        RDPLog.rdp.info("GFX: resize complete \(self.clientWidth)x\(self.clientHeight)")
                    } catch {
                        RDPLog.rdp.error("GFX: resize failed: \(error)")
                        throw error
                    }
                }
                guard !Task.isCancelled, gen == self.captureRestartGeneration else { return }

                let displayID: UInt32? = self.usesVirtualDisplay
                    ? (self.sessionManager?.sharedVirtualDisplay.displayID == 0
                        ? nil
                        : self.sessionManager?.sharedVirtualDisplay.displayID)
                    : DisplayTopology.physicalDisplayID(preferredIdentity: self.config.selectedDisplayIdentity)
                try await self.sharedCapture?.restart(
                    target: SharedScreenCapture.Target(
                        displayID: displayID,
                        width: captureW,
                        height: captureH
                    )
                )
                try Task.checkCancellation()
                guard gen == self.captureRestartGeneration else { return }
                guard self.phase == .active else { throw CancellationError() }
                RDPLog.rdp.info(
                    "DISP: screen capture restarted at \(captureW)x\(captureH) " +
                    "(desktop \(self.clientWidth)x\(self.clientHeight))"
                )
                self.syncMouseMapping(reason: "DISP resize complete")
                if gen == self.captureRestartGeneration {
                    self.rfxSuspendEncodeForResize = false
                }
            } catch is CancellationError {
                return
            } catch {
                // Keep the RDP session alive — a failed capture restart should not
                // kick the client off just for changing resolution.
                RDPLog.rdp.error("DISP: screen capture restart failed: \(error)")
                if self.gfxReady {
                    self.gfx.requestForceIDR(reason: "DISP resize recovery")
                }
                self.syncMouseMapping(reason: "DISP resize recovery")
                if gen == self.captureRestartGeneration {
                    self.rfxSuspendEncodeForResize = false
                }
            }
        }
    }

    /// RFX Progressive:
    /// 1) Bootstrap / dirty / hash-scan enqueue
    /// 2) Strict per-frame op budget (including TILE_SIMPLE full refresh)
    /// 3) Upgrades only after FIRST queue drains and ACK is healthy
    /// 4) Encode overload skip + latest-frame only
    private static let rfxTileSize = 64
    private static let rfxHashScanMinIntervalNs: UInt64 = 100_000_000 // 100ms
    /// Steady-state FIRST/UPGRADE/SIMPLE ops per tick.
    private static let rfxOpBudget = 48
    /// Bootstrap TILE_SIMPLE budget (spread full refresh across ticks).
    private static let rfxBootstrapOpBudget = 64
    /// Estimated client queue delay above which RFX skips sending.
    private static let rfxHighQueueDelayMs = 200.0
    /// Only upgrade when the estimated client queue delay is this low or lower.
    private static let rfxUpgradeQueueDelayMs = 80.0

    static func rfxHashScanDue(lastScanNs: UInt64, nowNs: UInt64) -> Bool {
        lastScanNs == 0 || nowNs &- lastScanNs >= rfxHashScanMinIntervalNs
    }

    func resetRFXPending() {
        lastRFXCaptureSequence = 0
        rfxPendingKeys.removeAll(keepingCapacity: true)
        rfxUpgradeKeys.removeAll(keepingCapacity: true)
        rfxTileStages.removeAll(keepingCapacity: true)
        rfxTileHashes.removeAll(keepingCapacity: true)
        rfxHashCols = 0
        rfxHashRows = 0
        rfxNeedsFullRefresh = true
        rfxBootstrapSimplePending = false
        rfxLastHashScanNs = 0
        rfxLoggedScaleGeometry = nil
    }

    /// Returns `true` when an RFX frame was encoded and queued for send.
    @discardableResult
    private func pushRFXFrame(frame: CapturedFrame, captureDirty: [CGRect]) -> Bool {
        if rfxSuspendEncodeForResize {
            return false
        }
        // RFX encoding is serialized off the capture loop. Do not repeat dirty
        // hashing, scaling, or tile extraction while that worker owns the slot.
        if gfx.isEncodeInFlight {
            return false
        }
        if videoController.consumeRFXSkipFrame() {
            return false
        }
        if gfx.isAckWindowFull {
            return false
        }

        // SCKit can omit dirty metadata on a virtual display. Keep scanning for
        // the full session, but avoid scaling every capture sample.
        if !rfxNeedsFullRefresh, captureDirty.isEmpty, rfxPendingKeys.isEmpty {
            if rfxUpgradeKeys.isEmpty {
                let now = DispatchTime.now().uptimeNanoseconds
                guard Self.rfxHashScanDue(lastScanNs: rfxLastHashScanNs, nowNs: now) else {
                    return false
                }
                rfxLastHashScanNs = now
            }
            // else: drain pending upgrades without waiting for the hash-scan interval
        }

        // Tile grid must match CREATE_SURFACE; without MAP_SCALED (e.g. V8.1),
        // scale capture → surface first.
        let sourceWidth = frame.width
        let sourceHeight = frame.height
        let surface = gfx.surfaceEncodeSize
        guard let prepared = Self.rfxPrepareFrameForSurface(
            frame: frame,
            captureDirty: captureDirty,
            surfaceWidth: surface.width,
            surfaceHeight: surface.height,
            transfer: gfx.pixelTransfer
        ) else {
            RDPLog.rdp.error(
                "GFX: RFX cannot scale capture \(frame.width)x\(frame.height) " +
                "→ surface \(surface.width)x\(surface.height)"
            )
            return false
        }
        var frame = prepared.frame
        let captureDirty = prepared.dirty
        if prepared.didScale {
            let changedGeometry = rfxLoggedScaleGeometry?.sourceWidth != sourceWidth
                || rfxLoggedScaleGeometry?.sourceHeight != sourceHeight
                || rfxLoggedScaleGeometry?.width != frame.width
                || rfxLoggedScaleGeometry?.height != frame.height
            if changedGeometry {
                rfxLoggedScaleGeometry = (sourceWidth, sourceHeight, frame.width, frame.height)
                RDPLog.rdp.debug(
                    "GFX: RFX scaled capture \(sourceWidth)x\(sourceHeight) → " +
                    "surface \(frame.width)x\(frame.height) " +
                    "tiles≈\((frame.width + Self.rfxTileSize - 1) / Self.rfxTileSize)x" +
                    "\((frame.height + Self.rfxTileSize - 1) / Self.rfxTileSize)"
                )
            }
            // Keep mouse letterbox in sync with encode letterbox when aspects differ.
            if DisplayContentLayout.aspectsDiffer(
                sourceWidth, sourceHeight, frame.width, frame.height
            ) {
                let layout = DisplayContentLayout.aspectFit(
                    desktopWidth: frame.width,
                    desktopHeight: frame.height,
                    sourceWidth: sourceWidth,
                    sourceHeight: sourceHeight
                )
                if layout != captureContentLayout {
                    captureContentLayout = layout
                    syncMouseMapping(reason: "encode letterbox")
                }
            }
        }

        // Prefer newest pixels after scale prep (capture may have advanced).
        if prepared.didScale == false,
           let newer = sharedCapture?.currentFrame(),
           newer.pixelBuffer !== frame.pixelBuffer {
            frame = newer
        }

        ensureRFXHashGrid(width: frame.width, height: frame.height)

        var forceSimpleFullQuality = false
        if rfxNeedsFullRefresh {
            rfxNeedsFullRefresh = false
            rfxBootstrapSimplePending = true
            forceSimpleFullQuality = true
            rfxUpgradeKeys.removeAll(keepingCapacity: true)
            rfxTileStages.removeAll(keepingCapacity: true)
            for i in rfxTileHashes.indices { rfxTileHashes[i] = 0 }
            let full = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
            enqueueRFXChangedTiles(
                frame: frame,
                keys: Self.rfxTileKeys(from: [full], frameWidth: frame.width, frameHeight: frame.height)
            )
        } else if rfxBootstrapSimplePending {
            forceSimpleFullQuality = true
        } else if !captureDirty.isEmpty {
            enqueueRFXChangedTiles(
                frame: frame,
                keys: Self.rfxTileKeys(
                    from: captureDirty, frameWidth: frame.width, frameHeight: frame.height
                )
            )
        } else if rfxPendingKeys.isEmpty && !rfxUpgradeKeys.isEmpty {
            // Drain quality upgrades only — avoid a full-grid hash scan every tick.
        } else {
            let before = rfxPendingKeys.count
            enqueueRFXChangedTiles(
                frame: frame,
                keys: Self.rfxAllTileKeys(frameWidth: frame.width, frameHeight: frame.height)
            )
            let added = rfxPendingKeys.count - before
            if added > 0 {
                RDPLog.rdp.debug("GFX: RFX hash-scan enqueued \(added) changed tiles")
            }
        }

        // Static desktop with nothing queued — do not burn CPU on upgrades-only churn
        // when the hash scan found no changes and FIRST queue is empty. Still drain
        // upgrades when they remain from a prior dirty burst.
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

    /// Scale capture into CREATE_SURFACE geometry when it differs from the desktop.
    static func rfxPrepareFrameForSurface(
        frame: CapturedFrame,
        captureDirty: [CGRect],
        surfaceWidth: Int,
        surfaceHeight: Int,
        transfer: PixelBufferTransfer
    ) -> (frame: CapturedFrame, dirty: [CGRect], didScale: Bool)? {
        let sw = max(surfaceWidth, 1)
        let sh = max(surfaceHeight, 1)
        if frame.width == sw, frame.height == sh {
            return (frame, captureDirty, false)
        }
        guard let srcPB = frame.pixelBuffer else { return nil }
        // RFX tiles read packed BGRA.
        guard let scaledPB = transfer.transfer(
            srcPB,
            width: sw,
            height: sh,
            pixelFormat: kCVPixelFormatType_32BGRA,
            scaling: Self.aspectsDiffer(frame.width, frame.height, sw, sh) ? .letterbox : .fill
        ) else { return nil }
        let dirty: [CGRect]
        if Self.aspectsDiffer(frame.width, frame.height, sw, sh) {
            let layout = DisplayContentLayout.aspectFit(
                desktopWidth: sw,
                desktopHeight: sh,
                sourceWidth: frame.width,
                sourceHeight: frame.height
            )
            dirty = rfxLetterboxDirtyRects(
                captureDirty,
                fromWidth: frame.width,
                fromHeight: frame.height,
                layout: layout
            )
        } else {
            dirty = rfxScaleDirtyRects(
                captureDirty,
                fromWidth: frame.width,
                fromHeight: frame.height,
                toWidth: sw,
                toHeight: sh
            )
        }
        let scaled = CapturedFrame(
            width: sw,
            height: sh,
            bgrBottomUp: [],
            dirtyRects: dirty,
            pixelBuffer: scaledPB
        )
        return (scaled, dirty, true)
    }

    static func rfxScaleDirtyRects(
        _ rects: [CGRect],
        fromWidth: Int,
        fromHeight: Int,
        toWidth: Int,
        toHeight: Int
    ) -> [CGRect] {
        guard fromWidth > 0, fromHeight > 0,
              fromWidth != toWidth || fromHeight != toHeight
        else {
            return rects
        }
        let sx = CGFloat(toWidth) / CGFloat(fromWidth)
        let sy = CGFloat(toHeight) / CGFloat(fromHeight)
        return rects.map { rect in
            CGRect(
                x: rect.origin.x * sx,
                y: rect.origin.y * sy,
                width: rect.size.width * sx,
                height: rect.size.height * sy
            )
        }
    }

    private static func aspectsDiffer(_ aw: Int, _ ah: Int, _ bw: Int, _ bh: Int) -> Bool {
        DisplayContentLayout.aspectsDiffer(aw, ah, bw, bh)
    }

    static func rfxLetterboxDirtyRects(
        _ rects: [CGRect],
        fromWidth: Int,
        fromHeight: Int,
        layout: DisplayContentLayout
    ) -> [CGRect] {
        guard fromWidth > 0, fromHeight > 0 else { return rects }
        let sx = CGFloat(layout.contentWidth) / CGFloat(fromWidth)
        let sy = CGFloat(layout.contentHeight) / CGFloat(fromHeight)
        return rects.map { rect in
            CGRect(
                x: CGFloat(layout.offsetX) + rect.origin.x * sx,
                y: CGFloat(layout.offsetY) + rect.origin.y * sy,
                width: rect.size.width * sx,
                height: rect.size.height * sy
            )
        }
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
        guard gfxPipelineEnabled else { return }
        let deadline = Date().addingTimeInterval(10)
        capsTimeoutTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.phase == .active {
                if self.vcRouter.dynamicVC.hasCompletedCapsExchange { return }
                if self.gfxReady { return }
                if Date() >= deadline {
                    RDPLog.rdp.info("DVC: CAPS_RSP timeout (>10s) — client doesn't support DVC, terminating session (spec 3.3.2)")
                    self.terminate()
                    return
                }
                self.vcRouter.dynamicVC.sweepStaleState()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func pushBitmapFrame(width w: Int, height h: Int) {
        // skip GFX/bitmap send while TCP unwritable.
        guard graphicsWritable else { return }

        // DirtyInfo maxTile=64.
        let bitmapMaxTile = 64
        if let frame = sharedCapture?.currentFrame() {
            var frame = frame
            if frame.width != w || frame.height != h {
                guard let source = frame.pixelBuffer,
                      let scaled = gfx.pixelTransfer.transfer(
                        source,
                        width: w,
                        height: h,
                        pixelFormat: kCVPixelFormatType_32BGRA,
                        scaling: .letterbox
                      ),
                      let bgr = Self.pixelBufferToBGRBottomUp(scaled) else {
                    RDPLog.rdp.error(
                        "Slow-path: cannot scale bitmap capture " +
                        "\(frame.width)x\(frame.height) → \(w)x\(h)"
                    )
                    return
                }
                // Dirty rectangles are in source coordinates. After a GPU
                // letterbox transfer, send a full surface instead of reusing
                // coordinates that no longer describe the wire desktop.
                frame = CapturedFrame(
                    width: w,
                    height: h,
                    bgrBottomUp: bgr,
                    dirtyRects: nil,
                    pixelBuffer: scaled
                )
            }
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
