import Foundation
import XCTest
@testable import SwiftRDPCore

final class VideoQualityRegressionTests: XCTestCase {
    func testHigherMeasuredUDPRTTDoesNotThrottleAnUnqueuedPath() {
        let controller = makeMeasuredVideoController()
        let start = Date()
        controller.updateTransportRTT(nanoseconds: 5_000_000, measuredAt: 1, now: start)
        controller.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 5, unacked: 0, now: start)
        for index in 1...300 {
            let now = start.addingTimeInterval(Double(index) * 0.1)
            controller.updateTransportRTT(nanoseconds: 300_000_000, measuredAt: UInt64(index + 1), now: now)
            controller.noteServerQueue(bytes: 0, now: now)
            controller.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 300, unacked: 0, now: now)
        }
        XCTAssertEqual(controller.targetFPS, 60)
        XCTAssertEqual(controller.targetBitrate, 20_000_000)
        XCTAssertEqual(controller.performanceSnapshot(now: start.addingTimeInterval(30)).networkPressure, 0)
    }

    func testTCPControllerUsesCurrentRTTWhileDetectorRetainsHistoricalMinimum() {
        let controller = makeMeasuredVideoController()
        let start = Date()
        var metrics = NetworkAutoDetect.Metrics()
        metrics.baseRTTMs = 5
        metrics.averageRTTMs = 5
        metrics.rttMeasuredAtNanoseconds = 1
        controller.updateAutoDetect(metrics, now: start)
        controller.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 5, unacked: 0, now: start)
        for index in 1...100 {
            let now = start.addingTimeInterval(Double(index) * 0.1)
            metrics.averageRTTMs = 300
            metrics.rttMeasuredAtNanoseconds = UInt64(index + 1)
            controller.updateAutoDetect(metrics, now: now)
            controller.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 300, unacked: 0, now: now)
        }
        XCTAssertEqual(controller.targetFPS, 60)
        XCTAssertEqual(controller.targetBitrate, 20_000_000)
    }

    func testCurrentRTTDoesNotHideClientDeliveryOrLocalQueuePressure() {
        let controller = makeMeasuredVideoController()
        let start = Date()
        controller.updateTransportRTT(nanoseconds: 300_000_000, measuredAt: 1, now: start)
        controller.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 300, unacked: 0, now: start)
        for index in 1...30 {
            let now = start.addingTimeInterval(Double(index) * 0.1)
            controller.updateTransportRTT(nanoseconds: 300_000_000, measuredAt: UInt64(index + 1), now: now)
            controller.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 900, unacked: 2, now: now)
            controller.noteServerQueue(bytes: 1_000_000, now: now)
        }
        XCTAssertLessThan(controller.targetBitrate, 20_000_000)
        XCTAssertGreaterThan(controller.performanceSnapshot(now: start.addingTimeInterval(3)).networkPressure, 1)
    }

    func testSmallTimerDelaysDoNotAccumulateIntoALowerCaptureRate() {
        var pacer = VideoFramePacer()
        let period: UInt64 = 1_000_000_000 / 60
        XCTAssertEqual(pacer.remainingWaitNanoseconds(fps: 60, now: 0), 0)
        pacer.noteSubmission(at: 0)
        for index in 1...120 {
            let scheduled = UInt64(index) * period
            let actual = scheduled + 2_000_000
            XCTAssertEqual(pacer.remainingWaitNanoseconds(fps: 60, now: actual), 0)
            pacer.noteSubmission(at: actual)
            XCTAssertEqual(pacer.remainingWaitNanoseconds(fps: 60, now: actual), period - 2_000_000)
        }
    }

    func testLongCaptureStallSkipsMissedFramesWithoutCatchupBurst() {
        var pacer = VideoFramePacer()
        _ = pacer.remainingWaitNanoseconds(fps: 60, now: 0)
        pacer.noteSubmission(at: 0)
        let resumed: UInt64 = 2_000_000_000
        XCTAssertEqual(pacer.remainingWaitNanoseconds(fps: 60, now: resumed), 0)
        pacer.noteSubmission(at: resumed)
        XCTAssertEqual(pacer.remainingWaitNanoseconds(fps: 60, now: resumed), 1_000_000_000 / 60)
    }

    func testUnknownPathStartsBelowConfiguredMaximumBitrate() {
        let controller = VideoTargetController(bitrate: 20_000_000, fps: 60)
        XCTAssertLessThanOrEqual(controller.targetBitrate, 4_000_000)
        XCTAssertEqual(controller.configuredBitrate, 20_000_000)
        XCTAssertEqual(controller.targetFPS, 60)
        XCTAssertTrue(controller.bitrateReduced)
    }

    func testLowMotionCannotProbeBitrateUpToConfiguredMaximum() {
        let controller = VideoTargetController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        for index in 0..<15 {
            controller.noteServerQueue(bytes: 2_000_000,
                now: start.addingTimeInterval(Double(index) * 0.6))
        }
        let initialBitrate = controller.targetBitrate
        let initialFPS = controller.targetFPS
        for index in 0..<150 {
            let time = start.addingTimeInterval(10 + Double(index) * 0.1)
            controller.noteServerQueue(bytes: 0, now: time)
            controller.noteEncodedFrame(bytes: 1_000, now: time)
            controller.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 30, unacked: 0, now: time)
        }
        XCTAssertEqual(controller.targetBitrate, initialBitrate)
        XCTAssertGreaterThan(controller.targetFPS, initialFPS)
    }

    func testEncoderCanRecoverByLessThanItsNormalFPSIncrement() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        for index in 0..<16 {
            let time = start.addingTimeInterval(Double(index) / 60)
            controller.noteEncodedFrame(bytes: 10_000, encodeMs: 480,
                encodeBusyIntervalMs: 240, encoderBacklogged: true, now: time)
        }
        controller.noteEncodedFrame(bytes: 10_000, encodeMs: 480,
            encodeBusyIntervalMs: 240, encoderBacklogged: true,
            now: start.addingTimeInterval(1.3))
        XCTAssertEqual(controller.targetFPS, 5)
        // A 120 ms service interval can sustain eight FPS; it need not satisfy
        // a full five-FPS recovery increment.
        for index in 0..<40 {
            controller.noteEncodedFrame(bytes: 10_000, encodeMs: 240,
                encodeBusyIntervalMs: 120, encoderBacklogged: true,
                now: start.addingTimeInterval(2 + Double(index) * 0.2))
        }
        XCTAssertGreaterThan(controller.targetFPS, 5)
        XCTAssertLessThanOrEqual(controller.targetFPS, 8)
        XCTAssertEqual(controller.targetBitrate, 20_000_000)
    }

    func testConnectTimeBandwidthSetsInitialBitrateWithoutReducingFPS() {
        let controller = VideoTargetController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        var metrics = NetworkAutoDetect.Metrics()
        metrics.bandwidthKbps = 5_000
        metrics.bandwidthMeasuredAtNanoseconds = 1
        controller.updateAutoDetect(metrics, now: start)
        XCTAssertGreaterThanOrEqual(controller.targetBitrate, VideoTargetController.minAdaptiveBitrate)
        XCTAssertLessThan(controller.targetBitrate, 5_000_000)
        XCTAssertEqual(controller.targetFPS, 60)

        let initialBitrate = controller.targetBitrate
        for index in 0..<4 {
            let time = start.addingTimeInterval(Double(index) * 1.1)
            noteVideoDemand(controller, interval: 1.1, now: time)
            controller.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 30, unacked: 0,
                now: time)
        }
        XCTAssertGreaterThan(controller.targetBitrate, initialBitrate)
        let recoveredBitrate = controller.targetBitrate
        // Consuming the same measurement twice must not undo feedback recovery.
        controller.updateAutoDetect(metrics, now: start.addingTimeInterval(4))
        XCTAssertEqual(controller.targetBitrate, recoveredBitrate)
    }

    func testNormalDecodedFrameFeedbackDoesNotThrottleAHealthyPath() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        controller.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 8, unacked: 0, now: start)
        for index in 1...180 {
            controller.noteFrameAck(clientQueue: .unavailable,
                ackLatencyMs: index.isMultiple(of: 5) ? 70 : 40, unacked: 1,
                now: start.addingTimeInterval(Double(index) / 30))
        }
        XCTAssertEqual(controller.targetFPS, 60)
        XCTAssertEqual(controller.targetBitrate, 20_000_000)
        XCTAssertLessThan(controller.performanceSnapshot().networkPressure, 1)
        // Credit must cover the healthy client processing/feedback pipeline,
        // otherwise the window itself imposes a lower delivered frame rate.
        XCTAssertGreaterThan(controller.recommendedFrameAcknowledgementWindow(
            clientCeiling: 12, now: start.addingTimeInterval(6)), 2)
    }

    func testTinyClientQueueDoesNotCollapseHealthyFrameCredits() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        controller.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 6, unacked: 0, now: start)
        for index in 1...90 {
            let time = start.addingTimeInterval(Double(index) / 60)
            controller.noteFrameAck(
                clientQueue: index.isMultiple(of: 2) ? .queued(bytes: 18) : .unavailable,
                ackLatencyMs: 32, unacked: 1, acknowledgedBytes: 100_000,
                acknowledgementIntervalMs: 1_000 / 60, now: time)
            if index >= 30 {
                let window = controller.recommendedFrameAcknowledgementWindow(clientCeiling: 8, now: time)
                XCTAssertGreaterThanOrEqual(window, 3)
                XCTAssertLessThanOrEqual(window, 4)
            }
        }
        XCTAssertEqual(controller.recommendedFrameAcknowledgementWindow(
            clientCeiling: 2, now: start.addingTimeInterval(1.5)), 2)
    }

    func testRealClientBacklogTightensCreditsButExpiredFeedbackDoesNot() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        controller.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 6, unacked: 0, now: start)
        controller.noteFrameAck(clientQueue: .queued(bytes: 1_000_000),
            ackLatencyMs: 32, unacked: 1, acknowledgedBytes: 10_000,
            acknowledgementIntervalMs: 20, now: start.addingTimeInterval(0.1))

        XCTAssertEqual(controller.recommendedFrameAcknowledgementWindow(
            clientCeiling: 8, now: start.addingTimeInterval(0.1)), 1)
        XCTAssertEqual(controller.recommendedFrameAcknowledgementWindow(
            clientCeiling: 8, now: start.addingTimeInterval(6)), 2)
    }

    func testDelayedAcksDoNotEarnAdditionalFrameCredits() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        controller.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 6, unacked: 0, now: start)
        for index in 1...64 {
            controller.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 32, unacked: 1,
                now: start.addingTimeInterval(Double(index) / 60))
        }
        let healthyWindow = controller.recommendedFrameAcknowledgementWindow(
            clientCeiling: 8, now: start.addingTimeInterval(1.1))
        controller.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 1_000, unacked: 1,
            now: start.addingTimeInterval(1.2))

        XCTAssertLessThanOrEqual(controller.recommendedFrameAcknowledgementWindow(
            clientCeiling: 8, now: start.addingTimeInterval(1.2)), healthyWindow)
    }

    func testHealthyCreditsSustainOverlappingEncodingAndFeedback() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        controller.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 32, unacked: 0, now: start)
        var nextCaptureMs = 0.0
        var pendingOutputs: [Double] = []
        var pendingAcks: [Double] = []
        var delivered = 0
        // Model a 60 Hz source, two native slots, 20 ms encode latency and
        // 32 ms decoded-frame feedback. Admission must overlap those stages.
        for tick in 0..<2_000 {
            let nowMs = Double(tick)
            let time = start.addingTimeInterval(nowMs / 1_000)
            while let first = pendingAcks.first, first <= nowMs {
                pendingAcks.removeFirst()
                controller.noteFrameAck(clientQueue: .queued(bytes: 18), ackLatencyMs: 32,
                    unacked: pendingAcks.count, now: time)
            }
            let window = controller.recommendedFrameAcknowledgementWindow(clientCeiling: 8, now: time)
            while let first = pendingOutputs.first, first <= nowMs, pendingAcks.count < window {
                pendingOutputs.removeFirst()
                pendingAcks.append(nowMs + 32)
                delivered += 1
            }
            if nowMs >= nextCaptureMs {
                nextCaptureMs += 1_000 / 60
                if pendingOutputs.count < 2, pendingAcks.count < window {
                    pendingOutputs.append(nowMs + 20)
                }
            }
        }
        XCTAssertGreaterThanOrEqual(delivered, 110)
        XCTAssertEqual(controller.targetFPS, 60)
    }

    func testOnePacedFrameIsNotNetworkCongestionAtLowFPS() {
        let controller = VideoTargetController(bitrate: 1_000_000, fps: 5)
        let start = Date()
        for index in 0..<12 {
            let time = start.addingTimeInterval(Double(index) * 0.2)
            controller.noteServerQueue(bytes: 25_000, now: time)
            controller.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 35, unacked: 1, now: time)
        }
        XCTAssertEqual(controller.lastServerQueueDelayMs, 200, accuracy: 0.01)
        XCTAssertEqual(controller.performanceSnapshot().networkPressure, 0, accuracy: 0.01)
    }

    func testQualityRecoveryRaisesFPSBeforeFullConfiguredBitrateIsAvailable() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        for index in 0..<24 {
            controller.noteServerQueue(bytes: 2_000_000,
                now: start.addingTimeInterval(Double(index) * 0.6))
        }
        XCTAssertEqual(controller.targetFPS, 5)
        let lowBitrate = controller.targetBitrate
        for index in 0..<7 {
            let time = start.addingTimeInterval(15 + Double(index) * 1.1)
            controller.noteServerQueue(bytes: 0, now: time)
            noteVideoDemand(controller, interval: 1.1, now: time)
            controller.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 35, unacked: 1, now: time)
        }
        XCTAssertGreaterThan(controller.targetFPS, 5)
        XCTAssertGreaterThan(controller.targetBitrate, lowBitrate)
        XCTAssertLessThan(controller.targetBitrate, controller.configuredBitrate)
    }

    func testPacedApplicationACKRateCannotBecomeNetworkCapacity() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 30)
        let start = Date()
        controller.noteServerQueue(bytes: 250_000, now: start)
        for index in 0..<4 {
            controller.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 30, unacked: 1,
                acknowledgedBytes: 10_000, acknowledgementIntervalMs: 100,
                now: start.addingTimeInterval(Double(index) * 0.1))
        }
        controller.noteServerQueue(bytes: 25_000, now: start.addingTimeInterval(0.4))
        XCTAssertEqual(controller.lastServerQueueDelayMs, 10, accuracy: 0.01)
    }

    func testIndependentRTTPreventsTinyGraphicsACKOutlierFromBecomingBaseline() {
        let controller = makeMeasuredVideoController(bitrate: 6_000_000, fps: 30)
        let start = Date()
        var metrics = NetworkAutoDetect.Metrics()
        metrics.baseRTTMs = 30
        metrics.rttMeasuredAtNanoseconds = 1
        controller.updateAutoDetect(metrics, now: start)
        controller.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 1, unacked: 0, now: start)
        for index in 1...40 {
            controller.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 40, unacked: 1,
                now: start.addingTimeInterval(Double(index) * 0.05))
        }
        XCTAssertEqual(controller.targetFPS, 30)
        XCTAssertEqual(controller.targetBitrate, 6_000_000)
    }

    func testOldSessionCannotDetachReplacementCaptureObserver() throws {
        let manager = try makeTestSessionManager(config: ServerConfig())
        var old: RDPSession? = RDPSession(config: ServerConfig())
        weak var released = old
        manager.registerSession(try XCTUnwrap(old))
        XCTAssertTrue(manager.promoteSession(try XCTUnwrap(old)))
        let current = RDPSession(config: ServerConfig())
        manager.registerSession(current)
        XCTAssertTrue(manager.promoteSession(current))
        manager.unregisterSession(try XCTUnwrap(old))
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
        let c = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
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
        let c = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        c.noteClientQoE(renderMs: 113, now: Date().addingTimeInterval(-20))
        for _ in 0..<20 { c.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 30, unacked: 0) }
        XCTAssertEqual(c.targetFPS, 60)
        XCTAssertEqual(c.performanceSnapshot().clientRenderMs, 0)
        XCTAssertEqual(c.performanceSnapshot().clientPressure, 0)
    }

    func testQueueCallbacksDoNotResampleACKDelay() {
        let a = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        let b = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
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

    func testIdleTimeIsExcludedFromAcknowledgedDeliveryInterval() throws {
        let tracker = FrameAckTracker()
        tracker.track(frameId: 1, bytes: 10_000, nowNanoseconds: 1_000_000_000)
        _ = tracker.acknowledge(upTo: 1, nowNanoseconds: 1_010_000_000)
        tracker.track(frameId: 2, bytes: 10_000, nowNanoseconds: 11_000_000_000)
        let sample = try XCTUnwrap(tracker.acknowledge(upTo: 2, nowNanoseconds: 11_010_000_000))
        XCTAssertEqual(sample.latencyMs, 10)
        XCTAssertEqual(sample.acknowledgementIntervalMs, 10)
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
            for index in 0..<64 {
                let time = t.addingTimeInterval(Double(index) * 0.4)
                noteVideoDemand(c, interval: 0.4, now: time)
                c.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 30, unacked: 0,
                    now: time)
            }
            XCTAssertEqual(c.targetBitrate, c.configuredBitrate)
            for second in [30.0, 38.0, 45.0] {
                metrics.rttMeasuredAtNanoseconds += 1
                c.updateAutoDetect(metrics, now: t.addingTimeInterval(second))
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
        let c = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        let t = Date()
        c.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 30, unacked: 0, now: t)
        for index in 1...100 {
            c.noteFrameAck(clientQueue: .unavailable, ackLatencyMs: 130, unacked: 0,
                           now: t.addingTimeInterval(Double(index) / 60))
        }
        XCTAssertGreaterThan(c.performanceSnapshot().quality.ackExcessDelayMs, 90)
    }
}
