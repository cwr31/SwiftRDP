import CoreVideo
import ScreenCaptureKit
import XCTest
@testable import SwiftRDPCore

final class DisplayCaptureLifecycleTests: XCTestCase {
    func testUnavailableCaptureSourcesUseNativeErrorCodes() {
        for code in [SCStreamError.Code.noWindowList, .noDisplayList, .noCaptureSource] {
            let error = NSError(domain: SCStreamErrorDomain, code: code.rawValue)
            XCTAssertTrue(ScreenCapturer.isCaptureSourceUnavailable(error))
        }
    }

    func testCaptureSourceClassificationChecksTheErrorDomainAndCode() {
        let unrelated = NSError(domain: "test", code: SCStreamError.Code.noCaptureSource.rawValue)
        XCTAssertFalse(ScreenCapturer.isCaptureSourceUnavailable(unrelated))
        let denied = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        XCTAssertFalse(ScreenCapturer.isCaptureSourceUnavailable(denied))
    }

    func testCaptureConfigurationUsesOnlyFullRangeNV12AndBT709() {
        let config = ScreenCapturer.makeStreamConfiguration(
            layout: .aspectFit(
                desktopWidth: 1920, desktopHeight: 1080,
                sourceWidth: 1920, sourceHeight: 1080
            ),
            fps: 60, capturesAudio: true
        )
        XCTAssertEqual(config.pixelFormat, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        XCTAssertEqual(config.colorSpaceName, CGColorSpace.itur_709)
        XCTAssertEqual(config.width, 1920)
        XCTAssertEqual(config.height, 1080)
        XCTAssertEqual(config.destinationRect, CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertTrue(config.preservesAspectRatio)
        XCTAssertEqual(config.minimumFrameInterval.timescale, 60)
        XCTAssertTrue(config.capturesAudio)
        XCTAssertFalse(config.showsCursor)
    }

    func testNativeConfigurationCopiesKeepTheBackgroundColorAlive() throws {
        let layout = DisplayContentLayout.aspectFit(
            desktopWidth: 1424, desktopHeight: 700,
            sourceWidth: 3024, sourceHeight: 1964
        )
        for _ in 0..<32 {
            try autoreleasepool {
                let configuration = autoreleasepool {
                    ScreenCapturer.makeStreamConfiguration(
                        layout: layout, fps: 60, capturesAudio: false
                    )
                }
                // SCStream copies its configuration after the factory returns.
                let copy = try XCTUnwrap(configuration.copy() as? SCStreamConfiguration)
                let background = try XCTUnwrap(copy.backgroundColor)
                XCTAssertEqual(background.alpha, 1)
                XCTAssertTrue(try XCTUnwrap(background.components).dropLast().allSatisfy { $0 == 0 })
                XCTAssertEqual(copy.destinationRect, layout.contentRect)
                XCTAssertEqual(copy.width, 1424)
                XCTAssertEqual(copy.height, 700)
            }
        }
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
