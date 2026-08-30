import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// VideoToolbox H.264 encoder for the single-stream AVC420 GFX path.
///
/// Capture buffers are submitted at the visible desktop size. Output is a
/// single Annex-B access unit containing only the NAL types accepted by the
/// RDP graphics wire format.
public final class H264Encoder {
    public struct EncodedAccessUnit {
        public let bytes: [UInt8]
        public let isIDR: Bool
    }

    public enum EncodeError: Error {
        case sessionFailed(OSStatus)
        case frameFailed(OSStatus)
        case frameDropped
        case missingSampleData
        case timedOut
    }

    private final class PendingFrame {
        let generation: UInt64
        let deadline: DispatchTime
        let completion: (Result<EncodedAccessUnit, EncodeError>) -> Void

        init(
            generation: UInt64,
            deadline: DispatchTime,
            completion: @escaping (Result<EncodedAccessUnit, EncodeError>) -> Void
        ) {
            self.generation = generation
            self.deadline = deadline
            self.completion = completion
        }
    }

    private var session: VTCompressionSession?
    private let submissionLock = NSLock()
    private let lock = NSLock()
    private let deliveryQueue = DispatchQueue(
        label: "com.swiftrdp.h264.delivery",
        qos: .userInitiated
    )

    public private(set) var width = 0
    public private(set) var height = 0
    public private(set) var visibleWidth = 0
    public private(set) var visibleHeight = 0

    private var pendingForceKeyframe = false
    private var pending: [Int64: PendingFrame] = [:]
    private var sweepScheduled = false
    private var generation: UInt64 = 0
    private var idrCount = 0
    private var ptsValue: Int64 = 0
    private var loggedRateControlSupport = false
    private var rateControl = RateControlSupport()

    private static let ptsTimescale: CMTimeScale = 600
    private static let frameTimeout: TimeInterval = 1.0
    private static let sweepInterval: TimeInterval = 0.25
    public var bitrate: Int = 12_500_000
    public var expectedFrameRate: Int = 30
    public var asyncMode = true

