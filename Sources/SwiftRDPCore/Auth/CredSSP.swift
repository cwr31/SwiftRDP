import Foundation
import CryptoKit

/// CredSSP v6 server (MS-CSSP) with mandatory NTLMv2 public-key binding.
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
    private var bindingNonce: [UInt8]?
    public private(set) var state: State = .idle
    private static let version = 6

    private static let clientMagic = Array("CredSSP Client-To-Server Binding Hash".utf8) + [0]
    private static let serverMagic = Array("CredSSP Server-To-Client Binding Hash".utf8) + [0]

    public init(ntlm: NTLMServer, serverPublicKeyDER: [UInt8]) {
        self.ntlm = ntlm
        self.serverPublicKeyDER = serverPublicKeyDER
    }

    /// CredSSP v6 carries an NTSTATUS error so failed authentication ends immediately.
    public func encodeErrorResponse(ntStatus: UInt32 = CredSSP.statusLogonFailure) -> [UInt8] {
        return TSRequest(
            version: Self.version,
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
        case .unsupportedVersion:
            return statusNotSupported
        case .authFailed, .pubKeyAuthFailed:
            return statusLogonFailure
        case .parseFailed, .unexpectedState, .none:
            return statusLogonFailure
        }
    }

    /// Feed raw TLS application data; return response bytes to send (may be empty).
    public func handle(clientData: [UInt8]) throws -> (response: [UInt8], done: Bool) {
        do {
            return try handleRequest(TSRequest.parse(clientData))
        } catch {
            state = .failed
            throw error
        }
    }

    private func handleRequest(_ request: TSRequest) throws -> (response: [UInt8], done: Bool) {
        guard request.version >= Self.version else { throw CredSSPError.unsupportedVersion }
        guard request.errorCode == nil else { throw CredSSPError.authFailed }
        if let nonce = request.nonce, nonce.count != 32 { throw CredSSPError.pubKeyAuthFailed }
        RDPLog.auth.info("CredSSP: state=\(state) version=\(request.version)")

        switch state {
        case .idle:
            guard let token = request.negoTokens, request.authInfo == nil,
                  request.pubKeyAuth == nil else {
                throw CredSSPError.unexpectedState
            }
            let challenge = try ntlm.processNegotiate(token)
            state = .challengeSent
            RDPLog.auth.info("CredSSP: Sent NTLM Challenge")
            let resp = TSRequest(
                version: Self.version,
                negoTokens: challenge,
                authInfo: nil,
                pubKeyAuth: nil,
                errorCode: nil,
                nonce: nil
            ).encode()
            return (resp, false)

        case .challengeSent:
            guard let token = request.negoTokens, request.authInfo == nil else {
                throw CredSSPError.unexpectedState
            }
            guard let nonce = request.nonce, nonce.count == 32,
                  let binding = request.pubKeyAuth, !binding.isEmpty,
                  !serverPublicKeyDER.isEmpty else {
                throw CredSSPError.pubKeyAuthFailed
            }
            guard try ntlm.processAuthenticate(token) else { throw CredSSPError.authFailed }
            guard verifyClientPubKeyAuth(binding, nonce: nonce) else {
                throw CredSSPError.pubKeyAuthFailed
            }
            bindingNonce = nonce
            let serverBinding = sha256(Self.serverMagic + nonce + serverPublicKeyDER)
            guard let pubKeyAuth = ntlm.encryptMessage(serverBinding) else {
                throw CredSSPError.authFailed
            }
            state = .waitingClientFinal
            RDPLog.auth.info("CredSSP: Sent server pubKeyAuth (\(pubKeyAuth.count) bytes)")
            let resp = TSRequest(
                version: Self.version,
                negoTokens: nil,
                authInfo: nil,
                pubKeyAuth: pubKeyAuth,
                errorCode: nil,
                nonce: nil
            ).encode()
            return (resp, false)

        case .waitingClientFinal:
            // clientNonce is optional on TSRequest; repeated values stay bound to Authenticate.
            guard request.negoTokens == nil, request.pubKeyAuth == nil,
                  request.nonce == nil || request.nonce == bindingNonce,
                  let auth = request.authInfo, !auth.isEmpty else {
                throw CredSSPError.unexpectedState
            }
            guard ntlm.decryptMessage(auth) != nil else { throw CredSSPError.authFailed }
            state = .authenticated
            RDPLog.auth.info("CredSSP: Authentication successful for user=\(ntlm.authenticatedUser)")
            return ([], true)

        case .authenticated, .failed:
            throw CredSSPError.unexpectedState
        }
    }

    private func verifyClientPubKeyAuth(_ encrypted: [UInt8], nonce: [UInt8]) -> Bool {
        guard let plain = ntlm.decryptMessage(encrypted) else { return false }
        return plain == sha256(Self.clientMagic + nonce + serverPublicKeyDER)
    }

    private func sha256(_ data: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: Data(data)))
    }

    public enum CredSSPError: Error, Equatable {
        case parseFailed
        case unsupportedVersion
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
        let fields = try unwrap(data, tag: BER.tagSequence)
        var offset = 0
        var previousTag: UInt8 = 0x9F
        var version: Int?
        var nego: [UInt8]?
        var auth: [UInt8]?
        var pub: [UInt8]?
        var errorCode: UInt32?
        var nonce: [UInt8]?

        while offset < fields.count {
            let tag = fields[offset]
            guard (0xA0...0xA5).contains(tag), tag > previousTag else {
                throw CredSSP.CredSSPError.parseFailed
            }
            previousTag = tag
            let content = try read(fields, tag: tag, offset: &offset)
            switch tag {
            case 0xA0:
                let bytes = try unwrap(content, tag: BER.tagInteger)
                guard !bytes.isEmpty, bytes.count <= MemoryLayout<Int>.size, bytes[0] & 0x80 == 0 else {
                    throw CredSSP.CredSSPError.parseFailed
                }
                version = bytes.reduce(0) { ($0 << 8) | Int($1) }
            case 0xA1:
                let tokens = try unwrap(content, tag: BER.tagSequence)
                let token = try unwrap(tokens, tag: BER.tagSequence)
                let field = try unwrap(token, tag: 0xA0)
                nego = try unwrap(field, tag: BER.tagOctetString)
            case 0xA2:
                auth = try unwrap(content, tag: BER.tagOctetString)
            case 0xA3:
                pub = try unwrap(content, tag: BER.tagOctetString)
            case 0xA4:
                let bytes = try unwrap(content, tag: BER.tagInteger)
                guard !bytes.isEmpty, bytes.count <= 5 else { throw CredSSP.CredSSPError.parseFailed }
                var value: Int64 = bytes[0] & 0x80 == 0 ? 0 : -1
                for byte in bytes { value = (value << 8) | Int64(byte) }
                guard value >= Int64(Int32.min), value <= Int64(UInt32.max) else {
                    throw CredSSP.CredSSPError.parseFailed
                }
                errorCode = UInt32(truncatingIfNeeded: value)
            case 0xA5:
                nonce = try unwrap(content, tag: BER.tagOctetString)
            default:
                break
            }
        }
        guard let version else { throw CredSSP.CredSSPError.parseFailed }
        return TSRequest(
            version: version,
            negoTokens: nego,
            authInfo: auth,
            pubKeyAuth: pub,
            errorCode: errorCode,
            nonce: nonce
        )
    }

    private static func read(_ data: [UInt8], tag: UInt8, offset: inout Int) throws -> [UInt8] {
        guard offset < data.count, data[offset] == tag else { throw CredSSP.CredSSPError.parseFailed }
        offset += 1
        guard offset < data.count,
              data[offset] & 0x80 == 0 || Int(data[offset] & 0x7F) <= MemoryLayout<Int>.size,
              let length = BER.decodeLength(data, offset: &offset),
              length >= 0, length <= data.count - offset else {
            throw CredSSP.CredSSPError.parseFailed
        }
        let content = Array(data[offset..<(offset + length)])
        offset += length
        return content
    }

    private static func unwrap(_ data: [UInt8], tag: UInt8) throws -> [UInt8] {
        var offset = 0
        let content = try read(data, tag: tag, offset: &offset)
        guard offset == data.count else { throw CredSSP.CredSSPError.parseFailed }
        return content
    }

    func encode() -> [UInt8] {
        var seq: [UInt8] = []
        // version [0] EXPLICIT INTEGER
        let verBytes = BER.encodeInteger(version)
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
        if let nonce {
            seq.append(contentsOf: BER.encodeContext(5, contents: BER.encodeOctetString(nonce)))
        }
        return BER.encodeSequence(seq)
    }
}
