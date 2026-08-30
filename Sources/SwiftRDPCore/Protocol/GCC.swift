import Foundation

/// GCC Conference Create Request/Response user data blocks (MS-RDPBCGR).
public enum GCC {
    public static let csCore: UInt16 = 0xC001
    public static let csSecurity: UInt16 = 0xC002
    public static let csNet: UInt16 = 0xC003
    public static let csCluster: UInt16 = 0xC004
    public static let csMonitor: UInt16 = 0xC005
    public static let csMsgChannel: UInt16 = 0xC006
    public static let csMonitorEx: UInt16 = 0xC008

    public static let scCore: UInt16 = 0x0C01
    public static let scSecurity: UInt16 = 0x0C02
    public static let scNet: UInt16 = 0x0C03
    /// TS_UD_SC_MCS_MSGCHANNEL (MS-RDPBCGR 2.2.1.4.5)
    public static let scMsgChannel: UInt16 = 0x0C04

    /// RNS_UD_CS_SUPPORT_SKIP_CHANNELJOIN (MS-RDPBCGR 2.2.1.3.2) — NOT 0x0040 (monitor layout).
    public static let csSupportSkipChannelJoin: UInt16 = 0x0800
    /// RNS_UD_CS_SUPPORT_DYNVC_GFX_PROTOCOL (MS-RDPBCGR 2.2.1.3.2)
    public static let csSupportDynvcGfx: UInt16 = 0x0100
    /// RNS_UD_CS_SUPPORT_NETCHAR_AUTODETECT — client supports Network Characteristics Detection.
    public static let csSupportNetCharAutoDetect: UInt16 = 0x0080

    // MARK: SC_CORE earlyCapabilityFlags (MS-RDPBCGR 2.2.1.4.2)
    /// RNS_UD_SC_EDGE_ACTIONS_SUPPORTED_V1
    public static let scEdgeActionsSupportedV1: UInt32 = 0x0000_0001
    /// RNS_UD_SC_DYNAMIC_DST_SUPPORTED
    public static let scDynamicDSTSupported: UInt32 = 0x0000_0002
    /// RNS_UD_SC_EDGE_ACTIONS_SUPPORTED_V2
    public static let scEdgeActionsSupportedV2: UInt32 = 0x0000_0004
    /// RNS_UD_SC_SKIP_CHANNELJOIN_SUPPORTED
    public static let scSkipChannelJoinSupported: UInt32 = 0x0000_0008

    /// Highest `TS_UD_SC_CORE.version` we implement (matches FreeRDP default `RDP_VERSION_10_12`).
    public static let rdpVersionMax: UInt32 = 0x0008_0011
    /// Legacy RDP 5.0–8.1 server version (MS-RDPBCGR).
    public static let rdpVersion5Plus: UInt32 = 0x0008_0004

    /// Negotiate SC_CORE version the FreeRDP way: `MIN(serverMax, clientVersion)`,
    /// clamped to a known table entry (unknown client values fall back to `rdpVersion5Plus`).
    public static func negotiateRdpVersion(clientVersion: UInt32) -> UInt32 {
        let known: Set<UInt32> = [
            0x0008_0001,
            0x0008_0004,
            0x0008_0005, 0x0008_0006, 0x0008_0007, 0x0008_0008,
            0x0008_0009, 0x0008_000A, 0x0008_000B, 0x0008_000C,
            0x0008_000D, 0x0008_000E, 0x0008_000F, 0x0008_0010,
            0x0008_0011
        ]
        let capped = min(rdpVersionMax, clientVersion == 0 ? rdpVersionMax : clientVersion)
        if known.contains(capped) { return capped }
        // Client sent something odd — stay on the widely-supported 5+/8.x marker.
        return min(rdpVersionMax, rdpVersion5Plus)
    }

