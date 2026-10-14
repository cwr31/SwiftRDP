import SwiftUI

struct InputSettingsView: View {
    @ObservedObject var prefs: AppPreferences

    var body: some View {
        SettingsForm {
            Section(L10n.t(.mouseWheel)) {
                SettingsSliderRow(
                    title: .scrollSpeed,
                    value: scrollSpeedLabel,
                    lowerBound: "0.25×",
                    upperBound: "3×",
                    detail: .scrollSpeedHelp
                ) {
                    Slider(value: $prefs.wheelScrollSpeed, in: 0.25...3.0, step: 0.25)
                }

                Toggle(L10n.t(.invertScroll), isOn: $prefs.invertWheelScroll)
            }

            Section(L10n.t(.remotePointer)) {
                SettingsSliderRow(
                    title: .remotePointerSize,
                    value: pointerScaleLabel,
                    lowerBound: "1×",
                    upperBound: "3×",
                    detail: .remotePointerSizeHelp
                ) {
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
                }
            }

            Section(L10n.t(.keyboardMapping)) {
                KeyboardBindingEditor(prefs: prefs)
            }
        }
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
