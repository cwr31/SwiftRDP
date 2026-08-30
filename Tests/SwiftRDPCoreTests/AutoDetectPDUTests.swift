import XCTest
@testable import SwiftRDPCore

final class AutoDetectPDUTests: XCTestCase {
    func testBandwidthKbpsFormula() {
        // 1_000_000 bytes in 800ms → 10_000 kbps
        XCTAssertEqual(AutoDetectPDU.bandwidthKbps(timeDeltaMs: 800, byteCount: 1_000_000), 10_000)
        // A zero interval cannot produce a valid rate sample.
        XCTAssertEqual(AutoDetectPDU.bandwidthKbps(timeDeltaMs: 0, byteCount: 12_390), 0)
        XCTAssertEqual(AutoDetectPDU.bandwidthKbps(timeDeltaMs: 0, byteCount: 0), 0)
    }

    func testRoundTripRTTResponseParse() {
        var pdu: [UInt8] = []
        pdu.appendU16(AutoDetectPDU.secAutoDetectRsp)
        pdu.appendU16(0)
        pdu.append(0x06)
        pdu.append(AutoDetectPDU.typeIdResponse)
        pdu.appendU16(0x23)
        pdu.appendU16(AutoDetectPDU.rttResponse)
        let parsed = AutoDetectPDU.parseClientResponse(from: pdu)
        guard case .rtt(let seq)? = parsed else {
            return XCTFail("expected RTT response")
        }
        XCTAssertEqual(seq, 0x23)
    }

    func testBandwidthResultsParse() {
        var pdu: [UInt8] = []
        pdu.appendU16(AutoDetectPDU.secAutoDetectRsp)
        pdu.appendU16(0)
        pdu.append(0x0E)
        pdu.append(AutoDetectPDU.typeIdResponse)
        pdu.appendU16(0x30)
        pdu.appendU16(AutoDetectPDU.bwResultsConnectTime)
        pdu.appendU32(250)
        pdu.appendU32(50_000)
        let parsed = AutoDetectPDU.parseClientResponse(from: pdu)
        guard case .bandwidthResults(_, let type, let dt, let bytes)? = parsed else {
            return XCTFail("expected BW results")
        }
        XCTAssertEqual(type, AutoDetectPDU.bwResultsConnectTime)
        XCTAssertEqual(dt, 250)
        XCTAssertEqual(bytes, 50_000)
    }

    func testNetCharResultEncodeLength() {
        let pdu = AutoDetectPDU.encodeNetCharResult(
            sequenceNumber: 1,
            baseRTTMs: 40,
            bandwidthKbps: 12_000,
            averageRTTMs: 55
        )
        // SEC(4) + headerLength/type/seq/req(6) + base/bw/avg(12) = 22
        XCTAssertEqual(pdu.count, 22)
        XCTAssertEqual(UInt16(pdu[0]) | UInt16(pdu[1]) << 8, AutoDetectPDU.secAutoDetectReq)
        XCTAssertEqual(pdu[4], 0x12)
    }

    func testProbeResponsesRequireMatchingOutstandingSequence() {
        let detector = NetworkAutoDetect()
        var sent: [[UInt8]] = []
        var finished = false
        detector.onSend = { sent.append($0) }
        detector.onConnectTimeFinished = { finished = true }

        detector.beginConnectTime()
        XCTAssertEqual(detector.phase, .connectRTT)
        let rttSequence = UInt16(sent[0][6]) | UInt16(sent[0][7]) << 8

        detector.handleClientResponse(.rtt(sequenceNumber: rttSequence &+ 1))
        XCTAssertEqual(detector.phase, .connectRTT)
        XCTAssertFalse(detector.metrics.hasRTT)

        detector.handleClientResponse(.rtt(sequenceNumber: rttSequence))
        XCTAssertEqual(detector.phase, .connectBandwidth)
        let bandwidthSequence = UInt16(sent[1][6]) | UInt16(sent[1][7]) << 8

        detector.handleClientResponse(.bandwidthResults(
            sequenceNumber: bandwidthSequence &+ 1,
            responseType: AutoDetectPDU.bwResultsConnectTime,
            timeDeltaMs: 500,
            byteCount: 100_000
        ))
        XCTAssertEqual(detector.phase, .connectBandwidth)
        XCTAssertFalse(detector.metrics.hasBandwidth)

        detector.handleClientResponse(.bandwidthResults(
            sequenceNumber: bandwidthSequence,
            responseType: AutoDetectPDU.bwResultsConnectTime,
            timeDeltaMs: 500,
            byteCount: 100_000
        ))
        XCTAssertEqual(detector.phase, .complete)
        XCTAssertEqual(detector.metrics.bandwidthKbps, 1_600)
        XCTAssertTrue(finished)
    }

    func testNetworkCharacteristicsSyncCancelsCurrentProbe() {
        let detector = NetworkAutoDetect()
        var sent: [[UInt8]] = []
        var finished = false
        detector.onSend = { sent.append($0) }
        detector.onConnectTimeFinished = { finished = true }

        detector.beginConnectTime()
        let sequence = UInt16(sent[0][6]) | UInt16(sent[0][7]) << 8
        detector.handleClientResponse(.netCharSync(
            sequenceNumber: sequence,
            bandwidthKbps: 80_000,
            rttMs: 12
        ))

        XCTAssertEqual(detector.phase, .complete)
        XCTAssertEqual(detector.metrics.bandwidthKbps, 80_000)
        XCTAssertEqual(detector.metrics.averageRTTMs, 12)
        XCTAssertTrue(finished)
    }

}
