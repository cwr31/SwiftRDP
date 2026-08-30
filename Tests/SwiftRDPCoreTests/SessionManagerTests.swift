import NIO
import XCTest
@testable import SwiftRDPCore

final class SessionManagerTests: XCTestCase {
    private func makeAudit() throws -> ConnectionAudit {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mhrdp-session-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ConnectionAudit(directoryURL: directory)
    }

    func testRFXHashFallbackContinuesAtRateLimitWithoutInputActivity() {
        let interval: UInt64 = 100_000_000

        XCTAssertTrue(RDPSession.rfxHashScanDue(lastScanNs: 0, nowNs: 1))
        XCTAssertFalse(RDPSession.rfxHashScanDue(
            lastScanNs: 1_000_000_000,
            nowNs: 1_000_000_000 + interval - 1
        ))
        XCTAssertTrue(RDPSession.rfxHashScanDue(
            lastScanNs: 1_000_000_000,
            nowNs: 1_000_000_000 + interval
        ))
    }

    func testShutdownRequestDenialDoesNotCloseLoggedOnSession() {
        let session = RDPSession(config: ServerConfig())
        var writes = 0
        var closes = 0
        session.onWrite = { _ in writes += 1 }
        session.onClose = { closes += 1 }

        session.handleShutdownRequest()

        XCTAssertEqual(writes, 1)
        XCTAssertEqual(closes, 0)
        XCTAssertNotEqual(session.phase, .terminated)
    }

    func testNewConnectionReplacesCurrentSession() {
        let config = ServerConfig()
        let manager = SessionManager(config: config)
        let active = RDPSession(config: config)
        let replacement = RDPSession(config: config)

        manager.registerSession(active)
        XCTAssertTrue(manager.promoteSession(active))
        XCTAssertTrue(manager.hasActiveSession)

        manager.registerSession(replacement)
        XCTAssertEqual(active.phase, .terminated)
        XCTAssertFalse(manager.hasActiveSession)
        XCTAssertEqual(manager.liveClientSnapshot()?.id, replacement.id)
        XCTAssertEqual(manager.liveClientSnapshot()?.state, .connecting)

        XCTAssertTrue(manager.promoteSession(replacement))
        XCTAssertTrue(manager.hasActiveSession)
        XCTAssertEqual(manager.connectionSnapshot.sessionID, replacement.id)

        manager.unregisterSession(replacement)
        XCTAssertFalse(manager.hasActiveSession)
    }

    func testPromoteRestoresVirtualCaptureResolutionWithoutChangingRDPSize() {
        let config = ServerConfig(hostDisplayPolicy: .virtual)
        let manager = SessionManager(config: config)
        let session = RDPSession(config: config)
        session.info.clientName = "iPhone"
        session.info.peerAddress = "192.0.2.10"
        manager.rememberedSettingsProvider = { _ in
            RememberedSessionSettings(
                identity: SessionClientIdentity(
                    clientName: "iPhone",
                    peerAddress: "192.0.2.10"
                ),
                videoBitrate: 8_000_000,
                videoFPS: 60,
                audioPlaybackDestination: .controller,
                resolution: RememberedResolution(
                    width: 1920,
                    height: 1080,
                    logicalWidth: 1920,
                    logicalHeight: 1080,
                    hiDPI: false
                )
            )
        }

        manager.registerSession(session)
        XCTAssertTrue(manager.promoteSession(session))
        XCTAssertEqual(manager.virtualOverrideWidth, 1920)
        XCTAssertEqual(manager.virtualOverrideHeight, 1080)
        let params = manager.virtualDisplayParameters(clientWidth: 1424, clientHeight: 700)
        XCTAssertEqual(params.pixelWidth, 1920)
        XCTAssertEqual(params.pixelHeight, 1080)
        XCTAssertEqual(session.clientWidth, 1024)
        XCTAssertEqual(session.clientHeight, 768)
    }

    func testHostCursorRetainRelease() {
        let manager = SessionManager(config: ServerConfig())
        XCTAssertEqual(manager.hostCursorHiddenRetainCount, 0)

        manager.retainHostCursorHidden()
        XCTAssertEqual(manager.hostCursorHiddenRetainCount, 1)
        manager.retainHostCursorHidden()
        XCTAssertEqual(manager.hostCursorHiddenRetainCount, 2)

        manager.releaseHostCursorHidden()
        XCTAssertEqual(manager.hostCursorHiddenRetainCount, 1)
        manager.releaseHostCursorHidden()
        XCTAssertEqual(manager.hostCursorHiddenRetainCount, 0)

        // Extra release must not go negative.
        manager.releaseHostCursorHidden()
        XCTAssertEqual(manager.hostCursorHiddenRetainCount, 0)
    }

    func testOpenPolicyAllowsAllAddressesWithoutRateLimit() throws {
        let manager = SessionManager(config: ServerConfig(), audit: try makeAudit())

        for host in 1...100 {
            let address = try SocketAddress(
                ipAddress: "198.51.100.\((host - 1) % 254 + 1)",
                port: 50000
            )
            XCTAssertTrue(manager.allowConnection(from: address))
        }
    }

    func testKnownPeersOnlyAllowsAuthenticatedAddress() throws {
        let audit = try makeAudit()
        audit.recordAuthSuccess(peerAddress: "203.0.113.10")
        let manager = SessionManager(
            config: ServerConfig(knownPeersOnly: true),
            audit: audit
        )

        XCTAssertTrue(manager.allowConnection(
            from: try SocketAddress(ipAddress: "203.0.113.10", port: 50000)
        ))
        XCTAssertFalse(manager.allowConnection(
            from: try SocketAddress(ipAddress: "203.0.113.11", port: 50000)
        ))
    }

    func testKnownPeersOnlyCanBeAppliedLive() throws {
        let address = try SocketAddress(ipAddress: "198.51.100.10", port: 50000)
        let manager = SessionManager(config: ServerConfig(), audit: try makeAudit())

        XCTAssertTrue(manager.allowConnection(from: address))
        manager.applyKnownPeersOnly(true)
        XCTAssertFalse(manager.allowConnection(from: address))
        manager.applyKnownPeersOnly(false)
        XCTAssertTrue(manager.allowConnection(from: address))
    }

}
