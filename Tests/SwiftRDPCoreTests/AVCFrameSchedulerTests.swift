import XCTest
@testable import SwiftRDPCore

final class AVCFrameSchedulerTests: XCTestCase {
    func testDroppedFinalCaptureRetriesWithoutAnotherPublication() throws {
        var scheduler = AVCFrameScheduler()
        scheduler.observe(sequence: 1, now: 0)
        let first = try XCTUnwrap(scheduler.reserve(sequence: 1, forced: false, now: 0))
        XCTAssertNil(scheduler.reserve(sequence: 1, forced: false, now: 1))
        scheduler.complete(first, sent: false, now: 10, retryAfterNanoseconds: 20)
        XCTAssertEqual(scheduler.nextWaitNanoseconds(now: 10), 20)
        XCTAssertNil(scheduler.reserve(sequence: 1, forced: false, now: 29))
        let retry = try XCTUnwrap(scheduler.reserve(sequence: 1, forced: false, now: 30))
        XCTAssertFalse(retry.isRefinement)
        scheduler.complete(retry, sent: true, now: 40, meanSquaredError: 100)
        XCTAssertNil(scheduler.reserve(sequence: 1, forced: false, now: 41))
    }

    func testOldCompletionCannotHideANewerDroppedCapture() throws {
        var scheduler = AVCFrameScheduler()
        scheduler.observe(sequence: 1, now: 0)
        let old = try XCTUnwrap(scheduler.reserve(sequence: 1, forced: false, now: 0))
        scheduler.observe(sequence: 2, now: 1)
        let latest = try XCTUnwrap(scheduler.reserve(sequence: 2, forced: false, now: 1))
        scheduler.complete(latest, sent: false, now: 2)
        scheduler.complete(old, sent: true, now: 3, meanSquaredError: 100)
        let retry = try XCTUnwrap(scheduler.reserve(sequence: 2, forced: false, now: 4))
        XCTAssertFalse(retry.isRefinement)
        XCTAssertNil(scheduler.reserve(sequence: 1, forced: false, now: 4))
    }

    func testNewerSuccessfulCaptureSupersedesAnOldFailure() throws {
        var scheduler = AVCFrameScheduler()
        scheduler.observe(sequence: 1, now: 0)
        let old = try XCTUnwrap(scheduler.reserve(sequence: 1, forced: false, now: 0))
        scheduler.observe(sequence: 2, now: 1)
        let latest = try XCTUnwrap(scheduler.reserve(sequence: 2, forced: false, now: 1))
        scheduler.complete(latest, sent: true, now: 2, meanSquaredError: 100)
        scheduler.complete(old, sent: false, now: 3)
        XCTAssertNil(scheduler.reserve(sequence: 1, forced: false, now: 4))
        XCTAssertNil(scheduler.reserve(sequence: 2, forced: false, now: 4))
    }

    func testStaticRefinementWaitsForQuietAndStopsAfterOneAttempt() throws {
        var scheduler = try deliveredScheduler()
        let quiet = AVCFrameScheduler.quietIntervalNanoseconds
        XCTAssertEqual(scheduler.nextWaitNanoseconds(now: 0), quiet)
        XCTAssertNil(scheduler.reserve(sequence: 1, forced: false, now: quiet - 1))
        let first = try XCTUnwrap(scheduler.reserve(sequence: 1, forced: false, now: quiet))
        XCTAssertTrue(first.isRefinement)
        XCTAssertNil(scheduler.reserve(sequence: 1, forced: false, now: quiet + 1))
        scheduler.complete(first, sent: true, now: quiet + 1, meanSquaredError: 100)
        XCTAssertNil(scheduler.nextWaitNanoseconds(now: quiet + 1))
        XCTAssertNil(scheduler.reserve(sequence: 1, forced: false, now: 10_000_000_000))
    }

    func testFailedOptionalRefinementsDoNotRetryForever() throws {
        var scheduler = try deliveredScheduler()
        let submission = try XCTUnwrap(scheduler.reserve(sequence: 1, forced: false, now: 250_000_000))
        XCTAssertTrue(submission.isRefinement)
        scheduler.complete(submission, sent: false, now: 250_000_000)
        XCTAssertNil(scheduler.nextWaitNanoseconds(now: 1_000_000_000))
        XCTAssertNil(scheduler.reserve(sequence: 1, forced: false, now: 1_000_000_000))
    }

