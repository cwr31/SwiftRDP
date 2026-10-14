import Foundation
import NIOCore
import XCTest
@testable import SwiftRDPCore

final class MultitransportTests: XCTestCase {
    func testDelayAckParametersDoNotDiscardAccompanyingAcknowledgement() throws {
        for count: UInt8 in [0, 1, 8, 15, 16, 64, 78, 255] {
            let sender = RDPUDP2Connection(mtu: 1232, peerWindow: 1024, now: 0)
            try sender.enqueue(ByteBuffer(bytes: [1, 2, 3]), onSent: nil)
            _ = try sender.transmit(now: 0)
            var packet = RDPUDP2Packet()
            packet.ack = .init(sequence: 100, timestamp: 0, delayMilliseconds: 0)
            packet.delayAck = .init(count: count, milliseconds: 10)
            packet.ackOfAcks = 100
            XCTAssertEqual(try RDPUDP2Packet.parse(packet.encode()).delayAck?.count, count)
            _ = try sender.receive(packet.encode(), now: 1)
            XCTAssertEqual(sender.bufferedBytes, 0)
        }
    }

    func testCookieHashUsesNetworkDWORDOrderRatherThanRawDigestBytes() {
        // Fixed digest fixture for the 16 bytes 00...0f, independent of the encoder.
        let expected: [UInt8] = [
            0x26, 0xCB, 0x45, 0xBE, 0xBE, 0x36, 0xBF, 0x05,
            0x84, 0x84, 0xE6, 0xBD, 0xFD, 0xF0, 0x28, 0x1A,
            0x50, 0x98, 0xC6, 0x43, 0xFE, 0xE5, 0xDC, 0xA3,
            0x28, 0x99, 0xA6, 0xDB, 0x91, 0x89, 0x3A, 0xEE,
        ]
        XCTAssertEqual(RDPUDPSyn.encodeCookieHash(Array(0..<16)), expected)
    }

    func testSplitSelectiveAcknowledgementsRetainEveryMissingReliablePacket() throws {
        for reversed in [false, true] {
            let sender = RDPUDP2Connection(initialSendSequence: 11, initialReceiveSequence: 21,
                mtu: 1232, peerWindow: 1024, now: 0)
            try sender.enqueue(ByteBuffer(bytes: [UInt8](repeating: 7, count: 1220 * 10)), onSent: nil)
            XCTAssertEqual(try sender.transmit(now: 0).count, 10)
            var first = RDPUDP2Packet()
            first.vector = .init(base: 11, timestamp: nil, delayMilliseconds: 255, coded: [0x2A])
            var second = RDPUDP2Packet()
            second.vector = .init(base: 18, timestamp: 10, delayMilliseconds: 0, coded: [0x81, 0xC2])
            let vectors = reversed ? [second, first] : [first, second]
            for (index, packet) in vectors.enumerated() {
                _ = try sender.receive(packet.encode(), now: UInt64(index + 1) * 100_000)
            }
            // Channels 1, 3, 5, 7 and 8 are missing even though the second vector starts at 18.
            XCTAssertEqual(sender.bufferedBytes, 5 * 1220)
        }
    }

