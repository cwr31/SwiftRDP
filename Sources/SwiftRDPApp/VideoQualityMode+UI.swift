import SwiftRDPCore

extension VideoQualityMode: Identifiable {
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return L10n.t(.qualityAutomatic)
        case .original: return L10n.t(.qualityOriginal)
        case .ultra: return L10n.t(.qualityUltra)
        case .high: return L10n.t(.qualityHigh)
        case .custom: return L10n.t(.qualityCustom)
        }
    }
}
