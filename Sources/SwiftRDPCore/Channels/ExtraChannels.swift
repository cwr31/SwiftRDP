import Foundation

// MARK: - Display / Geometry / Input

public final class DisplayControlChannel {
    public static let dvcName = "Microsoft::Windows::RDS::DisplayControl"
    public var send: (([UInt8]) -> Void)?
    public var onResize: ((Int, Int) -> Void)?

    private let maxMonitors: UInt32 = 16
    private var lastResize: (Int, Int)?
    private var lastResizeAt: Date = .distantPast

    public init() {}

    public func attach(send: @escaping ([UInt8]) -> Void) {
        self.send = send
        RDPLog.channels.info("DisplayControl: DVC attached")
        sendCaps()
    }

    public func handle(_ data: [UInt8]) {
        guard data.count >= 8 else { return }
        let msgType = UInt32(data[0]) | UInt32(data[1]) << 8 | UInt32(data[2]) << 16 | UInt32(data[3]) << 24
        if msgType == 0x0000_0005 {
            RDPLog.channels.debug("DisplayControl: client CAPS \(data.count)B")
            return
        }
        guard msgType == 0x0000_0002, data.count >= 16 else {
            RDPLog.channels.debug("DisplayControl: PDU type=0x\(String(msgType, radix: 16)) \(data.count)B")
            return
        }
        let layoutSize = Int(UInt32(data[8]) | UInt32(data[9]) << 8 | UInt32(data[10]) << 16 | UInt32(data[11]) << 24)
        let numMonitors = Int(UInt32(data[12]) | UInt32(data[13]) << 8 | UInt32(data[14]) << 16 | UInt32(data[15]) << 24)
        guard layoutSize == 40 else {
            RDPLog.channels.info("DisplayControl: invalid MonitorLayoutSize \(layoutSize)")
            return
        }
        guard numMonitors > 0, data.count >= 16 + layoutSize else {
            RDPLog.channels.debug("DisplayControl: truncated MONITOR_LAYOUT")
            return
        }
        let width = Int(UInt32(data[28]) | UInt32(data[29]) << 8 | UInt32(data[30]) << 16 | UInt32(data[31]) << 24)
        let height = Int(UInt32(data[32]) | UInt32(data[33]) << 8 | UInt32(data[34]) << 16 | UInt32(data[35]) << 24)
        RDPLog.channels.info("DisplayControl: resize request \(width)x\(height)")
        guard width >= 200, height >= 200, width <= 8192, height <= 8192 else { return }
        emitResize(width: width, height: height)
    }

    private func sendCaps() {
        var body: [UInt8] = []
        body.appendU32(0x0000_0005) // DISPLAYCONTROL_CAPS_PDU
        body.appendU32(20)
        body.appendU32(maxMonitors)
        body.appendU32(4096)
        body.appendU32(2048)
        send?(body)
        RDPLog.channels.info("DISP: sent CAPS (maxMonitors=\(maxMonitors))")
    }

    private func emitResize(width: Int, height: Int) {
        let now = Date()
        if let last = lastResize, last.0 == width, last.1 == height, now.timeIntervalSince(lastResizeAt) < 0.4 {
            return
        }
        lastResize = (width, height)
        lastResizeAt = now
        onResize?(width, height)
    }
}

/// [MS-RDPEGT] Geometry Tracking DVC — `Microsoft::Windows::RDS::Geometry::v08.01`.
public final class GeometryDVChannel {
    public static let dvcName = "Microsoft::Windows::RDS::Geometry::v08.01"
    public var send: (([UInt8]) -> Void)?

    public struct Mapping {
        public var left: Int32
        public var top: Int32
        public var right: Int32
        public var bottom: Int32
        public var width: Int32 { right - left + 1 }
        public var height: Int32 { bottom - top + 1 }
    }

    private var mappings: [UInt64: Mapping] = [:]

    public init() {}

    public func attach(send: @escaping ([UInt8]) -> Void) {
        self.send = send
        RDPLog.channels.info("Geometry: DVC attached (\(Self.dvcName))")
    }

