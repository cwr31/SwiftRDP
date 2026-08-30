import Foundation

/// The queue-depth field in FRAME_ACK is a protocol state, not an empty/non-empty
/// boolean. Zero means unavailable and 0xFFFFFFFF suspends acknowledgements.
public enum ClientQueueFeedback: Sendable, Equatable {
    case unavailable
    case queued(bytes: Int)
    case suspended

    public var bytes: Int? {
        switch self {
        case .unavailable, .suspended: return nil
        case .queued(let bytes): return max(bytes, 0)
        }
    }
}

public enum VideoLinkState: String, Sendable, Equatable {
    case healthy
    case probing
    case congested
}

public enum VideoPressureSource: String, Sendable, Equatable {
    case none
    case network
    case serverQueue
    case clientQueue
    case decoder
    case encoder
}

public struct VideoQualityStatus: Sendable, Equatable {
    public let state: VideoLinkState
    public let linkState: VideoLinkState
    public let pressureSource: VideoPressureSource
    public let score: Double
    public let networkPressure: Double
    public let clientPressure: Double
    public let encoderPressure: Double
    public let serverQueueBytes: Int
    public let serverQueueDelayMs: Double
    public let clientQueue: ClientQueueFeedback
    public let clientQueueDelayMs: Double?
    public let clientRenderMs: Double
    public let ackExcessDelayMs: Double
    public let targetFPS: Int
    public let targetBitrate: Int

    public static let empty = VideoQualityStatus(
        state: .healthy,
        linkState: .healthy,
        pressureSource: .none,
        score: 0.5,
        networkPressure: 0,
        clientPressure: 0,
        encoderPressure: 0,
        serverQueueBytes: 0,
        serverQueueDelayMs: 0,
        clientQueue: .unavailable,
        clientQueueDelayMs: nil,
        clientRenderMs: 0,
        ackExcessDelayMs: 0,
        targetFPS: 0,
        targetBitrate: 0
    )
}

/// Adaptive video controller driven by acknowledged throughput, excess ACK delay,
/// client decode pressure, and server encode pressure.
public final class VideoTargetController: @unchecked Sendable {
    private let lock = NSRecursiveLock()

    private var configuredBitrateValue: Int
    private var configuredFPSValue: Int
    private var targetBitrateValue: Int
    private var targetFPSValue: Int
    private var adaptationPriorityValue: VideoAdaptationPriority

    private var networkBitrateCap: Int
    private var networkFPSCap: Int
    private var encoderFPSCap: Int
    private var decoderFPSCap: Int

    private var stallRecoveryModeValue = false
    private var bitrateReducedValue = false
    private var consecutiveBackpressureTimeoutsValue = 0
    private var lastClientQueueFeedbackValue: ClientQueueFeedback = .unavailable
    private var lastClientQueueDelayMsValue: Double?
    private var lastServerQueueBytesValue = 0
    private var lastServerQueueDelayMsValue = 0.0
    private var lastClientRenderMsValue = 0.0
    private var lastClientRenderAtValue: Date?
    private var lastReportedBitrateValue = 0
    private var linkQualityScoreValue = 0.5
    private var networkPressureValue = 0.0
    private var clientPressureValue = 0.0
    private var encoderPressureValue = 0.0
    private var pressureSourceValue: VideoPressureSource = .none

    private var linkState: VideoLinkState = .healthy
    private var baseAckLatencyMs: Double?
    private var currentExcessAckDelayMs = 0.0
    private var excessAckDelayEmaMs = 0.0
    private var networkExcessAckDelayEmaMs = 0.0
    private var acknowledgedBitrateEmaBps = 0.0
    private var networkCapacityEmaBps = 0.0
    private var acknowledgedFrameBytesEma = 0.0
    private var detectedBandwidthBps = 0.0
    private var acknowledgedBitrateAt: Date?
    private var networkCapacityAt: Date?
    private var detectedBandwidthAt: Date?
    private var outputBitrateEmaBps = 0.0
    private var outputWindowStartedAt: Date?
    private var outputWindowBytes = 0
    private var encodeLatenciesMs: [Double] = []
    private var ackLatenciesMs: [Double] = []
    private var encodeLimited = false
    private var encodePressureStreak = 0
    private var decoderLimited = false
    private var acknowledgedBitrateSampleCount = 0

    private var networkPressureSinceValue: Date?
    private var networkHealthySinceValue: Date?
    private var clientPressureSinceValue: Date?
    private var decoderHealthySinceValue: Date?
    private var encodePressureSinceValue: Date?
    private var encodeHealthySinceValue: Date?
    private var lastAdaptationAtValue: Date?

    private var lastPerfSummary: Date?
    private var captureFramesSinceSummary = 0
    private var framesSinceSummary = 0
    private var lastCaptureFPSValue = 0.0
    private var lastWireFPSValue = 0.0
    private var lastClientDecodedFPSValue = 0.0
    private var bytesSinceSummary = 0
    private var encodeMsSinceSummary = 0.0
    private var postEncodeMsSinceSummary = 0.0
    private var prepMsSinceSummary = 0.0
    private var captureAgeMsSinceSummary = 0.0
    private var clientDecodedFramesSinceSummary = 0
    private var lastClientDecodedTotal: UInt32?
    private var idrSinceSummary = 0
    private var encodeDropsSinceSummary = 0
    private var lastServerUnacked = 0
    private var lastAckWindow = 0

    private var rfxAdaptiveModeValue = false
    private var rfxPendingSkip = false
    private var rfxOverloadStreak = 0

    public static let maxFPS = 60
    public static let minAdaptiveFPS = 5
    public static let minAdaptiveBitrate = 1_000_000
    public static let serverQueueBudgetMs = 100.0
    public static let serverQueueResumeMs = 40.0
    public static let serverQueueLimitMs = 250.0
    public static let pressureConfirmationInterval: TimeInterval = 0.5
    public static let recoveryDwellInterval: TimeInterval = 1.0
    public static let adaptationCooldown: TimeInterval = 0.5
    public static let networkDelayBudgetFloorMs = 25.0
    private static let encodePressureSampleWindow = 16
    public static let encodePressureBudgetRatio = 0.85
    public static let encodeSustainableFPSRatio = 0.90
    public static let networkBitrateDecreaseFactor = 0.85
    public static let networkBitrateRecoveryFactor = 1.25
    private static let minimumAcknowledgedBytes = 4 * 1024
    private static let minimumAcknowledgedBitrateSamples = 3

