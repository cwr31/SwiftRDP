import Foundation

/// Outcome of a recorded connection / auth event for the Connections UI.
public enum ConnectionHistoryOutcome: String, Codable, Sendable, CaseIterable {
    case connecting
    case active
    case disconnected
    case authFailed
    case abandoned
}

/// One row in the connection history list (newest first when displayed).
public struct ConnectionHistoryEntry: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var sessionID: UUID?
    public var peerAddress: String
    public var userName: String
    public var clientName: String
    public var securityLabel: String
    public var outcome: ConnectionHistoryOutcome
    public var detail: String
    public var timestamp: Date
    public var durationSeconds: Int?

    public init(
        id: UUID = UUID(),
        sessionID: UUID? = nil,
        peerAddress: String,
        userName: String = "",
        clientName: String = "",
        securityLabel: String = "",
        outcome: ConnectionHistoryOutcome,
        detail: String = "",
        timestamp: Date = Date(),
        durationSeconds: Int? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.peerAddress = peerAddress
        self.userName = userName
        self.clientName = clientName
        self.securityLabel = securityLabel
        self.outcome = outcome
        self.detail = detail
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
    }
}

/// Live client for the Connections page.
public struct LiveClientSnapshot: Identifiable, Sendable, Equatable {
    public enum State: String, Sendable {
        case connecting
        case active
    }

    public var id: UUID
    public var state: State
    public var peerAddress: String
    public var userName: String
    public var clientName: String
    public var securityLabel: String
    public var phaseLabel: String
    public var width: Int
    public var height: Int
    public var connectedAt: Date
    public var quality: VideoQualityStatus?
    public var captureSkippedFrames: UInt64
}

/// Connection history and successfully authenticated IPs.
public final class ConnectionAudit: @unchecked Sendable {
    public static let shared = ConnectionAudit(
        directoryURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftRDP", isDirectory: true)
    )

    /// Cap persisted history size.
    public var maxHistoryEntries: Int = 200

    private let lock = NSLock()
    private let directoryURL: URL
    private let historyURL: URL
    private let trustedPeersURL: URL
    private var history: [ConnectionHistoryEntry] = []
    private var successfulPeers: [String: Date] = [:]

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        self.historyURL = directoryURL.appendingPathComponent("connection-history.json", isDirectory: false)
        self.trustedPeersURL = directoryURL.appendingPathComponent("trusted-peers.json", isDirectory: false)
        loadHistory()
        loadTrustedPeers()
    }

    public func recordAuthFailure(
        peerAddress: String,
        userName: String = "",
        sessionID: UUID? = nil,
        detail: String = "",
        now: Date = Date()
    ) {
        let key = normalizedPeer(peerAddress)
        let message = detail.isEmpty
            ? (userName.isEmpty ? "Authentication failed" : "Authentication failed for \(userName)")
            : detail

        append(
            ConnectionHistoryEntry(
                sessionID: sessionID,
                peerAddress: key,
                userName: userName,
                outcome: .authFailed,
                detail: message,
                timestamp: now
            )
        )
        RDPLog.auth.error("Auth failure: \(key)")
    }

    public func recordAuthSuccess(peerAddress: String, now: Date = Date()) {
        let key = normalizedPeer(peerAddress)
        lock.lock()
        if key != "unknown" { successfulPeers[key] = now }
        lock.unlock()
        if key != "unknown" { persistTrustedPeers() }
    }

    public func isKnownPeer(_ peerAddress: String) -> Bool {
        let key = normalizedPeer(peerAddress)
        guard key != "unknown" else { return false }
        lock.lock()
        defer { lock.unlock() }
        return successfulPeers[key] != nil
    }

    // MARK: - History

    public func historyEntries() -> [ConnectionHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return history
    }

    public func clearHistory() {
        lock.lock()
        history.removeAll(keepingCapacity: false)
        lock.unlock()
        persistHistory()
        RDPLog.io.info("Connection history cleared")
    }

    public func record(
        sessionID: UUID? = nil,
        peerAddress: String,
        userName: String = "",
        clientName: String = "",
        securityLabel: String = "",
        outcome: ConnectionHistoryOutcome,
        detail: String = "",
        durationSeconds: Int? = nil,
        timestamp: Date = Date()
    ) {
        append(
            ConnectionHistoryEntry(
                sessionID: sessionID,
                peerAddress: normalizedPeer(peerAddress),
                userName: userName,
                clientName: clientName,
                securityLabel: securityLabel,
                outcome: outcome,
                detail: detail,
                timestamp: timestamp,
                durationSeconds: durationSeconds
            )
        )
    }

    // MARK: - Private

    private func append(_ entry: ConnectionHistoryEntry) {
        lock.lock()
        history.insert(entry, at: 0)
        if history.count > maxHistoryEntries {
            history = Array(history.prefix(maxHistoryEntries))
        }
        lock.unlock()
        persistHistory()
    }

    private func normalizedPeer(_ peer: String) -> String {
        let trimmed = peer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "unknown" }
        if trimmed.hasPrefix("["), let end = trimmed.firstIndex(of: "]") {
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
        }
        if let pct = trimmed.firstIndex(of: "%") {
            return String(trimmed[..<pct])
        }
        return trimmed
    }

    private func loadHistory() {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return }
        do {
            let data = try Data(contentsOf: historyURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([ConnectionHistoryEntry].self, from: data)
            history = Array(decoded.prefix(maxHistoryEntries))
        } catch {
            RDPLog.io.error("Connection history load failed: \(error)")
            history = []
        }
    }

    private func loadTrustedPeers() {
        guard FileManager.default.fileExists(atPath: trustedPeersURL.path) else { return }
        do {
            let data = try Data(contentsOf: trustedPeersURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            successfulPeers = try decoder.decode([String: Date].self, from: data)
        } catch {
            RDPLog.io.error("Trusted peers load failed: \(error)")
            successfulPeers = [:]
        }
    }

    private func persistHistory() {
        lock.lock()
        let snapshot = history
        lock.unlock()
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: historyURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
        } catch {
            RDPLog.io.error("Connection history save failed: \(error)")
        }
    }

    private func persistTrustedPeers() {
        lock.lock()
        let snapshot = successfulPeers
        lock.unlock()
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: trustedPeersURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: trustedPeersURL.path
            )
        } catch {
            RDPLog.io.error("Trusted peers save failed: \(error)")
        }
    }
}
