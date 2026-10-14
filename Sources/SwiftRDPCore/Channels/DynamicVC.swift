import Foundation

/// DRDYNVC dynamic virtual channel manager (MS-RDPEDYC).
///
/// Wire header matches MS-RDPEDYC / MSTSC (Cmd in the **high** nibble):
/// `header = (Cmd << 4) | (Sp << 2) | cbId`
/// Standard CAPS requests use `0x50` (Cmd=caps, Sp=0).
public final class DynamicVCManager {
    public enum PDU: UInt8 {
        case create = 0x01 // CREATE_REQ and CREATE_RSP share Cmd
        case dataFirst = 0x02
        case data = 0x03
        case close = 0x04
        case caps = 0x05
        case dataFirstCompressed = 0x06
        case dataCompressed = 0x07
        case softSyncResponse = 0x09
    }

    public struct Channel {
        public let id: UInt32
        public let name: String
    }

    public static let graphicsDVCName = "Microsoft::Windows::RDS::Graphics"

    /// Outbound DRDYNVC bytes on the static `drdynvc` channel.
    public var send: (([UInt8]) -> Void)?
    /// Batched outbound DVC PDUs, used to enqueue one complete video frame atomically.
    public var sendBatch: (([[UInt8]], RDPSocket.WritePriority, RDPSocket.WriteCompletion?) -> Int?)?
    private var multitransportSender: (([[UInt8]], RDPSocket.WritePriority, RDPSocket.WriteCompletion?) -> Int?)?
    var sendMultitransportBatch: (([[UInt8]], RDPSocket.WritePriority, RDPSocket.WriteCompletion?) -> Int?)? {
        get { sendLock.withLock { multitransportSender } }
        set { sendLock.withLock { multitransportSender = newValue } }
    }
    var onSoftSyncResponse: (([UInt32]) -> Void)?
    /// Protected by sendLock so a complete frame belongs to exactly one transport.
    private var multitransportChannel: UInt32?

    private var nextChannelId: UInt32 = 1
    private var channelsById: [UInt32: Channel] = [:]
    private var channelsByName: [String: UInt32] = [:]
    private var createHandlers: [String: (UInt32, @escaping ([UInt8]) -> Void) -> Void] = [:]
    private var capsExchanged = false
    /// Set when server sends DYNVC_CAPS_VERSION3.
    private var capsSent = false
    /// Server-initiated creates awaiting client CREATE_RSP (MS-RDPEDYC: server sends CREATE_REQ).
    private var pendingCreateById: [UInt32: String] = [:]
    private var fragmentBuffers: [UInt32: (total: UInt32, data: [UInt8], started: Date)] = [:]
    /// MS-RDPEDYC 3.1.5: each DVC owns its decompression history across a transport switch.
    private var inboundDecoders: [UInt32: ZGFXCompressor] = [:]
    private let maxFragmentBytes = 16 * 1024 * 1024
    private var corruptionCount = 0
    private let maxPendingCreates = 32
    private let maxPendingFragments = 64
    /// MS-RDPEDYC 3.1.5 limits DVC PDUs to 1600 bytes on reliable transports.
    private static let maxDataPDUBytes = 1600
    /// Serializes complete logical DVC writes.
    private let sendLock = NSLock()
    /// CAPS response timeout: 10s.
    public static let capsResponseTimeoutNs: UInt64 = 10_000_000_000
    /// Fired once after CAPS exchange completes (server may then CREATE_REQ channels).
    public var onCapsExchanged: (() -> Void)?

    public init() {}

    public var hasCompletedCapsExchange: Bool { capsExchanged }

    // MARK: - Header

    /// Encode the common DRDYNVC header; individual PDU builders select `Sp`.
    private static func header(cmd: PDU, sp: UInt8 = 0, cbId: UInt8 = 0) -> UInt8 {
        (cmd.rawValue << 4) | ((sp & 0x03) << 2) | (cbId & 0x03)
    }

    private static func parseHeader(_ byte: UInt8) -> (cmd: UInt8, sp: UInt8, cbId: UInt8) {
        (
            (byte >> 4) & 0x0F,
            (byte >> 2) & 0x03,
            byte & 0x03
        )
    }

    // MARK: - Registration