    func testReceiverGeneratedMultipartVectorsDoNotDiscardLosses() throws {
        var clock: UInt64 = 1_000_000_000
        let sender = RDPUDP2Connection(initialSendSequence: 11, initialReceiveSequence: 21,
            mtu: 1232, peerWindow: 1024, now: clock)
        let receiver = RDPUDP2Connection(initialSendSequence: 21, initialReceiveSequence: 11,
            mtu: 1232, peerWindow: 1024, now: clock)
        sender.setTargetBitrate(1_000_000_000)
        // A healthy transfer establishes a window large enough to require two ACK vectors.
        for _ in 0..<1023 { try sender.enqueue(ByteBuffer(bytes: [1]), onSent: nil) }
        for _ in 0..<200 where sender.bufferedBytes > 0 {
            for packet in try sender.transmit(now: clock) {
                _ = try receiver.receive(packet.bytes, now: clock + 200_000)
            }
            for packet in try receiver.transmit(now: clock + 200_000) {
                _ = try sender.receive(packet.bytes, now: clock + 400_000)
            }
            clock += 1_000_000
        }
        XCTAssertEqual(sender.bufferedBytes, 0)
        try sender.enqueue(ByteBuffer(bytes: [UInt8](repeating: 7, count: 1023 * 1220)), onSent: nil)
        var count = 0
        for _ in 0..<1000 where sender.queuedBytes > 0 {
            for packet in try sender.transmit(now: clock) {
                if try RDPUDP2Packet.parse(packet.bytes).data != nil {
                    if count % 2 == 1 { _ = try receiver.receive(packet.bytes, now: clock) }
                    count += 1
                }
            }
            clock += 100_000
        }
        XCTAssertEqual(count, 1023)
        let acknowledgements = try receiver.transmit(now: clock)
        XCTAssertEqual(acknowledgements.count, 2)
        for packet in acknowledgements.reversed() {
            clock += 100_000
            _ = try sender.receive(packet.bytes, now: clock)
        }
        XCTAssertGreaterThanOrEqual(sender.bufferedBytes, 512 * 1220)
        var delivered: [UInt8] = []
        for _ in 0..<5000 where sender.bufferedBytes > 0 {
            for packet in try sender.transmit(now: clock) {
                for bytes in try receiver.receive(packet.bytes, now: clock + 200_000) {
                    delivered.append(contentsOf: bytes)
                }
            }
            for packet in try receiver.transmit(now: clock + 200_000) {
                _ = try sender.receive(packet.bytes, now: clock + 400_000)
            }
            clock += 1_000_000
        }
        XCTAssertEqual(sender.bufferedBytes, 0)
        XCTAssertEqual(delivered, [UInt8](repeating: 7, count: 1023 * 1220))
    }

    func testUDP2IndependentWireFixtureAndShortPrefix() throws {
        // MS-RDPEUDP2: little-endian layout, prefix in byte 7; sequence and
        // channel sequence are distinct. Fixture is independent of the encoder.
        let wire: [UInt8] = [5, 4, 0xA0, 0x34, 0x12, 1, 0, 0xE0, 6, 7]
        let packet = try RDPUDP2Packet.parse(wire)
        XCTAssertEqual(packet.logWindow, 10)
        XCTAssertEqual(packet.data?.sequence, 0x1234)
        XCTAssertEqual(packet.data?.channelSequence, 1)
        XCTAssertEqual(packet.data?.bytes, [5, 6, 7])
        XCTAssertEqual(packet.encode(), wire)
        let short: [UInt8] = [0, 0x10, 0xA0, 0x34, 0x12, 0, 0, 0x80]
        XCTAssertEqual(try RDPUDP2Packet.parse(short).ackOfAcks, 0x1234)
        var acknowledgement = RDPUDP2Packet()
        acknowledgement.ackOfAcks = 0x1234
        XCTAssertEqual(acknowledgement.encode(), short)
    }

    func testAckVectorBitOrderAndRunLength() throws {
        let vector = RDPUDP2Packet.AckVector(base: 1000, timestamp: 0x123456,
                                             delayMilliseconds: 3, coded: [0x64, 0xE4])
        XCTAssertEqual(Array(vector.states.prefix(7)), [false, false, true, false, false, true, true])
        XCTAssertEqual(Array(vector.states.suffix(36)), [Bool](repeating: true, count: 36))
        var p = RDPUDP2Packet()
        p.vector = vector
        let decoded = try RDPUDP2Packet.parse(p.encode())
        XCTAssertEqual(decoded.vector?.timestamp, 0x123456)
        XCTAssertEqual(decoded.vector?.states, vector.states)
    }

