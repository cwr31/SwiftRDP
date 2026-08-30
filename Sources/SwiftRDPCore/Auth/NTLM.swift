import Foundation
import CryptoKit
import CommonCrypto

/// Minimal NTLMv2 server for CredSSP/NLA (MS-NLMP).
/// Aligns with behavior: TargetInfo AV pairs, session key export, optional NT hash store under Application Support.
public final class NTLMServer: @unchecked Sendable {
    public let username: String
    public let password: String
    public let domain: String
    /// Host name used for NTLM TargetName / TargetInfo (NetBIOS + DNS AV pairs).
    public let serverName: String
    public let ntlmStoreURL: URL?

    public private(set) var serverChallenge: [UInt8] = []
    public private(set) var negotiateFlags: UInt32 = 0
    public private(set) var clientNegotiate: [UInt8] = []
    public private(set) var exportedSessionKey: [UInt8] = []
    public private(set) var authenticatedUser: String = ""

    /// CredSSP sealing sequence numbers (MS-NLMP EncryptMessage).
    private var serverSealSeq: UInt32 = 0
    private var clientSealSeq: UInt32 = 0
    private var serverSealHandle: StatefulRC4?
    private var clientSealHandle: StatefulRC4?

    /// MS-NLMP NegotiateFlags (selected bits).
    private enum Flags {
        static let unicode: UInt32 = 0x0000_0001
        static let oem: UInt32 = 0x0000_0002
        static let requestTarget: UInt32 = 0x0000_0004
        static let sign: UInt32 = 0x0000_0010
        static let seal: UInt32 = 0x0000_0020
        static let lmKey: UInt32 = 0x0000_0080
        static let ntlm: UInt32 = 0x0000_0200
        static let alwaysSign: UInt32 = 0x0000_8000
        static let targetTypeServer: UInt32 = 0x0002_0000
        static let extendedSessionSecurity: UInt32 = 0x0008_0000
        static let targetInfo: UInt32 = 0x0080_0000
        static let version: UInt32 = 0x0200_0000
        static let key128: UInt32 = 0x2000_0000
        static let keyExch: UInt32 = 0x4000_0000
        static let key56: UInt32 = 0x8000_0000
    }

    public init(
        username: String,
        password: String,
        domain: String = "",
        serverName: String = "SwiftRDP",
        ntlmStoreURL: URL? = nil
    ) {
        self.username = username
        self.password = password
        self.domain = domain
        self.serverName = serverName.isEmpty ? "SwiftRDP" : serverName
        self.ntlmStoreURL = ntlmStoreURL
    }

    public func processNegotiate(_ token: [UInt8]) throws -> [UInt8] {
        guard token.count >= 32 else {
            throw NTLMError.invalidMessage
        }
        guard Array(token[0..<8]) == Array("NTLMSSP\0".utf8) else {
            RDPLog.auth.error("NTLM: Invalid signature")
            throw NTLMError.invalidMessage
        }
        let msgType = u32(token, 8)
        guard msgType == 1 else {
            RDPLog.auth.error("NTLM: Expected Negotiate (1), got \(msgType)")
            throw NTLMError.invalidMessage
        }
        clientNegotiate = token
        negotiateFlags = u32(token, 12)
        serverChallenge = (0..<8).map { _ in UInt8.random(in: 0...255) }
        RDPLog.auth.info("NTLM: Negotiate flags=0x\(String(negotiateFlags, radix: 16)) len=\(token.count)")
        return buildChallenge()
    }

