import Foundation
import CryptoKit

/// CredSSP TSRequest server (MS-CSSP) for NLA — aligned with log phases / pubKeyAuth binding.
public final class CredSSP {
    public enum State {
        case idle
        case challengeSent
        case waitingClientFinal
        case authenticated
        case failed
    }

    /// NTSTATUS for bad username/password ([MS-ERREF]).
    public static let statusLogonFailure: UInt32 = 0xC000_006D
    /// NTSTATUS when CredSSP version / feature is unsupported.
    public static let statusNotSupported: UInt32 = 0xC000_00BB

    private let ntlm: NTLMServer
    private let serverPublicKeyDER: [UInt8]
    public private(set) var state: State = .idle
    private var clientVersion = 6
    private var clientNonce: [UInt8]?
    /// MS-CSSP: client pubKeyAuth must verify before authentication completes (version ≥ 5).
    private var clientPubKeyAuthVerified = false

    private static let clientMagic = Array("CredSSP Client-To-Server Binding Hash".utf8) + [0]
    private static let serverMagic = Array("CredSSP Server-To-Client Binding Hash".utf8) + [0]

    public init(ntlm: NTLMServer, serverPublicKeyDER: [UInt8]) {
        self.ntlm = ntlm
        self.serverPublicKeyDER = serverPublicKeyDER
    }

    /// MS-CSSP: versions 3, 4, and ≥6 carry `errorCode` so the client can fail immediately.
    public static func supportsErrorCode(version: Int) -> Bool {
        version == 3 || version == 4 || version >= 6
    }

    /// Build a failure `TSRequest` with NTSTATUS `errorCode` when the peer version supports it.
    public func encodeErrorResponse(ntStatus: UInt32 = CredSSP.statusLogonFailure) -> [UInt8]? {
        guard Self.supportsErrorCode(version: clientVersion) else { return nil }
        return TSRequest(
            version: min(clientVersion, 6),
            negoTokens: nil,
            authInfo: nil,
            pubKeyAuth: nil,
            errorCode: ntStatus,
            nonce: nil
        ).encode()
    }

    /// Map CredSSP failures to NTSTATUS for the error `TSRequest`.
    public static func ntStatus(for error: Error) -> UInt32 {
        switch error as? CredSSPError {
        case .authFailed, .pubKeyAuthFailed:
            return statusLogonFailure
        case .parseFailed, .unexpectedState, .none:
            return statusLogonFailure
        }
    }

    /// Feed raw TLS application data; return response bytes to send (may be empty).
    public func handle(clientData: [UInt8]) throws -> (response: [UInt8], done: Bool) {
        if state == .idle {
            RDPLog.auth.info("CredSSP: Starting NLA handshake")
        } else {
            RDPLog.auth.info("CredSSP: continue state=\(state) in=\(clientData.count)B")
        }
        guard let ts = try? TSRequest.parse(clientData) else {
            if clientData.starts(with: Array("NTLMSSP\0".utf8)) {
                return try handleNTLMToken(clientData)
            }
            RDPLog.auth.error("CredSSP: failed to parse initial TSRequest")
            throw CredSSPError.parseFailed
        }
        clientVersion = ts.version
        RDPLog.auth.info("CredSSP: Client version=\(ts.version) nego=\(ts.negoTokens?.count ?? 0) authInfo=\(ts.authInfo?.count ?? 0) pubKeyAuth=\(ts.pubKeyAuth?.count ?? 0) nonce=\(ts.nonce?.count ?? 0) spki=\(serverPublicKeyDER.count)")

        if let nonce = ts.nonce, nonce.count == 32 {
            clientNonce = nonce
        }

        if let token = ts.negoTokens, !token.isEmpty {
            // server order: finish NTLM Authenticate, verify client pubKeyAuth, then send server pubKeyAuth.
            return try handleNTLMToken(
                token,
                clientVersion: ts.version,
                clientNonce: ts.nonce,
                clientPubKeyAuth: ts.pubKeyAuth
            )
        }

        // Final CredSSP messages after NTLM Authenticate (pubKeyAuth / authInfo)
        if state == .waitingClientFinal {
            if let pub = ts.pubKeyAuth, !pub.isEmpty {
                guard verifyClientPubKeyAuth(pub) else {
                    state = .failed
                    throw CredSSPError.pubKeyAuthFailed
                }
                clientPubKeyAuthVerified = true
                RDPLog.auth.info("CredSSP: Client pubKeyAuth verified")
            }
            if let auth = ts.authInfo, !auth.isEmpty {
                guard ntlm.decryptMessage(auth) != nil else {
                    state = .failed
                    RDPLog.auth.error("CredSSP: failed to decrypt authInfo (len=\(auth.count))")
                    throw CredSSPError.authFailed
                }
                if clientVersion >= 5, !clientPubKeyAuthVerified {
                    state = .failed
                    throw CredSSPError.pubKeyAuthFailed
                }
                RDPLog.auth.info("CredSSP: Received credentials for user=\(ntlm.authenticatedUser)")
                state = .authenticated
                RDPLog.auth.info("CredSSP: Authentication successful for user=\(ntlm.authenticatedUser)")
                // No TSRequest response after authInfo — NLA ends, MCS begins.
                return ([], true)
            }
            // pubKeyAuth alone: wait for authInfo.
            return ([], false)
        }

        throw CredSSPError.unexpectedState
    }

