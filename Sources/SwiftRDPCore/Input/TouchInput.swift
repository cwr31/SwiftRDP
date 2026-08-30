import Foundation
import CoreGraphics

/// [MS-RDPEI] touch / pen input — `TouchInput` on DVC `Microsoft::Windows::RDS::Input`.
public final class TouchInput: @unchecked Sendable {
    public static let dvcName = "Microsoft::Windows::RDS::Input"

    public var send: (([UInt8]) -> Void)?
    public var onUserActivity: (() -> Void)?

    /// Coordinate scale into host screen space (same as mouse).
    public var scaleX: CGFloat = 1
    public var scaleY: CGFloat = 1
    public var originX: CGFloat = 0
    public var originY: CGFloat = 0
    public var letterboxOffsetX: CGFloat = 0
    public var letterboxOffsetY: CGFloat = 0
    public var contentWidth: CGFloat = 0
    public var contentHeight: CGFloat = 0

    private var readySent = false
    private var activeContacts: [UInt8: CGPoint] = [:]

    public init() {}

    public func attach(send: @escaping ([UInt8]) -> Void) {
        self.send = send
        readySent = false
        sendSCReady()
    }

    public func handle(_ data: [UInt8]) {
        onUserActivity?()
        guard data.count >= 6 else {
            RDPLog.input.info("TouchInput: PDU too short (\(data.count)B)")
            return
        }
        let eventId = UInt16(data[0]) | UInt16(data[1]) << 8
        let pduLength = Int(UInt32(data[2]) | UInt32(data[3]) << 8 | UInt32(data[4]) << 16 | UInt32(data[5]) << 24)
        if pduLength > 0, data.count < pduLength {
            RDPLog.input.debug("TouchInput: truncated eventId=\(eventId) have=\(data.count) expect=\(pduLength)")
        }

        switch eventId {
        case RDPEI.eventCSReady:
            handleCSReady(data)
        case RDPEI.eventTouch:
            handleTouchEvent(data)
        case RDPEI.eventPen:
            handlePenEvent(data)
        case RDPEI.eventDismissHovering:
            RDPLog.input.info("TouchInput: dismiss hovering contact")
            activeContacts.removeAll()
        case RDPEI.eventSuspendTouch:
            RDPLog.input.debug("TouchInput: SUSPEND_TOUCH")
        case RDPEI.eventResumeTouch:
            RDPLog.input.debug("TouchInput: RESUME_TOUCH")
        default:
            RDPLog.input.info("TouchInput: unknown eventId=\(eventId)")
        }
    }

    /// Slow-path / fast-path hooks kept for InputInjector parity (RDPEI is DVC-primary).
    public func handleSlowPathTouch(_ payload: [UInt8]) {
        handle(payload)
    }

    public func handleFastPathTouch(_ data: [UInt8]) {
        handle(data)
    }

    // MARK: - Handshake

    private func sendSCReady() {
        // RDPINPUT_HEADER + protocolVersion(4) — "sent SC_READY (v1.0.0)"
        var pdu: [UInt8] = []
        let bodyLen = 10 // header(6) + version(4)
        pdu.appendU16(RDPEI.eventSCReady)
        pdu.appendU32(UInt32(bodyLen))
        pdu.appendU32(RDPEI.protocolV100)
        if let send {
            send(pdu)
            readySent = true
            RDPLog.input.info("TouchInput: sent SC_READY (v1.0.0)")
        } else {
            RDPLog.input.info("TouchInput: SC_READY send failed: no send path")
            RDPLog.input.info("TouchInput: channel create failed: no send path")
        }
    }

    private func handleCSReady(_ data: [UInt8]) {
        // header(6) + flags(4) + protocolVersion(4) + maxTouchContacts(2) = 16
        guard data.count >= 16 else {
            RDPLog.input.info("TouchInput: CS_READY too short (\(data.count))")
            return
        }
        let version = UInt32(data[10]) | UInt32(data[11]) << 8 | UInt32(data[12]) << 16 | UInt32(data[13]) << 24
        let major = (version >> 16) & 0xFFFF
        let minor = (version >> 8) & 0xFF
        let patch = version & 0xFF
        RDPLog.input.info("TouchInput: CS_READY version=\(major).\(minor).\(patch)")
        if !readySent {
            sendSCReady()
        }
    }

