import Foundation

/// Outbound Graphics channel boundary. Codec code emits protocol PDUs; the
/// transport owns segmentation, ZGFX state, serialization, and the channel write.
public protocol GraphicsTransport: AnyObject, Sendable {
    @discardableResult
    func sendGraphicsPDUs(
        _ pdus: [[UInt8]],
        compress: Bool,
        priority: RDPSocket.WritePriority
    ) -> Int?
    func reset()
}

/// RDP dynamic Graphics channel transport using one ZGFX segment per PDU.
public final class RDPGFXDynamicChannelTransport: GraphicsTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let sendFrame: ([[UInt8]], RDPSocket.WritePriority) -> Int?
    private let zgfx = ZGFXCompressor()

    public init(
        sendFrame: @escaping ([[UInt8]], RDPSocket.WritePriority) -> Int?
    ) {
        self.sendFrame = sendFrame
    }

    @discardableResult
    public func sendGraphicsPDUs(
        _ pdus: [[UInt8]],
        compress: Bool = true,
        priority: RDPSocket.WritePriority = .control
    ) -> Int? {
        guard !pdus.isEmpty else { return 0 }
        lock.lock()
        defer { lock.unlock() }

        var wrapped: [[UInt8]] = []
        wrapped.reserveCapacity(pdus.count)
        for pdu in pdus where !pdu.isEmpty {
            if pdu.count > ZGFXCompressor.maxSegmentUncompressed {
                RDPLog.gfx.info(
                    "GFX: ZGFX PDU \(pdu.count)B > \(ZGFXCompressor.maxSegmentUncompressed)B — " +
                    "multipart RDP8 bulk (E1)"
                )
            }
            // H.264 WIRE payloads are already entropy-coded; RFX/control PDUs
            // still benefit from ZGFX compression.
            wrapped.append(zgfx.wrap(pdu, compress: compress))
        }
        guard !wrapped.isEmpty else { return 0 }
        return sendFrame(wrapped, priority)
    }

    public func reset() {
        lock.lock()
        zgfx.reset()
        lock.unlock()
    }
}