    public init(
        bitrate: Int = ServerConfig.defaultVideoBitrate,
        fps: Int = 60,
        adaptationPriority: VideoAdaptationPriority = .qualityFirst
    ) {
        let resolvedBitrate = ServerConfig.normalizedVideoBitrate(bitrate)
        let resolvedFPS = min(Self.maxFPS, max(fps, 1))
        configuredBitrateValue = resolvedBitrate
        configuredFPSValue = resolvedFPS
        targetBitrateValue = resolvedBitrate
        targetFPSValue = resolvedFPS
        adaptationPriorityValue = adaptationPriority
        networkBitrateCap = resolvedBitrate
        networkFPSCap = resolvedFPS
        encoderFPSCap = resolvedFPS
        decoderFPSCap = resolvedFPS
    }

    public var configuredBitrate: Int { locked { configuredBitrateValue } }
    public var configuredFPS: Int { locked { configuredFPSValue } }
    public var targetBitrate: Int { locked { targetBitrateValue } }
    public var targetFPS: Int { locked { targetFPSValue } }
    public var stallRecoveryMode: Bool { locked { stallRecoveryModeValue } }
    public var bitrateReduced: Bool { locked { bitrateReducedValue } }
    public var consecutiveBackpressureTimeouts: Int { locked { consecutiveBackpressureTimeoutsValue } }
    public var clientQueueFeedback: ClientQueueFeedback { locked { lastClientQueueFeedbackValue } }
    public var lastClientQueueDelayMs: Double? { locked { lastClientQueueDelayMsValue } }
    public var lastServerQueueBytes: Int { locked { lastServerQueueBytesValue } }
    public var lastServerQueueDelayMs: Double { locked { lastServerQueueDelayMsValue } }
    /// Independent estimate of the egress rate used to turn server queue bytes
    /// into time. The target bitrate is a quality goal, not a socket drain rate.
    public var serverQueueDrainBitrate: Int {
        locked {
            max(
                Int(estimatedServerDrainBitrateLocked(now: Date()).rounded()),
                Self.minAdaptiveBitrate
            )
        }
    }
    public var lastClientRenderMs: Double { locked { lastClientRenderMsValue } }
    public var lastReportedBitrate: Int { locked { lastReportedBitrateValue } }
    public var linkQualityScore: Double { locked { linkQualityScoreValue } }
    public var adaptationPriority: VideoAdaptationPriority { locked { adaptationPriorityValue } }
    public var rfxAdaptiveMode: Bool { locked { rfxAdaptiveModeValue } }

    public var isHealthyLink: Bool {
        locked { linkState == .healthy && !stallRecoveryModeValue }
    }

    /// Returns the number of frames needed to keep the measured path's BDP in
    /// flight, bounded by the client's advertised ceiling.
    public func recommendedFrameAcknowledgementWindow(clientCeiling: Int) -> Int {
        locked {
            let ceiling = max(clientCeiling, 1)
            let fps = Double(max(targetFPSValue, 1))
            let targetFrameBytes = Double(max(targetBitrateValue, Self.minAdaptiveBitrate))
                / fps / 8
            let frameBytes = max(targetFrameBytes * 0.75, acknowledgedFrameBytesEma)
            let rttMs = max(
                baseAckLatencyMs ?? (1_000 / fps),
                1_000 / fps
            )
            let now = Date()
            let capacityIsFresh = networkCapacityEmaBps > 0
                && networkCapacityAt.map {
                    now >= $0 && now.timeIntervalSince($0) <= 5
                } == true
            let capacity = capacityIsFresh
                ? networkCapacityEmaBps
                : Double(max(targetBitrateValue, Self.minAdaptiveBitrate))
            let bdpBytes = capacity * rttMs / 8_000
            var window = max(1, Int(ceil(bdpBytes / max(frameBytes, 1))))
            if case .queued(let queueBytes) = lastClientQueueFeedbackValue, queueBytes > 0 {
                let queueFactor = bdpBytes / (bdpBytes + Double(queueBytes))
                window = max(1, Int(ceil(Double(window) * queueFactor)))
            }
            let queuePressure: Bool
            switch lastClientQueueFeedbackValue {
            case .queued(let bytes): queuePressure = bytes > 0
            case .unavailable, .suspended: queuePressure = false
            }
            let severeAckPressure = networkExcessAckDelayEmaMs > rttMs * 1.5
            let safeFloor = !stallRecoveryModeValue && !queuePressure && !severeAckPressure
                ? min(2, ceiling)
                : 1
            return min(max(window, safeFloor), ceiling)
        }
    }

    public func updateConfiguredBitrate(_ bps: Int) {
        locked {
            let previous = configuredBitrateValue
            configuredBitrateValue = ServerConfig.normalizedVideoBitrate(bps)
            if configuredBitrateValue <= previous {
                networkBitrateCap = min(networkBitrateCap, configuredBitrateValue)
                recomputeTargetsLocked()
            } else {
                if networkBitrateCap >= previous {
                    networkBitrateCap = previous
                    linkState = .probing
                }
                recomputeTargetsLocked()
            }
            RDPLog.rdp.info(
                "VideoTargetController: configured bitrate -> \(self.configuredBitrateValue) " +
                "(target=\(self.targetBitrateValue))"
            )
        }
    }

    public func updateConfiguredFPS(_ fps: Int) {
        locked {
            let previous = configuredFPSValue
            configuredFPSValue = min(Self.maxFPS, max(fps, 1))
            if configuredFPSValue <= previous {
                networkFPSCap = min(networkFPSCap, configuredFPSValue)
                encoderFPSCap = min(encoderFPSCap, configuredFPSValue)
                decoderFPSCap = min(decoderFPSCap, configuredFPSValue)
                recomputeTargetsLocked()
            } else {
                if networkFPSCap >= previous {
                    networkFPSCap = previous
                    linkState = .probing
                }
                if encoderFPSCap >= previous {
                    encoderFPSCap = previous
                    encodeLimited = true
                }
                if decoderFPSCap >= previous {
                    decoderFPSCap = configuredFPSValue
                }
                recomputeTargetsLocked()
            }
            RDPLog.rdp.info(
                "VideoTargetController: configured FPS -> \(self.configuredFPSValue) " +
                "(target=\(self.targetFPSValue))"
            )
        }
    }

    public func updateAdaptationPriority(_ priority: VideoAdaptationPriority) {
        locked { adaptationPriorityValue = priority }
    }

    /// Records a frame published by the capture producer for telemetry.
    public func noteCaptureFrame(now: Date = Date()) {
        locked {
            captureFramesSinceSummary += 1
            logSummaryIfNeededLocked(now: now)
        }
    }