    private func handleNTLMToken(
        _ token: [UInt8],
        clientVersion: Int = 6,
        clientNonce: [UInt8]? = nil,
        clientPubKeyAuth: [UInt8]? = nil
    ) throws -> (response: [UInt8], done: Bool) {
        guard token.count >= 12 else { throw CredSSPError.parseFailed }
        let msgType = UInt32(token[8]) | UInt32(token[9]) << 8 | UInt32(token[10]) << 16 | UInt32(token[11]) << 24
        switch msgType {
        case 1: // NEGOTIATE
            let challenge = try ntlm.processNegotiate(token)
            state = .challengeSent
            RDPLog.auth.info("CredSSP: Sent NTLM Challenge")
            let resp = TSRequest(
                version: clientVersion,
                negoTokens: challenge,
                authInfo: nil,
                pubKeyAuth: nil,
                errorCode: nil,
                nonce: nil
            ).encode()
            return (resp, false)

        case 3: // AUTHENTICATE
            let ok = try ntlm.processAuthenticate(token)
            if !ok {
                state = .failed
                throw CredSSPError.authFailed
            }
            if let clientNonce { self.clientNonce = clientNonce }

            // Client (version ≥5) typically sends pubKeyAuth with Authenticate.
            if let pub = clientPubKeyAuth, !pub.isEmpty {
                guard verifyClientPubKeyAuth(pub) else {
                    state = .failed
                    throw CredSSPError.pubKeyAuthFailed
                }
                clientPubKeyAuthVerified = true
                RDPLog.auth.info("CredSSP: Client pubKeyAuth verified")
            } else {
                RDPLog.auth.debug("CredSSP: Authenticate without client pubKeyAuth (will wait)")
            }

            let pubKeyAuth = buildServerPubKeyAuth(version: clientVersion)
            guard !pubKeyAuth.isEmpty else {
                state = .failed
                throw CredSSPError.authFailed
            }
            state = .waitingClientFinal
            RDPLog.auth.info("CredSSP: Sent server pubKeyAuth (\(pubKeyAuth.count) bytes)")
            let resp = TSRequest(
                version: min(clientVersion, 6),
                negoTokens: nil,
                authInfo: nil,
                pubKeyAuth: pubKeyAuth,
                errorCode: nil,
                nonce: nil
            ).encode()
            // Wait for client authInfo before finishing NLA.
            return (resp, false)

        default:
            throw CredSSPError.unexpectedState
        }
    }

