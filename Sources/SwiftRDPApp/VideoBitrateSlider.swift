import SwiftRDPCore
import SwiftUI

struct VideoBitrateSlider: View {
    @Binding var bitrate: Int
    @State private var draftMbps: Double?
    @State private var isEditing = false

    private var range: ClosedRange<Double> {
        let limits = VideoQualitySettings.customBitrateRange
        return Double(limits.lowerBound / 1_000_000)...Double(limits.upperBound / 1_000_000)
    }

    private var valueTitle: String {
        L10n.format(.customBitrateValue, Int(draftMbps ?? Double(bitrate) / 1_000_000), Int(range.upperBound))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.t(.videoBitrate))
                Spacer()
                Text(valueTitle)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: sliderBinding, in: range, step: 1, onEditingChanged: editingChanged)
                .accessibilityLabel(L10n.t(.videoBitrate))
                .accessibilityValue(valueTitle)
        }
        .onChange(of: bitrate) { _, _ in
            if !isEditing { draftMbps = nil }
        }
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { draftMbps ?? Double(bitrate) / 1_000_000 },
            set: { value in
                if isEditing {
                    draftMbps = value
                } else {
                    bitrate = Int(value.rounded()) * 1_000_000
                }
            }
        )
    }

    private func editingChanged(_ editing: Bool) {
        isEditing = editing
        if !editing, let draftMbps {
            // Apply once on release instead of retuning the live encoder on every drag event.
            bitrate = Int(draftMbps.rounded()) * 1_000_000
            self.draftMbps = nil
        }
    }
}