    public func noteEncodedFrame(
        bytes: Int,
        fps: Int,
        encodeMs: Double = 0,
        postEncodeMs: Double = 0,
        prepMs: Double = 0,
        captureAgeMs: Double = 0,
        isIDR: Bool = false,
        serverUnacked: Int? = nil,
        ackWindow: Int? = nil,
        now: Date = Date()
    ) {
        locked {
            updateOutputBitrateLocked(bytes: bytes, now: now)
            if let serverUnacked { lastServerUnacked = max(serverUnacked, 0) }
            if let ackWindow { lastAckWindow = max(ackWindow, 0) }
            if encodeMs > 0, !isIDR {
                encodeLatenciesMs.append(encodeMs)
                if encodeLatenciesMs.count > Self.encodePressureSampleWindow {
                    encodeLatenciesMs.removeFirst()
                }
            }
            framesSinceSummary += 1
            bytesSinceSummary += max(bytes, 0)
            encodeMsSinceSummary += max(encodeMs, 0)
            postEncodeMsSinceSummary += max(postEncodeMs, 0)
            prepMsSinceSummary += max(prepMs, 0)
            captureAgeMsSinceSummary += max(captureAgeMs, 0)
            if isIDR { idrSinceSummary += 1 }
            logSummaryIfNeededLocked(now: now)
            if encodePressureMsLocked() != nil {
                encodeHealthySinceValue = nil
            } else {
                encodePressureStreak = 0
                encodePressureSinceValue = nil
                considerEncodeRecoveryLocked(now: now)
            }
        }
    }

    /// Records the cumulative frame count reported by RDPGFX FRAME_ACK.
    /// The count is a client decode signal, not a server submission estimate.
    public func noteClientDecodedFrame(
        totalFramesDecoded: UInt32,
        now: Date = Date()
    ) {
        locked {
            if let previous = lastClientDecodedTotal {
                let delta = totalFramesDecoded &- previous
                if delta < 1_000_000 {
                    clientDecodedFramesSinceSummary += Int(delta)
                }
            }
            lastClientDecodedTotal = totalFramesDecoded
            logSummaryIfNeededLocked(now: now)
        }
    }

    /// Records a VideoToolbox `frameDropped` result for diagnostics. A single
    /// drop is not enough evidence to change the steady-state target.
    public func noteEncodeDrop() {
        locked {
            encodeDropsSinceSummary += 1
        }
    }

    public func noteFrameAck(
        clientQueue: ClientQueueFeedback,
        ackLatencyMs: Double,
        unacked: Int,
        acknowledgedBytes: Int = 0,
        acknowledgedFrames: Int = 1,
        acknowledgementIntervalMs: Double = 0,
        now: Date = Date()
    ) {
        locked {
            lastClientQueueFeedbackValue = Self.normalizedClientQueueFeedback(clientQueue)
            let windowBacklogged = lastAckWindow > 0 && unacked >= max(1, lastAckWindow - 1)
            updateAckDelayLocked(ackLatencyMs)
            let pathBacklogged = windowBacklogged
                || networkExcessAckDelayEmaMs > networkDelayBudgetMsLocked() * 0.5
                || lastServerQueueDelayMsValue > 0
            let deliveryRate = updateAcknowledgedBitrateLocked(
                bytes: acknowledgedBytes,
                intervalMs: acknowledgementIntervalMs,
                now: now
            )
            if deliveryRate > 0 {
                acknowledgedBitrateSampleCount = min(
                    acknowledgedBitrateSampleCount + 1,
                    Self.minimumAcknowledgedBitrateSamples
                )
                if pathBacklogged,
                   acknowledgedBitrateSampleCount >= Self.minimumAcknowledgedBitrateSamples {
                    networkCapacityEmaBps = networkCapacityEmaBps == 0
                        ? deliveryRate
                        : networkCapacityEmaBps * 0.75 + deliveryRate * 0.25
                    networkCapacityAt = now
                }
            }
            updateAcknowledgedFrameSizeLocked(
                bytes: acknowledgedBytes,
                frames: acknowledgedFrames
            )
            let drainRate = hasFreshAcknowledgedBitrateLocked(now: now)
                ? acknowledgedBitrateEmaBps
                : 0
            lastClientQueueDelayMsValue = clientQueueDelayLocked(drainBitrateBps: drainRate)
            updateNetworkExcessAckDelayLocked(now: now)
            refreshFeedbackPressureLocked(now: now)
            considerNetworkStateLocked(now: now)
            considerClientPressureLocked(now: now)
        }
    }

    public func noteClientQueueSuspended() {
        locked {
            lastClientQueueFeedbackValue = .suspended
            lastClientQueueDelayMsValue = nil
            refreshFeedbackPressureLocked(now: Date())
        }
    }

    public func noteServerQueue(bytes: Int, now: Date = Date()) {
        locked {
            lastServerQueueBytesValue = max(bytes, 0)
            lastServerQueueDelayMsValue = Double(lastServerQueueBytesValue) * 8_000
                / estimatedServerDrainBitrateLocked(now: now)
            refreshFeedbackPressureLocked(now: now)
            considerNetworkStateLocked(now: now)
        }
    }

    public func noteClientRenderTiming(
        commandDecodeMs: Int,
        renderMs: Int,
        now: Date = Date()
    ) {
        locked {
            lastClientRenderMsValue = Double(max(commandDecodeMs, 0) + max(renderMs, 0))
            lastClientRenderAtValue = now
            refreshFeedbackPressureLocked(now: now)
            considerClientPressureLocked(now: now)
        }
    }

    /// Records a completed output-stall recovery attempt. Quality caps are only
    /// applied after repeated stalls; the first attempt only clears stale frames.
    @discardableResult
    public func noteBackpressureTimeout(unackedWas: Int) -> Bool {
        locked {
            consecutiveBackpressureTimeoutsValue += 1
            guard consecutiveBackpressureTimeoutsValue >= 2 else { return false }
            let wasStallRecovery = stallRecoveryModeValue
            enterStallRecoveryModeLocked()
            RDPLog.rdp.info(
                "GFX: output stall recovery, reset unacked=\(unackedWas), " +
                "active=\(!wasStallRecovery)"
            )
            return !wasStallRecovery
        }
    }

    public func exitStallRecoveryIfPossible() {
        locked {
            guard stallRecoveryModeValue else { return }
            stallRecoveryModeValue = false
            consecutiveBackpressureTimeoutsValue = 0
            networkPressureSinceValue = nil
            networkHealthySinceValue = nil
            clientPressureSinceValue = nil
            RDPLog.rdp.info("VideoTargetController: output stall recovery cleared; awaiting ACK feedback")
        }
    }