    private func buildServerPubKeyAuth(version: Int) -> [UInt8] {
        let sessionKey = ntlm.exportedSessionKey
        guard sessionKey.count >= 16 else {
            RDPLog.auth.debug("CredSSP: no session key for pubKeyAuth")
            return []
        }
        let plaintext: [UInt8]
        if version >= 5 {
            let nonce = clientNonce ?? [UInt8](repeating: 0, count: 32)
            plaintext = sha256(Self.serverMagic + nonce + serverPublicKeyDER)
        } else {
            var key = serverPublicKeyDER
            if !key.isEmpty { key[0] = key[0] &+ 1 }
            plaintext = key
        }
        // MS-CSSP: pubKeyAuth = NTLM EncryptMessage(plaintext)
        guard let sealed = ntlm.encryptMessage(plaintext) else {
            RDPLog.auth.error("CredSSP: NTLM session key computation failed — wrong password")
            return []
        }
        return sealed
    }

    private func verifyClientPubKeyAuth(_ encrypted: [UInt8]) -> Bool {
        guard !encrypted.isEmpty else { return false }
        guard let plain = ntlm.decryptMessage(encrypted) else {
            RDPLog.auth.error("CredSSP: failed to decrypt client pubKeyAuth (len=\(encrypted.count))")
            return false
        }
        let ok = verifyPubKeyPlaintext(plain)
        if !ok {
            RDPLog.auth.error("CredSSP: pubKeyAuth plaintext mismatch (plain=\(plain.count) key=\(serverPublicKeyDER.count) nonce=\(clientNonce?.count ?? 0) ver=\(clientVersion))")
        }
        return ok
    }

    private func verifyPubKeyPlaintext(_ plain: [UInt8]) -> Bool {
        if clientVersion >= 5 {
            let nonce = clientNonce ?? [UInt8](repeating: 0, count: 32)
            let expected = sha256(Self.clientMagic + nonce + serverPublicKeyDER)
            return plain == expected
        } else {
            var key = serverPublicKeyDER
            if !key.isEmpty { key[0] = key[0] &+ 1 }
            return plain == key
        }
    }

    private func sha256(_ data: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: Data(data)))
    }

    public enum CredSSPError: Error {
        case parseFailed
        case unexpectedState
        case authFailed
        case pubKeyAuthFailed
    }
}

/// TSRequest ASN.1 SEQUENCE { version, negoTokens, authInfo, pubKeyAuth, errorCode, nonce }
struct TSRequest {
    var version: Int
    var negoTokens: [UInt8]?
    var authInfo: [UInt8]?
    var pubKeyAuth: [UInt8]?
    /// NTSTATUS failure code ([MS-CSSP] errorCode [4]); server → client on SPNEGO failure.
    var errorCode: UInt32?
    var nonce: [UInt8]?

    static func parse(_ data: [UInt8]) throws -> TSRequest {
        var o = 0
        guard data.count > 2, data[0] == 0x30 else { throw CredSSP.CredSSPError.parseFailed }
        o = 1
        guard let _ = BER.decodeLength(data, offset: &o) else { throw CredSSP.CredSSPError.parseFailed }

        var version = 6
        var nego: [UInt8]?
        var auth: [UInt8]?
        var pub: [UInt8]?
        var errorCode: UInt32?
        var nonce: [UInt8]?

        while o < data.count {
            let tag = data[o]
            o += 1
            guard let len = BER.decodeLength(data, offset: &o) else { break }
            guard o + len <= data.count else { break }
            let content = Array(data[o..<(o + len)])
            o += len
            let ctx = tag & 0x1F
            switch ctx {
            case 0:
                // INTEGER may be raw bytes or wrapped as 02 Len Value
                if content.count >= 3, content[0] == 0x02 {
                    var io = 1
                    if let ilen = BER.decodeLength(content, offset: &io), io + ilen <= content.count {
                        version = content[io..<(io + ilen)].reduce(0) { ($0 << 8) | Int($1) }
                    }
                } else if content.count == 1 {
                    version = Int(content[0])
                } else if !content.isEmpty {
                    version = content.reduce(0) { ($0 << 8) | Int($1) }
                }
            case 1:
                nego = unwrapNegoTokens(content)
            case 2:
                auth = unwrapOctet(content)
            case 3:
                pub = unwrapOctet(content)
            case 4:
                errorCode = decodeNTStatus(content)
            case 5:
                nonce = unwrapOctet(content)
            default:
                break
            }
        }
        return TSRequest(
            version: version,
            negoTokens: nego,
            authInfo: auth,
            pubKeyAuth: pub,
            errorCode: errorCode,
            nonce: nonce
        )
    }

