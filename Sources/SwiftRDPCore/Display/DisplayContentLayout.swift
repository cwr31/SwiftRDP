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

    public var contentRect: CGRect {
        CGRect(x: offsetX, y: offsetY, width: contentWidth, height: contentHeight)
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
        precondition(sourceWidth > 0 && sourceHeight > 0)
        let scale = min(Double(dw) / Double(sourceWidth), Double(dh) / Double(sourceHeight))
        var cw = max(Int((Double(sourceWidth) * scale).rounded()) & ~1, 2)
        var ch = max(Int((Double(sourceHeight) * scale).rounded()) & ~1, 2)
        if cw > dw { cw = dw }
        if ch > dh { ch = dh }

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
}
