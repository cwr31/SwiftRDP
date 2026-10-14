import NIO
import XCTest
@testable import SwiftRDPCore

final class SessionManagerTests: XCTestCase {
    func testStateNotificationsOnlyDescribeTheCurrentAuthenticatedDesktop() throws {
        let manager = try makeTestSessionManager(config: ServerConfig())
        let active = RDPSession(config: ServerConfig())
        let pending = RDPSession(config: ServerConfig())
        let changed = expectation(description: "Active desktop state changed")
        changed.assertForOverFulfill = true
        manager.onSessionStateChanged = {
            XCTAssertEqual(manager.connectionSnapshot.sessionID, active.id)
            XCTAssertEqual(manager.connectionSnapshot.audioPlaybackDestination, .host)
            changed.fulfill()
        }

        XCTAssertTrue(manager.registerSession(active))
        XCTAssertTrue(manager.promoteSession(active))
        XCTAssertTrue(manager.registerSession(pending))
        pending.applyAudioPlaybackDestination(.host)
        active.applyAudioPlaybackDestination(.host)
        active.applyAudioPlaybackDestination(.host)
        manager.unregisterSession(active)
        manager.noteSessionStateChanged(active)
        wait(for: [changed], timeout: 1)
    }

    func testShutdownRequestDenialDoesNotCloseLoggedOnSession() {
        let session = RDPSession(config: ServerConfig())
        var writes = 0
        var closes = 0
        session.socket.onWriteBatch = { packets, _, _ in
            writes += packets.count
            return true
        }
        session.onClose = { closes += 1 }

        session.handleShutdownRequest()

        XCTAssertEqual(writes, 1)
        XCTAssertEqual(closes, 0)
        XCTAssertNotEqual(session.phase, .terminated)
    }

    func testReplacementDoesNotDisplaceDesktopUntilPromotion() throws {
        let config = ServerConfig()
        let manager = try makeTestSessionManager(config: config)
        let active = RDPSession(config: config)
        let replacement = RDPSession(config: config)

        manager.registerSession(active)
        XCTAssertTrue(manager.promoteSession(active))
        XCTAssertTrue(manager.hasActiveSession)

        manager.registerSession(replacement)
        XCTAssertNotEqual(active.phase, .terminated)
        XCTAssertTrue(manager.hasActiveSession)
        XCTAssertEqual(manager.liveClientSnapshot()?.id, active.id)
        XCTAssertEqual(manager.liveClientSnapshot()?.state, .active)

        XCTAssertTrue(manager.promoteSession(replacement))
        XCTAssertEqual(active.phase, .terminated)
        XCTAssertTrue(manager.hasActiveSession)
        XCTAssertEqual(manager.connectionSnapshot.sessionID, replacement.id)

        manager.unregisterSession(replacement)
        XCTAssertFalse(manager.hasActiveSession)
    }

    func testFailedHandshakeLeavesAuthenticatedDesktopInPlace() throws {
        let manager = SessionManager(config: ServerConfig(), audit: try makeTestConnectionAudit())
        let desktop = RDPSession(config: ServerConfig())
        let candidate = RDPSession(config: ServerConfig())
        XCTAssertTrue(manager.registerSession(desktop))
        XCTAssertTrue(manager.promoteSession(desktop))
        XCTAssertTrue(manager.registerSession(candidate))
        manager.noteAuthenticationFailure(session: candidate, userName: "wrong", detail: "Rejected")
        candidate.terminate()
        manager.unregisterSession(candidate)
        XCTAssertTrue(manager.hasActiveSession)
        XCTAssertEqual(manager.liveClientSnapshot()?.id, desktop.id)
        XCTAssertNotEqual(desktop.phase, .terminated)
        XCTAssertFalse(manager.promoteSession(candidate))
    }

    func testPendingConnectionsAreBoundedAndReleasedOnDisconnect() throws {
        let manager = try makeTestSessionManager(config: ServerConfig())
        let candidates = (0..<5).map { _ in RDPSession(config: ServerConfig()) }
        for candidate in candidates.prefix(4) { XCTAssertTrue(manager.registerSession(candidate)) }
        XCTAssertFalse(manager.registerSession(candidates[4]))
        manager.unregisterSession(candidates[0])
        XCTAssertTrue(manager.registerSession(candidates[4]))
        XCTAssertNotNil(manager.liveClientSnapshot())
        XCTAssertFalse(manager.hasActiveSession)
    }

