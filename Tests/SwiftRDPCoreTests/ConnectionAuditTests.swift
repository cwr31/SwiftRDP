import XCTest
@testable import SwiftRDPCore

final class ConnectionAuditTests: XCTestCase {
    func testSessionManagersUseIsolatedAuditStoresInTests() throws {
        let first = try makeTestSessionManager()
        let second = try makeTestSessionManager()
        first.audit.recordAuthSuccess(peerAddress: "192.0.2.10")
        first.audit.record(peerAddress: "192.0.2.10", outcome: .active)
        XCTAssertTrue(first.audit.isKnownPeer("192.0.2.10"))
        XCTAssertFalse(second.audit.isKnownPeer("192.0.2.10"))
        XCTAssertTrue(second.audit.historyEntries().isEmpty)
    }

    private func tempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mhrdp-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testAuthFailureIsRecordedWithoutTrustingPeer() throws {
        let audit = ConnectionAudit(directoryURL: try tempDirectory())

        audit.recordAuthFailure(peerAddress: "198.51.100.20", userName: "bob")

        XCTAssertFalse(audit.isKnownPeer("198.51.100.20"))
        XCTAssertEqual(audit.historyEntries().first?.outcome, .authFailed)
        XCTAssertEqual(audit.historyEntries().first?.userName, "bob")
    }

    func testSuccessfulAuthMarksKnownPeer() throws {
        let audit = ConnectionAudit(directoryURL: try tempDirectory())

        audit.recordAuthSuccess(peerAddress: "203.0.113.46")

        XCTAssertTrue(audit.isKnownPeer("203.0.113.46"))
    }

    func testUnknownPeerNeverBecomesTrusted() throws {
        let audit = ConnectionAudit(directoryURL: try tempDirectory())

        audit.recordAuthSuccess(peerAddress: "unknown")

        XCTAssertFalse(audit.isKnownPeer("unknown"))
    }

    func testKnownPeerPersistsIndependentlyOfHistory() throws {
        let directory = try tempDirectory()
        let first = ConnectionAudit(directoryURL: directory)
        first.recordAuthSuccess(peerAddress: "203.0.113.45")
        first.clearHistory()

        let reloaded = ConnectionAudit(directoryURL: directory)

        XCTAssertTrue(reloaded.isKnownPeer("203.0.113.45"))
        XCTAssertTrue(reloaded.historyEntries().isEmpty)
    }

    func testHistoryClear() throws {
        let audit = ConnectionAudit(directoryURL: try tempDirectory())
        audit.record(peerAddress: "192.0.2.1", outcome: .connecting, detail: "hi")
        XCTAssertFalse(audit.historyEntries().isEmpty)

        audit.clearHistory()

        XCTAssertTrue(audit.historyEntries().isEmpty)
    }
}
