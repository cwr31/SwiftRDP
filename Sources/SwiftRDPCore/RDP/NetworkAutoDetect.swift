import Foundation

/// Server-side Network Characteristics Detection (MS-RDPBCGR 1.3.9 / 2.2.14).
/// Probe state is serialized because responses arrive on NIO while the
/// continuous scheduler runs in a Swift task.
public final class NetworkAutoDetect: @unchecked Sendable {
    public struct Metrics: Equatable, Sendable {
        public var baseRTTMs: UInt32 = 0
        public var averageRTTMs: UInt32 = 0
        /// Kilobits per second. Zero means that no valid bandwidth sample exists.
        public var bandwidthKbps: UInt32 = 0
        public var hasRTT: Bool { averageRTTMs > 0 || baseRTTMs > 0 }
        public var hasBandwidth: Bool { bandwidthKbps > 0 }
    }

    public enum Phase: Equatable {
        case idle
        case connectRTT
        case connectBandwidth
        case complete
        case continuousRTT
        case continuousBandwidth
    }

    private let lock = NSLock()
    private var phaseValue: Phase = .idle
    private var metricsValue = Metrics()
    private var onSendHandler: (([UInt8]) -> Void)?
    private var onConnectTimeFinishedHandler: (() -> Void)?
    private var onMetricsUpdatedHandler: ((Metrics) -> Void)?
    private var shouldDeferContinuousBandwidthHandler: (() -> Bool)?

    private var sequence: UInt16 = 0x20
    private var rttStartedAt: Date?
    private var pendingRTTSequence: UInt16?
    private var pendingBWSequence: UInt16?
    private var lastResultSequence: UInt16?
    private var connectTimeFinished = false
    private var operationGeneration: UInt64 = 0
    private var continuousGeneration: UInt64 = 0
    private var timeoutTask: Task<Void, Never>?
    private var continuousTask: Task<Void, Never>?

    /// Connect-time probes deliberately use a payload so the client can measure
    /// a sub-millisecond LAN path. Continuous probes measure existing traffic.
    private static let connectPayloadCount = 48
    private static let connectPayloadBytes: UInt16 = 4096
    private static let connectTimeoutNs: UInt64 = 3_000_000_000
    private static let continuousRTTIntervalNs: UInt64 = 15_000_000_000
    private static let continuousRTTTimeoutNs: UInt64 = 3_000_000_000
    private static let continuousBWIntervalNs: UInt64 = 45_000_000_000
    private static let continuousBWIntervalWhenHotNs: UInt64 = 90_000_000_000
    private static let continuousBWWindowNs: UInt64 = 1_000_000_000

    public init() {}

    deinit {
        let tasks = locked {
            (timeoutTask, continuousTask)
        }
        tasks.0?.cancel()
        tasks.1?.cancel()
    }

    public var phase: Phase { locked { phaseValue } }
    public var metrics: Metrics { locked { metricsValue } }

    public var onSend: (([UInt8]) -> Void)? {
        get { locked { onSendHandler } }
        set { locked { onSendHandler = newValue } }
    }

    public var onConnectTimeFinished: (() -> Void)? {
        get { locked { onConnectTimeFinishedHandler } }
        set { locked { onConnectTimeFinishedHandler = newValue } }
    }

    public var onMetricsUpdated: ((Metrics) -> Void)? {
        get { locked { onMetricsUpdatedHandler } }
        set { locked { onMetricsUpdatedHandler = newValue } }
    }

    public var shouldDeferContinuousBandwidth: (() -> Bool)? {
        get { locked { shouldDeferContinuousBandwidthHandler } }
        set { locked { shouldDeferContinuousBandwidthHandler = newValue } }
    }

    public var isConnectTimeInFlight: Bool {
        locked { phaseValue == .connectRTT || phaseValue == .connectBandwidth }
    }

    /// Begin Optional Connect-Time Auto-Detection (before licensing).
    public func beginConnectTime() {
        let request: (sequence: UInt16, pdu: [UInt8], generation: UInt64)? = locked {
            guard phaseValue == .idle else { return nil }
            connectTimeFinished = false
            operationGeneration &+= 1
            let generation = operationGeneration
            let sequence = nextSequenceLocked()
            phaseValue = .connectRTT
            pendingRTTSequence = sequence
            rttStartedAt = Date()
            return (
                sequence,
                AutoDetectPDU.encodeRTTRequest(
                    sequenceNumber: sequence,
                    connectTime: true
                ),
                generation
            )
        }
        guard let request else { return }
        send(request.pdu)
        armConnectTimeout(generation: request.generation)
        RDPLog.rdp.info("AutoDetect: connect-time RTT request seq=\(request.sequence)")
    }

