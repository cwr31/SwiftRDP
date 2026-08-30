import Foundation
import VideoToolbox
import CoreVideo

/// GPU pixel buffer scale / format conversion.
///
/// Replaces the old `CGContext` + `makeImage()` path: that allocated a CGImage
/// per frame and did the resample on the CPU, and NV12 sources needed a full
/// software unpack to BGRA first. `VTPixelTransferSession` handles NV12↔BGRA and
/// the resize in one hardware pass, and `kVTScalingMode_Letterbox` is the native
/// aspect-preserving mode, so there is no hand-written letterbox either.
public final class PixelBufferTransfer {

    public enum Scaling {
        /// Stretch to the destination rectangle.
        case fill
        /// Preserve the source aspect ratio, centered, black bars.
        case letterbox

        var mode: CFString {
            switch self {
            case .fill: return kVTScalingMode_Normal
            case .letterbox: return kVTScalingMode_Letterbox
            }
        }
    }

    private struct PoolKey: Hashable {
        let width: Int
        let height: Int
        let pixelFormat: OSType
    }

    private let lock = NSLock()
    private var session: VTPixelTransferSession?
    private var appliedScaling: Scaling?
    private var pools: [PoolKey: CVPixelBufferPool] = [:]

    public init() {}

    deinit {
        if let session { VTPixelTransferSessionInvalidate(session) }
    }

    /// Convert `source` into a `width`x`height` buffer of `pixelFormat`.
    /// Returns `source` unchanged when it already matches.
    public func transfer(
        _ source: CVPixelBuffer,
        width: Int,
        height: Int,
        pixelFormat: OSType,
        scaling: Scaling
    ) -> CVPixelBuffer? {
        guard width > 0, height > 0 else { return nil }
        if CVPixelBufferGetWidth(source) == width,
           CVPixelBufferGetHeight(source) == height,
           CVPixelBufferGetPixelFormatType(source) == pixelFormat {
            return source
        }
        lock.lock()
        defer { lock.unlock() }
        guard let session = ensureSessionLocked(scaling: scaling),
              let destination = ensureBufferLocked(
                width: width, height: height, pixelFormat: pixelFormat
              ) else { return nil }
        let status = VTPixelTransferSessionTransferImage(session, from: source, to: destination)
        guard status == noErr else {
            RDPLog.gfx.error(
                "PixelBufferTransfer: transfer failed (\(status)) " +
                "\(CVPixelBufferGetWidth(source))x\(CVPixelBufferGetHeight(source)) → \(width)x\(height)"
            )
            return nil
        }
        return destination
    }

    private func ensureSessionLocked(scaling: Scaling) -> VTPixelTransferSession? {
        if session == nil {
            var created: VTPixelTransferSession?
            let status = VTPixelTransferSessionCreate(
                allocator: kCFAllocatorDefault,
                pixelTransferSessionOut: &created
            )
            guard status == noErr, let created else {
                RDPLog.gfx.error("PixelBufferTransfer: session create failed (\(status))")
                return nil
            }
            session = created
            appliedScaling = nil
            // Downscaling a desktop is a resample, not a decimation — ask for the
            // better filter, it runs on the GPU either way.
            VTSessionSetProperty(
                created,
                key: kVTPixelTransferPropertyKey_DownsamplingMode,
                value: kVTDownsamplingMode_Average
            )
        }
        guard let session else { return nil }
        if appliedScaling != scaling {
            VTSessionSetProperty(
                session,
                key: kVTPixelTransferPropertyKey_ScalingMode,
                value: scaling.mode
            )
            appliedScaling = scaling
        }
        return session
    }

    /// One pool per geometry: a pool never hands out a buffer that is still
    /// retained downstream (VideoToolbox holds it until the encode completes).
    private func ensureBufferLocked(
        width: Int,
        height: Int,
        pixelFormat: OSType
    ) -> CVPixelBuffer? {
        let key = PoolKey(width: width, height: height, pixelFormat: pixelFormat)
        let pool: CVPixelBufferPool
        if let existing = pools[key] {
            pool = existing
        } else {
            let attributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var created: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(
                kCFAllocatorDefault, nil, attributes as CFDictionary, &created
            ) == kCVReturnSuccess, let created else {
                RDPLog.gfx.error("PixelBufferTransfer: pool create failed \(width)x\(height)")
                return nil
            }
            pools[key] = created
            pool = created
        }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault, pool, &buffer
        ) == kCVReturnSuccess else { return nil }
        return buffer
    }
}