    public func processAuthenticate(_ token: [UInt8]) throws -> Bool {
        guard token.count >= 88 else { return false }
        guard Array(token[0..<8]) == Array("NTLMSSP\0".utf8) else { return false }
        guard u32(token, 8) == 3 else { return false }

        let lmResp = readSecBuffer(token, offset: 12)
        let ntResp = readSecBuffer(token, offset: 20)
        let domainBuf = readSecBuffer(token, offset: 28)
        let userBuf = readSecBuffer(token, offset: 36)
        let encSessionKey = readSecBuffer(token, offset: 52)
        let flags = token.count >= 64 ? u32(token, 60) : negotiateFlags
        _ = lmResp

        let user = String(bytes: userBuf, encoding: .utf16LittleEndian) ?? ""
        let dom = String(bytes: domainBuf, encoding: .utf16LittleEndian) ?? ""
        authenticatedUser = user

        RDPLog.auth.info("CredSSP: NTLM Authenticate received, user=\(user) domain=\(dom)")

        guard user.lowercased() == username.lowercased() || username == "*" else {
            RDPLog.auth.error("CredSSP: Authentication failed for user=\(user)")
            return false
        }

        let ntHash = loadOrComputeNTHash(for: user)
        var verified = false
        if ntResp.count >= 16 {
            verified = verifyNTLMv2(
                ntHash: ntHash,
                username: user,
                domain: dom,
                serverChallenge: serverChallenge,
                ntResponse: ntResp
            )
        }

        if verified {
            RDPLog.auth.info("CredSSP: NTLM session key computed successfully")
            deriveSessionKey(ntHash: ntHash, username: user, domain: dom, ntResponse: ntResp, encSessionKey: encSessionKey, flags: flags)
            persistNTHash(user: user, hash: ntHash)
            RDPLog.auth.info("CredSSP: Authentication successful for user=\(user)")
            return true
        }

        RDPLog.auth.error("NTLM: NTProofStr mismatch — wrong password or hash")
        RDPLog.auth.error("CredSSP: authentication failed for '\(user)'")
        return false
    }

    public func buildChallenge() -> [UInt8] {
        // TargetName is the server's NetBIOS/computer name (not WORKGROUP).
        let targetNameStr = serverName
        let nbComputer = serverName.uppercased()
        let nbDomain = domain.isEmpty ? serverName.uppercased() : domain.uppercased()
        let targetName = utf16LE(targetNameStr)
        let targetInfo = buildTargetInfo(nbDomain: nbDomain, nbComputer: nbComputer)

        // Inherit client flags, then force bits that match the Challenge payload.
        // Windows mstsc aborts if TargetInfo is present but TARGET_INFO is clear.
        var flags = negotiateFlags
        flags &= ~Flags.oem
        flags &= ~Flags.lmKey // ESS and LM_KEY are mutually exclusive (MS-NLMP)
        flags |= Flags.unicode
        flags |= Flags.requestTarget
        flags |= Flags.ntlm
        flags |= Flags.alwaysSign
        flags |= Flags.targetTypeServer
        flags |= Flags.extendedSessionSecurity
        flags |= Flags.targetInfo
        flags |= Flags.version
        // Only grant crypto bits the client offered (MS-NLMP §3.2.5.1.2).
        flags |= negotiateFlags & Flags.sign
        flags |= negotiateFlags & Flags.seal
        flags |= negotiateFlags & Flags.key128
        flags |= negotiateFlags & Flags.keyExch
        flags |= negotiateFlags & Flags.key56
        // CredSSP needs sealing for pubKeyAuth — if client offered seal, keep it.
        if negotiateFlags & Flags.seal != 0 {
            flags |= Flags.seal
            flags |= Flags.sign
        }

        // 56-byte header including Version when VERSION flag set
        let headerSize = 56

        var msg: [UInt8] = []
        msg.append(contentsOf: Array("NTLMSSP\0".utf8))
        msg.appendU32(2) // CHALLENGE

        msg.appendU16(UInt16(targetName.count))
        msg.appendU16(UInt16(targetName.count))
        msg.appendU32(UInt32(headerSize))

        msg.appendU32(flags)
        msg.append(contentsOf: serverChallenge)
        msg.append(contentsOf: [UInt8](repeating: 0, count: 8))

        let tiOffset = headerSize + targetName.count
        msg.appendU16(UInt16(targetInfo.count))
        msg.appendU16(UInt16(targetInfo.count))
        msg.appendU32(UInt32(tiOffset))

        // Version (Windows 10 style)
        msg.append(contentsOf: [0x0A, 0x00, 0x63, 0x45, 0x00, 0x00, 0x00, 0x0F])

        assert(msg.count == headerSize)
        msg.append(contentsOf: targetName)
        msg.append(contentsOf: targetInfo)
        RDPLog.auth.info(
            "NTLM: Challenge flags=0x\(String(flags, radix: 16)) len=\(msg.count) " +
            "targetInfo=\(targetInfo.count) target=\(targetNameStr)"
        )
        return msg
    }

