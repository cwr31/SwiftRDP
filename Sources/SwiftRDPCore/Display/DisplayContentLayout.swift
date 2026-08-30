import CoreGraphics
import Foundation

/// Aspect-preserving content rect inside an RDP desktop (letterbox / pillarbox).
public struct DisplayContentLayout: Equatable, Sendable {
    public let desktopWidth: Int
    public let desktopHeight: Int
    public let contentWidth: Int
    public let contentHeight: Int
    public let offsetX: Int
    public let offsetY: Int

    public var isLetterboxed: Bool {
        contentWidth != desktopWidth || contentHeight != desktopHeight
            || offsetX != 0 || offsetY != 0
    }

    public init(
        desktopWidth: Int,
        desktopHeight: Int,
        contentWidth: Int,
        contentHeight: Int,
        offsetX: Int,
        offsetY: Int
    ) {
        self.desktopWidth = desktopWidth
        self.desktopHeight = desktopHeight
        self.contentWidth = contentWidth
        self.contentHeight = contentHeight
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    /// Largest even-sized rect of `source` aspect that fits inside the desktop.
    public static func aspectFit(
        desktopWidth: Int,
        desktopHeight: Int,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> DisplayContentLayout {
        let dw = max(desktopWidth & ~1, 2)
        let dh = max(desktopHeight & ~1, 2)
        guard sourceWidth > 0, sourceHeight > 0 else {
            return DisplayContentLayout(
                desktopWidth: dw,
                desktopHeight: dh,
                contentWidth: dw,
                contentHeight: dh,
                offsetX: 0,
                offsetY: 0
            )
        }

        let scale = min(Double(dw) / Double(sourceWidth), Double(dh) / Double(sourceHeight))
        var cw = max(Int((Double(sourceWidth) * scale).rounded()) & ~1, 2)
        var ch = max(Int((Double(sourceHeight) * scale).rounded()) & ~1, 2)
        if cw > dw { cw = dw }
        if ch > dh { ch = dh }

        // Near-full coverage → avoid 1–2px bars that only cost padding work.
        if dw - cw <= 2, dh - ch <= 2 {
            return DisplayContentLayout(
                desktopWidth: dw,
                desktopHeight: dh,
                contentWidth: dw,
                contentHeight: dh,
                offsetX: 0,
                offsetY: 0
            )
        }

        let ox = max((dw - cw) / 2, 0)
        let oy = max((dh - ch) / 2, 0)
        return DisplayContentLayout(
            desktopWidth: dw,
            desktopHeight: dh,
            contentWidth: cw,
            contentHeight: ch,
            offsetX: ox,
            offsetY: oy
        )
    }

    /// True when width/height ratios differ by more than `tolerance`.
    public static func aspectsDiffer(
        _ aw: Int,
        _ ah: Int,
        _ bw: Int,
        _ bh: Int,
        tolerance: Double = 0.02
    ) -> Bool {
        guard aw > 0, ah > 0, bw > 0, bh > 0 else { return false }
        let left = Double(aw) / Double(ah)
        let right = Double(bw) / Double(bh)
        return abs(left - right) > tolerance
    }

    /// Physical-panel capture into an RDP desktop.
    ///
    /// Desktop / surface / capture / mouse all stay panel-native pixels. Capture
    /// must not be padded: SCKit `scalesToFit` preserves the aspect ratio and
    /// centers, so a padded request would shift the image and the wire crop would
    /// lose the bottom rows. H.264 handles non-multiple-of-16 sizes with the SPS
    /// cropping window.
    /// Callers must adopt the returned layout desktop size.
    public static func physicalMirrorPlan(
        desktopWidth: Int,
        desktopHeight: Int,
        panelWidth: Int,
        panelHeight: Int
    ) -> (captureWidth: Int, captureHeight: Int, layout: DisplayContentLayout) {
        let pw = max(panelWidth & ~1, 2)
        let ph = max(panelHeight & ~1, 2)
        _ = desktopWidth
        _ = desktopHeight
        return (
            pw,
            ph,
            DisplayContentLayout(
                desktopWidth: pw,
                desktopHeight: ph,
                contentWidth: pw,
                contentHeight: ph,
                offsetX: 0,
                offsetY: 0
            )
        )
    }
}