    public struct ClientCore {
        public var version: UInt32
        public var desktopWidth: UInt16
        public var desktopHeight: UInt16
        public var colorDepth: UInt16
        public var clientName: String
        public var earlyCapabilityFlags: UInt16
    }

    public struct ClientNet {
        public var channelCount: UInt32
        public var channels: [(name: String, options: UInt32)]
    }

    public struct ParsedClientData {
        public var core: ClientCore?
        public var net: ClientNet?
        /// CS_MCS_MSGCHANNEL present (logs `CS_MCS_MSGCHANNEL`).
        public var hasMsgChannel: Bool
        public var clusterFlags: UInt32?
        public var rawBlocks: [(type: UInt16, data: [UInt8])]
        public var supportsSkipChannelJoin: Bool {
            ((core?.earlyCapabilityFlags ?? 0) & csSupportSkipChannelJoin) != 0
        }
    }

    /// Extract userData from MCS Connect-Initial's GCC blob (H.221 key "Duca").
    public static func parseClientData(fromGCCUserData userData: [UInt8]) -> ParsedClientData {
        var result = ParsedClientData(
            core: nil, net: nil,
            hasMsgChannel: false, clusterFlags: nil, rawBlocks: []
        )
        guard let range = userData.firstRange(of: Array("Duca".utf8)) else {
            RDPLog.rdp.debug("GCC: H.221 key 'Duca' not found in GCC data")
            return result
        }
        var o = range.upperBound
        guard o < userData.count else { return result }
        // Length after "Duca" is a PER length determinant (not raw BE16).
        guard let (clientDataLen, lenBytes) = perLength(from: userData, offset: o) else {
            RDPLog.rdp.info("GCC: PER length after Duca failed")
            return result
        }
        o += lenBytes
        let end = min(userData.count, o + clientDataLen)
        RDPLog.rdp.debug("GCC userData: ducaOffset=\(range.lowerBound) len=\(clientDataLen) (perBytes=\(lenBytes))")
        RDPLog.rdp.info("GCC: H.221 key 'Duca' blocksEnd=\(end) remaining=\(end - o)")
        while o + 4 <= end {
            let type = UInt16(userData[o]) | UInt16(userData[o + 1]) << 8
            let len = Int(UInt16(userData[o + 2]) | UInt16(userData[o + 3]) << 8)
            o += 4
            guard len >= 4, o + (len - 4) <= end else {
                RDPLog.rdp.info(
                    "GCC: stop at type=0x\(String(type, radix: 16)) len=\(len) o=\(o) end=\(end)"
                )
                break
            }
            let payload = Array(userData[o..<(o + len - 4)])
            o += len - 4
            result.rawBlocks.append((type, payload))
            RDPLog.rdp.info("GCC block type=0x\(String(type, radix: 16)) payload=\(payload.count)B")
            switch type {
            case csCore:
                result.core = parseCore(payload)
            case csNet:
                result.net = parseNet(payload)
            case csCluster:
                if payload.count >= 4 {
                    let flags = u32(payload, 0)
                    result.clusterFlags = flags
                    RDPLog.rdp.info("CS_CLUSTER flags=0x\(String(flags, radix: 16))")
                }
            case csMonitor:
                RDPLog.rdp.info("CS_MONITOR (\(payload.count)B)")
            case csMonitorEx:
                RDPLog.rdp.info("CS_MONITOR_EX (\(payload.count)B)")
            case csMsgChannel:
                result.hasMsgChannel = true
                RDPLog.rdp.info("CS_MCS_MSGCHANNEL")
            default:
                break
            }
        }
        return result
    }

    /// ITU-T PER length determinant used in GCC octet strings.
    /// - length ≤ 127: 1 byte (bit7=0)
    /// - length < 16K: 2 bytes (bit7=1, bit6=0, low 14 bits = length)
    private static func perLength(from data: [UInt8], offset: Int) -> (length: Int, bytes: Int)? {
        guard offset < data.count else { return nil }
        let b0 = data[offset]
        if b0 & 0x80 == 0 {
            return (Int(b0), 1)
        }
        guard b0 & 0x40 == 0, offset + 1 < data.count else { return nil }
        let length = (Int(b0 & 0x3F) << 8) | Int(data[offset + 1])
        return (length, 2)
    }

