import XCTest
@testable import SwiftRDPCore

final class DisplayCaptureLifecycleTests: XCTestCase {
    func testDisplaySleepErrorDetectsChineseSCKMessage() {
        let error = NSError(
            domain: "com.apple.ScreenCaptureKit",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "找不到任何要捕捉的显示器或窗口"]
        )
        XCTAssertTrue(ScreenCapturer.isDisplaySleepError(error))
    }

    func testDisplaySleepErrorDetectsEnglishDisplayMissing() {
        let error = NSError(
            domain: "com.apple.ScreenCaptureKit",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Could not find display or window to capture"]
        )
        XCTAssertTrue(ScreenCapturer.isDisplaySleepError(error))
    }

    func testDisplaySleepErrorIgnoresUnrelatedErrors() {
        let error = NSError(
            domain: "test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Permission denied"]
        )
        XCTAssertFalse(ScreenCapturer.isDisplaySleepError(error))
    }

    func testDisplayWakeSessionBeginEndIsIdempotent() {
        DisplayWake.endCaptureSession()
        DisplayWake.beginCaptureSession(keepBuiltInPanelAwake: true)
        DisplayWake.beginCaptureSession(keepBuiltInPanelAwake: true)
        DisplayWake.endCaptureSession()
        DisplayWake.endCaptureSession()
    }

    func testAsleepBuiltInIsExcludedFromPhysicalDisplayIDs() {
        // When the built-in panel is clamshell-asleep it must not appear in
        // physicalDisplayIDs(); capture sleep/wake handlers rely on this.
        let ids = DisplayTopology.physicalDisplayIDs()
        for id in ids {
            XCTAssertEqual(CGDisplayIsAsleep(id), 0, "physicalDisplayIDs must exclude asleep panels")
            XCTAssertEqual(CGDisplayIsActive(id), 1)
        }
    }
}


extension DisplayCaptureLifecycleTests {
    /// `beginOperation` runs synchronously inside `start()` while holding the
    /// capture lock. Calling a lock-taking accessor from there (NSLock is not
    /// recursive) wedges the whole session — capture never starts, the client
    /// sees a black screen, and every later `setCaptureFPS` / codec callback
    /// piles up on the same mutex.
    func testStartReleasesTheCaptureLockAndDoesNotSelfDeadlock() async {
        let capturer = ScreenCapturer(width: 64, height: 64)
        Task { try? await capturer.start() }

        // Any lock-taking accessor: it can only answer once beginOperation has
        // returned and released the lock. Screen Recording is not required.
        let released = expectation(description: "capture lock released")
        Task.detached {
            _ = capturer.isCaptureAuthorized
            released.fulfill()
        }
        await fulfillment(of: [released], timeout: 10)
        await capturer.stopAndWait()
    }
}


extension DisplayCaptureLifecycleTests {
    /// `setCaptureFPS` retunes the live stream through `updateConfiguration`.
    /// It must never tear the stream down: a live capture-target change should
    /// not freeze the desktop or restart the first-sample wait.
    func testSetCaptureFPSDoesNotRestartTheCaptureLifecycle() async {
        let capturer = ScreenCapturer(width: 64, height: 64)
        // No stream is running (Screen Recording is not required for this): the
        // FPS is recorded and no restart is scheduled either way.
        capturer.setCaptureFPS(24)
        capturer.setCaptureFPS(24)
        capturer.setCaptureFPS(60)
        await capturer.stopAndWait()
    }
}
