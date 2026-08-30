import Foundation
import NIOSSL

/// Generates and loads self-signed TLS material for the RDP server.
/// Path style mirrors `~/Library/Application Support/<App>/certs/`.
public enum CertStore {
    public struct Material {
        public let certificate: NIOSSLCertificate
        public let privateKey: NIOSSLPrivateKey
        public let certificatePEM: Data
        public let privateKeyPEM: Data
        /// SubjectPublicKey for CredSSP pubKeyAuth (MS-CSSP): OpenSSL RSAPublicKey DER
        /// (BIT STRING contents of SubjectPublicKeyInfo — not the full SPKI wrapper).
        public let subjectPublicKeyInfoDER: [UInt8]
    }

    public static func ensure(certsDirectory: URL, commonName: String = "SwiftRDP") throws -> Material {
        try FileManager.default.createDirectory(at: certsDirectory, withIntermediateDirectories: true)
        let crtURL = certsDirectory.appendingPathComponent("server.crt")
        let keyURL = certsDirectory.appendingPathComponent("server.key")

        if FileManager.default.fileExists(atPath: crtURL.path),
           FileManager.default.fileExists(atPath: keyURL.path) {
            let crtData = try Data(contentsOf: crtURL)
            let keyData = try Data(contentsOf: keyURL)
            return try load(certificatePEM: crtData, privateKeyPEM: keyData)
        }

        RDPLog.auth.info("Generating self-signed TLS certificate…")
        try generateWithOpenSSL(crtURL: crtURL, keyURL: keyURL, commonName: commonName)
        RDPLog.auth.info("Generated self-signed TLS certificate at \(crtURL.path)")
        let crtData = try Data(contentsOf: crtURL)
        let keyData = try Data(contentsOf: keyURL)
        return try load(certificatePEM: crtData, privateKeyPEM: keyData)
    }

    private static func load(certificatePEM: Data, privateKeyPEM: Data) throws -> Material {
        let cert = try NIOSSLCertificate(bytes: [UInt8](certificatePEM), format: .pem)
        let key = try NIOSSLPrivateKey(bytes: [UInt8](privateKeyPEM), format: .pem)
        let spki = try extractSubjectPublicKeyInfo(fromCertificatePEM: certificatePEM)
        return Material(
            certificate: cert,
            privateKey: key,
            certificatePEM: certificatePEM,
            privateKeyPEM: privateKeyPEM,
            subjectPublicKeyInfoDER: spki
        )
    }

    /// Extract CredSSP SubjectPublicKey from a PEM certificate.
    /// Prefer OpenSSL `i2d_PublicKey` (RSAPublicKey DER), not full SPKI.
    public static func extractSubjectPublicKeyInfo(fromCertificatePEM pem: Data) throws -> [UInt8] {
        if let key = try? extractSubjectPublicKeyWithOpenSSL(pem: pem), !key.isEmpty {
            return key
        }
        throw CertError.publicKeyExtractFailed
    }

    private static func extractSubjectPublicKeyWithOpenSSL(pem: Data) throws -> [UInt8] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mhrdp-\(UUID().uuidString).crt")
        try pem.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Prefer PKCS#1 RSAPublicKey (matches i2d_PublicKey).
        if let pkcs1 = try? runOpenSSL([
            "x509", "-in", tmp.path, "-pubkey", "-noout"
        ], pipeTo: ["rsa", "-pubin", "-RSAPublicKey_out", "-outform", "DER"]), !pkcs1.isEmpty {
            return pkcs1
        }

        // Fallback: SPKI PEM → DER → strip to BIT STRING payload (drop unused-bits byte).
        let pubPEM = try runOpenSSL(["x509", "-in", tmp.path, "-pubkey", "-noout"])
        let spki = [UInt8](try pemToDER(Data(pubPEM)))
        if let bitPayload = subjectPublicKeyFromSPKI(spki) {
            return bitPayload
        }
        throw CertError.publicKeyExtractFailed
    }

    /// Run openssl; optionally pipe stdout into a second openssl invocation.
    private static func runOpenSSL(_ args: [String], pipeTo second: [String]? = nil) throws -> [UInt8] {
        let p1 = Process()
        p1.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p1.arguments = args
        let out1 = Pipe()
        let err1 = Pipe()
        p1.standardOutput = out1
        p1.standardError = err1

        guard let second else {
            try p1.run()
            p1.waitUntilExit()
            guard p1.terminationStatus == 0 else {
                throw CertError.opensslFailed(String(data: err1.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            }
            return [UInt8](out1.fileHandleForReading.readDataToEndOfFile())
        }

        let p2 = Process()
        p2.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p2.arguments = second
        let out2 = Pipe()
        let err2 = Pipe()
        p2.standardInput = out1
        p2.standardOutput = out2
        p2.standardError = err2
        try p1.run()
        try p2.run()
        p1.waitUntilExit()
        p2.waitUntilExit()
        guard p1.terminationStatus == 0, p2.terminationStatus == 0 else {
            let e1 = String(data: err1.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let e2 = String(data: err2.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CertError.opensslFailed(e1 + e2)
        }
        return [UInt8](out2.fileHandleForReading.readDataToEndOfFile())
    }

    /// From SPKI DER, return subjectPublicKey BIT STRING contents without the unused-bits byte.
    private static func subjectPublicKeyFromSPKI(_ spki: [UInt8]) -> [UInt8]? {
        guard spki.first == 0x30 else { return nil }
        var o = 1
        guard let _ = BER.decodeLength(spki, offset: &o) else { return nil }
        // AlgorithmIdentifier SEQUENCE
        guard o < spki.count, spki[o] == 0x30 else { return nil }
        o += 1
        guard let algLen = BER.decodeLength(spki, offset: &o), o + algLen <= spki.count else { return nil }
        o += algLen
        // subjectPublicKey BIT STRING
        guard o < spki.count, spki[o] == 0x03 else { return nil }
        o += 1
        guard let bitLen = BER.decodeLength(spki, offset: &o), o + bitLen <= spki.count, bitLen >= 1 else { return nil }
        // Drop unused-bits count (first octet of BIT STRING value).
        return Array(spki[(o + 1)..<(o + bitLen)])
    }

    private static func pemToDER(_ pem: Data) throws -> Data {
        guard let str = String(data: pem, encoding: .utf8) else { throw CertError.publicKeyExtractFailed }
        let lines = str.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
        let b64 = lines.joined()
        guard let der = Data(base64Encoded: b64) else { throw CertError.publicKeyExtractFailed }
        return der
    }

    private static func generateWithOpenSSL(crtURL: URL, keyURL: URL, commonName: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", keyURL.path,
            "-out", crtURL.path,
            "-days", "3650",
            "-nodes",
            "-subj", "/CN=\(commonName)",
            "-addext", "extendedKeyUsage=serverAuth",
            "-addext", "keyUsage=digitalSignature,keyEncipherment",
        ]
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CertError.opensslFailed(msg)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    }

    public enum CertError: Error, CustomStringConvertible {
        case opensslFailed(String)
        case publicKeyExtractFailed
        public var description: String {
            switch self {
            case .opensslFailed(let s): return "openssl failed: \(s)"
            case .publicKeyExtractFailed: return "failed to extract SubjectPublicKeyInfo"
            }
        }
    }
}
