import Foundation

/// ITU T.125 MCS subset used by RDP (MS-RDPBCGR).
public enum MCS {
    // DomainMCSPDU choices (application tags)
    public static let connectInitial: UInt8 = 0x65      // app 101? Actually BER APPLICATION
    // Per MS: Connect-Initial is APPLICATION 101 (0x7F65) or in RDP often 0x7f 0x65
    // Wire format commonly: 0x7F 0x65 for Connect-Initial, 0x7F 0x66 for Connect-Response

    public static let erectDomainRequest: UInt8 = 1
    public static let disconnectProviderUltimatum: UInt8 = 8
    public static let attachUserRequest: UInt8 = 10
    public static let attachUserConfirm: UInt8 = 11
    public static let channelJoinRequest: UInt8 = 14
    public static let channelJoinConfirm: UInt8 = 15
    public static let sendDataRequest: UInt8 = 25
    public static let sendDataIndication: UInt8 = 26

    public struct ConnectInitial {
        public var calledDomainSelector: [UInt8]
        public var callingDomainSelector: [UInt8]
        public var upwardFlag: Bool
        public var targetParameters: DomainParameters
        public var minimumParameters: DomainParameters
        public var maximumParameters: DomainParameters
        public var userData: [UInt8] // GCC CCrq
    }

    public struct DomainParameters: Sendable {
        public var maxChannelIds: Int
        public var maxUserIds: Int
        public var maxTokenIds: Int
        public var numPriorities: Int
        public var minThroughput: Int
        public var maxHeight: Int
        public var maxMCSPDUsize: Int
        public var protocolVersion: Int

        public static let rdpDefault = DomainParameters(
            maxChannelIds: 34,
            maxUserIds: 3, // Connect Response uses 3 (not 2)
            maxTokenIds: 0,
            numPriorities: 1,
            minThroughput: 0,
            maxHeight: 1,
            maxMCSPDUsize: 65535,
            protocolVersion: 2
        )
    }

    // MARK: - Parse Connect-Initial

    public static func parseConnectInitial(_ data: [UInt8]) -> ConnectInitial? {
        // Expect APPLICATION 101: 0x7F 0x65
        var o = 0
        guard data.count > 4 else { return nil }
        if data[0] == 0x7F {
            guard data[1] == 0x65 else { return nil }
            o = 2
        } else if data[0] == 0x65 {
            o = 1
        } else {
            return nil
        }
        guard let len = BER.decodeLength(data, offset: &o) else { return nil }
        guard o + len <= data.count else { return nil }
        let body = Array(data[o..<(o + len)])
        return parseConnectInitialBody(body)
    }

    private static func parseConnectInitialBody(_ body: [UInt8]) -> ConnectInitial? {
        var o = 0
        // calledDomainSelector OCTET STRING
        guard let called = readOctetString(body, offset: &o) else { return nil }
        guard let calling = readOctetString(body, offset: &o) else { return nil }
        // upwardFlag BOOLEAN
        guard o + 3 <= body.count, body[o] == BER.tagBoolean else { return nil }
        let upward = body[o + 2] != 0
        o += 3
        guard let target = readDomainParameters(body, offset: &o) else { return nil }
        guard let minimum = readDomainParameters(body, offset: &o) else { return nil }
        guard let maximum = readDomainParameters(body, offset: &o) else { return nil }
        guard let userData = readOctetString(body, offset: &o) else { return nil }
        return ConnectInitial(
            calledDomainSelector: called,
            callingDomainSelector: calling,
            upwardFlag: upward,
            targetParameters: target,
            minimumParameters: minimum,
            maximumParameters: maximum,
            userData: userData
        )
    }

    private static func readOctetString(_ data: [UInt8], offset: inout Int) -> [UInt8]? {
        guard offset < data.count, data[offset] == BER.tagOctetString else { return nil }
        offset += 1
        guard let len = BER.decodeLength(data, offset: &offset) else { return nil }
        guard offset + len <= data.count else { return nil }
        let v = Array(data[offset..<(offset + len)])
        offset += len
        return v
    }