    public func handle(_ data: [UInt8]) {
        guard data.count >= 8 else {
            RDPLog.channels.debug("Geometry: short PDU (\(data.count)B)")
            return
        }
        // MAPPED_GEOMETRY_PACKET / CLEAR share a versioned header.
        let pduType = UInt32(data[0]) | UInt32(data[1]) << 8 | UInt32(data[2]) << 16 | UInt32(data[3]) << 24
        let pduLength = Int(UInt32(data[4]) | UInt32(data[5]) << 8 | UInt32(data[6]) << 16 | UInt32(data[7]) << 24)
        if pduLength > 0, data.count < pduLength {
            RDPLog.channels.debug("Geometry: truncated type=0x\(String(pduType, radix: 16)) have=\(data.count) expect=\(pduLength)")
        }

        switch pduType {
        case RDPEGT.mappedGeometry:
            handleMappedGeometry(data)
        case RDPEGT.clearGeometry:
            handleClearGeometry(data)
        default:
            RDPLog.channels.debug("Geometry: unknown PDU type=0x\(String(pduType, radix: 16)) \(data.count)B")
        }
    }

    private func handleMappedGeometry(_ data: [UInt8]) {
        // Header(8) + mappingId(8) + ... geometry fields. Be tolerant of layout variants.
        guard data.count >= 24 else {
            RDPLog.channels.info("Geometry: MAPPED_GEOMETRY too short (\(data.count))")
            return
        }
        let mappingId = u64(data, 8)
        // Common layout after mappingId: left/top/right/bottom as INT32 (some clients include more).
        var left: Int32 = 0
        var top: Int32 = 0
        var right: Int32 = 0
        var bottom: Int32 = 0
        if data.count >= 40 {
            left = Int32(bitPattern: u32(data, 24))
            top = Int32(bitPattern: u32(data, 28))
            right = Int32(bitPattern: u32(data, 32))
            bottom = Int32(bitPattern: u32(data, 36))
        } else if data.count >= 32 {
            // Fallback: width/height after mappingId
            let width = Int32(bitPattern: u32(data, 16))
            let height = Int32(bitPattern: u32(data, 20))
            right = max(width - 1, 0)
            bottom = max(height - 1, 0)
        }
        mappings[mappingId] = Mapping(left: left, top: top, right: right, bottom: bottom)
        RDPLog.channels.info(
            "Geometry: MAPPED_GEOMETRY id=\(mappingId) rect=(\(left),\(top))-(\(right),\(bottom)) " +
            "total=\(mappings.count)"
        )
        // Full-desktop hosts do not rematerialize RAIL windows; ACK keeps the client happy.
        sendAck(mappingId: mappingId)
    }

    private func handleClearGeometry(_ data: [UInt8]) {
        guard data.count >= 16 else {
            mappings.removeAll()
            RDPLog.channels.info("Geometry: CLEAR_GEOMETRY (all)")
            return
        }
        let mappingId = u64(data, 8)
        mappings.removeValue(forKey: mappingId)
        RDPLog.channels.info("Geometry: CLEAR_GEOMETRY id=\(mappingId) remaining=\(mappings.count)")
    }

    private func sendAck(mappingId: UInt64) {
        // Some clients accept silent acceptance; emit a minimal ack-shaped PDU when send is live.
        guard let send else { return }
        var body: [UInt8] = []
        body.appendU32(RDPEGT.geometryAck)
        body.appendU32(16)
        body.appendU64(mappingId)
        send(body)
    }

    private func u32(_ d: [UInt8], _ o: Int) -> UInt32 {
        UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
    }

    private func u64(_ d: [UInt8], _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(d[o + i]) << (8 * i) }
        return v
    }
}

private enum RDPEGT {
    static let mappedGeometry: UInt32 = 0x0000_0001
    static let clearGeometry: UInt32 = 0x0000_0002
    static let geometryAck: UInt32 = 0x0000_0003
}

public final class GeometryTracking: VirtualChannel {
    public let name = "disp"
    public var send: (([UInt8]) -> Void)?

    /// Invoked when client requests a monitor layout / resize.
    public var onResize: ((Int, Int) -> Void)?