    func testRejectsTruncationConflictingFlagsAndOversizedUDP() throws {
        var packet = RDPUDP2Packet()
        packet.ack = .init(sequence: 9, timestamp: 7, delayMilliseconds: 1,
                            timeScale: 2, additions: [5, 6])
        let valid = packet.encode()
        for size in 0..<valid.count { XCTAssertThrowsError(try RDPUDP2Packet.parse(Array(valid.prefix(size)))) }
        var invalid = valid
        invalid[1] |= 8 // ACK and ACKVEC are mutually exclusive
        XCTAssertThrowsError(try RDPUDP2Packet.parse(invalid))
        invalid = valid; invalid[1] = 0; invalid[2] = 0xA0 // no payload flags
        XCTAssertThrowsError(try RDPUDP2Packet.parse(invalid))
        XCTAssertThrowsError(try RDPUDP2Packet.parse([UInt8](repeating: 0, count: 1233)))
    }

    func testMstscDataStartsTLSWithoutExplicitAcknowledgement() throws {
        // Captured mstsc layout: DATA | AOA | DELAYACKINFO | undocumented 0x200.
        // This fixture is independent of the server encoder.
        let wire: [UInt8] = [
            0x00, 0x14, 0xF3, 0x01, 0x14, 0x00, 0x64, 0xE0,
            0x64, 0x00, 0x01, 0x00, 0x16, 0x03, 0x01, 0x01,
        ]
        let packet = try RDPUDP2Packet.parse(wire)
        XCTAssertNil(packet.ack)
        XCTAssertNil(packet.vector)
        XCTAssertEqual(packet.logWindow, 15)
        XCTAssertEqual(packet.delayAck?.count, 1)
        XCTAssertEqual(packet.delayAck?.milliseconds, 20)
        XCTAssertEqual(packet.ackOfAcks, 100)
        XCTAssertEqual(packet.data?.sequence, 100)
        XCTAssertEqual(packet.data?.channelSequence, 1)
        let engine = RDPUDP2Connection(initialReceiveSequence: 100,
            mtu: 1232, peerWindow: 1024, now: 0)
        XCTAssertEqual(try engine.receive(wire, now: 1), [[0x16, 0x03, 0x01, 0x01]])
        let ack = try XCTUnwrap(engine.transmit(now: 1).first)
        XCTAssertEqual(try RDPUDP2Packet.parse(ack.bytes).ack?.sequence, 100)
    }

    func testV3SynAndCookieHashUseNetworkByteOrder() throws {
        var bytes: [UInt8] = []
        bytes.appendU32(UInt32.max, endian: .big); bytes.appendU16(512, endian: .big)
        bytes.appendU16(0x1001, endian: .big); bytes.appendU32(0x12345678, endian: .big)
        bytes.appendU16(1232, endian: .big); bytes.appendU16(1232, endian: .big)
        bytes.appendU16(1, endian: .big); bytes.appendU16(0x0101, endian: .big)
        let hash = (0..<32).map(UInt8.init)
        bytes += hash; bytes += repeatElement(0, count: 1232 - bytes.count)
        let syn = try RDPUDPSyn.parse(bytes)
        XCTAssertEqual(syn.initialSequence, 0x12345678)
        XCTAssertEqual(syn.cookieHash, hash)
        let response = syn.acknowledgement(serverSequence: 0x11223344, receiveWindow: 1024)
        XCTAssertEqual(Array(response.prefix(20)),
                       [0x12, 0x34, 0x56, 0x78, 4, 0, 0x10, 5, 0x11, 0x22, 0x33, 0x44,
                        4, 0xD0, 4, 0xD0, 0, 1, 1, 1])
        XCTAssertTrue(response[20...].allSatisfy { $0 == 0 })
        var unsupported = bytes; unsupported[19] = 2
        XCTAssertThrowsError(try RDPUDPSyn.parse(unsupported)) { error in
            guard case RDPUDPSyn.ParseError.version(_, 0x0102) = error else {
                return XCTFail("Expected the unsupported version to be reported")
            }
        }
        XCTAssertThrowsError(try RDPUDPSyn.parse(Array(bytes.dropLast())))
    }

