import Dispatch
import XCTest
@testable import SwiftRDPCore

final class VideoTargetControllerTests: XCTestCase {
    func testStartsAtConfiguredTargets() {
        let controller = VideoTargetController(bitrate: 20_000_000, fps: 60)

        XCTAssertEqual(controller.targetBitrate, 20_000_000)
        XCTAssertEqual(controller.targetFPS, 60)
        XCTAssertFalse(controller.bitrateReduced)
    }

    func testFrameAckQueueUsesProtocolStates() {
        let controller = VideoTargetController(bitrate: 20_000_000, fps: 60)

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
        let controller = VideoTargetController(bitrate: 20_000_000, fps: 60)

        acknowledge(
            controller,
            queue: .unavailable,
            latency: 30,
            acknowledgedBytes: 100_000,
            intervalMs: 100
        )

        XCTAssertNil(controller.lastClientQueueDelayMs)
        XCTAssertEqual(controller.perfSnapshot.quality.clientQueue, .unavailable)
    }

    func testClientQueuePressureDoesNotReduceNetworkBitrate() {
        let controller = VideoTargetController(
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
        XCTAssertEqual(controller.perfSnapshot.pressureSource, .clientQueue)
        XCTAssertEqual(controller.perfSnapshot.networkPressure, 0, accuracy: 0.01)
    }

    func testServerQueueUsesTimeBudgetAndReducesNetworkLoad() {
        let controller = VideoTargetController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        let queuedBytes = Int(20_000_000.0 * 0.2 / 8.0)

        controller.noteServerQueue(bytes: queuedBytes, now: start)
        XCTAssertEqual(controller.lastServerQueueDelayMs, 200, accuracy: 0.1)
        XCTAssertEqual(controller.targetFPS, 60)

        controller.noteServerQueue(bytes: queuedBytes, now: start.addingTimeInterval(0.6))

        XCTAssertLessThan(controller.targetFPS, 60)
        XCTAssertEqual(controller.targetBitrate, 20_000_000)
        XCTAssertEqual(controller.perfSnapshot.pressureSource, .serverQueue)
    }

    func testLiveAckRateOverridesStaleAutoDetectRateForQueueDelay() {
        let controller = VideoTargetController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        controller.seedFromAutoDetect(bandwidthKbps: 100_000, rttMs: 10, now: start)
        controller.noteServerQueue(bytes: 500_000, now: start)

        controller.noteFrameAck(
            clientQueue: .unavailable,
            ackLatencyMs: 10,
            unacked: 0,
            acknowledgedBytes: 25_000,
            acknowledgedFrames: 1,
            acknowledgementIntervalMs: 100,
            now: start.addingTimeInterval(1)
        )
        controller.noteServerQueue(bytes: 500_000, now: start.addingTimeInterval(1))

        XCTAssertGreaterThan(controller.lastServerQueueDelayMs, 1_000)
    }

    func testServerQueueDelayUsesMeasuredDrainRate() {
        let controller = VideoTargetController(bitrate: 20_000_000, fps: 60)
        controller.seedFromAutoDetect(bandwidthKbps: 100_000, rttMs: 10)

        controller.noteServerQueue(bytes: 500_000)

        XCTAssertEqual(controller.serverQueueDrainBitrate, 100_000_000)
        XCTAssertEqual(controller.lastServerQueueDelayMs, 40, accuracy: 0.1)
        XCTAssertEqual(controller.targetFPS, 60)
        XCTAssertEqual(controller.targetBitrate, 20_000_000)
    }

    func testExpiredAutoDetectRateDoesNotLimitNetworkAdaptation() {
        let controller = VideoTargetController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        controller.seedFromAutoDetect(bandwidthKbps: 5_000, rttMs: 10, now: start)

        controller.noteServerQueue(bytes: 500_000, now: start.addingTimeInterval(31))

        XCTAssertEqual(controller.lastServerQueueDelayMs, 200, accuracy: 0.1)
    }

    func testFullAckWindowWithHealthyAcksDoesNotCreateNetworkPressure() {
        let controller = VideoTargetController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        controller.noteEncodedFrame(
            bytes: 100_000,
            fps: 60,
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
        XCTAssertEqual(controller.perfSnapshot.quality.networkPressure, 0, accuracy: 0.01)
        XCTAssertGreaterThan(controller.linkQualityScore, 0.9)
    }

    func testNetworkPressureRequiresTimeDwellBeforeAdapting() {
        let controller = VideoTargetController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        seedHealthy(controller, at: start)
        controller.noteEncodedFrame(
            bytes: 100_000,
            fps: 60,
            serverUnacked: 0,
            ackWindow: 2,
            now: start
        )

        acknowledge(
            controller,
            queue: .unavailable,
            latency: 220,
            unacked: 0,
            at: start.addingTimeInterval(1)
        )
        XCTAssertEqual(controller.targetFPS, 60)

        acknowledge(
            controller,
            queue: .unavailable,
            latency: 220,
            unacked: 0,
            at: start.addingTimeInterval(1.1)
        )
        XCTAssertEqual(controller.targetFPS, 60)

        acknowledge(
            controller,
            queue: .unavailable,
            latency: 220,
            unacked: 0,
            at: start.addingTimeInterval(1.6)
        )
        XCTAssertLessThan(controller.targetFPS, 60)
    }

    func testNetworkSpikeCannotAdaptMoreThanOncePerCooldown() {
        let controller = VideoTargetController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        seedHealthy(controller, at: start)

        acknowledge(
            controller,
            queue: .unavailable,
            latency: 220,
            at: start.addingTimeInterval(1)
        )
        acknowledge(
            controller,
            queue: .unavailable,
            latency: 220,
            at: start.addingTimeInterval(1.6)
        )
        let firstReducedFPS = controller.targetFPS
        XCTAssertLessThan(firstReducedFPS, 60)

        acknowledge(
            controller,
            queue: .unavailable,
            latency: 220,
            at: start.addingTimeInterval(1.61)
        )
        XCTAssertEqual(controller.targetFPS, firstReducedFPS)

        acknowledge(
            controller,
            queue: .unavailable,
            latency: 220,
            at: start.addingTimeInterval(2.11)
        )
        XCTAssertLessThan(controller.targetFPS, firstReducedFPS)
    }

    func testSingleLowAckSampleCannotCollapseBitrate() {
        let controller = VideoTargetController(
            bitrate: 20_000_000,
            fps: 60,
            adaptationPriority: .fpsFirst
        )
        let start = Date()
        seedHealthy(controller, at: start)

        acknowledge(
            controller,
            queue: .unavailable,
            latency: 220,
            at: start.addingTimeInterval(1),
            acknowledgedBytes: 5_000,
            intervalMs: 100
        )
        acknowledge(
            controller,
            queue: .unavailable,
            latency: 220,
            at: start.addingTimeInterval(1.6),
            acknowledgedBytes: 5_000,
            intervalMs: 100
        )

        XCTAssertEqual(controller.targetBitrate, 17_000_000)
        XCTAssertEqual(controller.targetFPS, 60)
    }

    func testQualityFirstReachesMinimumFPSBeforeReducingBitrate() {
        let controller = VideoTargetController(bitrate: 20_000_000, fps: 60)
        let start = Date()

        for index in 0..<14 {
            controller.noteServerQueue(
                bytes: 500_000,
                now: start.addingTimeInterval(Double(index) * 0.6)
            )
        }

        XCTAssertEqual(controller.targetFPS, VideoTargetController.minAdaptiveFPS)
        XCTAssertEqual(controller.targetBitrate, 20_000_000)

        controller.noteServerQueue(bytes: 500_000, now: start.addingTimeInterval(8.4))
        XCTAssertEqual(controller.targetBitrate, 17_000_000)
    }

    func testNormalRTTJitterStaysWithinNetworkDelayBudget() {
        let controller = VideoTargetController(bitrate: 20_000_000, fps: 60)
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
        XCTAssertLessThan(controller.perfSnapshot.networkPressure, 1)
    }

    func testNetworkRecoveryRequiresDwellAndIsGradual() {
        let controller = VideoTargetController(bitrate: 20_000_000, fps: 60)
        let start = Date()
        seedHealthy(controller, at: start)
        controller.noteServerQueue(bytes: 500_000, now: start.addingTimeInterval(1))
        controller.noteServerQueue(bytes: 500_000, now: start.addingTimeInterval(1.6))
        let reducedFPS = controller.targetFPS
        XCTAssertLessThan(reducedFPS, 60)

        controller.noteServerQueue(bytes: 0, now: start.addingTimeInterval(1.8))
        XCTAssertEqual(controller.targetFPS, reducedFPS)
        controller.noteServerQueue(bytes: 0, now: start.addingTimeInterval(3.0))

        XCTAssertGreaterThan(controller.targetFPS, reducedFPS)
        XCTAssertLessThan(controller.targetFPS, 60)
    }

    func testEncodePressureUsesTimeDwellAndNeverReducesBitrate() {
        let controller = VideoTargetController(
            bitrate: 4_000_000,
            fps: 60,
            adaptationPriority: .fpsFirst
        )
        let start = Date()
        for index in 0..<16 {
            let now = start.addingTimeInterval(Double(index) / 60)
            controller.noteEncodedFrame(bytes: 60_000, fps: 60, encodeMs: 45, now: now)
            controller.noteEncodePressure(now: now)
        }
        XCTAssertEqual(controller.targetFPS, 60)

        controller.noteEncodePressure(now: start.addingTimeInterval(1.3))

        XCTAssertLessThan(controller.targetFPS, 60)
        XCTAssertEqual(controller.targetBitrate, 4_000_000)
    }

    func testEncoderFrameDropOnlyUpdatesTelemetry() {
        let controller = VideoTargetController(bitrate: 20_000_000, fps: 60)

        for _ in 0..<20 {
            controller.noteEncodeDrop()
        }

        XCTAssertEqual(controller.targetFPS, 60)
        XCTAssertEqual(controller.targetBitrate, 20_000_000)
    }

    func testClientRenderPressureUsesTimeDwell() {
        let controller = VideoTargetController(bitrate: 20_000_000, fps: 60)
        let start = Date()

        controller.noteClientRenderTiming(commandDecodeMs: 32, renderMs: 81, now: start)
        XCTAssertEqual(controller.targetFPS, 60)
        controller.noteClientRenderTiming(
            commandDecodeMs: 32,
            renderMs: 81,
            now: start.addingTimeInterval(0.1)
        )
        XCTAssertEqual(controller.targetFPS, 60)
        controller.noteClientRenderTiming(
            commandDecodeMs: 32,
            renderMs: 81,
            now: start.addingTimeInterval(0.6)
        )

        XCTAssertLessThan(controller.targetFPS, 60)
        XCTAssertEqual(controller.targetBitrate, 20_000_000)
        XCTAssertEqual(controller.perfSnapshot.pressureSource, .decoder)
    }

    func testStallRecoveryStillRequiresRepeatedTimeouts() {
        let controller = VideoTargetController(bitrate: 20_000_000, fps: 60)

        XCTAssertFalse(controller.noteBackpressureTimeout(unackedWas: 3))
        XCTAssertFalse(controller.stallRecoveryMode)
        XCTAssertTrue(controller.noteBackpressureTimeout(unackedWas: 3))
        XCTAssertTrue(controller.stallRecoveryMode)
        XCTAssertEqual(controller.targetFPS, 30)
        XCTAssertEqual(controller.targetBitrate, 10_000_000)
    }

    func testSessionResetClearsSplitFeedback() {
        let controller = VideoTargetController(bitrate: 20_000_000, fps: 60)
        controller.noteServerQueue(bytes: 100_000)
        acknowledge(controller, queue: .queued(bytes: 80_000), latency: 200)
        controller.resetSession()

        XCTAssertEqual(controller.clientQueueFeedback, .unavailable)
        XCTAssertNil(controller.lastClientQueueDelayMs)
        XCTAssertEqual(controller.lastServerQueueBytes, 0)
        XCTAssertEqual(controller.lastServerQueueDelayMs, 0)
        XCTAssertEqual(controller.targetFPS, 60)
        XCTAssertEqual(controller.targetBitrate, 20_000_000)
    }

    func testConcurrentFeedbackAndSnapshotsAreSafe() {
        let controller = VideoTargetController(bitrate: 20_000_000, fps: 60)
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
            _ = controller.perfSnapshot
        }

        XCTAssertGreaterThanOrEqual(controller.targetFPS, VideoTargetController.minAdaptiveFPS)
        XCTAssertGreaterThanOrEqual(controller.targetBitrate, VideoTargetController.minAdaptiveBitrate)
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
