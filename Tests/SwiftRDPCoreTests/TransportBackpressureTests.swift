import XCTest
@testable import SwiftRDPCore

final class TransportBackpressureTests: XCTestCase {
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

    func testVideoQueueBudgetUsesMeasuredDrainRate() {
        let session = RDPSession(config: ServerConfig())
        session.videoController.seedFromAutoDetect(bandwidthKbps: 100_000, rttMs: 10)
        let initial = session.videoOutboundQueueWatermarks()

        session.applyVideoBitrate(1_000_000)
        let reduced = session.videoOutboundQueueWatermarks()

        XCTAssertEqual(reduced.limit, initial.limit)
        XCTAssertGreaterThanOrEqual(reduced.limit, reduced.high)
        XCTAssertGreaterThan(reduced.high, reduced.low)
    }
}