    func testNewCaptureCancelsUnsubmittedRefinementAndRestartsQuietDeadline() throws {
        var scheduler = try deliveredScheduler()
        scheduler.observe(sequence: 2, now: 249_000_000)
        XCTAssertNil(scheduler.reserve(sequence: 1, forced: false, now: 250_000_000))
        let latest = try XCTUnwrap(scheduler.reserve(sequence: 2, forced: false, now: 250_000_000))
        XCTAssertFalse(latest.isRefinement)
        scheduler.complete(latest, sent: true, now: 251_000_000, meanSquaredError: 100)
        XCTAssertEqual(scheduler.nextWaitNanoseconds(now: 251_000_000), 248_000_000)
    }

    func testNewCaptureKeepsAnAlreadyEncodedReferenceInFlight() throws {
        var scheduler = try deliveredScheduler()
        let refinement = try XCTUnwrap(scheduler.reserve(sequence: 1, forced: false, now: 250_000_000))
        scheduler.observe(sequence: 2, now: 251_000_000)
        let latest = try XCTUnwrap(scheduler.reserve(sequence: 2, forced: false, now: 251_000_000))
        scheduler.complete(refinement, sent: true, now: 252_000_000, meanSquaredError: 100)
        XCTAssertNil(scheduler.reserve(sequence: 2, forced: false, now: 253_000_000))
        scheduler.complete(latest, sent: false, now: 254_000_000)
        XCTAssertNotNil(scheduler.reserve(sequence: 2, forced: false, now: 255_000_000))
    }

    func testPressureBlocksOnlyOptionalRefinementAndRecoveryResumesIt() throws {
        var scheduler = try deliveredScheduler()
        scheduler.updateBudget(bitrate: 2_000_000, refinementAllowed: false, now: 0)
        XCTAssertNil(scheduler.reserve(sequence: 1, forced: false, now: 1_000_000_000))
        XCTAssertNil(scheduler.nextWaitNanoseconds(now: 1_000_000_000))
        scheduler.observe(sequence: 2, now: 1_000_000_000)
        let latest = try XCTUnwrap(scheduler.reserve(sequence: 2, forced: false, now: 1_000_000_000))
        scheduler.complete(latest, sent: true, now: 1_000_000_001, meanSquaredError: 100)
        scheduler.updateBudget(bitrate: 2_000_000, refinementAllowed: true, now: 2_000_000_000)
        XCTAssertTrue(try XCTUnwrap(scheduler.reserve(sequence: 2, forced: false, now: 2_000_000_000)).isRefinement)
    }

    func testHigherAdaptiveBudgetRearmsButLowerBudgetDoesNot() throws {
        var scheduler = try deliveredScheduler()
        scheduler.updateBudget(bitrate: 2_000_000, refinementAllowed: true, now: 0)
        try exhaustRefinements(&scheduler)
        scheduler.updateBudget(bitrate: 1_000_000, refinementAllowed: true, now: 1_000_000_000)
        XCTAssertNil(scheduler.nextWaitNanoseconds(now: 1_000_000_000))
        scheduler.updateBudget(bitrate: 1_250_000, refinementAllowed: true, now: 2_000_000_000)
        XCTAssertTrue(try XCTUnwrap(scheduler.reserve(sequence: 1, forced: false, now: 2_000_000_000)).isRefinement)
    }

    func testExplicitQualityRefreshCoalescesWithoutAccumulatingFrames() throws {
        var scheduler = try deliveredScheduler()
        try exhaustRefinements(&scheduler)
        for _ in 0..<100 { scheduler.requestRefinement(now: 1_000_000_000) }
        let submission = try XCTUnwrap(scheduler.reserve(sequence: 1, forced: false, now: 1_000_000_000))
        scheduler.complete(submission, sent: true, now: 1_000_000_000, meanSquaredError: 100)
        XCTAssertNil(scheduler.nextWaitNanoseconds(now: 2_000_000_000))
    }

    func testRefreshRequestsCannotBypassTheRefinementSpacing() throws {
        var scheduler = try deliveredScheduler()
        let first = try XCTUnwrap(scheduler.reserve(sequence: 1, forced: false, now: 250_000_000))
        scheduler.complete(first, sent: true, now: 251_000_000, meanSquaredError: 100)
        scheduler.requestRefinement(now: 252_000_000)
        XCTAssertNil(scheduler.reserve(sequence: 1, forced: false, now: 253_000_000))
        XCTAssertEqual(scheduler.nextWaitNanoseconds(now: 253_000_000), 197_000_000)
    }

