import Foundation

/// Virtual channel plugin interface — P1+ implementations plug in here.
public protocol VirtualChannel: AnyObject {
    var name: String { get }
    var send: (([UInt8]) -> Void)? { get set }
    func onOpen(channelId: UInt16)
    func onData(_ data: [UInt8])
    func onClose()
}

/// Routes MCS virtual-channel traffic by static channel name.
public final class VirtualChannelRouter {
    private let config: ServerConfig
    private var channels: [String: VirtualChannel] = [:]
    private var idToName: [UInt16: String] = [:]
    public var sendToChannel: ((UInt16, [UInt8]) -> Void)?
    public var sendToChannelBatch: ((UInt16, [[UInt8]], RDPSocket.WritePriority) -> Int?)?

    /// Negotiated CHANNEL_CHUNK_LENGTH (server Demand Active default: 16256).
    public var chunkSize: Int = ChannelPDU.defaultChunkSize

    /// Shared DRDYNVC manager (for GFX registration).
    public let dynamicVC: DynamicVCManager
    private let drdynvc: DrdynvcChannel

    private struct FragmentBuffer {
        var total: Int
        var data: [UInt8]
    }

    private var inboundFragments: [UInt16: FragmentBuffer] = [:]

    public init(config: ServerConfig = ServerConfig()) {
        self.config = config
        let dyn = DynamicVCManager()
        self.dynamicVC = dyn
        self.drdynvc = DrdynvcChannel(manager: dyn)
        registerDefaults(config: config)
    }

    /// Channels this host can service when enabled. Still listed in SC_NET even when
    /// disabled/unimplemented so `channelIdArray` stays 1:1 with CS_NET order.
    public static let supportedStaticChannelNames: Set<String> = [
        "cliprdr",
        "rdpsnd",
        "drdynvc",
        "disp",
    ]

    /// Register default virtual channel handlers (implemented channels only).
    public func registerDefaults(config: ServerConfig) {
        if config.clipboardEnabled {
            register(ClipboardSync())
        }
        register(AudioPlayback(playbackEnabled: config.audioPlaybackDestination.sendsToController))
        register(drdynvc)
        register(GeometryTracking())
    }

    /// Register or replace a channel handler.
    public func register(_ channel: VirtualChannel) {
        channels[channel.name] = channel
        wireSend(channel)
    }

    public func channel(named name: String) -> VirtualChannel? {
        channels[name]
    }

    /// Map MCS channel id after GCC channel negotiation / join.
    public func bind(channelId: UInt16, name: String) {
        let key = Self.normalizeChannelName(name).lowercased()
        // SKIP_CHANNELJOIN clients can pipeline AttachUser after the Connect
        // Response. Treat a repeated bind as a no-op so channel open callbacks
        // cannot reset an already active stream.
        if idToName[channelId] == key {
            return
        }
        idToName[channelId] = key
        if let ch = channels[key] {
            ch.onOpen(channelId: channelId)
        } else if let match = channels.first(where: { key.hasPrefix($0.key.lowercased()) }) {
            idToName[channelId] = match.key
            match.value.onOpen(channelId: channelId)
        } else {
            // Still joined for SC_NET ID alignment; inbound PDUs are ignored.
            RDPLog.channels.info("VC bind: placeholder '\(key)' (id=\(channelId))")
        }
    }

    public func bindAll(from channelMap: [UInt16: String]) {
        for (id, name) in channelMap where name != "I/O" {
            bind(channelId: id, name: name)
        }
    }

