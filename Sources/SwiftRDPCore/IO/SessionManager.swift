import CoreGraphics
import Foundation
import NIO
import NIOSSL
import NIOTLS

/// TCP bind + live session registry.
public final class SessionManager: @unchecked Sendable {
    public private(set) var config: ServerConfig
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?

    private let registryLock = NSLock()
    private struct SessionLifecycle {
        let connectedAt: Date
        var wasActive = false
        var authFailed = false

        init(connectedAt: Date = Date()) {
            self.connectedAt = connectedAt
        }
    }

    /// The one TCP session allowed by the server. It may be connecting or active.
    private var currentSession: RDPSession?
    /// Retained briefly by session ID so an asynchronously closing displaced socket
    /// can finish its audit without touching the replacement session.
    private var sessionLifecycles: [UUID: SessionLifecycle] = [:]
    public let sharedVirtualDisplay = VirtualDisplayManager()
    /// One raw screen capture owned by the current desktop session.
    public let sharedScreenCapture = SharedScreenCapture()
    /// Resolved runtime mode after applying the configured host-display policy.
    public private(set) var hostDisplayMode: HostDisplayMode
    /// Menu-bar override for Virtual Display size (0 = follow latest client / default).
    public private(set) var virtualOverrideWidth = 0
    public private(set) var virtualOverrideHeight = 0
    public private(set) var virtualOverrideHiDPI = false
    public private(set) var virtualOverrideLogicalWidth = 0
    public private(set) var virtualOverrideLogicalHeight = 0
    private var displayReconfigRegistered = false
    private var topologyRefreshTask: Task<Void, Never>?
    private var pendingDisplayReconfigurationFlags: CGDisplayChangeSummaryFlags = []
    private var virtualDisplayDestroyTask: Task<Void, Never>?
    private var virtualDisplayDestroyGeneration: UInt64 = 0
    /// Refcount for CGDisplayHideCursor — hide on first desktop, show when last leaves.
    private var hostCursorRetainCount = 0

    /// Auto-Reconnect cookies (MS-RDPBCGR ARC) keyed by LogonId.
    private var autoReconnectCookies: [UInt32: (cookie: [UInt8], created: Date)] = [:]
    private var nextLogonId: UInt32 = 1

    private static let arcCookieTTL: TimeInterval = 3600

    public let audit: ConnectionAudit
    /// App-provided durable settings lookup. Called after client identity is known,
    /// immediately before the desktop is created.
    public var rememberedSettingsProvider: (@Sendable (SessionClientIdentity) -> RememberedSessionSettings?)?

    public init(config: ServerConfig, audit: ConnectionAudit = .shared) {
        self.config = config
        self.audit = audit
        self.hostDisplayMode = DisplayTopology.preferredMode(policy: config.hostDisplayPolicy)
    }

    /// Reset host cursor retain count under lock (sync helper for async callers).
    private func resetHostCursorRetainCount() -> Bool {
        registryLock.lock()
        let result = hostCursorRetainCount > 0
        hostCursorRetainCount = 0
        registryLock.unlock()
        return result
    }

    public func applyVideoBitrate(_ bps: Int, to sessionID: UUID) {
        registryLock.lock()
        let session = currentSession?.id == sessionID && currentSession?.phase == .active
            ? currentSession
            : nil
        registryLock.unlock()
        session?.applyVideoBitrate(bps)
    }

    public func applyKnownPeersOnly(_ enabled: Bool) {
        registryLock.lock()
        config.knownPeersOnly = enabled
        registryLock.unlock()
        RDPLog.io.info("Connection access policy: knownPeersOnly=\(enabled)")
    }

    public func applyVideoFPS(_ fps: Int, to sessionID: UUID) {
        registryLock.lock()
        let session = currentSession?.id == sessionID && currentSession?.phase == .active
            ? currentSession
            : nil
        registryLock.unlock()
        session?.applyVideoFPS(fps)
    }

    /// Live adaptation-priority UI update — applies without restart.
    public func applyVideoAdaptationPriority(_ priority: VideoAdaptationPriority) {
        config.videoAdaptationPriority = priority
        activeDesktopSession()?.applyVideoAdaptationPriority(priority)
        RDPLog.io.info("SessionManager: live adaptation priority → \(priority.rawValue)")
    }

    /// Apply one settled value to current sessions and retain it for future connections.
    public func applyRemotePointerScale(_ scale: Double) {
        let scale = CursorTracker.normalizedScale(scale)
        config.remotePointerScale = scale
        activeDesktopSession()?.applyRemotePointerScale(scale)
        RDPLog.io.info("SessionManager: pointer scale → \(scale)x")
    }

    public func applyAudioPlaybackDestination(
        _ destination: AudioPlaybackDestination,
        to sessionID: UUID
    ) {
        registryLock.lock()
        let session = currentSession?.id == sessionID ? currentSession : nil
        registryLock.unlock()
        session?.applyAudioPlaybackDestination(destination)
    }

