import XCTest
@testable import SwiftRDPCore

final class MCSTests: XCTestCase {
    func testDomainChoicesHaveOneDispatchPath() {
        for first in UInt8.min...UInt8.max {
            let packet: [UInt8] = [first, 0, 1, 0x03, 0xEB, 0x70, 3, 0xAA, 0xBB, 0xCC]
            let parsed = MCS.parseDomainPDU(packet)
            switch first >> 2 {
            case MCS.erectDomainRequest:
                guard case .erectDomain? = parsed else { return XCTFail("Missing ErectDomain") }
                XCTAssertEqual(MCS.domainPDULength(packet), 5)
            case MCS.attachUserRequest:
                guard case .attachUserRequest? = parsed else { return XCTFail("Missing AttachUser") }
                XCTAssertEqual(MCS.domainPDULength(packet), 1)
            case MCS.channelJoinRequest:
                guard case .channelJoinRequest(let user, let channel)? = parsed else {
                    return XCTFail("Missing ChannelJoin")
                }
                XCTAssertEqual(user, 1002)
                XCTAssertEqual(channel, 1003)
                XCTAssertEqual(MCS.domainPDULength(packet), 5)
            case MCS.sendDataRequest:
                guard case .sendDataRequest(_, let channel, let data)? = parsed else {
                    return XCTFail("Missing SendData")
                }
                XCTAssertEqual(channel, 1003)
                XCTAssertEqual(data, [0xAA, 0xBB, 0xCC])
                XCTAssertEqual(MCS.domainPDULength(packet), 10)
            case MCS.disconnectProviderUltimatum:
                guard case .disconnect? = parsed else { return XCTFail("Missing Disconnect") }
                XCTAssertEqual(MCS.domainPDULength(packet), packet.count)
            default:
                XCTAssertNil(parsed)
                XCTAssertNil(MCS.domainPDULength(packet))
            }
        }
    }

    func testTruncatedJoinAndSendDataAreRejected() {
        let join: [UInt8] = [0x38, 0, 1, 3, 0xEB]
        for count in 0..<join.count { XCTAssertNil(MCS.parseDomainPDU(Array(join.prefix(count)))) }
        let send: [UInt8] = [0x64, 0, 1, 3, 0xEB, 0x70, 3, 1, 2, 3]
        for count in 0..<send.count { XCTAssertNil(MCS.parseDomainPDU(Array(send.prefix(count)))) }
    }
}
