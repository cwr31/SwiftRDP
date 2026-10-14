import AppKit
import SwiftRDPCore
import SwiftUI

struct PermissionsSettingsView: View {
    @State private var screenOK = false
    @State private var accessibilityOK = false

    var body: some View {
        SettingsForm {
            Section {
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
            } header: {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.t(.permissionsIntro))
                        .font(.callout.weight(.regular))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.t(.permissionsRequired))
                }
            }

            Section {
                HStack {
                    Label(
                        screenOK && accessibilityOK
                            ? L10n.t(.allPermissionsGranted)
                            : L10n.t(.actionNeeded),
                        systemImage: screenOK && accessibilityOK
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(screenOK && accessibilityOK ? .green : .orange)
                    Spacer()
                    Button(L10n.t(.refresh), systemImage: "arrow.clockwise") {
                        refresh()
                    }
                    .controlSize(.small)
                }
            }
        }
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
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(granted ? .green : .orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                Text(granted ? L10n.t(.granted) : L10n.t(.notGranted))
                    .font(.callout)
                    .foregroundStyle(granted ? .green : .orange)

                if !granted {
                    Button(L10n.t(.openSystemSettings), action: action)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 6)
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
        SettingsForm {
            Section(L10n.t(.authentication)) {
                Toggle(isOn: $prefs.authEnabled) {
                    SettingsControlLabel(.requireAuthNLA, detail: .authHelp)
                }
                .onChange(of: prefs.authEnabled) { _, _ in onRestartNeeded() }

                LabeledContent(L10n.t(.username)) {
                    TextField(
                        "",
                        text: $prefs.username,
                        prompt: Text(L10n.t(.usernamePlaceholder))
                    )
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(width: 240)
                        .accessibilityLabel(L10n.t(.username))
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
                        .multilineTextAlignment(.leading)
                        .accessibilityLabel(L10n.t(.password))

                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showPassword ? L10n.t(.hidePassword) : L10n.t(.showPassword))
                        .help(showPassword ? L10n.t(.hidePassword) : L10n.t(.showPassword))
                    }
                    .frame(width: 240)
                }

                if prefs.authEnabled && credentialsAreEmpty {
                    Text(L10n.t(.credentialsEmptyError))
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack(spacing: 12) {
                    if prefs.credentialsDirty {
                        Text(L10n.t(.savedRestartCredentials))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if prefs.isServerRunning {
                        Text(L10n.format(.activeUser, prefs.username))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Button(L10n.t(.applyAndRestart), systemImage: "arrow.triangle.2.circlepath") {
                        prefs.applyCredentialsAndRestart()
                        onRestartApplied()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(credentialsAreEmpty || !prefs.credentialsDirty)
                }
            }

            Section(L10n.t(.server)) {
                LabeledContent(L10n.t(.port)) {
                    TextField("", text: $portText, prompt: Text("3389"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 90)
                        .accessibilityLabel(L10n.t(.port))
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
    @State private var hostLoginPassword = ""
    @State private var hasHostLoginPassword = false
    @State private var accessibilityOK = false
    @State private var hostLoginPasswordStatus: String?

    init(prefs: AppPreferences) {
        self.prefs = prefs
        _timeoutText = State(initialValue: String(prefs.idleTimeout))
    }

    var body: some View {
        SettingsForm {
            Section(L10n.t(.session)) {
                LabeledContent(L10n.t(.idleTimeout)) {
                    TextField("", text: $timeoutText, prompt: Text("0"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 90)
                        .accessibilityLabel(L10n.t(.idleTimeout))
                        .onChange(of: timeoutText) { _, _ in updateTimeout() }
                }
                if !isTimeoutValid {
                    Text(L10n.t(.invalidTimeout))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section(L10n.t(.power)) {
                Toggle(isOn: $prefs.preventSystemSleep) {
                    SettingsControlLabel(.preventSystemSleep, detail: .preventSystemSleepHelp)
                }

                Toggle(isOn: $prefs.preventDisplaySleep) {
                    SettingsControlLabel(.preventDisplaySleep, detail: .preventDisplaySleepHelp)
                }
            }

            Section {
                Toggle(isOn: $prefs.keepScreenUnlockedWhileConnected) {
                    SettingsControlLabel(.keepScreenUnlockedWhileConnected, detail: .keepUnlockedHelp)
                }
                .disabled(!hasHostLoginPassword || !prefs.authEnabled || !accessibilityOK)

                LabeledContent(L10n.t(.hostLoginPassword)) {
                    SecureField("", text: $hostLoginPassword)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(width: 240)
                        .accessibilityLabel(L10n.t(.hostLoginPassword))
                }

                HStack {
                    if let hostLoginPasswordStatus {
                        Text(hostLoginPasswordStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    if hasHostLoginPassword {
                        Button(L10n.t(.removeHostLoginPassword), systemImage: "trash") {
                            removeHostLoginPassword()
                        }
                    }

                    Button(L10n.t(.saveHostLoginPassword), systemImage: "key.fill") {
                        saveHostLoginPassword()
                    }
                    .disabled(hostLoginPassword.isEmpty)
                }
            } header: {
                Text(L10n.t(.remoteSessionSecurity))
            } footer: {
                SettingsHelpText(.hostLoginPasswordHelp)
            }
        }
        .onAppear {
            timeoutText = String(prefs.idleTimeout)
            hasHostLoginPassword = HostUnlockCredentialStore.hasCredential
            accessibilityOK = PermissionGate.isAccessibilityTrusted
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityOK = PermissionGate.isAccessibilityTrusted
        }
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

    private func saveHostLoginPassword() {
        guard HostUnlockCredentialStore.save(hostLoginPassword) else {
            hostLoginPasswordStatus = L10n.t(.hostLoginPasswordSaveFailed)
            return
        }
        hostLoginPassword = ""
        hasHostLoginPassword = true
        hostLoginPasswordStatus = L10n.t(.hostLoginPasswordSaved)
    }

    private func removeHostLoginPassword() {
        prefs.keepScreenUnlockedWhileConnected = false
        guard HostUnlockCredentialStore.remove() else {
            hostLoginPasswordStatus = L10n.t(.hostLoginPasswordSaveFailed)
            return
        }
        hostLoginPassword = ""
        hasHostLoginPassword = false
        hostLoginPasswordStatus = nil
    }
}

struct AudioSettingsView: View {
    @ObservedObject var prefs: AppPreferences

    var body: some View {
        SettingsForm {
            Section {
                Picker(L10n.t(.audioPlaybackDestination), selection: $prefs.audioPlaybackDestination) {
                    ForEach(AudioPlaybackDestination.allCases) { destination in
                        Text(title(for: destination))
                            .tag(destination)
                    }
                }

            } footer: {
                SettingsHelpText(.audioPlaybackHelp)
            }
        }
    }

    private func title(for destination: AudioPlaybackDestination) -> String {
        switch destination {
        case .controller: return L10n.t(.audioController)
        case .host: return L10n.t(.audioHost)
        case .both: return L10n.t(.audioBoth)
        }
    }
}
