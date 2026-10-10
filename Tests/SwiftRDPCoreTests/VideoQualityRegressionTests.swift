import Foundation
import XCTest
@testable import SwiftRDPCore

final class VideoQualityRegressionTests: XCTestCase {
    func testOldSessionCannotDetachReplacementCaptureObserver() throws {
        let manager = SessionManager(config: ServerConfig())
        var old: RDPSession? = RDPSession(config: ServerConfig())
        weak var released = old
        manager.registerSession(try XCTUnwrap(old))
        let current = RDPSession(config: ServerConfig())
        manager.registerSession(current)
        var notifications = 0
        manager.sharedScreenCapture.attach(
            owner: current.id, captureFPS: 60, capturesAudio: false,
            onFrameAvailable: { notifications += 1 }
        )
        let frame = CapturedFrame(width: 2, height: 2, bgrBottomUp: [])
        manager.sharedScreenCapture.frameHub.publish(frame)
        old = nil
        XCTAssertNil(released)
        manager.sharedScreenCapture.frameHub.publish(frame)
        XCTAssertEqual(notifications, 2)
        manager.sharedScreenCapture.detach(owner: current.id)
        manager.sharedScreenCapture.frameHub.publish(frame)
        XCTAssertEqual(notifications, 2)
    }

    func testClientQueueCapRecoversWithHealthyACKs() {
        let c = VideoTargetController(bitrate: 20_000_000, fps: 60)
        let t = Date()
        for second in [0.0, 0.6] {
            c.noteFrameAck(clientQueue: .queued(bytes: 500_000), ackLatencyMs: 30,
                           unacked: 0, acknowledgedBytes: 100_000, acknowledgementIntervalMs: 100,
                           now: t.addingTimeInterval(second))
        }
        XCTAssertEqual(c.targetFPS, 48)
        for second in 1...6 {
            c.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 30, unacked: 0,
                           now: t.addingTimeInterval(Double(second)))
        }
        XCTAssertEqual(c.targetFPS, 60)
        XCTAssertEqual(c.targetBitrate, 20_000_000)
    }

    func testStaleQoEDoesNotCauseFurtherReductions() {
        let c = VideoTargetController(bitrate: 20_000_000, fps: 60)
        c.noteClientQoE(renderMs: 113, now: Date().addingTimeInterval(-20))
        for _ in 0..<20 { c.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 30, unacked: 0) }
        XCTAssertEqual(c.targetFPS, 60)
        XCTAssertEqual(c.performanceSnapshot().clientRenderMs, 0)
        XCTAssertEqual(c.performanceSnapshot().clientPressure, 0)
    }

    func testQueueCallbacksDoNotResampleACKDelay() {
        let a = VideoTargetController(bitrate: 20_000_000, fps: 60)
        let b = VideoTargetController(bitrate: 20_000_000, fps: 60)
        let t = Date()
        for c in [a, b] {
            c.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 30, unacked: 0, now: t)
            c.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 130, unacked: 0, now: t.addingTimeInterval(1))
            c.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 30, unacked: 0, now: t.addingTimeInterval(1.1))
        }
        for _ in 0..<10 { b.noteServerQueue(bytes: 0, now: t.addingTimeInterval(1.1)) }
        XCTAssertEqual(a.performanceSnapshot().quality.ackExcessDelayMs, 16, accuracy: 0.001)
        XCTAssertEqual(a.performanceSnapshot().quality.ackExcessDelayMs,
                       b.performanceSnapshot().quality.ackExcessDelayMs, accuracy: 0.001)
    }

    func testIdleTimeIsExcludedAndApplicationLimitedRateDoesNotSetCapacity() throws {
        let tracker = FrameAckTracker()
        tracker.track(frameId: 1, bytes: 10_000, nowNanoseconds: 1_000_000_000)
        _ = tracker.acknowledge(upTo: 1, nowNanoseconds: 1_010_000_000)
        tracker.track(frameId: 2, bytes: 10_000, nowNanoseconds: 11_000_000_000)
        let sample = try XCTUnwrap(tracker.acknowledge(upTo: 2, nowNanoseconds: 11_010_000_000))
        XCTAssertEqual(sample.latencyMs, 10)
        XCTAssertEqual(sample.acknowledgementIntervalMs, 10)
        XCTAssertTrue(sample.isApplicationLimited)
        let c = VideoTargetController(bitrate: 20_000_000, fps: 60)
        c.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: sample.latencyMs, unacked: 0,
                       acknowledgedBytes: sample.acknowledgedBytes,
                       acknowledgementIntervalMs: sample.acknowledgementIntervalMs,
                       isApplicationLimited: sample.isApplicationLimited)
        c.noteServerQueue(bytes: 50_000)
        XCTAssertEqual(c.lastServerQueueDelayMs, 20, accuracy: 0.001)
    }

    func testRTTUpdatesCannotRenewBandwidthEvenAfterGraphicsReset() {
        for resetsGraphics in [false, true] {
            let c = VideoTargetController(bitrate: 20_000_000, fps: 60)
            let t = Date()
            var metrics = NetworkAutoDetect.Metrics()
            metrics.baseRTTMs = 30
            metrics.averageRTTMs = 30
            metrics.bandwidthKbps = 1_000
            metrics.rttMeasuredAtNanoseconds = 1
            metrics.bandwidthMeasuredAtNanoseconds = 1
            c.updateAutoDetect(metrics, now: t)
            if resetsGraphics { c.resetGraphicsChannel() }
            for index in 1...3 {
                metrics.rttMeasuredAtNanoseconds += 1
                c.updateAutoDetect(metrics, now: t.addingTimeInterval(Double(index) * 15))
            }
            c.noteServerQueue(bytes: 50_000, now: t.addingTimeInterval(46))
            XCTAssertEqual(c.lastServerQueueDelayMs, 20, accuracy: 0.001)
        }
    }

    func testFrameDeadlineSurvivesEarlyWakeupsAndFPSChanges() {
        var pacer = VideoFramePacer()
        XCTAssertEqual(pacer.remainingWaitNanoseconds(fps: 5, now: 0), 0)
        pacer.noteSubmission(at: 0)
        for now in stride(from: UInt64(20_000_000), through: 180_000_000, by: 20_000_000) {
            XCTAssertEqual(pacer.remainingWaitNanoseconds(fps: 5, now: now), 200_000_000 - now)
        }
        XCTAssertEqual(pacer.remainingWaitNanoseconds(fps: 5, now: 200_000_000), 0)
        XCTAssertEqual(pacer.remainingWaitNanoseconds(fps: 60, now: 20_000_000), 0)
        XCTAssertEqual(pacer.remainingWaitNanoseconds(fps: 5, now: 2_000_000_000), 0)
    }

    func testQualityIsUnknownWithoutFeedback() {
        let c = VideoTargetController(bitrate: 20_000_000, fps: 60)
        XCTAssertEqual(c.performanceSnapshot().quality.state, .unknown)
        c.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 30, unacked: 0)
        XCTAssertEqual(c.performanceSnapshot().quality.state, .healthy)
    }

    func testContinuousDelayCannotBecomeItsOwnHealthyBaseline() {
        let c = VideoTargetController(bitrate: 20_000_000, fps: 60)
        let t = Date()
        c.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 30, unacked: 0, now: t)
        for index in 1...100 {
            c.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 130, unacked: 0,
                           now: t.addingTimeInterval(Double(index) / 60))
        }
        XCTAssertGreaterThan(c.performanceSnapshot().quality.ackExcessDelayMs, 90)
    }
}
