import CryptoKit
import XCTest
@testable import SwiftRDPCore

final class CredSSPTests: XCTestCase {
    func testChangingPasswordRejectsThePreviousCredentialForTheSameUser() throws {
        let original = try CredSSPPeer(serverPassword: "previous-password")
        _ = try original.server.handle(clientData: original.authenticationRequest().encode())

        let stale = try CredSSPPeer(serverPassword: "new-password", clientPassword: "previous-password")
        XCTAssertThrowsError(try stale.server.handle(clientData: stale.authenticationRequest().encode())) {
            XCTAssertEqual($0 as? CredSSP.CredSSPError, .authFailed)
        }

        let current = try CredSSPPeer(serverPassword: "new-password")
        _ = try current.server.handle(clientData: current.authenticationRequest().encode())
        let final = try current.server.handle(clientData: current.credentialsRequest().encode())
        XCTAssertTrue(final.done)
        XCTAssertEqual(current.server.state, .authenticated)
    }

    func testTSRequestEncodesLogonFailureErrorCode() throws {
        let req = TSRequest(
            version: 6,
            negoTokens: nil,
            authInfo: nil,
            pubKeyAuth: nil,
            errorCode: CredSSP.statusLogonFailure,
            nonce: nil
        )
        let encoded = req.encode()
        // ASN.1 INTEGER for 0xC000006D is 02 04 C0 00 00 6D
        let marker: [UInt8] = [0x02, 0x04, 0xC0, 0x00, 0x00, 0x6D]
        XCTAssertTrue(
            encoded.windows(ofCount: marker.count).contains(where: { Array($0) == marker }),
            "encoded=\(encoded.map { String(format: "%02x", $0) }.joined())"
        )

        let parsed = try TSRequest.parse(encoded)
        XCTAssertEqual(parsed.version, 6)
        XCTAssertEqual(parsed.errorCode, CredSSP.statusLogonFailure)
        XCTAssertNil(parsed.negoTokens)
        XCTAssertNil(parsed.pubKeyAuth)
    }

    func testEncodeErrorResponseForVersion6() throws {
        let ntlm = NTLMServer(username: "user", password: "password", domain: "", serverName: "SwiftRDP")
        let credSSP = CredSSP(ntlm: ntlm, serverPublicKeyDER: Array(repeating: 0x01, count: 32))
        let bytes = credSSP.encodeErrorResponse(ntStatus: CredSSP.statusLogonFailure)
        let parsed = try TSRequest.parse(bytes)
        XCTAssertEqual(parsed.errorCode, CredSSP.statusLogonFailure)
        XCTAssertEqual(parsed.version, 6)
    }

    func testModernHandshakeVerifiesBothBindingsBeforeAcceptingCredentials() throws {
        let peer = try CredSSPPeer()
        let response = try peer.server.handle(clientData: peer.authenticationRequest().encode())
        XCTAssertFalse(response.done)
        XCTAssertEqual(peer.server.state, .waitingClientFinal)
        let request = try TSRequest.parse(response.response)
        XCTAssertEqual(request.version, 6)
        XCTAssertNil(request.nonce)
        let serverSeal = CredSSPSeal(key: peer.sessionKey, direction: "server-to-client")
        let serverBinding = try XCTUnwrap(serverSeal.open(try XCTUnwrap(request.pubKeyAuth)))
        let expected = Array(SHA256.hash(data: Data(
            Array("CredSSP Server-To-Client Binding Hash\0".utf8) + peer.nonce + peer.publicKey
        )))
        XCTAssertEqual(serverBinding, expected)

        let final = try peer.server.handle(clientData: peer.credentialsRequest().encode())
        XCTAssertTrue(final.done)
        XCTAssertTrue(final.response.isEmpty)
        XCTAssertEqual(peer.server.state, .authenticated)
    }

    func testObsoleteVersionsAreRejectedWithNotSupportedStatus() throws {
        for version in 0...5 {
            let ntlm = NTLMServer(username: "alice", password: "test-password")
            let server = CredSSP(ntlm: ntlm, serverPublicKeyDER: [1])
            let request = TSRequest(version: version, negoTokens: CredSSPPeer.negotiate,
                authInfo: nil, pubKeyAuth: nil, errorCode: nil, nonce: nil)
            XCTAssertThrowsError(try server.handle(clientData: request.encode())) { error in
                XCTAssertEqual(error as? CredSSP.CredSSPError, .unsupportedVersion)
                XCTAssertEqual(CredSSP.ntStatus(for: error), CredSSP.statusNotSupported)
            }
            XCTAssertEqual(server.state, .failed)
        }
    }