    func testUDP2ReceiveBaseUsesDataFieldsAcrossWrapAndInitialLoss() throws {
        let receiver = RDPUDP2Connection(initialReceiveSequence: 0xFFFF,
            mtu: 1232, peerWindow: 1024, now: 0)
        var second = RDPUDP2Packet()
        second.ackOfAcks = 0xFFFF
        second.data = .init(sequence: 0, channelSequence: 2, bytes: [2])
        XCTAssertTrue(try receiver.receive(second.encode(), now: 1).isEmpty)
        let ack = try RDPUDP2Packet.parse(XCTUnwrap(receiver.transmit(now: 1).first?.bytes))
        XCTAssertNil(ack.ack)
        XCTAssertEqual(ack.vector?.base, 0xFFFF)
        XCTAssertEqual(ack.vector?.states, [false, true])
        var retry = RDPUDP2Packet()
        retry.ackOfAcks = 1
        retry.data = .init(sequence: 1, channelSequence: 1, bytes: [1])
        XCTAssertEqual(try receiver.receive(retry.encode(), now: 2), [[1], [2]])
        let zero = RDPUDP2Connection(initialSendSequence: 0, initialReceiveSequence: 0,
            mtu: 1232, peerWindow: 1024, now: 0)
        var first = RDPUDP2Packet()
        first.data = .init(sequence: 0, channelSequence: 1, bytes: [3])
        XCTAssertEqual(try zero.receive(first.encode(), now: 1), [[3]])
        let zeroAck = try RDPUDP2Packet.parse(XCTUnwrap(zero.transmit(now: 20_000_000).first?.bytes))
        XCTAssertEqual(zeroAck.ack?.sequence, 0)
    }

    func testTunnelFramingSurvivesTLSFragmentationAndCoalescing() throws {
        let payload = (0..<1000).map { UInt8($0 % 251) }
        let message = MultitransportPDU.TunnelMessage(action: .data,
                                                     subheaders: [(1, [3, 4])], payload: payload).encode()
        XCTAssertEqual(Array(message.prefix(4)), [2, 0xE8, 3, 8])
        var buffer = ByteBuffer()
        for byte in message.dropLast() {
            buffer.writeInteger(byte)
            XCTAssertNil(try MultitransportPDU.TunnelMessage.read(from: &buffer))
            XCTAssertEqual(buffer.readerIndex, 0)
        }
        buffer.writeInteger(message.last!)
        buffer.writeBytes(message)
        for _ in 0..<2 {
            let decoded = try XCTUnwrap(MultitransportPDU.TunnelMessage.read(from: &buffer))
            XCTAssertEqual(decoded.payload, payload)
            XCTAssertEqual(decoded.subheaders.first?.bytes, [3, 4])
        }
        XCTAssertEqual(buffer.readableBytes, 0)
        var malformed = ByteBuffer(bytes: [2, 0, 0, 3])
        XCTAssertThrowsError(try MultitransportPDU.TunnelMessage.read(from: &malformed))
        malformed = ByteBuffer(bytes: [2, 0, 0, 5, 0])
        XCTAssertThrowsError(try MultitransportPDU.TunnelMessage.read(from: &malformed))
    }

    func testTunnelAuthenticationAndBootstrapAreBoundToMainSession() {
        let cookie = (0..<16).map(UInt8.init)
        var create: [UInt8] = []; create.appendU32(42); create.appendU32(0); create += cookie
        XCTAssertTrue(MultitransportPDU.authenticates(create, requestID: 42, cookie: cookie))
        XCTAssertFalse(MultitransportPDU.authenticates(create, requestID: 43, cookie: cookie))
        var wrongCookie = cookie; wrongCookie[15] ^= 1
        XCTAssertFalse(MultitransportPDU.authenticates(create, requestID: 42, cookie: wrongCookie))
        create[4] = 1
        XCTAssertFalse(MultitransportPDU.authenticates(create, requestID: 42, cookie: cookie))
        XCTAssertEqual(Array(MultitransportPDU.initiate(requestID: 42, cookie: cookie).prefix(12)),
                       [2, 0, 0, 0, 42, 0, 0, 0, 1, 0, 0, 0])
        XCTAssertEqual(MultitransportPDU.response([4, 0, 0, 0, 42, 0, 0, 0, 0, 0, 0, 0])?.requestID, 42)
        XCTAssertNil(MultitransportPDU.response([0, 0, 0, 0, 42, 0, 0, 0, 0, 0, 0, 0]))
    }

