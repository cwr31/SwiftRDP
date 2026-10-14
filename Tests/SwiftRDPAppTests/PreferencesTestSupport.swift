import Foundation
import SwiftRDPCore
import Testing
@testable import SwiftRDPApp

@MainActor
extension AppPreferences {
    func rememberTestConnection(clientName: String, peerAddress: String) {
        var snapshot = SessionManager.ConnectionSnapshot.empty
        snapshot.clientName = clientName
        snapshot.peerAddress = peerAddress
        snapshot.videoQuality = videoQuality
        snapshot.configuredFPS = videoFPS
        snapshot.audioPlaybackDestination = audioPlaybackDestination
        rememberConnection(snapshot)
    }
}

@MainActor
func withTestSession(
    prefs: AppPreferences,
    quality: VideoQualitySettings,
    _ test: (RDPSession) throws -> Void
) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("swiftrdp-app-test-audit-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = ServerConfig(videoQuality: quality)
    let manager = SessionManager(config: config, audit: ConnectionAudit(directoryURL: directory))
    let session = RDPSession(config: config)
    session.info.clientName = "First"
    session.info.peerAddress = "192.0.2.1"
    try #require(manager.registerSession(session))
    try #require(manager.promoteSession(session))
    prefs.sessionManagerProvider = { manager }
    defer {
        prefs.sessionManagerProvider = nil
        session.terminate()
    }
    try test(session)
}