    public func startContinuous() {
        let (oldTask, generation) = locked {
            continuousGeneration &+= 1
            let oldTask = continuousTask
            continuousTask = nil
            return (oldTask, continuousGeneration)
        }
        oldTask?.cancel()

        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            var lastBandwidthProbe = Date.distantPast
            while !Task.isCancelled {
                guard let self, self.isContinuousGeneration(generation) else { return }
                self.startContinuousRTT()

                try? await Task.sleep(nanoseconds: Self.continuousRTTTimeoutNs)
                guard !Task.isCancelled, self.isContinuousGeneration(generation) else { return }
                self.expireContinuousRTT()

                try? await Task.sleep(nanoseconds: Self.continuousRTTIntervalNs - Self.continuousRTTTimeoutNs)
                guard !Task.isCancelled, self.isContinuousGeneration(generation) else { return }

                let desktopHot = self.shouldDeferBandwidth()
                let interval = desktopHot
                    ? Self.continuousBWIntervalWhenHotNs
                    : Self.continuousBWIntervalNs
                let enoughTimePassed = Date().timeIntervalSince(lastBandwidthProbe)
                    >= TimeInterval(interval) / 1_000_000_000
                if enoughTimePassed, !desktopHot,
                   let sequence = self.startContinuousBandwidth() {
                    lastBandwidthProbe = Date()
                    try? await Task.sleep(nanoseconds: Self.continuousBWWindowNs)
                    guard !Task.isCancelled, self.isContinuousGeneration(generation) else { return }
                    self.stopContinuousBandwidth(sequence: sequence)
                    try? await Task.sleep(nanoseconds: Self.continuousRTTTimeoutNs)
                    guard !Task.isCancelled, self.isContinuousGeneration(generation) else { return }
                    self.expireContinuousBandwidth(sequence: sequence)
                } else if desktopHot {
                    RDPLog.rdp.debug("AutoDetect: defer continuous BW probe (desktop hot)")
                }
            }
        }

