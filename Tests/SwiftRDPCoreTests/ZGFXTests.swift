import XCTest
@testable import SwiftRDPCore

final class ZGFXTests: XCTestCase {
    func testSingleSegmentUsesUncompressedRDP8Bulk() {
        let payload: [UInt8] = [0x01, 0x02, 0x03]

        let wrapped = ZGFXCompressor().wrap(payload)

        XCTAssertEqual(wrapped, [
            ZGFXCompressor.segmentedSingle,
            ZGFXCompressor.packetComprTypeRDP8,
            0x01, 0x02, 0x03,
        ])
    }

    func testMultipartSegmentsRoundTrip() throws {
        let payload = (0..<(ZGFXCompressor.maxSegmentUncompressed + 17)).map {
            UInt8(truncatingIfNeeded: $0)
        }

        let wrapped = ZGFXCompressor().wrap(payload)

        XCTAssertEqual(wrapped[0], ZGFXCompressor.segmentedMultipart)
        XCTAssertEqual(readU16(wrapped, at: 1), 2)
        XCTAssertEqual(readU32(wrapped, at: 3), UInt32(payload.count))
        XCTAssertEqual(ZGFXCompressor().decompress(wrapped), payload)
    }


    func testWrapCanSkipCompression() {
        let payload = Array(repeating: Array("SwiftRDP frame ".utf8), count: 1_000).flatMap { $0 }
        let wrapped = ZGFXCompressor().wrap(payload, compress: false)
        XCTAssertEqual(wrapped[0], ZGFXCompressor.segmentedSingle)
        XCTAssertEqual(wrapped[1], ZGFXCompressor.packetComprTypeRDP8)
        XCTAssertEqual(ZGFXCompressor().decompress(wrapped), payload)
    }

    func testRoundTripCompressesRepeatedPayload() {
        let payload = Array(repeating: Array("SwiftRDP frame ".utf8), count: 1_000).flatMap { $0 }

        let wrapped = ZGFXCompressor().wrap(payload)

        XCTAssertEqual(wrapped[0], ZGFXCompressor.segmentedSingle)
        XCTAssertEqual(
            wrapped[1],
            ZGFXCompressor.packetComprTypeRDP8 | ZGFXCompressor.packetCompressed
        )
        XCTAssertEqual(ZGFXCompressor().decompress(wrapped), payload)
    }

    func testDecompressUncompressedSegmentUpdatesHistory() {
        let decoder = ZGFXCompressor()
        let segment: [UInt8] = [
            ZGFXCompressor.packetComprTypeRDP8,
            0x10, 0x20, 0x30,
        ]

        XCTAssertEqual(decoder.decompressSegment(segment), [0x10, 0x20, 0x30])
    }

    func testDecompressKnownLiteralAndMatchTokenStream() {
        // Three generic literals ("ABC"), followed by distance=3, length=3.
        let segment: [UInt8] = [
            ZGFXCompressor.packetComprTypeRDP8 | ZGFXCompressor.packetCompressed,
            0x20, 0x90, 0x88, 0x71, 0x18,
            0x02, // two padding bits in the preceding byte
        ]

        XCTAssertEqual(ZGFXCompressor().decompressSegment(segment), Array("ABCABC".utf8))
    }

    func testGraphicsTransportBatchesACompleteFrame() {
        var framePDUs: [[UInt8]] = []
        var framePriority: RDPSocket.WritePriority?
        let transport = RDPGFXDynamicChannelTransport(
            sendFrame: { pdus, priority in
                framePDUs = pdus
                framePriority = priority
                return pdus.reduce(0) { $0 + $1.count }
            }
        )

        XCTAssertNotNil(
            transport.sendGraphicsPDUs(
                [[0x01], [0x02], [0x03]],
                compress: false,
                priority: RDPSocket.WritePriority.video
            )
        )
        XCTAssertEqual(framePDUs.count, 3)
        XCTAssertEqual(framePriority, .video)
        XCTAssertTrue(framePDUs.allSatisfy { $0.first == ZGFXCompressor.segmentedSingle })
    }

    func testDynamicVCBatchesAllFragmentsForOneVideoFrame() {
        let manager = DynamicVCManager()
        var batches: [[[UInt8]]] = []
        var priority: RDPSocket.WritePriority?
        manager.sendBatch = { pdus, receivedPriority in
            batches.append(pdus)
            priority = receivedPriority
            return pdus.reduce(0) { $0 + $1.count }
        }

        let first = Array(repeating: UInt8(0x11), count: 2_000)
        let second = Array(repeating: UInt8(0x22), count: 2_000)
        XCTAssertNotNil(
            manager.sendDataBatch(
                channelId: 1,
                payloads: [first, second],
                priority: .video
            )
        )

        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(priority, .video)
        XCTAssertGreaterThan(batches[0].count, 2)
        XCTAssertEqual(
            (batches[0].first?.first ?? 0) >> 4,
            DynamicVCManager.PDU.dataFirst.rawValue
        )
    }

    func testCompressedDVCFirstAndContinuationDeliverDecompressedPayload() {
        let manager = DynamicVCManager()
        var delivered: [UInt8]?
        manager.dataRelay = { _, payload in delivered = payload }

        // Cmd=DATA_FIRST_COMPRESSED, channelId=1, total uncompressed length=6.
        manager.handle(pdu: [0x60, 0x01, 0x06, 0x04] + Array("ABC".utf8))
        XCTAssertNil(delivered)

        // Cmd=DATA_COMPRESSED, channelId=1. A raw RDP8 segment is valid here too.
        manager.handle(pdu: [0x70, 0x01, 0x04] + Array("DEF".utf8))
        XCTAssertEqual(delivered, Array("ABCDEF".utf8))
    }

    private func readU16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private func readU32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}