    /// Decode ASN.1 INTEGER contents (optionally wrapped) as NTSTATUS / Int32 bits.
    private static func decodeNTStatus(_ content: [UInt8]) -> UInt32? {
        let bytes: [UInt8]
        if content.count >= 2, content[0] == 0x02 {
            var io = 1
            guard let ilen = BER.decodeLength(content, offset: &io), io + ilen <= content.count else {
                return nil
            }
            bytes = Array(content[io..<(io + ilen)])
        } else {
            bytes = content
        }
        guard !bytes.isEmpty, bytes.count <= 8 else { return nil }
        var value: Int64 = 0
        if bytes[0] & 0x80 != 0 {
            value = -1
        }
        for b in bytes {
            value = (value << 8) | Int64(b)
        }
        return UInt32(bitPattern: Int32(truncatingIfNeeded: value))
    }

    private static func unwrapOctet(_ content: [UInt8]) -> [UInt8] {
        if content.first == 0x04 {
            var o = 1
            if let len = BER.decodeLength(content, offset: &o), o + len <= content.count {
                return Array(content[o..<(o + len)])
            }
        }
        return content
    }

    private static func unwrapNegoTokens(_ content: [UInt8]) -> [UInt8]? {
        var o = 0
        if content.first == 0x30 {
            o = 1
            _ = BER.decodeLength(content, offset: &o)
        }
        while o < content.count {
            let t = content[o]
            o += 1
            guard let len = BER.decodeLength(content, offset: &o) else { return nil }
            guard o + len <= content.count else {
                RDPLog.auth.error("SPNEGO length too large")
                return nil
            }
            let slice = Array(content[o..<(o + len)])
            o += len
            if t == 0x04 { return slice }
            if t == 0x30 || t == 0xA0 {
                if let inner = unwrapNegoTokens(slice) { return inner }
            }
        }
        return content
    }

    func encode() -> [UInt8] {
        var seq: [UInt8] = []
        // version [0] EXPLICIT INTEGER
        let verBytes: [UInt8] = [0x02, 0x01, UInt8(min(max(version, 2), 6))]
        seq.append(contentsOf: BER.encodeContext(0, contents: verBytes, constructed: true))

        if let nego = negoTokens {
            // negoTokens [1] NegoData
            // NegoData ::= SEQUENCE OF NegoToken
            // NegoToken ::= SEQUENCE { negoToken [0] OCTET STRING }
            let oct = BER.encodeOctetString(nego)
            let negoTokenField = BER.encodeContext(0, contents: oct, constructed: true)
            let negoTokenSeq = BER.encodeSequence(negoTokenField) // one NegoToken
            let negoData = BER.encodeSequence(negoTokenSeq) // SEQUENCE OF (DER as SEQUENCE)
            seq.append(contentsOf: BER.encodeContext(1, contents: negoData, constructed: true))
        }
        if let auth = authInfo {
            seq.append(contentsOf: BER.encodeContext(2, contents: BER.encodeOctetString(auth), constructed: true))
        }
        if let pub = pubKeyAuth {
            seq.append(contentsOf: BER.encodeContext(3, contents: BER.encodeOctetString(pub), constructed: true))
        }
        if let code = errorCode {
            // errorCode [4] INTEGER — signed NTSTATUS (e.g. 0xC000006D → 02 04 C0 00 00 6D)
            let signed = Int(Int32(bitPattern: code))
            seq.append(contentsOf: BER.encodeContext(4, contents: BER.encodeInteger(signed), constructed: true))
        }
        // Do not echo client nonce in server responses (client-only field in practice).
        return BER.encodeSequence(seq)
    }
}