    /// Live global audio destination update — applies to the current session.
    public func applyAudioPlaybackDestination(_ destination: AudioPlaybackDestination) {
        config.audioPlaybackDestination = destination
        registryLock.lock()
        let session = currentSession
        registryLock.unlock()
        session?.applyAudioPlaybackDestination(destination)
        RDPLog.io.info("SessionManager: live audio playback → \(destination.rawValue)")
    }

    // MARK: - Host display mode + resolution menu

    public var usesVirtualDisplay: Bool {
        hostDisplayMode == .virtualMatchClient
    }

    /// Resolutions for the menu bar (mode-dependent).
    public func hostResolutionOptions() -> [HostResolutionOption] {
        switch hostDisplayMode {
        case .physicalMirror:
            guard let displayID = DisplayTopology.physicalDisplayID(
                preferredIdentity: config.selectedDisplayIdentity
            ) else {
                return []
            }
            return DisplayTopology.physicalResolutionOptions(displayID: displayID)
        case .virtualMatchClient:
            let snap = connectionSnapshot
            let vd = sharedVirtualDisplay
            let currentHiDPI: Bool
            let currentLogicalW: Int
            let currentLogicalH: Int
            if virtualOverrideWidth > 0, virtualOverrideHeight > 0 {
                currentHiDPI = virtualOverrideHiDPI
                currentLogicalW = virtualOverrideHiDPI
                    ? (virtualOverrideLogicalWidth > 0 ? virtualOverrideLogicalWidth : virtualOverrideWidth / 2)
                    : virtualOverrideWidth
                currentLogicalH = virtualOverrideHiDPI
                    ? (virtualOverrideLogicalHeight > 0 ? virtualOverrideLogicalHeight : virtualOverrideHeight / 2)
                    : virtualOverrideHeight
            } else if vd.active, vd.logicalWidth > 0, vd.logicalHeight > 0 {
                currentHiDPI = vd.preferHiDPI
                currentLogicalW = vd.logicalWidth
                currentLogicalH = vd.logicalHeight
            } else if vd.requestedWidth > 0 {
                currentHiDPI = vd.preferHiDPI
                currentLogicalW = vd.logicalWidth > 0 ? vd.logicalWidth : vd.requestedWidth
                currentLogicalH = vd.logicalHeight > 0 ? vd.logicalHeight : vd.requestedHeight
            } else {
                currentHiDPI = false
                currentLogicalW = snap.width > 0 ? snap.width : 1920
                currentLogicalH = snap.height > 0 ? snap.height : 1080
            }
            return DisplayTopology.virtualResolutionOptions(
                currentLogicalWidth: currentLogicalW,
                currentLogicalHeight: currentLogicalH,
                currentHiDPI: currentHiDPI,
                clientWidth: snap.width,
                clientHeight: snap.height
            )
        }
    }

    /// Pixel + HiDPI parameters for creating or refreshing the shared Virtual Display.
    public func virtualDisplayParameters(
        clientWidth: Int,
        clientHeight: Int
    ) -> VirtualDisplayParameters {
        if virtualOverrideWidth > 0, virtualOverrideHeight > 0 {
            let logicalW = virtualOverrideHiDPI
                ? (virtualOverrideLogicalWidth > 0 ? virtualOverrideLogicalWidth : virtualOverrideWidth / 2)
                : virtualOverrideWidth
            let logicalH = virtualOverrideHiDPI
                ? (virtualOverrideLogicalHeight > 0 ? virtualOverrideLogicalHeight : virtualOverrideHeight / 2)
                : virtualOverrideHeight
            return VirtualDisplayParameters(
                pixelWidth: virtualOverrideWidth,
                pixelHeight: virtualOverrideHeight,
                preferHiDPI: virtualOverrideHiDPI,
                logicalWidth: logicalW,
                logicalHeight: logicalH
            )
        }
        return .native(pixelWidth: clientWidth, pixelHeight: clientHeight)
    }

