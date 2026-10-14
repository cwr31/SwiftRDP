import Foundation
import NIOCore

/// MS-RDPBCGR network characteristics probes, confined to the main TCP event loop.
public final class NetworkAutoDetect: @unchecked Sendable {
    public struct Metrics: Equatable, Sendable {
        public var baseRTTMs: UInt32 = 0
        public var averageRTTMs: UInt32 = 0
        public var bandwidthKbps: UInt32 = 0
        public var rttMeasuredAtNanoseconds: UInt64 = 0
        public var bandwidthMeasuredAtNanoseconds: UInt64 = 0
        public var hasRTT: Bool { averageRTTMs > 0 || baseRTTMs > 0 }
        public var hasBandwidth: Bool { bandwidthKbps > 0 }
    }

    public enum Phase: Equatable {
        case idle, connectRTT, connectBandwidth, complete, continuousRTT
    }

    public private(set) var phase: Phase = .idle
    public private(set) var metrics = Metrics()
    public var onSend: (([UInt8]) -> Void)?
    public var onConnectTimeFinished: (() -> Void)?
    public var onMetricsUpdated: ((Metrics) -> Void)?
    public var onConnectionUnresponsive: (() -> Void)?

    private let eventLoop: EventLoop
    private var sequence: UInt16 = 0x20
    private var pendingSequence: UInt16?
    private var rttStartedAt: UInt64 = 0
    private var timeoutTask: Scheduled<Void>?
    private var continuousTask: Scheduled<Void>?
    private var missedProbes = 0

    public init(eventLoop: EventLoop) { self.eventLoop = eventLoop }

    deinit {
        timeoutTask?.cancel()
        continuousTask?.cancel()
    }

    public var isConnectTimeInFlight: Bool { phase == .connectRTT || phase == .connectBandwidth }

    public func beginConnectTime() {
        eventLoop.preconditionInEventLoop()
        guard phase == .idle else { return }
        phase = .connectRTT
        beginRTT(connectTime: true)
    }

    public func startContinuous() {
        eventLoop.preconditionInEventLoop()
        guard phase == .idle || phase == .complete else { return }
        continuousTask?.cancel()
        missedProbes = 0
        scheduleContinuous(in: .seconds(2))
    }

    public func stop() {
        eventLoop.preconditionInEventLoop()
        timeoutTask?.cancel(); timeoutTask = nil
        continuousTask?.cancel(); continuousTask = nil
        phase = .idle
        pendingSequence = nil
        missedProbes = 0
    }

    public func handleClientResponse(_ response: AutoDetectPDU.ClientResponse) {
        eventLoop.preconditionInEventLoop()
        switch response {
        case .rtt(let receivedSequence):
            guard receivedSequence == pendingSequence,
                  phase == .connectRTT || phase == .continuousRTT else { return }
            let connect = phase == .connectRTT
            let elapsed = (eventLoop.now.uptimeNanoseconds - rttStartedAt) / 1_000_000
            applyRTT(UInt32(clamping: max(elapsed, 1)))
            timeoutTask?.cancel(); timeoutTask = nil
            pendingSequence = nil
            missedProbes = 0
            phase = connect ? .connectBandwidth : .complete
            onMetricsUpdated?(metrics)
            if connect { beginBandwidth() }

        case .bandwidthResults(let receivedSequence, let responseType, let timeDeltaMs, let byteCount):
            guard phase == .connectBandwidth, receivedSequence == pendingSequence,
                  responseType == AutoDetectPDU.bwResultsConnectTime else { return }
            let kbps = AutoDetectPDU.bandwidthKbps(timeDeltaMs: timeDeltaMs, byteCount: byteCount)
            if kbps > 0 {
                metrics.bandwidthKbps = kbps
                metrics.bandwidthMeasuredAtNanoseconds = measurementTime
            }
            onMetricsUpdated?(metrics)
            finishConnectTime()

        case .netCharSync(let receivedSequence, let bandwidthKbps, let rttMs):
            guard isConnectTimeInFlight, receivedSequence == pendingSequence else { return }
            if bandwidthKbps > 0 {
                metrics.bandwidthKbps = bandwidthKbps
                metrics.bandwidthMeasuredAtNanoseconds = measurementTime
            }
            if rttMs > 0 {
                metrics.baseRTTMs = rttMs
                metrics.averageRTTMs = rttMs
                metrics.rttMeasuredAtNanoseconds = measurementTime
            }
            onMetricsUpdated?(metrics)
            finishConnectTime(publish: false)
        }
    }

    private var measurementTime: UInt64 { max(eventLoop.now.uptimeNanoseconds, 1) }

    private func nextSequence() -> UInt16 {
        sequence &+= 1
        if sequence == 0 { sequence = 1 }
        return sequence
    }

    private func beginRTT(connectTime: Bool) {
        pendingSequence = nextSequence()
        rttStartedAt = eventLoop.now.uptimeNanoseconds
        timeoutTask?.cancel()
        timeoutTask = eventLoop.scheduleTask(in: .seconds(3)) { [weak self] in
            guard let self else { return }
            if connectTime { finishConnectTime() }
            else { expireContinuousRTT() }
        }
        onSend?(AutoDetectPDU.encodeRTTRequest(sequenceNumber: sequence, connectTime: connectTime))
    }

    private func beginBandwidth() {
        pendingSequence = nextSequence()
        timeoutTask = eventLoop.scheduleTask(in: .seconds(5)) { [weak self] in self?.finishConnectTime() }
        onSend?(AutoDetectPDU.encodeBandwidthStart(sequenceNumber: sequence, connectTime: true))
        // A bounded connect-time payload gives sub-millisecond paths a measurable interval.
        for _ in 0..<48 {
            onSend?(AutoDetectPDU.encodeBandwidthPayload(sequenceNumber: sequence, payloadLength: 4096))
        }
        onSend?(AutoDetectPDU.encodeBandwidthStop(sequenceNumber: sequence, connectTime: true))
    }

    private func finishConnectTime(publish: Bool = true) {
        guard isConnectTimeInFlight else { return }
        timeoutTask?.cancel(); timeoutTask = nil
        pendingSequence = nil
        phase = .complete
        if publish, metrics.hasRTT || metrics.hasBandwidth {
            onSend?(AutoDetectPDU.encodeNetCharResult(sequenceNumber: nextSequence(),
                baseRTTMs: metrics.baseRTTMs, bandwidthKbps: metrics.bandwidthKbps,
                averageRTTMs: metrics.averageRTTMs))
        }
        onConnectTimeFinished?()
    }

    private func scheduleContinuous(in delay: TimeAmount) {
        continuousTask = eventLoop.scheduleTask(in: delay) { [weak self] in
            guard let self, phase == .idle || phase == .complete else { return }
            phase = .continuousRTT
            scheduleContinuous(in: .seconds(15))
            beginRTT(connectTime: false)
        }
    }

    private func expireContinuousRTT() {
        guard phase == .continuousRTT else { return }
        timeoutTask = nil
        pendingSequence = nil
        phase = .complete
        missedProbes += 1
        if missedProbes == 3 {
            stop()
            onConnectionUnresponsive?()
        }
    }

    private func applyRTT(_ ms: UInt32) {
        metrics.rttMeasuredAtNanoseconds = measurementTime
        metrics.averageRTTMs = metrics.averageRTTMs == 0 ? ms
            : UInt32((Double(metrics.averageRTTMs) * 0.8 + Double(ms) * 0.2).rounded())
        metrics.baseRTTMs = metrics.baseRTTMs == 0 ? ms : min(metrics.baseRTTMs, ms)
    }
}