    func testRefinementsCannotReplenishTheirOwnBudgetThroughQueuePressure() throws {
        var scheduler = try deliveredScheduler()
        let submission = try XCTUnwrap(scheduler.reserve(sequence: 1, forced: false, now: 250_000_000))
        scheduler.updateBudget(bitrate: 2_000_000, refinementAllowed: false, now: 250_000_000)
        scheduler.complete(submission, sent: true, now: 250_000_001, meanSquaredError: 100)
        scheduler.updateBudget(bitrate: 2_000_000, refinementAllowed: true, now: 250_000_002)
        XCTAssertNil(scheduler.nextWaitNanoseconds(now: 1_000_000_000))
    }

    func testForcedRefreshCanResendTheSameDeliveredCapture() throws {
        var scheduler = try deliveredScheduler()
        try exhaustRefinements(&scheduler)
        let forced = try XCTUnwrap(scheduler.reserve(sequence: 1, forced: true, now: 1_000_000_000))
        XCTAssertFalse(forced.isRefinement)
        XCTAssertNil(scheduler.reserve(sequence: 1, forced: true, now: 1_000_000_001))
    }

    func testResetDiscardsPendingAndDeliveredState() throws {
        var scheduler = try deliveredScheduler()
        try exhaustRefinements(&scheduler)
        scheduler = AVCFrameScheduler()
        scheduler.requestRefinement(now: 0)
        XCTAssertNil(scheduler.nextWaitNanoseconds(now: 0))
        scheduler.observe(sequence: 1, now: 0)
        XCTAssertFalse(try XCTUnwrap(scheduler.reserve(sequence: 1, forced: false, now: 0)).isRefinement)
    }

    func testRefinementRequiresMeasuredImprovementWithinItsByteBudget() throws {
        var scheduler = try deliveredScheduler()
        let submission = try XCTUnwrap(scheduler.reserve(sequence: 1, forced: false, now: 250_000_000))
        XCTAssertTrue(scheduler.shouldSendRefinement(submission, meanSquaredError: 80, bytes: 100, byteLimit: 100))
        XCTAssertFalse(scheduler.shouldSendRefinement(submission, meanSquaredError: 95, bytes: 100, byteLimit: 100))
        XCTAssertFalse(scheduler.shouldSendRefinement(submission, meanSquaredError: 110, bytes: 100, byteLimit: 100))
        XCTAssertFalse(scheduler.shouldSendRefinement(submission, meanSquaredError: nil, bytes: 100, byteLimit: 100))
        XCTAssertFalse(scheduler.shouldSendRefinement(submission, meanSquaredError: 80, bytes: 101, byteLimit: 100))
        scheduler.observe(sequence: 2, now: 250_000_001)
        XCTAssertFalse(scheduler.shouldSendRefinement(submission, meanSquaredError: 80, bytes: 100, byteLimit: 100))
    }

    func testMissingOrLosslessNativeMetricsDoNotScheduleOptionalWork() throws {
        for error in [nil, 0] as [Double?] {
            var scheduler = AVCFrameScheduler()
            scheduler.observe(sequence: 1, now: 0)
            let source = try XCTUnwrap(scheduler.reserve(sequence: 1, forced: false, now: 0))
            scheduler.complete(source, sent: true, now: 0, meanSquaredError: error)
            XCTAssertNil(scheduler.nextWaitNanoseconds(now: 1_000_000_000))
            XCTAssertNil(scheduler.reserve(sequence: 1, forced: false, now: 1_000_000_000))
            XCTAssertNotNil(scheduler.reserve(sequence: 1, forced: true, now: 1_000_000_000))
        }
    }

    func testStaticByteBudgetUsesOnlyTheCurrentPacingRate() {
        XCTAssertEqual(AVCFrameScheduler.refinementByteLimit(bitrate: 1_000_000), 22_500)
        XCTAssertEqual(AVCFrameScheduler.refinementByteLimit(bitrate: 20_000_000), 450_000)
    }

    private func deliveredScheduler() throws -> AVCFrameScheduler {
        var scheduler = AVCFrameScheduler()
        scheduler.observe(sequence: 1, now: 0)
        let submission = try XCTUnwrap(scheduler.reserve(sequence: 1, forced: false, now: 0))
        scheduler.complete(submission, sent: true, now: 0, meanSquaredError: 100)
        return scheduler
    }

    private func exhaustRefinements(_ scheduler: inout AVCFrameScheduler) throws {
        let submission = try XCTUnwrap(scheduler.reserve(sequence: 1, forced: false, now: 250_000_000))
        scheduler.complete(submission, sent: true, now: 250_000_000, meanSquaredError: 100)
    }
}