    /// Menu-bar resolution pick — applies immediately.
    /// Physical: `width`/`height` are CG “Looks like” points (must not be even-aligned —
    /// many System Settings sizes are odd, e.g. 1512×945); `preferHiDPI` selects the Retina twin.
    public func applyHostResolution(
        width: Int,
        height: Int,
        preferHiDPI: Bool = true,
        logicalWidth: Int? = nil,
        logicalHeight: Int? = nil
    ) {
        switch hostDisplayMode {
        case .physicalMirror:
            // Keep exact Looks-like points for CGDisplayMode matching.
            let w = max(width, 1)
            let h = max(height, 1)
            guard let displayID = DisplayTopology.physicalDisplayID(
                preferredIdentity: config.selectedDisplayIdentity
            ) else {
                RDPLog.io.error("SessionManager: no physical display for resolution apply")
                return
            }
            guard DisplayTopology.applyPhysicalResolution(
                displayID: displayID,
                width: w,
                height: h,
                preferHiDPI: preferHiDPI
            ) else {
                return
            }
            let tag = preferHiDPI ? " HiDPI" : ""
            refreshActiveDesktops(reason: "physical resolution \(w)x\(h)\(tag)")
        case .virtualMatchClient:
            let (w, h) = VirtualDisplayParameters.fitWithinPixelLimit(
                width: width,
                height: height
            )
            let logicalW = preferHiDPI ? w / 2 : w
            let logicalH = preferHiDPI ? h / 2 : h
            virtualOverrideWidth = w
            virtualOverrideHeight = h
            virtualOverrideHiDPI = preferHiDPI
            virtualOverrideLogicalWidth = logicalW
            virtualOverrideLogicalHeight = logicalH
            if sharedVirtualDisplay.active || activeDesktopSession() != nil {
                sharedVirtualDisplay.createMatching(
                    width: w,
                    height: h,
                    preferHiDPI: preferHiDPI,
                    logicalWidth: logicalW,
                    logicalHeight: logicalH
                )
            }
            activeDesktopSession()?.applyHostResolution(width: w, height: h)
            let tag = preferHiDPI ? " HiDPI \(logicalW)x\(logicalH)" : ""
            RDPLog.io.info("SessionManager: virtual resolution → \(w)x\(h)\(tag)")
        }
    }

    /// Recompute physical vs virtual from attached displays; rebind sessions on change.
    @discardableResult
    public func refreshHostDisplayMode(reason: String) -> Bool {
        let next = DisplayTopology.preferredMode(policy: config.hostDisplayPolicy)
        guard next != hostDisplayMode else { return false }
        let previous = hostDisplayMode
        hostDisplayMode = next
        RDPLog.io.info(
            "SessionManager: host display \(previous.rawValue) → \(next.rawValue) (\(reason))"
        )
        if next == .physicalMirror {
            virtualOverrideWidth = 0
            virtualOverrideHeight = 0
            virtualOverrideHiDPI = false
            virtualOverrideLogicalWidth = 0
            virtualOverrideLogicalHeight = 0
            if sharedVirtualDisplay.active {
                sharedVirtualDisplay.destroy()
            }
        }
        refreshActiveDesktops(reason: "mode \(next.rawValue)")
        resyncPowerAssertions(reason: "mode \(next.rawValue)")
        return true
    }