    func testValidNonceMayBePresentInEveryModernHandshakeMessage() throws {
        let peer = try CredSSPPeer(repeatNonce: true)
        _ = try peer.server.handle(clientData: peer.authenticationRequest().encode())
        let final = try peer.server.handle(clientData: peer.credentialsRequest().encode())
        XCTAssertTrue(final.done)
        XCTAssertEqual(peer.server.state, .authenticated)
    }

    func testFinalMessageCannotReplaceTheVerifiedNonce() throws {
        let peer = try CredSSPPeer(repeatNonce: true)
        _ = try peer.server.handle(clientData: peer.authenticationRequest().encode())
        var final = peer.credentialsRequest()
        final.nonce![0] ^= 1
        XCTAssertThrowsError(try peer.server.handle(clientData: final.encode()))
        XCTAssertEqual(peer.server.state, .failed)
    }

    func testMissingOrInvalidNonceCannotCompleteAuthentication() throws {
        let nonces: [[UInt8]?] = [nil, [], [UInt8](repeating: 1, count: 31), [UInt8](repeating: 1, count: 33)]
        for nonce in nonces {
            let peer = try CredSSPPeer()
            var request = peer.authenticationRequest()
            request.nonce = nonce
            XCTAssertThrowsError(try peer.server.handle(clientData: request.encode())) { error in
                XCTAssertEqual(error as? CredSSP.CredSSPError, .pubKeyAuthFailed)
            }
            XCTAssertEqual(peer.server.state, .failed)
        }
    }

    func testMissingOrCorruptedBindingCannotCompleteAuthentication() throws {
        for mutation in 0..<3 {
            let peer = try CredSSPPeer()
            var request = peer.authenticationRequest()
            switch mutation {
            case 0: request.pubKeyAuth = nil
            case 1: request.pubKeyAuth = []
            default: request.pubKeyAuth![16] ^= 1
            }
            XCTAssertThrowsError(try peer.server.handle(clientData: request.encode())) { error in
                XCTAssertEqual(error as? CredSSP.CredSSPError, .pubKeyAuthFailed)
            }
            XCTAssertEqual(peer.server.state, .failed)
        }
    }

    func testBindingIsBoundToTheActualNonceAndCertificate() throws {
        for changeCertificate in [false, true] {
            let peer = try CredSSPPeer()
            var request = peer.authenticationRequest(bindingKey: changeCertificate ? [0xFF] : nil)
            if !changeCertificate { request.nonce![0] ^= 1 }
            XCTAssertThrowsError(try peer.server.handle(clientData: request.encode())) { error in
                XCTAssertEqual(error as? CredSSP.CredSSPError, .pubKeyAuthFailed)
            }
        }
    }

    func testCredentialsCannotSkipTheBindingStepOrDowngradeTheVersion() throws {
        let early = try CredSSPPeer()
        XCTAssertThrowsError(try early.server.handle(clientData: early.credentialsRequest().encode()))
        XCTAssertEqual(early.server.state, .failed)

        let downgrade = try CredSSPPeer()
        _ = try downgrade.server.handle(clientData: downgrade.authenticationRequest().encode())
        var final = downgrade.credentialsRequest()
        final.version = 4
        XCTAssertThrowsError(try downgrade.server.handle(clientData: final.encode())) { error in
            XCTAssertEqual(error as? CredSSP.CredSSPError, .unsupportedVersion)
        }
        XCTAssertEqual(downgrade.server.state, .failed)
    }

    func testFailedHandshakeCannotRestartWithAnotherNegotiate() throws {
        let peer = try CredSSPPeer()
        XCTAssertThrowsError(try peer.server.handle(clientData: [0]))
        let request = TSRequest(version: 6, negoTokens: CredSSPPeer.negotiate,
            authInfo: nil, pubKeyAuth: nil, errorCode: nil, nonce: nil)
        XCTAssertThrowsError(try peer.server.handle(clientData: request.encode())) { error in
            XCTAssertEqual(error as? CredSSP.CredSSPError, .unexpectedState)
        }
    }