    func testGCCMultitransportRequiresExplicitNegotiation() {
        let block: [UInt8] = [0x0A, 0xC0, 8, 0, 1, 2, 0, 0]
        let data = GCC.parseClientData(fromGCCUserData: Array("Duca".utf8) + [8] + block)
        XCTAssertEqual(data.multitransportFlags, 0x201)
        let server = GCC.buildServerUserData(selectedProtocol: 1, channelNames: ["drdynvc"],
                                              advertiseMsgChannel: true, multitransportFlags: 0x201)
        let advertised: [UInt8] = [8, 0x0C, 8, 0, 1, 2, 0, 0]
        XCTAssertNotNil(server.firstRange(of: advertised))
        XCTAssertNil(GCC.buildServerUserData(selectedProtocol: 1, channelNames: []).firstRange(of: advertised))
    }

    func testSoftSyncPreservesFrameBoundariesAndNewChannelsStartOnTCP() throws {
        let dvc = DynamicVCManager()
        dvc.send = { _ in }
        dvc.handle(pdu: [0x50, 0, 3, 0])
        dvc.createChannel(name: DynamicVCManager.graphicsDVCName)
        dvc.handle(pdu: [0x10, 1, 0, 0, 0, 0])
        XCTAssertEqual(dvc.channelId(forName: DynamicVCManager.graphicsDVCName), 1)
        var tcp: [[[UInt8]]] = [], udp: [[[UInt8]]] = []
        var barrier: RDPSocket.WriteCompletion?
        dvc.sendBatch = { messages, priority, onWritten in
            tcp.append(messages)
            if messages[0][0] == 0x80 {
                XCTAssertEqual(priority, .graphicsControl)
                barrier = onWritten
            }
            return messages.reduce(0) { $0 + $1.count }
        }
        dvc.sendMultitransportBatch = { messages, _, _ in
            udp.append(messages); return messages.reduce(0) { $0 + $1.count }
        }
        let payload = [UInt8](repeating: 5, count: 200_000)
        XCTAssertNotNil(dvc.sendDataBatch(channelId: 1, payloads: [payload], priority: .video))
        XCTAssertTrue(tcp[0].allSatisfy { $0.count <= 1600 })
        let written = CompletionCounter()
        XCTAssertTrue(dvc.switchToMultitransport(channelId: 1, onTCPFlushed: { _ in written.increment() }))
        XCTAssertEqual(written.value, 0)
        XCTAssertEqual(tcp[1][0], [0x80, 0, 18, 0, 0, 0, 3, 0, 1, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0, 0])
        XCTAssertNotNil(dvc.sendDataBatch(channelId: 1, payloads: [payload], priority: .video))
        XCTAssertEqual(tcp.count, 2)
        XCTAssertEqual(udp.count, 1)
        XCTAssertEqual(udp[0], tcp[0])
        XCTAssertTrue(udp[0].allSatisfy { $0.count <= 1600 })
        barrier?(1)
        XCTAssertEqual(written.value, 1)
        var delivered: [UInt8] = []
        dvc.setDataHandler(channelId: 1) { delivered += $0 }
        for pdu in udp[0] { XCTAssertTrue(dvc.handleMultitransport(pdu: pdu)) }
        XCTAssertEqual(delivered, payload)
        XCTAssertFalse(dvc.handleMultitransport(pdu: [0x30, 2, 9]))
        XCTAssertFalse(dvc.handleMultitransport(pdu: [0x50, 0, 3, 0]))
        dvc.closeChannel(name: DynamicVCManager.graphicsDVCName)
        dvc.createChannel(name: DynamicVCManager.graphicsDVCName)
        dvc.handle(pdu: [0x10, 2, 0, 0, 0, 0])
        XCTAssertNotNil(dvc.sendDataBatch(channelId: 2, payloads: [[8]], priority: .video))
        XCTAssertEqual(tcp.count, 3)
        XCTAssertEqual(udp.count, 1)
    }

