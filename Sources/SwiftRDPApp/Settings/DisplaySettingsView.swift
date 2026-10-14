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

    private var videoFPSBinding: Binding<VideoFPSPreset> {
        Binding(
            get: { VideoFPSPreset(rawValue: prefs.videoFPS) ?? .default },
            set: { prefs.videoFPS = $0.rawValue }
        )
    }

    var body: some View {
        SettingsForm {
            Section {
                LabeledContent(L10n.t(.displayMode)) {
                    Picker("", selection: $prefs.displayMode) {
                        Text(L10n.t(.displayModeBitmap)).tag(DisplayMode.bitmap)
                        Text(L10n.t(.displayModeRemoteFX)).tag(DisplayMode.rfx)
                        Text(L10n.t(.displayModeH264)).tag(DisplayMode.h264)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    .accessibilityLabel(L10n.t(.displayMode))
                }
                .onChange(of: prefs.displayMode) { _, _ in onRestartNeeded() }
            }

            if prefs.displayMode == .h264 {
                Section {
                    VideoQualityPicker(selection: $prefs.videoQuality)

                    Picker(selection: videoFPSBinding) {
                        ForEach(VideoFPSPreset.allCases.reversed()) { preset in
                            Text(preset.title).tag(preset)
                        }
                    } label: {
                        SettingsControlLabel(.videoFPS, detail: .videoFPSHelp)
                    }
                    .accessibilityLabel(L10n.t(.videoFPS))

                    Picker(L10n.t(.videoAdaptationPriority), selection: $prefs.videoAdaptationPriority) {
                        ForEach(VideoAdaptationPriority.allCases) { priority in
                            Text(priority.title).tag(priority)
                        }
                    }
                } header: {
                    Text(L10n.t(.sectionVideo))
                } footer: {
                    SettingsHelpText(.defaultVideoSettingsHelp)
                }
            } else {
                Section {
                    Picker(L10n.t(.videoFPS), selection: videoFPSBinding) {
                        ForEach(VideoFPSPreset.allCases.reversed()) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                }
            }

            Section {
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

            } header: {
                Text(L10n.t(.monitors))
            } footer: {
                SettingsHelpText(.hostDisplayPolicyHelp)
            }
        }
    }

    private func hostDisplayPolicyTitle(_ policy: HostDisplayPolicy) -> String {
        switch policy {
        case .automatic: return L10n.t(.displaySourceAutomatic)
        case .virtual: return L10n.t(.displaySourceVirtual)
        }
    }
}
