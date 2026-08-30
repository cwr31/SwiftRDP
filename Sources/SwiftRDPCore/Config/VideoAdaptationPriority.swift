import Foundation

/// When configured FPS and bitrate cannot both be sustained, which dimension
/// to sacrifice first.
public enum VideoAdaptationPriority: String, Sendable, CaseIterable {
    /// Lower frame rate before reducing encode bitrate.
    case qualityFirst
    /// Lower encode bitrate before reducing frame rate.
    case fpsFirst
}
