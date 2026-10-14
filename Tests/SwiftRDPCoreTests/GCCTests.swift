import XCTest
@testable import SwiftRDPCore

final class GCCTests: XCTestCase {
    func testNegotiationPreservesDefinedClientVersions() {
        for version in UInt32(0x0008_0004)...0x0008_0011 {
            XCTAssertEqual(GCC.negotiateRdpVersion(clientVersion: version), version)
        }
    }

    func testNegotiationRejectsUnknownAndUnsupportedVersions() {
        for version: UInt32 in [0, 0x0008_0001, 0x0008_0002, 0x0008_0003, 0x0008_0012, .max] {
            XCTAssertNil(GCC.negotiateRdpVersion(clientVersion: version))
        }
    }
}
