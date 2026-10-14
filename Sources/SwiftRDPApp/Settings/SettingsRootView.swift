import SwiftUI

struct SettingsRootView: View {
    @ObservedObject var prefs: AppPreferences
    @Bindable var settings: SettingsState

    var body: some View {
        NavigationSplitView {
            List(selection: Binding($settings.section)) {
                ForEach(SettingsSectionGroup.all) { group in
                    Section(L10n.t(group.title)) {
                        ForEach(group.sections) { section in
                            Label {
                                Text(section.title)
                            } icon: {
                                Image(systemName: section.systemImage)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(section)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(200)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    Text(settings.section.title)
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .gesture(WindowDragGesture())
                        .allowsWindowActivationEvents(true)

                    if settings.restartPending && prefs.isServerRunning && !prefs.isServerRestarting {
                        Button {
                            settings.restartPending = false
                            prefs.applyAndRestartHandler?()
                        } label: {
                            Label(L10n.t(.restartServer), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

                Divider()

                page(for: settings.section)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .navigationTitle(settings.section.title)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 780, idealWidth: 960, minHeight: 560, idealHeight: 680)
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
        settings.restartPending = prefs.isServerRunning
    }

    private func clearRestartPending() {
        settings.restartPending = false
    }
}
