import Foundation

public enum VideoQualityMode: String, Codable, CaseIterable, Sendable {
    case automatic
    case original
    case ultra
    case high
    case custom
}

/// User-selected video budgets. Transport adaptation stays active in every mode.
public struct VideoQualitySettings: Codable, Equatable, Sendable {
    public static let customBitrateRange = 1_000_000...500_000_000
    public static let defaultCustomBitrate = 30_000_000
    public static let `default` = VideoQualitySettings()

    public var mode: VideoQualityMode
    public var customBitrate: Int {
        didSet { customBitrate = Self.normalizedCustomBitrate(customBitrate) }
    }

    public init(mode: VideoQualityMode = .automatic, customBitrate: Int = defaultCustomBitrate) {
        self.mode = mode
        self.customBitrate = Self.normalizedCustomBitrate(customBitrate)
    }

    public var bitrateCeiling: Int {
        switch mode {
        case .automatic, .original: return 20_000_000
        case .ultra: return 8_000_000
        case .high: return 2_000_000
        case .custom: return customBitrate
        }
    }

    private static func normalizedCustomBitrate(_ bitrate: Int) -> Int {
        min(max(bitrate, customBitrateRange.lowerBound), customBitrateRange.upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case mode, customBitrate
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: try values.decode(VideoQualityMode.self, forKey: .mode),
            customBitrate: try values.decode(Int.self, forKey: .customBitrate)
        )
    }
}
