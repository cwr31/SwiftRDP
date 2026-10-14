import Foundation

/// User frame-rate ceiling; capture and encoding follow the adapted target.
enum VideoFPSPreset: Int, CaseIterable, Identifiable {
    case rate15 = 15
    case rate30 = 30
    case rate45 = 45
    case rate60 = 60

    static let `default`: VideoFPSPreset = .rate60

    var id: Int { rawValue }

    var title: String {
        L10n.format(.fpsRateTitle, rawValue)
    }
}
