/// H.264 encode bitrate ceiling (bps). The controller adapts down under pressure.
enum VideoQualityPreset: Int, CaseIterable, Identifiable {
    case mbps2 = 2_000_000
    case mbps8 = 8_000_000
    case mbps20 = 20_000_000
    case mbps50 = 50_000_000
    case mbps100 = 100_000_000

    static let `default`: VideoQualityPreset = .mbps20

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .mbps2: return L10n.t(.qualityMbps2)
        case .mbps8: return L10n.t(.qualityMbps8)
        case .mbps20: return L10n.t(.qualityMbps20)
        case .mbps50: return L10n.t(.qualityMbps50)
        case .mbps100: return L10n.t(.qualityMbps100)
        }
    }
}
