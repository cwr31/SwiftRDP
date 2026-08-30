import AppKit
import SwiftRDPCore
import SwiftUI

struct DisplaySettingsView: View {
    @ObservedObject var prefs: AppPreferences
    let onRestartNeeded: () -> Void

    private var displays: [(identity: String, name: String)] {
        var result: [(String, String)] = [("", L10n.t(.autoPrimaryDisplay))]
        for id in DisplayTopology.physicalDisplayIDs() {
            let screen = NSScreen.screens.first { screen in
                let key = NSDeviceDescriptionKey("NSScreenNumber")
                return (screen.deviceDescription[key] as? NSNumber)?.uint32Value == id
            }
            let name = screen?.localizedName ?? L10n.format(.displayN, id)
            result.append((DisplayTopology.stableDisplayIdentity(for: id), name))
        }
        return result
    }

    private var physicalDisplayBinding: Binding<String> {
        Binding(
            get: {
                displays.contains(where: { $0.identity == prefs.selectedDisplayIdentity })
                    ? prefs.selectedDisplayIdentity
                    : ""
            },
            set: { prefs.selectedDisplayIdentity = $0 }
        )
    }

    private var videoQualityBinding: Binding<VideoQualityPreset> {
        Binding(
            get: { VideoQualityPreset(rawValue: prefs.videoBitrate) ?? .default },
            set: { prefs.videoBitrate = $0.rawValue }
        )
    }

    private var videoFPSBinding: Binding<VideoFPSPreset> {
        Binding(
            get: { VideoFPSPreset(rawValue: prefs.videoFPS) ?? .default },
            set: { prefs.videoFPS = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(L10n.t(.displayMode)) {
                    Picker("", selection: $prefs.displayMode) {
                        Text(L10n.t(.displayModeBitmap)).tag(DisplayMode.bitmap)
                        Text(L10n.t(.displayModeRemoteFX)).tag(DisplayMode.rfx)
                        Text(L10n.t(.displayModeH264)).tag(DisplayMode.h264)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                .onChange(of: prefs.displayMode) { _, _ in onRestartNeeded() }
            }

            if prefs.displayMode == .h264 {
                Section(L10n.t(.sectionH264)) {
                    Picker(L10n.t(.videoQuality), selection: videoQualityBinding) {
                            ForEach(VideoQualityPreset.allCases) { preset in
                                Text(preset.title).tag(preset)
                            }
                        }

                    Text(L10n.t(.videoQualityHelp))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Picker(L10n.t(.videoFPS), selection: videoFPSBinding) {
                            ForEach(VideoFPSPreset.allCases) { preset in
                                Text(preset.title).tag(preset)
                            }
                        }

                    Picker(L10n.t(.videoAdaptationPriority), selection: $prefs.videoAdaptationPriority) {
                            ForEach(VideoAdaptationPriority.allCases) { priority in
                                Text(priority.title).tag(priority)
                            }
                        }
                }
            } else {
                Section {
                    Picker(L10n.t(.videoFPS), selection: videoFPSBinding) {
                            ForEach(VideoFPSPreset.allCases) { preset in
                                Text(preset.title).tag(preset)
                            }
                        }
                }
            }

            Section(L10n.t(.monitors)) {
                Picker(L10n.t(.displaySource), selection: $prefs.hostDisplayPolicy) {
                    ForEach(HostDisplayPolicy.allCases, id: \.self) { policy in
                        Text(hostDisplayPolicyTitle(policy)).tag(policy)
                    }
                }
                .onChange(of: prefs.hostDisplayPolicy) { _, _ in onRestartNeeded() }

                if prefs.hostDisplayPolicy == .automatic {
                    Picker(L10n.t(.displayToShare), selection: physicalDisplayBinding) {
                        ForEach(displays, id: \.identity) { item in
                            Text(item.name).tag(item.identity)
                        }
                    }
                    .onChange(of: prefs.selectedDisplayIdentity) { _, _ in onRestartNeeded() }
                }

                Text(L10n.t(.hostDisplayPolicyHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func hostDisplayPolicyTitle(_ policy: HostDisplayPolicy) -> String {
        switch policy {
        case .automatic: return L10n.t(.displaySourceAutomatic)
        case .virtual: return L10n.t(.displaySourceVirtual)
        }
    }
}