    func testSoftSyncResponseValidation() {
        XCTAssertEqual(MultitransportPDU.softSyncResponse([0x90, 0, 1, 0, 0, 0, 1, 0, 0, 0]), [1])
        XCTAssertEqual(MultitransportPDU.softSyncResponse([0x90, 0, 0, 0, 0, 0]), [])
        XCTAssertNil(MultitransportPDU.softSyncResponse([0x90, 0, 2, 0, 0, 0, 1, 0, 0, 0]))
        XCTAssertNil(MultitransportPDU.softSyncResponse([0x91, 0, 0, 0, 0, 0]))
    }

    func testClientMayUseApprovedTunnelForAnotherOpenDVC() {
        let manager = DynamicVCManager()
        manager.send = { _ in }
        manager.handle(pdu: [0x50, 0, 3, 0])
        manager.createChannel(name: "input")
        manager.handle(pdu: [0x10, 1, 0, 0, 0, 0])
        var received: [UInt8] = []
        manager.setDataHandler(channelId: 1) { received = $0 }
        XCTAssertTrue(manager.handleMultitransport(pdu: [0x30, 1, 8, 9]))
        XCTAssertEqual(received, [8, 9])
        XCTAssertFalse(manager.handleMultitransport(pdu: [0x30, 2, 8, 9]))
    }

    func testDVCDecompressionHistoriesRemainIndependentAcrossTransports() {
        let manager = DynamicVCManager()
        var channels: [UInt32: [[UInt8]]] = [:]
        manager.dataRelay = { id, bytes in channels[id, default: []].append(bytes) }
        manager.handle(pdu: [0x70, 1, 0x04] + Array("ABC".utf8))
        manager.handle(pdu: [0x70, 2, 0x04] + Array("DEF".utf8))
        // A distance=3/length=3 match refers to this DVC's previous bytes.
        XCTAssertTrue(manager.handleMultitransport(pdu: [0x70, 1, 0x24, 0x88, 0xC0, 5]))
        XCTAssertEqual(channels[1], [Array("ABC".utf8), Array("ABC".utf8)])
        XCTAssertEqual(channels[2], [Array("DEF".utf8)])
    }

