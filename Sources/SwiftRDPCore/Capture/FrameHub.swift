import CoreGraphics
import CoreVideo
import Foundation

public struct CapturedFrame: @unchecked Sendable {
    public let width: Int
    public let height: Int
    /// 24-bit BGR bottom-up, row padded to 4 bytes (RDP bitmap style).
    public let bgrBottomUp: [UInt8]
    /// SCKit dirty regions. `nil` means that every region may have changed;
    /// an empty array means that capture reported no dirty regions.
    public let dirtyRects: [CGRect]?
    public let pixelBuffer: CVPixelBuffer?
    /// Monotonic host time associated with the capture sample.
    /// Zero means the frame was constructed without capture timing.
    public let captureUptimeNanoseconds: UInt64

    public init(
        width: Int,
        height: Int,
        bgrBottomUp: [UInt8],
        dirtyRects: [CGRect]? = nil,
        pixelBuffer: CVPixelBuffer? = nil,
        captureUptimeNanoseconds: UInt64 = 0
    ) {
        self.width = width
        self.height = height
        self.bgrBottomUp = bgrBottomUp
        self.dirtyRects = dirtyRects
        self.pixelBuffer = pixelBuffer
        self.captureUptimeNanoseconds = captureUptimeNanoseconds
    }
}

/// Latest-frame exchange between the capture producer and session consumers.
///
/// Publishing never waits for an encoder. A slow consumer observes the newest
/// complete frame and can account for consumer-skipped samples through
/// `markDelivered(sequence:after:)`.
public final class FrameHub: @unchecked Sendable {
    public struct Statistics: Sendable, Equatable {
        public let publishedFrames: UInt64
        public let deliveredFrames: UInt64
        public let skippedFrames: UInt64
        public let latestSequence: UInt64
        public let latestCaptureUptimeNanoseconds: UInt64

        public init(
            publishedFrames: UInt64,
            deliveredFrames: UInt64,
            skippedFrames: UInt64,
            latestSequence: UInt64,
            latestCaptureUptimeNanoseconds: UInt64
        ) {
            self.publishedFrames = publishedFrames
            self.deliveredFrames = deliveredFrames
            self.skippedFrames = skippedFrames
            self.latestSequence = latestSequence
            self.latestCaptureUptimeNanoseconds = latestCaptureUptimeNanoseconds
        }
    }

    private let lock = NSLock()
    private var latestFrame: CapturedFrame?
    private var sequence: UInt64 = 0
    private var publishedFrames: UInt64 = 0
    private var deliveredFrames: UInt64 = 0
    private var skippedFrames: UInt64 = 0

    /// Called after a complete frame is visible to consumers.
    public var onFrameAvailable: (() -> Void)?

    public init() {}

    @discardableResult
    public func publish(_ frame: CapturedFrame, notify: Bool = true) -> UInt64 {
        let callback: (() -> Void)?
        let publishedSequence: UInt64
        lock.lock()
        sequence &+= 1
        publishedSequence = sequence
        latestFrame = frame
        publishedFrames &+= 1
        callback = onFrameAvailable
        lock.unlock()

        if notify {
            callback?()
        }
        return publishedSequence
    }

    /// Notify consumers after a producer has finished its own lifecycle lock.
    public func notifyFrameAvailable() {
        lock.lock()
        let callback = onFrameAvailable
        lock.unlock()
        callback?()
    }

    public func currentFrame() -> CapturedFrame? {
        lock.lock()
        defer { lock.unlock() }
        return latestFrame
    }

    public func currentFrameSnapshot() -> (frame: CapturedFrame, sequence: UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        guard let latestFrame else { return nil }
        return (latestFrame, sequence)
    }

    /// Mark the newest frame accepted by a consumer. This measures the frames
    /// the consumer actually skipped, rather than counting every publication
    /// that happened while any frame was resident in the hub.
    @discardableResult
    public func markDelivered(sequence deliveredSequence: UInt64, after previousSequence: UInt64) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        guard deliveredSequence > previousSequence else { return 0 }
        let skipped = previousSequence == 0 ? 0 : deliveredSequence - previousSequence - 1
        deliveredFrames &+= 1
        skippedFrames &+= skipped
        return skipped
    }

    public var statistics: Statistics {
        lock.lock()
        defer { lock.unlock() }
        return Statistics(
            publishedFrames: publishedFrames,
            deliveredFrames: deliveredFrames,
            skippedFrames: skippedFrames,
            latestSequence: sequence,
            latestCaptureUptimeNanoseconds: latestFrame?.captureUptimeNanoseconds ?? 0
        )
    }

    /// Start a fresh capture accounting interval while keeping the sequence
    /// monotonic across stream generations.
    public func resetStatistics() {
        lock.lock()
        publishedFrames = 0
        deliveredFrames = 0
        skippedFrames = 0
        lock.unlock()
    }

    /// Discard the current frame when a stream generation ends. Sequence and
    /// counters remain monotonic so consumers can distinguish a restart.
    public func clearLatestFrame() {
        lock.lock()
        latestFrame = nil
        lock.unlock()
    }
}
