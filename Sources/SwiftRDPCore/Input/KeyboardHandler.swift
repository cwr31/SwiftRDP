import Foundation
import CoreGraphics

/// Injects keyboard events from RDP slow-path or fast-path input.
/// Set-1 scancode → Mac virtual-key translation, plus Unicode keyboard events.
public final class KeyboardHandler: @unchecked Sendable {
    public static var bindings: [RemoteKeyboardKey: MacKeyboardKey] {
        get { bindingsLock.withLock { storedBindings } }
        set { bindingsLock.withLock { storedBindings = newValue } }
    }
    private static let bindingsLock = NSLock()
    nonisolated(unsafe) private static var storedBindings = KeyboardMappingPreset.direct.bindings
    /// Independent source so injected keys do not inherit the Mac’s physical
    /// Fn/Globe sticky state (Fn+E opens the emoji picker), while still
    /// delivering through the HID tap like a normal user event.
    private let eventSource: CGEventSource? = {
        let src = CGEventSource(stateID: .privateState)
        src?.localEventsSuppressionInterval = 0
        return src
    }()
    private var downModifierFlags: CGEventFlags = []
    private var pressedScanCodes: [PhysicalScanCode: CGKeyCode] = [:]
    private let lock = NSLock()
    private var loggedKeys = 0

    private struct PhysicalScanCode: Hashable {
        let scanCode: UInt16
        let extended: Bool
    }

    public init() {}

    public func injectKey(scanCode: UInt16, flags: UInt16) {
        let release = (flags & 0x8000) != 0
        let extended = (flags & 0x0100) != 0

        let physicalKey = PhysicalScanCode(scanCode: scanCode, extended: extended)
        let cgKey: CGKeyCode?
        if release {
            cgKey = lock.withLock { pressedScanCodes.removeValue(forKey: physicalKey) }
                ?? Self.resolveMappedKey(scanCode: scanCode, extended: extended)
        } else {
            cgKey = Self.resolveMappedKey(scanCode: scanCode, extended: extended)
            if let cgKey {
                lock.withLock { pressedScanCodes[physicalKey] = cgKey }
            }
        }

        guard let cgKey else {
            RDPLog.input.info("Unmapped scancode: 0x\(String(scanCode, radix: 16)) ext=\(extended)")
            return
        }
        if loggedKeys < 12 {
            loggedKeys += 1
            RDPLog.input.info(
                "Key: scan=0x\(String(scanCode, radix: 16)) ext=\(extended) vk=0x\(String(cgKey, radix: 16)) \(release ? "up" : "down")"
            )
        }
        postKey(cgKey, keyDown: !release)
    }

