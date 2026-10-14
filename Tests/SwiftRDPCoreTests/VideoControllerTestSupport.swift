import Foundation
@testable import SwiftRDPCore

/// A measured fast path for tests of feedback after startup has completed.
func makeMeasuredVideoController(
    bitrate: Int = ServerConfig.defaultVideoBitrate,
    fps: Int = 60,
    adaptationPriority: VideoAdaptationPriority = .qualityFirst
) -> VideoTargetController {
    let controller = VideoTargetController(bitrate: bitrate, fps: fps,
        adaptationPriority: adaptationPriority)
    var metrics = NetworkAutoDetect.Metrics()
    metrics.bandwidthKbps = 100_000
    metrics.bandwidthMeasuredAtNanoseconds = 1
    controller.updateAutoDetect(metrics)
    return controller
}

/// Generates actual source demand at its current budget, rather than claiming
/// additional bandwidth from idle ACK or queue callbacks.
func noteVideoDemand(_ controller: VideoTargetController, interval: TimeInterval, now: Date) {
    controller.noteEncodedFrame(bytes: Int(Double(controller.targetBitrate) * interval / 8), now: now)
}