    public func noteEncodePressure(now: Date = Date()) {
        locked {
            guard !stallRecoveryModeValue,
                  let encodeMs = encodePressureMsLocked()
            else {
                encodePressureStreak = 0
                encodePressureSinceValue = nil
                return
            }

            if encodePressureSinceValue == nil {
                encodePressureSinceValue = now
            }
            guard now.timeIntervalSince(encodePressureSinceValue ?? now)
                >= Self.pressureConfirmationInterval,
                adaptationAllowedLocked(now: now)
            else {
                return
            }
            encodePressureStreak = 0
            let previousTargetFPS = targetFPSValue
            lowerFPSForEncodePressureLocked(encodeMs: encodeMs)
            lastAdaptationAtValue = now
            encodeLimited = true
            if targetFPSValue < previousTargetFPS {
                RDPLog.rdp.info(
                    "VideoTargetController: encode pressure -> \(self.targetFPSValue)fps / " +
                    "\(self.targetBitrateValue / 1_000_000)Mbps"
                )
            }
        }
    }

    /// Seeds RTT and a non-authoritative bandwidth estimate for queue timing.
    /// Auto-detect never caps the video target by itself.
    public func seedFromAutoDetect(
        bandwidthKbps: UInt32,
        rttMs: UInt32,
        now: Date = Date()
    ) {
        locked {
            guard !stallRecoveryModeValue else { return }
            if rttMs > 0 {
                baseAckLatencyMs = Double(rttMs)
                linkQualityScoreValue = Self.qualityFromRTT(Double(rttMs))
            }
            if bandwidthKbps > 0 {
                let measured = Double(bandwidthKbps) * 1_000
                detectedBandwidthBps = detectedBandwidthBps == 0
                    ? measured
                    : detectedBandwidthBps * 0.75 + measured * 0.25
                detectedBandwidthAt = now
            }
        }
    }

    private func resetFeedbackLocked() {
        stallRecoveryModeValue = false
        consecutiveBackpressureTimeoutsValue = 0
        lastClientQueueFeedbackValue = .unavailable
        lastClientQueueDelayMsValue = nil
        lastServerQueueBytesValue = 0
        lastServerQueueDelayMsValue = 0
        lastClientRenderMsValue = 0
        lastClientRenderAtValue = nil
        lastReportedBitrateValue = 0
        linkQualityScoreValue = 0.5
        networkPressureValue = 0
        clientPressureValue = 0
        encoderPressureValue = 0
        pressureSourceValue = .none
        baseAckLatencyMs = nil
        excessAckDelayEmaMs = 0
        currentExcessAckDelayMs = 0
        networkExcessAckDelayEmaMs = 0
        acknowledgedBitrateEmaBps = 0
        networkCapacityEmaBps = 0
        acknowledgedFrameBytesEma = 0
        detectedBandwidthBps = 0
        acknowledgedBitrateAt = nil
        networkCapacityAt = nil
        detectedBandwidthAt = nil
        outputBitrateEmaBps = 0
        outputWindowStartedAt = nil
        outputWindowBytes = 0
        encodeLatenciesMs.removeAll(keepingCapacity: true)
        ackLatenciesMs.removeAll(keepingCapacity: true)
        encodeLimited = false
        encodePressureStreak = 0
        decoderLimited = false
        acknowledgedBitrateSampleCount = 0
        networkPressureSinceValue = nil
        networkHealthySinceValue = nil
        clientPressureSinceValue = nil
        decoderHealthySinceValue = nil
        encodePressureSinceValue = nil
        encodeHealthySinceValue = nil
        lastAdaptationAtValue = nil
        rfxPendingSkip = false
        rfxOverloadStreak = 0
        lastPerfSummary = nil
        captureFramesSinceSummary = 0
        framesSinceSummary = 0
        lastCaptureFPSValue = 0
        lastWireFPSValue = 0
        lastClientDecodedFPSValue = 0
        bytesSinceSummary = 0
        encodeMsSinceSummary = 0
        postEncodeMsSinceSummary = 0
        prepMsSinceSummary = 0
        captureAgeMsSinceSummary = 0
        clientDecodedFramesSinceSummary = 0
        lastClientDecodedTotal = nil
        idrSinceSummary = 0
        encodeDropsSinceSummary = 0
        lastServerUnacked = 0
        lastAckWindow = 0
    }

    public func resetSession() {
        locked {
            resetFeedbackLocked()
            resetAdaptiveTargetsLocked()
        }
    }

    /// Reset per-channel feedback without restoring configured network targets.
    /// Recreating Graphics does not mean that the underlying RDP path recovered.
    public func resetGraphicsChannel() {
        locked {
            let preservedNetworkBitrate = networkBitrateCap
            let preservedNetworkFPS = networkFPSCap
            let preservedEncoderFPS = encoderFPSCap
            let preservedDecoderFPS = decoderFPSCap
            let preservedBandwidth = detectedBandwidthBps
            let preservedBandwidthAt = detectedBandwidthAt
            let preservedCapacity = networkCapacityEmaBps
            let preservedCapacityAt = networkCapacityAt
            let preservedFrameBytes = acknowledgedFrameBytesEma
            let preservedBaseAck = baseAckLatencyMs
            let preservedLinkState = linkState
            let preservedLinkQuality = linkQualityScoreValue

            resetFeedbackLocked()
            networkBitrateCap = min(preservedNetworkBitrate, configuredBitrateValue)
            networkFPSCap = min(preservedNetworkFPS, configuredFPSValue)
            encoderFPSCap = min(preservedEncoderFPS, configuredFPSValue)
            decoderFPSCap = min(preservedDecoderFPS, configuredFPSValue)
            detectedBandwidthBps = preservedBandwidth
            detectedBandwidthAt = preservedBandwidthAt
            networkCapacityEmaBps = preservedCapacity
            networkCapacityAt = preservedCapacityAt
            acknowledgedFrameBytesEma = preservedFrameBytes
            baseAckLatencyMs = preservedBaseAck
            linkState = preservedLinkState
            linkQualityScoreValue = preservedLinkQuality
            encodeLimited = encoderFPSCap < configuredFPSValue
            decoderLimited = decoderFPSCap < configuredFPSValue

            recomputeTargetsLocked()
        }
    }

    public func setRFXAdaptiveMode(_ enabled: Bool) {
        locked {
            rfxAdaptiveModeValue = enabled
            rfxPendingSkip = false
            rfxOverloadStreak = 0
        }
    }

    public func consumeRFXSkipFrame() -> Bool {
        locked {
            guard rfxAdaptiveModeValue, rfxPendingSkip else { return false }
            rfxPendingSkip = false
            return true
        }
    }

    public func noteRFXEncodeMs(_ encodeMs: Double, now: Date = Date()) {
        locked {
            guard rfxAdaptiveModeValue, !stallRecoveryModeValue else { return }
            let interval = 1000 / Double(max(targetFPSValue, 1))
            guard encodeMs > interval * 0.85 else {
                rfxOverloadStreak = 0
                return
            }
            rfxPendingSkip = true
            rfxOverloadStreak += 1
            guard rfxOverloadStreak >= 2,
                  adaptationAllowedLocked(now: now)
            else { return }
            rfxOverloadStreak = 0
            lowerFPSForEncodePressureLocked(encodeMs: encodeMs)
            lastAdaptationAtValue = now
        }
    }