    // MARK: - TargetInfo / AV_PAIRs

    private func buildTargetInfo(nbDomain: String, nbComputer: String) -> [UInt8] {
        var info: [UInt8] = []
        func av(_ id: UInt16, _ value: [UInt8]) {
            info.appendU16(id)
            info.appendU16(UInt16(value.count))
            info.append(contentsOf: value)
        }
        // MS-NLMP Challenge TargetInfo — do NOT include MsvAvTargetName (0x0009);
        // that AvId is only valid in AUTHENTICATE and causes mstsc to abort NLA.
        av(0x0001, utf16LE(nbComputer)) // MsvAvNbComputerName
        av(0x0002, utf16LE(nbDomain))   // MsvAvNbDomainName
        av(0x0003, utf16LE(nbComputer)) // MsvAvDnsComputerName
        av(0x0004, utf16LE(nbDomain))   // MsvAvDnsDomainName
        let filetime = Self.windowsFileTimeNow()
        av(0x0007, ByteWriter.u64(filetime)) // MsvAvTimestamp
        info.appendU16(0) // EOL
        info.appendU16(0)
        return info
    }

    private static func windowsFileTimeNow() -> UInt64 {
        // 100-ns intervals since 1601-01-01
        let unix = Date().timeIntervalSince1970
        return UInt64((unix + 11644473600.0) * 10_000_000.0)
    }

    // MARK: - Session key

    private func deriveSessionKey(
        ntHash: [UInt8],
        username: String,
        domain: String,
        ntResponse: [UInt8],
        encSessionKey: [UInt8],
        flags: UInt32
    ) {
        let ntProof = Array(ntResponse[0..<16])
        let responseKeyNT = hmacMD5(key: ntHash, data: utf16LE(username.uppercased() + domain))
        let sessionBaseKey = hmacMD5(key: responseKeyNT, data: ntProof)
        let keyExchangeKey = sessionBaseKey

        if flags & 0x4000_0000 != 0, encSessionKey.count == 16 { // NEGOTIATE_KEY_EXCH
            exportedSessionKey = RC4Handle.crypt(key: keyExchangeKey, data: encSessionKey)
        } else {
            exportedSessionKey = keyExchangeKey
        }
        prepareSealingKeys()
    }

    private func prepareSealingKeys() {
        guard exportedSessionKey.count >= 16 else { return }
        let serverSignMagic = Array("session key to server-to-client signing key magic constant\0".utf8)
        let serverSealMagic = Array("session key to server-to-client sealing key magic constant\0".utf8)
        let clientSignMagic = Array("session key to client-to-server signing key magic constant\0".utf8)
        let clientSealMagic = Array("session key to client-to-server sealing key magic constant\0".utf8)
        serverSignKey = md5(exportedSessionKey + serverSignMagic)
        serverSealKey = md5(exportedSessionKey + serverSealMagic)
        clientSignKey = md5(exportedSessionKey + clientSignMagic)
        clientSealKey = md5(exportedSessionKey + clientSealMagic)
        serverSealHandle = StatefulRC4(key: serverSealKey)
        clientSealHandle = StatefulRC4(key: clientSealKey)
        serverSealSeq = 0
        clientSealSeq = 0
    }

    private var serverSignKey: [UInt8] = []
    private var serverSealKey: [UInt8] = []
    private var clientSignKey: [UInt8] = []
    private var clientSealKey: [UInt8] = []

