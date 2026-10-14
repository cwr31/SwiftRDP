import CoreVideo
import Foundation
import XCTest
@testable import SwiftRDPCore

final class RFXCaptureDamageTests: XCTestCase {
    func testStaleGeometryIsRejectedWithoutInspectingDamageOrRescaling() throws {
        let session = try makeSession()
        defer { session.gfx.stop() }
        let hub = FrameHub()
        hub.publish(frame(try makeBuffer(width: 128)))
        XCTAssertFalse(session.pushRFXFrame(snapshot: try XCTUnwrap(hub.currentFrameSnapshot())))
        XCTAssertTrue(session.rfxTileHashes.isEmpty)
        XCTAssertEqual(session.lastRFXDamageSequence, 0)
        XCTAssertFalse(session.gfx.hasPendingEncode)

        hub.publish(frame(try makeBuffer()))
        XCTAssertTrue(session.pushRFXFrame(snapshot: try XCTUnwrap(hub.currentFrameSnapshot())))
        waitForOutput(session, frameID: 1)
    }

    func testMissingMetadataIsInspectedOnlyOncePerCaptureSample() throws {
        let session = try makeSession()
        defer { session.gfx.stop() }
        let hub = FrameHub()
        let buffer = try makeBuffer()
        hub.publish(frame(buffer))
        XCTAssertTrue(session.pushRFXFrame(snapshot: try XCTUnwrap(hub.currentFrameSnapshot())))
        waitForOutput(session, frameID: 1)
        let originalHash = session.rfxTileHashes[0]

        hub.publish(frame(buffer))
        let unchanged = try XCTUnwrap(hub.currentFrameSnapshot())
        XCTAssertFalse(session.pushRFXFrame(snapshot: unchanged))
        XCTAssertEqual(session.lastRFXDamageSequence, unchanged.sequence)

        changePixel(buffer)
        XCTAssertFalse(session.pushRFXFrame(snapshot: unchanged))
        XCTAssertEqual(session.rfxTileHashes[0], originalHash)

        hub.publish(frame(buffer))
        XCTAssertTrue(session.pushRFXFrame(snapshot: try XCTUnwrap(hub.currentFrameSnapshot())))
        XCTAssertNotEqual(session.rfxTileHashes[0], originalHash)
        waitForOutput(session, frameID: 2)
    }

    func testExplicitlyEmptyMetadataDoesNotScanPixels() throws {
        let session = try makeSession()
        defer { session.gfx.stop() }
        let hub = FrameHub()
        let buffer = try makeBuffer()
        hub.publish(frame(buffer))
        XCTAssertTrue(session.pushRFXFrame(snapshot: try XCTUnwrap(hub.currentFrameSnapshot())))
        waitForOutput(session, frameID: 1)
        let originalHash = session.rfxTileHashes[0]

        changePixel(buffer)
        hub.publish(frame(buffer, dirty: []))
        XCTAssertFalse(session.pushRFXFrame(snapshot: try XCTUnwrap(hub.currentFrameSnapshot())))
        XCTAssertEqual(session.rfxTileHashes[0], originalHash)

        hub.publish(frame(buffer))
        XCTAssertTrue(session.pushRFXFrame(snapshot: try XCTUnwrap(hub.currentFrameSnapshot())))
        XCTAssertNotEqual(session.rfxTileHashes[0], originalHash)
        waitForOutput(session, frameID: 2)
    }

    func testSkippedCaptureSamplesDoNotLoseTheirDirtyTiles() throws {
        let session = try makeSession(width: 128)
        defer { session.gfx.stop() }
        let hub = FrameHub()
        let buffer = try makeBuffer(width: 128)
        hub.publish(frame(buffer))
        XCTAssertTrue(session.pushRFXFrame(snapshot: try XCTUnwrap(hub.currentFrameSnapshot())))
        waitForOutput(session, frameID: 1)
        let originalHashes = session.rfxTileHashes

        changePixel(buffer)
        hub.publish(frame(buffer, dirty: [CGRect(x: 0, y: 0, width: 1, height: 1)]))
        changePixel(buffer, x: 64)
        hub.publish(frame(buffer, dirty: [CGRect(x: 64, y: 0, width: 1, height: 1)]))
        XCTAssertTrue(session.pushRFXFrame(snapshot: try XCTUnwrap(hub.currentFrameSnapshot())))
        XCTAssertNotEqual(session.rfxTileHashes[0], originalHashes[0])
        XCTAssertNotEqual(session.rfxTileHashes[1], originalHashes[1])
        waitForOutput(session, frameID: 2)
    }

