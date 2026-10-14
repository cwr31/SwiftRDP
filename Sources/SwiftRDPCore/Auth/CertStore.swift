import Foundation
import NIOSSL

/// Generates and loads self-signed TLS material for the RDP server.
/// Path style mirrors `~/Library/Application Support/<App>/certs/`.
public enum CertStore {
    public struct Material {
        public let certificate: NIOSSLCertificate
        public let privateKey: NIOSSLPrivateKey
        /// CredSSP uses the SubjectPublicKey BIT STRING, not the SPKI wrapper.
        public let subjectPublicKey: [UInt8]
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
        let spki = try cert.extractPublicKey().toSPKIBytes()
        guard let publicKey = subjectPublicKeyFromSPKI(spki) else {
            throw CertError.publicKeyExtractFailed
        }
        return Material(
            certificate: cert,
            privateKey: key,
            subjectPublicKey: publicKey
        )
    }

    /// From SPKI DER, return subjectPublicKey BIT STRING contents without the unused-bits byte.
    private static func subjectPublicKeyFromSPKI(_ spki: [UInt8]) -> [UInt8]? {
        guard spki.first == 0x30 else { return nil }
        var o = 1
        guard let length = BER.decodeLength(spki, offset: &o), o + length == spki.count else { return nil }
        // AlgorithmIdentifier SEQUENCE
        guard o < spki.count, spki[o] == 0x30 else { return nil }
        o += 1
        guard let algLen = BER.decodeLength(spki, offset: &o), o + algLen <= spki.count else { return nil }
        o += algLen
        // subjectPublicKey BIT STRING
        guard o < spki.count, spki[o] == 0x03 else { return nil }
        o += 1
        guard let bitLen = BER.decodeLength(spki, offset: &o), o + bitLen == spki.count,
              bitLen > 1, spki[o] == 0 else { return nil }
        // Drop unused-bits count (first octet of BIT STRING value).
        return Array(spki[(o + 1)..<(o + bitLen)])
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
            case .publicKeyExtractFailed: return "failed to extract SubjectPublicKey"
            }
        }
    }
}
