import SwiftUI

struct InputSettingsView: View {
    @ObservedObject var prefs: AppPreferences

    var body: some View {
        Form {
            Section(L10n.t(.mouseWheel)) {
                LabeledContent(L10n.t(.scrollSpeed)) {
                    VStack(alignment: .trailing, spacing: 8) {
                        Text(scrollSpeedLabel)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Slider(value: $prefs.wheelScrollSpeed, in: 0.25...3.0, step: 0.25)
                        HStack {
                            Text("0.25×")
                            Spacer()
                            Text("3×")
                        }
                        .frame(maxWidth: .infinity)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
                
                Text(L10n.t(.scrollSpeedHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(L10n.t(.invertScroll), isOn: $prefs.invertWheelScroll)
            }

            Section(L10n.t(.remotePointer)) {
                LabeledContent(L10n.t(.remotePointerSize)) {
                    VStack(alignment: .trailing, spacing: 8) {
                        Text(pointerScaleLabel)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Slider(
                            value: $prefs.remotePointerScale,
                            in: 1.0...3.0,
                            step: 0.25,
                            onEditingChanged: { editing in
                                if !editing {
                                    prefs.applyRemotePointerScale()
                                }
                            }
                        )
                        HStack {
                            Text("1×")
                            Spacer()
                            Text("3×")
                        }
                        .frame(maxWidth: .infinity)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
                
                Text(L10n.t(.remotePointerSizeHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.t(.keyboardMapping)) {
                KeyboardBindingEditor(prefs: prefs)
            }
        }
        .formStyle(.grouped)
    }

    private var scrollSpeedLabel: String {
        let value = prefs.wheelScrollSpeed
        if value == 1.0 { return "1×" }
        if value == floor(value) { return String(format: "%.0f×", value) }
        return String(format: "%.2g×", value)
    }

    private var pointerScaleLabel: String {
        let value = prefs.remotePointerScale
        if value == floor(value) { return String(format: "%.0f×", value) }
        if value * 2 == floor(value * 2) { return String(format: "%.1f×", value) }
        return String(format: "%.2f×", value)
    }
}
