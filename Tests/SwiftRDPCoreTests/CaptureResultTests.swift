import XCTest
@testable import SwiftRDPCore

final class CaptureResultTests: XCTestCase {
    func testNativeCallbackPayloadArrivingBeforeWaitIsReturned() async throws {
        let result = CaptureResult<Int>()
        result.succeed(42)
        let value = try await result.wait(
            timeoutNanoseconds: 1_000_000_000,
            timeoutError: ScreenCapturer.CaptureError.shareableContentTimedOut
        )
        XCTAssertEqual(value, 42)
    }

    func testMissingNativeCallbackTimesOutWithoutWaitingForItToFinish() async {
        let result = CaptureResult<Int>()
        do {
            _ = try await result.wait(
                timeoutNanoseconds: 1_000_000,
                timeoutError: ScreenCapturer.CaptureError.shareableContentTimedOut
            )
            XCTFail("A missing native callback must time out")
        } catch {
            guard case ScreenCapturer.CaptureError.shareableContentTimedOut = error else {
                return XCTFail("Unexpected callback error: \(error)")
            }
        }
    }

    func testStartupDoesNotSucceedBeforeAFrameArrives() async throws {
        let startup = CaptureResult<Void>()
        let completion = CompletionState()
        let waiter = Task {
            try await startup.wait(timeoutNanoseconds: 1_000_000_000, timeoutError: ScreenCapturer.CaptureError.firstFrameTimedOut)
            await completion.finish()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let premature = await completion.finished
        XCTAssertFalse(premature)
        startup.succeed(())
        try await waiter.value
    }

    func testFrameArrivingBeforeWaitIsNotLost() async throws {
        let startup = CaptureResult<Void>()
        startup.succeed(())
        try await startup.wait(timeoutNanoseconds: 1_000_000_000, timeoutError: ScreenCapturer.CaptureError.firstFrameTimedOut)
    }

    func testMissingFrameTimesOutInsteadOfReportingSuccess() async {
        do {
            try await CaptureResult<Void>().wait(timeoutNanoseconds: 1_000_000, timeoutError: ScreenCapturer.CaptureError.firstFrameTimedOut)
            XCTFail("Startup without a frame must fail")
        } catch {
            guard case ScreenCapturer.CaptureError.firstFrameTimedOut = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testStreamFailureWakesTheStartupWaiter() async {
        let startup = CaptureResult<Void>()
        let waiter = Task { try await startup.wait(timeoutNanoseconds: 10_000_000_000, timeoutError: ScreenCapturer.CaptureError.firstFrameTimedOut) }
        await Task.yield()
        startup.fail(NSError(domain: "capture-startup-test", code: 42))
        do {
            try await waiter.value
            XCTFail("Stopped stream must not report success")
        } catch {
            XCTAssertEqual((error as NSError).domain, "capture-startup-test")
            XCTAssertEqual((error as NSError).code, 42)
        }
    }

    func testCancellationDoesNotWaitForTheStartupTimeout() async {
        let startup = CaptureResult<Void>()
        let waiter = Task { try await startup.wait(timeoutNanoseconds: 10_000_000_000, timeoutError: ScreenCapturer.CaptureError.firstFrameTimedOut) }
        await Task.yield()
        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("Cancelled startup must not report success")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testLateFrameFromFailedAttemptCannotCompleteTheNextAttempt() async {
        let previous = CaptureResult<Void>()
        previous.fail(ScreenCapturer.CaptureError.firstFrameTimedOut)
        previous.succeed(())
        let next = CaptureResult<Void>()
        do {
            try await next.wait(timeoutNanoseconds: 1_000_000, timeoutError: ScreenCapturer.CaptureError.firstFrameTimedOut)
            XCTFail("Only this attempt's frame can complete startup")
        } catch {
            guard case ScreenCapturer.CaptureError.firstFrameTimedOut = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}

private actor CompletionState {
    private(set) var finished = false
    func finish() { finished = true }
}