    public func onCreate(
        name: String,
        callback: @escaping (UInt32, @escaping ([UInt8]) -> Void) -> Void
    ) {
        createHandlers[name] = callback
    }

    public func channelId(forName name: String) -> UInt32? {
        channelsByName[name]
    }

    // MARK: - Server CREATE_REQ (MS-RDPEDYC 2.2.2.1)

    /// Open a DVC from the server. Client replies with CREATE_RSP; then `onCreate` handler runs.
    public func createChannel(name: String, priority: UInt8 = 0) {
        if channelsByName[name] != nil {
            RDPLog.channels.info("DVC: CREATE_REQ skipped — channel already open (\(name))")
            return
        }
        if pendingCreateById.values.contains(name) {
            RDPLog.channels.info("DVC: CREATE_REQ skipped — create already pending (\(name))")
            return
        }
        guard capsExchanged else {
            RDPLog.channels.info("DVC: cannot create channel before caps exchange")
            return
        }
        guard let send else {
            RDPLog.channels.info("DVC: CREATE_REQ send failed channelId=0")
            return
        }
        if pendingCreateById.count >= maxPendingCreates {
            RDPLog.channels.info("DVC: too many pending creates (\(pendingCreateById.count))")
            return
        }
        let channelId = nextChannelId
        nextChannelId += 1
        let cbId = Self.widthCode(for: channelId)
        pendingCreateById[channelId] = name
        send(buildCreateRequest(name: name, channelId: channelId, cbChannelId: cbId, sp: priority))
        RDPLog.channels.info("DVC: CREATE_REQ channelId=\(channelId) name=\(name)")
    }

    /// Server-initiated CLOSE — used to recover a wedged Graphics pipeline.
    /// Clears local maps then notifies the close handler (same as client CLOSE).
    public func closeChannel(name: String) {
        guard let channelId = channelsByName[name] else { return }
        resetMultitransport(channelId: channelId)
        let cbId = Self.widthCode(for: channelId)
        if let send {
            send(buildClose(channelId: channelId, cbChannelId: cbId))
            RDPLog.channels.info("DVC: sent CLOSE channelId=\(channelId) name=\(name)")
        }
        channelsById.removeValue(forKey: channelId)
        channelsByName.removeValue(forKey: name)
        fragmentBuffers.removeValue(forKey: channelId)
        inboundDecoders.removeValue(forKey: channelId)
        dataHandlers.removeValue(forKey: channelId)
        if let close = closeHandlers.removeValue(forKey: channelId) {
            close()
        }
    }

    // MARK: - Inbound

    public func handle(pdu: [UInt8]) {
        expireFragments(now: Date())
        guard !pdu.isEmpty else {
            RDPLog.channels.debug("DRDYNVC: PDU too short (\(pdu.count)B)")
            return
        }
        var offset = 0
        while offset < pdu.count {
            let start = offset
            handleOne(pdu: pdu, offset: &offset)
            if offset <= start { break }
        }
    }

    /// The client's Soft-Sync response approves tunnels, not individual inbound DVCs.
    /// Accept data for any open DVC; its compression history stays with the channel.
    func handleMultitransport(pdu: [UInt8]) -> Bool {
        guard let byte = pdu.first else { return false }
        let header = Self.parseHeader(byte)
        guard [2, 3, 4, 6, 7].contains(header.cmd) else { return false }
        var offset = 1
        guard let channelId = readChannelId(pdu, offset: &offset, cbChId: header.cbId),
              channelsById[channelId] != nil || dataHandlers[channelId] != nil || dataRelay != nil else { return false }
        handle(pdu: pdu)
        return true
    }

