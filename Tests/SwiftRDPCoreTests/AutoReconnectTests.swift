import CryptoKit
import XCTest
@testable import SwiftRDPCore

final class AutoReconnectTests: XCTestCase {
    func testTLSVerifierAuthenticatesOriginalUserAndRejectsRawCookie() throws {
        let manager = try makeTestSessionManager(config: ServerConfig())
        let session = promoteSession(userName: "alice", manager: manager)
        let issued = try XCTUnwrap(manager.issueAutoReconnectCookie(for: session, nowNanoseconds: 1))
        let verifier = tlsVerifier(issued.cookie)
        XCTAssertEqual(manager.validateAutoReconnect(logonID: issued.logonId,
            securityVerifier: verifier, nowNanoseconds: 2), "alice")
        XCTAssertNil(manager.validateAutoReconnect(logonID: issued.logonId,
            securityVerifier: issued.cookie, nowNanoseconds: 2))
        var damaged = verifier
        damaged[0] ^= 1
        XCTAssertNil(manager.validateAutoReconnect(logonID: issued.logonId,
            securityVerifier: damaged, nowNanoseconds: 2))
        XCTAssertNil(manager.validateAutoReconnect(logonID: issued.logonId + 1,
            securityVerifier: verifier, nowNanoseconds: 2))
    }

    func testCookieRotationExpiresPreviousCredentialAndKeepsReconnectSessionID() throws {
        let manager = try makeTestSessionManager(config: ServerConfig())
        let session = promoteSession(userName: "alice", manager: manager)
        let initial = try XCTUnwrap(manager.issueAutoReconnectCookie(for: session, nowNanoseconds: 1))
        session.info.logonId = initial.logonId
        let rotated = try XCTUnwrap(manager.issueAutoReconnectCookie(for: session, nowNanoseconds: 2))
        XCTAssertEqual(initial.logonId, rotated.logonId)
        XCTAssertNotEqual(initial.cookie, rotated.cookie)
        XCTAssertNil(manager.validateAutoReconnect(logonID: initial.logonId,
            securityVerifier: tlsVerifier(initial.cookie), nowNanoseconds: 3))
        XCTAssertEqual(manager.validateAutoReconnect(logonID: rotated.logonId,
            securityVerifier: tlsVerifier(rotated.cookie), nowNanoseconds: 3), "alice")
        XCTAssertNil(manager.validateAutoReconnect(logonID: rotated.logonId,
            securityVerifier: tlsVerifier(rotated.cookie), nowNanoseconds: 3_600_000_000_002))

        let replacement = promoteSession(userName: "bob", manager: manager)
        let current = try XCTUnwrap(manager.issueAutoReconnectCookie(for: replacement, nowNanoseconds: 4))
        XCTAssertNil(manager.validateAutoReconnect(logonID: rotated.logonId,
            securityVerifier: tlsVerifier(rotated.cookie), nowNanoseconds: 5))
        // An old loop finishing activation cannot overwrite the replacement's credential.
        XCTAssertNil(manager.issueAutoReconnectCookie(for: session, nowNanoseconds: 6))
        XCTAssertEqual(manager.validateAutoReconnect(logonID: current.logonId,
            securityVerifier: tlsVerifier(current.cookie), nowNanoseconds: 7), "bob")
    }

    func testParserUsesCookieFieldAndIgnoresSignatureInsideTimeZone() throws {
        let packet = clientPacket(logonID: 42)
        let info = clientInfo(packet: packet, timeZonePrefix: clientPacket(logonID: 99))
        let decoded = try XCTUnwrap(AutoReconnectPDU.parseClientPacket(fromClientInfo: info))
        XCTAssertEqual(decoded.logonID, 42)
        XCTAssertEqual(decoded.securityVerifier, Array(0..<16))
    }

    func testParserRejectsEveryTruncatedCookieAndInconsistentLength() {
        let complete = clientInfo(packet: clientPacket(logonID: 42))
        for count in 0..<complete.count {
            XCTAssertNil(AutoReconnectPDU.parseClientPacket(fromClientInfo: Array(complete.prefix(count))))
        }
        XCTAssertNil(AutoReconnectPDU.parseClientPacket(
            fromClientInfo: clientInfo(packet: clientPacket(logonID: 42), cookieLength: 0)))
        XCTAssertNil(AutoReconnectPDU.parseClientPacket(
            fromClientInfo: clientInfo(packet: clientPacket(logonID: 42), cookieLength: 27)))
        var wrongVersion = clientPacket(logonID: 42)
        wrongVersion[4] = 2
        XCTAssertNil(AutoReconnectPDU.parseClientPacket(fromClientInfo: clientInfo(packet: wrongVersion)))
    }

    private func tlsVerifier(_ random: [UInt8]) -> [UInt8] {
        Array(HMAC<Insecure.MD5>.authenticationCode(for: Data(repeating: 0, count: 32),
            using: SymmetricKey(data: Data(random))))
    }

    private func promoteSession(userName: String, manager: SessionManager) -> RDPSession {
        let session = RDPSession(config: ServerConfig())
        session.info.userName = userName
        XCTAssertTrue(manager.registerSession(session))
        XCTAssertTrue(manager.promoteSession(session))
        return session
    }

    private func clientPacket(logonID: UInt32) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.appendU32(28)
        bytes.appendU32(1)
        bytes.appendU32(logonID)
        return bytes + Array(0..<16)
    }

    private func clientInfo(packet: [UInt8], timeZonePrefix: [UInt8] = [], cookieLength: UInt16 = 28) -> [UInt8] {
        let strings = ["", "alice", "", "", ""].map { Array($0.data(using: .utf16LittleEndian)!) }
        var bytes: [UInt8] = []
        bytes.appendU32(0)
        bytes.appendU32(0x10) // INFO_UNICODE without INFO_MOUSE
        for string in strings { bytes.appendU16(UInt16(string.count)) }
        for string in strings { bytes += string + [0, 0] }
        bytes.appendU16(2) // IPv4
        let address = Array("127.0.0.1".data(using: .utf16LittleEndian)!) + [0, 0]
        bytes.appendU16(UInt16(address.count))
        bytes += address
        bytes.appendU16(2)
        bytes += [0, 0] // empty client directory
        bytes += timeZonePrefix + [UInt8](repeating: 0, count: 172 - timeZonePrefix.count)
        bytes.appendU32(0) // clientSessionId
        bytes.appendU32(0) // performanceFlags
        bytes.appendU16(cookieLength)
        return bytes + packet
    }
}
