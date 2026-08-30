import XCTest
@testable import SwiftRDPCore

final class KeyboardMappingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        KeyboardHandler.bindings = KeyboardMappingPreset.direct.bindings
    }

    override func tearDown() {
        KeyboardHandler.bindings = KeyboardMappingPreset.direct.bindings
        super.tearDown()
    }

    func testPresetMapsWindowsShortcutModifiers() {
        KeyboardHandler.bindings = KeyboardMappingPreset.windowsShortcuts.bindings

        XCTAssertEqual(KeyboardHandler.resolveMappedKey(scanCode: 0x1D, extended: false), 0x37)
        XCTAssertEqual(KeyboardHandler.resolveMappedKey(scanCode: 0x5B, extended: true), 0x3B)
        XCTAssertEqual(KeyboardHandler.resolveMappedKey(scanCode: 0x1D, extended: true), 0x36)
    }

    func testDynamicBindingReplacesTemplateValuePerPhysicalKey() {
        var bindings = KeyboardMappingPreset.windowsShortcuts.bindings
        bindings[.leftControl] = .leftOption
        KeyboardHandler.bindings = bindings

        XCTAssertEqual(KeyboardHandler.resolveMappedKey(scanCode: 0x1D, extended: false), 0x3A)
        XCTAssertEqual(KeyboardHandler.resolveMappedKey(scanCode: 0x1D, extended: true), 0x36)
    }

    func testDisabledBindingDropsKey() {
        var bindings = KeyboardMappingPreset.direct.bindings
        bindings[.leftWindows] = .disabled
        KeyboardHandler.bindings = bindings

        XCTAssertNil(KeyboardHandler.resolveMappedKey(scanCode: 0x5B, extended: true))
    }

    func testPreviouslyUnmappedMenuKeyCanBeBound() {
        XCTAssertNil(KeyboardHandler.resolveMappedKey(scanCode: 0x5D, extended: true))

        var bindings = KeyboardMappingPreset.direct.bindings
        bindings[.menu] = .escape
        KeyboardHandler.bindings = bindings

        XCTAssertEqual(KeyboardHandler.resolveMappedKey(scanCode: 0x5D, extended: true), 0x35)
    }
}