    private func handleOne(pdu: [UInt8], offset: inout Int) {
        guard offset < pdu.count else { return }
        let parsed = Self.parseHeader(pdu[offset])
        offset += 1

        guard let type = PDU(rawValue: parsed.cmd) else {
            RDPLog.channels.info("DVC: unknown cmd=0x\(String(parsed.cmd, radix: 16)) hdr=0x\(String(pdu[offset - 1], radix: 16))")
            corruptionCount += 1
            if corruptionCount >= 8 {
                RDPLog.channels.info("DVC: protocol corruption threshold exceeded (\(corruptionCount))")
            }
            offset = pdu.count
            return
        }

        switch type {
        case .caps:
            handleCaps(pdu: pdu, offset: &offset)
        case .create:
            // Server→client CREATE_REQ; inbound on server is CREATE_RSP (channelId + status).
            handleCreateRsp(pdu: pdu, cbChId: parsed.cbId, offset: &offset)
        case .dataFirst:
            handleDataFirst(pdu: pdu, cbChId: parsed.cbId, sp: parsed.sp, offset: &offset)
            offset = pdu.count // data PDU consumes remainder of this VC message
        case .data:
            handleData(pdu: pdu, cbChId: parsed.cbId, offset: &offset)
            offset = pdu.count
        case .close:
            handleClose(pdu: pdu, cbChId: parsed.cbId, offset: &offset)
        case .dataFirstCompressed:
            handleCompressedDataFirst(
                pdu: pdu,
                cbChId: parsed.cbId,
                sp: parsed.sp,
                offset: &offset
            )
            offset = pdu.count
        case .dataCompressed:
            handleCompressedData(pdu: pdu, cbChId: parsed.cbId, offset: &offset)
            offset = pdu.count
        case .softSyncResponse:
            if let tunnels = MultitransportPDU.softSyncResponse(Array(pdu[(offset - 1)...])) {
                onSoftSyncResponse?(tunnels)
            }
            offset = pdu.count
        }
    }

    /// Bound fragment retention on inbound activity without a polling task.
    private func expireFragments(now: Date) {
        let timeout: TimeInterval = 10
        for (id, frag) in fragmentBuffers where now.timeIntervalSince(frag.started) > timeout {
            fragmentBuffers.removeValue(forKey: id)
            RDPLog.channels.info("DVC: fragment timeout channelId=\(id)")
        }
    }

    private func handleCaps(pdu: [UInt8], offset: inout Int) {
        if offset < pdu.count { offset += 1 } // pad
        guard pdu.count >= offset + 2 else {
            offset = pdu.count
            return
        }
        let version = UInt16(pdu[offset]) | UInt16(pdu[offset + 1]) << 8
        offset += 2
        inboundDecoders.removeAll()
        RDPLog.channels.debug("DRDYNVC: CAPS version=\(version)")

        let firstExchange = !capsExchanged
        let negotiatedVersion: UInt16
        if capsSent, !capsExchanged {
            capsExchanged = true
            negotiatedVersion = version
        } else if capsExchanged {
            negotiatedVersion = version
        } else {
            // Client initiated CAPS — reply with the negotiated version.
            capsExchanged = true
            capsSent = true
            let rspVersion = min(max(version, 1), 3)
            negotiatedVersion = rspVersion
            send?(buildCapsResponse(version: rspVersion))
        }

        RDPLog.channels.info("DVC: CAPS_RSP version=\(negotiatedVersion)")

        if firstExchange, capsExchanged {
            onCapsExchanged?()
        }
    }

    /// Server-first DYNVC_CAPS_VERSION3 once `onSend` is live.
    public func sendServerCapsIfNeeded() {
        guard !capsSent, !capsExchanged else { return }
        guard let send else {
            RDPLog.channels.debug("DVC: CAPS_VERSION3 deferred (send not wired)")
            return
        }
        send(buildCapsVersion3())
        capsSent = true
        RDPLog.channels.info("DVC: sent CAPS_VERSION3")
    }

