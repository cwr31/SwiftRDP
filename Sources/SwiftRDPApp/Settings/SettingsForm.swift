import SwiftUI

struct SettingsForm<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .controlSize(.regular)
    }
}

struct SettingsHelpText: View {
    let key: L10n.Key

    init(_ key: L10n.Key) {
        self.key = key
    }

    var body: some View {
        Text(L10n.t(key))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsControlLabel: View {
    let title: L10n.Key
    let detail: L10n.Key

    init(_ title: L10n.Key, detail: L10n.Key) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t(title))
            SettingsHelpText(detail)
        }
    }
}

struct SettingsSliderRow<Content: View>: View {
    let title: L10n.Key
    let value: String
    let lowerBound: String
    let upperBound: String
    let detail: L10n.Key
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.t(title))
                Spacer()
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 2) {
                content
                    .accessibilityLabel(L10n.t(title))
                    .accessibilityValue(value)
                HStack {
                    Text(lowerBound)
                    Spacer()
                    Text(upperBound)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            SettingsHelpText(detail)
        }
        .padding(.vertical, 4)
    }
}
