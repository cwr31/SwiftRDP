import XCTest
@testable import SwiftRDPCore

final class RememberedSessionSettingsTests: XCTestCase {
    func testIdentityPrefersNormalizedClientName() {
        let first = SessionClientIdentity(clientName: " Office-PC ", peerAddress: "10.0.0.2")
        let second = SessionClientIdentity(clientName: "office-pc", peerAddress: "10.0.0.9")

        XCTAssertEqual(first.stableKey, second.stableKey)
        XCTAssertEqual(first.stableKey, "client:office-pc")
    }

    func testIdentityFallsBackToPeerAddress() {
        let identity = SessionClientIdentity(clientName: "", peerAddress: " 10.0.0.2 ")
        XCTAssertEqual(identity.stableKey, "peer:10.0.0.2")
    }

    func testSettingsRoundTrip() throws {
        let original = RememberedSessionSettings(
            identity: SessionClientIdentity(clientName: "MacBook", peerAddress: "10.0.0.2"),
            videoBitrate: 8_000_000,
            videoFPS: 60,
            audioPlaybackDestination: .controller,
            resolution: RememberedResolution(
                width: 3024,
                height: 1964,
                logicalWidth: 1512,
                logicalHeight: 982,
                hiDPI: true
            )
        )

        let decoded = try JSONDecoder().decode(
            RememberedSessionSettings.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)
    }
}
