import XCTest
@testable import SwiftRDPCore

final class CredSSPErrorCodeTests: XCTestCase {
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

    func testSupportsErrorCodeVersions() {
        // MS-CSSP: errorCode for versions 3, 4, and ≥6 (not 2 or 5).
        XCTAssertFalse(CredSSP.supportsErrorCode(version: 2))
        XCTAssertTrue(CredSSP.supportsErrorCode(version: 3))
        XCTAssertTrue(CredSSP.supportsErrorCode(version: 4))
        XCTAssertFalse(CredSSP.supportsErrorCode(version: 5))
        XCTAssertTrue(CredSSP.supportsErrorCode(version: 6))
    }

    func testEncodeErrorResponseForVersion6() throws {
        let ntlm = NTLMServer(username: "user", password: "password", domain: "", serverName: "SwiftRDP")
        let credSSP = CredSSP(ntlm: ntlm, serverPublicKeyDER: Array(repeating: 0x01, count: 32))
        // Default clientVersion is 6 until a peer TSRequest is seen.
        guard let bytes = credSSP.encodeErrorResponse(ntStatus: CredSSP.statusLogonFailure) else {
            return XCTFail("expected error TSRequest for version 6")
        }
        let parsed = try TSRequest.parse(bytes)
        XCTAssertEqual(parsed.errorCode, CredSSP.statusLogonFailure)
        XCTAssertEqual(parsed.version, 6)
    }
}

private extension Array {
    func windows(ofCount n: Int) -> [ArraySlice<Element>] {
        guard n > 0, count >= n else { return [] }
        return (0...(count - n)).map { self[$0..<($0 + n)] }
    }
}