    // MARK: - Touch frames

    private func handleTouchEvent(_ data: [UInt8]) {
        // header(6) + encodeTime(4) + frameCount(2) + frames…
        guard data.count >= 12 else { return }
        var o = 10 // skip header + encodeTime start; encodeTime at 6
        let frameCount = Int(UInt16(data[10]) | UInt16(data[11]) << 8)
        o = 12
        for _ in 0..<frameCount {
            guard o + 10 <= data.count else { break }
            // RDPINPUT_TOUCH_FRAME: contactCount(2) + frameOffset(8) + contacts
            let contactCount = Int(UInt16(data[o]) | UInt16(data[o + 1]) << 8)
            o += 2 + 8
            for _ in 0..<contactCount {
                guard o + 13 <= data.count else { return }
                let contactId = data[o]
                o += 1
                // fieldsPresent (1) — skip optional fields based on mask after core
                let fieldsPresent = data[o]
                o += 1
                let x = Int16(bitPattern: UInt16(data[o]) | UInt16(data[o + 1]) << 8)
                let y = Int16(bitPattern: UInt16(data[o + 2]) | UInt16(data[o + 3]) << 8)
                o += 4
                let contactFlags = UInt32(data[o]) | UInt32(data[o + 1]) << 8
                    | UInt32(data[o + 2]) << 16 | UInt32(data[o + 3]) << 24
                o += 4
                // Optional: contactRect(8), orientation(2), pressure(4)
                if fieldsPresent & 0x01 != 0 { o += 8 }
                if fieldsPresent & 0x02 != 0 { o += 2 }
                if fieldsPresent & 0x04 != 0 { o += 4 }

                RDPLog.input.info("TouchInput: contact x=\(x) y=\(y) id=\(contactId) flags=0x\(String(contactFlags, radix: 16))")
                injectContact(id: contactId, x: Int(x), y: Int(y), flags: contactFlags)
            }
        }
    }

    private func injectContact(id: UInt8, x: Int, y: Int, flags: UInt32) {
        let pt = absolutePoint(x: x, y: y)
        let down = (flags & RDPEI.contactDown) != 0
        let up = (flags & RDPEI.contactUp) != 0
        let update = (flags & RDPEI.contactUpdate) != 0
        let canceled = (flags & RDPEI.contactCanceled) != 0

        if canceled {
            if let last = activeContacts.removeValue(forKey: id),
               let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: last, mouseButton: .left) {
                e.post(tap: .cghidEventTap)
            }
            return
        }