    /// MS-NLMP EncryptMessage (Extended Session Security) → 16-byte signature || ciphertext.
    /// Order matches MS-NLMP: RC4(message) then RC4(HMAC[0..7]) on the same seal handle.
    public func encryptMessage(_ plaintext: [UInt8]) -> [UInt8]? {
        if serverSealHandle == nil { prepareSealingKeys() }
        guard let seal = serverSealHandle, serverSignKey.count == 16 else {
            RDPLog.auth.error("NTLM: Server seal handle not initialized")
            return nil
        }
        let seq = serverSealSeq
        serverSealSeq &+= 1
        var seqBytes: [UInt8] = []
        seqBytes.appendU32(seq)
        let digest = hmacMD5(key: serverSignKey, data: seqBytes + plaintext)
        let sealed = seal.crypt(plaintext)
        let sealedChecksum = seal.crypt(Array(digest.prefix(8)))
        // NTLMSSP_MESSAGE_SIGNATURE: Version(4)=1 | CheckSum(8) | SeqNum(4)
        var sig: [UInt8] = []
        sig.appendU32(1)
        sig.append(contentsOf: sealedChecksum)
        sig.appendU32(seq)
        return sig + sealed
    }

    /// MS-NLMP DecryptMessage — returns plaintext if signature verifies.
    public func decryptMessage(_ blob: [UInt8]) -> [UInt8]? {
        guard blob.count > 16 else { return nil }
        if clientSealHandle == nil { prepareSealingKeys() }
        guard let seal = clientSealHandle, clientSignKey.count == 16 else {
            RDPLog.auth.error("NTLM: Client seal handle not initialized")
            return nil
        }
        let sig = Array(blob[0..<16])
        let cipher = Array(blob[16...])
        let seq = u32(sig, 12)
        let receivedChecksum = Array(sig[4..<12])
        let plain = seal.crypt(cipher)
        var seqBytes: [UInt8] = []
        seqBytes.appendU32(seq)
        let digest = hmacMD5(key: clientSignKey, data: seqBytes + plain)
        // Same RC4 stream as EncryptMessage: seal expected digest[0..7] and compare.
        let expectedChecksum = seal.crypt(Array(digest.prefix(8)))
        guard expectedChecksum == receivedChecksum, u32(sig, 0) == 1 else { return nil }
        return plain
    }

    private func md5(_ data: [UInt8]) -> [UInt8] {
        Array(Insecure.MD5.hash(data: Data(data)))
    }

    // MARK: - NT hash store (compatible layout idea)

    private func loadOrComputeNTHash(for user: String) -> [UInt8] {
        if let url = ntlmStoreURL {
            let file = url.appendingPathComponent("\(user.lowercased()).hash")
            if let data = try? Data(contentsOf: file), data.count == 16 {
                RDPLog.auth.debug("CredSSP: loaded stored NT hash for '\(user)'")
                return [UInt8](data)
            }
        }
        return Self.ntHash(password: password)
    }