    /// Client CREATE_RSP after our CREATE_REQ (MS-RDPEDYC 2.2.2.2).
    private func handleCreateRsp(pdu: [UInt8], cbChId: UInt8, offset: inout Int) {
        guard let channelId = readChannelId(pdu, offset: &offset, cbChId: cbChId),
              offset + 4 <= pdu.count else {
            RDPLog.channels.debug("DRDYNVC: CREATE_RSP parse failed")
            offset = pdu.count
            return
        }
        let status = UInt32(pdu[offset]) | UInt32(pdu[offset + 1]) << 8
            | UInt32(pdu[offset + 2]) << 16 | UInt32(pdu[offset + 3]) << 24
        offset += 4

        guard let name = pendingCreateById.removeValue(forKey: channelId) else {
            RDPLog.channels.info("DVC: CREATE_RSP channelId=\(channelId) (unexpected)")
            return
        }

        RDPLog.channels.info("DVC: CREATE_RSP channelId=\(channelId)")
        if status != 0 {
            let err = "status=0x\(String(status, radix: 16))"
            if name == Self.graphicsDVCName {
                RDPLog.channels.error("GFX: channel create failed: \(err)")
            } else {
                RDPLog.channels.error("DVC: channel create failed \(name): \(err)")
            }
            return
        }

        let channel = Channel(id: channelId, name: name)
        channelsById[channelId] = channel
        channelsByName[name] = channelId

        if name == Self.graphicsDVCName {
            RDPLog.channels.info("GFX: enabled — dynamic channel \(Self.graphicsDVCName) id=\(channelId)")
        } else {
            RDPLog.channels.debug("DRDYNVC: created channel '\(name)' id=\(channelId)")
        }

        if let handler = createHandlers[name] {
            let sendData: ([UInt8]) -> Void = { [weak self] payload in
                self?.sendData(channelId: channelId, payload: payload)
            }
            handler(channelId, sendData)
        }

    }

    private func handleDataFirst(
        pdu: [UInt8], cbChId: UInt8, sp: UInt8, offset: inout Int
    ) {
        guard let channelId = readChannelId(pdu, offset: &offset, cbChId: cbChId),
              let totalLen = readVariableUInt32(pdu, offset: &offset, widthCode: sp) else { return }
        acceptFirstChunk(channelId: channelId, totalLen: totalLen, chunk: Array(pdu[offset...]))
    }

    private func handleCompressedDataFirst(
        pdu: [UInt8], cbChId: UInt8, sp: UInt8, offset: inout Int
    ) {
        guard let channelId = readChannelId(pdu, offset: &offset, cbChId: cbChId),
              let totalLen = readVariableUInt32(pdu, offset: &offset, widthCode: sp),
              let chunk = decompressBulkPayload(Array(pdu[offset...]), channelId: channelId, command: "DATA_FIRST") else {
            return
        }
        acceptFirstChunk(channelId: channelId, totalLen: totalLen, chunk: chunk)
    }

    private func acceptFirstChunk(channelId: UInt32, totalLen: UInt32, chunk: [UInt8]) {
        if totalLen > UInt32(maxFragmentBytes) {
            RDPLog.channels.info("DVC: fragment too large (\(totalLen))")
            return
        }
        if fragmentBuffers.count >= maxPendingFragments {
            RDPLog.channels.info("DVC: too many pending fragments")
            return
        }
        fragmentBuffers[channelId] = (total: totalLen, data: chunk, started: Date())
        if chunk.count >= Int(totalLen) {
            deliver(channelId: channelId, payload: Array(chunk.prefix(Int(totalLen))))
            fragmentBuffers.removeValue(forKey: channelId)
        }
    }

    private func handleData(pdu: [UInt8], cbChId: UInt8, offset: inout Int) {
        guard let channelId = readChannelId(pdu, offset: &offset, cbChId: cbChId) else { return }
        acceptChunk(channelId: channelId, chunk: Array(pdu[offset...]))
    }

    private func handleCompressedData(
        pdu: [UInt8], cbChId: UInt8, offset: inout Int
    ) {
        guard let channelId = readChannelId(pdu, offset: &offset, cbChId: cbChId),
              let chunk = decompressBulkPayload(Array(pdu[offset...]), channelId: channelId, command: "DATA") else {
            return
        }
        acceptChunk(channelId: channelId, chunk: chunk)
    }

    private func decompressBulkPayload(_ payload: [UInt8], channelId: UInt32, command: String) -> [UInt8]? {
        guard channelsById[channelId] != nil || dataHandlers[channelId] != nil || dataRelay != nil else { return nil }
        let decoder: ZGFXCompressor
        if let existing = inboundDecoders[channelId] { decoder = existing }
        else {
            guard inboundDecoders.count < maxPendingFragments else { return nil }
            decoder = ZGFXCompressor()
            inboundDecoders[channelId] = decoder
        }
        guard let decoded = decoder.decompressSegment(payload) else {
            RDPLog.channels.error("DRDYNVC: failed to decompress \(command) RDP8 bulk segment")
            return nil
        }
        return decoded
    }

