import Foundation

/// MS-RDPBCGR 2.2.14 Network Characteristics / Auto-Detect PDUs
/// (message channel, Basic Security Header + RDP_AUTODETECT_* body).
public enum AutoDetectPDU {
    public static let secAutoDetectReq: UInt16 = 0x1000
    public static let secAutoDetectRsp: UInt16 = 0x2000

    public static let typeIdRequest: UInt8 = 0x00
    public static let typeIdResponse: UInt8 = 0x01

    // Server → client requestType
    public static let rttRequestContinuous: UInt16 = 0x0001
    public static let rttRequestConnectTime: UInt16 = 0x1001
    public static let bwStartContinuous: UInt16 = 0x0014
    public static let bwStartConnectTime: UInt16 = 0x1014
    public static let bwPayload: UInt16 = 0x0002
    public static let bwStopConnectTime: UInt16 = 0x002B
    public static let bwStopContinuous: UInt16 = 0x0429
    public static let netCharBaseRTTAvgRTT: UInt16 = 0x0840
    public static let netCharBandwidthAvgRTT: UInt16 = 0x0880
    public static let netCharBaseRTTBandwidthAvgRTT: UInt16 = 0x08C0

    // Client → server responseType
    public static let rttResponse: UInt16 = 0x0000
    public static let bwResultsConnectTime: UInt16 = 0x0003
    public static let bwResultsContinuous: UInt16 = 0x000B
    public static let netCharSync: UInt16 = 0x0018

    public enum ClientResponse: Equatable, Sendable {
        case rtt(sequenceNumber: UInt16)
        case bandwidthResults(sequenceNumber: UInt16, responseType: UInt16, timeDeltaMs: UInt32, byteCount: UInt32)
        case netCharSync(sequenceNumber: UInt16, bandwidthKbps: UInt32, rttMs: UInt32)
    }

    public static func bandwidthKbps(timeDeltaMs: UInt32, byteCount: UInt32) -> UInt32 {
        guard byteCount > 0, timeDeltaMs > 0 else { return 0 }
        let bits = UInt64(byteCount) * 8
        return UInt32(min(bits / UInt64(timeDeltaMs), UInt64(UInt32.max)))
    }

    public static func encodeRTTRequest(sequenceNumber: UInt16, connectTime: Bool) -> [UInt8] {
        encodeRequestHeader(
            headerLength: 0x06,
            sequenceNumber: sequenceNumber,
            requestType: connectTime ? rttRequestConnectTime : rttRequestContinuous
        )
    }

    public static func encodeBandwidthStart(sequenceNumber: UInt16, connectTime: Bool) -> [UInt8] {
        encodeRequestHeader(
            headerLength: 0x06,
            sequenceNumber: sequenceNumber,
            requestType: connectTime ? bwStartConnectTime : bwStartContinuous
        )
    }

    public static func encodeBandwidthPayload(sequenceNumber: UInt16, payloadLength: UInt16) -> [UInt8] {
        var body = encodeRequestHeader(
            headerLength: 0x08,
            sequenceNumber: sequenceNumber,
            requestType: bwPayload
        )
        // Strip the outer SEC header from the helper and rebuild with payloadLength.
        // Helper already includes SEC + 6-byte auto-detect header; append payloadLength + zeros.
        body.appendU16(payloadLength)
        if payloadLength > 0 {
            body.append(contentsOf: [UInt8](repeating: 0x5A, count: Int(payloadLength)))
        }
        return body
    }

    public static func encodeBandwidthStop(sequenceNumber: UInt16, connectTime: Bool, payloadLength: UInt16 = 0) -> [UInt8] {
        if connectTime {
            var body = encodeRequestHeader(
                headerLength: 0x08,
                sequenceNumber: sequenceNumber,
                requestType: bwStopConnectTime
            )
            body.appendU16(payloadLength)
            if payloadLength > 0 {
                body.append(contentsOf: [UInt8](repeating: 0x5A, count: Int(payloadLength)))
            }
            return body
        }
        return encodeRequestHeader(
            headerLength: 0x06,
            sequenceNumber: sequenceNumber,
            requestType: bwStopContinuous
        )
    }

    /// Network Characteristics Result with baseRTT + bandwidth + averageRTT (kbps / ms).
    public static func encodeNetCharResult(
        sequenceNumber: UInt16,
        baseRTTMs: UInt32,
        bandwidthKbps: UInt32,
        averageRTTMs: UInt32
    ) -> [UInt8] {
        var pdu: [UInt8] = []
        pdu.appendU16(secAutoDetectReq)
        pdu.appendU16(0) // flagsHi
        pdu.append(0x12) // headerLength
        pdu.append(typeIdRequest)
        pdu.appendU16(sequenceNumber)
        pdu.appendU16(netCharBaseRTTBandwidthAvgRTT)
        pdu.appendU32(baseRTTMs)
        pdu.appendU32(bandwidthKbps)
        pdu.appendU32(averageRTTMs)
        return pdu
    }

    public static func parseClientResponse(from payload: [UInt8]) -> ClientResponse? {
        guard payload.count >= 4 + 6 else { return nil }
        let flags = UInt16(payload[0]) | UInt16(payload[1]) << 8
        guard flags & secAutoDetectRsp != 0 else { return nil }
        let o = 4
        let headerLength = payload[o]
        let typeId = payload[o + 1]
        guard typeId == typeIdResponse else { return nil }
        let sequence = UInt16(payload[o + 2]) | UInt16(payload[o + 3]) << 8
        let responseType = UInt16(payload[o + 4]) | UInt16(payload[o + 5]) << 8

        switch responseType {
        case rttResponse:
            guard headerLength == 0x06 else { return nil }
            return .rtt(sequenceNumber: sequence)
        case bwResultsConnectTime, bwResultsContinuous:
            guard headerLength == 0x0E, payload.count >= o + 14 else { return nil }
            let timeDelta = UInt32(payload[o + 6]) | UInt32(payload[o + 7]) << 8
                | UInt32(payload[o + 8]) << 16 | UInt32(payload[o + 9]) << 24
            let byteCount = UInt32(payload[o + 10]) | UInt32(payload[o + 11]) << 8
                | UInt32(payload[o + 12]) << 16 | UInt32(payload[o + 13]) << 24
            return .bandwidthResults(
                sequenceNumber: sequence,
                responseType: responseType,
                timeDeltaMs: timeDelta,
                byteCount: byteCount
            )
        case netCharSync:
            guard headerLength == 0x0E, payload.count >= o + 14 else { return nil }
            let bw = UInt32(payload[o + 6]) | UInt32(payload[o + 7]) << 8
                | UInt32(payload[o + 8]) << 16 | UInt32(payload[o + 9]) << 24
            let rtt = UInt32(payload[o + 10]) | UInt32(payload[o + 11]) << 8
                | UInt32(payload[o + 12]) << 16 | UInt32(payload[o + 13]) << 24
            return .netCharSync(sequenceNumber: sequence, bandwidthKbps: bw, rttMs: rtt)
        default:
            return nil
        }
    }

    private static func encodeRequestHeader(
        headerLength: UInt8,
        sequenceNumber: UInt16,
        requestType: UInt16
    ) -> [UInt8] {
        var pdu: [UInt8] = []
        pdu.appendU16(secAutoDetectReq)
        pdu.appendU16(0)
        pdu.append(headerLength)
        pdu.append(typeIdRequest)
        pdu.appendU16(sequenceNumber)
        pdu.appendU16(requestType)
        return pdu
    }
}