    private static func readDomainParameters(_ data: [UInt8], offset: inout Int) -> DomainParameters? {
        guard offset < data.count, data[offset] == BER.tagSequence else { return nil }
        offset += 1
        guard let len = BER.decodeLength(data, offset: &offset) else { return nil }
        let end = offset + len
        guard end <= data.count else { return nil }
        var vals: [Int] = []
        while offset < end {
            guard data[offset] == BER.tagInteger else { return nil }
            offset += 1
            guard let ilen = BER.decodeLength(data, offset: &offset) else { return nil }
            guard offset + ilen <= data.count else { return nil }
            var v = 0
            for _ in 0..<ilen {
                v = (v << 8) | Int(data[offset])
                offset += 1
            }
            vals.append(v)
        }
        guard vals.count >= 8 else { return nil }
        return DomainParameters(
            maxChannelIds: vals[0],
            maxUserIds: vals[1],
            maxTokenIds: vals[2],
            numPriorities: vals[3],
            minThroughput: vals[4],
            maxHeight: vals[5],
            maxMCSPDUsize: vals[6],
            protocolVersion: vals[7]
        )
    }

    // MARK: - Build PDUs

    public static func buildConnectResponse(userData: [UInt8], result: UInt8 = 0) -> [UInt8] {
        // Connect-Response ::= SEQUENCE {
        // result ENUMERATED,
        // calledConnectId INTEGER,
        // domainParameters DomainParameters,
        // userData OCTET STRING
        // } — APPLICATION 102 (0x7F 0x66)
        var seq: [UInt8] = []
        seq.append(contentsOf: BER.encodeEnumeration(result)) // rt-successful = 0
        seq.append(contentsOf: BER.encodeInteger(0)) // calledConnectId
        seq.append(contentsOf: encodeDomainParameters(.rdpDefault))
        seq.append(contentsOf: BER.encodeOctetString(userData))
        let body = BER.encodeLength(seq.count) + seq
        return [0x7F, 0x66] + body
    }

    public static func encodeDomainParameters(_ p: DomainParameters) -> [UInt8] {
        var inner: [UInt8] = []
        for v in [
            p.maxChannelIds, p.maxUserIds, p.maxTokenIds, p.numPriorities,
            p.minThroughput, p.maxHeight, p.maxMCSPDUsize, p.protocolVersion,
        ] {
            inner.append(contentsOf: BER.encodeInteger(v))
        }
        return BER.encodeSequence(inner)
    }

    public static func buildErectDomainRequest() -> [UInt8] {
        // Rarely needed from server; client sends it.
        [0x04, 0x01, 0x00, 0x01, 0x00]
    }

    public static func buildAttachUserConfirm(userId: UInt16, result: UInt8 = 0) -> [UInt8] {
        // PER: initiator is encoded as (userId - 1001)
        let initiator = userId >= 1001 ? userId - 1001 : userId
        var out: [UInt8] = []
        out.append(0x2E) // attachUserConfirm with initiator present
        out.append(result)
        out.appendU16(initiator, endian: .big)
        return out
    }

    public static func buildChannelJoinConfirm(userId: UInt16, channelId: UInt16, result: UInt8 = 0) -> [UInt8] {
        let initiator = userId >= 1001 ? userId - 1001 : userId
        var out: [UInt8] = []
        out.append(0x3E) // channelJoinConfirm
        out.append(result)
        out.appendU16(initiator, endian: .big)
        out.appendU16(channelId, endian: .big)
        out.appendU16(channelId, endian: .big)
        return out
    }

    public static func buildSendDataIndication(userId: UInt16, channelId: UInt16, data: [UInt8]) -> [UInt8] {
        let initiator = userId >= 1001 ? userId - 1001 : userId
        var out: [UInt8] = []
        out.append(0x68) // sendDataIndication
        out.appendU16(initiator, endian: .big)
        out.appendU16(channelId, endian: .big)
        out.append(0x70) // dataPriority high + segmentation
        // ITU-T X.691 / T.125 PER length determinant used by RDP:
        // < 128 → 1 byte; otherwise 2 bytes with high bit set (max 16 383).
        // Larger payloads must be fragmented at CHANNEL_PDU / application layer.
        precondition(
            data.count < 0x8000,
            "MCS SendDataIndication payload \(data.count) ≥ 16384; chunk at VC layer"
        )
        if data.count < 128 {
            out.append(UInt8(data.count))
        } else {
            out.appendU16(UInt16(data.count) | 0x8000, endian: .big)
        }
        out.append(contentsOf: data)
        return out
    }

