import AppKit
import Foundation

private struct RenderedCursor: Hashable {
    let hotspotX: Int
    let hotspotY: Int
    let width: Int
    let height: Int
    let xorMask: [UInt8]
    let andMask: [UInt8]
}

/// Captures the cursor currently displayed by WindowServer and sends it through
/// the RDP pointer cache independently of the framebuffer.
public final class CursorTracker: @unchecked Sendable {
    private static let minRefreshIntervalNs: UInt64 = 33_333_333
    private static let refreshRequestDelayNs: UInt64 = 2_000_000
    private static let pointerCacheCapacity: UInt16 = 25

    private let stateLock = NSLock()
    private let refreshQueue = DispatchQueue(
        label: "com.swiftrdp.cursor-refresh",
        qos: .userInitiated
    )
    private var refreshTimer: DispatchSourceTimer?
    private var refreshScheduled = false
    private var pendingForceRefresh = false
    private var lastRefreshNs: UInt64 = 0
    private var outputSuppressed = false
    private var pointerScale: Double
    private var maximumDimension: Int
    private var cacheByCursor: [RenderedCursor: UInt16] = [:]
    private var cursorsByCacheIndex: [UInt16: RenderedCursor] = [:]
    private var nextCacheIndex: UInt16 = 0
    private var activeCacheIndex: UInt16?

    public var onSendFastPath: (([UInt8]) -> Void)?

    public init(scale: Double = 2.0, maximumDimension: Int = 32) {
        self.pointerScale = Self.normalizedScale(scale)
        self.maximumDimension = Self.normalizedMaximumDimension(maximumDimension)
    }

    /// Re-render the next observed system cursor at the new negotiated scale.
    public func setScale(_ scale: Double) {
        let scale = Self.normalizedScale(scale)
        stateLock.lock()
        guard scale != pointerScale else {
            stateLock.unlock()
            return
        }
        pointerScale = scale
        invalidateCacheLocked()
        stateLock.unlock()
        requestRefresh(force: true)
        RDPLog.input.info("Cursor: pointer scale changed to \(String(format: "%.2f", scale))x")
    }

    /// Apply the pointer-size ceiling negotiated in Confirm Active.
    public func setMaximumDimension(_ maximumDimension: Int) {
        let maximumDimension = Self.normalizedMaximumDimension(maximumDimension)
        stateLock.lock()
        guard maximumDimension != self.maximumDimension else {
            stateLock.unlock()
            return
        }
        self.maximumDimension = maximumDimension
        invalidateCacheLocked()
        stateLock.unlock()
        requestRefresh(force: true)
        RDPLog.input.info("Cursor: maximum pointer dimension changed to \(maximumDimension)")
    }

    /// Start cursor observation independently from desktop capture.
    public func start() {
        stateLock.lock()
        guard refreshTimer == nil else {
            stateLock.unlock()
            return
        }
        pendingForceRefresh = true
        let timer = DispatchSource.makeTimerSource(queue: refreshQueue)
        refreshTimer = timer
        stateLock.unlock()

        timer.setEventHandler { [weak self] in
            self?.refreshCurrentCursor()
        }
        timer.schedule(
            deadline: .now() + .milliseconds(250),
            repeating: .milliseconds(250),
            leeway: .milliseconds(50)
        )
        timer.resume()
        requestRefresh(force: true)
    }

    /// Stop cursor observation with the desktop session.
    public func stop() {
        stateLock.lock()
        let timer = refreshTimer
        refreshTimer = nil
        refreshScheduled = false
        pendingForceRefresh = false
        outputSuppressed = true
        stateLock.unlock()

        timer?.setEventHandler {}
        timer?.cancel()
    }

    /// Pause pointer updates while the client suppresses display output.
    public func setOutputSuppressed(_ suppressed: Bool) {
        stateLock.lock()
        guard outputSuppressed != suppressed else {
            stateLock.unlock()
            return
        }
        outputSuppressed = suppressed
        lastRefreshNs = 0
        if suppressed {
            pendingForceRefresh = false
        } else {
            pendingForceRefresh = true
            activeCacheIndex = nil
        }
        stateLock.unlock()

        if !suppressed {
            requestRefresh(force: true)
        }
    }

    /// Request a coalesced cursor-shape refresh after host pointer movement.
    public func requestRefresh() {
        requestRefresh(force: false)
    }

    private func requestRefresh(force: Bool) {
        stateLock.lock()
        guard refreshTimer != nil, !outputSuppressed else {
            stateLock.unlock()
            return
        }
        if force {
            pendingForceRefresh = true
        }
        guard !refreshScheduled else {
            stateLock.unlock()
            return
        }

        let now = DispatchTime.now().uptimeNanoseconds
        let remaining = lastRefreshNs == 0
            ? 0
            : Self.minRefreshIntervalNs - min(now &- lastRefreshNs, Self.minRefreshIntervalNs)
        let delayNs = max(Self.refreshRequestDelayNs, remaining)
        refreshScheduled = true
        stateLock.unlock()

        refreshQueue.asyncAfter(
            deadline: .now() + .nanoseconds(Int(delayNs))
        ) { [weak self] in
            self?.refreshCurrentCursor()
        }
    }

    private func refreshCurrentCursor() {
        stateLock.lock()
        refreshScheduled = false
        guard refreshTimer != nil, !outputSuppressed else {
            stateLock.unlock()
            return
        }

        let force = pendingForceRefresh
        pendingForceRefresh = false
        let now = DispatchTime.now().uptimeNanoseconds
        if !force,
           lastRefreshNs != 0,
           now &- lastRefreshNs < Self.minRefreshIntervalNs
        {
            stateLock.unlock()
            return
        }
        lastRefreshNs = now
        stateLock.unlock()

        let cursor = NSCursor.currentSystem ?? NSCursor.arrow
        publish(cursor: cursor)
    }