    private static func parseCore(_ data: [UInt8]) -> ClientCore? {
        guard data.count >= 32 else { return nil }
        let version = u32(data, 0)
        let w = u16(data, 4)
        let h = u16(data, 6)
        let depth = u16(data, 8)
        var name = ""
        // clientName @ offset 20 (32 bytes UTF-16LE) — MS-RDPBCGR 2.2.1.3.2
        if data.count >= 52 {
            let nameBytes = Array(data[20..<52])
            name = String(bytes: nameBytes, encoding: .utf16LittleEndian)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
        }
        // earlyCapabilityFlags @ offset 140 in TS_UD_CS_CORE body
        var early: UInt16 = 0
        if data.count >= 142 {
            early = u16(data, 140)
        }
        return ClientCore(
            version: version,
            desktopWidth: w,
            desktopHeight: h,
            colorDepth: depth,
            clientName: name,
            earlyCapabilityFlags: early
        )
    }

    private static func parseNet(_ data: [UInt8]) -> ClientNet? {
        guard data.count >= 4 else { return nil }
        let count = u32(data, 0)
        var channels: [(String, UInt32)] = []
        var o = 4
        for _ in 0..<count {
            guard o + 12 <= data.count else { break }
            let nameBytes = Array(data[o..<(o + 8)])
            let name = String(bytes: nameBytes.filter { $0 != 0 }, encoding: .ascii) ?? ""
            let options = u32(data, o + 8)
            channels.append((name, options))
            o += 12
        }
        return ClientNet(channelCount: count, channels: channels)
    }

    private static func u16(_ d: [UInt8], _ o: Int) -> UInt16 {
        UInt16(d[o]) | UInt16(d[o + 1]) << 8
    }

    private static func u32(_ d: [UInt8], _ o: Int) -> UInt32 {
        UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
    }

    // MARK: Server response user data

    public static func buildServerUserData(
        selectedProtocol: UInt32,
        channelNames: [String],
        ioChannel: UInt16 = 1003,
        advertiseSkipChannelJoin: Bool = true,
        /// Must echo client's X.224 requestedProtocols (MS-RDPBCGR TS_UD_SC_CORE).
        clientRequestedProtocols: UInt32? = nil,
        /// Client `TS_UD_CS_CORE.version` — SC_CORE advertises `MIN(rdpVersionMax, this)`.
        clientRdpVersion: UInt32 = 0,
        /// emit SC_MCS_MSGCHANNEL when client sent CS_MCS_MSGCHANNEL.
        advertiseMsgChannel: Bool = false,
        msgChannelId: UInt16 = 1002
    ) -> [UInt8] {
        let negotiatedVersion = negotiateRdpVersion(clientVersion: clientRdpVersion)
        let scCore = buildSCCore(
            rdpVersion: negotiatedVersion,
            clientRequestedProtocols: clientRequestedProtocols ?? selectedProtocol,
            skipChannelJoin: advertiseSkipChannelJoin
        )
        let scSecurity = buildSCSecurity()
        let scNet = buildSCNet(ioChannel: ioChannel, channelNames: channelNames)
        var serverBlocks = scCore + scSecurity + scNet
        if advertiseMsgChannel {
            serverBlocks += buildSCMsgChannel(channelId: msgChannelId)
            RDPLog.rdp.info("SC_MCS_MSGCHANNEL: channelId=\(msgChannelId)")
        }

        // GCC Conference Create Response — / wire layout.
        // PER: choice(0) | T.124 OID | length(0x2A, ignored) | choice(0x14) | nodeID | tag | result |
        // numSets(1) | choice(0xC0) | octetString("McDn",min=4) | octetString(serverBlocks,min=0)
        var gcc: [UInt8] = []
        gcc.append(0x00) // ConnectData choice: object identifier
        // t124_02_98_oid = {0,0,20,124,0,1} → PER OID
        gcc.append(contentsOf: [0x05, 0x00, 0x14, 0x7C, 0x00, 0x01])
        gcc.append(0x2A) // connectPDU length (ignored by client per MS-RDPBCGR)
        gcc.append(0x14) // ConnectGCCPDU: conferenceCreateResponse
        // nodeID 0x79F3 with min 1001 → BE16(0x79F3-1001)=0x760A
        gcc.append(contentsOf: [0x76, 0x0A])
        gcc.append(contentsOf: [0x01, 0x01]) // tag INTEGER = 1 (PER length 1 + value)
        gcc.append(0x00) // result ENUMERATED success
        gcc.append(0x01) // number of UserData sets
        gcc.append(0xC0) // UserData present + h221NonStandard
        // octet_string("McDn", min=4) → length (4-4)=0, then key bytes
        gcc.append(0x00)
        gcc.append(contentsOf: Array("McDn".utf8))
        // octet_string(serverBlocks, min=0) → PER length + blocks
        gcc.append(contentsOf: perLength(serverBlocks.count))
        gcc.append(contentsOf: serverBlocks)
        return gcc
    }