    private func acceptChunk(channelId: UInt32, chunk: [UInt8]) {
        if var frag = fragmentBuffers[channelId] {
            frag.data.append(contentsOf: chunk)
            guard frag.data.count <= maxFragmentBytes else {
                fragmentBuffers.removeValue(forKey: channelId)
                RDPLog.channels.info("DVC: fragment buffer exceeded \(frag.data.count)")
                return
            }
            if frag.data.count >= Int(frag.total) {
                deliver(channelId: channelId, payload: Array(frag.data.prefix(Int(frag.total))))
                fragmentBuffers.removeValue(forKey: channelId)
            } else {
                fragmentBuffers[channelId] = frag
            }
        } else {
            deliver(channelId: channelId, payload: chunk)
        }
    }

    private func handleClose(pdu: [UInt8], cbChId: UInt8, offset: inout Int) {
        guard let channelId = readChannelId(pdu, offset: &offset, cbChId: cbChId) else { return }
        resetMultitransport(channelId: channelId)
        inboundDecoders.removeValue(forKey: channelId)
        if let ch = channelsById.removeValue(forKey: channelId) {
            channelsByName.removeValue(forKey: ch.name)
            RDPLog.channels.info("DVC: CLOSE channelId=\(channelId) name=\(ch.name)")
        }
        fragmentBuffers.removeValue(forKey: channelId)
        dataHandlers.removeValue(forKey: channelId)
        if let close = closeHandlers.removeValue(forKey: channelId) {
            close()
        }
    }

    private func deliver(channelId: UInt32, payload: [UInt8]) {
        if let handler = dataHandlers[channelId] {
            handler(payload)
        } else {
            dataRelay?(channelId, payload)
        }
    }

    public var dataRelay: ((UInt32, [UInt8]) -> Void)?
    private var dataHandlers: [UInt32: ([UInt8]) -> Void] = [:]
    private var closeHandlers: [UInt32: () -> Void] = [:]

    public func setDataHandler(channelId: UInt32, handler: @escaping ([UInt8]) -> Void) {
        dataHandlers[channelId] = handler
    }

    public func setCloseHandler(channelId: UInt32, handler: @escaping () -> Void) {
        closeHandlers[channelId] = handler
    }

    // MARK: - Outbound builders

    private func buildCapsResponse(version: UInt16) -> [UInt8] {
        // CAPS_RSP: UINT16 0x0050 (= header 0x50 + pad 0x00), then version.
        var pdu: [UInt8] = []
        pdu.append(Self.header(cmd: .caps, sp: 0, cbId: 0)) // 0x50
        pdu.append(0)
        pdu.appendU16(version)
        return pdu
    }

    /// DYNVC_CAPS_VERSION3 (MS-RDPEDYC 2.2.1.1.3).
    public func buildCapsVersion3() -> [UInt8] {
        var pdu: [UInt8] = []
        pdu.append(Self.header(cmd: .caps))
        pdu.append(0)
        pdu.appendU16(3)
        // PriorityCharge0–3 — equal share (non-zero so formula is defined).
        pdu.appendU16(1000)
        pdu.appendU16(1000)
        pdu.appendU16(1000)
        pdu.appendU16(1000)
        return pdu
    }

    public func buildCreateRequest(
        name: String,
        channelId: UInt32 = 1,
        cbChannelId: UInt8 = 0,
        sp: UInt8 = 0
    ) -> [UInt8] {
        var pdu: [UInt8] = []
        pdu.append(Self.header(cmd: .create, sp: sp, cbId: cbChannelId))
        appendChannelId(&pdu, channelId: channelId, cbChannelId: cbChannelId)
        pdu.append(contentsOf: Array(name.utf8))
        pdu.append(0)
        return pdu
    }

    public func buildDataFirst(
        channelId: UInt32,
        totalLength: UInt32,
        payload: [UInt8],
        cbChannelId: UInt8 = 0,
        sp: UInt8? = nil
    ) -> [UInt8] {
        buildDataFirst(
            channelId: channelId,
            totalLength: totalLength,
            payload: payload[...],
            cbChannelId: cbChannelId,
            sp: sp
        )
    }