    func noteDisplayTopologyChanged(flags: CGDisplayChangeSummaryFlags) {
        registryLock.lock()
        pendingDisplayReconfigurationFlags.formUnion(flags)
        topologyRefreshTask?.cancel()
        topologyRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            let flags = self.takePendingDisplayReconfigurationFlags()
            guard !flags.isEmpty else { return }
            self.handleDisplayReconfiguration(flags)
        }
        registryLock.unlock()
    }

    private func takePendingDisplayReconfigurationFlags() -> CGDisplayChangeSummaryFlags {
        registryLock.lock()
        let flags = pendingDisplayReconfigurationFlags
        pendingDisplayReconfigurationFlags = []
        topologyRefreshTask = nil
        registryLock.unlock()
        return flags
    }

    private func handleDisplayReconfiguration(_ flags: CGDisplayChangeSummaryFlags) {
        let impact = DisplayTopology.reconfigurationImpact(
            flags: flags,
            autoSelectPrimary: config.selectedDisplayIdentity.isEmpty
        )
        switch impact {
        case .topology:
            let modeChanged = refreshHostDisplayMode(reason: "display topology")
            if !modeChanged, hostDisplayMode == .physicalMirror {
                refreshActiveDesktops(reason: "display topology")
            }
        case .geometry:
            if hostDisplayMode == .physicalMirror {
                refreshActiveDesktops(reason: "display geometry")
            } else if sharedVirtualDisplay.active {
                _ = sharedVirtualDisplay.restoreRequestedMode(context: "display reconfiguration")
            }
        case .none:
            RDPLog.io.debug("SessionManager: display metadata changed flags=\(flags.rawValue)")
        }
    }

    /// Live-apply Settings power assertions to the shared virtual display and client.
    public func applyPowerAssertions(preventSystemSleep: Bool, preventDisplaySleep: Bool) {
        VirtualDisplayManager.setPowerPolicy(
            preventSystemSleep: preventSystemSleep,
            preventDisplaySleep: preventDisplaySleep
        )
        sharedVirtualDisplay.reapplyWakeAssertions()
        activeDesktopSession()?.reapplyPowerAssertions()
        RDPLog.io.info(
            "SessionManager: power assertions system=\(preventSystemSleep) " +
            "display=\(VirtualDisplayManager.effectivePreventDisplaySleep())"
        )
    }

    /// Re-assert Settings power policy after VD destroy / mode flips.
    private func resyncPowerAssertions(reason: String) {
        sharedVirtualDisplay.reapplyWakeAssertions()
        activeDesktopSession()?.reapplyPowerAssertions()
        RDPLog.io.info("SessionManager: power assertions resync (\(reason))")
    }

    private func refreshActiveDesktops(reason: String) {
        activeDesktopSession()?.rebindHostDisplay(reason: reason)
    }

    private func activeDesktopSession() -> RDPSession? {
        registryLock.lock()
        defer { registryLock.unlock() }
        guard let session = currentSession,
              session.phase == .active,
              sessionLifecycles[session.id]?.wasActive == true else {
            return nil
        }
        return session
    }

    private func registerDisplayReconfigObserver() {
        guard !displayReconfigRegistered else { return }
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        let err = CGDisplayRegisterReconfigurationCallback(Self.displayReconfigTrampoline, ptr)
        if err == .success {
            displayReconfigRegistered = true
            RDPLog.io.info("SessionManager: display reconfiguration observer registered")
        } else {
            RDPLog.io.error("SessionManager: display reconfiguration observer failed err=\(err.rawValue)")
        }
    }

    private func unregisterDisplayReconfigObserver() {
        guard displayReconfigRegistered else { return }
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(Self.displayReconfigTrampoline, ptr)
        displayReconfigRegistered = false
        registryLock.lock()
        topologyRefreshTask?.cancel()
        topologyRefreshTask = nil
        pendingDisplayReconfigurationFlags = []
        registryLock.unlock()
    }

    private static let displayReconfigTrampoline: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        guard let userInfo else { return }
        // Ignore the begin half of a configure transaction.
        if (flags.rawValue & CGDisplayChangeSummaryFlags.beginConfigurationFlag.rawValue) != 0 {
            return
        }
        let manager = Unmanaged<SessionManager>.fromOpaque(userInfo).takeUnretainedValue()
        manager.noteDisplayTopologyChanged(flags: flags)
    }

    /// Install the new connection as the only current session and displace the old
    /// one before the new handshake proceeds.
    public func registerSession(_ session: RDPSession) {
        let displaced: RDPSession?
        registryLock.lock()
        cancelVirtualDisplayDestroyLocked()
        displaced = currentSession
        currentSession = session
        session.sessionManager = self
        sessionLifecycles[session.id] = SessionLifecycle()
        registryLock.unlock()

        if let displaced, displaced.id != session.id {
            RDPLog.io.info(
                "SessionManager: replacing client old=\(displaced.id.uuidString) " +
                "new=\(session.id.uuidString)"
            )
            displaced.terminate()
        }
    }

    /// Promote only after RDP authentication/capability finalization succeeds.
    @discardableResult
    public func promoteSession(_ session: RDPSession) -> Bool {
        registryLock.lock()
        guard currentSession?.id == session.id else {
            registryLock.unlock()
            return false
        }

        sessionLifecycles[session.id]?.wasActive = true
        RDPLog.io.info("SessionManager: client promoted id=\(session.id.uuidString)")
        let peer = session.info.peerAddress
        let user = session.info.userName
        let client = session.info.clientName
        let security = session.info.securityLabel
        registryLock.unlock()

        let identity = SessionClientIdentity(clientName: client, peerAddress: peer)
        if let settings = rememberedSettingsProvider?(identity) {
            session.applyVideoBitrate(settings.videoBitrate)
            session.applyVideoFPS(settings.videoFPS)
            session.applyAudioPlaybackDestination(settings.audioPlaybackDestination)
            if let resolution = settings.resolution {
                restoreVirtualCaptureResolution(resolution)
            }
            RDPLog.io.info("SessionManager: restored settings for \(identity.displayName)")
        }

        audit.recordAuthSuccess(peerAddress: peer)
        audit.record(
            sessionID: session.id,
            peerAddress: peer.isEmpty ? "unknown" : peer,
            userName: user,
            clientName: client,
            securityLabel: security,
            outcome: .active,
            detail: "Desktop session active"
        )
        return true
    }

    private func restoreVirtualCaptureResolution(_ resolution: RememberedResolution) {
        guard hostDisplayMode == .virtualMatchClient else { return }
        let fitted = VirtualDisplayParameters.fitWithinPixelLimit(
            width: resolution.width,
            height: resolution.height
        )
        virtualOverrideWidth = fitted.0
        virtualOverrideHeight = fitted.1
        virtualOverrideHiDPI = resolution.hiDPI
        virtualOverrideLogicalWidth = max(resolution.logicalWidth, 1)
        virtualOverrideLogicalHeight = max(resolution.logicalHeight, 1)
        RDPLog.io.info(
            "SessionManager: restored virtual capture source " +
            String(fitted.0) + "x" + String(fitted.1) +
            " (remembered logical " + String(resolution.logicalWidth) + "x" +
            String(resolution.logicalHeight) + ")"
        )
    }

    public func allowConnection(from address: SocketAddress?) -> Bool {
        let key = address?.ipAddress ?? "unknown"

        registryLock.lock()
        let knownPeersOnly = config.knownPeersOnly
        registryLock.unlock()
        return !knownPeersOnly || audit.isKnownPeer(key)
    }


    /// Record a new inbound handshake for the Connections history.
    public func noteHandshakeStarted(_ session: RDPSession) {
        audit.record(
            sessionID: session.id,
            peerAddress: session.info.peerAddress.isEmpty ? "unknown" : session.info.peerAddress,
            outcome: .connecting,
            detail: "Handshake started"
        )
    }

    /// Record a CredSSP / Client Info password failure for connection history.
    public func noteAuthenticationFailure(
        session: RDPSession,
        userName: String,
        detail: String
    ) {
        registryLock.lock()
        sessionLifecycles[session.id]?.authFailed = true
        registryLock.unlock()
        let peer = session.info.peerAddress.isEmpty ? "unknown" : session.info.peerAddress
        audit.recordAuthFailure(
            peerAddress: peer,
            userName: userName,
            sessionID: session.id,
            detail: detail
        )
    }

    public func liveClientSnapshot() -> LiveClientSnapshot? {
        registryLock.lock()
        let session = currentSession
        let lifecycle = session.flatMap { sessionLifecycles[$0.id] }
        registryLock.unlock()

        guard let session else { return nil }
        let w = session.info.width > 0 ? session.info.width : session.clientWidth
        let h = session.info.height > 0 ? session.info.height : session.clientHeight
        let activeSnapshot = lifecycle?.wasActive == true ? makeSnapshot(session: session) : nil
        return LiveClientSnapshot(
            id: session.id,
            state: lifecycle?.wasActive == true ? .active : .connecting,
            peerAddress: session.info.peerAddress,
            userName: session.info.userName,
            clientName: session.info.clientName,
            securityLabel: session.info.securityLabel,
            phaseLabel: Self.phaseLabel(session.phase),
            width: w,
            height: h,
            connectedAt: lifecycle?.connectedAt ?? Date(),
            quality: activeSnapshot?.quality,
            captureSkippedFrames: activeSnapshot?.captureSkippedFrames ?? 0
        )
    }

    public static func phaseLabel(_ phase: RDPSession.Phase) -> String {
        switch phase {
        case .connectionInitiation: return "X.224"
        case .tls: return "TLS"
        case .credssp: return "NLA"
        case .basicSettings: return "MCS"
        case .channelConnection: return "Channels"
        case .secureSettings: return "Client Info"
        case .licensing: return "License"
        case .capabilities: return "Capabilities"
        case .connectionFinalization: return "Finalizing"
        case .active: return "Active"
        case .terminated: return "Terminated"
        }
    }

    public func unregisterSession(_ session: RDPSession) {
        let shouldDestroySharedVD: Bool
        registryLock.lock()
        let lifecycle = sessionLifecycles.removeValue(forKey: session.id)
        let wasCurrent = currentSession?.id == session.id
        let wasActive = lifecycle?.wasActive ?? false
        let authFailed = lifecycle?.authFailed ?? false
        let connectedAt = lifecycle?.connectedAt
        if wasCurrent {
            currentSession = nil
        }
        shouldDestroySharedVD = wasCurrent && currentSession == nil
        registryLock.unlock()

        if !authFailed {
            let peer = session.info.peerAddress.isEmpty ? "unknown" : session.info.peerAddress
            let duration: Int? = connectedAt.map { Int(Date().timeIntervalSince($0).rounded()) }
            if wasActive {
                audit.record(
                    sessionID: session.id,
                    peerAddress: peer,
                    userName: session.info.userName,
                    clientName: session.info.clientName,
                    securityLabel: session.info.securityLabel,
                    outcome: .disconnected,
                    detail: "Session disconnected",
                    durationSeconds: duration
                )
            } else {
                audit.record(
                    sessionID: session.id,
                    peerAddress: peer,
                    userName: session.info.userName,
                    clientName: session.info.clientName,
                    securityLabel: session.info.securityLabel,
                    outcome: .abandoned,
                    detail: "Handshake closed before desktop",
                    durationSeconds: duration
                )
            }
        }

        if shouldDestroySharedVD { scheduleVirtualDisplayDestroy() }
    }

    private func cancelVirtualDisplayDestroyLocked() {
        virtualDisplayDestroyGeneration &+= 1
        virtualDisplayDestroyTask?.cancel()
        virtualDisplayDestroyTask = nil
    }

    private func scheduleVirtualDisplayDestroy() {
        registryLock.lock()
        cancelVirtualDisplayDestroyLocked()
        let generation = virtualDisplayDestroyGeneration
        virtualDisplayDestroyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.canDestroySharedResources(generation: generation) else { return }
            await self.sharedScreenCapture.stopIfIdle()
            guard !Task.isCancelled else { return }
            self.destroyVirtualDisplayIfIdle(generation: generation)
        }
        registryLock.unlock()
    }

    private func canDestroySharedResources(generation: UInt64) -> Bool {
        registryLock.lock()
        defer { registryLock.unlock() }
        return generation == virtualDisplayDestroyGeneration
            && currentSession == nil
    }

    private func destroyVirtualDisplayIfIdle(generation: UInt64) {
        let destroyed = sharedVirtualDisplay.destroyIf {
            registryLock.lock()
            defer { registryLock.unlock() }
            guard generation == virtualDisplayDestroyGeneration,
                  currentSession == nil else { return false }
            virtualDisplayDestroyTask = nil
            return true
        }
        if destroyed {
            RDPLog.io.info("SessionManager: shared display state cleared (client left)")
        }
    }

    private func cancelVirtualDisplayDestroy() {
        registryLock.lock()
        cancelVirtualDisplayDestroyLocked()
        registryLock.unlock()
    }

    // MARK: - Auto-Reconnect (ARC)

    /// Allocate LogonId + 16-byte ARC cookie for Save Session Info.
    public func issueAutoReconnectCookie() -> (logonId: UInt32, cookie: [UInt8]) {
        registryLock.lock()
        defer { registryLock.unlock() }
        pruneExpiredARCCookiesLocked()
        let logonId = nextLogonId
        nextLogonId &+= 1
        if nextLogonId == 0 { nextLogonId = 1 }
        var cookie = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, cookie.count, &cookie)
        if status != errSecSuccess {
            for i in 0..<16 { cookie[i] = UInt8.random(in: 0...255) }
        }
        autoReconnectCookies[logonId] = (cookie, Date())
        RDPLog.io.info("ARC: issued logonId=\(logonId)")
        return (logonId, cookie)
    }

    /// Validate client ARC cookie from Client Info extended data.
    public func validateAutoReconnectCookie(logonId: UInt32, cookie: [UInt8]) -> Bool {
        registryLock.lock()
        defer { registryLock.unlock() }
        pruneExpiredARCCookiesLocked()
        guard let entry = autoReconnectCookies[logonId] else { return false }
        guard entry.cookie.count == cookie.count else { return false }
        var mismatch: UInt8 = 0
        for i in 0..<cookie.count {
            mismatch |= entry.cookie[i] ^ cookie[i]
        }
        let ok = mismatch == 0
        if ok {
            RDPLog.io.info("ARC: validated logonId=\(logonId)")
        }
        return ok
    }

    private func pruneExpiredARCCookiesLocked() {
        let cutoff = Date().addingTimeInterval(-Self.arcCookieTTL)
        autoReconnectCookies = autoReconnectCookies.filter { $0.value.created >= cutoff }
    }

    public func session(for id: UUID) -> RDPSession? {
        registryLock.lock()
        defer { registryLock.unlock() }
        return currentSession?.id == id ? currentSession : nil
    }

    /// Capture target used by sessions: shared VD id, else config/primary.
    public func sharedCaptureDisplayID() -> UInt32? {
        if sharedScreenCapture.isRunning,
           let selected = sharedScreenCapture.selectedDisplayID,
           selected != 0 {
            return selected
        }
        if sharedVirtualDisplay.active, sharedVirtualDisplay.displayID != 0 {
            return sharedVirtualDisplay.displayID
        }
        return DisplayTopology.physicalDisplayID(
            preferredIdentity: config.selectedDisplayIdentity
        )
    }

    public var hasActiveSession: Bool {
        registryLock.lock()
        defer { registryLock.unlock() }
        guard let session = currentSession else { return false }
        return sessionLifecycles[session.id]?.wasActive == true
    }

    public func terminateSession(id: UUID) {
        let session: RDPSession? = {
            registryLock.lock()
            defer { registryLock.unlock() }
            return currentSession?.id == id ? currentSession : nil
        }()
        session?.terminate()
    }

    public func terminateCurrentSession() {
        let session: RDPSession? = {
            registryLock.lock()
            defer { registryLock.unlock() }
            return currentSession
        }()
        session?.terminate()
    }

    // MARK: - Host cursor refcount

    public func retainHostCursorHidden() {
        registryLock.lock()
        hostCursorRetainCount += 1
        let count = hostCursorRetainCount
        registryLock.unlock()
        if count == 1 {
            CGDisplayHideCursor(CGMainDisplayID())
            RDPLog.io.info("Cursor: host cursor hidden (client System Pointer)")
        }
    }

    public func releaseHostCursorHidden() {
        registryLock.lock()
        hostCursorRetainCount = max(0, hostCursorRetainCount - 1)
        let count = hostCursorRetainCount
        registryLock.unlock()
        if count == 0 {
            CGDisplayShowCursor(CGMainDisplayID())
            RDPLog.io.info("Cursor: host cursor restored")
        }
    }

    /// Test/inspection helper — current hide retain count.
    public var hostCursorHiddenRetainCount: Int {
        registryLock.lock()
        defer { registryLock.unlock() }
        return hostCursorRetainCount
    }

    /// Snapshot of one active desktop session for menu-bar status.
    public struct ConnectionSnapshot: Sendable {
        public var sessionID: UUID
        public var clientName: String
        public var width: Int
        public var height: Int
        public var avgAckRTTMs: Double
        public var p95AckRTTMs: Double
        public var avgEncodeMs: Double
        public var captureFPS: Double
        public var wireFPS: Double
        public var clientDecodedFPS: Double
        public var captureSkippedFrames: UInt64
        public var targetFPS: Int
        public var configuredFPS: Int
        public var audioPlaybackDestination: AudioPlaybackDestination
        public var targetBitrate: Int
        public var configuredBitrate: Int
        public var lastReportedBitrate: Int
        public var clientQueue: ClientQueueFeedback
        public var clientQueueDelayMs: Double
        public var serverQueueBytes: Int
        public var serverQueueDelayMs: Double
        public var clientRenderMs: Double
        public var hasRTTSamples: Bool
        /// Actual encode path, e.g. "H.264", "RemoteFX", "Bitmap".
        public var encodingLabel: String
        public var stallRecoveryMode: Bool
        public var frameAcknowledgementsSuspended: Bool
        public var bitrateReduced: Bool
        public var quality: VideoQualityStatus
        public var userName: String
        public var peerAddress: String
        /// "NLA", "NLA-EX", "TLS", …
        public var securityLabel: String
        /// Auto-Detect RTT (ms) / bandwidth (kbps) from Network Characteristics Result.
        public var autoDetectRTTMs: UInt32
        public var autoDetectBandwidthKbps: UInt32
        /// Graphics frames awaiting FRAME_ACK.
        public var gfxUnacked: Int
        public static let empty = ConnectionSnapshot(
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            clientName: "",
            width: 0,
            height: 0,
            avgAckRTTMs: 0,
            p95AckRTTMs: 0,
            avgEncodeMs: 0,
            captureFPS: 0,
            wireFPS: 0,
            clientDecodedFPS: 0,
            captureSkippedFrames: 0,
            targetFPS: 0,
            configuredFPS: 0,
            audioPlaybackDestination: .both,
            targetBitrate: 0,
            configuredBitrate: 0,
            lastReportedBitrate: 0,
            clientQueue: .unavailable,
            clientQueueDelayMs: 0,
            serverQueueBytes: 0,
            serverQueueDelayMs: 0,
            clientRenderMs: 0,
            hasRTTSamples: false,
            encodingLabel: "",
            stallRecoveryMode: false,
            frameAcknowledgementsSuspended: false,
            bitrateReduced: false,
            quality: .empty,
            userName: "",
            peerAddress: "",
            securityLabel: "",
            autoDetectRTTMs: 0,
            autoDetectBandwidthKbps: 0,
            gfxUnacked: 0,
        )
    }

    public var connectionSnapshot: ConnectionSnapshot {
        registryLock.lock()
        defer { registryLock.unlock() }
        guard let session = currentSession,
              sessionLifecycles[session.id]?.wasActive == true else {
            return .empty
        }
        return makeSnapshot(session: session)
    }

    private func makeSnapshot(session: RDPSession) -> ConnectionSnapshot {
        let perf = session.videoController.perfSnapshot
        let captureStats = session.sharedCapture?.captureStatistics
        let name = session.info.clientName
        let w = session.info.width > 0 ? session.info.width : session.clientWidth
        let h = session.info.height > 0 ? session.info.height : session.clientHeight
        return ConnectionSnapshot(
            sessionID: session.id,
            clientName: name,
            width: w,
            height: h,
            avgAckRTTMs: perf.avgAckRTTMs,
            p95AckRTTMs: perf.p95AckRTTMs,
            avgEncodeMs: perf.avgEncodeMs,
            captureFPS: perf.captureFPS,
            wireFPS: perf.wireFPS,
            clientDecodedFPS: perf.clientDecodedFPS,
            captureSkippedFrames: captureStats?.skippedFrames ?? 0,
            targetFPS: perf.targetFPS,
            configuredFPS: session.videoController.configuredFPS,
            audioPlaybackDestination: session.audioPlaybackDestination,
            targetBitrate: perf.targetBitrate,
            configuredBitrate: perf.configuredBitrate,
            lastReportedBitrate: perf.lastReportedBitrate,
            clientQueue: perf.clientQueue,
            clientQueueDelayMs: perf.clientQueueDelayMs,
            serverQueueBytes: perf.serverQueueBytes,
            serverQueueDelayMs: perf.serverQueueDelayMs,
            clientRenderMs: perf.clientRenderMs,
            hasRTTSamples: perf.sampleCount > 0,
            encodingLabel: session.encodingLabel,
            stallRecoveryMode: perf.stallRecoveryMode,
            frameAcknowledgementsSuspended: session.gfx.isFrameAcknowledgementSuspended,
            bitrateReduced: perf.bitrateReduced,
            quality: perf.quality,
            userName: session.info.userName,
            peerAddress: session.info.peerAddress,
            securityLabel: session.info.securityLabel,
            autoDetectRTTMs: session.info.autoDetectRTTMs,
            autoDetectBandwidthKbps: session.info.autoDetectBandwidthKbps,
            gfxUnacked: session.gfx.unackedFrameCount,
        )
    }

    public func start() async throws {
        RDPLog.enableFileLogging(appSupportName: config.appSupportName)
        RDPLog.verbose = config.devLog
        hostDisplayMode = DisplayTopology.preferredMode(policy: config.hostDisplayPolicy)
        registerDisplayReconfigObserver()
        sharedVirtualDisplay.reapplyWakeAssertions()
        RDPLog.io.info(
            "SessionManager: host display policy=\(config.hostDisplayPolicy.rawValue) " +
            "mode=\(hostDisplayMode.rawValue) " +
            "awakeBuiltIn=\(DisplayTopology.hasAwakeBuiltInDisplay()) " +
            "power system=\(VirtualDisplayManager.preventSystemSleep) " +
            "display=\(VirtualDisplayManager.effectivePreventDisplaySleep())"
        )

        let material = try CertStore.ensure(certsDirectory: config.certsURL, commonName: config.serverName)
        var tlsConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(material.certificate)],
            privateKey: .privateKey(material.privateKey)
        )
        // Microsoft RDP clients are unreliable on TLS 1.3 for CredSSP; pin TLS 1.2.
        tlsConfig.minimumTLSVersion = .tlsv12
        switch config.tlsVersionMode {
        case .tls12:
            tlsConfig.maximumTLSVersion = .tlsv12
        case .tls12Or13:
            tlsConfig.maximumTLSVersion = .tlsv13
        }
        let sslContext = try NIOSSLContext(configuration: tlsConfig)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.group = group
        let publicKeyDER = material.subjectPublicKeyInfoDER
        let manager = self

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 8)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                guard manager.allowConnection(from: channel.remoteAddress) else {
                    return channel.close()
                }
                let session = RDPSession(config: manager.config, serverPublicKeyDER: publicKeyDER)
                if let host = channel.remoteAddress?.ipAddress, !host.isEmpty {
                    session.notePeerHost(host)
                } else if let desc = channel.remoteAddress?.description {
                    session.notePeerHost(desc)
                }
                manager.registerSession(session)
                manager.noteHandshakeStarted(session)
                let transport = NIOTransport(session: session, sslContext: sslContext)
                return channel.pipeline.addHandler(transport.inboundHandler)
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .childChannelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            // Keep the TCP write-ahead bounded so interactive static channels are not
            // buried behind a burst of H.264 fragments. Audio is prioritized by the
            // outbound scheduler, while this watermark limits bytes already accepted
            // by NIO before that priority can take effect.
            .childChannelOption(
                ChannelOptions.writeBufferWaterMark,
                value: .init(low: 64 * 1024, high: 256 * 1024)
            )
            // Keep the kernel send buffer bounded for the same reason. A large
            // kernel queue is invisible to NIO's channel writability callback.
            .childChannelOption(
                ChannelOptions.socketOption(.so_sndbuf),
                value: 256 * 1024
            )

        do {
            let ch = try await bootstrap.bind(host: config.bindHost, port: config.port).get()
            self.channel = ch
            RDPLog.io.info("RDP Server listening on port \(config.port)")
        } catch {
            RDPLog.io.error("Could not bind to port \(config.port). Another RDP app or a previous instance may be using this port.")
            throw error
        }

    }

    public func stop() async {
        unregisterDisplayReconfigObserver()
        let sessions: [RDPSession] = {
            registryLock.lock()
            defer { registryLock.unlock() }
            let list = currentSession.map { [$0] } ?? []
            currentSession = nil
            sessionLifecycles.removeAll()
            return list
        }()
        sessions.first?.terminate()
        await sharedScreenCapture.stopAndWait()
        cancelVirtualDisplayDestroy()
        sharedVirtualDisplay.destroy()
        // Ensure host cursor is visible after full stop even if retain leaked.
        let needsShow = resetHostCursorRetainCount()
        if needsShow {
            CGDisplayShowCursor(CGMainDisplayID())
        }
        try? await channel?.close().get()
        try? await group?.shutdownGracefully()
        group = nil
        channel = nil
    }
}
