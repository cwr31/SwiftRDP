import Foundation
import CoreGraphics

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

/// Desktop composition DVC hook (`DesktopComposition`) — [MS-RDPEDC].
///
/// This host mirrors the full desktop via ScreenCaptureKit and does **not** implement
/// Windows DWM composition redirection. Capability set advertises COMPDESK_NOT_SUPPORTED;
/// the DVC stays quiet (no COMPOSITION_ON) so clients are not told a false mode.
public final class DesktopComposition {
    public static let channelName = "Microsoft::Windows::RDS::DesktopComposition"
    public var send: (([UInt8]) -> Void)?

    private static let compositionOn: UInt16 = 0x0001
    private static let compositionOff: UInt16 = 0x0002
    private static let dwmDeskEnter: UInt16 = 0x0003
    private static let dwmDeskLeave: UInt16 = 0x0004

    public init() {}

    public func attach(send: @escaping ([UInt8]) -> Void) {
        self.send = send
        RDPLog.rdp.debug("DesktopComposition: attached (composition not supported — idle)")
    }

    public func handle(_ data: [UInt8]) {
        guard data.count >= 4 else {
            RDPLog.rdp.info("DesktopComposition: received short data (\(data.count)B)")
            return
        }
        let header = UInt16(data[0]) | UInt16(data[1]) << 8
        switch header {
        case Self.compositionOn:
            RDPLog.rdp.info("DesktopComposition: client COMPOSITION_ON ignored (COMPDESK_NOT_SUPPORTED)")
        case Self.compositionOff:
            RDPLog.rdp.info("DesktopComposition: client COMPOSITION_OFF")
        case Self.dwmDeskEnter:
            RDPLog.rdp.info("DesktopComposition: client DWM_DESK_ENTER ignored")
        case Self.dwmDeskLeave:
            RDPLog.rdp.info("DesktopComposition: client DWM_DESK_LEAVE")
        default:
            RDPLog.rdp.info("DesktopComposition: received header=0x\(String(header, radix: 16))")
        }
    }

    public func sendCompositionOn() {
        // Intentionally no-op: do not claim composition while caps say unsupported.
        RDPLog.rdp.debug("DesktopComposition: COMPOSITION_ON suppressed")
    }

    public func sendCompositionOff() {
        guard let send else { return }
        send(buildOrder(Self.dwmDeskLeave))
        send(buildOrder(Self.compositionOff))
        RDPLog.rdp.info("DesktopComposition: sent COMPOSITION_OFF")
    }

    private func buildOrder(_ type: UInt16) -> [UInt8] {
        var b: [UInt8] = []
        b.appendU16(type)
        b.appendU16(4)
        return b
    }
}
