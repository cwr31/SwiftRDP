import SwiftRDPCore
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var prefs: AppPreferences

    private var manager: SessionManager? {
        prefs.sessionManagerProvider?()
    }

    private var activeSnapshot: SessionManager.ConnectionSnapshot? {
        guard prefs.isServerRunning,
              !prefs.isServerRestarting,
              let manager,
              manager.hasActiveSession else { return nil }
        return manager.connectionSnapshot
    }

    var body: some View {
        Text(prefs.sessionStatusText)
            .font(.headline)

        Text(serverDetail)
            .foregroundStyle(.secondary)

        if let quality = activeSnapshot?.quality {
            Label(qualityStateTitle(quality), systemImage: qualityStateIcon(quality))
                .font(.caption.weight(.semibold))
                .foregroundStyle(quality.state == .healthy ? .green : .orange)
            Text(L10n.format(
                .qualityTarget,
                quality.targetFPS,
                Double(quality.targetBitrate) / 1_000_000
            ))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }

        Divider()

        Button {
            AppDelegate.shared?.toggleServer()
        } label: {
            Label(
                prefs.isServerRunning ? L10n.t(.stopServer) : L10n.t(.startServer),
                systemImage: prefs.isServerRunning ? "stop.fill" : "play.fill"
            )
        }
        .disabled(prefs.isServerRestarting)

        Button {
            AppDelegate.shared?.copyConnection()
        } label: {
            Label(L10n.t(.copyConnectionAddress), systemImage: "doc.on.doc")
        }
        .disabled(!prefs.isServerRunning || prefs.isServerRestarting)

        if activeSnapshot != nil {
            Button {
                AppDelegate.shared?.disconnectClient()
            } label: {
                Label(L10n.t(.disconnectClient), systemImage: "xmark.circle")
            }
        }

        Menu(L10n.t(.resolutionMenu), systemImage: "rectangle.on.rectangle") {
            let options = manager?.hostResolutionOptions() ?? []
            if options.isEmpty {
                Text(L10n.t(.noResolutionOptions))
            } else {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Button {
                        AppDelegate.shared?.applyResolution(option)
                    } label: {
                        choiceLabel(option.title, selected: option.isCurrent)
                    }
                }
            }
        }
        .disabled(activeSnapshot == nil)

        Menu(L10n.t(.menuVideo), systemImage: "film") {
            if prefs.displayMode == .h264 {
                Text(L10n.t(.videoQuality))
                    .font(.caption)
                ForEach(VideoQualityPreset.allCases) { preset in
                    Button {
                        AppDelegate.shared?.applyVideoQuality(preset)
                    } label: {
                        choiceLabel(preset.title, selected: currentQuality == preset)
                    }
                }
                Divider()
            }

            Text(L10n.t(.videoFPS))
                .font(.caption)
            ForEach(VideoFPSPreset.allCases) { preset in
                Button {
                    AppDelegate.shared?.applyVideoFPS(preset)
                } label: {
                    choiceLabel(preset.title, selected: currentFPS == preset)
                }
            }
        }
        .disabled(!prefs.isServerRunning || prefs.isServerRestarting)

        Menu(L10n.t(.menuAudio), systemImage: "speaker.wave.2") {
            ForEach(AudioPlaybackDestination.allCases) { destination in
                Button {
                    AppDelegate.shared?.applyAudioDestination(destination)
                } label: {
                    choiceLabel(
                        audioTitle(destination),
                        selected: currentAudioDestination == destination
                    )
                }
            }
        }
        .disabled(!prefs.isServerRunning || prefs.isServerRestarting)

        Divider()

        Button {
            SettingsCoordinator.shared.open()
        } label: {
            Label(L10n.t(.openSettingsEllipsis), systemImage: "gearshape")
        }

        Button {
            SettingsCoordinator.shared.open(section: .logs)
        } label: {
            Label(L10n.t(.viewServerLog), systemImage: "doc.text")
        }

        Button {
            SettingsCoordinator.shared.open(section: .permissions)
        } label: {
            Label(L10n.t(.checkPermissions), systemImage: "lock.shield")
        }

        Divider()

        Button(L10n.t(.quitApp)) {
            AppDelegate.shared?.quit()
        }
    }

    private var serverDetail: String {
        if prefs.isServerRestarting { return L10n.t(.restartInProgress) }
        if !prefs.isServerRunning { return L10n.t(.startServerHint) }
        return L10n.format(.listeningOnPort, prefs.serverPort)
    }

    private var currentQuality: VideoQualityPreset {
        VideoQualityPreset(
            rawValue: activeSnapshot?.configuredBitrate ?? prefs.videoBitrate
        ) ?? .default
    }

    private var currentFPS: VideoFPSPreset {
        VideoFPSPreset(rawValue: activeSnapshot?.configuredFPS ?? prefs.videoFPS) ?? .default
    }

    private var currentAudioDestination: AudioPlaybackDestination {
        activeSnapshot?.audioPlaybackDestination ?? prefs.audioPlaybackDestination
    }

    private func audioTitle(_ destination: AudioPlaybackDestination) -> String {
        switch destination {
        case .controller: return L10n.t(.audioController)
        case .host: return L10n.t(.audioHost)
        case .both: return L10n.t(.audioBoth)
        }
    }

    private func qualityStateTitle(_ quality: VideoQualityStatus) -> String {
        switch quality.state {
        case .healthy: return L10n.t(.qualityHealthy)
        case .probing: return L10n.t(.qualityProbing)
        case .congested: return L10n.t(.qualityCongested)
        }
    }

    private func qualityStateIcon(_ quality: VideoQualityStatus) -> String {
        switch quality.state {
        case .healthy: return "checkmark.circle.fill"
        case .probing: return "waveform.path.ecg"
        case .congested: return "exclamationmark.triangle.fill"
        }
    }

    private func choiceLabel(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 18)
            if selected {
                Image(systemName: "checkmark")
            }
        }
    }
}