    private func considerNetworkStateLocked(
        now: Date
    ) {
        guard !stallRecoveryModeValue else { return }

        let rttMs = estimatedRTTMsLocked()
        // A full application ACK window is expected during steady streaming.
        // It limits admission, but is not network congestion by itself.
        let pathPressure = networkExcessAckDelayEmaMs / networkDelayBudgetMsLocked()
        let serverQueuePressure = lastServerQueueDelayMsValue / Self.serverQueueBudgetMs
        let pressure = max(pathPressure, serverQueuePressure)

        if pressure >= 1 {
            networkHealthySinceValue = nil
            if networkPressureSinceValue == nil {
                networkPressureSinceValue = now
            }
            linkState = .probing
            guard now.timeIntervalSince(networkPressureSinceValue ?? now)
                >= Self.pressureConfirmationInterval,
                adaptationAllowedLocked(now: now)
            else { return }

            linkState = .congested
            lowerNetworkLoadLocked()
            lastAdaptationAtValue = now
            return
        }

        networkPressureSinceValue = nil
        let healthy = pressure < 0.25
            && networkExcessAckDelayEmaMs <= networkDelayBudgetMsLocked() * 0.5
        guard healthy else {
            networkHealthySinceValue = nil
            return
        }

        guard networkBitrateCap < configuredBitrateValue
            || networkFPSCap < configuredFPSValue else {
            linkState = .healthy
            networkHealthySinceValue = nil
            return
        }

        if networkHealthySinceValue == nil {
            networkHealthySinceValue = now
        }
        linkState = .probing
        guard now.timeIntervalSince(networkHealthySinceValue ?? now)
            >= Self.recoveryDwellInterval,
            adaptationAllowedLocked(now: now)
        else { return }

        recoverNetworkOneStepLocked()
        lastAdaptationAtValue = now
        networkHealthySinceValue = now
        if networkFPSCap >= configuredFPSValue,
           networkBitrateCap >= configuredBitrateValue {
            linkState = .healthy
        }
        RDPLog.rdp.debug(
            "VideoTargetController: feedback recovery -> " +
            "\(self.targetFPSValue)fps / \(self.targetBitrateValue / 1_000_000)Mbps " +
            "rtt=\(Int(rttMs))ms"
        )
    }

    private func lowerNetworkLoadLocked() {
        switch adaptationPriorityValue {
        case .qualityFirst:
            if networkFPSCap > Self.minAdaptiveFPS {
                networkFPSCap = max(
                    Self.minAdaptiveFPS,
                    networkFPSCap - max(1, networkFPSCap / 5)
                )
            } else {
                lowerBitrateFromFeedbackLocked(floor: Self.minAdaptiveBitrate)
            }
        case .fpsFirst:
            if networkBitrateCap > Self.minAdaptiveBitrate {
                lowerBitrateFromFeedbackLocked(floor: Self.minAdaptiveBitrate)
            } else {
                networkFPSCap = max(
                    Self.minAdaptiveFPS,
                    networkFPSCap - max(1, networkFPSCap / 5)
                )
            }
        }
        recomputeTargetsLocked()
        RDPLog.rdp.info(
            "VideoTargetController: congestion networkExcess=\(Int(self.networkExcessAckDelayEmaMs))ms " +
            "serverQueue=\(Int(self.lastServerQueueDelayMsValue))ms -> " +
            "\(self.targetFPSValue)fps / \(self.targetBitrateValue / 1_000_000)Mbps"
        )
    }

    private func lowerBitrateFromFeedbackLocked(floor: Int) {
        let next = Int(Double(networkBitrateCap) * Self.networkBitrateDecreaseFactor)
        networkBitrateCap = max(floor, next)
    }

    private func recoverNetworkOneStepLocked() {
        switch adaptationPriorityValue {
        case .qualityFirst:
            if networkBitrateCap < configuredBitrateValue {
                raiseNetworkBitrateOneStepLocked()
            } else if networkFPSCap < configuredFPSValue {
                networkFPSCap = min(
                    configuredFPSValue,
                    networkFPSCap + max(1, configuredFPSValue / 12)
                )
            }
        case .fpsFirst:
            if networkFPSCap < configuredFPSValue {
                networkFPSCap = min(
                    configuredFPSValue,
                    networkFPSCap + max(1, configuredFPSValue / 12)
                )
            } else if networkBitrateCap < configuredBitrateValue {
                raiseNetworkBitrateOneStepLocked()
            }
        }
        recomputeTargetsLocked()
    }

    private func raiseNetworkBitrateOneStepLocked() {
        networkBitrateCap = min(
            configuredBitrateValue,
            max(
                networkBitrateCap + 1,
                Int(Double(networkBitrateCap) * Self.networkBitrateRecoveryFactor)
            )
        )
    }

    private func lowerDecoderLoadLocked() {
        decoderFPSCap = max(
            Self.minAdaptiveFPS,
            Int((Double(decoderFPSCap) * 0.8).rounded(.down))
        )
        recomputeTargetsLocked()
        RDPLog.rdp.info(
            "VideoTargetController: decoder pressure render=\(Int(lastClientRenderMsValue))ms -> " +
            "\(targetFPSValue)fps"
        )
    }

    private func considerClientPressureLocked(now: Date) {
        guard !stallRecoveryModeValue else { return }

        if clientPressureValue >= 1 {
            decoderHealthySinceValue = nil
            if clientPressureSinceValue == nil {
                clientPressureSinceValue = now
            }
            guard now.timeIntervalSince(clientPressureSinceValue ?? now)
                >= Self.pressureConfirmationInterval,
                adaptationAllowedLocked(now: now)
            else { return }
            lowerDecoderLoadLocked()
            lastAdaptationAtValue = now
            return
        }

        clientPressureSinceValue = nil
        guard decoderLimited, linkState != .congested else {
            decoderHealthySinceValue = nil
            return
        }
        if decoderHealthySinceValue == nil {
            decoderHealthySinceValue = now
        }
        guard now.timeIntervalSince(decoderHealthySinceValue ?? now)
            >= Self.recoveryDwellInterval,
            adaptationAllowedLocked(now: now)
        else { return }
        decoderFPSCap = min(
            configuredFPSValue,
            decoderFPSCap + max(1, configuredFPSValue / 12)
        )
        decoderLimited = decoderFPSCap < configuredFPSValue
        recomputeTargetsLocked()
        lastAdaptationAtValue = now
        decoderHealthySinceValue = now
    }

