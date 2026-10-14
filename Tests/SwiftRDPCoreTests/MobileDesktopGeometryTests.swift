import CoreGraphics
import CoreVideo
import ScreenCaptureKit
import XCTest
@testable import SwiftRDPCore

final class MobileDesktopGeometryTests: XCTestCase {
    func testConnectInitialPreservesIPhoneDesktop() {
        let session = makeTLSSession()
        session.receive(X224.buildData(connectInitial(width: 1424, height: 700)))

        XCTAssertEqual(session.phase, .channelConnection)
        XCTAssertEqual(session.clientWidth, 1424)
        XCTAssertEqual(session.clientHeight, 700)
        XCTAssertEqual(session.info.width, 1424)
        XCTAssertEqual(session.info.height, 700)
        XCTAssertEqual(session.info.clientName, "iPhone")
    }

    func testConnectInitialRejectsUnknownVersionWithoutSendingAResponse() {
        for version: UInt32 in [0, 0x0008_0001, 0x0008_0003, 0x0008_0012, .max] {
            let session = makeTLSSession()
            var responses = 0
            var closes = 0
            session.socket.onWriteBatch = { packets, _, _ in
                responses += packets.count
                return true
            }
            session.onClose = { closes += 1 }
            session.receive(X224.buildData(connectInitial(width: 1424, height: 700, version: version)))

            XCTAssertEqual(session.phase, .terminated)
            XCTAssertEqual(responses, 0)
            XCTAssertEqual(closes, 1)
        }
    }

    func testConnectInitialAcceptsCurrentClientCoreMarker() {
        let session = makeTLSSession()
        session.receive(X224.buildData(connectInitial(width: 1424, height: 700, version: 0x0008_0004)))
        XCTAssertEqual(session.phase, .channelConnection)
    }

    func testConnectInitialRejectsMissingClientCoreData() {
        let session = makeTLSSession()
        session.receive(X224.buildData(connectInitial(width: 1424, height: 700, coreType: 0xFFFF)))
        XCTAssertEqual(session.phase, .terminated)
    }

    func testDemandActiveDoesNotReplaceClientSizeWithPhysicalPanel() {
        for (width, height) in [(1424, 700), (1425, 701)] {
            let session = makeTLSSession()
            session.clientWidth = width
            session.clientHeight = height
            // SEC_INFO_PKT followed by a Unicode TS_INFO_PACKET with empty strings.
            let info = ByteWriter.u32(0) + ByteWriter.u32(0x10)
                + [UInt8](repeating: 0, count: 20)
            var mcs = MCS.buildSendDataIndication(
                userId: 1001, channelId: 1003, data: [0x40, 0, 0, 0] + info
            )
            mcs[0] = 0x64
            session.receive(X224.buildData(mcs))

            XCTAssertEqual(session.phase, .capabilities)
            XCTAssertEqual(session.clientWidth, 1424)
            XCTAssertEqual(session.clientHeight, 700)
        }
    }

    func testMouseAndTouchSubtractBarsBeforeScalingOnAnOffsetDisplay() {
        let mouse = MouseHandler()
        let touch = TouchInput()
        let layout = DisplayContentLayout.aspectFit(
            desktopWidth: 1424, desktopHeight: 700,
            sourceWidth: 3024, sourceHeight: 1964
        )
        let injector = InputInjector(mouse: mouse, touch: touch)
        injector.setDesktopMapping(DesktopInputMapping(
            layout: layout,
            hostBounds: CGRect(x: -1512, y: 100, width: 1512, height: 982)
        ))
        XCTAssertEqual(mouse.coordinateMapping, touch.coordinateMapping)

        for (x, y, expected) in [
            (0, 0, CGPoint(x: -1512, y: 100)),
            (712, 350, CGPoint(x: -756, y: 591)),
            (1424, 700, CGPoint(x: -1, y: 1081)),
        ] {
            XCTAssertEqual(mouse.absolutePoint(x: x, y: y), expected)
            XCTAssertEqual(touch.absolutePoint(x: x, y: y), expected)
        }
    }

