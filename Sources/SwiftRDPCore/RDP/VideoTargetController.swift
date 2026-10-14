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
    case unknown
    case healthy
    case probing
    case congested
}

public enum VideoPressureSource: String, Sendable, Equatable {
    case none
    case frameAck
    case serverQueue
    case clientQueue
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
        state: .unknown,
        linkState: .unknown,
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

/// Adaptive video targets driven by excess queue/ACK delay and encode/decode pressure.
/// Application ACK throughput measures delivery, not the capacity of the network.
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
    private var lastFrameAckAt: Date?
    private var lastEncodeAt: Date?
    private var detectedRTTMs: Double?
    private var lastRTTSampleNanoseconds: UInt64 = 0
    private var lastBandwidthSampleNanoseconds: UInt64 = 0
    private var detectedRTTAt: Date?
    private var lastReportedBitrateValue = 0
    private var linkQualityScoreValue = 0.5
    private var networkPressureValue = 0.0
    private var clientPressureValue = 0.0
    private var encoderPressureValue = 0.0
    private var pressureSourceValue: VideoPressureSource = .none

    private var linkState: VideoLinkState = .healthy
    private var baseAckLatencyMs: Double?
    private var excessAckDelayEmaMs = 0.0
    private var acknowledgedBitrateEmaBps = 0.0
    private var detectedBandwidthBps = 0.0
    private var acknowledgedBitrateAt: Date?
    private var detectedBandwidthAt: Date?
    private var outputBitrateEmaBps = 0.0
    private var outputWindowStartedAt: Date?
    private var outputWindowBytes = 0
    private var encodeLatenciesMs: [Double] = []
    private var encodeServiceIntervalsMs: [Double] = []
    private var encoderBackloggedValue = false
    private var ackLatenciesMs: [Double] = []

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
    public static let initialAdaptiveBitrate = 4_000_000
    public static let serverQueueBudgetMs = 100.0
    public static let serverQueueResumeMs = 40.0
    public static let serverQueueLimitMs = 250.0
    public static let pressureConfirmationInterval: TimeInterval = 0.5
    public static let recoveryDwellInterval: TimeInterval = 1.0
    public static let adaptationCooldown: TimeInterval = 0.5
    public static let frameAckDelayBudgetFloorMs = 100.0
    private static let encodePressureSampleWindow = 16
    private static let rfxEncodeBudgetRatio = 0.85
    private static let encoderThroughputPressureRatio = 1.10
    public static let networkBitrateDecreaseFactor = 0.85
    public static let networkBitrateRecoveryFactor = 1.25
    private static let minimumAcknowledgedBytes = 4 * 1024
    private static let networkRecoveryPressureLimit = 0.75
    private static let bitrateProbeUtilization = 0.8
    private static let feedbackLifetime: TimeInterval = 5

    public init(
        bitrate: Int = ServerConfig.defaultVideoBitrate,
        fps: Int = 60,
        adaptationPriority: VideoAdaptationPriority = .qualityFirst
    ) {
        let resolvedBitrate = ServerConfig.normalizedVideoBitrate(bitrate)
        let resolvedFPS = min(Self.maxFPS, max(fps, 1))
        configuredBitrateValue = resolvedBitrate
        configuredFPSValue = resolvedFPS
        targetBitrateValue = min(resolvedBitrate, Self.initialAdaptiveBitrate)
        targetFPSValue = resolvedFPS
        adaptationPriorityValue = adaptationPriority
        networkBitrateCap = targetBitrateValue
        networkFPSCap = resolvedFPS
        encoderFPSCap = resolvedFPS
        decoderFPSCap = resolvedFPS
        bitrateReducedValue = targetBitrateValue < resolvedBitrate
    }