    public func buildDataFirst(
        channelId: UInt32,
        totalLength: UInt32,
        payload: ArraySlice<UInt8>,
        cbChannelId: UInt8 = 0,
        sp: UInt8? = nil
    ) -> [UInt8] {
        let lengthWidthCode = sp ?? Self.widthCode(for: totalLength)
        var pdu: [UInt8] = []
        pdu.reserveCapacity(1 + 4 + 4 + payload.count)
        pdu.append(Self.header(cmd: .dataFirst, sp: lengthWidthCode, cbId: cbChannelId))
        appendChannelId(&pdu, channelId: channelId, cbChannelId: cbChannelId)
        appendVariableUInt32(&pdu, value: totalLength, widthCode: lengthWidthCode)
        pdu.append(contentsOf: payload)
        return pdu
    }

    public func buildData(channelId: UInt32, payload: [UInt8], cbChannelId: UInt8 = 0) -> [UInt8] {
        buildData(channelId: channelId, payload: payload[...], cbChannelId: cbChannelId)
    }

    public func buildData(
        channelId: UInt32,
        payload: ArraySlice<UInt8>,
        cbChannelId: UInt8 = 0
    ) -> [UInt8] {
        var pdu: [UInt8] = []
        pdu.reserveCapacity(1 + 4 + payload.count)
        pdu.append(Self.header(cmd: .data, cbId: cbChannelId))
        appendChannelId(&pdu, channelId: channelId, cbChannelId: cbChannelId)
        pdu.append(contentsOf: payload)
        return pdu
    }

    public func buildClose(channelId: UInt32, cbChannelId: UInt8 = 0) -> [UInt8] {
        var pdu: [UInt8] = []
        pdu.append(Self.header(cmd: .close, cbId: cbChannelId))
        appendChannelId(&pdu, channelId: channelId, cbChannelId: cbChannelId)
        return pdu
    }

    public func sendData(channelId: UInt32, payload: [UInt8]) {
        _ = sendDataBatch(channelId: channelId, payloads: [payload], priority: .control)
    }

    @discardableResult
    public func sendDataBatch(
        channelId: UInt32,
        payloads: [[UInt8]],
        priority: RDPSocket.WritePriority,
        onWritten: RDPSocket.WriteCompletion? = nil
    ) -> Int? {
        guard !payloads.isEmpty else { return nil }

        // Build all fragments while holding the same lock used by single writes;
        // no other DVC message can interleave into a video frame.
        sendLock.lock()
        defer { sendLock.unlock() }
        guard let sender = multitransportChannel == channelId ? multitransportSender : sendBatch else {
            return nil
        }
        var pdus: [[UInt8]] = []
        for payload in payloads {
            pdus.append(contentsOf: makeDataPDUs(channelId: channelId, payload: payload))
        }
        guard !pdus.isEmpty else { return nil }
        return sender(pdus, priority, onWritten)
    }

    /// The request shares the ordered TCP graphics lane with earlier frames. New
    /// data enters UDP atomically, and TLS output waits for this TCP flush.
    func switchToMultitransport(channelId: UInt32, onTCPFlushed: @escaping RDPSocket.WriteCompletion) -> Bool {
        sendLock.lock()
        defer { sendLock.unlock() }
        guard multitransportChannel == nil, channelsById[channelId] != nil,
              multitransportSender != nil, let sendBatch,
              sendBatch([MultitransportPDU.softSyncRequest(channelID: channelId)], .graphicsControl, onTCPFlushed) != nil
        else { return false }
        multitransportChannel = channelId
        return true
    }

    func resetMultitransport(channelId: UInt32? = nil) {
        sendLock.lock()
        if channelId == nil || multitransportChannel == channelId { multitransportChannel = nil }
        sendLock.unlock()
    }

