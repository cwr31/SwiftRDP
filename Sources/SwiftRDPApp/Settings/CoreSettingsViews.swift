import AppKit
import SwiftRDPCore
import SwiftUI

struct PermissionsSettingsView: View {
    @State private var screenOK = false
    @State private var accessibilityOK = false

    var body: some View {
        Form {
            Section {
                Text(L10n.t(.permissionsIntro))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.t(.permissionsRequired)) {
                PermissionStatusRow(
                    title: L10n.t(.screenRecording),
                    detail: L10n.t(.screenRecordingDetail),
                    granted: screenOK
                ) {
                    _ = PermissionGate.requestScreenRecording()
                    PermissionGate.openScreenRecordingSettings()
                }
                PermissionStatusRow(
                    title: L10n.t(.accessibility),
                    detail: L10n.t(.accessibilityDetail),
                    granted: accessibilityOK
                ) {
                    PermissionGate.requestAccessibility(prompt: true)
                    PermissionGate.openAccessibilitySettings()
                }
            }

            Section {
                HStack {
                    Button(L10n.t(.refresh), systemImage: "arrow.clockwise") {
                        refresh()
                    }
                    Spacer()
                    Label(
                        screenOK && accessibilityOK
                            ? L10n.t(.allPermissionsGranted)
                            : L10n.t(.actionNeeded),
                        systemImage: screenOK && accessibilityOK
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(screenOK && accessibilityOK ? .green : .orange)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        screenOK = PermissionGate.isScreenRecordingTrusted
        accessibilityOK = PermissionGate.isAccessibilityTrusted
    }
}

private struct PermissionStatusRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(title, systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(granted ? Color.primary : Color.orange)
                Spacer()
                Text(granted ? L10n.t(.granted) : L10n.t(.notGranted))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(granted ? .green : .orange)
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !granted {
                Button(L10n.t(.openSystemSettings), action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var prefs: AppPreferences
    let onRestartNeeded: () -> Void
    let onRestartApplied: () -> Void

    @State private var showPassword = false
    @State private var portText: String

    init(
        prefs: AppPreferences,
        onRestartNeeded: @escaping () -> Void,
        onRestartApplied: @escaping () -> Void
    ) {
        self.prefs = prefs
        self.onRestartNeeded = onRestartNeeded
        self.onRestartApplied = onRestartApplied
        _portText = State(initialValue: String(prefs.serverPort))
    }

    var body: some View {
        Form {
            Section(L10n.t(.authentication)) {
                Toggle(L10n.t(.requireAuthNLA), isOn: $prefs.authEnabled)
                    .onChange(of: prefs.authEnabled) { _, _ in onRestartNeeded() }

                Text(L10n.t(.authHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent(L10n.t(.username)) {
                    TextField(
                        "",
                        text: $prefs.username,
                        prompt: Text(L10n.t(.usernamePlaceholder))
                    )
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent(L10n.t(.password)) {
                    HStack(spacing: 8) {
                        Group {
                            if showPassword {
                                TextField(
                                    "",
                                    text: $prefs.password,
                                    prompt: Text(L10n.t(.passwordPlaceholder))
                                )
                            } else {
                                SecureField(
                                    "",
                                    text: $prefs.password,
                                    prompt: Text(L10n.t(.passwordPlaceholder))
                                )
                            }
                        }
                        .textFieldStyle(.roundedBorder)

                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(showPassword ? L10n.t(.hidePassword) : L10n.t(.showPassword))
                    }
                }

                if prefs.authEnabled && credentialsAreEmpty {
                    Text(L10n.t(.credentialsEmptyError))
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack(spacing: 10) {
                    Button(L10n.t(.applyAndRestart), systemImage: "arrow.triangle.2.circlepath") {
                        prefs.applyCredentialsAndRestart()
                        onRestartApplied()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(credentialsAreEmpty || !prefs.credentialsDirty)

                    if prefs.credentialsDirty {
                        Text(L10n.t(.savedRestartCredentials))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if prefs.isServerRunning {
                        Text(L10n.format(.activeUser, prefs.username))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section(L10n.t(.server)) {
                LabeledContent(L10n.t(.port)) {
                    TextField("", text: $portText, prompt: Text("3389"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: portText) { _, _ in updatePort() }
                }

                if !isPortValid {
                    Text(L10n.t(.invalidPort))
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Toggle(L10n.t(.autoStartServer), isOn: $prefs.autoStartServer)
                Toggle(L10n.t(.launchAtLogin), isOn: $prefs.launchAtLogin)
            }

            Section {
                Picker(L10n.t(.language), selection: $prefs.appLanguage) {
                    ForEach(L10n.Language.allCases) { language in
                        Text(language.rawValue).tag(language.rawValue)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { portText = String(prefs.serverPort) }
        .onChange(of: prefs.serverPort) { _, value in
            if portText != String(value) {
                portText = String(value)
            }
        }
    }

    private var credentialsAreEmpty: Bool {
        prefs.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (prefs.authEnabled && prefs.password.isEmpty)
    }

    private var isPortValid: Bool {
        guard let value = Int(portText) else { return false }
        return (1...65_535).contains(value)
    }

    private func updatePort() {
        guard isPortValid, let value = Int(portText), value != prefs.serverPort else { return }
        prefs.serverPort = value
        onRestartNeeded()
    }
}

struct SessionSettingsView: View {
    @ObservedObject var prefs: AppPreferences
    @State private var timeoutText: String

    init(prefs: AppPreferences) {
        self.prefs = prefs
        _timeoutText = State(initialValue: String(prefs.idleTimeout))
    }

    var body: some View {
        Form {
            Section(L10n.t(.session)) {
                LabeledContent(L10n.t(.idleTimeout)) {
                    TextField("", text: $timeoutText, prompt: Text("0"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: timeoutText) { _, _ in updateTimeout() }
                }
                if !isTimeoutValid {
                    Text(L10n.t(.invalidTimeout))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section(L10n.t(.power)) {
                Toggle(L10n.t(.preventSystemSleep), isOn: $prefs.preventSystemSleep)
                Text(L10n.t(.preventSystemSleepHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(L10n.t(.preventDisplaySleep), isOn: $prefs.preventDisplaySleep)
                Text(L10n.t(.preventDisplaySleepHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { timeoutText = String(prefs.idleTimeout) }
        .onChange(of: prefs.idleTimeout) { _, value in
            if timeoutText != String(value) {
                timeoutText = String(value)
            }
        }
    }

    private var isTimeoutValid: Bool {
        guard let value = Int(timeoutText) else { return false }
        return value >= 0
    }

    private func updateTimeout() {
        guard isTimeoutValid, let value = Int(timeoutText), value != prefs.idleTimeout else { return }
        prefs.idleTimeout = value
    }
}

struct AudioSettingsView: View {
    @ObservedObject var prefs: AppPreferences

    var body: some View {
        Form {
            Section {
                Picker(L10n.t(.audioPlaybackDestination), selection: $prefs.audioPlaybackDestination) {
                    ForEach(AudioPlaybackDestination.allCases) { destination in
                        Text(title(for: destination))
                            .tag(destination)
                    }
                }

                Text(L10n.t(.audioPlaybackHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func title(for destination: AudioPlaybackDestination) -> String {
        switch destination {
        case .controller: return L10n.t(.audioController)
        case .host: return L10n.t(.audioHost)
        case .both: return L10n.t(.audioBoth)
        }
    }
}
