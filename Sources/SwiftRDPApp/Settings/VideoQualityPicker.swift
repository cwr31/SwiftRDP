import SwiftRDPCore
import SwiftUI

struct VideoQualityPicker: View {
    @Binding var selection: VideoQualitySettings

    var body: some View {
        Picker(selection: modeBinding) {
            ForEach(VideoQualityMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        } label: {
            SettingsControlLabel(.videoQuality, detail: .videoQualityHelp)
        }
        .accessibilityLabel(L10n.t(.videoQuality))

        if selection.mode == .custom {
            VideoBitrateSlider(bitrate: customBitrateBinding)
        }

    }

    private var modeBinding: Binding<VideoQualityMode> {
        Binding(
            get: { selection.mode },
            set: { selection.mode = $0 }
        )
    }

    private var customBitrateBinding: Binding<Int> {
        Binding(
            get: { selection.customBitrate },
            set: { selection.customBitrate = $0 }
        )
    }
}
