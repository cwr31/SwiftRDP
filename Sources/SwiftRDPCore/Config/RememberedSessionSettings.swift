import Foundation

/// Stable client identity used for per-connection settings.
public struct SessionClientIdentity: Sendable, Hashable {
    public let clientName: String
    public let peerAddress: String

    public init(clientName: String, peerAddress: String) {
        self.clientName = clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.peerAddress = peerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var stableKey: String {
        let normalizedName = clientName.lowercased()
        if !normalizedName.isEmpty {
            return "client:\(normalizedName)"
        }
        return "peer:\(peerAddress.lowercased())"
    }

    public var displayName: String {
        if !clientName.isEmpty { return clientName }
        if !peerAddress.isEmpty { return peerAddress }
        return "Unknown client"
    }
}

public struct RememberedResolution: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var logicalWidth: Int
    public var logicalHeight: Int
    public var hiDPI: Bool

    public init(width: Int, height: Int, logicalWidth: Int, logicalHeight: Int, hiDPI: Bool) {
        self.width = width
        self.height = height
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.hiDPI = hiDPI
    }
}

/// Durable overrides for one RDP client. Missing resolution means follow the client request.
public struct RememberedSessionSettings: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var clientName: String
    public var peerAddress: String
    public var videoBitrate: Int
    public var videoFPS: Int
    public var audioPlaybackDestination: AudioPlaybackDestination
    public var resolution: RememberedResolution?
    public var lastConnectedAt: Date

    public init(
        identity: SessionClientIdentity,
        videoBitrate: Int,
        videoFPS: Int,
        audioPlaybackDestination: AudioPlaybackDestination,
        resolution: RememberedResolution? = nil,
        lastConnectedAt: Date = Date()
    ) {
        self.id = identity.stableKey
        self.clientName = identity.clientName
        self.peerAddress = identity.peerAddress
        self.videoBitrate = videoBitrate
        self.videoFPS = videoFPS
        self.audioPlaybackDestination = audioPlaybackDestination
        self.resolution = resolution
        self.lastConnectedAt = lastConnectedAt
    }

    public var identity: SessionClientIdentity {
        SessionClientIdentity(clientName: clientName, peerAddress: peerAddress)
    }
}