    /// PER length determinant.
    private static func perLength(_ length: Int) -> [UInt8] {
        if length > 0x7F {
            let v = UInt16(length) | 0x8000
            return [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        }
        return [UInt8(length)]
    }

    private static func buildSCCore(rdpVersion: UInt32, clientRequestedProtocols: UInt32, skipChannelJoin: Bool) -> [UInt8] {
        // TS_UD_SC_CORE (MS-RDPBCGR 2.2.1.4.2): version | clientRequestedProtocols | earlyCapabilityFlags
        // No padding/unused field between version and protocols.
        // Early caps follow FreeRDP defaults: DYNAMIC_DST + optional SKIP_CHANNELJOIN.
        // EDGE_ACTIONS_V1/V2 stay off (Mac host; FreeRDP also leaves them unset by default).
        var body: [UInt8] = []
        body.appendU32(rdpVersion)
        body.appendU32(clientRequestedProtocols)
        var early: UInt32 = scDynamicDSTSupported
        if skipChannelJoin {
            early |= scSkipChannelJoinSupported
        }
        body.appendU32(early)
        return block(type: scCore, body: body)
    }

    private static func buildSCSecurity() -> [UInt8] {
        var body: [UInt8] = []
        body.appendU32(0) // encryptionMethod none (TLS already)
        body.appendU32(0) // encryptionLevel none
        body.appendU32(0) // serverRandomLen
        body.appendU32(0) // serverCertLen
        return block(type: scSecurity, body: body)
    }

    private static func buildSCNet(ioChannel: UInt16, channelNames: [String]) -> [UInt8] {
        var body: [UInt8] = []
        body.appendU16(ioChannel)
        body.appendU16(UInt16(channelNames.count))
        var id: UInt16 = 1004
        for _ in channelNames {
            body.appendU16(id)
            id += 1
        }
        if body.count % 4 != 0 {
            body.append(contentsOf: [UInt8](repeating: 0, count: 4 - (body.count % 4)))
        }
        return block(type: scNet, body: body)
    }

    /// TS_UD_SC_MCS_MSGCHANNEL — MCS message channel id.
    private static func buildSCMsgChannel(channelId: UInt16) -> [UInt8] {
        var body: [UInt8] = []
        body.appendU16(channelId)
        return block(type: scMsgChannel, body: body)
    }

    private static func block(type: UInt16, body: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.appendU16(type)
        out.appendU16(UInt16(body.count + 4))
        out.append(contentsOf: body)
        return out
    }
}
