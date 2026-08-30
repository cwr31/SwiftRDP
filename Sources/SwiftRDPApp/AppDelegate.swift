import AppKit
import Darwin
import SwiftRDPCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var sessionManager: SessionManager?
    private var sessionPollTimer: Timer?
    private var observedSessionID: UUID?
    private var instanceLockFD: Int32 = -1
    private let hostAudioSuppressor = HostAudioSuppressor()

    private var prefs: AppPreferences { .shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard acquireInstanceLock() else {
            NSApp.terminate(nil)
            return
        }
        Self.shared = self
        NSApp.setActivationPolicy(.accessory)
        SettingsCoordinator.shared.install()

        startSessionPolling()

        if prefs.launchAtLogin {
            LaunchAtLogin.setEnabled(true)
        }

        prefs.sessionManagerProvider = { [weak self] in
            self?.sessionManager
        }
        prefs.applyAndRestartHandler = { [weak self] in
            self?.restartServer()
        }
        prefs.applyRememberedSessionSettingsLiveHandler = { [weak self] settings in
            self?.applyRememberedSessionSettings(settings)
        }
        prefs.applyVideoAdaptationPriorityLiveHandler = { [weak self] priority in
            self?.sessionManager?.applyVideoAdaptationPriority(priority)
        }
        prefs.applyAudioPlaybackDestinationLiveHandler = { [weak self] destination in
            self?.sessionManager?.applyAudioPlaybackDestination(destination)
            self?.updateRuntimeState()
        }
        prefs.applyRemotePointerScaleHandler = { [weak self] scale in
            self?.sessionManager?.applyRemotePointerScale(scale)
        }
        prefs.applyKnownPeersOnlyLiveHandler = { [weak self] enabled in
            self?.sessionManager?.applyKnownPeersOnly(enabled)
        }
        prefs.applyPowerAssertionsLiveHandler = { [weak self] system, display in
            VirtualDisplayManager.setPowerPolicy(
                preventSystemSleep: system,
                preventDisplaySleep: display
            )
            self?.sessionManager?.applyPowerAssertions(
                preventSystemSleep: system,
                preventDisplaySleep: display
            )
        }

        DispatchQueue.main.async {
            if !PermissionGate.allGranted {
                _ = PermissionGate.requestScreenRecording()
                PermissionGate.requestAccessibility(prompt: true)
                SettingsCoordinator.shared.open(section: .permissions)
            }
            if self.prefs.autoStartServer {
                self.startServer()
            } else {
                self.updateRuntimeState()
            }
            RDPLog.app.info(
                "Menu bar app ready release=\(AppBuildInfo.releaseVersion) "
                + "build=\(AppBuildInfo.buildVersion)"
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionPollTimer?.invalidate()
        hostAudioSuppressor.setSuppressed(false)
        if let manager = sessionManager {
            Task { await manager.stop() }
        }
        if instanceLockFD >= 0 {
            close(instanceLockFD)
            instanceLockFD = -1
        }
    }

    private func acquireInstanceLock() -> Bool {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.swiftrdp.app.lock")
        let fd = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            RDPLog.app.error("Unable to create instance lock")
            return false
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            RDPLog.app.info("Another SwiftRDP instance is already running")
            return false
        }
        instanceLockFD = fd
        return true
    }

    func toggleServer() {
        if prefs.isServerRunning {
            stopServer()
        } else {
            startServer()
        }
    }

    func copyConnection() {
        let addresses = prefs.connectionAddresses()
        let text = addresses.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        RDPLog.app.info("Copied connection address(es): \(text)")
    }

    func disconnectClient() {
        guard prefs.isServerRunning, let manager = sessionManager else { return }
        RDPLog.app.info("Disconnect: terminating current client")
        manager.terminateCurrentSession()
        updateRuntimeState()
    }

    func quit() {
        stopServer()
        NSApp.terminate(nil)
    }

    func applyVideoQuality(_ preset: VideoQualityPreset) {
        RDPLog.app.notice("Video quality -> \(preset.title)")
        if let manager = sessionManager, manager.hasActiveSession {
            updateRememberedSettings(for: manager.connectionSnapshot) {
                $0.videoBitrate = preset.rawValue
            }
        } else {
            prefs.videoBitrate = preset.rawValue
        }
    }

    func applyVideoFPS(_ preset: VideoFPSPreset) {
        RDPLog.app.notice("Video FPS -> \(preset.title)")
        if let manager = sessionManager, manager.hasActiveSession {
            updateRememberedSettings(for: manager.connectionSnapshot) {
                $0.videoFPS = preset.rawValue
            }
        } else {
            prefs.videoFPS = preset.rawValue
        }
    }

    func applyAudioDestination(_ destination: AudioPlaybackDestination) {
        if let manager = sessionManager, manager.hasActiveSession {
            let snapshot = manager.connectionSnapshot
            guard destination != snapshot.audioPlaybackDestination else { return }
            updateRememberedSettings(for: snapshot) {
                $0.audioPlaybackDestination = destination
            }
        } else {
            guard destination != prefs.audioPlaybackDestination else { return }
            prefs.audioPlaybackDestination = destination
        }
        RDPLog.app.notice("Audio playback -> \(destination.rawValue)")
    }

    func applyResolution(_ option: HostResolutionOption) {
        guard option.width > 0, option.height > 0,
              let manager = sessionManager, manager.hasActiveSession else { return }

        let resolution = RememberedResolution(
            width: option.width,
            height: option.height,
            logicalWidth: option.pointWidth,
            logicalHeight: option.pointHeight,
            hiDPI: option.hiDPI
        )
        updateRememberedSettings(for: manager.connectionSnapshot) {
            $0.resolution = resolution
        }
        RDPLog.app.notice("Resolution -> \(option.pointWidth)x\(option.pointHeight)")
    }

    private func restartServer() {
        RDPLog.app.info("Applying settings - restarting server")
        prefs.isServerRestarting = true
        updateRuntimeState()

        guard let manager = sessionManager else {
            startServer()
            return
        }

        Task {
            await manager.stop()
            sessionManager = nil
            prefs.isServerRunning = false
            updateRuntimeState()
            try? await Task.sleep(nanoseconds: 300_000_000)
            startServer()
        }
    }

    private func startServer() {
        guard !prefs.isServerRunning else { return }

        let config = prefs.makeServerConfig()
        let manager = SessionManager(config: config)
        let rememberedStore = prefs.rememberedSessionStore
        manager.rememberedSettingsProvider = { identity in
            rememberedStore.settings(for: identity)
        }
        VirtualDisplayManager.setPowerPolicy(
            preventSystemSleep: prefs.preventSystemSleep,
            preventDisplaySleep: prefs.preventDisplaySleep
        )
        sessionManager = manager

        Task {
            do {
                try await manager.start()
                manager.applyPowerAssertions(
                    preventSystemSleep: prefs.preventSystemSleep,
                    preventDisplaySleep: prefs.preventDisplaySleep
                )
                prefs.isServerRunning = true
                prefs.isServerRestarting = false
                updateRuntimeState()
            } catch {
                RDPLog.app.error("Failed to start server: \(error)")
                sessionManager = nil
                prefs.isServerRunning = false
                prefs.isServerRestarting = false
                updateRuntimeState()

                let alert = NSAlert()
                alert.messageText = L10n.t(.serverStartFailed)
                alert.informativeText = L10n.format(.serverStartFailedBody, config.port)
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    private func stopServer() {
        guard let manager = sessionManager else {
            prefs.isServerRunning = false
            prefs.isServerRestarting = false
            updateRuntimeState()
            return
        }

        Task {
            await manager.stop()
            sessionManager = nil
            prefs.isServerRunning = false
            prefs.isServerRestarting = false
            updateRuntimeState()
        }
    }

    private func startSessionPolling() {
        sessionPollTimer?.invalidate()
        sessionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateRuntimeState() }
        }
    }

    private func updateRuntimeState() {
        let running = prefs.isServerRunning
        let restarting = prefs.isServerRestarting
        let manager = sessionManager
        let snapshot = manager?.connectionSnapshot ?? .empty
        let active = !restarting && running && manager?.hasActiveSession == true
        let currentID = active ? snapshot.sessionID : nil

        if let currentID, observedSessionID != currentID {
            prefs.rememberConnection(
                clientName: snapshot.clientName,
                peerAddress: snapshot.peerAddress
            )
        }
        observedSessionID = currentID

        if restarting {
            prefs.sessionStatusText = L10n.t(.serverRestarting)
        } else if !running {
            prefs.sessionStatusText = L10n.t(.serverStopped)
        } else if active {
            let client = snapshot.clientName.isEmpty
                ? L10n.t(.clientFallback)
                : snapshot.clientName
            var parts = [L10n.t(.connected), client]
            if !snapshot.encodingLabel.isEmpty {
                parts.append(snapshot.encodingLabel)
            }
            prefs.sessionStatusText = parts.joined(separator: " · ")
        } else {
            prefs.sessionStatusText = L10n.t(.noActiveSession)
        }

        let suppressHost = active && snapshot.audioPlaybackDestination.suppressesHost
        if !hostAudioSuppressor.setSuppressed(suppressHost), suppressHost {
            updateRememberedSettings(for: snapshot) {
                $0.audioPlaybackDestination = .both
            }
        }
    }

    private func updateRememberedSettings(
        for snapshot: SessionManager.ConnectionSnapshot,
        mutate: (inout RememberedSessionSettings) -> Void
    ) {
        let identity = SessionClientIdentity(
            clientName: snapshot.clientName,
            peerAddress: snapshot.peerAddress
        )
        var settings = prefs.rememberedSessionStore.settings(for: identity)
            ?? RememberedSessionSettings(
                identity: identity,
                videoBitrate: prefs.videoBitrate,
                videoFPS: prefs.videoFPS,
                audioPlaybackDestination: prefs.audioPlaybackDestination
            )
        mutate(&settings)
        settings.lastConnectedAt = Date()
        prefs.updateRememberedSessionSettings(settings)
    }

    private func applyRememberedSessionSettings(_ settings: RememberedSessionSettings) {
        guard let manager = sessionManager, manager.hasActiveSession else { return }
        let snapshot = manager.connectionSnapshot
        guard SessionClientIdentity(
            clientName: snapshot.clientName,
            peerAddress: snapshot.peerAddress
        ).stableKey == settings.id else { return }

        manager.applyVideoBitrate(settings.videoBitrate, to: snapshot.sessionID)
        manager.applyVideoFPS(settings.videoFPS, to: snapshot.sessionID)
        manager.applyAudioPlaybackDestination(
            settings.audioPlaybackDestination,
            to: snapshot.sessionID
        )
        if let resolution = settings.resolution {
            manager.applyHostResolution(
                width: resolution.width,
                height: resolution.height,
                preferHiDPI: resolution.hiDPI,
                logicalWidth: resolution.logicalWidth,
                logicalHeight: resolution.logicalHeight
            )
        }
        updateRuntimeState()
    }
}
