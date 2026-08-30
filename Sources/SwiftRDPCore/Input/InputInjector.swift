import Foundation
import CoreGraphics

/// Thin facade over MouseHandler + KeyboardHandler (split) for PDU parsing.
public final class InputInjector: @unchecked Sendable {
    public let mouse: MouseHandler
    public let keyboard: KeyboardHandler
    public let touch: TouchInput

    /// Fired on mouse/keyboard input (for IdleTimeout — not every TCP byte).
    public var onUserActivity: (() -> Void)?

    public var scaleX: CGFloat {
        get { mouse.scaleX }
        set { mouse.scaleX = newValue }
    }

    public var scaleY: CGFloat {
        get { mouse.scaleY }
        set { mouse.scaleY = newValue }
    }

    public var originX: CGFloat {
        get { mouse.originX }
        set { mouse.originX = newValue }
    }

    public var originY: CGFloat {
        get { mouse.originY }
        set { mouse.originY = newValue }
    }

    public init(
        mouse: MouseHandler = MouseHandler(),
        keyboard: KeyboardHandler = KeyboardHandler(),
        touch: TouchInput = TouchInput()
    ) {
        self.mouse = mouse
        self.keyboard = keyboard
        self.touch = touch
    }

    public func handleSlowPathInput(_ payload: [UInt8]) {
        onUserActivity?()
        guard payload.count >= 4 else { return }
        let num = Int(UInt16(payload[0]) | UInt16(payload[1]) << 8)
        var o = 4
        for _ in 0..<num {
            guard o + 6 <= payload.count else { break }
            // TS_INPUT_EVENT: eventTime(4) + messageType(2)
            let msgType = UInt16(payload[o + 4]) | UInt16(payload[o + 5]) << 8
            o += 6
            switch msgType {
            case 0x0000: // INPUT_EVENT_SYNC
                guard o + 6 <= payload.count else { return }
                o += 6
                keyboard.resetModifiers()
            case 0x0004: // INPUT_EVENT_SCANCODE
                // TS_KEYBOARD_EVENT: keyboardFlags(2) + keyCode(2) + pad2Octets(2)
                guard o + 6 <= payload.count else { return }
                let flags = UInt16(payload[o]) | UInt16(payload[o + 1]) << 8
                let keyCode = UInt16(payload[o + 2]) | UInt16(payload[o + 3]) << 8
                o += 6
                keyboard.handleSlowPathScanCode(scanCode: keyCode, flags: flags)
            case 0x0005: // INPUT_EVENT_UNICODE
                // TS_UNICODE_KEYBOARD_EVENT: keyboardFlags(2) + unicodeCode(2) + pad2Octets(2)
                guard o + 6 <= payload.count else { return }
                let flags = UInt16(payload[o]) | UInt16(payload[o + 1]) << 8
                let code = UInt16(payload[o + 2]) | UInt16(payload[o + 3]) << 8
                o += 6
                keyboard.handleSlowPathUnicode(codeUnit: code, flags: flags)
            case 0x8001: // INPUT_EVENT_MOUSE
                guard o + 6 <= payload.count else { return }
                let flags = UInt16(payload[o]) | UInt16(payload[o + 1]) << 8
                let x = Int(UInt16(payload[o + 2]) | UInt16(payload[o + 3]) << 8)
                let y = Int(UInt16(payload[o + 4]) | UInt16(payload[o + 5]) << 8)
                o += 6
                mouse.handleSlowPathMouse(flags: flags, x: x, y: y)
            case 0x8002: // INPUT_EVENT_MOUSEX
                guard o + 6 <= payload.count else { return }
                let flags = UInt16(payload[o]) | UInt16(payload[o + 1]) << 8
                let x = Int(UInt16(payload[o + 2]) | UInt16(payload[o + 3]) << 8)
                let y = Int(UInt16(payload[o + 4]) | UInt16(payload[o + 5]) << 8)
                o += 6
                mouse.handleSlowPathMouseX(flags: flags, x: x, y: y)
            case 0x8004: // INPUT_EVENT_MOUSEREL
                guard o + 6 <= payload.count else { return }
                let flags = UInt16(payload[o]) | UInt16(payload[o + 1]) << 8
                let dx = Int16(bitPattern: UInt16(payload[o + 2]) | UInt16(payload[o + 3]) << 8)
                let dy = Int16(bitPattern: UInt16(payload[o + 4]) | UInt16(payload[o + 5]) << 8)
                o += 6
                mouse.injectRelative(flags: flags, dx: dx, dy: dy)
            default:
                RDPLog.input.debug("Input: unknown msgType=0x\(String(msgType, radix: 16))")
                return
            }
        }
    }

