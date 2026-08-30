import Foundation

/// Ready-made binding tables that can replace the editable configuration.
public enum KeyboardMappingPreset: String, Sendable, CaseIterable {
    /// Physical position: Windows/Command → ⌘, Control → ⌃, Alt → ⌥.
    case direct
    /// Windows shortcuts: Control → ⌘ (Ctrl+C = copy), Windows → ⌃.
    case windowsShortcuts
    /// Swap ⌥ and ⌘ on the Mac host.
    case swapOptionCommand
}

/// Remote PC keys exposed for per-key binding. These cover the modifier cluster
/// where PC and Mac conventions differ most often.
public enum RemoteKeyboardKey: String, Codable, Sendable, Hashable {
    case capsLock
    case leftShift
    case leftControl
    case leftWindows
    case leftAlt
    case space
    case rightAlt
    case rightWindows
    case menu
    case rightControl
    case rightShift

    public static func resolve(scanCode: UInt16, extended: Bool) -> Self? {
        switch (scanCode, extended) {
        case (0x3A, false): return .capsLock
        case (0x2A, false): return .leftShift
        case (0x1D, false): return .leftControl
        case (0x5B, true): return .leftWindows
        case (0x38, false): return .leftAlt
        case (0x39, false): return .space
        case (0x38, true): return .rightAlt
        case (0x5C, true): return .rightWindows
        case (0x5D, true): return .menu
        case (0x1D, true): return .rightControl
        case (0x36, false): return .rightShift
        default: return nil
        }
    }
}

/// Mac virtual keys available as binding targets.
public enum MacKeyboardKey: UInt16, Codable, Sendable, Hashable {
    case disabled = 0xFFFF
    case escape = 0x35
    case tab = 0x30
    case capsLock = 0x39
    case leftShift = 0x38
    case leftControl = 0x3B
    case leftOption = 0x3A
    case leftCommand = 0x37
    case space = 0x31
    case delete = 0x33
    case rightCommand = 0x36
    case rightOption = 0x3D
    case rightControl = 0x3E
    case rightShift = 0x3C

    public var virtualKeyCode: UInt16? {
        self == .disabled ? nil : rawValue
    }
}

extension KeyboardMappingPreset {
    public var bindings: [RemoteKeyboardKey: MacKeyboardKey] {
        var bindings: [RemoteKeyboardKey: MacKeyboardKey] = [
            .capsLock: .capsLock,
            .leftShift: .leftShift,
            .leftControl: .leftControl,
            .leftWindows: .leftCommand,
            .leftAlt: .leftOption,
            .space: .space,
            .rightAlt: .rightOption,
            .rightWindows: .rightCommand,
            .menu: .disabled,
            .rightControl: .rightControl,
            .rightShift: .rightShift,
        ]

        switch self {
        case .direct:
            break
        case .windowsShortcuts:
            bindings[.leftControl] = .leftCommand
            bindings[.leftWindows] = .leftControl
            bindings[.rightControl] = .rightCommand
            bindings[.rightWindows] = .rightControl
        case .swapOptionCommand:
            bindings[.leftAlt] = .leftCommand
            bindings[.leftWindows] = .leftOption
            bindings[.rightAlt] = .rightCommand
            bindings[.rightWindows] = .rightOption
        }
        return bindings
    }
}