    var hasPendingFrames: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !pending.isEmpty
    }

    public init() {}

    static func isFrameDropped(_ infoFlags: VTEncodeInfoFlags) -> Bool {
        infoFlags.contains(.frameDropped)
    }

    public func start(width: Int, height: Int) throws {
        stop()
        visibleWidth = max(width & ~1, 2)
        visibleHeight = max(height & ~1, 2)
        self.width = visibleWidth
        self.height = visibleHeight
        expectedFrameRate = Self.constrainedFrameRate(
            expectedFrameRate,
            width: self.width,
            height: self.height
        )
        pendingForceKeyframe = true
        ptsValue = 0
        loggedRateControlSupport = false
        session = try makeSession(width: self.width, height: self.height)
        RDPLog.gfx.info("H264: AVC420 VideoToolbox zero-copy (NV12/BGRA -> VT)")
        RDPLog.gfx.info(
            "H264: encoder initialized \(self.width)x\(self.height) " +
            "visible=\(visibleWidth)x\(visibleHeight)"
        )
    }

    public func stop() {
        submissionLock.lock()
        defer { submissionLock.unlock() }
        lock.lock()
        generation &+= 1
        let oldSession = session
        session = nil
        pending.removeAll(keepingCapacity: true)
        pendingForceKeyframe = false
        sweepScheduled = false
        lock.unlock()
        invalidate(oldSession)
    }

    /// Keep H.264 throughput below the H.264 Level 5.2 macroblock rate.
    static func constrainedFrameRate(
        _ requestedFPS: Int,
        width: Int,
        height: Int
    ) -> Int {
        let requested = max(1, min(requestedFPS, 60))
        let macroblocksPerFrame = max(((width + 15) / 16) * ((height + 15) / 16), 1)
        let safeLevel52MacroblocksPerSecond = 2_073_600 * 96 / 100
        return min(
            requested,
            max(safeLevel52MacroblocksPerSecond / macroblocksPerFrame, 1)
        )
    }

    private var encoderPictureRate: Int { expectedFrameRate }

    public func updateBitrate(_ bps: Int) {
        bitrate = max(bps, 1_000_000)
        applyRateControl(session)
    }

    public func updateExpectedFrameRate(_ fps: Int) {
        let clamped = Self.constrainedFrameRate(
            fps,
            width: max(width, 1),
            height: max(height, 1)
        )
        guard clamped != expectedFrameRate else { return }
        expectedFrameRate = clamped
        let rate = expectedFrameRate as CFNumber
        if let session {
            VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_ExpectedFrameRate,
                value: rate
            )
        }
        applyRateControl(session)
    }

    public func requestForceKeyframe() {
        lock.lock()
        pendingForceKeyframe = true
        lock.unlock()
    }

    public func noteIDR() {
        idrCount += 1
        if idrCount % 30 == 0 {
            RDPLog.gfx.info("H264: H264 stats: IDR=\(idrCount)")
        }
    }

    @discardableResult
    public func encodeAsync(
        pixelBuffer: CVPixelBuffer,
        completion: @escaping (Result<EncodedAccessUnit, EncodeError>) -> Void
    ) -> Bool {
        submit(pixelBuffer: pixelBuffer, completion: completion) != nil
    }

    public func encode(pixelBuffer: CVPixelBuffer) -> EncodedAccessUnit? {
        var encoded: EncodedAccessUnit?
        let done = DispatchSemaphore(value: 0)
        let submitted = submit(pixelBuffer: pixelBuffer) { result in
            switch result {
            case .success(let unit):
                encoded = unit
            case .failure(let error):
                RDPLog.gfx.error("H264: encode failed (\(error))")
            }
            done.signal()
        }
        guard let pts = submitted else { return nil }
        completeFrames(untilPresentationTimeStamp: pts)
        guard done.wait(timeout: .now() + Self.frameTimeout + Self.sweepInterval * 2) == .success else {
            RDPLog.gfx.error("H264: encode delivery stalled \(width)x\(height)")
            return nil
        }
        return encoded
    }

    private func submit(
        pixelBuffer: CVPixelBuffer,
        completion: @escaping (Result<EncodedAccessUnit, EncodeError>) -> Void
    ) -> CMTime? {
        submissionLock.lock()
        defer { submissionLock.unlock() }

        lock.lock()
        guard let session, pending.isEmpty else {
            lock.unlock()
            return nil
        }
        let force = consumeForceKeyframeLocked()
        let durationValue = CMTimeValue(
            max(1, Int(Self.ptsTimescale) / max(encoderPictureRate, 1))
        )
        let pts = CMTime(value: ptsValue, timescale: Self.ptsTimescale)
        ptsValue += durationValue
        let key = pts.value
        let submissionGeneration = generation
        pending[key] = PendingFrame(
            generation: submissionGeneration,
            deadline: .now() + Self.frameTimeout,
            completion: completion
        )
        scheduleSweepLocked()
        lock.unlock()

        let duration = CMTime(value: durationValue, timescale: Self.ptsTimescale)
        let properties: CFDictionary? = force
            ? ([kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary)
            : nil
        var encodeInfoFlags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: properties,
            infoFlagsOut: &encodeInfoFlags
        ) { [weak self] status, infoFlags, sampleBuffer in
            guard let self else { return }
            if Self.isFrameDropped(infoFlags) {
                RDPLog.gfx.debug(
                    "H264: frame dropped status=\(status) " +
                    "flags=0x\(String(infoFlags.rawValue, radix: 16))"
                )
                self.finish(key: key, generation: submissionGeneration, failure: .frameDropped)
                return
            }
            guard status == noErr else {
                self.finish(
                    key: key,
                    generation: submissionGeneration,
                    failure: .frameFailed(status)
                )
                return
            }
            guard let sampleBuffer else {
                RDPLog.gfx.error("H264: output missing sample data")
                self.finish(
                    key: key,
                    generation: submissionGeneration,
                    failure: .missingSampleData
                )
                return
            }
            if !CMSampleBufferDataIsReady(sampleBuffer) {
                let readyStatus = CMSampleBufferMakeDataReady(sampleBuffer)
                guard readyStatus == noErr, CMSampleBufferDataIsReady(sampleBuffer) else {
                    RDPLog.gfx.error("H264: sample data not ready status=\(readyStatus)")
                    self.finish(
                        key: key,
                        generation: submissionGeneration,
                        failure: .missingSampleData
                    )
                    return
                }
            }
            guard let unit = Self.makeAccessUnit(sampleBuffer) else {
                RDPLog.gfx.error("H264: output sample could not be parsed")
                self.finish(
                    key: key,
                    generation: submissionGeneration,
                    failure: .missingSampleData
                )
                return
            }
            self.deliver(key: key, generation: submissionGeneration, unit: unit)
        }
        guard status == noErr else {
            RDPLog.gfx.error("H264: submission failed: \(status)")
            dropPending(key: key, generation: submissionGeneration)
            return nil
        }
        if Self.isFrameDropped(encodeInfoFlags) {
            RDPLog.gfx.debug(
                "H264: synchronously dropped " +
                "flags=0x\(String(encodeInfoFlags.rawValue, radix: 16))"
            )
            finish(key: key, generation: submissionGeneration, failure: .frameDropped)
        }
        return pts
    }

    private func deliver(key: Int64, generation: UInt64, unit: EncodedAccessUnit) {
        lock.lock()
        guard self.generation == generation, let frame = pending.removeValue(forKey: key) else {
            lock.unlock()
            return
        }
        lock.unlock()
        deliveryQueue.async { frame.completion(.success(unit)) }
    }

    private func dropPending(key: Int64, generation: UInt64) {
        lock.lock()
        if self.generation == generation, pending.removeValue(forKey: key) != nil {
            pendingForceKeyframe = true
        }
        lock.unlock()
    }

    private func finish(key: Int64, generation: UInt64, failure: EncodeError) {
        lock.lock()
        guard self.generation == generation, let frame = pending.removeValue(forKey: key) else {
            lock.unlock()
            return
        }
        // A dropped input never reached the client and does not invalidate the
        // encoder's last emitted reference frame. Other failures need a fresh
        // reference chain before the next picture is sent.
        if case .frameDropped = failure {
            // Keep the current reference chain.
        } else {
            pendingForceKeyframe = true
        }
        lock.unlock()
        deliveryQueue.async { frame.completion(.failure(failure)) }
    }

    private func scheduleSweepLocked() {
        guard !sweepScheduled, !pending.isEmpty else { return }
        sweepScheduled = true
        deliveryQueue.asyncAfter(deadline: .now() + Self.sweepInterval) { [weak self] in
            self?.sweepExpired()
        }
    }

    private func sweepExpired() {
        let now = DispatchTime.now()
        var expired: [PendingFrame] = []
        lock.lock()
        sweepScheduled = false
        for (key, frame) in pending where frame.deadline < now {
            pending.removeValue(forKey: key)
            expired.append(frame)
            pendingForceKeyframe = true
        }
        scheduleSweepLocked()
        lock.unlock()
        for frame in expired { frame.completion(.failure(.timedOut)) }
    }

    private func completeFrames(untilPresentationTimeStamp pts: CMTime) {
        lock.lock()
        let currentSession = session
        lock.unlock()
        if let currentSession {
            let status = VTCompressionSessionCompleteFrames(
                currentSession,
                untilPresentationTimeStamp: pts
            )
            if status != noErr {
                RDPLog.gfx.error("H264: CompleteFrames failed: \(status)")
            }
        }
    }

    private func consumeForceKeyframeLocked() -> Bool {
        let force = pendingForceKeyframe
        pendingForceKeyframe = false
        return force
    }

    private func makeSession(width: Int, height: Int) throws -> VTCompressionSession {
        let imageAttributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let sess = try Self.createSession(
            width: width,
            height: height,
            imageAttributes: imageAttributes
        )

        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AllowOpenGOP, value: kCFBooleanFalse)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(
            sess,
            key: kVTCompressionPropertyKey_AllowTemporalCompression,
            value: kCFBooleanTrue
        )
        VTSessionSetProperty(
            sess,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: encoderPictureRate as CFNumber
        )
        VTSessionSetProperty(
            sess,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: (1 << 30) as CFNumber
        )
        VTSessionSetProperty(
            sess,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: 0.0 as CFNumber
        )
        VTSessionSetProperty(
            sess,
            key: kVTCompressionPropertyKey_ColorPrimaries,
            value: kCVImageBufferColorPrimaries_ITU_R_709_2
        )
        VTSessionSetProperty(
            sess,
            key: kVTCompressionPropertyKey_TransferFunction,
            value: kCVImageBufferTransferFunction_ITU_R_709_2
        )
        VTSessionSetProperty(
            sess,
            key: kVTCompressionPropertyKey_YCbCrMatrix,
            value: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        )
        VTSessionSetProperty(
            sess,
            key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            value: kCFBooleanTrue
        )
        let profileLabel = applyHighProfile(sess)

        let support = Self.probeRateControlSupport(sess)
        lock.lock()
        rateControl = support
        let shouldLogSupport = !loggedRateControlSupport
        loggedRateControlSupport = true
        lock.unlock()
        applyRateControl(sess)
        VTCompressionSessionPrepareToEncodeFrames(sess)

        if shouldLogSupport {
            RDPLog.gfx.info(
                "H264: LLRC rate control - DataRateLimits=\(support.dataRateLimits ? "yes" : "no")"
            )
        }
        RDPLog.gfx.info(
            "H264: VideoToolbox encoder created \(profileLabel) " +
            "llrc=true \(width)x\(height)"
        )
        return sess
    }

    private static func createSession(
        width: Int,
        height: Int,
        imageAttributes: [CFString: Any]
    ) throws -> VTCompressionSession {
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue as Any,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue as Any,
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: kCFBooleanTrue as Any,
        ]
        var sess: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: imageAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &sess
        )
        if status == noErr, let sess { return sess }
        RDPLog.gfx.error("H264: VTCompressionSessionCreate failed: \(status)")
        throw EncodeError.sessionFailed(status)
    }

    private func applyHighProfile(_ session: VTCompressionSession) -> String {
        let profileStatus = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_H264_High_AutoLevel
        )
        let entropyStatus = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_H264EntropyMode,
            value: kVTH264EntropyMode_CABAC
        )
        if profileStatus != noErr || entropyStatus != noErr {
            RDPLog.gfx.error(
                "H264: High/CABAC configuration failed " +
                "profile=\(profileStatus) entropy=\(entropyStatus)"
            )
        }
        return "profile=High entropy=CABAC"
    }

    private struct RateControlSupport {
        var dataRateLimits = false
    }

    private static func probeRateControlSupport(_ session: VTCompressionSession) -> RateControlSupport {
        var support = RateControlSupport()
        var list: CFDictionary?
        guard VTSessionCopySupportedPropertyDictionary(
            session,
            supportedPropertyDictionaryOut: &list
        ) == noErr, let dictionary = list else {
            return support
        }
        let supported = dictionary as NSDictionary
        support.dataRateLimits = supported[kVTCompressionPropertyKey_DataRateLimits] != nil
        return support
    }

    static func dataRateLimitBytesPerSecond(forBitrate bitrate: Int) -> Int {
        let bitrate = max(bitrate, 1_000_000)
        let peakBitsPerSecond = max(
            Int(Double(bitrate) * 1.35),
            bitrate + 2_000_000
        )
        return max(peakBitsPerSecond / 8, 1)
    }

    private func applyRateControl(_ session: VTCompressionSession?) {
        guard let session else { return }
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: bitrate as CFNumber
        )
        lock.lock()
        let supportsDataRateLimits = rateControl.dataRateLimits
        lock.unlock()
        if supportsDataRateLimits {
            let peakBytesPerSecond = Self.dataRateLimitBytesPerSecond(forBitrate: bitrate)
            let limits: [CFNumber] = [peakBytesPerSecond as CFNumber, 1.0 as CFNumber]
            VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_DataRateLimits,
                value: limits as CFArray
            )
        }
    }

    private func invalidate(_ session: VTCompressionSession?) {
        guard let session else { return }
        VTCompressionSessionInvalidate(session)
    }

    private static let startCode: [UInt8] = [0, 0, 0, 1]

    private static func makeAccessUnit(_ sampleBuffer: CMSampleBuffer) -> EncodedAccessUnit? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let isIDR = isSyncSample(sampleBuffer)
        var lengthFieldSize = 4
        var parameterSets: [(pointer: UnsafePointer<UInt8>, size: Int)] = []
        if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var count = 0
            var headerLength: Int32 = 4
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &headerLength
            )
            if status == noErr {
                lengthFieldSize = Int(headerLength)
                if isIDR {
                    for index in 0..<count {
                        var pointer: UnsafePointer<UInt8>?
                        var size = 0
                        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                            format,
                            parameterSetIndex: index,
                            parameterSetPointerOut: &pointer,
                            parameterSetSizeOut: &size,
                            parameterSetCountOut: nil,
                            nalUnitHeaderLengthOut: nil
                        ) == noErr, let pointer, size > 0 else { continue }
                        parameterSets.append((pointer, size))
                    }
                }
            }
        }
        guard (1...4).contains(lengthFieldSize) else { return nil }

        return withAVCCBytes(dataBuffer) { source, total -> EncodedAccessUnit? in
            let bytes = annexBAccessUnit(
                avcc: source,
                length: total,
                lengthFieldSize: lengthFieldSize,
                parameterSets: parameterSets
            )
            guard !bytes.isEmpty else { return nil }
            return EncodedAccessUnit(bytes: bytes, isIDR: isIDR)
        }
    }

    static func annexBAccessUnit(
        avcc: UnsafePointer<UInt8>,
        length: Int,
        lengthFieldSize: Int,
        parameterSets: [(pointer: UnsafePointer<UInt8>, size: Int)]
    ) -> [UInt8] {
        guard (1...4).contains(lengthFieldSize) else { return [] }
        var out: [UInt8] = []
        let parameterBytes = parameterSets.reduce(0) { $0 + $1.size + startCode.count }
        out.reserveCapacity(length + parameterBytes)
        for set in parameterSets {
            out.append(contentsOf: startCode)
            out.append(contentsOf: UnsafeBufferPointer(start: set.pointer, count: set.size))
        }
        var offset = 0
        while offset + lengthFieldSize <= length {
            var nalLength = 0
            for index in 0..<lengthFieldSize {
                nalLength = (nalLength << 8) | Int(avcc[offset + index])
            }
            offset += lengthFieldSize
            guard nalLength > 0, offset + nalLength <= length else { break }
            switch avcc[offset] & 0x1F {
            case 1, 5, 7, 8:
                out.append(contentsOf: startCode)
                out.append(contentsOf: UnsafeBufferPointer(start: avcc + offset, count: nalLength))
            default:
                break
            }
            offset += nalLength
        }
        return out
    }

    private static func withAVCCBytes<T>(
        _ dataBuffer: CMBlockBuffer,
        _ body: (UnsafePointer<UInt8>, Int) -> T?
    ) -> T? {
        let total = CMBlockBufferGetDataLength(dataBuffer)
        guard total > 0 else { return nil }
        if CMBlockBufferIsRangeContiguous(dataBuffer, atOffset: 0, length: total) {
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                dataBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: nil,
                dataPointerOut: &pointer
            ) == noErr, let pointer else { return nil }
            return body(UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), total)
        }
        var scratch = [UInt8](repeating: 0, count: total)
        let status = scratch.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(
                dataBuffer,
                atOffset: 0,
                dataLength: total,
                destination: base
            )
        }
        guard status == noErr else { return nil }
        return scratch.withUnsafeBufferPointer { buffer -> T? in
            guard let base = buffer.baseAddress else { return nil }
            return body(base, total)
        }
    }

    private static func isSyncSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[CFString: Any]], let first = attachments.first else {
            return true
        }
        return first[kCMSampleAttachmentKey_NotSync] as? Bool != true
    }
}