    public func handleFastPath(_ data: [UInt8]) {
        onUserActivity?()
        guard data.count >= 2 else { return }
        var o = 1
        if data[1] & 0x80 != 0 {
            guard data.count >= 3 else { return }
            o = 3
        } else {
            o = 2
        }
        // MS-RDPBCGR: if numEvents in header is 0, next byte is numberEvents.
        var eventsLeft = Int((data[0] >> 2) & 0x0F)
        if eventsLeft == 0 {
            guard o < data.count else { return }
            eventsLeft = Int(data[o])
            o += 1
        }
        while o < data.count, eventsLeft > 0 {
            let code = data[o]
            o += 1
            let eventCode = (code >> 5) & 0x7
            let flags = UInt16(code & 0x1F)
            switch eventCode {
            case 0: // SCANCODE
                guard o < data.count else { return }
                let scan = UInt16(data[o])
                o += 1
                keyboard.handleFastPathScanCode(flags: flags, scan: scan)
            case 1: // MOUSE
                guard o + 6 <= data.count else { return }
                let mflags = UInt16(data[o]) | UInt16(data[o + 1]) << 8
                let x = Int(UInt16(data[o + 2]) | UInt16(data[o + 3]) << 8)
                let y = Int(UInt16(data[o + 4]) | UInt16(data[o + 5]) << 8)
                o += 6
                mouse.handleFastPathMouse(flags: mflags, x: x, y: y)
            case 2: // MOUSEX
                guard o + 6 <= data.count else { return }
                let mflags = UInt16(data[o]) | UInt16(data[o + 1]) << 8
                let x = Int(UInt16(data[o + 2]) | UInt16(data[o + 3]) << 8)
                let y = Int(UInt16(data[o + 4]) | UInt16(data[o + 5]) << 8)
                o += 6
                mouse.handleFastPathMouseX(flags: mflags, x: x, y: y)
            case 3: // SYNC
                keyboard.resetModifiers()
            case 4: // UNICODE
                guard o + 2 <= data.count else { return }
                let codeUnit = UInt16(data[o]) | UInt16(data[o + 1]) << 8
                o += 2
                keyboard.handleFastPathUnicode(flags: flags, codeUnit: codeUnit)
            case 5: // MOUSEREL (FASTPATH_INPUT_EVENT_MOUSEREL)
                guard o + 6 <= data.count else { return }
                let mflags = UInt16(data[o]) | UInt16(data[o + 1]) << 8
                let dx = Int16(bitPattern: UInt16(data[o + 2]) | UInt16(data[o + 3]) << 8)
                let dy = Int16(bitPattern: UInt16(data[o + 4]) | UInt16(data[o + 5]) << 8)
                o += 6
                mouse.injectRelative(flags: mflags, dx: dx, dy: dy)
            case 6: // QOE_TIMESTAMP — ignore (2 or 4 bytes depending on client)
                if o + 4 <= data.count {
                    o += 4
                } else if o + 2 <= data.count {
                    o += 2
                } else {
                    return
                }
            default:
                return
            }
            eventsLeft -= 1
        }
    }
}