    /// Byte length of the first Domain PDU in `data` (for concatenated PDUs).
    public static func domainPDULength(_ data: [UInt8]) -> Int? {
        guard let first = data.first else { return nil }
        let choice = first >> 2
        switch choice {
        case erectDomainRequest:
            // 04 01 00 01 00 — typical 5 bytes
            return min(5, data.count)
        case attachUserRequest:
            return 1
        case channelJoinRequest:
            return data.count >= 5 ? 5 : nil
        case sendDataRequest:
            guard data.count >= 7 else { return nil }
            var o = 6
            let length: Int
            if data[o] & 0x80 == 0 {
                length = Int(data[o]); o += 1
            } else {
                guard o + 2 <= data.count else { return nil }
                length = (Int(data[o] & 0x7F) << 8) | Int(data[o + 1]); o += 2
            }
            return o + length
        case disconnectProviderUltimatum:
            return data.count
        default:
            if first == 0x04 { return min(5, data.count) }
            return nil
        }
    }

    public static func parseDomainPDU(_ data: [UInt8]) -> DomainPDU? {
        guard let first = data.first else { return nil }
        let choice = first >> 2
        switch choice {
        case erectDomainRequest:
            return .erectDomain
        case attachUserRequest:
            return .attachUserRequest
        case channelJoinRequest:
            // 0x38 = 14<<2 — initiator is (userId - 1001) on the wire
            guard data.count >= 5 else { return nil }
            let initiator = UInt16(data[1]) << 8 | UInt16(data[2])
            let channelId = UInt16(data[3]) << 8 | UInt16(data[4])
            let userId = initiator < 1001 ? initiator + 1001 : initiator
            return .channelJoinRequest(userId: userId, channelId: channelId)
        case sendDataRequest:
            return parseSendDataRequest(data)
        case disconnectProviderUltimatum:
            return .disconnect
        default:
            // try alternate masks used by some clients
            // NOTE: 0x28 is AttachUserRequest (10<<2) — already handled above via choice.
            if first == 0x04 { return .erectDomain }
            if (first & 0xFC) == 0x38, data.count >= 5 {
                let initiator = UInt16(data[1]) << 8 | UInt16(data[2])
                let channelId = UInt16(data[3]) << 8 | UInt16(data[4])
                let userId = initiator < 1001 ? initiator + 1001 : initiator
                return .channelJoinRequest(userId: userId, channelId: channelId)
            }
            if (first & 0xFC) == 0x64 {
                return parseSendDataRequest(data)
            }
            RDPLog.rdp.debug("Unknown MCS domain PDU first=0x\(String(first, radix: 16)) choice=\(choice) \(data.hexPreview())")
            return nil
        }
    }

    private static func parseSendDataRequest(_ data: [UInt8]) -> DomainPDU? {
        guard data.count >= 7 else { return nil }
        let userId = UInt16(data[1]) << 8 | UInt16(data[2])
        let channelId = UInt16(data[3]) << 8 | UInt16(data[4])
        // data[5] = priority/segmentation
        var o = 6
        guard o < data.count else { return nil }
        let length: Int
        if data[o] & 0x80 == 0 {
            length = Int(data[o])
            o += 1
        } else {
            guard o + 2 <= data.count else { return nil }
            length = (Int(data[o] & 0x7F) << 8) | Int(data[o + 1])
            o += 2
        }
        guard o + length <= data.count else { return nil }
        let payload = Array(data[o..<(o + length)])
        return .sendDataRequest(userId: userId, channelId: channelId, data: payload)
    }

    public enum DomainPDU {
        case erectDomain
        case attachUserRequest
        case channelJoinRequest(userId: UInt16, channelId: UInt16)
        case sendDataRequest(userId: UInt16, channelId: UInt16, data: [UInt8])
        case disconnect
    }
}
