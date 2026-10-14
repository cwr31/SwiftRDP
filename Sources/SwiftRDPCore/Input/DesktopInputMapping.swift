import CoreGraphics

/// One immutable inverse of the capture layout, shared by mouse, touch and pen.
public struct DesktopInputMapping: Equatable, Sendable {
    private let hostBounds: CGRect
    private let toHost: CGAffineTransform
    private let toDesktop: CGAffineTransform

    public init(layout: DisplayContentLayout, hostBounds: CGRect) {
        precondition(layout.contentWidth > 0 && layout.contentHeight > 0)
        precondition(hostBounds.width > 0 && hostBounds.height > 0)
        let contentRect = layout.contentRect
        self.hostBounds = hostBounds
        let sx = hostBounds.width / contentRect.width
        let sy = hostBounds.height / contentRect.height
        toHost = CGAffineTransform(
            a: sx, b: 0, c: 0, d: sy,
            tx: hostBounds.minX - contentRect.minX * sx,
            ty: hostBounds.minY - contentRect.minY * sy
        )
        toDesktop = toHost.inverted()
    }

    public func hostPoint(x: Int, y: Int) -> CGPoint {
        clampedHostPoint(CGPoint(x: x, y: y).applying(toHost))
    }

    public func desktopPoint(for hostPoint: CGPoint) -> CGPoint {
        clampedHostPoint(hostPoint).applying(toDesktop)
    }

    public func hostDelta(dx: Int16, dy: Int16) -> CGVector {
        CGVector(dx: CGFloat(dx) * toHost.a, dy: CGFloat(dy) * toHost.d)
    }

    public func clampedHostPoint(_ point: CGPoint) -> CGPoint {
        // Quartz bounds are half-open; the far edge can belong to another display.
        CGPoint(
            x: min(max(point.x, hostBounds.minX), hostBounds.maxX - 1),
            y: min(max(point.y, hostBounds.minY), hostBounds.maxY - 1)
        )
    }
}