    func testTSRequestRejectsMalformedASN1InsteadOfTreatingItAsRawFields() {
        let version = BER.encodeContext(0, contents: BER.encodeInteger(6))
        let malformed: [[UInt8]] = [
            CredSSPPeer.negotiate,
            BER.encodeSequence([]),
            BER.encodeSequence(BER.encodeContext(0, contents: [6])),
            BER.encodeSequence(version + version),
            BER.encodeSequence(version + BER.encodeContext(2, contents: [1, 2, 3])),
            BER.encodeSequence(version + BER.encodeContext(1, contents: BER.encodeOctetString([1]))),
            BER.encodeSequence(version + [0xA5, 3, 0x04, 2, 1]),
            BER.encodeSequence(version) + [0],
            [0x30, 0x80],
            [0x30, 0x89] + [UInt8](repeating: 0, count: 9),
        ]
        for packet in malformed {
            XCTAssertThrowsError(try TSRequest.parse(packet)) { error in
                XCTAssertEqual(error as? CredSSP.CredSSPError, .parseFailed)
            }
        }
    }

    func testTLSFragmentedTSRequestWaitsForACompleteMessage() throws {
        let session = makeNLASession()
        var writes = 0
        session.socket.onWriteBatch = { packets, _, _ in
            writes += packets.count
            return true
        }
        let request = TSRequest(version: 6, negoTokens: CredSSPPeer.negotiate,
            authInfo: nil, pubKeyAuth: nil, errorCode: nil, nonce: nil).encode()
        session.receive(Array(request.prefix(2)))
        XCTAssertEqual(session.phase, .credssp)
        XCTAssertEqual(writes, 0)
        session.receive(Array(request.dropFirst(2)))
        XCTAssertEqual(session.phase, .credssp)
        XCTAssertEqual(writes, 1)
    }

    func testRawNTLMAndInvalidASN1FramingCloseNLASession() {
        for packet in [CredSSPPeer.negotiate, [0x30, 0x80], [0x30, 0x89]] {
            let session = makeNLASession()
            var closes = 0
            session.onClose = { closes += 1 }
            session.receive(packet)
            XCTAssertEqual(session.phase, .terminated)
            XCTAssertEqual(closes, 1)
        }
    }

    func testNLARequiredServerRejectsTLSOnlyNegotiation() {
        let session = RDPSession(config: ServerConfig())
        var writes: [[UInt8]] = []
        session.socket.onWriteBatch = { packets, _, _ in
            writes.append(contentsOf: packets)
            return true
        }
        let request: [UInt8] = [14, 0xE0, 0, 0, 0, 0, 0, 1, 0, 8, 0]
            + ByteWriter.u32(X224.protocolSSL)
        session.receive(TPKT.wrap(request))
        XCTAssertEqual(session.phase, .terminated)
        XCTAssertEqual(writes, [X224.buildNegotiationFailure(failureCode: X224.failureHybridRequiredByServer)])
    }

    private func makeNLASession() -> RDPSession {
        let session = RDPSession(config: ServerConfig(), serverPublicKeyDER: [1])
        let request: [UInt8] = [14, 0xE0, 0, 0, 0, 0, 0, 1, 0, 8, 0]
            + ByteWriter.u32(X224.protocolHybrid)
        session.receive(TPKT.wrap(request))
        session.notifyTLSCompleted()
        XCTAssertEqual(session.phase, .credssp)
        return session
    }
}

private final class CredSSPPeer {
    static let negotiate = Array("NTLMSSP\0".utf8) + ByteWriter.u32(1)
        + ByteWriter.u32(0x2008_0031) + [UInt8](repeating: 0, count: 16)
    let publicKey: [UInt8] = Array(1...32)
    let nonce: [UInt8] = Array(32...63)
    let server: CredSSP
    let sessionKey: [UInt8]
    private let authenticate: [UInt8]
    private let seal: CredSSPSeal
    private let repeatNonce: Bool
    private let password: String