    /// Testable entry point for publishing a concrete system cursor.
    @discardableResult
    func publish(cursor: NSCursor) -> Bool {
        stateLock.lock()
        let scale = pointerScale
        let maximumDimension = maximumDimension
        let suppressed = outputSuppressed
        stateLock.unlock()

        guard !suppressed else { return false }
        guard let rendered = Self.render(
            cursor,
            scale: scale,
            maximumDimension: maximumDimension
        ) else {
            return false
        }

        guard let send = onSendFastPath else { return false }

        var updates: [[UInt8]] = []
        var cacheIndex: UInt16 = 0
        var isNew = false
        var shouldSelect = false

        stateLock.lock()
        // A live settings change invalidates the render produced above. The next
        // refresh will render again at the new settings.
        guard !outputSuppressed,
              scale == pointerScale,
              maximumDimension == self.maximumDimension
        else {
            stateLock.unlock()
            return false
        }

        if let existing = cacheByCursor[rendered] {
            cacheIndex = existing
        } else {
            cacheIndex = nextCacheIndex
            nextCacheIndex = (nextCacheIndex + 1) % Self.pointerCacheCapacity
            if let evicted = cursorsByCacheIndex.updateValue(rendered, forKey: cacheIndex) {
                cacheByCursor.removeValue(forKey: evicted)
            }
            cacheByCursor[rendered] = cacheIndex
            isNew = true
        }

        if isNew || activeCacheIndex != cacheIndex {
            activeCacheIndex = cacheIndex
            shouldSelect = true
        }
        stateLock.unlock()

        if isNew {
            updates.append(
                FastPathOutput.pointer(
                    cacheIndex: cacheIndex,
                    hotspotX: rendered.hotspotX,
                    hotspotY: rendered.hotspotY,
                    width: rendered.width,
                    height: rendered.height,
                    xorMask: rendered.xorMask,
                    andMask: rendered.andMask
                )
            )
        }
        if shouldSelect {
            updates.append(FastPathOutput.cachedPointer(cacheIndex: cacheIndex))
        }

        for update in updates {
            send(update)
        }
        if isNew || shouldSelect {
            RDPLog.input.info(
                "Cursor: \(isNew ? "published" : "selected") cache=\(cacheIndex) " +
                "size=\(rendered.width)x\(rendered.height) hotspot=\(rendered.hotspotX),\(rendered.hotspotY)"
            )
        }
        return isNew || shouldSelect
    }

    private func invalidateCacheLocked() {
        cacheByCursor.removeAll(keepingCapacity: true)
        cursorsByCacheIndex.removeAll(keepingCapacity: true)
        nextCacheIndex = 0
        activeCacheIndex = nil
    }

    deinit {
        stop()
    }

    public static func normalizedScale(_ scale: Double) -> Double {
        min(max(scale.isFinite ? scale : 2.0, 1.0), 3.0)
    }

    static func normalizedMaximumDimension(_ value: Int) -> Int {
        value >= 96 ? 96 : 32
    }

    static func scaledDimensions(
        for size: CGSize,
        scale: Double,
        maximumDimension: Int = 96
    ) -> (width: Int, height: Int) {
        let scale = normalizedScale(scale)
        let maximumDimension = normalizedMaximumDimension(maximumDimension)
        func dimension(_ value: CGFloat) -> Int {
            var pixels = min(max(1, Int((value * scale).rounded())), maximumDimension)
            if pixels % 2 != 0 { pixels += 1 }
            return min(pixels, maximumDimension)
        }
        return (dimension(size.width), dimension(size.height))
    }

    // MARK: - Render NSCursor → RDP 24-bpp XOR + 1-bpp AND

    private static func render(
        _ cursor: NSCursor,
        scale: Double,
        maximumDimension: Int
    ) -> RenderedCursor? {
        let image = cursor.image
        let dimensions = scaledDimensions(
            for: image.size,
            scale: scale,
            maximumDimension: maximumDimension
        )
        let width = dimensions.width
        let height = dimensions.height

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            NSColor.clear.setFill()
            NSBezierPath.fill(NSRect(x: 0, y: 0, width: width, height: height))
            image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let pixels = rep.bitmapData else { return nil }
        let xorStride = (width * 3 + 1) & ~1
        let andStride = ((width + 15) / 16) * 2
        var xorMask = [UInt8](repeating: 0, count: xorStride * height)
        var andMask = [UInt8](repeating: 0xFF, count: andStride * height)

        for y in 0..<height {
            let destinationY = height - 1 - y
            for x in 0..<width {
                let sourceIndex = (y * width + x) * 4
                let destinationIndex = destinationY * xorStride + x * 3
                let alpha = pixels[sourceIndex + 3]
                xorMask[destinationIndex] = alpha < 128 ? 0 : pixels[sourceIndex + 2]
                xorMask[destinationIndex + 1] = alpha < 128 ? 0 : pixels[sourceIndex + 1]
                xorMask[destinationIndex + 2] = alpha < 128 ? 0 : pixels[sourceIndex]

                let maskIndex = destinationY * andStride + x / 8
                let bit = UInt8(0x80 >> (x % 8))
                if alpha < 128 {
                    andMask[maskIndex] |= bit
                } else {
                    andMask[maskIndex] &= ~bit
                }
            }
        }

        let hotspot = cursor.hotSpot
        return RenderedCursor(
            hotspotX: min(max(0, Int((hotspot.x * scale).rounded())), width - 1),
            hotspotY: min(max(0, Int((hotspot.y * scale).rounded())), height - 1),
            width: width,
            height: height,
            xorMask: xorMask,
            andMask: andMask
        )
    }
}
