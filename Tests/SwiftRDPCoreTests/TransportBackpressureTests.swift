import XCTest
@testable import SwiftRDPCore

final class TransportBackpressureTests: XCTestCase {
    func testFailedUDPBootstrapKeepsCurrentTCPMeasurements() {
        let session = RDPSession(config: ServerConfig())
        var metrics = NetworkAutoDetect.Metrics()
        metrics.bandwidthKbps = 1_000
        metrics.bandwidthMeasuredAtNanoseconds = 1
        session.videoController.updateAutoDetect(metrics)
        let before = session.videoController.serverQueueDrainBitrate
        session.setGraphicsUsesUDP(false)
        XCTAssertEqual(session.videoController.serverQueueDrainBitrate, before)
    }

    func testUDPGraphicsUsesItsOwnQueueAndWritability() {
        let session = RDPSession(config: ServerConfig())
        session.setChannelWritable(false)
        session.setNIOOutboundQueueBytes(session.videoOutboundQueueWatermarks().high)
        session.setVideoFrameQueueFull(true)
        XCTAssertFalse(session.graphicsWritable)

        session.setGraphicsUsesUDP(true)
        XCTAssertTrue(session.graphicsWritable)
        XCTAssertFalse(session.channelWritable)
        let high = session.videoOutboundQueueWatermarks().high
        session.updateUDPGraphicsState(.init(queuedBytes: high, framesFull: false))
        XCTAssertFalse(session.graphicsWritable)
        session.setNIOOutboundQueueBytes(0)
        session.setVideoFrameQueueFull(false)
        session.setChannelWritable(true)
        XCTAssertFalse(session.graphicsWritable)
        session.updateUDPGraphicsState(.init(queuedBytes: 0, framesFull: true))
        XCTAssertFalse(session.graphicsWritable)
        session.updateUDPGraphicsState(.init(queuedBytes: 0, framesFull: false))
        XCTAssertTrue(session.graphicsWritable)
        session.setGraphicsUsesUDP(false)
        XCTAssertTrue(session.graphicsWritable)
        session.setChannelWritable(false)
        XCTAssertFalse(session.graphicsWritable)
    }

    func testTransportSwitchCannotRenewOldBandwidthAndPreservesTargets() {
        let controller = VideoTargetController(bitrate: 10_000_000, fps: 30)
        var metrics = NetworkAutoDetect.Metrics()
        metrics.bandwidthKbps = 1_000
        metrics.bandwidthMeasuredAtNanoseconds = 1
        controller.updateAutoDetect(metrics)
        let start = Date()
        for index in 0..<64 {
            let time = start.addingTimeInterval(Double(index) * 0.4)
            noteVideoDemand(controller, interval: 0.4, now: time)
            controller.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 30, unacked: 0,
                now: time)
        }
        XCTAssertEqual(controller.targetBitrate, controller.configuredBitrate)
        let limited = controller.serverQueueDrainBitrate
        let fps = controller.targetFPS, bitrate = controller.targetBitrate
        controller.resetNetworkPathMeasurements()
        let fresh = controller.serverQueueDrainBitrate
        XCTAssertGreaterThan(fresh, limited)
        controller.updateAutoDetect(metrics)
        XCTAssertEqual(controller.serverQueueDrainBitrate, fresh)
        XCTAssertEqual(controller.targetFPS, fps)
        XCTAssertEqual(controller.targetBitrate, bitrate)
    }

    func testNIOQueueWatermarkUsesHysteresis() {
        let session = RDPSession(config: ServerConfig())

        XCTAssertTrue(session.graphicsWritable)

        let watermarks = session.videoOutboundQueueWatermarks()
        XCTAssertGreaterThan(watermarks.high, watermarks.low)
        XCTAssertGreaterThanOrEqual(watermarks.limit, watermarks.high)

        session.setNIOOutboundQueueBytes(watermarks.high)
        XCTAssertFalse(session.graphicsWritable)

        session.setNIOOutboundQueueBytes(watermarks.low + 1)
        XCTAssertFalse(session.graphicsWritable)

        session.setNIOOutboundQueueBytes(watermarks.low)
        XCTAssertTrue(session.graphicsWritable)
    }

    func testChannelWritabilityIsSynchronizedWithGraphicsAdmission() {
        let session = RDPSession(config: ServerConfig())

        session.setChannelWritable(false)
        XCTAssertFalse(session.channelWritable)
        XCTAssertFalse(session.graphicsWritable)

        session.setChannelWritable(true)
        XCTAssertTrue(session.channelWritable)
        XCTAssertTrue(session.graphicsWritable)
    }

    func testVideoQueueBudgetTracksPacingRate() {
        let session = RDPSession(config: ServerConfig())
        var metrics = NetworkAutoDetect.Metrics()
        metrics.bandwidthKbps = 100_000
        metrics.baseRTTMs = 10
        metrics.rttMeasuredAtNanoseconds = 1
        metrics.bandwidthMeasuredAtNanoseconds = 1
        session.videoController.updateAutoDetect(metrics)
        let initial = session.videoOutboundQueueWatermarks()

        session.applyVideoQuality(VideoQualitySettings(mode: .custom, customBitrate: 1_000_000))
        let reduced = session.videoOutboundQueueWatermarks()

        XCTAssertLessThan(reduced.limit, initial.limit)
        XCTAssertGreaterThanOrEqual(reduced.limit, reduced.high)
        XCTAssertGreaterThan(reduced.high, reduced.low)
    }
}
