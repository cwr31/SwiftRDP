import CoreGraphics
import CoreVideo
import XCTest
@testable import SwiftRDPCore

final class GFXPipelineTests: XCTestCase {
    private let zgfxDecoder = ZGFXCompressor()

    private func attach(
        _ pipeline: GFXPipeline,
        send: @escaping ([UInt8]) -> Void
    ) {
        pipeline.attach(
            transport: RDPGFXDynamicChannelTransport { pdus, _ in
                for pdu in pdus { send(pdu) }
                return pdus.reduce(0) { $0 + $1.count }
            }
        )
    }

    func testAVC106EncodesDesktopSizeOneToOne() throws {
        let pipeline = GFXPipeline()
        var writes: [[UInt8]] = []
        attach(pipeline) { writes.append($0) }
        pipeline.asyncEncoding = false
        defer { pipeline.stop() }

        try pipeline.start(width: 1920, height: 1200)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0600))

        let commands = writes.map(unwrap).map { readU16($0, at: 0) }
        // RESET, CAPS_CONFIRM, CREATE, MAP (unscaled)
        XCTAssertEqual(commands, [0x0013, 0x000E, 0x0009, 0x000F])
        let create = unwrap(writes[2])
        // Encode 1:1 at desktop size (only align down to 16).
        XCTAssertEqual(readU16(create, at: 10), 1920)
        XCTAssertEqual(readU16(create, at: 12), 1200)
        XCTAssertEqual(pipeline.surfaceEncodeSize.width, 1920)
        XCTAssertEqual(pipeline.surfaceEncodeSize.height, 1200)
        XCTAssertEqual(pipeline.h264.visibleWidth, 1920)
        XCTAssertEqual(pipeline.h264.visibleHeight, 1200)
    }

    func testForceRequestDuringBootstrapSurvivesTheInFlightIDR() throws {
        let pipeline = GFXPipeline()
        let collector = WriteCollector()
        attach(pipeline) { collector.append($0) }
        pipeline.asyncEncoding = true
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        let setupWriteCount = collector.count
        let buffer = try makePixelBuffer(width: 64, height: 64)

        XCTAssertEqual(pipeline.encodeFrame(pixelBuffer: buffer), .submitted)
        pipeline.requestForceIDR(reason: "refresh during bootstrap")
        _ = try waitForWrites(collector, count: setupWriteCount + 3)
        XCTAssertTrue(pipeline.hasPendingForcedFrame)

        pipeline.handleClientPDU(frameAck(frameId: 1))
        XCTAssertEqual(pipeline.encodeFrame(pixelBuffer: buffer), .submitted)
        let writes = try waitForWrites(collector, count: setupWriteCount + 6)
        let wire = unwrap(writes[setupWriteCount + 4])
        XCTAssertTrue(containsAnnexBNAL(type: 5, in: wire))
    }

    func testBootstrapUsesNegotiatedFrameWindowAndKeepsPFrameChain() throws {
        let pipeline = GFXPipeline()
        var writes: [[UInt8]] = []
        // Keep the window small so two H.264 frames (plus bootstrap probe) saturate it.
        pipeline.configureFrameAcknowledgement(maxUnacknowledgedFrameCount: 2)
        attach(pipeline) { writes.append($0) }
        pipeline.asyncEncoding = false
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        let setupWriteCount = writes.count
        let first = try makePixelBuffer(width: 64, height: 64, value: 0)
        let second = try makePixelBuffer(width: 64, height: 64, value: 20)
        let third = try makePixelBuffer(width: 64, height: 64, value: 40)
        let fourth = try makePixelBuffer(width: 64, height: 64, value: 60)

        XCTAssertEqual(pipeline.encodeFrame(pixelBuffer: first), .submitted)
        XCTAssertEqual(writes.count, setupWriteCount + 3)
        XCTAssertEqual(pipeline.encodeFrame(pixelBuffer: second), .submitted)
        XCTAssertEqual(writes.count, setupWriteCount + 6)
        XCTAssertEqual(pipeline.encodeFrame(pixelBuffer: third), .blocked)
        XCTAssertEqual(writes.count, setupWriteCount + 6)

        pipeline.handleClientPDU(frameAck(frameId: 1))
        XCTAssertEqual(pipeline.encodeFrame(pixelBuffer: third), .submitted)
        XCTAssertEqual(writes.count, setupWriteCount + 9)

        pipeline.handleClientPDU(frameAck(frameId: 2))
        XCTAssertEqual(pipeline.encodeFrame(pixelBuffer: fourth), .submitted)
        XCTAssertEqual(writes.count, setupWriteCount + 12)

        let wire = unwrap(writes[writes.count - 2])
        XCTAssertEqual(readU16(wire, at: 0), 0x0001)
        let bitstream = Array(wire[39..<wire.count])
        XCTAssertTrue(containsAnnexBNAL(type: 1, in: bitstream))
        XCTAssertFalse(containsAnnexBNAL(type: 5, in: bitstream))
        XCTAssertFalse(containsAnnexBNAL(type: 7, in: bitstream))
        XCTAssertFalse(containsAnnexBNAL(type: 8, in: bitstream))
    }

    func testInitialWindowDoesNotUseAdvertisedCeiling() throws {
        let pipeline = GFXPipeline()
        pipeline.configureFrameAcknowledgement(maxUnacknowledgedFrameCount: 8)
        pipeline.setAudioLowLatencyMode(true)
        attach(pipeline) { _ in }
        pipeline.asyncEncoding = false
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        XCTAssertEqual(pipeline.currentFrameAcknowledgementWindow, 2)

        for value: UInt8 in [0, 20] {
            XCTAssertEqual(
                pipeline.encodeFrame(pixelBuffer: try makePixelBuffer(width: 64, height: 64, value: value)),
                .submitted
            )
        }
        XCTAssertEqual(
            pipeline.encodeFrame(pixelBuffer: try makePixelBuffer(width: 64, height: 64, value: 40)),
            .blocked
        )
    }

    func testControllerAudioTightensGraphicsWindowWhenQueueIsPressured() throws {
        let pipeline = GFXPipeline()
        pipeline.configureFrameAcknowledgement(maxUnacknowledgedFrameCount: 8)
        pipeline.setAudioLowLatencyMode(true)
        pipeline.setAudioQueuePressure(true)
        attach(pipeline) { _ in }
        pipeline.asyncEncoding = false
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        XCTAssertEqual(pipeline.currentFrameAcknowledgementWindow, 2)

        XCTAssertEqual(
            pipeline.encodeFrame(pixelBuffer: try makePixelBuffer(width: 64, height: 64, value: 0)),
            .submitted
        )
        XCTAssertEqual(
            pipeline.encodeFrame(pixelBuffer: try makePixelBuffer(width: 64, height: 64, value: 20)),
            .submitted
        )
        XCTAssertEqual(
            pipeline.encodeFrame(pixelBuffer: try makePixelBuffer(width: 64, height: 64, value: 40)),
            .blocked
        )

        pipeline.handleClientPDU(frameAck(frameId: 1))
        XCTAssertEqual(
            pipeline.encodeFrame(pixelBuffer: try makePixelBuffer(width: 64, height: 64, value: 40)),
            .submitted
        )
    }

    func testSteadyStateWaitsForFrameAckBeforeNextFrame() throws {
        let pipeline = GFXPipeline()
        var writes: [[UInt8]] = []
        pipeline.configureFrameAcknowledgement(maxUnacknowledgedFrameCount: 1)
        attach(pipeline) { writes.append($0) }
        pipeline.asyncEncoding = false
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        let setupWriteCount = writes.count
        let first = try makePixelBuffer(width: 64, height: 64, value: 0)
        let second = try makePixelBuffer(width: 64, height: 64, value: 20)
        let third = try makePixelBuffer(width: 64, height: 64, value: 40)

        XCTAssertEqual(pipeline.encodeFrame(pixelBuffer: first), .submitted)
        pipeline.handleClientPDU(frameAck(frameId: 1))
        XCTAssertEqual(pipeline.encodeFrame(pixelBuffer: second), .submitted)
        XCTAssertEqual(writes.count, setupWriteCount + 6)

        XCTAssertEqual(pipeline.encodeFrame(pixelBuffer: third), .blocked)
        XCTAssertEqual(
            writes.count,
            setupWriteCount + 6,
            "an unacknowledged steady-state frame must hold the next encode"
        )

        pipeline.handleClientPDU(frameAck(frameId: 2))
        XCTAssertEqual(pipeline.encodeFrame(pixelBuffer: third), .submitted)
        XCTAssertEqual(writes.count, setupWriteCount + 9)
    }

    func testMeasuredWindowStaysWithinAdvertisedCeiling() throws {
        let pipeline = GFXPipeline()
        pipeline.configureFrameAcknowledgement(maxUnacknowledgedFrameCount: 8)
        attach(pipeline) { _ in }
        pipeline.attachController(VideoTargetController(bitrate: 12_500_000, fps: 30))
        pipeline.asyncEncoding = false
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        XCTAssertGreaterThanOrEqual(pipeline.currentFrameAcknowledgementWindow, 1)
        XCTAssertLessThanOrEqual(pipeline.currentFrameAcknowledgementWindow, 8)
    }

    func testQoEFeedbackDoesNotAcknowledgeGraphicsFrames() throws {
        let pipeline = GFXPipeline()
        pipeline.configureFrameAcknowledgement(maxUnacknowledgedFrameCount: 1)
        attach(pipeline) { _ in }
        pipeline.asyncEncoding = false
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        pipeline.encodeFrame(pixelBuffer: try makePixelBuffer(width: 64, height: 64))
        XCTAssertEqual(pipeline.unackedFrameCount, 1)

        pipeline.handleClientPDU(qoeFrameAck(frameId: 1, commandDecodeMs: 4, renderMs: 6))
        XCTAssertEqual(pipeline.unackedFrameCount, 1)
        pipeline.handleClientPDU(frameAck(frameId: 1))
        XCTAssertEqual(pipeline.unackedFrameCount, 0)
    }

    func testFrameAckQueueMapsUnavailableAndQueuedStates() throws {
        let pipeline = GFXPipeline()
        let controller = VideoTargetController(bitrate: 8_000_000, fps: 30)
        attach(pipeline) { _ in }
        pipeline.attachController(controller)
        pipeline.asyncEncoding = false
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        let buffer = try makePixelBuffer(width: 64, height: 64)

        XCTAssertEqual(pipeline.encodeFrame(pixelBuffer: buffer), .submitted)
        pipeline.handleClientPDU(frameAck(frameId: 1, clientQueueBytes: 0))
        XCTAssertEqual(controller.clientQueueFeedback, .unavailable)

        XCTAssertEqual(pipeline.encodeFrame(pixelBuffer: buffer), .submitted)
        pipeline.handleClientPDU(frameAck(frameId: 2, clientQueueBytes: 12_345))
        XCTAssertEqual(controller.clientQueueFeedback, .queued(bytes: 12_345))
    }

    func testTCPSendStallOnlyPausesEncode() {
        let pipeline = GFXPipeline()
        attach(pipeline) { _ in }
        pipeline.attachController(VideoTargetController(bitrate: 12_500_000, fps: 30))
        defer { pipeline.stop() }

        pipeline.setSendBlocked(true)
        XCTAssertEqual(
            pipeline.encodeFrame(pixelBuffer: try! makePixelBuffer(width: 64, height: 64)),
            .blocked
        )
        pipeline.setSendBlocked(false)
        XCTAssertFalse(pipeline.isAckWindowFull)
    }

    func testSuspendFrameAcknowledgementsClearsWindowAndAllowsContinuousOutput() throws {
        let pipeline = GFXPipeline()
        let controller = VideoTargetController(bitrate: 20_000_000, fps: 60)
        var writes: [[UInt8]] = []
        pipeline.attachController(controller)
        attach(pipeline) { writes.append($0) }
        pipeline.asyncEncoding = false
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        let setupWriteCount = writes.count
        let first = try makePixelBuffer(width: 64, height: 64, value: 0)

        pipeline.encodeFrame(pixelBuffer: first)
        XCTAssertEqual(writes.count, setupWriteCount + 3)

        pipeline.handleClientPDU(frameAck(frameId: 1, clientQueueBytes: UInt32.max))
        XCTAssertTrue(pipeline.isFrameAcknowledgementSuspended)
        XCTAssertFalse(controller.stallRecoveryMode)
        XCTAssertEqual(controller.targetFPS, 60)
        XCTAssertEqual(controller.targetBitrate, 20_000_000)

        for value: UInt8 in [20, 40, 60] {
            pipeline.encodeFrame(
                pixelBuffer: try makePixelBuffer(width: 64, height: 64, value: value)
            )
        }
        XCTAssertEqual(writes.count, setupWriteCount + 12)

        pipeline.handleClientPDU(frameAck(frameId: 4, clientQueueBytes: 0))
        XCTAssertFalse(pipeline.isFrameAcknowledgementSuspended)
        pipeline.encodeFrame(
            pixelBuffer: try makePixelBuffer(width: 64, height: 64, value: 80)
        )
        XCTAssertEqual(writes.count, setupWriteCount + 15)
    }

    func testResizeRejectsOldAckAndBootstrapsWithNewIDR() throws {
        let pipeline = GFXPipeline()
        var writes: [[UInt8]] = []
        pipeline.configureFrameAcknowledgement(maxUnacknowledgedFrameCount: 1)
        attach(pipeline) { writes.append($0) }
        pipeline.asyncEncoding = false
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        pipeline.encodeFrame(pixelBuffer: try makePixelBuffer(width: 64, height: 64))
        XCTAssertEqual(readU32(unwrap(writes[writes.count - 3]), at: 12), 1)

        let resizeStart = writes.count
        try pipeline.start(width: 80, height: 66)
        XCTAssertEqual(
            writes[resizeStart...].map(unwrap).map { readU16($0, at: 0) },
            [0x000E, 0x0009, 0x000F]
        )
        let create = unwrap(writes[resizeStart + 1])
        // AVC420 codes exactly the visible surface — no padding, no VT rescale.
        XCTAssertEqual(readU16(create, at: 10), 80)
        XCTAssertEqual(readU16(create, at: 12), 66)
        XCTAssertEqual(pipeline.h264.visibleWidth, 80)
        XCTAssertEqual(pipeline.h264.visibleHeight, 66)
        XCTAssertEqual(pipeline.h264.width, 80)
        XCTAssertEqual(pipeline.h264.height, 66)

        let resizedBuffer = try makePixelBuffer(width: 80, height: 66, value: 0)
        let changedResizedBuffer = try makePixelBuffer(width: 80, height: 66, value: 40)
        pipeline.encodeFrame(pixelBuffer: resizedBuffer)
        let firstResizeStart = unwrap(writes[writes.count - 3])
        let firstResizeWire = unwrap(writes[writes.count - 2])
        XCTAssertEqual(readU16(firstResizeStart, at: 0), 0x000B)
        XCTAssertEqual(readU32(firstResizeStart, at: 12), 2)
        XCTAssertEqual(readU16(firstResizeWire, at: 0), 0x0001)
        XCTAssertTrue(containsAnnexBNAL(type: 5, in: firstResizeWire))
        let firstResizeWriteCount = writes.count

        pipeline.handleClientPDU(frameAck(frameId: 1))
        XCTAssertEqual(pipeline.encodeFrame(pixelBuffer: changedResizedBuffer), .blocked)
        XCTAssertEqual(writes.count, firstResizeWriteCount)

        pipeline.handleClientPDU(frameAck(frameId: 2))
        XCTAssertEqual(pipeline.encodeFrame(pixelBuffer: changedResizedBuffer), .submitted)
        XCTAssertEqual(writes.count, firstResizeWriteCount + 3)
    }

    func testOutputResumeRebuildsSurfaceAndBootstrapsWithNewIDR() throws {
        let pipeline = GFXPipeline()
        var writes: [[UInt8]] = []
        attach(pipeline) { writes.append($0) }
        pipeline.asyncEncoding = false
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        let buffer = try makePixelBuffer(width: 64, height: 64, value: 20)
        XCTAssertEqual(pipeline.encodeFrame(pixelBuffer: buffer), .submitted)
        pipeline.handleClientPDU(frameAck(frameId: 1))

        pipeline.pauseSending()
        let rebuildStart = writes.count
        try pipeline.start(width: 64, height: 64)

        XCTAssertFalse(pipeline.isSendPaused)
        XCTAssertEqual(
            writes[rebuildStart...].map(unwrap).map { readU16($0, at: 0) },
            [0x000E, 0x0009, 0x000F]
        )
        XCTAssertEqual(pipeline.encodeFrame(pixelBuffer: buffer), .submitted)

        let start = unwrap(writes[writes.count - 3])
        let wire = unwrap(writes[writes.count - 2])
        XCTAssertEqual(readU32(start, at: 12), 2)
        XCTAssertTrue(containsAnnexBNAL(type: 5, in: wire))
        XCTAssertEqual(readU32(wire, at: 25), 1)
        XCTAssertEqual(readU16(wire, at: 29), 0)
        XCTAssertEqual(readU16(wire, at: 31), 0)
        XCTAssertEqual(readU16(wire, at: 33), 64)
        XCTAssertEqual(readU16(wire, at: 35), 64)
    }

    func testRepeatedCapsResetsProtocolWithoutDeletingClientState() throws {
        let pipeline = GFXPipeline()
        var writes: [[UInt8]] = []
        attach(pipeline) { writes.append($0) }
        pipeline.asyncEncoding = false
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        let buffer = try makePixelBuffer(width: 64, height: 64)
        pipeline.encodeFrame(pixelBuffer: buffer)
        pipeline.handleClientPDU(frameAck(frameId: 1, clientQueueBytes: UInt32.max))
        XCTAssertTrue(pipeline.isFrameAcknowledgementSuspended)

        let renegotiationStart = writes.count
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        XCTAssertEqual(
            writes[renegotiationStart...].map(unwrap).map { readU16($0, at: 0) },
            [0x0013, 0x000E, 0x0009, 0x000F]
        )
        XCTAssertFalse(pipeline.isFrameAcknowledgementSuspended)

        pipeline.encodeFrame(pixelBuffer: buffer)
        let start = unwrap(writes[writes.count - 3])
        let wire = unwrap(writes[writes.count - 2])
        XCTAssertEqual(readU16(start, at: 0), 0x000B)
        XCTAssertEqual(readU32(start, at: 12), 2, "frame IDs remain unique across a protocol reset")
        XCTAssertEqual(readU16(wire, at: 0), 0x0001)
        XCTAssertTrue(containsAnnexBNAL(type: 5, in: wire))
    }

    func testSelectsHighestKnownRDP10Capability() throws {
        let pipeline = GFXPipeline()
        attach(pipeline) { _ in }
        pipeline.asyncEncoding = false
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(sets: [
            (0x000A_0400, 0),
            (0x000A_0600, 0),
            (0x000A_0502, 0),
            (0x000A_0200, 0),
        ]))

        XCTAssertEqual(pipeline.selectedCapVersion, 0x000A_0600)
        XCTAssertEqual(pipeline.encodingLabel, "H.264 AVC420")
    }

    func testVersion101CapsConfirmUsesSixteenReservedBytes() {
        let pipeline = GFXPipeline()
        let pdu = pipeline.buildCapsConfirm(version: 0x000A_0100, flags: 0xFFFF_FFFF)

        XCTAssertEqual(readU32(pdu, at: 4), 32)
        XCTAssertEqual(readU32(pdu, at: 8), 0x000A_0100)
        XCTAssertEqual(readU32(pdu, at: 12), 16)
        XCTAssertEqual(Array(pdu[16..<32]), [UInt8](repeating: 0, count: 16))
    }

    func testSelectsHighestKnownCapabilityWhenUnknownVersionIsAdvertised() throws {
        let pipeline = GFXPipeline()
        attach(pipeline) { _ in }
        pipeline.asyncEncoding = false
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(sets: [
            (0x000A_0002, 0),
            (0x000A_0200, 0),
            (0x000A_0600, 0),
            (0x000B_0101, 0),
        ]))

        // Unknown capability versions are ignored; choose the highest known set.
        XCTAssertEqual(pipeline.selectedCapVersion, 0x000A_0600)
        XCTAssertEqual(pipeline.encodingLabel, "H.264 AVC420")
    }

    func testH264UsesProgressiveWhenHighestSelectedCapabilityDisablesAVC() throws {
        let pipeline = GFXPipeline()
        var writes: [[UInt8]] = []
        attach(pipeline) { writes.append($0) }
        pipeline.asyncEncoding = false
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(sets: [
            (0x0008_0105, 0x0000_0002),
            (0x0008_0004, 0x0000_0002),
            (0x000A_0002, 0x0000_0022),
            (0x000A_0200, 0x0000_0022),
            (0x000A_0301, 0x0000_0020),
            (0x000A_0400, 0x0000_0022),
            (0x000B_0101, 0x0000_01A2),
        ]))

        XCTAssertTrue(pipeline.activeCodec.isProgressive)
        XCTAssertEqual(pipeline.selectedCapVersion, 0x000A_0400)
        XCTAssertEqual(pipeline.selectedCapFlags, 0x0000_0022)
        XCTAssertEqual(pipeline.encodingLabel, "RemoteFX Progressive")
        XCTAssertEqual(writes.map(unwrap).map { readU16($0, at: 0) }, [
            0x0013, 0x000E, 0x0009, 0x000F,
        ])
    }

    func testSelectedCapabilityFlagsOverrideLowerAVCCapability() throws {
        let pipeline = GFXPipeline()
        var writes: [[UInt8]] = []
        attach(pipeline) { writes.append($0) }
        pipeline.asyncEncoding = false
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(sets: [
            (0x000A_0200, 0),
            (0x000A_0400, 0x0000_0020),
        ]))

        XCTAssertTrue(pipeline.activeCodec.isProgressive)
        XCTAssertEqual(pipeline.selectedCapVersion, 0x000A_0400)
        XCTAssertEqual(pipeline.selectedCapFlags, 0x0000_0020)
        let confirm = try XCTUnwrap(writes.map(unwrap).first { readU16($0, at: 0) == 0x0013 })
        XCTAssertEqual(readU32(confirm, at: 8), 0x000A_0400)
        XCTAssertEqual(readU32(confirm, at: 12), 4)
        XCTAssertEqual(readU32(confirm, at: 16), 0x0000_0020)
    }

    func testThinClientCapabilityWithoutClassicRemoteFXNotifiesCapabilityFailure() throws {
        let pipeline = GFXPipeline()
        attach(pipeline) { _ in }
        pipeline.asyncEncoding = false
        let failure = expectation(description: "GFX capability rejection")
        pipeline.onCapabilityFailure = { failure.fulfill() }
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x0008_0105, flags: 0x01))

        wait(for: [failure], timeout: 1)
        XCTAssertEqual(pipeline.selectedCapVersion, 0)
        XCTAssertEqual(pipeline.encodingLabel, "H.264 AVC420")
    }

    func testDuplicateCapabilitySetIsRejected() throws {
        let pipeline = GFXPipeline()
        attach(pipeline) { _ in }
        let failure = expectation(description: "duplicate capability rejection")
        pipeline.onCapabilityFailure = { failure.fulfill() }
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(sets: [
            (0x000A_0400, 0),
            (0x000A_0400, 0),
        ]))

        wait(for: [failure], timeout: 1)
        XCTAssertEqual(pipeline.selectedCapVersion, 0)
    }

    func testCapabilitySetLengthMustMatchKnownLayout() throws {
        let pipeline = GFXPipeline()
        attach(pipeline) { _ in }
        let failure = expectation(description: "capability length rejection")
        pipeline.onCapabilityFailure = { failure.fulfill() }
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertiseRaw(sets: [
            (0x000A_0400, [0, 0, 0, 0, 0]),
        ]))

        wait(for: [failure], timeout: 1)
        XCTAssertEqual(pipeline.selectedCapVersion, 0)
    }

    func testVersion101ReservedBytesMustBeZero() throws {
        let pipeline = GFXPipeline()
        attach(pipeline) { _ in }
        let failure = expectation(description: "version 10.1 reserved bytes rejection")
        pipeline.onCapabilityFailure = { failure.fulfill() }
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        var reserved = [UInt8](repeating: 0, count: 16)
        reserved[0] = 1
        pipeline.handleClientPDU(capsAdvertiseRaw(sets: [
            (0x000A_0100, reserved),
        ]))

        wait(for: [failure], timeout: 1)
        XCTAssertEqual(pipeline.selectedCapVersion, 0)
    }

    func testAVC420MetadataCropsPaddedBitstreamToLogicalRegion() {
        let stream = GFXPipeline.buildAVC420BitmapStream(
            regions: [(0, 0, 1920, 1080)],
            quality: 100,
            h264AnnexB: [0, 0, 0, 1, 0x65]
        )

        XCTAssertEqual(Array(stream.prefix(4)), [1, 0, 0, 0])
        XCTAssertEqual(Array(stream[4..<12]), [0, 0, 0, 0, 128, 7, 56, 4])
        XCTAssertEqual(Array(stream[12..<14]), [22, 100])
        XCTAssertEqual(Array(stream[14...]), [0, 0, 0, 1, 0x65]) // length-prefixed single NAL
    }

    func testAVC420MetadataDoesNotConfuseH264PFramesWithProgressiveRegions() {
        let stream = GFXPipeline.buildAVC420BitmapStream(
            regions: [(0, 0, 64, 64)],
            quality: 100,
            h264AnnexB: [0, 0, 0, 1, 0x41]
        )

        XCTAssertEqual(Array(stream[12..<14]), [22, 100])
    }

    func testAVC420MetadataBuilderRejectsEmptyRegions() {
        let avc420 = GFXPipeline.buildAVC420BitmapStream(
            regions: [],
            quality: 100,
            h264AnnexB: [0, 0, 0, 1, 0x65]
        )
        XCTAssertTrue(avc420.isEmpty)

        let degenerate = GFXPipeline.buildAVC420BitmapStream(
            regions: [(0, 0, 0, 64)],
            quality: 100,
            h264AnnexB: [0, 0, 0, 1, 0x65]
        )
        XCTAssertTrue(degenerate.isEmpty)

    }

    func testBootstrapIDRAdvertisesWholeSurfaceRegion() throws {
        let pipeline = GFXPipeline()
        var writes: [[UInt8]] = []
        attach(pipeline) { writes.append($0) }
        pipeline.asyncEncoding = false
        defer { pipeline.stop() }

        try pipeline.start(width: 128, height: 128)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        let setupWriteCount = writes.count
        let buffer = try makePixelBuffer(width: 128, height: 128)

        XCTAssertEqual(pipeline.encodeFrame(pixelBuffer: buffer), .submitted)

        let wire = try wirePDU(in: writes, after: setupWriteCount)
        // Destination rect is the whole surface...
        XCTAssertEqual(readU16(wire, at: 13), 0)
        XCTAssertEqual(readU16(wire, at: 15), 0)
        XCTAssertEqual(readU16(wire, at: 17), 128)
        XCTAssertEqual(readU16(wire, at: 19), 128)
        // A complete IDR uses one exclusive full-surface metadata rectangle.
        XCTAssertEqual(readU32(wire, at: 25), 1)
        XCTAssertEqual(readU16(wire, at: 29), 0)
        XCTAssertEqual(readU16(wire, at: 31), 0)
        XCTAssertEqual(readU16(wire, at: 33), 128)
        XCTAssertEqual(readU16(wire, at: 35), 128)
    }

    func testLetterboxedBootstrapIDRUsesFullOutputSurface() throws {
        let pipeline = GFXPipeline()
        var writes: [[UInt8]] = []
        attach(pipeline) { writes.append($0) }
        pipeline.asyncEncoding = false
        defer { pipeline.stop() }

        try pipeline.start(width: 256, height: 256)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        let setupWriteCount = writes.count
        let source = try makePixelBuffer(width: 128, height: 64, value: 0)

        XCTAssertEqual(pipeline.encodeFrame(pixelBuffer: source), .submitted)

        let wire = try wirePDU(in: writes, after: setupWriteCount)
        XCTAssertEqual(readU16(wire, at: 13), 0)
        XCTAssertEqual(readU16(wire, at: 15), 0)
        XCTAssertEqual(readU16(wire, at: 17), 256)
        XCTAssertEqual(readU16(wire, at: 19), 256)
        XCTAssertEqual(readU32(wire, at: 25), 1)
        // The source is letterboxed inside the output; an IDR still declares
        // the complete output surface as its replacement region.
        XCTAssertEqual(readU16(wire, at: 29), 0)
        XCTAssertEqual(readU16(wire, at: 31), 0)
        XCTAssertEqual(readU16(wire, at: 33), 256)
        XCTAssertEqual(readU16(wire, at: 35), 256)
    }

    /// Collects pipeline writes from any thread (async delivery queue).
    private final class WriteCollector {
        private let lock = NSLock()
        private var writes: [[UInt8]] = []

        func append(_ write: [UInt8]) {
            lock.lock()
            writes.append(write)
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return writes.count
        }

        var snapshot: [[UInt8]] {
            lock.lock()
            defer { lock.unlock() }
            return writes
        }
    }

    private func waitForWrites(
        _ collector: WriteCollector,
        count: Int,
        timeout: TimeInterval = 2.0
    ) throws -> [[UInt8]] {
        let deadline = Date().addingTimeInterval(timeout)
        while collector.count < count, Date() < deadline {
            usleep(2000)
        }
        let writes = collector.snapshot
        XCTAssertGreaterThanOrEqual(writes.count, count)
        return writes
    }

    private func capsAdvertise(version: UInt32, flags: UInt32 = 0) -> [UInt8] {
        capsAdvertise(sets: [(version, flags)])
    }

    private func capsAdvertise(sets: [(UInt32, UInt32)]) -> [UInt8] {
        capsAdvertiseRaw(sets: sets.map { ($0.0, [
            UInt8($0.1 & 0xFF),
            UInt8(($0.1 >> 8) & 0xFF),
            UInt8(($0.1 >> 16) & 0xFF),
            UInt8(($0.1 >> 24) & 0xFF),
        ]) })
    }

    private func capsAdvertiseRaw(sets: [(UInt32, [UInt8])]) -> [UInt8] {
        var bytes: [UInt8] = [0x12, 0x00, 0x00, 0x00]
        let pduLength = 10 + sets.reduce(0) { $0 + 8 + $1.1.count }
        appendU32(UInt32(pduLength), to: &bytes)
        bytes.append(UInt8(sets.count & 0xFF))
        bytes.append(UInt8((sets.count >> 8) & 0xFF))
        for (version, data) in sets {
            appendU32(version, to: &bytes)
            appendU32(UInt32(data.count), to: &bytes)
            bytes.append(contentsOf: data)
        }
        return bytes
    }

    private func frameAck(frameId: UInt32, clientQueueBytes: UInt32 = 0) -> [UInt8] {
        var bytes: [UInt8] = [0x0D, 0x00, 0x00, 0x00]
        appendU32(20, to: &bytes)
        appendU32(clientQueueBytes, to: &bytes)
        appendU32(frameId, to: &bytes)
        appendU32(frameId, to: &bytes)
        return bytes
    }

    private func qoeFrameAck(frameId: UInt32, commandDecodeMs: UInt16, renderMs: UInt16) -> [UInt8] {
        var bytes: [UInt8] = [0x16, 0x00, 0x00, 0x00]
        appendU32(20, to: &bytes)
        appendU32(frameId, to: &bytes)
        appendU32(0, to: &bytes)
        bytes.append(UInt8(commandDecodeMs & 0xFF))
        bytes.append(UInt8(commandDecodeMs >> 8))
        bytes.append(UInt8(renderMs & 0xFF))
        bytes.append(UInt8(renderMs >> 8))
        return bytes
    }

    private func makePixelBuffer(
        width: Int,
        height: Int,
        value: UInt8 = 0
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                nil,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let pixels = base.advanced(by: row * stride)
            for column in 0..<width {
                let offset = column * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = 255
            }
        }
        return buffer
    }

    private func setBGRA(
        _ buffer: CVPixelBuffer,
        x: Int,
        y: Int,
        b: UInt8,
        g: UInt8,
        r: UInt8
    ) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        base[offset] = b
        base[offset + 1] = g
        base[offset + 2] = r
        base[offset + 3] = 255
    }

    private func makeNV12PixelBuffer(
        width: Int,
        height: Int,
        y: UInt8 = 16,
        u: UInt8 = 128,
        v: UInt8 = 128
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        // IOSurface-backed so VideoToolbox takes it on the AVC420 fallback path.
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let yBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
            .assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<height {
            let samples = yBase.advanced(by: row * yStride)
            for column in 0..<width { samples[column] = y }
        }
        let uvBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
            .assumingMemoryBound(to: UInt8.self)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0..<(height / 2) {
            let samples = uvBase.advanced(by: row * uvStride)
            for column in stride(from: 0, to: width, by: 2) {
                samples[column] = u
                samples[column + 1] = v
            }
        }
        return buffer
    }

    private func unwrap(_ bytes: [UInt8]) -> [UInt8] {
        XCTAssertGreaterThanOrEqual(bytes.count, 2)
        guard let decoded = zgfxDecoder.decompress(bytes) else {
            XCTFail("expected valid ZGFX framed data")
            return []
        }
        return decoded
    }

    /// WireToSurface1 PDU among writes appended after setup (cmdId 0x0001 at offset 0).
    private func wirePDU(in writes: [[UInt8]], after setupWriteCount: Int) throws -> [UInt8] {
        for write in writes[setupWriteCount...] {
            let pdu = unwrap(write)
            if readU16(pdu, at: 0) == 0x0001 {
                return pdu
            }
        }
        XCTFail("expected WireToSurface1 after setup write \(setupWriteCount)")
        return []
    }

    private func containsAnnexBNAL(type: UInt8, in bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else { return false }
        var index = 0
        while index + 3 < bytes.count {
            let nalOffset: Int?
            if index + 4 <= bytes.count,
               bytes[index] == 0, bytes[index + 1] == 0,
               bytes[index + 2] == 0, bytes[index + 3] == 1 {
                nalOffset = index + 4
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                nalOffset = index + 3
            } else {
                nalOffset = nil
            }
            if let nalOffset, nalOffset < bytes.count, bytes[nalOffset] & 0x1F == type {
                return true
            }
            index += 1
        }
        return false
    }

    private func appendU32(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 24) & 0xFF))
    }

    private func readU16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private func readU32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) |
            UInt32(bytes[offset + 1]) << 8 |
            UInt32(bytes[offset + 2]) << 16 |
            UInt32(bytes[offset + 3]) << 24
    }
}