    func testBidirectionalLossReorderingDuplicatesAndSequenceWrap() throws {
        let start: UInt64 = 1_000_000_000
        let a = RDPUDP2Connection(initialSendSequence: 0x1234_FFF9, initialReceiveSequence: 78, mtu: 1232, peerWindow: 1024, now: start)
        let b = RDPUDP2Connection(initialSendSequence: 78, initialReceiveSequence: 0x1234_FFF9, mtu: 1232, peerWindow: 1024, now: start)
        let dataA = (0..<160_000).map { UInt8($0 % 251) }, dataB = (0..<50_000).map { UInt8($0 % 239) }
        let completion = CompletionCounter()
        try a.enqueue(ByteBuffer(bytes: dataA), onSent: { completion.increment() })
        try b.enqueue(ByteBuffer(bytes: dataB), onSent: nil)
        struct Flight { let arrival: UInt64; let toA: Bool; let bytes: [UInt8] }
        var flights: [Flight] = [], toA: [UInt8] = [], toB: [UInt8] = []
        var clock = start, number = 0
        var droppedChannels: Set<String> = []
        for _ in 0..<30_000 {
            let arrivals = flights.filter { $0.arrival <= clock }
            flights.removeAll { $0.arrival <= clock }
            for packet in arrivals {
                let chunks = try (packet.toA ? a : b).receive(packet.bytes, now: clock)
                for chunk in chunks { if packet.toA { toA += chunk } else { toB += chunk } }
            }
            for (source, targetA) in [(a, false), (b, true)] {
                for outgoing in try source.transmit(now: clock) {
                    outgoing.onSent?() // successful local socket write, even if the network drops it
                    number += 1
                    let packet = try RDPUDP2Packet.parse(outgoing.bytes)
                    let key = "\(targetA):\(packet.data?.channelSequence ?? 0)"
                    if packet.data != nil, number % 11 == 1, droppedChannels.insert(key).inserted { continue }
                    if packet.data == nil && number % 19 == 0 { continue }
                    let delay: UInt64 = number % 3 == 0 ? 23_000_000 : 7_000_000
                    flights.append(Flight(arrival: clock + delay, toA: targetA, bytes: outgoing.bytes))
                    if number % 7 == 0 { flights.append(Flight(arrival: clock + 31_000_000, toA: targetA, bytes: outgoing.bytes)) }
                }
            }
            if toA.count == dataB.count, toB.count == dataA.count, a.bufferedBytes == 0, b.bufferedBytes == 0 { break }
            let deadlines = [a.nextDeadline(now: clock), b.nextDeadline(now: clock), flights.map(\.arrival).min()]
            clock = max(clock + 1, deadlines.compactMap { $0 }.min()!)
            if clock - start > 15_000_000_000 { break }
        }
        XCTAssertEqual(toA, dataB)
        XCTAssertEqual(toB, dataA)
        XCTAssertGreaterThan(a.retransmissionCount + b.retransmissionCount, 0)
        XCTAssertEqual(completion.value, 1)
        XCTAssertEqual(a.bufferedBytes, 0)
        XCTAssertEqual(b.bufferedBytes, 0)
    }

    func testReliableChannelWrapSkipsZeroAndPreservesOrderedBytes() throws {
        let sender = RDPUDP2Connection(mtu: 1232, peerWindow: 1024, now: 0)
        let receiver = RDPUDP2Connection(mtu: 1232, peerWindow: 1024, now: 0)
        var clock: UInt64 = 0
        var boundary: [UInt16] = []
        for ordinal in 1...65_540 {
            var bytes: [UInt8] = []
            bytes.appendU32(UInt32(ordinal))
            try sender.enqueue(ByteBuffer(bytes: bytes), onSent: nil)
            let outgoing = try XCTUnwrap(sender.transmit(now: clock).first)
            let packet = try RDPUDP2Packet.parse(outgoing.bytes)
            if ordinal >= 65_534 { boundary.append(try XCTUnwrap(packet.data?.channelSequence)) }
            let delivered = try receiver.receive(outgoing.bytes, now: clock + 500_000)
            XCTAssertEqual(delivered, [bytes])
            // Independent cumulative ACKs keep the test focused on the reliable stream,
            // without injecting the receiver's unrelated idle dummy probes.
            var ack = RDPUDP2Packet()
            ack.ack = .init(sequence: try XCTUnwrap(packet.data?.sequence),
                            timestamp: 0, delayMilliseconds: 0)
            _ = try sender.receive(ack.encode(), now: clock + 750_000)
            clock += 1_000_000
        }
        // MS-RDPEUDP2 3.1.1.2.4.2, Windows behavior: zero is skipped on wrap.
        XCTAssertEqual(boundary, [65_534, 65_535, 1, 2, 3, 4, 5])
        XCTAssertEqual(sender.bufferedBytes, 0)
        var invalid = RDPUDP2Packet()
        invalid.data = .init(sequence: 104, channelSequence: 0, bytes: [0x16])
        XCTAssertThrowsError(try receiver.receive(invalid.encode(), now: clock))
    }

