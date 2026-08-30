import Foundation
import SwiftRDPCore

extension KeyboardMappingPreset: Identifiable {
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: return L10n.t(.keyboardMappingDirect)
        case .windowsShortcuts: return L10n.t(.keyboardMappingWindows)
        case .swapOptionCommand: return L10n.t(.keyboardMappingSwapOptionCommand)
        }
    }
}

extension RemoteKeyboardKey: Identifiable {
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .capsLock: return "Caps Lock"
        case .leftShift: return "Left Shift"
        case .leftControl: return "Left Ctrl"
        case .leftWindows: return "Left Win"
        case .leftAlt: return "Left Alt"
        case .space: return "Space"
        case .rightAlt: return "Right Alt"
        case .rightWindows: return "Right Win"
        case .menu: return "Menu"
        case .rightControl: return "Right Ctrl"
        case .rightShift: return "Right Shift"
        }
    }

    var keyCap: String {
        switch self {
        case .capsLock: return "Caps"
        case .leftShift, .rightShift: return "Shift"
        case .leftControl, .rightControl: return "Ctrl"
        case .leftWindows, .rightWindows: return "Win"
        case .leftAlt, .rightAlt: return "Alt"
        case .space: return "Space"
        case .menu: return "Menu"
        }
    }
}

extension MacKeyboardKey: Identifiable {
    public var id: UInt16 { rawValue }

    var title: String {
        switch self {
        case .disabled: return L10n.t(.keyboardBindingDisabled)
        case .escape: return "Esc"
        case .tab: return "Tab"
        case .capsLock: return "Caps Lock"
        case .leftShift: return "⇧ Left Shift"
        case .leftControl: return "⌃ Left Control"
        case .leftOption: return "⌥ Left Option"
        case .leftCommand: return "⌘ Left Command"
        case .space: return "Space"
        case .delete: return "Delete"
        case .rightCommand: return "⌘ Right Command"
        case .rightOption: return "⌥ Right Option"
        case .rightControl: return "⌃ Right Control"
        case .rightShift: return "⇧ Right Shift"
        }
    }

    var symbol: String {
        switch self {
        case .disabled: return "—"
        case .escape: return "esc"
        case .tab: return "⇥"
        case .capsLock: return "⇪"
        case .leftShift, .rightShift: return "⇧"
        case .leftControl, .rightControl: return "⌃"
        case .leftOption, .rightOption: return "⌥"
        case .leftCommand, .rightCommand: return "⌘"
        case .space: return "␠"
        case .delete: return "⌫"
        }
    }
}