    /// MS-RDPBCGR Unicode keyboard event — inject the UTF-16 code unit directly.
    public func injectUnicode(codeUnit: UInt16, release: Bool) {
        if loggedKeys < 12 {
            loggedKeys += 1
            RDPLog.input.info(
                "Key: unicode=U+\(String(format: "%04X", codeUnit)) \(release ? "up" : "down")"
            )
        }
        // Key-up unicode events are redundant for CGEvent unicode injection.
        guard !release else { return }
        guard codeUnit != 0 else { return }

        let source = eventSource ?? CGEventSource(stateID: .combinedSessionState)
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else {
            return
        }
        lock.lock()
        let flags = downModifierFlags
        lock.unlock()
        e.flags = flags
        var chars: [UniChar] = [codeUnit]
        e.keyboardSetUnicodeString(stringLength: 1, unicodeString: &chars)
        e.post(tap: .cghidEventTap)

        // Synthetic key-up so apps that watch up/down pairs still advance.
        if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            up.flags = flags
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &chars)
            up.post(tap: .cghidEventTap)
        }
    }

    public func handleFastPathScanCode(flags: UInt16, scan: UInt16) {
        var slowFlags: UInt16 = 0
        if flags & 0x01 != 0 { slowFlags |= 0x8000 } // KBDFLAGS_RELEASE
        if flags & 0x02 != 0 { slowFlags |= 0x0100 } // KBDFLAGS_EXTENDED
        injectKey(scanCode: scan, flags: slowFlags)
    }

    public func handleFastPathUnicode(flags: UInt16, codeUnit: UInt16) {
        injectUnicode(codeUnit: codeUnit, release: (flags & 0x01) != 0)
    }

    public func handleSlowPathScanCode(scanCode: UInt16, flags: UInt16) {
        injectKey(scanCode: scanCode, flags: flags)
    }

    public func handleSlowPathUnicode(codeUnit: UInt16, flags: UInt16) {
        injectUnicode(codeUnit: codeUnit, release: (flags & 0x8000) != 0)
    }

    public func resetModifiers() {
        RDPLog.input.info("KeyboardHandler: all modifiers reset")
        lock.lock()
        downModifierFlags = []
        pressedScanCodes.removeAll()
        lock.unlock()
        for vk: CGKeyCode in [0x37, 0x36, 0x3A, 0x3D, 0x3B, 0x3E, 0x38, 0x3C] {
            postKey(vk, keyDown: false, trackModifiers: false)
        }
    }

    private func postKey(_ cgKey: CGKeyCode, keyDown: Bool, trackModifiers: Bool = true) {
        let source = eventSource ?? CGEventSource(stateID: .combinedSessionState)
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: cgKey, keyDown: keyDown) else {
            return
        }

        lock.lock()
        if trackModifiers, let flag = Self.modifierFlag(for: cgKey) {
            if keyDown {
                downModifierFlags.insert(flag)
            } else {
                downModifierFlags.remove(flag)
            }
        }
        // Explicit flags only — clearing prevents a sticky Fn/Globe from turning
        // a normal "E" into Fn+E (emoji & symbols) or Option+E (dead-key accents).
        let flags = downModifierFlags
        lock.unlock()

        e.flags = flags
        e.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        e.post(tap: .cghidEventTap)
    }

    private static func modifierFlag(for key: CGKeyCode) -> CGEventFlags? {
        switch key {
        case 0x37, 0x36: return .maskCommand
        case 0x3A, 0x3D: return .maskAlternate
        case 0x3B, 0x3E: return .maskControl
        case 0x38, 0x3C: return .maskShift
        default: return nil
        }
    }

    // MARK: - Scancode map (PC Set-1 → Mac VK)

    static func resolveMappedKey(scanCode: UInt16, extended: Bool) -> CGKeyCode? {
        if let remoteKey = RemoteKeyboardKey.resolve(scanCode: scanCode, extended: extended) {
            let binding = bindingsLock.withLock { storedBindings[remoteKey] ?? .disabled }
            return binding.virtualKeyCode.map { CGKeyCode($0) }
        }
        return mapScanCode(scanCode, extended: extended)
    }

    private static func mapScanCode(_ scan: UInt16, extended: Bool) -> CGKeyCode? {
        if extended {
            switch scan {
            case 0x48: return 0x7E // Up
            case 0x50: return 0x7D // Down
            case 0x4B: return 0x7B // Left
            case 0x4D: return 0x7C // Right
            case 0x47: return 0x73 // Home
            case 0x4F: return 0x77 // End
            case 0x49: return 0x74 // Page Up
            case 0x51: return 0x79 // Page Down
            case 0x53: return 0x75 // Forward Delete
            case 0x52: return 0x72 // Help / Insert
            case 0x1C: return 0x4C // Keypad Enter
            case 0x35: return 0x4B // Keypad /
            case 0x37: return 0x43 // Keypad *
            default: return nil
            }
        }

        switch scan {
        // Letters
        case 0x10: return 0x0C // Q
        case 0x11: return 0x0D // W
        case 0x12: return 0x0E // E
        case 0x13: return 0x0F // R
        case 0x14: return 0x11 // T
        case 0x15: return 0x10 // Y
        case 0x16: return 0x20 // U
        case 0x17: return 0x22 // I
        case 0x18: return 0x1F // O
        case 0x19: return 0x23 // P
        case 0x1E: return 0x00 // A
        case 0x1F: return 0x01 // S
        case 0x20: return 0x02 // D
        case 0x21: return 0x03 // F
        case 0x22: return 0x05 // G
        case 0x23: return 0x04 // H
        case 0x24: return 0x26 // J
        case 0x25: return 0x28 // K
        case 0x26: return 0x25 // L
        case 0x2C: return 0x06 // Z
        case 0x2D: return 0x07 // X
        case 0x2E: return 0x08 // C
        case 0x2F: return 0x09 // V
        case 0x30: return 0x0B // B
        case 0x31: return 0x2D // N
        case 0x32: return 0x2E // M
        // Digits
        case 0x0B: return 0x1D // 0
        case 0x02: return 0x12 // 1
        case 0x03: return 0x13 // 2
        case 0x04: return 0x14 // 3
        case 0x05: return 0x15 // 4
        case 0x06: return 0x17 // 5
        case 0x07: return 0x16 // 6
        case 0x08: return 0x1A // 7
        case 0x09: return 0x1C // 8
        case 0x0A: return 0x19 // 9
        // Punctuation
        case 0x0C: return 0x1B // -
        case 0x0D: return 0x18 // =
        case 0x1A: return 0x21 // [
        case 0x1B: return 0x1E // ]
        case 0x27: return 0x29 // ;
        case 0x28: return 0x27 // '
        case 0x29: return 0x32 // `
        case 0x2B: return 0x2A // \
        case 0x33: return 0x2B // ,
        case 0x34: return 0x2F // .
        case 0x35: return 0x2C // /
        // Controls
        case 0x1C: return 0x24 // Return
        case 0x01: return 0x35 // Escape
        case 0x0E: return 0x33 // Delete
        case 0x0F: return 0x30 // Tab
        // Function keys
        case 0x3B: return 0x7A // F1
        case 0x3C: return 0x78 // F2
        case 0x3D: return 0x63 // F3
        case 0x3E: return 0x76 // F4
        case 0x3F: return 0x60 // F5
        case 0x40: return 0x61 // F6
        case 0x41: return 0x62 // F7
        case 0x42: return 0x64 // F8
        case 0x43: return 0x65 // F9
        case 0x44: return 0x6D // F10
        case 0x57: return 0x67 // F11
        case 0x58: return 0x6F // F12
        // Keypad
        case 0x45: return 0x47 // Num Lock → Clear
        case 0x4E: return 0x45 // Keypad +
        case 0x4A: return 0x4E // Keypad -
        case 0x37: return 0x43 // Keypad *
        case 0x47: return 0x59 // Keypad 7
        case 0x48: return 0x5B // Keypad 8
        case 0x49: return 0x5C // Keypad 9
        case 0x4B: return 0x56 // Keypad 4
        case 0x4C: return 0x57 // Keypad 5
        case 0x4D: return 0x58 // Keypad 6
        case 0x4F: return 0x53 // Keypad 1
        case 0x50: return 0x54 // Keypad 2
        case 0x51: return 0x55 // Keypad 3
        case 0x52: return 0x52 // Keypad 0
        case 0x53: return 0x41 // Keypad .
        default: return nil
        }
    }
}
