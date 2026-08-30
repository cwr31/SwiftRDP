import Foundation

/// Codec families implemented by the Graphics pipeline.
/// AVC444 is intentionally outside this enum until its complete wire format is implemented.
public enum GraphicsCodec: String, Sendable {
    case h264AVC420
    case remoteFXProgressive

    public var isProgressive: Bool {
        self == .remoteFXProgressive
    }

    public var label: String {
        switch self {
        case .h264AVC420: return "H.264 AVC420"
        case .remoteFXProgressive: return "RemoteFX Progressive"
        }
    }
}
