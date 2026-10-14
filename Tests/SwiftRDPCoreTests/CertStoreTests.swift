import Foundation
import Security
import XCTest
@testable import SwiftRDPCore

final class CertStoreTests: XCTestCase {
    func testExistingTLSMaterialIsPreservedAndCredSSPKeyMatchesNativeExport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftrdp-cert-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try CertStore.ensure(certsDirectory: directory, commonName: "SwiftRDP Test")
        let privateKeyURL = directory.appendingPathComponent("server.key")
        let privateKey = try Data(contentsOf: privateKeyURL)
        let certificateDER = try first.certificate.toDERBytes()
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, Data(certificateDER) as CFData))
        let key = try XCTUnwrap(SecCertificateCopyKey(certificate))
        let nativePublicKey = try XCTUnwrap(SecKeyCopyExternalRepresentation(key, nil))
        XCTAssertEqual(first.subjectPublicKey, [UInt8](nativePublicKey as Data))

        let second = try CertStore.ensure(certsDirectory: directory, commonName: "Different Name")
        XCTAssertEqual(try second.certificate.toDERBytes(), certificateDER)
        XCTAssertEqual(second.subjectPublicKey, first.subjectPublicKey)
        XCTAssertEqual(try Data(contentsOf: privateKeyURL), privateKey)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       ["server.crt", "server.key"])
    }

    func testInvalidExistingMaterialFailsWithoutReplacingIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftrdp-invalid-cert-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let certificate = directory.appendingPathComponent("server.crt")
        let privateKey = directory.appendingPathComponent("server.key")
        try Data("invalid certificate".utf8).write(to: certificate)
        try Data("invalid private key".utf8).write(to: privateKey)

        XCTAssertThrowsError(try CertStore.ensure(certsDirectory: directory))
        XCTAssertEqual(try Data(contentsOf: certificate), Data("invalid certificate".utf8))
        XCTAssertEqual(try Data(contentsOf: privateKey), Data("invalid private key".utf8))
    }
}