    public func handle(channelId: UInt16, payload: [UInt8]) {
        guard let name = idToName[channelId], let ch = channels[name] else {
            RDPLog.channels.debug("VC \(channelId): \(payload.count)B (unbound)")
            return
        }
        guard let hdr = ChannelPDU.parse(payload) else {
            RDPLog.channels.error("VC \(channelId): invalid CHANNEL_PDU_HEADER (\(payload.count)B)")
            return
        }

        if hdr.flags & ChannelPDU.flagFirst != 0 {
            inboundFragments[channelId] = FragmentBuffer(total: hdr.length, data: hdr.payload)
        } else {
            guard var buf = inboundFragments[channelId] else {
                RDPLog.channels.error("VC \(channelId): CHANNEL_PDU fragment without FIRST")
                return
            }
            guard buf.total == hdr.length else {
                RDPLog.channels.error("VC \(channelId): CHANNEL_PDU length mismatch across fragments")
                inboundFragments.removeValue(forKey: channelId)
                return
            }
            buf.data.append(contentsOf: hdr.payload)
            inboundFragments[channelId] = buf
        }

        guard hdr.flags & ChannelPDU.flagLast != 0 else { return }
        guard let complete = inboundFragments.removeValue(forKey: channelId) else { return }
        guard complete.data.count == complete.total else {
            RDPLog.channels.error(
                "VC \(channelId): CHANNEL_PDU incomplete (\(complete.data.count)/\(complete.total))"
            )
            return
        }
        ch.onData(complete.data)
    }

    public func closeAll() {
        for (_, name) in idToName {
            channels[name]?.onClose()
        }
        idToName.removeAll()
        inboundFragments.removeAll()
    }

    public static func normalizeChannelName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\0", with: "")
    }

    /// Build the SC_NET channel list from CS_NET.
    ///
    /// MS-RDPBCGR 2.2.1.4.4: `channelIdArray` is positional against the client's
    /// CHANNEL_DEF list. Dropping a middle entry (classic case: `rdpsnd` while audio
    /// is off) shifts IDs so mstsc maps `cliprdr`/`drdynvc` to the wrong MCS channels —
    /// DVC CAPS then lands on the wrong endpoint and H.264 never starts.
    ///
    /// Keep every non-empty CS_NET name in order. Disabled/unimplemented channels stay
    /// as placeholders (joined, no handler).
    public func filterAcceptedChannelNames(_ names: [String]) -> [String] {
        var accepted: [String] = []
        for raw in names {
            let key = Self.normalizeChannelName(raw)
            guard !key.isEmpty else { continue }
            let lower = key.lowercased()
            accepted.append(lower)

            if channels[lower] != nil {
                continue
            }
            if Self.supportedStaticChannelNames.contains(lower) {
                let reason: String
                switch lower {
                case "cliprdr" where !config.clipboardEnabled:
                    reason = "clipboard disabled"
                default:
                    reason = "no handler registered"
                }
                RDPLog.channels.info("VC: SC_NET keeps '\(lower)' for ID alignment (\(reason))")
            } else {
                RDPLog.channels.info("VC: SC_NET keeps '\(lower)' for ID alignment (unimplemented)")
            }
        }
        return accepted
    }

    private func wireSend(_ channel: VirtualChannel) {
        channel.send = { [weak self, weak channel] body in
            guard let self, let channel else { return }
            guard let channelId = self.idToName.first(where: { $0.value == channel.name })?.key else {
                RDPLog.channels.debug("VC send: '\(channel.name)' not bound")
                return
            }
            // Channel plugins always send raw channel body; router applies CHANNEL_PDU chunking.
            for framed in ChannelPDU.chunk(body, chunkSize: self.chunkSize) {
                self.sendToChannel?(channelId, framed)
            }
        }
        if let drdynvc = channel as? DrdynvcChannel {
            drdynvc.sendBatch = { [weak self, weak drdynvc] bodies, priority in
                guard let self, let drdynvc,
                      let channelId = self.idToName.first(where: { $0.value == drdynvc.name })?.key
                else { return nil }
                let framedBodies = bodies.flatMap {
                    ChannelPDU.chunk($0, chunkSize: self.chunkSize)
                }
                if let sendToChannelBatch = self.sendToChannelBatch {
                    return sendToChannelBatch(channelId, framedBodies, priority)
                }
                for body in framedBodies {
                    self.sendToChannel?(channelId, body)
                }
                return framedBodies.reduce(0) { $0 + $1.count }
            }
        }
    }
}
