import CoreGraphics
import CoreVideo
import XCTest
@testable import SwiftRDPCore

final class GFXPipelineTests: XCTestCase {
    func testPipelineStateChangesAreDeliveredAfterSetupAndStop() throws {
        let pipeline = GFXPipeline()
        defer { pipeline.onStateChanged = nil; pipeline.stop() }
        attach(pipeline) { _ in }
        let ready = expectation(description: "Graphics ready")
        pipeline.onStateChanged = {
            XCTAssertTrue(pipeline.isPipelineReady)
            ready.fulfill()
        }
        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        wait(for: [ready], timeout: 2)

        let stopped = expectation(description: "Graphics stopped")
        pipeline.onStateChanged = {
            XCTAssertFalse(pipeline.isPipelineReady)
            stopped.fulfill()
        }
        pipeline.stop()
        wait(for: [stopped], timeout: 2)
    }

    private let zgfxDecoder = ZGFXCompressor()
    private var captureSequence: UInt64 = 0

    private func nextCaptureSequence() -> UInt64 {
        captureSequence += 1
        return captureSequence
    }

    func testAsyncCompletedFrameWaitsForCreditThenDrainsOnACK() throws {
        let pipeline = GFXPipeline()
        pipeline.configureFrameAcknowledgement(maxUnacknowledgedFrameCount: 2)
        let gateEntered = DispatchSemaphore(value: 0)
        let releaseGate = DispatchSemaphore(value: 0)
        let writesLock = NSLock()
        var videos = 0
        var gateNextVideo = false
        pipeline.attach(transport: RDPGFXDynamicChannelTransport { pdus, priority, written in
            writesLock.lock()
            let gated = priority == .video && gateNextVideo
            if priority == .video { videos += 1 }
            if gated { gateNextVideo = false }
            writesLock.unlock()
            if gated {
                gateEntered.signal()
                _ = releaseGate.wait(timeout: .now() + 3)
            }
            written?(DispatchTime.now().uptimeNanoseconds)
            return pdus.reduce(0) { $0 + $1.count }
        })
        defer { releaseGate.signal(); pipeline.stop() }
        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: try makePixelBuffer(width: 64, height: 64)), .submitted)
        pipeline.handleClientPDU(frameAck(frameId: 1))
        writesLock.lock(); gateNextVideo = true; writesLock.unlock()
        XCTAssertEqual(pipeline.encodeFrame(pixelBuffer: try makePixelBuffer(width: 64, height: 64, value: 20),
            captureSequence: nextCaptureSequence()), .submitted)
        XCTAssertEqual(gateEntered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(pipeline.encodeFrame(pixelBuffer: try makePixelBuffer(width: 64, height: 64, value: 40),
            captureSequence: nextCaptureSequence()), .submitted)
        // A negotiated/live window can tighten while the second picture is encoding.
        pipeline.configureFrameAcknowledgement(maxUnacknowledgedFrameCount: 1)
        XCTAssertEqual(pipeline.currentFrameAcknowledgementWindow, 1)
        releaseGate.signal()
        let queued = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            pipeline.queuedEncodedFrameCount == 1
        }, object: nil)
        wait(for: [queued], timeout: 2)
        XCTAssertEqual(pipeline.unackedFrameCount, 1)
        writesLock.lock(); let beforeACK = videos; writesLock.unlock()
        XCTAssertEqual(beforeACK, 2)
        pipeline.handleClientPDU(frameAck(frameId: 2))
        XCTAssertEqual(pipeline.queuedEncodedFrameCount, 0)
        XCTAssertEqual(pipeline.unackedFrameCount, 1)
        writesLock.lock(); let afterACK = videos; writesLock.unlock()
        XCTAssertEqual(afterACK, 3)
    }

    func testFutureACKCannotClearTrackedFrames() throws {
        let pipeline = GFXPipeline()
        attach(pipeline) { _ in }
        defer { pipeline.stop() }
        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: try makePixelBuffer(width: 64, height: 64)), .submitted)
        pipeline.handleClientPDU(frameAck(frameId: 2))
        XCTAssertEqual(pipeline.unackedFrameCount, 1)
        pipeline.handleClientPDU(frameAck(frameId: 1))
        XCTAssertEqual(pipeline.unackedFrameCount, 0)
    }

    func testOnlyTrackedACKExitsStallRecovery() throws {
        let pipeline = GFXPipeline()
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        pipeline.attachController(controller)
        attach(pipeline) { _ in }
        defer { pipeline.stop() }
        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        _ = controller.noteBackpressureTimeout(unackedWas: 2)
        _ = controller.noteBackpressureTimeout(unackedWas: 2)
        pipeline.handleClientPDU(frameAck(frameId: 0))
        XCTAssertTrue(controller.stallRecoveryMode)
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: try makePixelBuffer(width: 64, height: 64)), .submitted)
        pipeline.handleClientPDU(frameAck(frameId: 1))
        XCTAssertFalse(controller.stallRecoveryMode)
    }

    func testQoECommandIntervalDoesNotBecomeDecoderPressure() throws {
        let pipeline = GFXPipeline()
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        pipeline.attachController(controller)
        attach(pipeline) { _ in }
        defer { pipeline.stop() }
        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: try makePixelBuffer(width: 64, height: 64)), .submitted)
        pipeline.handleClientPDU(qoeFrameAck(frameId: 1, commandDecodeMs: 2000, renderMs: 10))
        XCTAssertEqual(controller.performanceSnapshot().clientRenderMs, 10)
        XCTAssertEqual(controller.performanceSnapshot().clientPressure, 0)
        XCTAssertEqual(controller.targetFPS, 60)
        pipeline.handleClientPDU(qoeFrameAck(frameId: 2, commandDecodeMs: 0, renderMs: 5000))
        XCTAssertEqual(controller.performanceSnapshot().clientRenderMs, 10)
    }

    private func attach(
        _ pipeline: GFXPipeline,
        send: @escaping ([UInt8]) -> Void
    ) {
        pipeline.attach(
            transport: RDPGFXDynamicChannelTransport { pdus, _, onWritten in
                for pdu in pdus { send(pdu) }
                onWritten?(DispatchTime.now().uptimeNanoseconds)
                return pdus.reduce(0) { $0 + $1.count }
            }
        )
    }

    @discardableResult
    private func encodeFrameAndWait(
        _ pipeline: GFXPipeline,
        pixelBuffer: CVPixelBuffer,
        sequence: UInt64? = nil
    ) -> GFXPipeline.FrameSubmission {
        let completed = DispatchSemaphore(value: 0)
        let previous = pipeline.onWorkAvailable
        pipeline.onWorkAvailable = { previous?(); completed.signal() }
        defer { pipeline.onWorkAvailable = previous }
        let result = pipeline.encodeFrame(pixelBuffer: pixelBuffer,
            captureSequence: sequence ?? nextCaptureSequence())
        if result == .submitted {
            let deadline = DispatchTime.now() + 2
            while pipeline.hasPendingEncode {
                guard completed.wait(timeout: deadline) == .success else {
                    XCTFail("Graphics output did not complete")
                    break
                }
            }
        }
        return result
    }

    func testRejectedFinalFrameRetriesTheSameCaptureWithAFreshReference() throws {
        let pipeline = GFXPipeline()
        let collector = WriteCollector()
        var rejectNextVideo = false
        let lock = NSLock()
        pipeline.attach(transport: RDPGFXDynamicChannelTransport { pdus, priority, written in
            if lock.withLock({ () -> Bool in
                guard priority == .video, rejectNextVideo else { return false }
                rejectNextVideo = false
                return true
            }) { return nil }
            for pdu in pdus { collector.append(pdu) }
            written?(DispatchTime.now().uptimeNanoseconds)
            return pdus.reduce(0) { $0 + $1.count }
        })
        defer { pipeline.stop() }
        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        let setup = collector.count
        let decoder = H264TestDecoder()
        XCTAssertEqual(encodeFrameAndWait(pipeline,
            pixelBuffer: try makePixelBuffer(width: 64, height: 64), sequence: 1), .submitted)
        let firstWire = try wirePDU(in: collector.snapshot, after: setup)
        _ = try decoder.decode(Array(firstWire.dropFirst(39)))
        pipeline.handleClientPDU(frameAck(frameId: 1))
        let final = try makePixelBuffer(width: 64, height: 64, value: 200)
        let beforeRejection = collector.count
        lock.withLock { rejectNextVideo = true }
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: final, sequence: 2), .submitted)
        XCTAssertEqual(collector.count, beforeRejection)
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: final, sequence: 2), .submitted)
        let retryWire = try wirePDU(in: collector.snapshot, after: beforeRejection)
        XCTAssertTrue(containsAnnexBNAL(type: 5, in: retryWire))
        let decoded = try decoder.decode(Array(retryWire.dropFirst(39)))
        XCTAssertGreaterThan(firstLuma(decoded), 150)
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: final, sequence: 2), .blocked)
    }

    func testQuietCaptureAttemptsAtMostOneUsefulReferenceRefreshThenStops() throws {
        let pipeline = GFXPipeline()
        let collector = WriteCollector()
        attach(pipeline) { collector.append($0) }
        defer { pipeline.stop() }
        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        let buffer = try makeDetailedPixelBuffer()
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: buffer, sequence: 1), .submitted)
        pipeline.handleClientPDU(frameAck(frameId: 1))
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: buffer, sequence: 1), .blocked)
        Thread.sleep(forTimeInterval: 0.27)
        let beforeRefresh = collector.count
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: buffer, sequence: 1), .submitted)
        XCTAssertLessThanOrEqual(collector.count, beforeRefresh + 3)
        if collector.count > beforeRefresh {
            let wire = try wirePDU(in: collector.snapshot, after: beforeRefresh)
            XCTAssertTrue(containsAnnexBNAL(type: 5, in: wire))
            XCTAssertEqual(collector.count, beforeRefresh + 3)
            pipeline.handleClientPDU(frameAck(frameId: 2))
        }
        Thread.sleep(forTimeInterval: 0.22)
        for _ in 0..<16 {
            XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: buffer, sequence: 1), .blocked)
        }
        XCTAssertNil(pipeline.nextFrameWaitNanoseconds)
    }

    func testQualityIncreaseRefreshesStaticContentWithoutOverridingAdaptation() throws {
        let session = RDPSession(config: ServerConfig(videoQuality: VideoQualitySettings(mode: .high)))
        let pipeline = session.gfx
        let collector = WriteCollector()
        attach(pipeline) { collector.append($0) }
        defer { pipeline.stop() }
        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        let buffer = try makeDetailedPixelBuffer()
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: buffer, sequence: 1), .submitted)
        pipeline.handleClientPDU(frameAck(frameId: 1))
        Thread.sleep(forTimeInterval: 0.27)
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: buffer, sequence: 1), .submitted)
        pipeline.handleClientPDU(frameAck(frameId: 2))
        XCTAssertNil(pipeline.nextFrameWaitNanoseconds)
        session.applyVideoQuality(VideoQualitySettings(mode: .original))
        XCTAssertEqual(session.videoController.targetBitrate, 2_000_000)
        Thread.sleep(forTimeInterval: 0.22)
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: buffer, sequence: 1), .submitted)
    }

    func testNetworkPressureDefersThePendingStaticRefreshUntilRecovery() throws {
        let pipeline = GFXPipeline()
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        pipeline.attachController(controller)
        attach(pipeline) { _ in }
        defer { pipeline.stop() }
        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        let buffer = try makeDetailedPixelBuffer()
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: buffer, sequence: 1), .submitted)
        pipeline.handleClientPDU(frameAck(frameId: 1))
        controller.noteServerQueue(bytes: 2_000_000)
        pipeline.applyLiveControllerCaps()
        Thread.sleep(forTimeInterval: 0.27)
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: buffer, sequence: 1), .blocked)
        controller.noteServerQueue(bytes: 0)
        pipeline.applyLiveControllerCaps()
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: buffer, sequence: 1), .submitted)
    }

    func testOversizedOptionalRefreshNeverRetriesIdleAndNextCaptureStillDecodes() throws {
        let pipeline = GFXPipeline()
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        pipeline.attachController(controller)
        let collector = WriteCollector()
        attach(pipeline) { collector.append($0) }
        defer { pipeline.stop() }
        try pipeline.start(width: 512, height: 512)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        let buffer = try makePixelBuffer(width: 512, height: 512)
        CVPixelBufferLockBaseAddress(buffer, [])
        let pixels = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt32.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer) / 4
        for y in 0..<512 {
            for x in 0..<512 {
                let r = (x * 17 + y * 31) & 255
                let g = (x * 53 ^ y * 97) & 255
                let b = (x * 113 + y * 73) & 255
                pixels[y * stride + x] = 0xff000000 | UInt32(r << 16 | g << 8 | b)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let setup = collector.count
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: buffer, sequence: 1), .submitted)
        let firstWire = try wirePDU(in: collector.snapshot, after: setup)
        let decoder = H264TestDecoder()
        _ = try decoder.decode(Array(firstWire.dropFirst(39)))
        pipeline.handleClientPDU(frameAck(frameId: 1))
        controller.updateConfiguredBitrate(1_000_000)
        pipeline.applyLiveControllerCaps()
        let liveEncoder = pipeline.h264
        Thread.sleep(forTimeInterval: 0.27)
        let beforeRefresh = collector.count
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: buffer, sequence: 1), .submitted)
        XCTAssertEqual(collector.count, beforeRefresh, "an oversized optional IDR must not reach the transport")
        XCTAssertTrue(pipeline.h264 === liveEncoder)
        XCTAssertNil(pipeline.nextFrameWaitNanoseconds)
        for _ in 0..<16 {
            XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: buffer, sequence: 1), .blocked)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        for y in 0..<32 {
            for x in 0..<32 { pixels[y * stride + x] = 0xffc8c8c8 }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let latest = buffer
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: latest, sequence: 2), .submitted)
        let finalWire = try wirePDU(in: collector.snapshot, after: beforeRefresh)
        XCTAssertFalse(containsAnnexBNAL(type: 5, in: finalWire), "a rejected trial must not force a live IDR")
        let decoded = try decoder.decode(Array(finalWire.dropFirst(39)))
        XCTAssertGreaterThan(firstLuma(decoded), 150)
    }

    func testAcceptedTrialBecomesLiveAndNextUpdateUsesItsPFrameReference() throws {
        let pipeline = GFXPipeline()
        pipeline.targetBitrate = 2_000_000
        let collector = WriteCollector()
        attach(pipeline) { collector.append($0) }
        defer { pipeline.stop() }
        try pipeline.start(width: 512, height: 512)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        let decoder = H264TestDecoder()
        var latest: CVPixelBuffer?
        for index in 0..<8 {
            let buffer = try makeDetailedPixelBuffer(width: 512, height: 512, seed: index)
            var wired = false
            for _ in 0..<8 {
                let before = collector.count
                _ = encodeFrameAndWait(pipeline, pixelBuffer: buffer, sequence: UInt64(index + 1))
                if collector.count > before {
                    let wire = try wirePDU(in: collector.snapshot, after: before)
                    _ = try decoder.decode(Array(wire.dropFirst(39)))
                    let end = unwrap(try XCTUnwrap(collector.snapshot.last))
                    pipeline.handleClientPDU(frameAck(frameId: readU32(end, at: 8)))
                    wired = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.04)
            }
            XCTAssertTrue(wired)
            latest = buffer
            Thread.sleep(forTimeInterval: 1.0 / 30)
        }
        let buffer = try XCTUnwrap(latest)
        let original = pipeline.h264
        pipeline.targetBitrate = 20_000_000
        pipeline.h264.updateBitrate(20_000_000)
        pipeline.requestStaticRefinement()
        Thread.sleep(forTimeInterval: 0.27)
        let beforeTrial = collector.count
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: buffer, sequence: 8), .submitted)
        XCTAssertFalse(pipeline.h264 === original)
        let trialWire = try wirePDU(in: collector.snapshot, after: beforeTrial)
        XCTAssertTrue(containsAnnexBNAL(type: 5, in: trialWire))
        _ = try decoder.decode(Array(trialWire.dropFirst(39)))
        let end = unwrap(try XCTUnwrap(collector.snapshot.last))
        pipeline.handleClientPDU(frameAck(frameId: readU32(end, at: 8)))

        CVPixelBufferLockBaseAddress(buffer, [])
        let pixels = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt32.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer) / 4
        for y in 0..<32 {
            for x in 0..<32 { pixels[y * stride + x] = 0xffc8c8c8 }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let beforeUpdate = collector.count
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: buffer, sequence: 9), .submitted)
        let updateWire = try wirePDU(in: collector.snapshot, after: beforeUpdate)
        XCTAssertFalse(containsAnnexBNAL(type: 5, in: updateWire))
        let decoded = try decoder.decode(Array(updateWire.dropFirst(39)))
        XCTAssertGreaterThan(firstLuma(decoded), 150)
    }

    private func firstLuma(_ buffer: CVPixelBuffer) -> UInt8 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.load(as: UInt8.self)
    }

    private func makeDetailedPixelBuffer(width: Int = 64, height: Int = 64,
                                        seed: Int = 0) throws -> CVPixelBuffer {
        let buffer = try makePixelBuffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let pixels = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt32.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer) / 4
        for y in 0..<height {
            for x in 0..<width {
                let value = UInt32(((x * 17 + y * 29 + seed * 47) ^ ((x / 3 + y / 5) * 37)) & 255)
                pixels[y * stride + x] = 0xff000000 | value * 0x010101
            }
        }
        return buffer
    }

    func testAVC106EncodesDesktopSizeOneToOne() throws {
        let pipeline = GFXPipeline()
        let collector = WriteCollector()
        var writes: [[UInt8]] { collector.snapshot }
        attach(pipeline) { collector.append($0) }
        defer { pipeline.stop() }

        try pipeline.start(width: 1920, height: 1200)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0600))

        let commands = writes.map(unwrap).map { readU16($0, at: 0) }
        // RESET, CAPS_CONFIRM, CREATE, MAP (unscaled)
        XCTAssertEqual(commands, [0x0013, 0x000E, 0x0009, 0x000F])
        let create = unwrap(writes[2])
        // Surface and encoder both use the negotiated desktop size.
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
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        let setupWriteCount = collector.count
        let buffer = try makePixelBuffer(width: 64, height: 64)

        XCTAssertEqual(pipeline.encodeFrame(pixelBuffer: buffer, captureSequence: 1), .submitted)
        pipeline.requestForceIDR(reason: "refresh during bootstrap")
        _ = try waitForWrites(collector, count: setupWriteCount + 3)

        pipeline.handleClientPDU(frameAck(frameId: 1))
        XCTAssertEqual(pipeline.encodeFrame(pixelBuffer: buffer, captureSequence: 1), .submitted)
        let writes = try waitForWrites(collector, count: setupWriteCount + 6)
        let wire = unwrap(writes[setupWriteCount + 4])
        XCTAssertTrue(containsAnnexBNAL(type: 5, in: wire))
    }

    func testBootstrapUsesNegotiatedFrameWindowAndKeepsPFrameChain() throws {
        let pipeline = GFXPipeline()
        let collector = WriteCollector()
        var writes: [[UInt8]] { collector.snapshot }
        // Keep the window small so two H.264 frames (plus bootstrap probe) saturate it.
        pipeline.configureFrameAcknowledgement(maxUnacknowledgedFrameCount: 2)
        attach(pipeline) { collector.append($0) }
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        let setupWriteCount = writes.count
        let first = try makePixelBuffer(width: 64, height: 64, value: 0)
        let second = try makePixelBuffer(width: 64, height: 64, value: 20)
        let third = try makePixelBuffer(width: 64, height: 64, value: 40)
        let fourth = try makePixelBuffer(width: 64, height: 64, value: 60)

        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: first), .submitted)
        XCTAssertEqual(writes.count, setupWriteCount + 3)
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: second), .submitted)
        XCTAssertEqual(writes.count, setupWriteCount + 6)
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: third), .blocked)
        XCTAssertEqual(writes.count, setupWriteCount + 6)

        pipeline.handleClientPDU(frameAck(frameId: 1))
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: third), .submitted)
        XCTAssertEqual(writes.count, setupWriteCount + 9)

        pipeline.handleClientPDU(frameAck(frameId: 2))
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: fourth), .submitted)
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
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        XCTAssertEqual(pipeline.currentFrameAcknowledgementWindow, 2)

        for value: UInt8 in [0, 20] {
            XCTAssertEqual(
                encodeFrameAndWait(pipeline, pixelBuffer: try makePixelBuffer(width: 64, height: 64, value: value)),
                .submitted
            )
        }
        XCTAssertEqual(
            encodeFrameAndWait(pipeline, pixelBuffer: try makePixelBuffer(width: 64, height: 64, value: 40)),
            .blocked
        )
    }

    func testControllerAudioTightensGraphicsWindowWhenQueueIsPressured() throws {
        let pipeline = GFXPipeline()
        pipeline.configureFrameAcknowledgement(maxUnacknowledgedFrameCount: 8)
        pipeline.setAudioLowLatencyMode(true)
        pipeline.setAudioQueuePressure(true)
        attach(pipeline) { _ in }
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        XCTAssertEqual(pipeline.currentFrameAcknowledgementWindow, 2)

        XCTAssertEqual(
            encodeFrameAndWait(pipeline, pixelBuffer: try makePixelBuffer(width: 64, height: 64, value: 0)),
            .submitted
        )
        XCTAssertEqual(
            encodeFrameAndWait(pipeline, pixelBuffer: try makePixelBuffer(width: 64, height: 64, value: 20)),
            .submitted
        )
        XCTAssertEqual(
            encodeFrameAndWait(pipeline, pixelBuffer: try makePixelBuffer(width: 64, height: 64, value: 40)),
            .blocked
        )

        pipeline.handleClientPDU(frameAck(frameId: 1))
        XCTAssertEqual(
            encodeFrameAndWait(pipeline, pixelBuffer: try makePixelBuffer(width: 64, height: 64, value: 40)),
            .submitted
        )
    }

    func testSteadyStateWaitsForFrameAckBeforeNextFrame() throws {
        let pipeline = GFXPipeline()
        let collector = WriteCollector()
        var writes: [[UInt8]] { collector.snapshot }
        pipeline.configureFrameAcknowledgement(maxUnacknowledgedFrameCount: 1)
        attach(pipeline) { collector.append($0) }
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        let setupWriteCount = writes.count
        let first = try makePixelBuffer(width: 64, height: 64, value: 0)
        let second = try makePixelBuffer(width: 64, height: 64, value: 20)
        let third = try makePixelBuffer(width: 64, height: 64, value: 40)

        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: first), .submitted)
        pipeline.handleClientPDU(frameAck(frameId: 1))
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: second), .submitted)
        XCTAssertEqual(writes.count, setupWriteCount + 6)

        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: third), .blocked)
        XCTAssertEqual(
            writes.count,
            setupWriteCount + 6,
            "an unacknowledged steady-state frame must hold the next encode"
        )

        pipeline.handleClientPDU(frameAck(frameId: 2))
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: third), .submitted)
        XCTAssertEqual(writes.count, setupWriteCount + 9)
    }

    func testMeasuredWindowStaysWithinAdvertisedCeiling() throws {
        let pipeline = GFXPipeline()
        pipeline.configureFrameAcknowledgement(maxUnacknowledgedFrameCount: 8)
        attach(pipeline) { _ in }
        pipeline.attachController(makeMeasuredVideoController(bitrate: 12_500_000, fps: 30))
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
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        encodeFrameAndWait(pipeline, pixelBuffer: try makePixelBuffer(width: 64, height: 64))
        XCTAssertEqual(pipeline.unackedFrameCount, 1)

        pipeline.handleClientPDU(qoeFrameAck(frameId: 1, commandDecodeMs: 4, renderMs: 6))
        XCTAssertEqual(pipeline.unackedFrameCount, 1)
        pipeline.handleClientPDU(frameAck(frameId: 1))
        XCTAssertEqual(pipeline.unackedFrameCount, 0)
    }

    func testFrameAckQueueMapsUnavailableAndQueuedStates() throws {
        let pipeline = GFXPipeline()
        let controller = makeMeasuredVideoController(bitrate: 8_000_000, fps: 30)
        attach(pipeline) { _ in }
        pipeline.attachController(controller)
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        let buffer = try makePixelBuffer(width: 64, height: 64)

        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: buffer), .submitted)
        pipeline.handleClientPDU(frameAck(frameId: 1, clientQueueBytes: 0))
        XCTAssertEqual(controller.clientQueueFeedback, .unavailable)

        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: buffer), .submitted)
        pipeline.handleClientPDU(frameAck(frameId: 2, clientQueueBytes: 12_345))
        XCTAssertEqual(controller.clientQueueFeedback, .queued(bytes: 12_345))
    }

    func testTCPSendStallOnlyPausesEncode() {
        let pipeline = GFXPipeline()
        attach(pipeline) { _ in }
        pipeline.attachController(makeMeasuredVideoController(bitrate: 12_500_000, fps: 30))
        defer { pipeline.stop() }

        pipeline.setSendBlocked(true)
        XCTAssertEqual(
            pipeline.encodeFrame(pixelBuffer: try! makePixelBuffer(width: 64, height: 64), captureSequence: 1),
            .blocked
        )
        pipeline.setSendBlocked(false)
        XCTAssertFalse(pipeline.isAckWindowFull)
    }

    func testSuspendFrameAcknowledgementsClearsWindowAndAllowsContinuousOutput() throws {
        let pipeline = GFXPipeline()
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        let collector = WriteCollector()
        var writes: [[UInt8]] { collector.snapshot }
        pipeline.attachController(controller)
        attach(pipeline) { collector.append($0) }
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        let setupWriteCount = writes.count
        let first = try makePixelBuffer(width: 64, height: 64, value: 0)

        encodeFrameAndWait(pipeline, pixelBuffer: first)
        XCTAssertEqual(writes.count, setupWriteCount + 3)

        pipeline.handleClientPDU(frameAck(frameId: 1, clientQueueBytes: UInt32.max))
        XCTAssertTrue(pipeline.isFrameAcknowledgementSuspended)
        XCTAssertFalse(controller.stallRecoveryMode)
        XCTAssertEqual(controller.targetFPS, 60)
        XCTAssertEqual(controller.targetBitrate, 20_000_000)

        for value: UInt8 in [20, 40, 60] {
            encodeFrameAndWait(pipeline,
                pixelBuffer: try makePixelBuffer(width: 64, height: 64, value: value)
            )
        }
        XCTAssertEqual(writes.count, setupWriteCount + 12)

        pipeline.handleClientPDU(frameAck(frameId: 4, clientQueueBytes: 0))
        XCTAssertFalse(pipeline.isFrameAcknowledgementSuspended)
        encodeFrameAndWait(pipeline,
            pixelBuffer: try makePixelBuffer(width: 64, height: 64, value: 80)
        )
        XCTAssertEqual(writes.count, setupWriteCount + 15)
    }

    func testResizeRejectsOldAckAndBootstrapsWithNewIDR() throws {
        let pipeline = GFXPipeline()
        let collector = WriteCollector()
        var writes: [[UInt8]] { collector.snapshot }
        pipeline.configureFrameAcknowledgement(maxUnacknowledgedFrameCount: 1)
        attach(pipeline) { collector.append($0) }
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        encodeFrameAndWait(pipeline, pixelBuffer: try makePixelBuffer(width: 64, height: 64))
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
        encodeFrameAndWait(pipeline, pixelBuffer: resizedBuffer)
        let firstResizeStart = unwrap(writes[writes.count - 3])
        let firstResizeWire = unwrap(writes[writes.count - 2])
        XCTAssertEqual(readU16(firstResizeStart, at: 0), 0x000B)
        XCTAssertEqual(readU32(firstResizeStart, at: 12), 2)
        XCTAssertEqual(readU16(firstResizeWire, at: 0), 0x0001)
        XCTAssertTrue(containsAnnexBNAL(type: 5, in: firstResizeWire))
        let firstResizeWriteCount = writes.count

        pipeline.handleClientPDU(frameAck(frameId: 1))
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: changedResizedBuffer), .blocked)
        XCTAssertEqual(writes.count, firstResizeWriteCount)

        pipeline.handleClientPDU(frameAck(frameId: 2))
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: changedResizedBuffer), .submitted)
        XCTAssertEqual(writes.count, firstResizeWriteCount + 3)
    }

    func testOutputResumeRebuildsSurfaceAndBootstrapsWithNewIDR() throws {
        let pipeline = GFXPipeline()
        let collector = WriteCollector()
        var writes: [[UInt8]] { collector.snapshot }
        attach(pipeline) { collector.append($0) }
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        let buffer = try makePixelBuffer(width: 64, height: 64, value: 20)
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: buffer), .submitted)
        pipeline.handleClientPDU(frameAck(frameId: 1))

        pipeline.pauseSending()
        let rebuildStart = writes.count
        try pipeline.start(width: 64, height: 64)

        XCTAssertFalse(pipeline.isSendPaused)
        XCTAssertEqual(
            writes[rebuildStart...].map(unwrap).map { readU16($0, at: 0) },
            [0x000E, 0x0009, 0x000F]
        )
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: buffer), .submitted)

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
        let collector = WriteCollector()
        var writes: [[UInt8]] { collector.snapshot }
        attach(pipeline) { collector.append($0) }
        defer { pipeline.stop() }

        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        let buffer = try makePixelBuffer(width: 64, height: 64)
        encodeFrameAndWait(pipeline, pixelBuffer: buffer)
        pipeline.handleClientPDU(frameAck(frameId: 1, clientQueueBytes: UInt32.max))
        XCTAssertTrue(pipeline.isFrameAcknowledgementSuspended)

        let renegotiationStart = writes.count
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        XCTAssertEqual(
            writes[renegotiationStart...].map(unwrap).map { readU16($0, at: 0) },
            [0x0013, 0x000E, 0x0009, 0x000F]
        )
        XCTAssertFalse(pipeline.isFrameAcknowledgementSuspended)

        encodeFrameAndWait(pipeline, pixelBuffer: buffer)
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

    func testSelectsHighestKnownCapabilityWhenUnknownVersionIsAdvertised() throws {
        let pipeline = GFXPipeline()
        attach(pipeline) { _ in }
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
        let collector = WriteCollector()
        var writes: [[UInt8]] { collector.snapshot }
        attach(pipeline) { collector.append($0) }
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
        let collector = WriteCollector()
        var writes: [[UInt8]] { collector.snapshot }
        attach(pipeline) { collector.append($0) }
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

    func testCapsConfirmContainsOnlyTheNegotiableVersionAndFlags() throws {
        let pipeline = GFXPipeline()
        let collector = WriteCollector()
        var writes: [[UInt8]] { collector.snapshot }
        attach(pipeline) { collector.append($0) }
        defer { pipeline.stop() }
        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertiseRaw(sets: [
            (0x000A_0100, [UInt8](repeating: 0, count: 16)),
            (0x000A_0600, [2, 0, 0, 0]),
        ]))
        let confirm = try XCTUnwrap(writes.map(unwrap).first { readU16($0, at: 0) == 0x0013 })
        XCTAssertEqual(confirm.count, 20)
        XCTAssertEqual(readU32(confirm, at: 4), 20)
        XCTAssertEqual(readU32(confirm, at: 8), 0x000A_0600)
        XCTAssertEqual(readU32(confirm, at: 12), 4)
        XCTAssertEqual(readU32(confirm, at: 16), 2)
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
        let collector = WriteCollector()
        var writes: [[UInt8]] { collector.snapshot }
        attach(pipeline) { collector.append($0) }
        defer { pipeline.stop() }

        try pipeline.start(width: 128, height: 128)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        let setupWriteCount = writes.count
        let buffer = try makePixelBuffer(width: 128, height: 128)

        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: buffer), .submitted)

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

    func testStaleCaptureGeometryDoesNotConsumeEncodeCreditOrBootstrap() throws {
        let pipeline = GFXPipeline()
        let collector = WriteCollector()
        attach(pipeline) { collector.append($0) }
        defer { pipeline.stop() }
        try pipeline.start(width: 64, height: 64)
        pipeline.handleClientPDU(capsAdvertise(version: 0x000A_0400))
        let setupWriteCount = collector.count
        let stale = try makePixelBuffer(width: 128, height: 64)

        for _ in 0..<16 {
            XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: stale), .blocked)
        }
        XCTAssertEqual(collector.count, setupWriteCount)
        XCTAssertFalse(pipeline.hasPendingEncode)
        XCTAssertFalse(pipeline.isEncodeWindowFull)
        XCTAssertEqual(pipeline.unackedFrameCount, 0)

        let current = try makePixelBuffer(width: 64, height: 64)
        XCTAssertEqual(encodeFrameAndWait(pipeline, pixelBuffer: current), .submitted)
        let wire = try wirePDU(in: collector.snapshot, after: setupWriteCount)
        XCTAssertEqual(readU16(wire, at: 17), 64)
        XCTAssertEqual(readU16(wire, at: 19), 64)
        XCTAssertTrue(containsAnnexBNAL(type: 5, in: wire))
    }

    private final class WriteCollector {
        private let condition = NSCondition()
        private var writes: [[UInt8]] = []

        func append(_ write: [UInt8]) {
            condition.lock()
            writes.append(write)
            condition.broadcast()
            condition.unlock()
        }

        var count: Int {
            condition.lock()
            defer { condition.unlock() }
            return writes.count
        }

        var snapshot: [[UInt8]] {
            condition.lock()
            defer { condition.unlock() }
            return writes
        }

        func wait(for count: Int, until deadline: Date) -> [[UInt8]] {
            condition.lock()
            defer { condition.unlock() }
            while writes.count < count, condition.wait(until: deadline) {}
            return writes
        }
    }

    private func waitForWrites(
        _ collector: WriteCollector,
        count: Int,
        timeout: TimeInterval = 2.0
    ) throws -> [[UInt8]] {
        let writes = collector.wait(for: count, until: Date().addingTimeInterval(timeout))
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
