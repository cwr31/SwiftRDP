import AppKit
import SwiftRDPCore
import Testing
@testable import SwiftRDPApp

@MainActor
struct CustomBitrateMenuTests {
    private func withPreferences(_ test: (AppPreferences) throws -> Void) rethrows {
        let suite = "SwiftRDPCustomMenuTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppPreferences.Key.hasLaunchedBefore)
        let prefs = AppPreferences(defaults: defaults)
        prefs.isServerRunning = true
        try test(prefs)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @Test func customItemContainsInlineSliderAndHintWithoutSwitchOrWindow() throws {
        try withPreferences { prefs in
            _ = NSApplication.shared
            let windowCount = NSApp.windows.count
            let controller = MenuBarController(prefs: prefs, onAction: { _ in })
            controller.refresh()
            let quality = try #require(controller.menu.items.first { $0.title == L10n.t(.videoQuality) }?.submenu)
            let custom = try #require(quality.items.first { $0.title == VideoQualityMode.custom.title })
            let submenu = try #require(custom.submenu)
            submenu.delegate?.menuWillOpen?(submenu)
            let view = try #require(submenu.item(at: 0)?.view as? CustomBitrateMenuView)

            #expect(custom.representedObject == nil)
            #expect(view.slider.minValue == 1)
            #expect(view.slider.maxValue == 500)
            #expect(view.slider.doubleValue == 30)
            #expect(descendants(of: view).compactMap { $0 as? NSButton }.isEmpty)
            #expect(descendants(of: view).compactMap { $0 as? NSTextField }
                .contains { $0.stringValue == L10n.t(.customBitratePrompt) && !$0.isEditable })
            #expect(prefs.videoQuality.mode == .automatic)
            #expect(NSApp.windows.count == windowCount)

            view.slider.doubleValue = 37
            view.bitrateChanged(view.slider)
            #expect(prefs.videoQuality.mode == .custom)
            #expect(prefs.videoQuality.bitrateCeiling == 37_000_000)
            #expect(prefs.videoFPS == 60)
            #expect(NSApp.windows.count == windowCount)
        }
    }

    @Test func nativeSubmenuAndCheckmarkSurviveSelectionUpdates() throws {
        try withPreferences { prefs in
            _ = NSApplication.shared
            let controller = MenuBarController(prefs: prefs, onAction: { _ in })
            controller.refresh()
            let quality = try #require(controller.menu.items.first { $0.title == L10n.t(.videoQuality) }?.submenu)
            let custom = try #require(quality.items.first { $0.title == VideoQualityMode.custom.title })
            let submenu = try #require(custom.submenu)
            submenu.delegate?.menuWillOpen?(submenu)
            let view = try #require(submenu.item(at: 0)?.view as? CustomBitrateMenuView)
            view.slider.doubleValue = 50
            view.bitrateChanged(view.slider)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

            let updated = try #require(quality.items.first { $0.title == VideoQualityMode.custom.title })
            #expect(updated.state == .on)
            #expect(updated.submenu === submenu)
            controller.refreshSelectionStates()
            #expect(updated.submenu === submenu)
            #expect(submenu.items.count == 1)
        }
    }

    @Test func draggingBudgetActivatesOnlyTheCapturedClient() {
        withPreferences { prefs in
            prefs.videoFPS = 30
            prefs.rememberTestConnection(clientName: "First", peerAddress: "10.0.0.1")
            prefs.rememberTestConnection(clientName: "Second", peerAddress: "10.0.0.2")
            prefs.applyCustomVideoBitrate(50_000_000, for: "client:first")
            #expect(prefs.videoQuality(for: "client:first")?.mode == .custom)
            #expect(prefs.videoQuality(for: "client:first")?.customBitrate == 50_000_000)
            #expect(prefs.videoQuality(for: "client:second")?.mode == .automatic)
            #expect(prefs.videoQuality.mode == .automatic)
            #expect(prefs.rememberedSessionSettings.allSatisfy { $0.videoFPS == 30 })
        }
    }

    @Test func removedClientCannotRedirectSliderEditsToAnotherScope() {
        withPreferences { prefs in
            prefs.rememberTestConnection(clientName: "First", peerAddress: "10.0.0.1")
            prefs.forgetRememberedSessionSettings(id: "client:first")
            prefs.applyCustomVideoBitrate(50_000_000, for: "client:first")
            #expect(prefs.videoQuality(for: "client:first") == nil)
            #expect(prefs.videoQuality.mode == .automatic)
        }
    }

    @Test func activeCustomMenuKeepsSessionModeAndSavedCustomBudget() throws {
        try withPreferences { prefs in
            let quality = VideoQualitySettings(mode: .automatic, customBitrate: 37_000_000)
            try withTestSession(prefs: prefs, quality: quality) { _ in
                let controller = CustomBitrateMenuController(prefs: prefs)
                controller.menuWillOpen(controller.menu)
                let view = try #require(controller.menu.item(at: 0)?.view as? CustomBitrateMenuView)
                #expect(view.slider.doubleValue == 37)
                #expect(prefs.videoQuality(for: "client:first") == quality)
            }
        }
    }
}
