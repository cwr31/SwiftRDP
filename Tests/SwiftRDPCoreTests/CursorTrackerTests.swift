import CoreGraphics
import AppKit
import XCTest
@testable import SwiftRDPCore

final class CursorTrackerTests: XCTestCase {
    func testPointerScaleIsClampedToSupportedRange() {
        XCTAssertEqual(CursorTracker.normalizedScale(0.5), 1.0)
        XCTAssertEqual(CursorTracker.normalizedScale(2.0), 2.0)
        XCTAssertEqual(CursorTracker.normalizedScale(4.0), 3.0)
    }

    func testPointerDimensionsScaleAndRemainEven() {
        let normal = CursorTracker.scaledDimensions(
            for: CGSize(width: 16, height: 17),
            scale: 1.0
        )
        let retina = CursorTracker.scaledDimensions(
            for: CGSize(width: 16, height: 17),
            scale: 2.0
        )

        XCTAssertEqual(normal.width, 16)
        XCTAssertEqual(normal.height, 18)
        XCTAssertEqual(retina.width, 32)
        XCTAssertEqual(retina.height, 34)
    }

    func testPointerDimensionsRespectLargePointerLimit() {
        let dimensions = CursorTracker.scaledDimensions(
            for: CGSize(width: 64, height: 64),
            scale: 3.0
        )

        XCTAssertEqual(dimensions.width, 96)
        XCTAssertEqual(dimensions.height, 96)
    }

    func testChangingScaleInvalidatesDynamicPointerCache() {
        let tracker = CursorTracker(scale: 1.0, maximumDimension: 96)
        var updates: [[UInt8]] = []
        tracker.onSendFastPath = { updates.append($0) }

        XCTAssertTrue(tracker.publish(cursor: .arrow))
        XCTAssertEqual(updates.count, 2)
        XCTAssertFalse(tracker.publish(cursor: .arrow))
        XCTAssertEqual(updates.count, 2)

        tracker.setScale(2.0)
        XCTAssertTrue(tracker.publish(cursor: .arrow))

        XCTAssertEqual(updates.count, 4)
    }

    func testSuppressOutputPausesPointerUpdatesAndReactivatesCachedCursor() {
        let tracker = CursorTracker(scale: 1.0, maximumDimension: 96)
        var updates: [[UInt8]] = []
        tracker.onSendFastPath = { updates.append($0) }

        XCTAssertTrue(tracker.publish(cursor: .arrow))
        updates.removeAll()

        tracker.setOutputSuppressed(true)
        XCTAssertFalse(tracker.publish(cursor: .arrow))
        XCTAssertTrue(updates.isEmpty)

        tracker.setOutputSuppressed(false)
        XCTAssertTrue(tracker.publish(cursor: .arrow))
        XCTAssertEqual(updates.count, 1)
    }

    func testSessionManagerStoresAppliedScale() {
        let manager = SessionManager(config: ServerConfig(remotePointerScale: 1.0))

        manager.applyRemotePointerScale(2.5)

        XCTAssertEqual(manager.config.remotePointerScale, 2.5)
    }
}
