import AppKit
import SwiftRDPCore
import Testing
@testable import SwiftRDPApp

@MainActor
struct MenuSelectionTests {
    private func withPreferences(_ test: (AppPreferences) throws -> Void) rethrows {
        let suite = "SwiftRDPMenuTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppPreferences.Key.hasLaunchedBefore)
        let prefs = AppPreferences(defaults: defaults)
        prefs.isServerRunning = true
        try test(prefs)
    }

    private func nativeItems(prefs: AppPreferences, submenuTitle: String) throws -> [NSMenuItem] {
        _ = NSApplication.shared
        let controller = MenuBarController(prefs: prefs, onAction: { _ in })
        return try withExtendedLifetime(controller) {
            controller.refresh()
            let submenu = try #require(controller.menu.items.first { $0.title == submenuTitle }?.submenu)
            #expect(submenu.showsStateColumn)
            return submenu.items
        }
    }

    @Test func nativeMenuChecksSelectedQualityAndFPS() throws {
        try withPreferences { prefs in
            prefs.videoQuality.mode = .original
            prefs.videoFPS = 60
            let items = try nativeItems(prefs: prefs, submenuTitle: L10n.t(.videoQuality))
            let quality = try #require(items.first { $0.title == VideoQualityMode.original.title })
            let fps = try #require(items.first { $0.title == VideoFPSPreset.rate60.title })
            #expect(quality.state == .on)
            #expect(fps.state == .on)
        }
    }

    @Test(arguments: VideoQualityMode.allCases, VideoFPSPreset.allCases)
    func everyQualityAndFPSCombinationHasExactlyOneNativeCheck(
        mode: VideoQualityMode,
        fps: VideoFPSPreset
    ) throws {
        try withPreferences { prefs in
            prefs.videoQuality = VideoQualitySettings(mode: mode, customBitrate: 20_000_000)
            prefs.videoFPS = fps.rawValue
            let items = try nativeItems(prefs: prefs, submenuTitle: L10n.t(.videoQuality))
            let qualityTitles = Set(VideoQualityMode.allCases.map(\.title))
            let fpsTitles = Set(VideoFPSPreset.allCases.map(\.title))
            let qualityItems = items.filter { qualityTitles.contains($0.title) }
            let fpsItems = items.filter { fpsTitles.contains($0.title) }

            #expect(qualityItems.count == VideoQualityMode.allCases.count)
            #expect(fpsItems.count == VideoFPSPreset.allCases.count)
            #expect(qualityItems.filter { $0.state == .on }.map(\.title) == [mode.title])
            #expect(fpsItems.filter { $0.state == .on }.map(\.title) == [fps.title])
        }
    }

    @Test(arguments: [DisplayMode.bitmap, .rfx])
    func nonH264MenusStillCheckFrameRate(mode: DisplayMode) throws {
        try withPreferences { prefs in
            prefs.displayMode = mode
            prefs.videoFPS = 30
            let items = try nativeItems(prefs: prefs, submenuTitle: L10n.t(.videoFPS))
            #expect(items.filter { $0.state == .on }.map(\.title) == [VideoFPSPreset.rate30.title])
        }
    }

    @Test func nativeAudioMenuChecksCurrentDestination() throws {
        try withPreferences { prefs in
            prefs.audioPlaybackDestination = .host
            let items = try nativeItems(prefs: prefs, submenuTitle: L10n.t(.menuAudio))
            #expect(items.filter { $0.state == .on }.map(\.title) == [L10n.t(.audioHost)])
        }
    }

    @Test func existingNativeMenuRefreshesChecksWhenPreferencesChange() throws {
        try withPreferences { prefs in
            let controller = MenuBarController(prefs: prefs, onAction: { _ in })
            controller.refresh()
            @MainActor func checkedTitles() throws -> [String] {
                let submenu = try #require(controller.menu.items.first { $0.title == L10n.t(.videoQuality) }?.submenu)
                return submenu.items.filter { $0.state == .on }.map(\.title)
            }

            let initialTitles = try checkedTitles()
            #expect(initialTitles == [VideoQualityMode.automatic.title, VideoFPSPreset.rate60.title])
            prefs.videoQuality.mode = .high
            prefs.videoFPS = 30
            // Let the queued preference notification observe the completed assignment.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            let updatedTitles = try checkedTitles()
            #expect(updatedTitles == [VideoQualityMode.high.title, VideoFPSPreset.rate30.title])
        }
    }

    @Test(arguments: [VideoQualityMode.automatic, .original, .custom])
    func activeMenuUsesExplicitSessionModeWithoutRememberedSettings(mode: VideoQualityMode) throws {
        try withPreferences { prefs in
            let quality = VideoQualitySettings(mode: mode, customBitrate: 20_000_000)
            try withTestSession(prefs: prefs, quality: quality) { _ in
                #expect(prefs.rememberedSessionSettings.isEmpty)
                let items = try nativeItems(prefs: prefs, submenuTitle: L10n.t(.videoQuality))
                let titles = Set(VideoQualityMode.allCases.map(\.title))
                #expect(items.filter { titles.contains($0.title) && $0.state == .on }.map(\.title) == [mode.title])
            }
        }
    }
}