    func testCaptureUsesTheSameClientSizedSurfaceAndContentRectAsInput() {
        let layout = DisplayContentLayout.aspectFit(
            desktopWidth: 1424, desktopHeight: 700,
            sourceWidth: 3024, sourceHeight: 1964
        )
        let config = ScreenCapturer.makeStreamConfiguration(
            layout: layout, fps: 60, capturesAudio: false
        )
        XCTAssertEqual(config.width, 1424)
        XCTAssertEqual(config.height, 700)
        XCTAssertEqual(config.destinationRect, layout.contentRect)
        XCTAssertTrue(config.scalesToFit)
        XCTAssertTrue(config.preservesAspectRatio)
        XCTAssertEqual(config.pixelFormat, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    }

    func testRelativeInputPreservesProtocolAxisDirectionAndRoundTrips() {
        let layout = DisplayContentLayout.aspectFit(
            desktopWidth: 1512, desktopHeight: 982,
            sourceWidth: 3024, sourceHeight: 1964
        )
        let mapping = DesktopInputMapping(
            layout: layout,
            hostBounds: CGRect(x: -1512, y: 100, width: 1512, height: 982)
        )
        let delta = mapping.hostDelta(dx: -10, dy: -20)
        XCTAssertEqual(delta.dx, -10)
        XCTAssertEqual(delta.dy, -20, "RDP and Quartz both use negative Y for upward movement")
        XCTAssertEqual(
            mapping.desktopPoint(for: mapping.hostPoint(x: 712, y: 350)),
            CGPoint(x: 712, y: 350)
        )
    }

    func testInputIsUnmappedUntilCaptureGeometryIsKnown() {
        let injector = InputInjector()
        XCTAssertNil(injector.mouse.absolutePoint(x: 100, y: 100))
        XCTAssertNil(injector.touch.absolutePoint(x: 100, y: 100))
    }

    func testCaptureTargetUsesClientSizeWithoutChangingPhysicalResolution() throws {
        let manager = try makeTestSessionManager()
        try XCTSkipUnless(manager.hostDisplayMode == .physicalMirror, "Requires a physical capture source")
        let session = RDPSession(config: manager.config)
        session.sessionManager = manager
        session.clientWidth = 1424
        session.clientHeight = 700
        let hostSize = VirtualDisplayManager.physicalDisplayPixelSize()
        let original = try session.captureTarget(for: manager)
        XCTAssertEqual(original.width, 1424)
        XCTAssertEqual(original.height, 700)

        session.handleDesktopResize(width: 700, height: 1424)
        let rotated = try session.captureTarget(for: manager)
        XCTAssertEqual(rotated.width, 700)
        XCTAssertEqual(rotated.height, 1424)
        XCTAssertEqual(rotated.displayID, original.displayID)
        XCTAssertEqual(session.info.width, 700)
        XCTAssertEqual(session.info.height, 1424)
        let after = VirtualDisplayManager.physicalDisplayPixelSize()
        XCTAssertEqual(after.width, hostSize.width)
        XCTAssertEqual(after.height, hostSize.height)
    }

    func testMissingVirtualSourceDoesNotFallBackToPhysicalCapture() throws {
        let manager = try makeTestSessionManager(config: ServerConfig(hostDisplayPolicy: .virtual))
        let session = RDPSession(config: manager.config)
        XCTAssertThrowsError(try session.captureTarget(for: manager)) { error in
            guard case ScreenCapturer.CaptureError.noDisplay = error else {
                return XCTFail("Unexpected source error: \(error)")
            }
        }
    }

    private func makeTLSSession() -> RDPSession {
        let session = RDPSession(config: ServerConfig(nlaEnabled: false))
        let request: [UInt8] = [14, 0xE0, 0, 0, 0, 0, 0, 1, 0, 8, 0]
            + ByteWriter.u32(X224.protocolSSL)
        session.receive(TPKT.wrap(request))
        session.notifyTLSCompleted()
        XCTAssertEqual(session.phase, .basicSettings)
        return session
    }

    private func connectInitial(
        width: UInt16,
        height: UInt16,
        version: UInt32 = GCC.rdpVersionMax,
        coreType: UInt16 = GCC.csCore
    ) -> [UInt8] {
        var core = ByteWriter.u32(version)
            + ByteWriter.u16(width) + ByteWriter.u16(height) + ByteWriter.u16(24)
        core += [UInt8](repeating: 0, count: 10)
        let name = Array("iPhone".data(using: .utf16LittleEndian)!)
        core += name + [UInt8](repeating: 0, count: 32 - name.count)
        let block = ByteWriter.u16(coreType) + ByteWriter.u16(UInt16(core.count + 4)) + core
        let gcc = Array("Duca".utf8) + [UInt8(block.count)] + block
        let parameters = MCS.encodeDomainParameters(.rdpDefault)
        let body = BER.encodeOctetString([1]) + BER.encodeOctetString([1])
            + [1, 1, 0xFF] + parameters + parameters + parameters + BER.encodeOctetString(gcc)
        return [0x7F, 0x65] + BER.encodeLength(body.count) + body
    }
}
