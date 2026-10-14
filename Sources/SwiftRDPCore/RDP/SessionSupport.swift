import Foundation

/// Per-session metadata (`SessionInfo`).
public struct SessionInfo: Sendable {
    public var clientName: String = ""
    public var userName: String = ""
    /// TCP peer host (IPv4/IPv6), set when the channel becomes active.
    public var peerAddress: String = ""
    public var width: Int = 0
    public var height: Int = 0
    public var logonId: UInt32 = 0
    public var licensed: Bool = false
    /// Negotiated security: "NLA", "NLA-EX", "TLS", or empty before X.224 CC.
    public var securityLabel: String = ""
    /// Auto-Detect metrics (ms / kbps) for menu — filled after Network Characteristics Result.
    public var autoDetectRTTMs: UInt32 = 0
    public var autoDetectBandwidthKbps: UInt32 = 0

    public init() {}
}