    private func lowerFPSForEncodePressureLocked(encodeMs: Double) {
        let sustainable = Int(
            (1000 / max(encodeMs, 1) * Self.encodeSustainableFPSRatio).rounded(.down)
        )
        encoderFPSCap = max(
            Self.minAdaptiveFPS,
            min(encoderFPSCap, configuredFPSValue, sustainable)
        )
        encodeLimited = true
        recomputeTargetsLocked()
    }

    private func encodePressureMsLocked() -> Double? {
        guard encodeLatenciesMs.count >= encodePressureSampleCountLocked() else {
            return nil
        }
        let encodeMs = recentP95EncodeMsLocked()
        let budget = 1000 / Double(max(targetFPSValue, 1))
        guard encodeMs > budget * Self.encodePressureBudgetRatio else {
            return nil
        }
        return encodeMs
    }

    private func considerEncodeRecoveryLocked(now: Date) {
        guard !stallRecoveryModeValue, encodeLimited,
              linkState != .congested else {
            encodeHealthySinceValue = nil
            return
        }
        guard encodeLatenciesMs.count >= encodePressureSampleCountLocked() else { return }
        let encodeMs = recentP95EncodeMsLocked()
        let candidate = min(
            configuredFPSValue,
            encoderFPSCap + max(1, configuredFPSValue / 12)
        )
        let candidateBudget = 1000 / Double(max(candidate, 1))
        guard encodeMs > 0, encodeMs <= candidateBudget * Self.encodePressureBudgetRatio else {
            encodeHealthySinceValue = nil
            return
        }
        if encodeHealthySinceValue == nil {
            encodeHealthySinceValue = now
        }
        guard now.timeIntervalSince(encodeHealthySinceValue ?? now)
            >= Self.recoveryDwellInterval,
            adaptationAllowedLocked(now: now)
        else { return }
        encoderFPSCap = candidate
        encodeLimited = encoderFPSCap < configuredFPSValue
        recomputeTargetsLocked()
        lastAdaptationAtValue = now
        encodeHealthySinceValue = now
    }

    private func updateAckDelayLocked(_ latencyMs: Double) {
        let latency = max(latencyMs, 0)
        ackLatenciesMs.append(latency)
        if ackLatenciesMs.count > 64 { ackLatenciesMs.removeFirst() }
        let sortedBaseline = ackLatenciesMs.sorted()
        let baselineIndex = min(sortedBaseline.count - 1, sortedBaseline.count / 10)
        baseAckLatencyMs = sortedBaseline[baselineIndex]
        let excess = max(0, latency - (baseAckLatencyMs ?? latency))
        currentExcessAckDelayMs = excess
        excessAckDelayEmaMs = excessAckDelayEmaMs == 0
            ? excess
            : excessAckDelayEmaMs * 0.8 + excess * 0.2
    }

    private func updateNetworkExcessAckDelayLocked(now: Date) {
        let recentClientRender: Double
        if let renderedAt = lastClientRenderAtValue,
           now.timeIntervalSince(renderedAt) <= 1,
           now >= renderedAt {
            recentClientRender = lastClientRenderMsValue
        } else {
            recentClientRender = 0
        }
        let clientQueueDelay = lastClientQueueDelayMsValue ?? 0
        let excess = max(0, currentExcessAckDelayMs - recentClientRender - clientQueueDelay)
        networkExcessAckDelayEmaMs = networkExcessAckDelayEmaMs == 0
            ? excess
            : networkExcessAckDelayEmaMs * 0.8 + excess * 0.2
    }

    private func clientQueueDelayLocked(drainBitrateBps: Double) -> Double? {
        switch lastClientQueueFeedbackValue {
        case .unavailable, .suspended:
            return nil
        case .queued(let bytes):
            let bitrate = drainBitrateBps > 0
                ? drainBitrateBps
                : Double(max(targetBitrateValue, Self.minAdaptiveBitrate))
            return Self.queueDelayMs(queueBytes: max(bytes, 0), drainBitrateBps: bitrate)
        }
    }

    private func estimatedServerDrainBitrateLocked(now: Date) -> Double {
        let liveRates = [
            (networkCapacityEmaBps, networkCapacityAt),
            (acknowledgedBitrateEmaBps, acknowledgedBitrateAt),
        ]
        let freshRates = liveRates.compactMap { rate, updatedAt -> Double? in
            guard rate > 0,
                  let updatedAt,
                  now >= updatedAt,
                  now.timeIntervalSince(updatedAt) <= 5
            else { return nil }
            return rate
        }
        if let liveRate = freshRates.min() {
            return max(liveRate, Double(Self.minAdaptiveBitrate))
        }
        if let detectedBandwidthAt,
           now >= detectedBandwidthAt,
           now.timeIntervalSince(detectedBandwidthAt) <= 30,
           detectedBandwidthBps > 0 {
            return max(detectedBandwidthBps, Double(Self.minAdaptiveBitrate))
        }
        return Double(max(targetBitrateValue, Self.minAdaptiveBitrate))
    }

    private func hasFreshAcknowledgedBitrateLocked(now: Date) -> Bool {
        guard let acknowledgedBitrateAt,
              now >= acknowledgedBitrateAt,
              now.timeIntervalSince(acknowledgedBitrateAt) <= 5
        else { return false }
        return acknowledgedBitrateEmaBps > 0
    }

    private func refreshFeedbackPressureLocked(now: Date) {
        updateNetworkExcessAckDelayLocked(now: now)
        let rttMs = estimatedRTTMsLocked()
        let frameBudgetMs = 1_000 / Double(max(targetFPSValue, 1))
        // ACK-window occupancy is admission state, not a quality penalty.
        let pathPressure = networkExcessAckDelayEmaMs / networkDelayBudgetMsLocked()
        let serverQueuePressure = lastServerQueueDelayMsValue / Self.serverQueueBudgetMs
        networkPressureValue = max(pathPressure, serverQueuePressure)

        let clientQueuePressure = (lastClientQueueDelayMsValue ?? 0)
            / max(rttMs, frameBudgetMs * 2)
        let renderPressure = max(
            0,
            (lastClientRenderMsValue - frameBudgetMs) / max(frameBudgetMs, 1)
        )
        clientPressureValue = max(clientQueuePressure, renderPressure)

        let encodePressure = encodePressureMsLocked().map {
            max(0, $0 / max(frameBudgetMs, 1) - 1)
        } ?? 0
        encoderPressureValue = encodePressure

        let pressures: [(VideoPressureSource, Double)] = [
            (.network, pathPressure),
            (.serverQueue, serverQueuePressure),
            (.clientQueue, clientQueuePressure),
            (.decoder, renderPressure),
            (.encoder, encodePressure),
        ]
        let maximumPressure = pressures.map { $0.1 }.max() ?? 0
        pressureSourceValue = maximumPressure > 0
            ? (pressures.max { lhs, rhs in lhs.1 < rhs.1 }?.0 ?? .none)
            : .none
        let networkQuality = 1 - min(1, networkPressureValue)
        let clientQuality = 1 - min(1, clientPressureValue)
        let encoderQuality = 1 - min(1, encoderPressureValue)
        let unackedQuality = 1.0
        linkQualityScoreValue = min(networkQuality, clientQuality, encoderQuality, unackedQuality)
    }

