import NIOEmbedded
import NIOCore
import NIOSSL
import XCTest
@testable import SwiftRDPCore

final class OutboundSchedulingTests: XCTestCase {
    func testCompletionBelongsToTheLastPacketOfABatch() {
        var queue = OutboundWriteQueue()
        let completed = expectation(description: "last packet written")
        queue.append([[1], [2], [3]], isVideo: true, onWritten: { _ in completed.fulfill() })
        XCTAssertNil(queue.popFirst()?.onWritten)
        XCTAssertNil(queue.popFirst()?.onWritten)
        XCTAssertEqual(queue.videoFrameCount, 1)
        queue.popFirst()?.onWritten?(1)
        XCTAssertEqual(queue.videoFrameCount, 0)
        wait(for: [completed], timeout: 0.1)
    }

    func testQueuePreservesPacketBoundariesAndOrder() {
        var queue = OutboundWriteQueue()
        let packets = (0..<100).map { [UInt8](repeating: UInt8($0), count: 1600) }
        queue.append(packets)
        XCTAssertEqual(queue.byteCount, 160_000)
        XCTAssertEqual(queue.messageCount, 1)
        for packet in packets { XCTAssertEqual(queue.popFirst()?.bytes, packet) }
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.byteCount, 0)
        XCTAssertEqual(queue.messageCount, 0)
    }

    func testBytePacerLimitsBurstAndRefillsOverTime() {
        var pacer = VideoBytePacer()
        XCTAssertEqual(pacer.reserve(bytes: 1600, bitrate: 1_600_000, now: 0), 0)
        XCTAssertEqual(pacer.reserve(bytes: 1600, bitrate: 1_600_000, now: 0), 6_000_000)
        XCTAssertEqual(pacer.reserve(bytes: 1600, bitrate: 1_600_000, now: 6_000_000), 0)
        XCTAssertEqual(pacer.reserve(bytes: 1600, bitrate: 1_600_000, now: 6_000_000), 8_000_000)
    }

    func testLargeVideoFrameIsPacedAndAudioCanInterleave() throws {
        let session = RDPSession(config: ServerConfig())
        let tls = try NIOSSLContext(configuration: .makeClientConfiguration())
        let channel = EmbeddedChannel(handler: NIOInboundHandler(session: session, sslContext: tls))
        defer { _ = try? channel.finish() }
        channel.pipeline.fireChannelActive()
        let packets = (0..<640).map { _ in [UInt8](repeating: 3, count: 1600) }
        XCTAssertTrue(session.socket.writeBatch(packets, priority: .video))
        var firstBurst = 0
        while let packet = try channel.readOutbound(as: ByteBuffer.self) {
            XCTAssertEqual(packet.readableBytes, 1600)
            firstBurst += packet.readableBytes
        }
        XCTAssertGreaterThan(firstBurst, 0)
        XCTAssertLessThanOrEqual(firstBurst, 64 * 1024)
        XCTAssertFalse(session.graphicsWritable)
        let audio: [UInt8] = [0xAA, 0xBB]
        XCTAssertTrue(session.socket.write(audio, priority: .audio))
        var next = try XCTUnwrap(channel.readOutbound(as: ByteBuffer.self))
        XCTAssertEqual(next.readBytes(length: next.readableBytes), audio)
    }

    func testTwoQueuedFramesPauseAdmissionAndRejectAThirdAtomically() throws {
        let session = RDPSession(config: ServerConfig())
        session.applyVideoBitrate(1_000_000)
        let tls = try NIOSSLContext(configuration: .makeClientConfiguration())
        let channel = EmbeddedChannel(handler: NIOInboundHandler(session: session, sslContext: tls))
        defer { _ = try? channel.finish() }
        channel.pipeline.fireChannelActive()
        let frame = (0..<3).map { _ in [UInt8](repeating: 3, count: 1600) }
        XCTAssertTrue(session.socket.writeBatch(frame, priority: .video))
        XCTAssertTrue(session.socket.writeBatch(frame, priority: .video))
        XCTAssertLessThan(session.videoController.lastServerQueueBytes, session.videoOutboundQueueWatermarks().high)
        XCTAssertFalse(session.graphicsWritable)
        XCTAssertFalse(session.socket.writeBatch(frame, priority: .video))
    }

    func testGraphicsControlCannotOvertakeAnInProgressFrame() throws {
        let session = RDPSession(config: ServerConfig())
        let tls = try NIOSSLContext(configuration: .makeClientConfiguration())
        let channel = EmbeddedChannel(handler: NIOInboundHandler(session: session, sslContext: tls))
        defer { _ = try? channel.finish() }
        channel.pipeline.fireChannelActive()
        let frame = (0..<640).map { _ in [UInt8](repeating: 3, count: 1600) }
        XCTAssertTrue(session.socket.writeBatch(frame, priority: .video))
        while try channel.readOutbound(as: ByteBuffer.self) != nil {}
        XCTAssertTrue(session.socket.write([0xCC], priority: .graphicsControl))
        while var packet = try channel.readOutbound(as: ByteBuffer.self) {
            XCTAssertEqual(packet.readBytes(length: packet.readableBytes), frame[0])
        }
        XCTAssertTrue(session.socket.write([0xAA], priority: .audio))
        var audio = try XCTUnwrap(channel.readOutbound(as: ByteBuffer.self))
        XCTAssertEqual(audio.readBytes(length: audio.readableBytes), [0xAA])
    }
}