    private var channelId: UInt16 = 0
    private let maxMonitors: UInt32 = 16
    private var capsSent = false
    private var lastResize: (Int, Int)?
    private var lastResizeAt: Date = .distantPast

    public init() {}

    public func onOpen(channelId: UInt16) {
        self.channelId = channelId
        RDPLog.channels.info("GeometryTracking: channel setup (id=\(channelId))")
    }

    public func startHandshakeIfNeeded() {
        guard channelId != 0, !capsSent else { return }
        capsSent = true
        sendCaps()
    }

    public func onData(_ data: [UInt8]) {
        let body = data
        guard body.count >= 8 else {
            RDPLog.channels.debug("GeometryTracking: unexpected client data (\(body.count)B)")
            return
        }

        let msgType = UInt32(body[0]) | UInt32(body[1]) << 8 | UInt32(body[2]) << 16 | UInt32(body[3]) << 24
        switch msgType {
        case DISP.monitorLayoutPDU:
            handleMonitorLayout(body)
        default:
            RDPLog.channels.debug("GeometryTracking: unexpected client data (type=0x\(String(msgType, radix: 16)))")
        }
    }

    public func onClose() {
        RDPLog.channels.debug("DISP: channel closed")
        capsSent = false
        channelId = 0
        lastResize = nil
    }

    private func sendCaps() {
        var body: [UInt8] = []
        body.appendU32(DISP.capsPDU)
        body.appendU32(20)
        body.appendU32(maxMonitors)
        body.appendU32(4096)
        body.appendU32(2048)
        if let send {
            send(body)
            RDPLog.channels.info("DISP: sent CAPS (maxMonitors=\(maxMonitors))")
        } else {
            RDPLog.channels.error("DISP: CAPS send failed: no send path")
        }
    }

    private func handleMonitorLayout(_ body: [UInt8]) {
        guard body.count >= 16 else {
            RDPLog.channels.error("DISP: failed to parse MONITOR_LAYOUT_PDU")
            return
        }
        let layoutSize = Int(UInt32(body[8]) | UInt32(body[9]) << 8 | UInt32(body[10]) << 16 | UInt32(body[11]) << 24)
        let numMonitors = Int(UInt32(body[12]) | UInt32(body[13]) << 8 | UInt32(body[14]) << 16 | UInt32(body[15]) << 24)
        guard layoutSize == 40 else {
            RDPLog.channels.info("DisplayControl: invalid MonitorLayoutSize \(layoutSize)")
            RDPLog.channels.error("DISP: failed to parse MONITOR_LAYOUT_PDU")
            return
        }
        guard numMonitors > 0, body.count >= 16 + layoutSize else {
            RDPLog.channels.error("DISP: failed to parse MONITOR_LAYOUT_PDU")
            return
        }

        let width = Int(UInt32(body[28]) | UInt32(body[29]) << 8 | UInt32(body[30]) << 16 | UInt32(body[31]) << 24)
        let height = Int(UInt32(body[32]) | UInt32(body[33]) << 8 | UInt32(body[34]) << 16 | UInt32(body[35]) << 24)

        if numMonitors > 1 {
            RDPLog.channels.info("DISP: client monitor layout (\(numMonitors) monitors)")
        }
        RDPLog.channels.info("DISP: resize request \(width)x\(height)")

        guard width >= 200, height >= 200, width <= 8192, height <= 8192 else {
            RDPLog.channels.error("DISP: invalid resolution \(width)x\(height)")
            RDPLog.channels.info("DISP: layout rejected")
            return
        }

        let now = Date()
        if let last = lastResize, last.0 == width, last.1 == height, now.timeIntervalSince(lastResizeAt) < 0.4 {
            return
        }
        lastResize = (width, height)
        lastResizeAt = now

        RDPLog.channels.info("DISP: applying resolution \(width)x\(height)")
        onResize?(width, height)
        RDPLog.channels.info("DISP: resolution change complete \(width)x\(height)")
    }
}

private enum DISP {
    static let capsPDU: UInt32 = 0x0000_0005
    static let monitorLayoutPDU: UInt32 = 0x0000_0002
}