    private func persistNTHash(user: String, hash: [UInt8]) {
        guard let url = ntlmStoreURL else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let file = url.appendingPathComponent("\(user.lowercased()).hash")
            try Data(hash).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            RDPLog.auth.debug("CredSSP: migrated NT hash for '\(user)'")
        } catch {
            RDPLog.auth.debug("CredSSP: NT hash persist failed: \(error)")
        }
    }

    // MARK: - Crypto

    public static func ntHash(password: String) -> [UInt8] {
        md4(utf16LE(password))
    }

    /// Remove cached NT hashes so a newly configured password takes effect immediately.
    public static func invalidateStoredHashes(in directory: URL) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "hash" {
                try? FileManager.default.removeItem(at: file)
                RDPLog.auth.info("Auth: NT hash deleted for '\(file.deletingPathExtension().lastPathComponent)'")
            }
        }
    }

    /// Write the NT hash for the configured username/password (call after Settings save).
    public static func storeHash(username: String, password: String, in directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let hash = ntHash(password: password)
            let file = directory.appendingPathComponent("\(username.lowercased()).hash")
            try Data(hash).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            RDPLog.auth.info("Auth: NT hash stored for '\(username)'")
        } catch {
            RDPLog.auth.error("Auth: Failed to store NT hash: \(error)")
        }
    }

    private func verifyNTLMv2(
        ntHash: [UInt8],
        username: String,
        domain: String,
        serverChallenge: [UInt8],
        ntResponse: [UInt8]
    ) -> Bool {
        guard ntResponse.count >= 16 else { return false }
        let clientProof = Array(ntResponse[0..<16])
        let clientBlob = Array(ntResponse[16...])
        let identity = utf16LE(username.uppercased() + domain)
        let ntlmv2Hash = hmacMD5(key: ntHash, data: identity)
        let expected = hmacMD5(key: ntlmv2Hash, data: serverChallenge + clientBlob)
        return expected == clientProof
    }

    private func readSecBuffer(_ data: [UInt8], offset: Int) -> [UInt8] {
        guard offset + 8 <= data.count else { return [] }
        let len = Int(u16(data, offset))
        let off = Int(u32(data, offset + 4))
        guard off >= 0, off + len <= data.count else { return [] }
        return Array(data[off..<(off + len)])
    }

    private func u16(_ d: [UInt8], _ o: Int) -> UInt16 {
        UInt16(d[o]) | UInt16(d[o + 1]) << 8
    }

    private func u32(_ d: [UInt8], _ o: Int) -> UInt32 {
        UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
    }

    private static func utf16LE(_ s: String) -> [UInt8] {
        Array(s.utf16).flatMap { ByteWriter.u16($0) }
    }

    private func utf16LE(_ s: String) -> [UInt8] { Self.utf16LE(s) }

    @available(macOS, deprecated: 10.15, message: "MD4 required by NTLM protocol")
    private static func md4(_ data: [UInt8]) -> [UInt8] {
        var ctx = CC_MD4_CTX()
        CC_MD4_Init(&ctx)
        _ = data.withUnsafeBytes { CC_MD4_Update(&ctx, $0.baseAddress, CC_LONG(data.count)) }
        var digest = [UInt8](repeating: 0, count: Int(CC_MD4_DIGEST_LENGTH))
        CC_MD4_Final(&digest, &ctx)
        return digest
    }

    private func hmacMD5(key: [UInt8], data: [UInt8]) -> [UInt8] {
        let mac = HMAC<Insecure.MD5>.authenticationCode(for: Data(data), using: SymmetricKey(data: Data(key)))
        return Array(mac)
    }

    /// RC4 state for NTLM/CredSSP session sealing (MS-NLMP / MS-CSSP).
    public final class RC4Handle {
        public static func crypt(key: [UInt8], data: [UInt8]) -> [UInt8] {
            RC4.crypt(key: key, data: data)
        }
    }
}

/// Minimal RC4 for NTLM/CredSSP sealing (MS-NLMP / MS-CSSP).
enum RC4 {
    static func crypt(key: [UInt8], data: [UInt8]) -> [UInt8] {
        StatefulRC4(key: key).crypt(data)
    }
}

enum NTLMError: Error {
    case invalidMessage
}

/// Stateful RC4 (sealing handle must persist across EncryptMessage calls).
final class StatefulRC4 {
    private var s: [Int]
    private var i = 0
    private var j = 0

    init(key: [UInt8]) {
        s = Array(0..<256)
        var jj = 0
        for ii in 0..<256 {
            jj = (jj + s[ii] + Int(key[ii % key.count])) & 0xFF
            s.swapAt(ii, jj)
        }
    }

    func crypt(_ data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count)
        for k in 0..<data.count {
            i = (i + 1) & 0xFF
            j = (j + s[i]) & 0xFF
            s.swapAt(i, j)
            let t = (s[i] + s[j]) & 0xFF
            out[k] = data[k] ^ UInt8(s[t])
        }
        return out
    }
}
