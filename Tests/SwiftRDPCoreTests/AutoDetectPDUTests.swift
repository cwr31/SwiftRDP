import NIOEmbedded
import XCTest
@testable import SwiftRDPCore

final class AutoDetectPDUTests: XCTestCase {
    func testEachMeasurementNotifiesOnceAndCarriesIndependentSampleIdentity() {
        let loop = EmbeddedEventLoop()
        let detector = NetworkAutoDetect(eventLoop: loop)
        defer { detector.stop() }
        var sent: [[UInt8]] = []
        var updates: [NetworkAutoDetect.Metrics] = []
        detector.onSend = { sent.append($0) }
        detector.onMetricsUpdated = { updates.append($0) }
        detector.beginConnectTime()
        let rttSequence = UInt16(sent[0][6]) | UInt16(sent[0][7]) << 8
        detector.handleClientResponse(.rtt(sequenceNumber: rttSequence))
        XCTAssertEqual(updates.count, 1)
        XCTAssertGreaterThan(updates[0].rttMeasuredAtNanoseconds, 0)
        XCTAssertEqual(updates[0].bandwidthMeasuredAtNanoseconds, 0)
        let bwSequence = UInt16(sent[1][6]) | UInt16(sent[1][7]) << 8
        detector.handleClientResponse(.bandwidthResults(
            sequenceNumber: bwSequence, responseType: AutoDetectPDU.bwResultsConnectTime,
            timeDeltaMs: 500, byteCount: 100_000
        ))
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates[1].rttMeasuredAtNanoseconds, updates[0].rttMeasuredAtNanoseconds)
        XCTAssertGreaterThan(updates[1].bandwidthMeasuredAtNanoseconds, 0)
    }

    func testBandwidthStageGetsItsOwnDeadline() {
        let loop = EmbeddedEventLoop()
        let detector = NetworkAutoDetect(eventLoop: loop)
        defer { detector.stop() }
        var sent: [[UInt8]] = []
        detector.onSend = { sent.append($0) }
        detector.beginConnectTime()
        let rttSequence = UInt16(sent[0][6]) | UInt16(sent[0][7]) << 8
        loop.advanceTime(by: .milliseconds(2200))
        detector.handleClientResponse(.rtt(sequenceNumber: rttSequence))
        let bwSequence = UInt16(sent[1][6]) | UInt16(sent[1][7]) << 8
        loop.advanceTime(by: .seconds(1))
        XCTAssertEqual(detector.phase, .connectBandwidth)
        detector.handleClientResponse(.bandwidthResults(
            sequenceNumber: bwSequence, responseType: AutoDetectPDU.bwResultsConnectTime,
            timeDeltaMs: 3_000, byteCount: 196_608
        ))
        XCTAssertEqual(detector.phase, .complete)
        XCTAssertTrue(detector.metrics.hasBandwidth)
    }

    func testThreeConsecutiveContinuousProbeFailuresCloseConnectionOnce() {
        let loop = EmbeddedEventLoop()
        let detector = NetworkAutoDetect(eventLoop: loop)
        var requests = 0
        var failures = 0
        detector.onSend = { _ in requests += 1 }
        detector.onConnectionUnresponsive = { failures += 1 }
        detector.startContinuous()
        loop.advanceTime(by: .seconds(2))
        for attempt in 0..<3 {
            XCTAssertEqual(detector.phase, .continuousRTT)
            loop.advanceTime(by: .seconds(3))
            if attempt < 2 {
                XCTAssertEqual(failures, 0)
                loop.advanceTime(by: .seconds(12))
            }
        }
        XCTAssertEqual(requests, 3)
        XCTAssertEqual(failures, 1)
        loop.advanceTime(by: .seconds(60))
        XCTAssertEqual(requests, 3)
        XCTAssertEqual(failures, 1)
    }

    func testSuccessfulProbeResetsFailureCountAndStopCancelsDeadlines() {
        let loop = EmbeddedEventLoop()
        let detector = NetworkAutoDetect(eventLoop: loop)
        var sent: [[UInt8]] = []
        var failures = 0
        detector.onSend = { sent.append($0) }
        detector.onConnectionUnresponsive = { failures += 1 }
        detector.startContinuous()
        loop.advanceTime(by: .seconds(2))
        loop.advanceTime(by: .seconds(3)) // first missed probe
        loop.advanceTime(by: .seconds(12))
        let sequence = UInt16(sent.last![6]) | UInt16(sent.last![7]) << 8
        loop.advanceTime(by: .milliseconds(200))
        detector.handleClientResponse(.rtt(sequenceNumber: sequence))
        XCTAssertEqual(detector.metrics.averageRTTMs, 200)
        loop.advanceTime(by: .milliseconds(14_800))
        loop.advanceTime(by: .seconds(3)) // one failure since successful response
        loop.advanceTime(by: .seconds(12))
        loop.advanceTime(by: .seconds(3)) // two failures since successful response
        XCTAssertEqual(failures, 0)
        detector.stop()
        let count = sent.count
        loop.advanceTime(by: .seconds(60))
        XCTAssertEqual(sent.count, count)
        XCTAssertEqual(failures, 0)
    }

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
        let loop = EmbeddedEventLoop()
        let detector = NetworkAutoDetect(eventLoop: loop)
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
        let loop = EmbeddedEventLoop()
        let detector = NetworkAutoDetect(eventLoop: loop)
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
