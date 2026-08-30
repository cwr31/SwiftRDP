import XCTest
@testable import SwiftRDPCore

final class FrameAckTrackerTests: XCTestCase {
    func testAcknowledgementMeasuresFromAcknowledgedFrameSend() throws {
        let tracker = FrameAckTracker()
        tracker.track(frameId: 1, bytes: 100, nowNanoseconds: 1_000_000)
        tracker.track(frameId: 2, bytes: 200, nowNanoseconds: 10_000_000)
        tracker.track(frameId: 3, bytes: 300, nowNanoseconds: 20_000_000)

        let sample = try XCTUnwrap(tracker.acknowledge(upTo: 2, nowNanoseconds: 50_000_000))

        XCTAssertEqual(sample.latencyMs, 40, accuracy: 0.001)
        XCTAssertEqual(sample.unacked, 1)
        XCTAssertEqual(sample.acknowledgedBytes, 300)
        XCTAssertEqual(sample.acknowledgementIntervalMs, 49, accuracy: 0.001)
        XCTAssertEqual(tracker.count, 1)
    }

    func testDuplicateAcknowledgementDoesNotCreateLatencySample() {
        let tracker = FrameAckTracker()
        tracker.track(frameId: 7, nowNanoseconds: 1_000_000)
        XCTAssertNotNil(tracker.acknowledge(upTo: 7, nowNanoseconds: 5_000_000))
        XCTAssertNil(tracker.acknowledge(upTo: 7, nowNanoseconds: 6_000_000))
    }

    func testAcknowledgementHandlesFrameIDWrap() throws {
        let tracker = FrameAckTracker()
        tracker.track(frameId: UInt32.max - 1, bytes: 10, nowNanoseconds: 1_000_000)
        tracker.track(frameId: UInt32.max, bytes: 20, nowNanoseconds: 2_000_000)
        tracker.track(frameId: 0, bytes: 30, nowNanoseconds: 3_000_000)
        tracker.track(frameId: 1, bytes: 40, nowNanoseconds: 4_000_000)

        let sample = try XCTUnwrap(tracker.acknowledge(upTo: 0, nowNanoseconds: 10_000_000))

        XCTAssertEqual(sample.acknowledgedBytes, 60)
        XCTAssertEqual(sample.unacked, 1)
        XCTAssertEqual(tracker.acknowledge(upTo: UInt32.max, nowNanoseconds: 11_000_000), nil)
    }
}
