import SwiftUI
import SwiftRDPCore

struct KeyboardBindingEditor: View {
    @ObservedObject var prefs: AppPreferences
    @State private var selectedKey: RemoteKeyboardKey = .leftControl

    private let targets: [MacKeyboardKey] = [
        .disabled, .leftControl, .leftOption, .leftCommand, .leftShift,
        .rightControl, .rightOption, .rightCommand, .rightShift,
        .capsLock, .escape, .tab, .space, .delete,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.t(.keyboardBindingPresets))
                Spacer()
                Menu(L10n.t(.keyboardBindingLoadPreset), systemImage: "arrow.down.doc") {
                    ForEach(KeyboardMappingPreset.allCases) { preset in
                        Button(preset.title) {
                            prefs.applyKeyboardPreset(preset)
                        }
                    }
                }
            }

            Grid(horizontalSpacing: 5, verticalSpacing: 5) {
                GridRow {
                    key(.capsLock, columns: 2)
                    key(.leftShift, columns: 3)
                    Color.clear.gridCellColumns(2)
                    key(.rightShift, columns: 3)
                }
                GridRow {
                    key(.leftControl)
                    key(.leftWindows)
                    key(.leftAlt)
                    key(.space, columns: 3)
                    key(.rightAlt)
                    key(.rightWindows)
                    key(.menu)
                    key(.rightControl)
                }
            }
            .frame(maxWidth: .infinity)

            HStack(alignment: .firstTextBaseline) {
                Text(selectedKey.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(L10n.t(.keyboardBindingRemoteKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent(L10n.t(.keyboardBindingOutput)) {
                Picker(
                    "",
                    selection: Binding(
                        get: { prefs.keyboardBindings[selectedKey] ?? .disabled },
                        set: { prefs.setKeyboardBinding($0, for: selectedKey) }
                    )
                ) {
                    ForEach(targets) { target in
                        Text(target.title).tag(target)
                    }
                }
                .labelsHidden()
            }
        }
    }

    private func effectiveBinding(for key: RemoteKeyboardKey) -> MacKeyboardKey {
        prefs.keyboardBindings[key] ?? .disabled
    }

    private func key(_ key: RemoteKeyboardKey, columns: Int = 1) -> some View {
        Button {
            selectedKey = key
        } label: {
            VStack(spacing: 2) {
                Text(key.keyCap)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(effectiveBinding(for: key).symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(selectedKey == key ? Color.accentColor : Color.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selectedKey == key ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(
                        selectedKey == key ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: selectedKey == key ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .gridCellColumns(columns)
        .accessibilityLabel(key.title)
        .accessibilityValue(effectiveBinding(for: key).title)
    }
}
