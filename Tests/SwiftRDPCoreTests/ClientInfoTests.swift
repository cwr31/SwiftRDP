import XCTest
@testable import SwiftRDPCore

final class ClientInfoTests: XCTestCase {
    func testEnhancedSecurityRequiresTheClientInfoHeader() {
        let session = makeTLSSession()
        session.receive(ioPacket(clientInfo()))
        XCTAssertEqual(session.phase, .terminated)
    }

    func testStandardSecurityExchangeIsNotAcceptedUnderTLS() {
        let session = makeTLSSession()
        session.receive(ioPacket([1, 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(session.phase, .terminated)
    }

    func testShareControlLengthIsNeverInterpretedAsSecurityFlags() {
        for length in [0x40, 0x200] {
            let session = sessionAfterClientInfo()
            session.receive(ioPacket(confirmActive(length: length)))
            XCTAssertEqual(session.phase, .connectionFinalization)
        }
    }

    func testShareControlDoesNotAcceptAnExtraSecurityHeader() {
        let session = sessionAfterClientInfo()
        session.receive(ioPacket([0, 0, 0, 0] + confirmActive(length: 64)))
        XCTAssertEqual(session.phase, .capabilities)
    }

    func testUserNameFollowsTheDomainAndItsMandatoryTerminator() {
        XCTAssertEqual(RDPSession.parseClientInfoUserName(clientInfo()), "alice")
        XCTAssertEqual(RDPSession.parseClientInfoUserName(clientInfo(domain: "")), "alice")
    }

    func testUserNameUsesTheDeclaredStringEncoding() {
        XCTAssertEqual(RDPSession.parseClientInfoUserName(clientInfo(unicode: false)), "alice")
    }

    func testTruncatedOrMisalignedUserNameIsRejected() {
        let packet = clientInfo()
        let userEnd = 18 + "DOMAIN".utf16.count * 2 + 2 + "alice".utf16.count * 2 + 2
        for count in 0..<userEnd {
            XCTAssertNil(RDPSession.parseClientInfoUserName(Array(packet.prefix(count))))
        }
        for offset in [8, 10] {
            var oddLength = packet
            oddLength[offset] |= 1
            XCTAssertNil(RDPSession.parseClientInfoUserName(oddLength))
        }
        for offset in [18 + 12, userEnd - 2] {
            var missingTerminator = packet
            missingTerminator[offset] = 1
            XCTAssertNil(RDPSession.parseClientInfoUserName(missingTerminator))
        }
    }

    private func clientInfo(domain: String = "DOMAIN", unicode: Bool = true) -> [UInt8] {
        let strings = [domain, "alice", "", "", ""].map {
            Array($0.data(using: unicode ? .utf16LittleEndian : .ascii)!)
        }
        var packet = ByteWriter.u32(0) + ByteWriter.u32(unicode ? 0x10 : 0)
        for bytes in strings { packet.appendU16(UInt16(bytes.count)) }
        for bytes in strings { packet += bytes + [UInt8](repeating: 0, count: unicode ? 2 : 1) }
        return packet
    }

    private func sessionAfterClientInfo() -> RDPSession {
        let session = makeTLSSession()
        session.receive(ioPacket([0x40, 0, 0, 0] + clientInfo()))
        XCTAssertEqual(session.info.userName, "alice")
        XCTAssertEqual(session.phase, .capabilities)
        return session
    }

    private func makeTLSSession() -> RDPSession {
        let session = RDPSession(config: ServerConfig(nlaEnabled: false))
        let request: [UInt8] = [14, 0xE0, 0, 0, 0, 0, 0, 1, 0, 8, 0]
            + ByteWriter.u32(X224.protocolSSL)
        session.receive(TPKT.wrap(request))
        XCTAssertEqual(session.phase, .tls)
        session.notifyTLSCompleted()
        XCTAssertEqual(session.phase, .basicSettings)
        return session
    }

    private func ioPacket(_ payload: [UInt8]) -> [UInt8] {
        var mcs = MCS.buildSendDataIndication(userId: 1001, channelId: 1003, data: payload)
        mcs[0] = 0x64 // SendDataRequest has the same payload fields as SendDataIndication.
        return X224.buildData(mcs)
    }

    private func confirmActive(length: Int) -> [UInt8] {
        let unknownCapability = ByteWriter.u16(0xFFFF) + ByteWriter.u16(UInt16(length - 20))
            + [UInt8](repeating: 0, count: length - 24)
        return ByteWriter.u16(UInt16(length)) + ByteWriter.u16(0x13) + ByteWriter.u16(1001)
            + ByteWriter.u32(0x10000) + ByteWriter.u16(1001) + ByteWriter.u16(0)
            + ByteWriter.u16(UInt16(length - 16)) + ByteWriter.u16(1) + ByteWriter.u16(0)
            + unknownCapability
    }
}