    init(
        repeatNonce: Bool = false,
        serverPassword: String = "test-password",
        clientPassword: String? = nil
    ) throws {
        self.repeatNonce = repeatNonce
        self.password = clientPassword ?? serverPassword
        let ntlm = NTLMServer(username: "alice", password: serverPassword)
        server = CredSSP(ntlm: ntlm, serverPublicKeyDER: publicKey)
        _ = try server.handle(clientData: TSRequest(version: 6, negoTokens: Self.negotiate,
            authInfo: nil, pubKeyAuth: nil, errorCode: nil, nonce: repeatNonce ? nonce : nil).encode())
        let user = Array("alice".data(using: .utf16LittleEndian)!)
        let identity = Array("ALICE".data(using: .utf16LittleEndian)!)
        let hash = NTLMServer.ntHash(password: password)
        let responseKey = Self.hmac(key: hash, data: identity)
        let blob: [UInt8] = [1, 1, 0, 0] + [UInt8](repeating: 0, count: 28)
        let proof = Self.hmac(key: responseKey, data: ntlm.serverChallenge + blob)
        sessionKey = Self.hmac(key: responseKey, data: proof)
        seal = CredSSPSeal(key: sessionKey, direction: "client-to-server")
        var token = [UInt8](repeating: 0, count: 88)
        token.replaceSubrange(0..<8, with: Array("NTLMSSP\0".utf8))
        token.replaceSubrange(8..<12, with: ByteWriter.u32(3))
        token.replaceSubrange(60..<64, with: ByteWriter.u32(0x2008_0031))
        for (offset, bytes) in [(12, []), (20, proof + blob), (28, []), (36, user), (44, []), (52, [])] {
            let field = ByteWriter.u16(UInt16(bytes.count)) + ByteWriter.u16(UInt16(bytes.count))
                + ByteWriter.u32(UInt32(token.count))
            token.replaceSubrange(offset..<(offset + 8), with: field)
            token += bytes
        }
        authenticate = token
    }

    func authenticationRequest(bindingKey: [UInt8]? = nil) -> TSRequest {
        let binding = Array(SHA256.hash(data: Data(
            Array("CredSSP Client-To-Server Binding Hash\0".utf8) + nonce + (bindingKey ?? publicKey)
        )))
        return TSRequest(version: 6, negoTokens: authenticate, authInfo: nil,
            pubKeyAuth: seal.seal(binding), errorCode: nil, nonce: nonce)
    }

    func credentialsRequest() -> TSRequest {
        let password = BER.encodeSequence(
            BER.encodeContext(0, contents: BER.encodeOctetString([]))
            + BER.encodeContext(1, contents: BER.encodeOctetString(Array("alice".data(using: .utf16LittleEndian)!)))
            + BER.encodeContext(2, contents: BER.encodeOctetString(Array(self.password.data(using: .utf16LittleEndian)!)))
        )
        let credentials = BER.encodeSequence(BER.encodeContext(0, contents: BER.encodeInteger(1))
            + BER.encodeContext(1, contents: BER.encodeOctetString(password)))
        return TSRequest(version: 6, negoTokens: nil, authInfo: seal.seal(credentials),
            pubKeyAuth: nil, errorCode: nil, nonce: repeatNonce ? nonce : nil)
    }

    static func hmac(key: [UInt8], data: [UInt8]) -> [UInt8] {
        Array(HMAC<Insecure.MD5>.authenticationCode(for: Data(data), using: SymmetricKey(data: Data(key))))
    }
}

private final class CredSSPSeal {
    private let signingKey: [UInt8]
    private let rc4: StatefulRC4
    private var sequence: UInt32 = 0

    init(key: [UInt8], direction: String) {
        signingKey = Array(Insecure.MD5.hash(data: Data(key
            + Array("session key to \(direction) signing key magic constant\0".utf8))))
        let sealingKey = Array(Insecure.MD5.hash(data: Data(key
            + Array("session key to \(direction) sealing key magic constant\0".utf8))))
        rc4 = StatefulRC4(key: sealingKey)
    }

    func seal(_ plain: [UInt8]) -> [UInt8] {
        let seq = ByteWriter.u32(sequence)
        sequence &+= 1
        let digest = CredSSPPeer.hmac(key: signingKey, data: seq + plain)
        let cipher = rc4.crypt(plain)
        return ByteWriter.u32(1) + rc4.crypt(Array(digest.prefix(8))) + seq + cipher
    }

    func open(_ sealed: [UInt8]) -> [UInt8]? {
        guard sealed.count > 16 else { return nil }
        let plain = rc4.crypt(Array(sealed.dropFirst(16)))
        let digest = CredSSPPeer.hmac(key: signingKey, data: Array(sealed[12..<16]) + plain)
        let checksum = rc4.crypt(Array(digest.prefix(8)))
        return checksum == Array(sealed[4..<12]) ? plain : nil
    }
}

private extension Array {
    func windows(ofCount n: Int) -> [ArraySlice<Element>] {
        guard n > 0, count >= n else { return [] }
        return (0...(count - n)).map { self[$0..<($0 + n)] }
    }
}
