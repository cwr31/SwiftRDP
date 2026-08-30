import Foundation
import CoreGraphics
import QuartzCore

/// Injects mouse events from RDP slow-path or fast-path input.
/// `MouseHandler` field surface ( / ).
public final class MouseHandler: @unchecked Sendable {
    /// Live prefs — Settings updates these without restarting the server.
    private static let settingsLock = NSLock()
    nonisolated(unsafe) private static var scrollSpeedValue = 1.0
    nonisolated(unsafe) private static var invertScrollValue = false

    public static var scrollSpeed: Double {
        get {
            settingsLock.lock()
            defer { settingsLock.unlock() }
            return scrollSpeedValue
        }
        set {
            settingsLock.lock()
            scrollSpeedValue = newValue
            settingsLock.unlock()
        }
    }

    public static var invertScroll: Bool {
        get {
            settingsLock.lock()
            defer { settingsLock.unlock() }
            return invertScrollValue
        }
        set {
            settingsLock.lock()
            invertScrollValue = newValue
            settingsLock.unlock()
        }
    }

    /// `buttonsDown` bitmask (PTRFLAGS button bits while held).
    private var buttonsDown: UInt16 = 0
    public var scaleX: CGFloat = 1
    public var scaleY: CGFloat = 1
    public var letterboxOffsetX: CGFloat = 0
    public var letterboxOffsetY: CGFloat = 0
    /// RDP content rect after letterbox, in desktop coordinates.
    public var contentWidth: CGFloat = 0
    public var contentHeight: CGFloat = 0
    /// Host display extent, in Quartz coordinates, for relative-pointer clamping.
    public var captureAreaWidth: CGFloat = 0
    public var captureAreaHeight: CGFloat = 0
    /// `screenOriginX/Y` — `CGDisplayBounds.origin`.
    public var originX: CGFloat = 0
    public var originY: CGFloat = 0

    private var lastClickTime: CFTimeInterval = 0
    private var lastClickPos: CGPoint = .zero
    private var lastClickButton: Int = -1
    private var clickCount: Int = 0
    /// init `0.5`.
    public var doubleClickInterval: CFTimeInterval = 0.5
    /// init `5.0`.
    public var doubleClickRadius: CGFloat = 5.0

    private var lastX: Int = 0
    private var lastY: Int = 0
    private var loggedEvents = 0
    /// Coalesce pure mouse-move CGEvents (~125 Hz) — RDP still tracks lastX/Y.
    private var lastMoveInjectTime: CFTimeInterval = 0
    private static let moveCoalesceInterval: CFTimeInterval = 0.008

    /// Called with RDP desktop coords after each injected event.
    public var onPointerMoved: ((Int, Int) -> Void)?

    public init() {}

    /// Remap cached RDP coords after desktop resize / mode flip (wheel uses lastX/Y).
    public func noteDesktopGeometryChanged(
        oldDesktopWidth: Int,
        oldDesktopHeight: Int,
        newDesktopWidth: Int,
        newDesktopHeight: Int
    ) {
        guard oldDesktopWidth > 0, oldDesktopHeight > 0,
              newDesktopWidth > 0, newDesktopHeight > 0 else { return }
        guard oldDesktopWidth != newDesktopWidth || oldDesktopHeight != newDesktopHeight else { return }
        let nx = lastX * newDesktopWidth / oldDesktopWidth
        let ny = lastY * newDesktopHeight / oldDesktopHeight
        lastX = min(max(nx, 0), max(newDesktopWidth - 1, 0))
        lastY = min(max(ny, 0), max(newDesktopHeight - 1, 0))
    }