    func testGraphicsRecoveryAndTerminationRunOnSessionEventLoop() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let loop = group.next()
        let session = RDPSession(config: ServerConfig())
        session.noteMainEventLoop(loop)
        let created = expectation(description: "One coalesced CREATE on the TCP loop")
        let closed = expectation(description: "Termination on the TCP loop")
        try loop.submit {
            session.gfxPipelineEnabled = true
            session.dvc.handle(pdu: [0x50, 0, 3, 0])
            session.dvc.send = { bytes in
                XCTAssertTrue(loop.inEventLoop)
                if bytes.first.map({ $0 >> 4 }) == 1 { created.fulfill() }
            }
            session.onClose = {
                XCTAssertTrue(loop.inEventLoop)
                closed.fulfill()
            }
        }.wait()
        session.requestGraphicsCreate(reason: .channelClosed, delay: 0.02, countAsStorm: true, coalesce: true)
        session.requestGraphicsCreate(reason: .channelClosed, delay: 0.02, countAsStorm: true, coalesce: true)
        wait(for: [created], timeout: 1)
        session.terminate()
        wait(for: [closed], timeout: 1)
    }

    func testTerminatingSessionCancelsDelayedGraphicsRecovery() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let loop = group.next()
        let session = RDPSession(config: ServerConfig())
        session.noteMainEventLoop(loop)
        let created = expectation(description: "No CREATE after termination")
        created.isInverted = true
        try loop.submit {
            session.gfxPipelineEnabled = true
            session.dvc.handle(pdu: [0x50, 0, 3, 0])
            session.dvc.send = { bytes in
                if bytes.first.map({ $0 >> 4 }) == 1 { created.fulfill() }
            }
            session.requestGraphicsCreate(reason: .channelClosed, delay: 0.02, countAsStorm: true, coalesce: true)
            session.terminate()
        }.wait()
        wait(for: [created], timeout: 0.05)
    }

    func testAuthenticatedSessionLifecycleCallbacks() throws {
        let manager = try makeTestSessionManager(config: ServerConfig())
        let session = RDPSession(config: ServerConfig())
        var started: [UUID] = []
        var ended: [UUID] = []
        manager.onAuthenticatedSessionStarted = { started.append($0) }
        manager.onAuthenticatedSessionEnded = { ended.append($0) }

        manager.registerSession(session)
        XCTAssertTrue(manager.promoteSession(session))
        XCTAssertEqual(started, [session.id])

        manager.unregisterSession(session)
        XCTAssertEqual(ended, [session.id])
    }

    func testPromoteRestoresVirtualCaptureResolutionWithoutChangingRDPSize() throws {
        let config = ServerConfig(hostDisplayPolicy: .virtual)
        let manager = try makeTestSessionManager(config: config)
        let session = RDPSession(config: config)
        session.info.clientName = "iPhone"
        session.info.peerAddress = "192.0.2.10"
        manager.rememberedSettingsProvider = { _ in
            RememberedSessionSettings(
                identity: SessionClientIdentity(
                    clientName: "iPhone",
                    peerAddress: "192.0.2.10"
                ),
                videoQuality: VideoQualitySettings(mode: .ultra),
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
        XCTAssertEqual(session.videoController.configuredBitrate, 8_000_000)
        XCTAssertEqual(manager.connectionSnapshot.videoQuality, VideoQualitySettings(mode: .ultra))
    }

    func testDefaultVideoTargetsDoNotReplaceActiveClientSettings() throws {
        let manager = try makeTestSessionManager(config: ServerConfig())
        let session = RDPSession(config: ServerConfig(videoQuality: VideoQualitySettings(mode: .ultra)))
        manager.registerSession(session)
        XCTAssertTrue(manager.promoteSession(session))

        let quality = VideoQualitySettings(mode: .custom, customBitrate: 50_000_000)
        manager.updateDefaultVideoTargets(quality: quality, fps: 30)

        XCTAssertEqual(manager.config.videoQuality, quality)
        XCTAssertEqual(manager.config.fps, 30)
        XCTAssertEqual(session.videoController.configuredBitrate, 8_000_000)
        XCTAssertEqual(manager.connectionSnapshot.videoQuality, VideoQualitySettings(mode: .ultra))
        XCTAssertEqual(session.videoController.configuredFPS, 60)
    }

    func testDefaultVideoTargetsStayWithinSupportedBounds() throws {
        let manager = try makeTestSessionManager(config: ServerConfig())
        manager.updateDefaultVideoTargets(
            quality: VideoQualitySettings(mode: .custom, customBitrate: 500_000), fps: 144
        )
        XCTAssertEqual(manager.config.videoQuality.bitrateCeiling, 1_000_000)
        XCTAssertEqual(manager.config.fps, 60)
    }

    func testSessionSnapshotPreservesEqualBitrateModesAndCustomBudget() throws {
        let manager = try makeTestSessionManager()
        let session = RDPSession(config: ServerConfig())
        XCTAssertTrue(manager.registerSession(session))
        XCTAssertTrue(manager.promoteSession(session))

        for mode in [VideoQualityMode.automatic, .original, .custom] {
            let quality = VideoQualitySettings(mode: mode, customBitrate: 20_000_000)
            session.applyVideoQuality(quality)
            XCTAssertEqual(manager.connectionSnapshot.videoQuality, quality)
            XCTAssertEqual(session.videoController.configuredBitrate, 20_000_000)
        }

        let quality = VideoQualitySettings(mode: .automatic, customBitrate: 37_000_000)
        session.applyVideoQuality(quality)
        XCTAssertEqual(manager.connectionSnapshot.videoQuality, quality)
        XCTAssertEqual(session.videoController.configuredBitrate, 20_000_000)
    }

    func testHostCursorRetainRelease() throws {
        let manager = try makeTestSessionManager(config: ServerConfig())
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
        let manager = SessionManager(config: ServerConfig(), audit: try makeTestConnectionAudit())

        for host in 1...100 {
            let address = try SocketAddress(
                ipAddress: "198.51.100.\((host - 1) % 254 + 1)",
                port: 50000
            )
            XCTAssertTrue(manager.allowConnection(from: address))
        }
    }

    func testKnownPeersOnlyAllowsAuthenticatedAddress() throws {
        let audit = try makeTestConnectionAudit()
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
        let manager = SessionManager(config: ServerConfig(), audit: try makeTestConnectionAudit())

        XCTAssertTrue(manager.allowConnection(from: address))
        manager.applyKnownPeersOnly(true)
        XCTAssertFalse(manager.allowConnection(from: address))
        manager.applyKnownPeersOnly(false)
        XCTAssertTrue(manager.allowConnection(from: address))
    }

}
