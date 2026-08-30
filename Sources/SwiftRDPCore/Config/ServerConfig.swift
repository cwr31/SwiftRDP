import Foundation

/// Display encoding mode for the RDP session.
public enum DisplayMode: String, Sendable, CaseIterable {
    case bitmap
    case h264
    case rfx
}

/// Host desktop source policy.
public enum HostDisplayPolicy: String, Sendable, CaseIterable {
    case automatic
    case virtual
}

/// Where captured system audio should be played during an RDP session.
public enum AudioPlaybackDestination: String, Codable, Sendable, CaseIterable, Identifiable {
    case controller
    case host
    case both

    public var id: String { rawValue }
    public var sendsToController: Bool { self != .host }
    public var suppressesHost: Bool { self == .controller }
}

/// TLS policy for CredSSP — Microsoft RDP clients are unreliable on TLS 1.3.
public enum TLSVersionMode: String, Sendable, CaseIterable {
    /// Pin TLS 1.2 only (mstsc default path).
    case tls12
    /// Allow TLS 1.2–1.3 (experimental; may break NLA with Windows App).
    case tls12Or13
}

/// Runtime configuration for one RDP session.
public struct ServerConfig: Sendable {
    public var port: Int
    public var bindHost: String
    public var username: String
    public var password: String
    /// When true, require CredSSP/NLA after TLS. When false, TLS-only (debug / some clients).
    public var nlaEnabled: Bool
    public var serverName: String
    public var width: Int
    public var height: Int
    public var fps: Int
    public var appSupportName: String
    /// Enable graphics pipeline (bitmap / H.264 / RFX).
    public var gfxEnabled: Bool
    public var clipboardEnabled: Bool
    public var audioPlaybackDestination: AudioPlaybackDestination
    public var displayMode: DisplayMode
    /// `IdleTimeout` — minutes of inactivity before disconnect (0 = off).
    public var idleTimeout: Int
    /// H.264 encode bitrate ceiling (bps). The target controller lowers it under pressure.
    public var videoBitrate: Int
    /// `TLSVersionMode`
    public var tlsVersionMode: TLSVersionMode
    /// `AsyncEncoding` — encode off the capture thread when true.
    public var asyncEncoding: Bool
    /// Stable physical display identity. Empty selects the current primary display.
    public var selectedDisplayIdentity: String
    public var hostDisplayPolicy: HostDisplayPolicy
    /// Scale applied to server-rendered RDP pointer shapes.
    public var remotePointerScale: Double
    /// `DevLog` — verbose protocol logging.
    public var devLog: Bool
    /// Trade-off when configured FPS and bitrate cannot both be sustained.
    public var videoAdaptationPriority: VideoAdaptationPriority
    /// Reject public addresses that have never completed authentication.
    public var knownPeersOnly: Bool

    public init(
        port: Int = 3389,
        bindHost: String = "0.0.0.0",
        username: String = "user",
        password: String = "password",
        nlaEnabled: Bool = true,
        serverName: String = "SwiftRDP",
        width: Int = 0,
        height: Int = 0,
        fps: Int = 60,
        appSupportName: String = "SwiftRDP",
        gfxEnabled: Bool = true,
        clipboardEnabled: Bool = true,
        audioPlaybackDestination: AudioPlaybackDestination = .both,
        displayMode: DisplayMode = .h264,
        idleTimeout: Int = 0,
        videoBitrate: Int = 20_000_000,
        tlsVersionMode: TLSVersionMode = .tls12,
        asyncEncoding: Bool = true,
        selectedDisplayIdentity: String = "",
        hostDisplayPolicy: HostDisplayPolicy = .automatic,
        remotePointerScale: Double = 2.0,
        devLog: Bool = false,
        videoAdaptationPriority: VideoAdaptationPriority = .qualityFirst,
        knownPeersOnly: Bool = false
    ) {
        self.port = port
        self.bindHost = bindHost
        self.username = username
        self.password = password
        self.nlaEnabled = nlaEnabled
        self.serverName = serverName
        self.width = width
        self.height = height
        self.fps = fps
        self.appSupportName = appSupportName
        self.gfxEnabled = gfxEnabled
        self.clipboardEnabled = clipboardEnabled
        self.audioPlaybackDestination = audioPlaybackDestination
        self.displayMode = displayMode
        self.idleTimeout = idleTimeout
        self.videoBitrate = Self.normalizedVideoBitrate(videoBitrate)
        self.tlsVersionMode = tlsVersionMode
        self.asyncEncoding = asyncEncoding
        self.selectedDisplayIdentity = selectedDisplayIdentity
        self.hostDisplayPolicy = hostDisplayPolicy
        self.remotePointerScale = min(max(remotePointerScale, 1.0), 3.0)
        self.devLog = devLog
        self.videoAdaptationPriority = videoAdaptationPriority
        self.knownPeersOnly = knownPeersOnly
    }

    public var appSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appSupportName, isDirectory: true)
    }

    public var certsURL: URL {
        appSupportURL.appendingPathComponent("certs", isDirectory: true)
    }

    public var ntlmURL: URL {
        appSupportURL.appendingPathComponent("ntlm", isDirectory: true)
    }

    public static let defaultVideoBitrate = 20_000_000

    public static func normalizedVideoBitrate(_ bps: Int) -> Int {
        bps > 0 ? max(bps, 1_000_000) : defaultVideoBitrate
    }
}