    private func adaptationAllowedLocked(now: Date) -> Bool {
        guard let last = lastAdaptationAtValue else { return true }
        return now.timeIntervalSince(last) >= Self.adaptationCooldown
    }

    private func qualityStateLocked() -> VideoLinkState {
        let maximumPressure = max(networkPressureValue, clientPressureValue, encoderPressureValue)
        if linkState == .congested || maximumPressure >= 1 { return .congested }
        if linkState == .probing || maximumPressure >= 0.25 { return .probing }
        return .healthy
    }

    private static func normalizedClientQueueFeedback(
        _ feedback: ClientQueueFeedback
    ) -> ClientQueueFeedback {
        switch feedback {
        case .unavailable, .suspended:
            return feedback
        case .queued(let bytes):
            return .queued(bytes: max(bytes, 0))
        }
    }

    private func updateAcknowledgedBitrateLocked(
        bytes: Int,
        intervalMs: Double,
        now: Date
    ) -> Double {
        guard bytes >= Self.minimumAcknowledgedBytes, intervalMs > 0 else { return 0 }
        let instant = Double(bytes) * 8_000 / intervalMs
        acknowledgedBitrateEmaBps = acknowledgedBitrateEmaBps == 0
            ? instant
            : acknowledgedBitrateEmaBps * 0.75 + instant * 0.25
        acknowledgedBitrateAt = now
        return instant
    }

    private func updateAcknowledgedFrameSizeLocked(bytes: Int, frames: Int) {
        guard bytes > 0, frames > 0 else { return }
        let instant = Double(bytes) / Double(frames)
        acknowledgedFrameBytesEma = acknowledgedFrameBytesEma == 0
            ? instant
            : acknowledgedFrameBytesEma * 0.75 + instant * 0.25
    }

    private func updateOutputBitrateLocked(bytes: Int, now: Date) {
        outputWindowBytes += max(bytes, 0)
        guard let started = outputWindowStartedAt else {
            outputWindowStartedAt = now
            return
        }
        let elapsed = now.timeIntervalSince(started)
        guard elapsed >= 0.25 else { return }
        let instant = Double(outputWindowBytes) * 8 / elapsed
        outputBitrateEmaBps = outputBitrateEmaBps == 0
            ? instant
            : outputBitrateEmaBps * 0.75 + instant * 0.25
        lastReportedBitrateValue = Int(outputBitrateEmaBps.rounded())
        outputWindowBytes = 0
        outputWindowStartedAt = now
    }

    private func refreshDerivedQualityLocked() {
        bitrateReducedValue = targetBitrateValue < configuredBitrateValue
    }

    private func enterStallRecoveryModeLocked() {
        stallRecoveryModeValue = true
        linkState = .congested
        networkFPSCap = min(
            networkFPSCap,
            max(Self.minAdaptiveFPS, networkFPSCap / 2)
        )
        networkBitrateCap = min(
            networkBitrateCap,
            max(Self.minAdaptiveBitrate, networkBitrateCap / 2)
        )
        recomputeTargetsLocked()
    }

    private func resetAdaptiveTargetsLocked() {
        linkState = .healthy
        networkBitrateCap = configuredBitrateValue
        networkFPSCap = configuredFPSValue
        encoderFPSCap = configuredFPSValue
        decoderFPSCap = configuredFPSValue
        encodeLimited = false
        decoderLimited = false
        networkPressureSinceValue = nil
        networkHealthySinceValue = nil
        clientPressureSinceValue = nil
        decoderHealthySinceValue = nil
        encodePressureSinceValue = nil
        encodeHealthySinceValue = nil
        lastAdaptationAtValue = nil
        recomputeTargetsLocked()
    }

    private func recomputeTargetsLocked() {
        targetBitrateValue = min(
            configuredBitrateValue,
            max(Self.minAdaptiveBitrate, networkBitrateCap)
        )
        targetFPSValue = min(
            configuredFPSValue,
            max(Self.minAdaptiveFPS, min(networkFPSCap, encoderFPSCap, decoderFPSCap))
        )
        refreshDerivedQualityLocked()
    }

    private func encodePressureSampleCountLocked() -> Int {
        max(4, min(Self.encodePressureSampleWindow, configuredFPSValue / 4))
    }

    private func estimatedRTTMsLocked() -> Double {
        max(baseAckLatencyMs ?? (1_000 / Double(max(targetFPSValue, 1))), 1)
    }

    private func networkDelayBudgetMsLocked() -> Double {
        max(estimatedRTTMsLocked(), Self.networkDelayBudgetFloorMs)
    }

    private func estimatedFrameBytesLocked() -> Double {
        let configuredFrameBytes = Double(max(targetBitrateValue, Self.minAdaptiveBitrate))
            / Double(max(targetFPSValue, 1)) / 8
        return max(configuredFrameBytes * 0.75, acknowledgedFrameBytesEma, 1)
    }

