import Foundation
import SwiftRDPCore

extension VideoAdaptationPriority: Identifiable {
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .qualityFirst: return L10n.t(.adaptationQualityFirst)
        case .fpsFirst: return L10n.t(.adaptationFPSFirst)
        }
    }
}