    func testBootstrapKeepsNewDamageForAlreadyPaintedTiles() throws {
        let session = try makeSession(width: 576, height: 512)
        defer { session.gfx.stop() }
        let hub = FrameHub()
        let buffer = try makeBuffer(width: 576, height: 512)
        hub.publish(frame(buffer))
        XCTAssertTrue(session.pushRFXFrame(snapshot: try XCTUnwrap(hub.currentFrameSnapshot())))
        waitForOutput(session, frameID: 1)
        XCTAssertTrue(session.rfxBootstrapSimplePending)
        XCTAssertFalse(session.rfxPendingKeys.contains(0))
        let originalHash = session.rfxTileHashes[0]

        changePixel(buffer)
        hub.publish(frame(buffer, dirty: [CGRect(x: 0, y: 0, width: 1, height: 1)]))
        XCTAssertTrue(session.pushRFXFrame(snapshot: try XCTUnwrap(hub.currentFrameSnapshot())))
        XCTAssertNotEqual(session.rfxTileHashes[0], originalHash)
        XCTAssertFalse(session.rfxBootstrapSimplePending)
        waitForOutput(session, frameID: 2)
    }

    private func makeSession(width: Int = 64, height: Int = 64) throws -> RDPSession {
        let session = RDPSession(config: ServerConfig(displayMode: .rfx))
        session.gfx.preferredCodec = .remoteFXProgressive
        session.gfx.attach(transport: RDPGFXDynamicChannelTransport { pdus, _, onWritten in
            onWritten?(DispatchTime.now().uptimeNanoseconds)
            return pdus.reduce(0) { $0 + $1.count }
        })
        try session.gfx.start(width: width, height: height)
        session.gfx.handleClientPDU(
            ByteWriter.u16(0x12) + ByteWriter.u16(0) + ByteWriter.u32(22)
                + ByteWriter.u16(1) + ByteWriter.u32(0x000A_0400)
                + ByteWriter.u32(4) + ByteWriter.u32(0)
        )
        XCTAssertTrue(session.gfx.isPipelineReady)
        // Damage admission is tested independently of adaptive frame skipping.
        session.videoController.setRFXAdaptiveMode(false)
        return session
    }

    private func waitForOutput(_ session: RDPSession, frameID: UInt32) {
        let finished = DispatchSemaphore(value: 0)
        let previous = session.gfx.onWorkAvailable
        session.gfx.onWorkAvailable = { previous?(); finished.signal() }
        defer { session.gfx.onWorkAvailable = previous }
        let deadline = DispatchTime.now() + 5
        while session.gfx.hasPendingEncode {
            guard finished.wait(timeout: deadline) == .success else {
                XCTFail("RemoteFX output did not complete")
                break
            }
        }
        XCTAssertEqual(session.gfx.unackedFrameCount, 1)
        session.gfx.handleClientPDU(
            ByteWriter.u16(0x0D) + ByteWriter.u16(0) + ByteWriter.u32(20)
                + ByteWriter.u32(0) + ByteWriter.u32(frameID) + ByteWriter.u32(frameID)
        )
        XCTAssertEqual(session.gfx.unackedFrameCount, 0)
    }

    private func makeBuffer(width: Int = 64, height: Int = 64) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &buffer
        ), kCVReturnSuccess)
        let result = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(result, [])
        if let base = CVPixelBufferGetBaseAddress(result) {
            memset(base, 64, CVPixelBufferGetDataSize(result))
        }
        CVPixelBufferUnlockBaseAddress(result, [])
        return result
    }

    private func changePixel(_ buffer: CVPixelBuffer, x: Int = 0) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let bytes = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self)
        bytes?[x * 4] = 192
    }

    private func frame(_ buffer: CVPixelBuffer, dirty: [CGRect]? = nil) -> CapturedFrame {
        CapturedFrame(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                      bgrBottomUp: [], dirtyRects: dirty, pixelBuffer: buffer)
    }
}