    private func recentAverageEncodeMsLocked(sampleCount: Int = 16) -> Double {
        let samples = encodeLatenciesMs.suffix(min(sampleCount, encodeLatenciesMs.count))
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0, +) / Double(samples.count)
    }

    private func recentP95EncodeMsLocked(sampleCount: Int = 16) -> Double {
        let samples = encodeLatenciesMs
            .suffix(min(sampleCount, encodeLatenciesMs.count))
            .sorted()
        guard !samples.isEmpty else { return 0 }
        return samples[min(samples.count - 1, Int(Double(samples.count) * 0.95))]
    }

    private func logSummaryIfNeededLocked(now: Date) {
        guard let last = lastPerfSummary else {
            lastPerfSummary = now
            return
        }
        let elapsed = now.timeIntervalSince(last)
        guard elapsed >= 1 else { return }
        let count = Double(max(framesSinceSummary, 1))
        let captureFPS = Double(captureFramesSinceSummary) / elapsed
        let wireFPS = Double(framesSinceSummary) / elapsed
        let clientDecodedFPS = Double(clientDecodedFramesSinceSummary) / elapsed
        let p95EncodeMs = recentP95EncodeMsLocked()
        lastCaptureFPSValue = captureFPS
        lastWireFPSValue = wireFPS
        lastClientDecodedFPSValue = clientDecodedFPS
        let ackAverage = ackLatenciesMs.isEmpty ? 0 : ackLatenciesMs.reduce(0, +) / Double(ackLatenciesMs.count)
        let stateLabel: String
        switch linkState {
        case .healthy: stateLabel = "healthy"
        case .congested: stateLabel = "congested"
        case .probing: stateLabel = "probing"
        }
        let clientQueueLabel: String
        switch lastClientQueueFeedbackValue {
        case .unavailable: clientQueueLabel = "unavailable"
        case .suspended: clientQueueLabel = "suspended"
        case .queued(let bytes): clientQueueLabel = "\(bytes)B"
        }
        RDPLog.rdp.notice(String(
            format: "VideoStats: capture=%.1ffps submitted=%.1ffps decoded=%.1ffps target=%dfps " +
                "targetBitrate=%.1fMbps out=%.0fkbps " +
                "age=%.1fms prep=%.1fms enc=%.1fms p95Enc=%.1fms post=%.1fms " +
                "idr=%d drops=%d unacked=%d/%d " +
                "clientQ=%@ clientQueue=%.0fms serverQ=%dB serverQueue=%.0fms " +
                "render=%.0fms ack=%.0fms excess=%.0fms networkExcess=%.0fms " +
                "linkQ=%.2f state=%@ source=%@ pressure=%.2f/%.2f/%.2f " +
                "caps=%d/%d/%d stallRecovery=%@",
            captureFPS, wireFPS, clientDecodedFPS, targetFPSValue,
            Double(targetBitrateValue) / 1_000_000,
            Double(bytesSinceSummary) * 8 / elapsed / 1000,
            captureAgeMsSinceSummary / count,
            prepMsSinceSummary / count, encodeMsSinceSummary / count, p95EncodeMs,
            postEncodeMsSinceSummary / count,
            idrSinceSummary, encodeDropsSinceSummary, lastServerUnacked, lastAckWindow,
            clientQueueLabel, lastClientQueueDelayMsValue ?? 0,
            lastServerQueueBytesValue, lastServerQueueDelayMsValue,
            lastClientRenderMsValue, ackAverage, excessAckDelayEmaMs,
            networkExcessAckDelayEmaMs, linkQualityScoreValue,
            stateLabel, pressureSourceValue.rawValue,
            networkPressureValue, clientPressureValue, encoderPressureValue,
            networkFPSCap, encoderFPSCap, decoderFPSCap,
            stallRecoveryModeValue ? "yes" : "no"
        ))
        framesSinceSummary = 0
        captureFramesSinceSummary = 0
        bytesSinceSummary = 0
        encodeMsSinceSummary = 0
        postEncodeMsSinceSummary = 0
        prepMsSinceSummary = 0
        captureAgeMsSinceSummary = 0
        clientDecodedFramesSinceSummary = 0
        idrSinceSummary = 0
        encodeDropsSinceSummary = 0
        lastPerfSummary = now
    }

    public struct PerfSnapshot: Sendable {
        public var avgEncodeMs: Double
        public var avgAckRTTMs: Double
        public var p95AckRTTMs: Double
        public var sampleCount: Int
        public var captureFPS: Double
        public var wireFPS: Double
        public var clientDecodedFPS: Double
        public var targetFPS: Int
        public var targetBitrate: Int
        public var configuredBitrate: Int
        public var lastReportedBitrate: Int
        public var clientQueue: ClientQueueFeedback
        public var clientQueueDelayMs: Double
        public var serverQueueBytes: Int
        public var serverQueueDelayMs: Double
        public var clientRenderMs: Double
        public var stallRecoveryMode: Bool
        public var bitrateReduced: Bool
        public var linkQualityScore: Double
        public var linkState: VideoLinkState
        public var pressureSource: VideoPressureSource
        public var networkPressure: Double
        public var clientPressure: Double
        public var encoderPressure: Double
        public var quality: VideoQualityStatus
    }

    public var perfSnapshot: PerfSnapshot {
        locked {
            let sorted = ackLatenciesMs.sorted()
            let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            return PerfSnapshot(
                avgEncodeMs: recentAverageEncodeMsLocked(sampleCount: encodeLatenciesMs.count),
                avgAckRTTMs: sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count),
                p95AckRTTMs: p95,
                sampleCount: sorted.count,
                captureFPS: lastCaptureFPSValue,
                wireFPS: lastWireFPSValue,
                clientDecodedFPS: lastClientDecodedFPSValue,
                targetFPS: targetFPSValue,
                targetBitrate: targetBitrateValue,
                configuredBitrate: configuredBitrateValue,
                lastReportedBitrate: lastReportedBitrateValue,
                clientQueue: lastClientQueueFeedbackValue,
                clientQueueDelayMs: lastClientQueueDelayMsValue ?? 0,
                serverQueueBytes: lastServerQueueBytesValue,
                serverQueueDelayMs: lastServerQueueDelayMsValue,
                clientRenderMs: lastClientRenderMsValue,
                stallRecoveryMode: stallRecoveryModeValue,
                bitrateReduced: bitrateReducedValue,
                linkQualityScore: linkQualityScoreValue,
                linkState: linkState,
                pressureSource: pressureSourceValue,
                networkPressure: networkPressureValue,
                clientPressure: clientPressureValue,
                encoderPressure: encoderPressureValue,
                quality: VideoQualityStatus(
                    state: qualityStateLocked(),
                    linkState: linkState,
                    pressureSource: pressureSourceValue,
                    score: linkQualityScoreValue,
                    networkPressure: networkPressureValue,
                    clientPressure: clientPressureValue,
                    encoderPressure: encoderPressureValue,
                    serverQueueBytes: lastServerQueueBytesValue,
                    serverQueueDelayMs: lastServerQueueDelayMsValue,
                    clientQueue: lastClientQueueFeedbackValue,
                    clientQueueDelayMs: lastClientQueueDelayMsValue,
                    clientRenderMs: lastClientRenderMsValue,
                    ackExcessDelayMs: networkExcessAckDelayEmaMs,
                    targetFPS: targetFPSValue,
                    targetBitrate: targetBitrateValue
                )
            )
        }
    }

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * min(1, max(0, t))
    }

    static func qualityFromRTT(_ rttMs: Double) -> Double {
        1 - min(1, max(0, (rttMs - 30) / 170))
    }

    static func queueDelayMs(queueBytes: Int?, drainBitrateBps: Double) -> Double? {
        guard let queueBytes, queueBytes > 0, drainBitrateBps > 0 else { return nil }
        return Double(queueBytes) * 8_000 / drainBitrateBps
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
