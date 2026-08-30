import SwiftRDPCore
import SwiftUI

struct ConnectionsSettingsView: View {
    @ObservedObject var prefs: AppPreferences
    @State private var live: LiveClientSnapshot?
    @State private var history: [ConnectionHistoryEntry] = []

    private static let refreshTick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private var audit: ConnectionAudit { prefs.connectionAudit }

    var body: some View {
        Form {
            Section(L10n.t(.connectionStatus)) {
                if let live {
                    LiveConnectionRow(client: live, prefs: prefs) {
                        refresh()
                    }
                } else {
                    Label(L10n.t(.connectionNone), systemImage: "network.slash")
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.t(.accessControl)) {
                Toggle(L10n.t(.knownPeersOnly), isOn: $prefs.knownPeersOnly)
                Text(L10n.t(.knownPeersOnlyHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.t(.rememberedConnections)) {
                Text(L10n.t(.rememberedConnectionsHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if prefs.rememberedSessionSettings.isEmpty {
                    Label(L10n.t(.noRememberedConnections), systemImage: "externaldrive")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(prefs.rememberedSessionSettings) { settings in
                        RememberedConnectionRow(settings: settings, prefs: prefs)
                    }
                }
            }

            Section {
                HStack {
                    Text(L10n.t(.connectionsHistory))
                    Spacer()
                    Button(L10n.t(.clearHistory), systemImage: "trash", role: .destructive) {
                        audit.clearHistory()
                        refresh()
                    }
                    .controlSize(.small)
                    .disabled(history.isEmpty)
                }

                if history.isEmpty {
                    Label(L10n.t(.connectionsHistoryEmpty), systemImage: "clock")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(history.prefix(100)) { entry in
                        ConnectionHistoryRow(entry: entry)
                    }
                    if history.count > 100 {
                        Text(L10n.format(.connectionsHistoryTruncated, history.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(Self.refreshTick) { _ in refresh() }
    }

    private func refresh() {
        live = prefs.sessionManagerProvider?()?.liveClientSnapshot()
        history = audit.historyEntries()
        prefs.refreshRememberedSessionSettings()
    }
}

private struct LiveConnectionRow: View {
    let client: LiveClientSnapshot
    @ObservedObject var prefs: AppPreferences
    let onDisconnect: () -> Void

    private var isActive: Bool { client.state == .active }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(primaryTitle)
                    .font(.body.weight(.semibold))
                Spacer()
                Label(
                    isActive ? L10n.t(.connectionsStateActive) : L10n.t(.connectionsStateConnecting),
                    systemImage: isActive ? "circle.fill" : "circle.dotted"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(isActive ? .green : .orange)
            }

            detailLine(icon: "network", text: client.peerAddress.isEmpty ? "—" : client.peerAddress)
            if !client.userName.isEmpty {
                detailLine(icon: "person", text: client.userName)
            }
            if !client.clientName.isEmpty {
                detailLine(icon: "laptopcomputer", text: client.clientName)
            }

            HStack(spacing: 10) {
                if !client.securityLabel.isEmpty {
                    Text(client.securityLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(client.phaseLabel)
                if client.width > 0, client.height > 0 {
                    Text("\(client.width)×\(client.height)")
                }
                Text(L10n.format(.connectedFor, formatDuration(since: client.connectedAt)))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let quality = client.quality {
                LiveQualityStatusView(
                    quality: quality,
                    captureSkippedFrames: client.captureSkippedFrames
                )
            }

            HStack {
                Spacer()
                Button(L10n.t(.disconnectClient), role: .destructive) {
                    prefs.sessionManagerProvider?()?.terminateSession(id: client.id)
                    onDisconnect()
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var primaryTitle: String {
        if !client.clientName.isEmpty { return client.clientName }
        if !client.userName.isEmpty { return client.userName }
        if !client.peerAddress.isEmpty { return client.peerAddress }
        return L10n.t(.clientFallback)
    }

    private func detailLine(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }

    private func formatDuration(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        if minutes > 0 { return String(format: "%dm %02ds", minutes, remainingSeconds) }
        return String(format: "%ds", remainingSeconds)
    }
}

private struct LiveQualityStatusView: View {
    let quality: VideoQualityStatus
    let captureSkippedFrames: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Label(L10n.t(.qualityStatus), systemImage: stateIcon)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(stateTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(stateColor)
            }

            HStack(spacing: 10) {
                Text(L10n.format(
                    .qualityTarget,
                    quality.targetFPS,
                    Double(quality.targetBitrate) / 1_000_000
                ))
                Text(L10n.format(
                    .qualityQueue,
                    clientQueueTitle,
                    quality.serverQueueDelayMs
                ))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                pressure(.qualitySourceNetwork, value: quality.networkPressure)
                pressure(.qualitySourceClientQueue, value: quality.clientPressure)
                pressure(.qualitySourceEncoder, value: quality.encoderPressure)
                Text(L10n.format(.qualitySkipped, captureSkippedFrames))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var stateTitle: String {
        switch quality.state {
        case .healthy: return L10n.t(.qualityHealthy)
        case .probing: return L10n.t(.qualityProbing)
        case .congested: return L10n.t(.qualityCongested)
        }
    }

    private var stateIcon: String {
        switch quality.state {
        case .healthy: return "checkmark.circle.fill"
        case .probing: return "waveform.path.ecg"
        case .congested: return "exclamationmark.triangle.fill"
        }
    }

    private var stateColor: Color {
        switch quality.state {
        case .healthy: return .green
        case .probing: return .orange
        case .congested: return .red
        }
    }

    private var clientQueueTitle: String {
        switch quality.clientQueue {
        case .unavailable, .suspended:
            return L10n.t(.qualityUnknown)
        case .queued(let bytes):
            return "\(bytes)B"
        }
    }

    private func pressure(_ source: L10n.Key, value: Double) -> some View {
        Text(L10n.format(.qualityPressure, L10n.t(source), min(max(value, 0), 1) * 100))
    }
}

private struct RememberedConnectionRow: View {
    let settings: RememberedSessionSettings
    @ObservedObject var prefs: AppPreferences

    var body: some View {
        DisclosureGroup {
                Picker(L10n.t(.videoQuality), selection: bitrateBinding) {
                    ForEach(VideoQualityPreset.allCases) { preset in
                        Text(preset.title).tag(preset.rawValue)
                    }
                }

            Picker(L10n.t(.videoFPS), selection: fpsBinding) {
                    ForEach(VideoFPSPreset.allCases) { preset in
                        Text(preset.title).tag(preset.rawValue)
                    }
                }

            Picker(L10n.t(.audioPlaybackDestination), selection: audioBinding) {
                    ForEach(AudioPlaybackDestination.allCases) { destination in
                        Text(audioDestinationTitle(destination)).tag(destination)
                    }
                }

            LabeledContent(L10n.t(.resolutionMenu)) {
                HStack(spacing: 8) {
                    Text(resolutionTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(settings.resolution == nil ? .secondary : .primary)
                    if settings.resolution != nil {
                        Button {
                            var updated = settings
                            updated.resolution = nil
                            prefs.updateRememberedSessionSettings(updated)
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.t(.followClientResolution))
                    }
                }
            }

            Button(L10n.t(.forgetConnection), role: .destructive) {
                prefs.forgetRememberedSessionSettings(id: settings.id)
            }
            .controlSize(.small)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.identity.displayName)
                        .font(.body.weight(.semibold))
                    if !settings.clientName.isEmpty, !settings.peerAddress.isEmpty {
                        Text(settings.peerAddress)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(L10n.format(
                    .lastConnected,
                    settings.lastConnectedAt.formatted(date: .abbreviated, time: .shortened)
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var bitrateBinding: Binding<Int> {
        Binding(
            get: { settings.videoBitrate },
            set: { value in
                var updated = settings
                updated.videoBitrate = value
                prefs.updateRememberedSessionSettings(updated)
            }
        )
    }

    private var fpsBinding: Binding<Int> {
        Binding(
            get: { settings.videoFPS },
            set: { value in
                var updated = settings
                updated.videoFPS = value
                prefs.updateRememberedSessionSettings(updated)
            }
        )
    }

    private var audioBinding: Binding<AudioPlaybackDestination> {
        Binding(
            get: { settings.audioPlaybackDestination },
            set: { value in
                var updated = settings
                updated.audioPlaybackDestination = value
                prefs.updateRememberedSessionSettings(updated)
            }
        )
    }

    private var resolutionTitle: String {
        guard let resolution = settings.resolution else { return L10n.t(.followClientResolution) }
        return "\(resolution.logicalWidth)×\(resolution.logicalHeight)" + (resolution.hiDPI ? " (HiDPI)" : "")
    }

    private func audioDestinationTitle(_ destination: AudioPlaybackDestination) -> String {
        switch destination {
        case .controller: return L10n.t(.audioController)
        case .host: return L10n.t(.audioHost)
        case .both: return L10n.t(.audioBoth)
        }
    }
}

private struct ConnectionHistoryRow: View {
    let entry: ConnectionHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(outcomeTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(outcomeColor)
                Spacer()
                Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(entry.peerAddress)
                .font(.caption.monospaced())
                .textSelection(.enabled)

            let metadata = [entry.userName, entry.clientName, entry.securityLabel]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            if !metadata.isEmpty {
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !entry.detail.isEmpty {
                Text(entry.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let seconds = entry.durationSeconds {
                Text(L10n.format(.historyDuration, formatSeconds(seconds)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var outcomeTitle: String {
        switch entry.outcome {
        case .connecting: return L10n.t(.historyOutcomeConnecting)
        case .active: return L10n.t(.historyOutcomeActive)
        case .disconnected: return L10n.t(.historyOutcomeDisconnected)
        case .authFailed: return L10n.t(.historyOutcomeAuthFailed)
        case .abandoned: return L10n.t(.historyOutcomeAbandoned)
        }
    }

    private var outcomeColor: Color {
        switch entry.outcome {
        case .active, .connecting: return .green
        case .disconnected, .abandoned: return .secondary
        case .authFailed: return .red
        }
    }

    private func formatSeconds(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        if minutes > 0 { return String(format: "%dm %02ds", minutes, remainingSeconds) }
        return String(format: "%ds", remainingSeconds)
    }
}