    private func makeDataPDUs(channelId: UInt32, payload: [UInt8]) -> [[UInt8]] {
        guard payload.count <= Int(UInt32.max) else {
            RDPLog.channels.info("DVC: fragment buffer exceeded \(payload.count)")
            return []
        }
        let total = UInt32(payload.count)
        let cbChannelId = Self.widthCode(for: channelId)
        let channelIdBytes = Self.byteWidth(for: cbChannelId)
        let maxChunk = Self.maxDataPDUBytes
        let singlePayloadLimit = maxChunk - (1 + channelIdBytes)
        guard singlePayloadLimit > 0 else { return [] }

        if payload.count <= singlePayloadLimit {
            return [buildData(
                channelId: channelId,
                payload: payload[...],
                cbChannelId: cbChannelId
            )]
        }

        let sp = Self.widthCode(for: total)
        let firstHeaderBytes = 1 + channelIdBytes + Self.byteWidth(for: sp)
        let firstChunkSize = maxChunk - firstHeaderBytes
        guard firstChunkSize > 0 else { return [] }

        var pdus: [[UInt8]] = []
        pdus.reserveCapacity((payload.count + singlePayloadLimit - 1) / singlePayloadLimit)
        let first = min(firstChunkSize, payload.count)
        pdus.append(buildDataFirst(
            channelId: channelId,
            totalLength: total,
            payload: payload[0..<first],
            cbChannelId: cbChannelId,
            sp: sp
        ))
        var offset = first
        while offset < payload.count {
            let end = min(offset + singlePayloadLimit, payload.count)
            pdus.append(buildData(
                channelId: channelId,
                payload: payload[offset..<end],
                cbChannelId: cbChannelId
            ))
            offset = end
        }
        return pdus
    }

    // MARK: - Helpers

    private func appendChannelId(_ pdu: inout [UInt8], channelId: UInt32, cbChannelId: UInt8) {
        appendVariableUInt32(&pdu, value: channelId, widthCode: cbChannelId)
    }

    private func readChannelId(_ pdu: [UInt8], offset: inout Int, cbChId: UInt8) -> UInt32? {
        readVariableUInt32(pdu, offset: &offset, widthCode: cbChId)
    }

    private static func widthCode(for value: UInt32) -> UInt8 {
        value <= UInt8.max ? 0 : (value <= UInt16.max ? 1 : 2)
    }

    private static func byteWidth(for widthCode: UInt8) -> Int {
        guard widthCode <= 2 else { return 0 }
        return 1 << Int(widthCode)
    }

    private func appendVariableUInt32(
        _ pdu: inout [UInt8], value: UInt32, widthCode: UInt8
    ) {
        let width = Self.byteWidth(for: widthCode)
        guard width > 0 else { return }
        var remaining = value
        for _ in 0..<width {
            pdu.append(UInt8(remaining & 0xFF))
            remaining >>= 8
        }
    }

    private func readVariableUInt32(
        _ pdu: [UInt8], offset: inout Int, widthCode: UInt8
    ) -> UInt32? {
        let width = Self.byteWidth(for: widthCode)
        guard width > 0 else { return nil }
        guard offset + width <= pdu.count else { return nil }
        var value: UInt32 = 0
        for i in 0..<width {
            value |= UInt32(pdu[offset + i]) << (8 * i)
        }
        offset += width
        return value
    }
}

/// Thin VirtualChannel adapter for the static `drdynvc` channel.
public final class DrdynvcChannel: VirtualChannel {
    public let name = "drdynvc"
    public let manager: DynamicVCManager
    public var send: (([UInt8]) -> Void)?
    public var sendBatch: (([[UInt8]], RDPSocket.WritePriority, RDPSocket.WriteCompletion?) -> Int?)?

    public init(manager: DynamicVCManager = DynamicVCManager()) {
        self.manager = manager
    }

    public func onOpen(channelId: UInt16) {
        RDPLog.channels.debug("drdynvc open \(channelId)")
        manager.send = { [weak self] pdu in self?.send?(pdu) }
        manager.sendBatch = { [weak self] pdus, priority, onWritten in
            self?.sendBatch?(pdus, priority, onWritten)
        }
        // CAPS is sent from RDPSession after Confirm Active (session path),
        // not at MCS Channel Join (too early for iPhone — before Client Info).
    }

    public func onData(_ data: [UInt8]) {
        if data.isEmpty {
            RDPLog.channels.info("DRDYNVC: empty PDU")
            return
        }
        let cmd = (data[0] >> 4) & 0x0F
        RDPLog.channels.debug("DRDYNVC: inbound \(data.count)B cmd=0x\(String(cmd, radix: 16)) hdr=0x\(String(data[0], radix: 16))")
        manager.handle(pdu: data)
    }

    public func onClose() {
        RDPLog.channels.debug("drdynvc close")
    }
}
