import AppKit
import SwiftRDPCore

@MainActor
final class CustomBitrateMenuView: NSView {
    let slider = MenuBitrateSlider(frame: .zero)
    private let valueLabel = NSTextField(labelWithString: "")
    private let onCommit: (Int) -> Void

    init(bitrate: Int, onCommit: @escaping (Int) -> Void) {
        self.onCommit = onCommit
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 86))
        autoresizingMask = [.width]

        let prompt = NSTextField(labelWithString: L10n.t(.customBitratePrompt))
        prompt.font = .menuFont(ofSize: 0)
        let separator = NSBox()
        separator.boxType = .separator

        let title = NSTextField(labelWithString: L10n.t(.videoBitrate))
        title.font = .menuFont(ofSize: 0)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let limits = VideoQualitySettings.customBitrateRange
        slider.minValue = Double(limits.lowerBound) / 1_000_000
        slider.maxValue = Double(limits.upperBound) / 1_000_000
        slider.doubleValue = Double(bitrate) / 1_000_000
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(bitrateChanged(_:))
        slider.setAccessibilityLabel(L10n.t(.videoBitrate))
        slider.didFinishDragging = { [weak self] in
            guard let self else { return }
            self.bitrateChanged(self.slider)
        }

        let row = NSStackView(views: [title, slider, valueLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12

        let content = NSStackView(views: [prompt, separator, row])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            separator.widthAnchor.constraint(equalTo: content.widthAnchor),
            row.widthAnchor.constraint(equalTo: content.widthAnchor),
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
        ])
        updateValueLabel()
    }

    required init?(coder: NSCoder) { nil }

    @objc func bitrateChanged(_ sender: NSSlider) {
        sender.doubleValue = min(max(sender.doubleValue.rounded(), sender.minValue), sender.maxValue)
        updateValueLabel()
        if !slider.isDragging {
            onCommit(Int(sender.doubleValue) * 1_000_000)
        }
    }

    private func updateValueLabel() {
        let title = L10n.format(.customBitrateValue, Int(slider.doubleValue), Int(slider.maxValue))
        valueLabel.stringValue = title
        slider.setAccessibilityValueDescription(title)
    }
}

@MainActor
final class MenuBitrateSlider: NSSlider {
    private(set) var isDragging = false
    var didFinishDragging: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        super.mouseDown(with: event)
        isDragging = false
        didFinishDragging?()
    }
}