    public var configuredBitrate: Int { locked { configuredBitrateValue } }
    public var configuredFPS: Int { locked { configuredFPSValue } }
    public var targetBitrate: Int { locked { targetBitrateValue } }
    public var targetFPS: Int { locked { targetFPSValue } }
    var allowsStaticRefinement: Bool {
        locked {
            !stallRecoveryModeValue
                && max(networkPressureValue, clientPressureValue)
                    < Self.networkRecoveryPressureLimit
        }
    }
    public var stallRecoveryMode: Bool { locked { stallRecoveryModeValue } }
    public var bitrateReduced: Bool { locked { bitrateReducedValue } }
    public var consecutiveBackpressureTimeouts: Int { locked { consecutiveBackpressureTimeoutsValue } }
    public var clientQueueFeedback: ClientQueueFeedback { locked { lastClientQueueFeedbackValue } }
    public var lastClientQueueDelayMs: Double? { locked { lastClientQueueDelayMsValue } }
    public var lastServerQueueBytes: Int { locked { lastServerQueueBytesValue } }
    public var lastServerQueueDelayMs: Double { locked { lastServerQueueDelayMsValue } }
    /// Queue drain is bounded by both the measured path and video pacing rate.
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

    /// Covers healthy delivery and client processing time with bounded frame
    /// credits, without widening the window in response to congestion.
    public func recommendedFrameAcknowledgementWindow(
        clientCeiling: Int,
        now: Date = Date()
    ) -> Int {
        locked {
            refreshFeedbackPressureLocked(now: now)
            let ackIsFresh = isFresh(lastFrameAckAt, now: now)
            let ceiling = min(max(clientCeiling, 1), 12)
            let framePeriodMs = 1_000 / Double(max(targetFPSValue, 1))
            let clientBacklogged = ackIsFresh && clientPressureValue >= 1
            let severeAckPressure = ackIsFresh
                && excessAckDelayEmaMs > frameAckDelayBudgetMsLocked(now: now) * 1.5
            if stallRecoveryModeValue || clientBacklogged || severeAckPressure { return 1 }

            let baselineMs = max(estimatedRTTMsLocked(now: now), baseAckLatencyMs ?? 0)
            var feedbackMs = max(baselineMs, framePeriodMs)
            if ackIsFresh, networkPressureValue < Self.networkRecoveryPressureLimit {
                // Use normal smoothed feedback, rather than its fastest sample.
                // The minimum remains the congestion baseline; unhealthy delay
                // cannot earn additional credits.
                feedbackMs = max(feedbackMs, baselineMs + excessAckDelayEmaMs)
            }
            // Credits count frames, independent of picture size or bitrate.
            // One spare credit lets capture/encoding overlap ACK arrival instead
            // of waiting for a full round trip before starting the next picture.
            let window = Int(ceil(feedbackMs / framePeriodMs)) + 1
            return min(window, ceiling)
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
        encodeMs: Double = 0,
        encodeBusyIntervalMs: Double? = nil,
        encoderBacklogged: Bool = false,
        postEncodeMs: Double = 0,
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
            lastEncodeAt = now
            encoderBackloggedValue = encoderBacklogged
            if let interval = encodeBusyIntervalMs, interval > 0, !isIDR {
                encodeServiceIntervalsMs.append(interval)
                if encodeServiceIntervalsMs.count > Self.encodePressureSampleWindow {
                    encodeServiceIntervalsMs.removeFirst()
                }
            }
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
            captureAgeMsSinceSummary += max(captureAgeMs, 0)
            if isIDR { idrSinceSummary += 1 }
            refreshFeedbackPressureLocked(now: now)
            logSummaryIfNeededLocked(now: now)
            considerEncoderStateLocked(now: now)
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
        acknowledgementIntervalMs: Double = 0,
        now: Date = Date()
    ) {
        locked {
            lastClientQueueFeedbackValue = Self.normalizedClientQueueFeedback(clientQueue)
            lastServerUnacked = max(unacked, 0)
            lastFrameAckAt = now
            updateAckDelayLocked(ackLatencyMs, now: now)
            updateAcknowledgedBitrateLocked(
                bytes: acknowledgedBytes,
                intervalMs: acknowledgementIntervalMs,
                now: now
            )
            let drainRate = hasFreshAcknowledgedBitrateLocked(now: now)
                ? acknowledgedBitrateEmaBps
                : 0
            lastClientQueueDelayMsValue = clientQueueDelayLocked(drainBitrateBps: drainRate)
            refreshFeedbackPressureLocked(now: now)
            considerNetworkStateLocked(now: now)
            considerClientPressureLocked(now: now)
        }
    }

    public func noteClientQueueSuspended() {
        locked {
            lastClientQueueFeedbackValue = .suspended
            lastClientQueueDelayMsValue = nil
            lastServerUnacked = 0
            lastFrameAckAt = nil
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

    /// QoE is diagnostic; its command interval also contains receive waiting.
    public func noteClientQoE(renderMs: Int, now: Date = Date()) {
        locked {
            lastClientRenderMsValue = Double(max(renderMs, 0))
            lastClientRenderAtValue = now
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

    /// Each auto-detection measurement is consumed once; RTT updates cannot
    /// renew a previous bandwidth measurement.
    public func updateAutoDetect(_ metrics: NetworkAutoDetect.Metrics, now: Date = Date()) {
        locked {
            if metrics.rttMeasuredAtNanoseconds > lastRTTSampleNanoseconds {
                lastRTTSampleNanoseconds = metrics.rttMeasuredAtNanoseconds
                detectedRTTMs = Double(metrics.averageRTTMs > 0 ? metrics.averageRTTMs : metrics.baseRTTMs)
                detectedRTTAt = now
            }
            if metrics.bandwidthMeasuredAtNanoseconds > lastBandwidthSampleNanoseconds,
               metrics.hasBandwidth {
                lastBandwidthSampleNanoseconds = metrics.bandwidthMeasuredAtNanoseconds
                detectedBandwidthBps = Double(metrics.bandwidthKbps) * 1_000
                detectedBandwidthAt = now
                // The connect-time probe is a starting point. Healthy delivery
                // can subsequently probe above it instead of keeping a hard cap.
                let ceiling = outputWindowStartedAt == nil ? configuredBitrateValue : networkBitrateCap
                networkBitrateCap = min(ceiling, max(Self.minAdaptiveBitrate,
                    Int(detectedBandwidthBps * Self.networkBitrateDecreaseFactor)))
                recomputeTargetsLocked()
                if networkBitrateCap < configuredBitrateValue { linkState = .probing }
            }
            refreshFeedbackPressureLocked(now: now)
        }
    }

    /// A TCP/UDP channel switch changes queueing and delivery capacity. Preserve the
    /// configured/adapted targets while relearning measurements for the new path.
    func resetNetworkPathMeasurements() {
        locked {
            // Keep consumed timestamps: switching back must not renew old TCP measurements.
            detectedRTTMs = nil; detectedRTTAt = nil
            detectedBandwidthBps = 0; detectedBandwidthAt = nil
            baseAckLatencyMs = nil; excessAckDelayEmaMs = 0
            acknowledgedBitrateEmaBps = 0; acknowledgedBitrateAt = nil
            ackLatenciesMs.removeAll(keepingCapacity: true); lastFrameAckAt = nil
            lastReportedBitrateValue = 0
            networkPressureValue = 0; networkPressureSinceValue = nil; networkHealthySinceValue = nil
        }
    }

    func updateTransportRTT(nanoseconds: Double, measuredAt: UInt64, now: Date = Date()) {
        locked {
            guard nanoseconds > 0, measuredAt > lastRTTSampleNanoseconds else { return }
            lastRTTSampleNanoseconds = measuredAt
            let milliseconds = nanoseconds / 1_000_000
            detectedRTTMs = milliseconds
            detectedRTTAt = now
            refreshFeedbackPressureLocked(now: now)
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
        lastFrameAckAt = nil
        lastEncodeAt = nil
        detectedRTTMs = nil
        detectedRTTAt = nil
        lastRTTSampleNanoseconds = 0
        lastBandwidthSampleNanoseconds = 0
        lastReportedBitrateValue = 0
        linkQualityScoreValue = 0.5
        networkPressureValue = 0
        clientPressureValue = 0
        encoderPressureValue = 0
        pressureSourceValue = .none
        baseAckLatencyMs = nil
        excessAckDelayEmaMs = 0
        acknowledgedBitrateEmaBps = 0
        detectedBandwidthBps = 0
        acknowledgedBitrateAt = nil
        detectedBandwidthAt = nil
        outputBitrateEmaBps = 0
        outputWindowStartedAt = nil
        outputWindowBytes = 0
        encodeLatenciesMs.removeAll(keepingCapacity: true)
        encodeServiceIntervalsMs.removeAll(keepingCapacity: true)
        encoderBackloggedValue = false
        ackLatenciesMs.removeAll(keepingCapacity: true)
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
            let preservedRTT = detectedRTTMs
            let preservedRTTAt = detectedRTTAt
            let preservedRTTSample = lastRTTSampleNanoseconds
            let preservedBandwidthSample = lastBandwidthSampleNanoseconds
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
            detectedRTTMs = preservedRTT
            detectedRTTAt = preservedRTTAt
            lastRTTSampleNanoseconds = preservedRTTSample
            lastBandwidthSampleNanoseconds = preservedBandwidthSample
            baseAckLatencyMs = preservedBaseAck
            linkState = preservedLinkState
            linkQualityScoreValue = preservedLinkQuality

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
            guard encodeMs > interval * Self.rfxEncodeBudgetRatio else {
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

        let rttMs = estimatedRTTMsLocked(now: now)
        // A full application ACK window is expected during steady streaming.
        // It limits admission, but is not network congestion by itself.
        let pressure = networkPressureValue

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
        let healthy = pressure < Self.networkRecoveryPressureLimit
        guard healthy else {
            networkHealthySinceValue = nil
            return
        }

        let canProbeBitrate = hasBitrateDemandLocked(now: now)
        guard (networkBitrateCap < configuredBitrateValue && canProbeBitrate)
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

        recoverNetworkOneStepLocked(now: now)
        lastAdaptationAtValue = now
        networkHealthySinceValue = now
        if networkFPSCap >= configuredFPSValue,
           networkBitrateCap >= configuredBitrateValue || !canProbeBitrate {
            linkState = .healthy
        }
        RDPLog.rdp.debug(
            "VideoTargetController: feedback recovery -> " +
            "\(self.targetFPSValue)fps / \(self.targetBitrateValue / 1_000_000)Mbps " +
            "rtt=\(Int(rttMs))ms"
        )
    }

    private func lowerNetworkLoadLocked() {
        lowerBitrateFromFeedbackLocked(floor: Self.minAdaptiveBitrate)
        if adaptationPriorityValue == .qualityFirst || networkBitrateCap == Self.minAdaptiveBitrate {
            networkFPSCap = max(
                Self.minAdaptiveFPS,
                networkFPSCap - max(1, networkFPSCap / 5)
            )
        }
        recomputeTargetsLocked()
        RDPLog.rdp.info(
            "VideoTargetController: congestion feedbackExcess=\(Int(self.excessAckDelayEmaMs))ms " +
            "serverQueue=\(Int(self.lastServerQueueDelayMsValue))ms -> " +
            "\(self.targetFPSValue)fps / \(self.targetBitrateValue / 1_000_000)Mbps"
        )
    }

    private func lowerBitrateFromFeedbackLocked(floor: Int) {
        let next = Int(Double(networkBitrateCap) * Self.networkBitrateDecreaseFactor)
        networkBitrateCap = max(floor, next)
    }

    private func recoverNetworkOneStepLocked(now: Date) {
        // Restore cadence independently of bitrate demand. A low-motion empty
        // queue does not prove extra bandwidth; probe bitrate only when used.
        // Quality priority recovers FPS in smaller increments.
        if hasBitrateDemandLocked(now: now) { raiseNetworkBitrateOneStepLocked() }
        let step = max(1, configuredFPSValue / 12)
        let fpsStep = adaptationPriorityValue == .qualityFirst
            ? max(1, min(step, networkFPSCap / 5)) : step
        networkFPSCap = min(configuredFPSValue, networkFPSCap + fpsStep)
        recomputeTargetsLocked()
    }

    private func hasBitrateDemandLocked(now: Date) -> Bool {
        isFresh(lastEncodeAt, now: now)
            && outputBitrateEmaBps >= Double(networkBitrateCap) * Self.bitrateProbeUtilization
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
        guard isFresh(lastFrameAckAt, now: now) else {
            clientPressureSinceValue = nil
            decoderHealthySinceValue = nil
            return
        }

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
        guard decoderFPSCap < configuredFPSValue,
              isFresh(lastFrameAckAt, now: now), linkState != .congested else {
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
        recomputeTargetsLocked()
        lastAdaptationAtValue = now
        decoderHealthySinceValue = now
    }

    private func lowerFPSForEncodePressureLocked(encodeMs: Double) {
        let ratio = rfxAdaptiveModeValue ? Self.rfxEncodeBudgetRatio : 1
        let sustainable = Int((1_000 / max(encodeMs, 1) * ratio).rounded())
        encoderFPSCap = max(
            Self.minAdaptiveFPS,
            min(encoderFPSCap, configuredFPSValue, sustainable)
        )
        recomputeTargetsLocked()
    }

    private func recentEncoderServiceMsLocked() -> Double {
        guard !encodeServiceIntervalsMs.isEmpty else { return 0 }
        return encodeServiceIntervalsMs.reduce(0, +) / Double(encodeServiceIntervalsMs.count)
    }

    private func encodePressureMsLocked() -> Double? {
        let encodeMs: Double
        let ratio: Double
        if rfxAdaptiveModeValue {
            guard encodeLatenciesMs.count >= encodePressureSampleCountLocked() else { return nil }
            encodeMs = recentP95EncodeMsLocked()
            ratio = Self.rfxEncodeBudgetRatio
        } else {
            guard encoderBackloggedValue, encodeServiceIntervalsMs.count >= 4 else { return nil }
            encodeMs = recentEncoderServiceMsLocked()
            ratio = Self.encoderThroughputPressureRatio
        }
        let budget = 1000 / Double(max(targetFPSValue, 1))
        guard encodeMs > budget * ratio else {
            return nil
        }
        return encodeMs
    }

    private func considerEncoderStateLocked(now: Date) {
        guard !stallRecoveryModeValue else { return }
        guard !rfxAdaptiveModeValue, let serviceMs = encodePressureMsLocked() else {
            encodePressureSinceValue = nil
            considerEncodeRecoveryLocked(now: now)
            return
        }
        encodeHealthySinceValue = nil
        if encodePressureSinceValue == nil { encodePressureSinceValue = now }
        guard now.timeIntervalSince(encodePressureSinceValue ?? now) >= Self.pressureConfirmationInterval,
              adaptationAllowedLocked(now: now) else { return }
        lowerFPSForEncodePressureLocked(encodeMs: serviceMs)
        lastAdaptationAtValue = now
        RDPLog.rdp.info("VideoTargetController: encoder throughput \(Int(serviceMs))ms/frame -> \(self.targetFPSValue)fps")
    }

    private func considerEncodeRecoveryLocked(now: Date) {
        guard !stallRecoveryModeValue, encoderFPSCap < configuredFPSValue,
              linkState != .congested else {
            encodeHealthySinceValue = nil
            return
        }
        var capacity = configuredFPSValue
        if rfxAdaptiveModeValue {
            guard encodeLatenciesMs.count >= encodePressureSampleCountLocked() else { return }
            capacity = Int((1_000 / max(recentP95EncodeMsLocked(), 1) * Self.rfxEncodeBudgetRatio).rounded(.down))
        } else if encoderBackloggedValue, encodeServiceIntervalsMs.count >= 4 {
            capacity = Int((1_000 / max(recentEncoderServiceMsLocked(), 1)).rounded())
        }
        let candidate = min(configuredFPSValue, capacity,
            encoderFPSCap + max(1, configuredFPSValue / 12))
        guard candidate > encoderFPSCap else {
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
        recomputeTargetsLocked()
        lastAdaptationAtValue = now
        encodeHealthySinceValue = now
    }

    private func updateAckDelayLocked(_ latencyMs: Double, now: Date) {
        let latency = max(latencyMs, 0)
        ackLatenciesMs.append(latency)
        if ackLatenciesMs.count > 64 { ackLatenciesMs.removeFirst() }
        baseAckLatencyMs = min(baseAckLatencyMs ?? latency, latency)
        let measuredRTT = isFresh(detectedRTTAt, now: now, lifetime: 30) ? detectedRTTMs : nil
        let baseline = max(baseAckLatencyMs ?? latency, measuredRTT ?? 0)
        let excess = max(0, latency - baseline)
        excessAckDelayEmaMs = ackLatenciesMs.count == 1
            ? excess
            : excessAckDelayEmaMs * 0.8 + excess * 0.2
    }

    private func isFresh(_ measuredAt: Date?, now: Date, lifetime: TimeInterval = feedbackLifetime) -> Bool {
        guard let measuredAt else { return false }
        return max(0, now.timeIntervalSince(measuredAt)) <= lifetime
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
        if let detectedBandwidthAt,
           now >= detectedBandwidthAt,
           now.timeIntervalSince(detectedBandwidthAt) <= 30,
           detectedBandwidthBps > 0 {
            return max(min(detectedBandwidthBps, Double(targetBitrateValue)), Double(Self.minAdaptiveBitrate))
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
        let frameBudgetMs = 1_000 / Double(max(targetFPSValue, 1))
        let ackIsFresh = isFresh(lastFrameAckAt, now: now)
        let clientQueuePressure = ackIsFresh
            ? (lastClientQueueDelayMsValue ?? 0) / max(estimatedRTTMsLocked(now: now), frameBudgetMs * 2)
            : 0
        // FRAME_ACK includes network delivery, client scheduling and decoding.
        // A known client backlog already accounts for this delay separately.
        let pathPressure = ackIsFresh && clientQueuePressure < 1
            ? excessAckDelayEmaMs / frameAckDelayBudgetMsLocked(now: now)
            : 0
        // Whole encoded frames enter the byte pacer atomically. One frame's
        // serialization time is expected; only additional backlog is pressure.
        let serverQueuePressure = max(lastServerQueueDelayMsValue - frameBudgetMs, 0)
            / Self.serverQueueBudgetMs
        networkPressureValue = max(pathPressure, serverQueuePressure)
        clientPressureValue = clientQueuePressure
        encoderPressureValue = isFresh(lastEncodeAt, now: now)
            ? (encodePressureMsLocked().map { $0 / (frameBudgetMs *
                (rfxAdaptiveModeValue ? Self.rfxEncodeBudgetRatio : Self.encoderThroughputPressureRatio)) } ?? 0)
            : 0

        let pressures: [(VideoPressureSource, Double)] = [
            (.frameAck, pathPressure),
            (.serverQueue, serverQueuePressure),
            (.clientQueue, clientQueuePressure),
            (.encoder, encoderPressureValue),
        ]
        let strongest = pressures.max { $0.1 < $1.1 }
        pressureSourceValue = strongest.map { $0.1 > 0 ? $0.0 : .none } ?? .none
        linkQualityScoreValue = 1 - min(1, max(networkPressureValue, clientPressureValue, encoderPressureValue))
    }

    private func adaptationAllowedLocked(now: Date) -> Bool {
        guard let last = lastAdaptationAtValue else { return true }
        return now.timeIntervalSince(last) >= Self.adaptationCooldown
    }

    private func qualityStateLocked(now: Date) -> VideoLinkState {
        let maximumPressure = max(networkPressureValue, clientPressureValue, encoderPressureValue)
        if stallRecoveryModeValue || maximumPressure >= 1 { return .congested }
        if !isFresh(lastFrameAckAt, now: now), !isFresh(detectedRTTAt, now: now, lifetime: 30) { return .unknown }
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
    ) {
        guard bytes >= Self.minimumAcknowledgedBytes, intervalMs > 0 else { return }
        let instant = Double(bytes) * 8_000 / intervalMs
        acknowledgedBitrateEmaBps = !isFresh(acknowledgedBitrateAt, now: now)
            ? instant
            : acknowledgedBitrateEmaBps * 0.75 + instant * 0.25
        acknowledgedBitrateAt = now
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
        networkBitrateCap = min(configuredBitrateValue, Self.initialAdaptiveBitrate)
        networkFPSCap = configuredFPSValue
        encoderFPSCap = configuredFPSValue
        decoderFPSCap = configuredFPSValue
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

    private func estimatedRTTMsLocked(now: Date = Date()) -> Double {
        let rtt = isFresh(detectedRTTAt, now: now, lifetime: 30) ? detectedRTTMs : nil
        return max(rtt ?? baseAckLatencyMs ?? (1_000 / Double(max(targetFPSValue, 1))), 1)
    }

    private func frameAckDelayBudgetMsLocked(now: Date) -> Double {
        // Decoded-frame feedback is not a transport ACK. Allow its scheduling
        // variation while bounding sustained additional delivery latency.
        max(estimatedRTTMsLocked(now: now), Self.frameAckDelayBudgetFloorMs,
            1_000 / Double(max(targetFPSValue, 1)))
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
        switch qualityStateLocked(now: now) {
        case .unknown: stateLabel = "unknown"
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
                "age=%.1fms enc=%.1fms p95Enc=%.1fms serviceEnc=%.1fms busyEnc=%@ post=%.1fms " +
                "idr=%d drops=%d unacked=%d/%d " +
                "clientQ=%@ clientQueue=%.0fms serverQ=%dB serverQueue=%.0fms " +
                "render=%.0fms ack=%.0fms feedbackExcess=%.0fms " +
                "linkQ=%.2f state=%@ source=%@ pressure=%.2f/%.2f/%.2f " +
                "caps=%d/%d/%d stallRecovery=%@",
            captureFPS, wireFPS, clientDecodedFPS, targetFPSValue,
            Double(targetBitrateValue) / 1_000_000,
            Double(bytesSinceSummary) * 8 / elapsed / 1000,
            captureAgeMsSinceSummary / count,
            encodeMsSinceSummary / count, p95EncodeMs,
            recentEncoderServiceMsLocked(), encoderBackloggedValue ? "yes" : "no",
            postEncodeMsSinceSummary / count,
            idrSinceSummary, encodeDropsSinceSummary, lastServerUnacked, lastAckWindow,
            clientQueueLabel, lastClientQueueDelayMsValue ?? 0,
            lastServerQueueBytesValue, lastServerQueueDelayMsValue,
            isFresh(lastClientRenderAtValue, now: now) ? lastClientRenderMsValue : 0, ackAverage,
            excessAckDelayEmaMs, linkQualityScoreValue,
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
        captureAgeMsSinceSummary = 0
        clientDecodedFramesSinceSummary = 0
        idrSinceSummary = 0
        encodeDropsSinceSummary = 0
        lastPerfSummary = now
    }

    public struct PerfSnapshot: Sendable {
        public var avgEncodeMs: Double
        public var avgFrameAckLatencyMs: Double
        public var p95FrameAckLatencyMs: Double
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

    public func performanceSnapshot(now: Date = Date()) -> PerfSnapshot {
        locked {
            refreshFeedbackPressureLocked(now: now)
            let queueIsFresh = isFresh(lastFrameAckAt, now: now)
            let sorted = ackLatenciesMs.sorted()
            let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            return PerfSnapshot(
                avgEncodeMs: recentAverageEncodeMsLocked(sampleCount: encodeLatenciesMs.count),
                avgFrameAckLatencyMs: sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count),
                p95FrameAckLatencyMs: p95,
                sampleCount: sorted.count,
                captureFPS: lastCaptureFPSValue,
                wireFPS: lastWireFPSValue,
                clientDecodedFPS: lastClientDecodedFPSValue,
                targetFPS: targetFPSValue,
                targetBitrate: targetBitrateValue,
                configuredBitrate: configuredBitrateValue,
                lastReportedBitrate: lastReportedBitrateValue,
                clientQueue: queueIsFresh ? lastClientQueueFeedbackValue : .unavailable,
                clientQueueDelayMs: queueIsFresh ? (lastClientQueueDelayMsValue ?? 0) : 0,
                serverQueueBytes: lastServerQueueBytesValue,
                serverQueueDelayMs: lastServerQueueDelayMsValue,
                clientRenderMs: isFresh(lastClientRenderAtValue, now: now) ? lastClientRenderMsValue : 0,
                stallRecoveryMode: stallRecoveryModeValue,
                bitrateReduced: bitrateReducedValue,
                linkQualityScore: linkQualityScoreValue,
                linkState: linkState,
                pressureSource: pressureSourceValue,
                networkPressure: networkPressureValue,
                clientPressure: clientPressureValue,
                encoderPressure: encoderPressureValue,
                quality: VideoQualityStatus(
                    state: qualityStateLocked(now: now),
                    linkState: linkState,
                    pressureSource: pressureSourceValue,
                    score: linkQualityScoreValue,
                    networkPressure: networkPressureValue,
                    clientPressure: clientPressureValue,
                    encoderPressure: encoderPressureValue,
                    serverQueueBytes: lastServerQueueBytesValue,
                    serverQueueDelayMs: lastServerQueueDelayMsValue,
                    clientQueue: queueIsFresh ? lastClientQueueFeedbackValue : .unavailable,
                    clientQueueDelayMs: queueIsFresh ? lastClientQueueDelayMsValue : nil,
                    clientRenderMs: isFresh(lastClientRenderAtValue, now: now) ? lastClientRenderMsValue : 0,
                    ackExcessDelayMs: excessAckDelayEmaMs,
                    targetFPS: targetFPSValue,
                    targetBitrate: targetBitrateValue
                )
            )
        }
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