    func testRetransmissionChangesOnlyTransportSequenceAndKeepaliveCannotHideStall() throws {
        let a = RDPUDP2Connection(initialSendSequence: 11, initialReceiveSequence: 21, mtu: 1232, peerWindow: 1024, now: 0)
        try a.enqueue(ByteBuffer(bytes: [1, 2, 3]), onSent: nil)
        let first = try RDPUDP2Packet.parse(XCTUnwrap(a.transmit(now: 0).first?.bytes))
        let retry = try a.transmit(now: 300_000_000).map { try RDPUDP2Packet.parse($0.bytes) }.first { $0.data != nil }
        XCTAssertEqual(retry?.data?.channelSequence, first.data?.channelSequence)
        XCTAssertNotEqual(retry?.data?.sequence, first.data?.sequence)
        var keepalive = RDPUDP2Packet(); keepalive.ackOfAcks = 21
        _ = try a.receive(keepalive.encode(), now: 15_000_000_000)
        XCTAssertThrowsError(try a.transmit(now: 16_000_000_000))
        XCTAssertTrue(a.isClosed)
    }

    func testDummyIsAcknowledgedWithoutConsumingReliableChannel() throws {
        let receiver = RDPUDP2Connection(initialSendSequence: 11, initialReceiveSequence: 21, mtu: 1232, peerWindow: 1024, now: 0)
        var dummy = RDPUDP2Packet(dummy: true)
        dummy.data = .init(sequence: 21, channelSequence: nil, bytes: [])
        XCTAssertTrue(try receiver.receive(dummy.encode(), now: 1).isEmpty)
        var real = RDPUDP2Packet()
        real.data = .init(sequence: 22, channelSequence: 1, bytes: [9])
        XCTAssertEqual(try receiver.receive(real.encode(), now: 2), [[9]])
        let acknowledgements = try receiver.transmit(now: 20_000_000).map { try RDPUDP2Packet.parse($0.bytes) }
        XCTAssertEqual(acknowledgements.first?.ack?.sequence, 22)
    }

    func testIdleDummyProbeMeasuresRTTWithoutReliableDataOrRetransmission() throws {
        let a = RDPUDP2Connection(initialSendSequence: 11, initialReceiveSequence: 21, mtu: 1232, peerWindow: 1024, now: 0)
        let b = RDPUDP2Connection(initialSendSequence: 21, initialReceiveSequence: 11, mtu: 1232, peerWindow: 1024, now: 0)
        let probe = try XCTUnwrap(a.transmit(now: 4_000_000_000).first)
        XCTAssertTrue(try RDPUDP2Packet.parse(probe.bytes).dummy)
        XCTAssertEqual(a.bufferedBytes, 0)
        XCTAssertTrue(try b.receive(probe.bytes, now: 4_010_000_000).isEmpty)
        let ack = try XCTUnwrap(b.transmit(now: 4_020_000_000).first)
        XCTAssertTrue(try a.receive(ack.bytes, now: 4_030_000_000).isEmpty)
        XCTAssertGreaterThan(a.smoothedRTTNanoseconds, 0)
        XCTAssertEqual(a.rttMeasuredAt, 4_030_000_000)

        let dropped = RDPUDP2Connection(initialSendSequence: 11, initialReceiveSequence: 21, mtu: 1232, peerWindow: 1024, now: 0)
        _ = try dropped.transmit(now: 4_000_000_000)
        let afterLoss = try dropped.transmit(now: 4_300_000_000)
        XCTAssertTrue(try afterLoss.allSatisfy { try RDPUDP2Packet.parse($0.bytes).data == nil })
        XCTAssertEqual(dropped.retransmissionCount, 0)
    }

    func testReliableReceiveWindowDoesNotAcknowledgeDiscardedBytes() throws {
        let receiver = RDPUDP2Connection(initialSendSequence: 11, initialReceiveSequence: 21, mtu: 1232, peerWindow: 1024, now: 0)
        var packet = RDPUDP2Packet()
        packet.data = .init(sequence: 21, channelSequence: 1025, bytes: [9])
        XCTAssertTrue(try receiver.receive(packet.encode(), now: 1).isEmpty)
        let ack = try receiver.transmit(now: 1).map { try RDPUDP2Packet.parse($0.bytes) }.first?.ack
        XCTAssertEqual(ack?.sequence, 20)
    }
}

private final class CompletionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