        if down {
            activeContacts[id] = pt
            if let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left) {
                e.post(tap: .cghidEventTap)
            }
        } else if up {
            activeContacts.removeValue(forKey: id)
            if let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left) {
                e.post(tap: .cghidEventTap)
            }
        } else if update || activeContacts[id] != nil {
            activeContacts[id] = pt
            if let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: pt, mouseButton: .left) {
                e.post(tap: .cghidEventTap)
            }
        } else {
            if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left) {
                e.post(tap: .cghidEventTap)
            }
        }
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

    // MARK: - Pen frames (MS-RDPEI RDPINPUT_PEN_EVENT)

    private func handlePenEvent(_ data: [UInt8]) {
        guard data.count >= 12 else { return }
        let frameCount = Int(UInt16(data[10]) | UInt16(data[11]) << 8)
        var o = 12
        for _ in 0..<frameCount {
            guard o + 10 <= data.count else { break }
            let contactCount = Int(UInt16(data[o]) | UInt16(data[o + 1]) << 8)
            o += 2 + 8
            for _ in 0..<contactCount {
                guard o + 13 <= data.count else { return }
                let contactId = data[o]
                o += 1
                let fieldsPresent = data[o]
                o += 1
                let x = Int16(bitPattern: UInt16(data[o]) | UInt16(data[o + 1]) << 8)
                let y = Int16(bitPattern: UInt16(data[o + 2]) | UInt16(data[o + 3]) << 8)
                o += 4
                let contactFlags = UInt32(data[o]) | UInt32(data[o + 1]) << 8
                    | UInt32(data[o + 2]) << 16 | UInt32(data[o + 3]) << 24
                o += 4
                if fieldsPresent & 0x01 != 0 { o += 8 }
                if fieldsPresent & 0x02 != 0 { o += 2 }
                var pressure: UInt32 = 0
                if fieldsPresent & 0x04 != 0 {
                    guard o + 4 <= data.count else { return }
                    pressure = UInt32(data[o]) | UInt32(data[o + 1]) << 8
                        | UInt32(data[o + 2]) << 16 | UInt32(data[o + 3]) << 24
                    o += 4
                }
                if fieldsPresent & 0x08 != 0 { o += 2 }
                if fieldsPresent & 0x10 != 0 { o += 2 }
                if fieldsPresent & 0x20 != 0 { o += 2 }

                let inverted = (contactFlags & RDPEI.penInverted) != 0
                RDPLog.input.info(
                    "TouchInput: pen x=\(x) y=\(y) id=\(contactId) flags=0x\(String(contactFlags, radix: 16)) " +
                    "pressure=\(pressure) inverted=\(inverted)"
                )
                injectPen(
                    id: contactId,
                    x: Int(x),
                    y: Int(y),
                    flags: contactFlags,
                    pressure: pressure,
                    inverted: inverted
                )
            }
        }
    }

    private func injectPen(
        id: UInt8,
        x: Int,
        y: Int,
        flags: UInt32,
        pressure: UInt32,
        inverted: Bool
    ) {
        let pt = absolutePoint(x: x, y: y)
        let down = (flags & RDPEI.contactDown) != 0
        let up = (flags & RDPEI.contactUp) != 0
        let update = (flags & RDPEI.contactUpdate) != 0
        let canceled = (flags & RDPEI.contactCanceled) != 0
        let mouseButton: CGMouseButton = inverted ? .right : .left
        let downType: CGEventType = inverted ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = inverted ? .rightMouseUp : .leftMouseUp
        let dragType: CGEventType = inverted ? .rightMouseDragged : .leftMouseDragged
        let pressureNorm = pressure > 0 ? min(Double(pressure) / 1024.0, 1.0) : 1.0

        if canceled {
            if let last = activeContacts.removeValue(forKey: id),
               let e = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: last, mouseButton: mouseButton) {
                e.post(tap: .cghidEventTap)
            }
            return
        }

        if down {
            activeContacts[id] = pt
            if let e = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: pt, mouseButton: mouseButton) {
                e.setDoubleValueField(.mouseEventPressure, value: pressureNorm)
                e.setIntegerValueField(.mouseEventSubtype, value: 1)
                e.post(tap: .cghidEventTap)
            }
        } else if up {
            activeContacts.removeValue(forKey: id)
            if let e = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: pt, mouseButton: mouseButton) {
                e.setDoubleValueField(.mouseEventPressure, value: pressureNorm)
                e.post(tap: .cghidEventTap)
            }
        } else if update || activeContacts[id] != nil {
            activeContacts[id] = pt
            if let e = CGEvent(mouseEventSource: nil, mouseType: dragType, mouseCursorPosition: pt, mouseButton: mouseButton) {
                e.setDoubleValueField(.mouseEventPressure, value: pressureNorm)
                e.post(tap: .cghidEventTap)
            }
        } else {
            if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left) {
                e.post(tap: .cghidEventTap)
            }
        }
    }
}

private enum RDPEI {
    static let eventSCReady: UInt16 = 0x0001
    static let eventCSReady: UInt16 = 0x0002
    static let eventTouch: UInt16 = 0x0003
    static let eventSuspendTouch: UInt16 = 0x0004
    static let eventResumeTouch: UInt16 = 0x0005
    static let eventDismissHovering: UInt16 = 0x0006
    static let eventPen: UInt16 = 0x0008

    static let protocolV100: UInt32 = 0x0001_0000

    static let contactDown: UInt32 = 0x0001
    static let contactUpdate: UInt32 = 0x0002
    static let contactUp: UInt32 = 0x0004
    static let contactCanceled: UInt32 = 0x0020
    /// RDPINPUT_PEN_CONTACT inverted tip (eraser).
    static let penInverted: UInt32 = 0x0000_0040
}