        let keepTask = locked {
            guard continuousGeneration == generation else { return false }
            continuousTask = task
            return true
        }
        if !keepTask { task.cancel() }
    }

    public func stop() {
        let tasks = locked {
            continuousGeneration &+= 1
            operationGeneration &+= 1
            let tasks = (timeoutTask, continuousTask)
            timeoutTask = nil
            continuousTask = nil
            phaseValue = .idle
            pendingRTTSequence = nil
            pendingBWSequence = nil
            rttStartedAt = nil
            lastResultSequence = nil
            return tasks
        }
        tasks.0?.cancel()
        tasks.1?.cancel()
    }

    public func handleClientResponse(_ response: AutoDetectPDU.ClientResponse) {
        switch response {
        case .rtt(let sequence):
            handleRTTResponse(sequence: sequence)
        case .bandwidthResults(
            let sequence,
            let responseType,
            let timeDeltaMs,
            let byteCount
        ):
            handleBandwidthResponse(
                sequence: sequence,
                responseType: responseType,
                timeDeltaMs: timeDeltaMs,
                byteCount: byteCount
            )
        case .netCharSync(let sequence, let bandwidthKbps, let rttMs):
            handleNetCharSync(
                sequence: sequence,
                bandwidthKbps: bandwidthKbps,
                rttMs: rttMs
            )
        }
    }

    // MARK: - Probe responses

    private func handleRTTResponse(sequence: UInt16) {
        let action: (metrics: Metrics, connect: Bool, bandwidthPDUs: [[UInt8]])? = locked {
            guard pendingRTTSequence == sequence,
                  let started = rttStartedAt,
                  phaseValue == .connectRTT || phaseValue == .continuousRTT
            else { return nil }

            let elapsedMs = max(1, Int(Date().timeIntervalSince(started) * 1000))
            pendingRTTSequence = nil
            rttStartedAt = nil
            applyRTTLocked(UInt32(min(elapsedMs, Int(UInt32.max))))

            if phaseValue == .connectRTT {
                phaseValue = .connectBandwidth
                let sequence = nextSequenceLocked()
                pendingBWSequence = sequence
                var pdus = [AutoDetectPDU.encodeBandwidthStart(
                    sequenceNumber: sequence,
                    connectTime: true
                )]
                pdus.reserveCapacity(Self.connectPayloadCount + 2)
                for _ in 0..<Self.connectPayloadCount {
                    pdus.append(AutoDetectPDU.encodeBandwidthPayload(
                        sequenceNumber: sequence,
                        payloadLength: Self.connectPayloadBytes
                    ))
                }
                pdus.append(AutoDetectPDU.encodeBandwidthStop(
                    sequenceNumber: sequence,
                    connectTime: true
                ))
                return (metricsValue, true, pdus)
            }

            phaseValue = .complete
            return (metricsValue, false, [])
        }
        guard let action else { return }

        notifyMetrics(action.metrics)
        if action.connect {
            sendAll(action.bandwidthPDUs)
            RDPLog.rdp.info(
                "AutoDetect: connect-time BW probe payloads=" +
                    "\(Self.connectPayloadCount)x\(Self.connectPayloadBytes)B"
            )
        } else {
            publishNetCharResult()
        }
    }

    private func handleBandwidthResponse(
        sequence: UInt16,
        responseType: UInt16,
        timeDeltaMs: UInt32,
        byteCount: UInt32
    ) {
        let action: (metrics: Metrics, connect: Bool)? = locked {
            let connect = phaseValue == .connectBandwidth
                && responseType == AutoDetectPDU.bwResultsConnectTime
            let continuous = phaseValue == .continuousBandwidth
                && responseType == AutoDetectPDU.bwResultsContinuous
            guard pendingBWSequence == sequence, connect || continuous else { return nil }

            pendingBWSequence = nil
            if continuous { phaseValue = .complete }

            let kbps = AutoDetectPDU.bandwidthKbps(
                timeDeltaMs: timeDeltaMs,
                byteCount: byteCount
            )
            if kbps > 0 {
                let previous = metricsValue.bandwidthKbps
                metricsValue.bandwidthKbps = previous == 0
                    ? kbps
                    : UInt32((Double(previous) * 0.75 + Double(kbps) * 0.25).rounded())
            }
            return (metricsValue, connect)
        }
        guard let action else { return }

        let kbps = AutoDetectPDU.bandwidthKbps(
            timeDeltaMs: timeDeltaMs,
            byteCount: byteCount
        )
        RDPLog.rdp.info(
            "AutoDetect: BW results type=0x\(String(responseType, radix: 16)) " +
                "delta=\(timeDeltaMs)ms bytes=\(byteCount) -> \(kbps)kbps"
        )
        publishNetCharResult()
        if action.connect {
            finishConnectTime(publish: false)
        }
    }

    private func handleNetCharSync(
        sequence: UInt16,
        bandwidthKbps: UInt32,
        rttMs: UInt32
    ) {
        let action: (metrics: Metrics, connect: Bool)? = locked {
            let matchesCurrentProbe = sequence == pendingRTTSequence
                || sequence == pendingBWSequence
            let matchesPublishedResult = pendingRTTSequence == nil
                && pendingBWSequence == nil
                && sequence == lastResultSequence
            guard phaseValue != .idle,
                  matchesCurrentProbe || matchesPublishedResult
            else { return nil }

            let connect = phaseValue == .connectRTT || phaseValue == .connectBandwidth
            lastResultSequence = nil
            if bandwidthKbps > 0 { metricsValue.bandwidthKbps = bandwidthKbps }
            if rttMs > 0 {
                metricsValue.baseRTTMs = rttMs
                metricsValue.averageRTTMs = rttMs
            }
            pendingRTTSequence = nil
            pendingBWSequence = nil
            rttStartedAt = nil
            if !connect { phaseValue = .complete }
            return (metricsValue, connect)
        }
        guard let action else { return }
        if action.connect { finishConnectTime(publish: false) }
        notifyMetrics(action.metrics)
        RDPLog.rdp.info(
            "AutoDetect: client NETCHAR sync bw=\(bandwidthKbps)kbps rtt=\(rttMs)ms"
        )
    }

    // MARK: - Continuous probes

    private func startContinuousRTT() {
        let request: (UInt16, [UInt8])? = locked {
            guard phaseValue == .idle || phaseValue == .complete else { return nil }
            let sequence = nextSequenceLocked()
            phaseValue = .continuousRTT
            pendingRTTSequence = sequence
            rttStartedAt = Date()
            return (
                sequence,
                AutoDetectPDU.encodeRTTRequest(
                    sequenceNumber: sequence,
                    connectTime: false
                )
            )
        }
        guard let request else { return }
        send(request.1)
        RDPLog.rdp.debug("AutoDetect: continuous RTT request seq=\(request.0)")
    }

    private func expireContinuousRTT() {
        locked {
            guard phaseValue == .continuousRTT else { return }
            phaseValue = .complete
            pendingRTTSequence = nil
            rttStartedAt = nil
        }
    }

    private func startContinuousBandwidth() -> UInt16? {
        let request: (UInt16, [UInt8])? = locked {
            guard phaseValue == .idle || phaseValue == .complete else { return nil }
            let sequence = nextSequenceLocked()
            phaseValue = .continuousBandwidth
            pendingBWSequence = sequence
            return (
                sequence,
                AutoDetectPDU.encodeBandwidthStart(
                    sequenceNumber: sequence,
                    connectTime: false
                )
            )
        }
        guard let request else { return nil }
        send(request.1)
        RDPLog.rdp.debug(
            "AutoDetect: continuous BW window start seq=\(request.0) " +
                "(existing traffic only)"
        )
        return request.0
    }

    private func stopContinuousBandwidth(sequence: UInt16) {
        let pdu: [UInt8]? = locked {
            guard phaseValue == .continuousBandwidth,
                  pendingBWSequence == sequence
            else { return nil }
            return AutoDetectPDU.encodeBandwidthStop(
                sequenceNumber: sequence,
                connectTime: false
            )
        }
        guard let pdu else { return }
        send(pdu)
    }

    private func expireContinuousBandwidth(sequence: UInt16) {
        locked {
            guard phaseValue == .continuousBandwidth,
                  pendingBWSequence == sequence
            else { return }
            phaseValue = .complete
            pendingBWSequence = nil
        }
    }

    // MARK: - State and callbacks

    private func nextSequenceLocked() -> UInt16 {
        sequence &+= 1
        if sequence == 0 { sequence = 1 }
        return sequence
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func send(_ pdu: [UInt8]) {
        let handler = locked { onSendHandler }
        handler?(pdu)
    }

    private func sendAll(_ pdus: [[UInt8]]) {
        for pdu in pdus { send(pdu) }
    }

    private func notifyMetrics(_ metrics: Metrics) {
        let handler = locked { onMetricsUpdatedHandler }
        handler?(metrics)
    }

    private func shouldDeferBandwidth() -> Bool {
        let handler = locked { shouldDeferContinuousBandwidthHandler }
        return handler?() == true
    }

    private func isContinuousGeneration(_ generation: UInt64) -> Bool {
        locked { continuousGeneration == generation }
    }

    private func applyRTTLocked(_ ms: UInt32) {
        guard ms > 0 else { return }
        metricsValue.averageRTTMs = metricsValue.averageRTTMs == 0
            ? ms
            : UInt32((Double(metricsValue.averageRTTMs) * 0.8 + Double(ms) * 0.2).rounded())
        if metricsValue.baseRTTMs == 0 || ms < metricsValue.baseRTTMs {
            metricsValue.baseRTTMs = ms
        }
    }

    private func armConnectTimeout(generation: UInt64) {
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.connectTimeoutNs)
            guard !Task.isCancelled, let self else { return }
            let shouldFinish = self.locked {
                self.operationGeneration == generation
                    && (self.phaseValue == .connectRTT || self.phaseValue == .connectBandwidth)
            }
            if shouldFinish {
                RDPLog.rdp.info("AutoDetect: connect-time timed out")
                self.finishConnectTime(publish: true)
            }
        }
        let oldTask = locked {
            let oldTask = timeoutTask
            timeoutTask = task
            return oldTask
        }
        oldTask?.cancel()
    }

    private func finishConnectTime(publish: Bool) {
        let action: (shouldPublish: Bool, onFinished: (() -> Void)?)? = locked {
            guard !connectTimeFinished,
                  phaseValue == .connectRTT || phaseValue == .connectBandwidth
            else { return nil }
            connectTimeFinished = true
            phaseValue = .complete
            pendingRTTSequence = nil
            pendingBWSequence = nil
            rttStartedAt = nil
            return (
                publish && (metricsValue.hasRTT || metricsValue.hasBandwidth),
                onConnectTimeFinishedHandler
            )
        }
        guard let action else { return }
        cancelConnectTimeout()
        if action.shouldPublish { publishNetCharResult() }
        action.onFinished?()
    }

    private func cancelConnectTimeout() {
        let task = locked {
            let task = timeoutTask
            timeoutTask = nil
            return task
        }
        task?.cancel()
    }

    private func publishNetCharResult() {
        let result: (pdu: [UInt8], metrics: Metrics)? = locked {
            guard metricsValue.hasRTT || metricsValue.hasBandwidth else { return nil }
            let sequence = nextSequenceLocked()
            lastResultSequence = sequence
            let base = metricsValue.baseRTTMs > 0
                ? metricsValue.baseRTTMs
                : metricsValue.averageRTTMs
            let average = metricsValue.averageRTTMs > 0
                ? metricsValue.averageRTTMs
                : base
            return (
                AutoDetectPDU.encodeNetCharResult(
                    sequenceNumber: sequence,
                    baseRTTMs: base,
                    bandwidthKbps: metricsValue.bandwidthKbps,
                    averageRTTMs: average
                ),
                metricsValue
            )
        }
        guard let result else { return }
        send(result.pdu)
        notifyMetrics(result.metrics)
    }
}
