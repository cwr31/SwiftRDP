import XCTest
@testable import SwiftRDPCore

extension XCTestCase {
    func makeTestConnectionAudit() throws -> ConnectionAudit {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftrdp-test-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        return ConnectionAudit(directoryURL: directory)
    }

    func makeTestSessionManager(config: ServerConfig = ServerConfig()) throws -> SessionManager {
        SessionManager(config: config, audit: try makeTestConnectionAudit())
    }
}