    public func injectMouse(flags: UInt16, x: Int, y: Int) {
        let down = (flags & 0x8000) != 0
        let button1 = (flags & 0x1000) != 0
        let button2 = (flags & 0x2000) != 0
        let button3 = (flags & 0x4000) != 0
        let move = (flags & 0x0800) != 0
        let wheel = (flags & 0x0200) != 0
        let hwheel = (flags & 0x0400) != 0

        // MS-RDPBCGR: xPos/yPos SHOULD be ignored for wheel events; clients often
        // send (0,0). Scroll at the last known pointer position instead.
        let rdpX: Int
        let rdpY: Int
        if wheel || hwheel {
            rdpX = lastX
            rdpY = lastY
        } else {
            rdpX = x
            rdpY = y
            lastX = x
            lastY = y
        }

        let pt = absolutePoint(x: rdpX, y: rdpY)

        let isButtonOrWheel = button1 || button2 || button3 || wheel || hwheel
        if isButtonOrWheel || loggedEvents < 4 {
            if !isButtonOrWheel { loggedEvents += 1 }
            RDPLog.input.info(
                "Mouse: rdp=(\(rdpX),\(rdpY)) host=(\(Int(pt.x)),\(Int(pt.y))) flags=0x\(String(flags, radix: 16)) move=\(move) b1=\(button1) down=\(down)"
            )
        }

        if wheel || hwheel {
            // MS-RDPBCGR: WheelRotationMask 0x01FF is a 9-bit signed field;
            // PTRFLAGS_WHEEL_NEGATIVE (0x0100) is the sign bit — sign-extend before use.
            var rotation = Int32(flags & 0x01FF)
            if rotation & 0x0100 != 0 {
                rotation -= 0x0200
            }
            if Self.invertScroll {
                rotation = -rotation
            }
            let speed = max(Self.scrollSpeed, 0.05)
            let scaled = Int32((Double(rotation) * speed).rounded())
            RDPLog.input.info(
                "Mouse: \(hwheel ? "h" : "")wheel rotation=\(rotation) scaled=\(scaled) speed=\(String(format: "%.2f", speed)) at host=(\(Int(pt.x)),\(Int(pt.y)))"
            )
            // Scroll under the RDP pointer — otherwise the host cursor may be elsewhere.
            if let moveEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: pt,
                mouseButton: .left
            ) {
                moveEvent.post(tap: .cghidEventTap)
            }
            // Windows WHEEL_DELTA is 120 per notch. Prefer line ticks; keep a pixel
            // remainder so smooth/trackpad-style deltas still move something.
            let lines = scaled / 120
            let pixelRemainder = (scaled % 120) * 2
            if hwheel {
                if lines != 0,
                   let e = CGEvent(
                    scrollWheelEvent2Source: nil,
                    units: .line,
                    wheelCount: 2,
                    wheel1: 0,
                    wheel2: lines,
                    wheel3: 0
                   ) {
                    e.post(tap: .cghidEventTap)
                }
                if pixelRemainder != 0,
                   let e = CGEvent(
                    scrollWheelEvent2Source: nil,
                    units: .pixel,
                    wheelCount: 2,
                    wheel1: 0,
                    wheel2: pixelRemainder,
                    wheel3: 0
                   ) {
                    e.post(tap: .cghidEventTap)
                }
            } else {
                if lines != 0,
                   let e = CGEvent(
                    scrollWheelEvent2Source: nil,
                    units: .line,
                    wheelCount: 1,
                    wheel1: lines,
                    wheel2: 0,
                    wheel3: 0
                   ) {
                    e.post(tap: .cghidEventTap)
                }
                if pixelRemainder != 0,
                   let e = CGEvent(
                    scrollWheelEvent2Source: nil,
                    units: .pixel,
                    wheelCount: 1,
                    wheel1: pixelRemainder,
                    wheel2: 0,
                    wheel3: 0
                   ) {
                    e.post(tap: .cghidEventTap)
                }
            }
            onPointerMoved?(rdpX, rdpY)
            return
        }

