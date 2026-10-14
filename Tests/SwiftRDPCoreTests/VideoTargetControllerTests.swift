import Dispatch
import XCTest
@testable import SwiftRDPCore

final class VideoTargetControllerTests: XCTestCase {
    func testMeasuredPathStartsAtConfiguredTargets() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)

        XCTAssertEqual(controller.targetBitrate, 20_000_000)
        XCTAssertEqual(controller.targetFPS, 60)
        XCTAssertFalse(controller.bitrateReduced)
    }

    func testFrameAckQueueUsesProtocolStates() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)

        acknowledge(controller, queue: .unavailable, latency: 30)
        XCTAssertEqual(controller.clientQueueFeedback, .unavailable)
        XCTAssertNil(controller.lastClientQueueDelayMs)

        acknowledge(controller, queue: .suspended, latency: 30)
        XCTAssertEqual(controller.clientQueueFeedback, .suspended)
        XCTAssertNil(controller.clientQueueFeedback.bytes)
        XCTAssertNil(controller.lastClientQueueDelayMs)

        acknowledge(controller, queue: .unavailable, latency: 30)
        XCTAssertEqual(controller.clientQueueFeedback, .unavailable)
        XCTAssertNil(controller.clientQueueFeedback.bytes)
        XCTAssertNil(controller.lastClientQueueDelayMs)

        acknowledge(
            controller,
            queue: .queued(bytes: 100_000),
            latency: 30,
            acknowledgedBytes: 100_000,
            intervalMs: 100
        )
        XCTAssertEqual(controller.clientQueueFeedback, .queued(bytes: 100_000))
        XCTAssertEqual(controller.lastClientQueueDelayMs ?? -1, 100, accuracy: 0.1)
    }

    func testUnavailableQueueDoesNotCreateSyntheticDelay() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)

        acknowledge(
            controller,
            queue: .unavailable,
            latency: 30,
            acknowledgedBytes: 100_000,
            intervalMs: 100
        )

        XCTAssertNil(controller.lastClientQueueDelayMs)
        XCTAssertEqual(controller.performanceSnapshot().quality.clientQueue, .unavailable)
    }

    func testClientQueuePressureDoesNotReduceNetworkBitrate() {
        let controller = makeMeasuredVideoController(
            bitrate: 20_000_000,
            fps: 60,
            adaptationPriority: .fpsFirst
        )
        let start = Date()
        seedHealthy(controller, at: start)

        acknowledge(
            controller,
            queue: .queued(bytes: 500_000),
            latency: 30,
            at: start.addingTimeInterval(1),
            acknowledgedBytes: 50_000,
            intervalMs: 100
        )
        acknowledge(
            controller,
            queue: .queued(bytes: 500_000),
            latency: 30,
            at: start.addingTimeInterval(1.6),
            acknowledgedBytes: 50_000,
            intervalMs: 100
        )

        XCTAssertLessThan(controller.targetFPS, 60)
        XCTAssertEqual(controller.targetBitrate, 20_000_000)
        XCTAssertEqual(controller.performanceSnapshot().pressureSource, .clientQueue)
        XCTAssertEqual(controller.performanceSnapshot().networkPressure, 0, accuracy: 0.01)
    }

    func testServerQueueUsesTimeBudgetAndReducesNetworkLoad() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        let queuedBytes = Int(20_000_000.0 * 0.2 / 8.0)

        controller.noteServerQueue(bytes: queuedBytes, now: start)
        XCTAssertEqual(controller.lastServerQueueDelayMs, 200, accuracy: 0.1)
        XCTAssertEqual(controller.targetFPS, 60)

        controller.noteServerQueue(bytes: queuedBytes, now: start.addingTimeInterval(0.6))

        XCTAssertLessThan(controller.targetFPS, 60)
        XCTAssertEqual(controller.targetBitrate, 17_000_000)
        XCTAssertEqual(controller.performanceSnapshot().pressureSource, .serverQueue)
    }

    func testServerQueueDelayIsBoundedByPacingRate() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        seed(controller, bandwidthKbps: 100_000, rttMs: 10)

        controller.noteServerQueue(bytes: 500_000)

        XCTAssertEqual(controller.serverQueueDrainBitrate, 20_000_000)
        XCTAssertEqual(controller.lastServerQueueDelayMs, 200, accuracy: 0.1)
        XCTAssertEqual(controller.targetFPS, 60)
        XCTAssertEqual(controller.targetBitrate, 20_000_000)
    }

    func testExpiredAutoDetectRateDoesNotLimitNetworkAdaptation() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        seed(controller, bandwidthKbps: 5_000, rttMs: 10, now: start)
        // Healthy feedback can probe above the initial measurement. Its stale
        // value must then stop limiting the estimated local queue drain rate.
        for index in 0..<64 {
            let time = start.addingTimeInterval(Double(index) * 0.4)
            noteVideoDemand(controller, interval: 0.4, now: time)
            acknowledge(controller, queue: .unavailable, latency: 20,
                at: time)
        }
        XCTAssertEqual(controller.targetBitrate, 20_000_000)

        controller.noteServerQueue(bytes: 500_000, now: start.addingTimeInterval(31))

        XCTAssertEqual(controller.lastServerQueueDelayMs, 200, accuracy: 0.1)
    }

    func testFullAckWindowWithHealthyAcksDoesNotCreateNetworkPressure() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        controller.noteEncodedFrame(
            bytes: 100_000,
            serverUnacked: 1,
            ackWindow: 2,
            now: start
        )

        for index in 0..<5 {
            acknowledge(
                controller,
                queue: .unavailable,
                latency: 20,
                unacked: 1,
                at: start.addingTimeInterval(0.3 + Double(index) * 0.3),
                acknowledgedBytes: 100_000,
                intervalMs: 100
            )
        }

        XCTAssertEqual(controller.targetFPS, 60)
        XCTAssertEqual(controller.targetBitrate, 20_000_000)
        XCTAssertEqual(controller.performanceSnapshot().quality.networkPressure, 0, accuracy: 0.01)
        XCTAssertGreaterThan(controller.linkQualityScore, 0.9)
    }

    func testNetworkPressureRequiresTimeDwellBeforeAdapting() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        seedHealthy(controller, at: start)
        controller.noteEncodedFrame(
            bytes: 100_000,
            serverUnacked: 0,
            ackWindow: 2,
            now: start
        )

        acknowledge(
            controller,
            queue: .unavailable,
            latency: 600,
            unacked: 0,
            at: start.addingTimeInterval(1)
        )
        XCTAssertEqual(controller.targetFPS, 60)

        acknowledge(
            controller,
            queue: .unavailable,
            latency: 600,
            unacked: 0,
            at: start.addingTimeInterval(1.1)
        )
        XCTAssertEqual(controller.targetFPS, 60)

        acknowledge(
            controller,
            queue: .unavailable,
            latency: 600,
            unacked: 0,
            at: start.addingTimeInterval(1.6)
        )
        XCTAssertLessThan(controller.targetFPS, 60)
    }

    func testNetworkSpikeCannotAdaptMoreThanOncePerCooldown() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        seedHealthy(controller, at: start)

        acknowledge(
            controller,
            queue: .unavailable,
            latency: 600,
            at: start.addingTimeInterval(1)
        )
        acknowledge(
            controller,
            queue: .unavailable,
            latency: 600,
            at: start.addingTimeInterval(1.6)
        )
        let firstReducedFPS = controller.targetFPS
        XCTAssertLessThan(firstReducedFPS, 60)

        acknowledge(
            controller,
            queue: .unavailable,
            latency: 600,
            at: start.addingTimeInterval(1.61)
        )
        XCTAssertEqual(controller.targetFPS, firstReducedFPS)

        acknowledge(
            controller,
            queue: .unavailable,
            latency: 600,
            at: start.addingTimeInterval(2.11)
        )
        XCTAssertLessThan(controller.targetFPS, firstReducedFPS)
    }

    func testSingleLowAckSampleCannotCollapseBitrate() {
        let controller = makeMeasuredVideoController(
            bitrate: 20_000_000,
            fps: 60,
            adaptationPriority: .fpsFirst
        )
        let start = Date()
        seedHealthy(controller, at: start)

        acknowledge(
            controller,
            queue: .unavailable,
            latency: 600,
            at: start.addingTimeInterval(1),
            acknowledgedBytes: 5_000,
            intervalMs: 100
        )
        acknowledge(
            controller,
            queue: .unavailable,
            latency: 600,
            at: start.addingTimeInterval(1.6),
            acknowledgedBytes: 5_000,
            intervalMs: 100
        )

        XCTAssertEqual(controller.targetBitrate, 17_000_000)
        XCTAssertEqual(controller.targetFPS, 60)
    }

    func testQualityFirstReducesBitrateAndFPSOnFirstCongestionStep() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        controller.noteServerQueue(bytes: 500_000, now: start)
        controller.noteServerQueue(bytes: 500_000, now: start.addingTimeInterval(0.6))

        XCTAssertEqual(controller.targetFPS, 48)
        XCTAssertEqual(controller.targetBitrate, 17_000_000)
    }

    func testNormalRTTJitterStaysWithinNetworkDelayBudget() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        for index in 0..<8 {
            acknowledge(
                controller,
                queue: .unavailable,
                latency: 10,
                at: start.addingTimeInterval(Double(index) * 0.05)
            )
        }
        for index in 0..<4 {
            acknowledge(
                controller,
                queue: .unavailable,
                latency: 25,
                at: start.addingTimeInterval(0.5 + Double(index) * 0.3)
            )
        }

        XCTAssertEqual(controller.targetFPS, 60)
        XCTAssertEqual(controller.targetBitrate, 20_000_000)
        XCTAssertLessThan(controller.performanceSnapshot().networkPressure, 1)
    }

    func testNetworkRecoveryRequiresDwellAndIsGradual() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        seedHealthy(controller, at: start)
        controller.noteServerQueue(bytes: 500_000, now: start.addingTimeInterval(1))
        controller.noteServerQueue(bytes: 500_000, now: start.addingTimeInterval(1.6))
        let reducedFPS = controller.targetFPS
        XCTAssertLessThan(reducedFPS, 60)

        controller.noteServerQueue(bytes: 0, now: start.addingTimeInterval(1.8))
        XCTAssertEqual(controller.targetFPS, reducedFPS)
        for index in 0..<10 {
            noteVideoDemand(controller, interval: 0.1,
                now: start.addingTimeInterval(2.0 + Double(index) * 0.1))
        }
        controller.noteServerQueue(bytes: 0, now: start.addingTimeInterval(3.0))

        let partiallyRecoveredFPS = controller.targetFPS
        XCTAssertGreaterThan(partiallyRecoveredFPS, reducedFPS)
        XCTAssertLessThan(partiallyRecoveredFPS, 60)
        XCTAssertEqual(controller.targetBitrate, 20_000_000)
        controller.noteServerQueue(bytes: 0, now: start.addingTimeInterval(4.2))
        XCTAssertGreaterThan(controller.targetFPS, partiallyRecoveredFPS)
        XCTAssertLessThan(controller.targetFPS, 60)
    }

    func testEncodePressureUsesTimeDwellAndNeverReducesBitrate() {
        let controller = makeMeasuredVideoController(
            bitrate: 4_000_000,
            fps: 60,
            adaptationPriority: .fpsFirst
        )
        let start = Date()
        for index in 0..<16 {
            let now = start.addingTimeInterval(Double(index) / 60)
            controller.noteEncodedFrame(bytes: 60_000, encodeMs: 90,
                encodeBusyIntervalMs: 45, encoderBacklogged: true, now: now)
        }
        XCTAssertEqual(controller.targetFPS, 60)

        controller.noteEncodedFrame(bytes: 60_000, encodeMs: 90,
            encodeBusyIntervalMs: 45, encoderBacklogged: true,
            now: start.addingTimeInterval(1.3))

        XCTAssertLessThan(controller.targetFPS, 60)
        XCTAssertEqual(controller.targetBitrate, 4_000_000)
    }

    func testPipelineLatencyDoesNotLimitAchievedSixtyFPSThroughput() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        for index in 0..<180 {
            controller.noteEncodedFrame(bytes: 10_000, encodeMs: 32,
                encodeBusyIntervalMs: 1_000 / 60, encoderBacklogged: true,
                now: start.addingTimeInterval(Double(index) / 60))
        }
        XCTAssertEqual(controller.targetFPS, 60)
        XCTAssertEqual(controller.performanceSnapshot().encoderPressure, 0)
    }

    func testApplicationLimitedEncoderDoesNotKeepAStaleCapacityCap() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        for index in 0..<12 {
            controller.noteEncodedFrame(bytes: 10_000, encodeMs: 80,
                encodeBusyIntervalMs: 40, encoderBacklogged: true,
                now: start.addingTimeInterval(Double(index) * 0.1))
        }
        XCTAssertLessThan(controller.targetFPS, 60)
        for index in 0..<10 {
            controller.noteEncodedFrame(bytes: 1_000, encodeMs: 30, encoderBacklogged: false,
                now: start.addingTimeInterval(2 + Double(index) * 1.1))
        }
        XCTAssertEqual(controller.targetFPS, 60)
    }

    func testEncoderFrameDropOnlyUpdatesTelemetry() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)

        for _ in 0..<20 {
            controller.noteEncodeDrop()
        }

        XCTAssertEqual(controller.targetFPS, 60)
        XCTAssertEqual(controller.targetBitrate, 20_000_000)
    }

    func testQoEIsDiagnosticAndDoesNotAdaptTargets() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        controller.noteClientQoE(renderMs: 113, now: start)
        controller.noteClientQoE(renderMs: 113, now: start.addingTimeInterval(0.6))

        XCTAssertEqual(controller.targetFPS, 60)
        XCTAssertEqual(controller.targetBitrate, 20_000_000)
        XCTAssertEqual(controller.performanceSnapshot().clientPressure, 0)
    }

    func testStallRecoveryStillRequiresRepeatedTimeouts() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)

        XCTAssertFalse(controller.noteBackpressureTimeout(unackedWas: 3))
        XCTAssertFalse(controller.stallRecoveryMode)
        XCTAssertTrue(controller.noteBackpressureTimeout(unackedWas: 3))
        XCTAssertTrue(controller.stallRecoveryMode)
        XCTAssertEqual(controller.targetFPS, 30)
        XCTAssertEqual(controller.targetBitrate, 10_000_000)
    }

    func testSessionResetClearsSplitFeedback() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        controller.noteServerQueue(bytes: 100_000)
        acknowledge(controller, queue: .queued(bytes: 80_000), latency: 200)
        controller.resetSession()

        XCTAssertEqual(controller.clientQueueFeedback, .unavailable)
        XCTAssertNil(controller.lastClientQueueDelayMs)
        XCTAssertEqual(controller.lastServerQueueBytes, 0)
        XCTAssertEqual(controller.lastServerQueueDelayMs, 0)
        XCTAssertEqual(controller.targetFPS, 60)
        XCTAssertEqual(controller.targetBitrate, VideoTargetController.initialAdaptiveBitrate)
        XCTAssertEqual(controller.configuredBitrate, 20_000_000)
    }

    func testConcurrentFeedbackAndSnapshotsAreSafe() {
        let controller = makeMeasuredVideoController(bitrate: 20_000_000, fps: 60)
        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            let queue: ClientQueueFeedback = index.isMultiple(of: 5)
                ? .unavailable
                : .queued(bytes: index * 100)
            controller.noteFrameAck(
                clientQueue: queue,
                ackLatencyMs: Double(30 + index % 200),
                unacked: index % 10,
                acknowledgedBytes: 10_000,
                acknowledgementIntervalMs: 16
            )
            _ = controller.performanceSnapshot()
        }

        XCTAssertGreaterThanOrEqual(controller.targetFPS, VideoTargetController.minAdaptiveFPS)
        XCTAssertGreaterThanOrEqual(controller.targetBitrate, VideoTargetController.minAdaptiveBitrate)
    }

    private func seed(
        _ controller: VideoTargetController,
        bandwidthKbps: UInt32,
        rttMs: UInt32,
        now: Date = Date()
    ) {
        var metrics = NetworkAutoDetect.Metrics()
        metrics.baseRTTMs = rttMs
        metrics.averageRTTMs = rttMs
        metrics.bandwidthKbps = bandwidthKbps
        metrics.rttMeasuredAtNanoseconds = 1
        metrics.bandwidthMeasuredAtNanoseconds = 2
        controller.updateAutoDetect(metrics, now: now)
    }

    private func acknowledge(
        _ controller: VideoTargetController,
        queue: ClientQueueFeedback,
        latency: Double,
        unacked: Int = 0,
        at: Date = Date(),
        acknowledgedBytes: Int = 0,
        intervalMs: Double = 0
    ) {
        controller.noteFrameAck(
            clientQueue: queue,
            ackLatencyMs: latency,
            unacked: unacked,
            acknowledgedBytes: acknowledgedBytes,
            acknowledgementIntervalMs: intervalMs,
            now: at
        )
    }

    private func seedHealthy(_ controller: VideoTargetController, at date: Date) {
        for index in 0..<8 {
            acknowledge(
                controller,
                queue: .unavailable,
                latency: 30,
                at: date.addingTimeInterval(Double(index) * 0.05),
                acknowledgedBytes: 100_000,
                intervalMs: 100
            )
        }
    }
}
