import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general
    case connections
    case display
    case input
    case audio
    case session
    case permissions
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.t(.sectionGeneral)
        case .connections: return L10n.t(.sectionConnections)
        case .display: return L10n.t(.sectionDisplay)
        case .input: return L10n.t(.sectionInput)
        case .audio: return L10n.t(.sectionAudio)
        case .session: return L10n.t(.sectionSession)
        case .permissions: return L10n.t(.sectionPermissions)
        case .logs: return L10n.t(.sectionLogs)
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .connections: return "point.3.connected.trianglepath.dotted"
        case .display: return "display"
        case .input: return "computermouse"
        case .audio: return "speaker.wave.2"
        case .session: return "macwindow.on.rectangle"
        case .permissions: return "lock.shield"
        case .logs: return "doc.text"
        }
    }

}

struct SettingsRootView: View {
    @ObservedObject var prefs: AppPreferences
    @ObservedObject var coordinator: SettingsCoordinator

    private var selection: Binding<SettingsSection> {
        Binding(
            get: { coordinator.section ?? .general },
            set: { coordinator.section = $0 }
        )
    }

    var body: some View {
        TabView(selection: selection) {
            TabSection(L10n.t(.settingsGroupServer)) {
                Tab(
                    SettingsSection.general.title,
                    systemImage: SettingsSection.general.systemImage,
                    value: SettingsSection.general
                ) {
                    tabPage(for: .general)
                }
                Tab(
                    SettingsSection.connections.title,
                    systemImage: SettingsSection.connections.systemImage,
                    value: SettingsSection.connections
                ) {
                    tabPage(for: .connections)
                }
            }

            TabSection(L10n.t(.settingsGroupExperience)) {
                Tab(
                    SettingsSection.display.title,
                    systemImage: SettingsSection.display.systemImage,
                    value: SettingsSection.display
                ) {
                    tabPage(for: .display)
                }
                Tab(
                    SettingsSection.input.title,
                    systemImage: SettingsSection.input.systemImage,
                    value: SettingsSection.input
                ) {
                    tabPage(for: .input)
                }
                Tab(
                    SettingsSection.audio.title,
                    systemImage: SettingsSection.audio.systemImage,
                    value: SettingsSection.audio
                ) {
                    tabPage(for: .audio)
                }
                Tab(
                    SettingsSection.session.title,
                    systemImage: SettingsSection.session.systemImage,
                    value: SettingsSection.session
                ) {
                    tabPage(for: .session)
                }
            }

            TabSection(L10n.t(.settingsGroupSupport)) {
                Tab(
                    SettingsSection.permissions.title,
                    systemImage: SettingsSection.permissions.systemImage,
                    value: SettingsSection.permissions
                ) {
                    tabPage(for: .permissions)
                }
                Tab(
                    SettingsSection.logs.title,
                    systemImage: SettingsSection.logs.systemImage,
                    value: SettingsSection.logs
                ) {
                    tabPage(for: .logs)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .toolbar {
            if coordinator.restartPending && prefs.isServerRunning && !prefs.isServerRestarting {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        coordinator.restartPending = false
                        prefs.applyAndRestartHandler?()
                    } label: {
                        Label(L10n.t(.restartServer), systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
        }
        .onChange(of: prefs.isServerRunning) { _, running in
            if !running {
                coordinator.restartPending = false
            }
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 540, idealHeight: 680)
    }

    @ViewBuilder
    private func tabPage(for section: SettingsSection) -> some View {
        page(for: section)
            .navigationTitle(section.title)
    }

    @ViewBuilder
    private func page(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSettingsView(
                prefs: prefs,
                onRestartNeeded: markRestartNeeded,
                onRestartApplied: clearRestartPending
            )
        case .connections:
            ConnectionsSettingsView(prefs: prefs)
        case .display:
            DisplaySettingsView(prefs: prefs, onRestartNeeded: markRestartNeeded)
        case .input:
            InputSettingsView(prefs: prefs)
        case .audio:
            AudioSettingsView(prefs: prefs)
        case .session:
            SessionSettingsView(prefs: prefs)
        case .permissions:
            PermissionsSettingsView()
        case .logs:
            LogsView(prefs: prefs)
        }
    }

    private func markRestartNeeded() {
        coordinator.restartPending = coordinator.section != nil && prefs.isServerRunning
    }

    private func clearRestartPending() {
        coordinator.restartPending = false
    }
}
