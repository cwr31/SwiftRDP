import XCTest
@testable import SwiftRDPCore

final class FrameHubTests: XCTestCase {
    func testDamageDistinguishesMissingMetadataFromAnUnchangedFrame() throws {
        let hub = FrameHub()
        hub.publish(CapturedFrame(width: 2, height: 2, bgrBottomUp: [], dirtyRects: []))
        let first = try XCTUnwrap(hub.currentFrameSnapshot())
        XCTAssertNil(first.dirtyRects(after: 0))
        XCTAssertEqual(first.dirtyRects(after: first.sequence), [])

        hub.publish(CapturedFrame(width: 2, height: 2, bgrBottomUp: [], dirtyRects: []))
        let unchanged = try XCTUnwrap(hub.currentFrameSnapshot())
        XCTAssertEqual(unchanged.dirtyRects(after: first.sequence), [])

        hub.publish(CapturedFrame(width: 2, height: 2, bgrBottomUp: []))
        let unknown = try XCTUnwrap(hub.currentFrameSnapshot())
        XCTAssertNil(unknown.dirtyRects(after: unchanged.sequence))
        XCTAssertEqual(unknown.dirtyRects(after: unknown.sequence), [])
    }

    func testSkippedCaptureSamplesRequireAFullDamageCheck() throws {
        let hub = FrameHub()
        hub.publish(CapturedFrame(width: 4, height: 4, bgrBottomUp: []))
        let first = try XCTUnwrap(hub.currentFrameSnapshot())
        let dirty = [CGRect(x: 0, y: 0, width: 2, height: 2)]
        hub.publish(CapturedFrame(width: 4, height: 4, bgrBottomUp: [], dirtyRects: dirty))
        let next = try XCTUnwrap(hub.currentFrameSnapshot())
        XCTAssertEqual(next.dirtyRects(after: first.sequence), dirty)

        hub.publish(CapturedFrame(width: 4, height: 4, bgrBottomUp: [], dirtyRects: []))
        let skipped = try XCTUnwrap(hub.currentFrameSnapshot())
        XCTAssertNil(skipped.dirtyRects(after: first.sequence))
    }

    func testPublishesLatestFrameAndTracksConsumerSkips() {
        let hub = FrameHub()
        var notifications = 0
        hub.onFrameAvailable = { notifications += 1 }

        let first = CapturedFrame(width: 2, height: 2, bgrBottomUp: [1])
        let second = CapturedFrame(width: 4, height: 4, bgrBottomUp: [2])
        let third = CapturedFrame(width: 6, height: 6, bgrBottomUp: [3])

        XCTAssertEqual(hub.publish(first), 1)
        XCTAssertEqual(hub.publish(second), 2)
        XCTAssertEqual(hub.publish(third), 3)
        XCTAssertEqual(notifications, 3)

        XCTAssertEqual(hub.markDelivered(sequence: 1, after: 0), 0)
        XCTAssertEqual(hub.markDelivered(sequence: 3, after: 1), 1)

        let snapshot = hub.currentFrameSnapshot()
        XCTAssertEqual(snapshot?.sequence, 3)
        XCTAssertEqual(snapshot?.frame.width, 6)
        XCTAssertEqual(snapshot?.frame.bgrBottomUp, [3])
        XCTAssertEqual(hub.statistics.deliveredFrames, 2)
        XCTAssertEqual(hub.statistics.skippedFrames, 1)
    }

    func testFirstDeliveryDoesNotCountPreviousCaptureIntervalAsSkipped() {
        let hub = FrameHub()
        _ = hub.publish(CapturedFrame(width: 2, height: 2, bgrBottomUp: []))
        _ = hub.publish(CapturedFrame(width: 2, height: 2, bgrBottomUp: []))

        XCTAssertEqual(hub.markDelivered(sequence: 2, after: 0), 0)
        XCTAssertEqual(hub.statistics.skippedFrames, 0)
    }

    func testClearingLatestFrameDoesNotReuseSequence() {
        let hub = FrameHub()
        _ = hub.publish(CapturedFrame(width: 2, height: 2, bgrBottomUp: []))
        hub.clearLatestFrame()

        XCTAssertNil(hub.currentFrameSnapshot())
        XCTAssertEqual(hub.publish(CapturedFrame(width: 2, height: 2, bgrBottomUp: [])), 2)
    }

    func testStatisticsCanStartANewCaptureInterval() {
        let hub = FrameHub()
        _ = hub.publish(CapturedFrame(width: 2, height: 2, bgrBottomUp: []))
        _ = hub.markDelivered(sequence: 1, after: 0)
        _ = hub.publish(CapturedFrame(width: 2, height: 2, bgrBottomUp: []))
        _ = hub.markDelivered(sequence: 2, after: 1)
        hub.resetStatistics()

        XCTAssertEqual(hub.statistics.publishedFrames, 0)
        XCTAssertEqual(hub.statistics.deliveredFrames, 0)
        XCTAssertEqual(hub.statistics.skippedFrames, 0)
        XCTAssertEqual(hub.publish(CapturedFrame(width: 2, height: 2, bgrBottomUp: [])), 3)
        XCTAssertEqual(hub.statistics.publishedFrames, 1)
    }
}