        if button1 {
            handleButton(button: 0, bit: 0x1000, down: down, at: pt)
        } else if button2 {
            handleButton(button: 1, bit: 0x2000, down: down, at: pt)
        } else if button3 {
            handleButton(button: 2, bit: 0x4000, down: down, at: pt)
        } else if move || (!button1 && !button2 && !button3) {
            // move: drag if buttonsDown set.
            let type: CGEventType
            let btn: CGMouseButton
            if buttonsDown & 0x1000 != 0 {
                type = .leftMouseDragged
                btn = .left
            } else if buttonsDown & 0x2000 != 0 {
                type = .rightMouseDragged
                btn = .right
            } else if buttonsDown & 0x4000 != 0 {
                type = .otherMouseDragged
                btn = .center
            } else {
                type = .mouseMoved
                btn = .left
                // Pure hover moves: coalesce CGEvent flood; still update remote cursor.
                let now = CACurrentMediaTime()
                if now - lastMoveInjectTime < Self.moveCoalesceInterval {
                    onPointerMoved?(rdpX, rdpY)
                    return
                }
                lastMoveInjectTime = now
            }
            if let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pt, mouseButton: btn) {
                e.setIntegerValueField(.mouseEventClickState, value: Int64(max(clickCount, 1)))
                e.post(tap: .cghidEventTap)
            }
        }

        onPointerMoved?(rdpX, rdpY)
    }

    private func handleButton(button: Int, bit: UInt16, down: Bool, at pt: CGPoint) {
        if down {
            buttonsDown |= bit
            let now = CACurrentMediaTime()
            let dist = hypot(pt.x - lastClickPos.x, pt.y - lastClickPos.y)
            if button == lastClickButton,
               now - lastClickTime < doubleClickInterval,
               dist < doubleClickRadius {
                clickCount += 1
            } else {
                clickCount = 1
            }
            lastClickTime = now
            lastClickPos = pt
            lastClickButton = button
        } else {
            buttonsDown &= ~bit
        }

        let mouseButton: CGMouseButton
        let type: CGEventType
        switch button {
        case 1:
            mouseButton = .right
            type = down ? .rightMouseDown : .rightMouseUp
        case 2:
            mouseButton = .center
            type = down ? .otherMouseDown : .otherMouseUp
        default:
            mouseButton = .left
            type = down ? .leftMouseDown : .leftMouseUp
        }
        if let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pt, mouseButton: mouseButton) {
            e.setIntegerValueField(.mouseEventClickState, value: Int64(max(clickCount, 1)))
            e.post(tap: .cghidEventTap)
        }
    }

    public func handleFastPathMouse(flags: UInt16, x: Int, y: Int) {
        injectMouse(flags: flags, x: x, y: y)
    }

    public func handleSlowPathMouse(flags: UInt16, x: Int, y: Int) {
        injectMouse(flags: flags, x: x, y: y)
    }

    /// Extended mouse buttons (MS-RDPBCGR TS_POINTERX_EVENT / Fast-Path MOUSEX).
    /// PTRXFLAGS_BUTTON1 = 0x0001 (XBUTTON1), BUTTON2 = 0x0002 (XBUTTON2), DOWN = 0x8000.
    public func handleFastPathMouseX(flags: UInt16, x: Int, y: Int) {
        injectMouseX(flags: flags, x: x, y: y)
    }

    public func handleSlowPathMouseX(flags: UInt16, x: Int, y: Int) {
        injectMouseX(flags: flags, x: x, y: y)
    }

    private func injectMouseX(flags: UInt16, x: Int, y: Int) {
        let down = (flags & 0x8000) != 0
        let button1 = (flags & 0x0001) != 0
        let button2 = (flags & 0x0002) != 0
        guard button1 || button2 else { return }

        lastX = x
        lastY = y
        let pt = absolutePoint(x: x, y: y)

        // Map XBUTTON1/2 to Quartz other-mouse buttons 3 and 4 (0-based buttonNumber).
        let buttonNumber: Int64 = button1 ? 3 : 4
        let bit: UInt16 = button1 ? 0x0001 : 0x0002
        if down {
            buttonsDown |= bit
        } else {
            buttonsDown &= ~bit
        }
        let type: CGEventType = down ? .otherMouseDown : .otherMouseUp
        if let e = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: pt,
            mouseButton: .center
        ) {
            e.setIntegerValueField(.mouseEventButtonNumber, value: buttonNumber)
            e.post(tap: .cghidEventTap)
        }
        onPointerMoved?(x, y)
    }

    private func absolutePoint(x: Int, y: Int) -> CGPoint {
        let rawX = max(CGFloat(x) - letterboxOffsetX, 0)
        let rawY = max(CGFloat(y) - letterboxOffsetY, 0)
        let contentX = contentWidth > 0 ? min(rawX, contentWidth) : rawX
        let contentY = contentHeight > 0 ? min(rawY, contentHeight) : rawY
        return CGPoint(
            x: originX + contentX * scaleX,
            y: originY + contentY * scaleY
        )
    }

    /// Relative mouse (MS-RDPBCGR TS_RELPOINTER_EVENT / Fast-Path MOUSEREL).
    public func injectRelative(flags: UInt16, dx: Int16, dy: Int16) {
        let move = (flags & 0x0800) != 0
        let down = (flags & 0x8000) != 0
        let button1 = (flags & 0x1000) != 0
        let button2 = (flags & 0x2000) != 0
        let button3 = (flags & 0x4000) != 0

        let current = CGEvent(source: nil)?.location ?? CGPoint(x: originX, y: originY)
        // RDP yDelta: negative = up. Quartz Y grows downward — flip.
        let scaledDX = CGFloat(dx) * scaleX
        let scaledDY = CGFloat(-dy) * scaleY
        var pt = CGPoint(x: current.x + scaledDX, y: current.y + scaledDY)

        // Keep inside the capture area when known.
        if captureAreaWidth > 0, captureAreaHeight > 0 {
            let minX = originX
            let minY = originY
            let maxX = originX + captureAreaWidth - 1
            let maxY = originY + captureAreaHeight - 1
            pt.x = min(max(pt.x, minX), maxX)
            pt.y = min(max(pt.y, minY), maxY)
        }

        if button1 {
            handleButton(button: 0, bit: 0x1000, down: down, at: pt)
        } else if button2 {
            handleButton(button: 1, bit: 0x2000, down: down, at: pt)
        } else if button3 {
            handleButton(button: 2, bit: 0x4000, down: down, at: pt)
        } else if move || (!button1 && !button2 && !button3) {
            let type: CGEventType
            let btn: CGMouseButton
            if buttonsDown & 0x1000 != 0 {
                type = .leftMouseDragged
                btn = .left
            } else if buttonsDown & 0x2000 != 0 {
                type = .rightMouseDragged
                btn = .right
            } else if buttonsDown & 0x4000 != 0 {
                type = .otherMouseDragged
                btn = .center
            } else {
                type = .mouseMoved
                btn = .left
            }
            if let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pt, mouseButton: btn) {
                e.setIntegerValueField(.mouseEventDeltaX, value: Int64(scaledDX.rounded()))
                e.setIntegerValueField(.mouseEventDeltaY, value: Int64(scaledDY.rounded()))
                e.post(tap: .cghidEventTap)
            }
        }

        // Approximate RDP desktop coords for cursor shadow.
        let rdpX = Int(((pt.x - originX) / max(scaleX, 0.0001) + letterboxOffsetX).rounded())
        let rdpY = Int(((pt.y - originY) / max(scaleY, 0.0001) + letterboxOffsetY).rounded())
        lastX = rdpX
        lastY = rdpY
        onPointerMoved?(rdpX, rdpY)
    }
}
