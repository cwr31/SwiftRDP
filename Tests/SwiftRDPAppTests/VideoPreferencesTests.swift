import Foundation
import SwiftRDPCore
import Testing
@testable import SwiftRDPApp

@MainActor
struct VideoPreferencesTests {
    private func withDefaults(_ test: (UserDefaults) throws -> Void) rethrows {
        let suite = "SwiftRDPAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppPreferences.Key.hasLaunchedBefore)
        try test(defaults)
    }

    @Test func newPreferencesUseAutomaticQuality() {
        withDefaults { defaults in
            let prefs = AppPreferences(defaults: defaults)
            #expect(prefs.videoQuality == .default)
            #expect(prefs.makeServerConfig().videoQuality == .default)
            #expect(prefs.videoFPS == 60)
        }
    }

    @Test func selectingNamedTierKeepsCustomBudgetAcrossReloads() {
        withDefaults { defaults in
            let prefs = AppPreferences(defaults: defaults)
            prefs.videoQuality = VideoQualitySettings(mode: .custom, customBitrate: 37_000_000)
            prefs.videoQuality.mode = .ultra
            let reloaded = AppPreferences(defaults: defaults)
            #expect(reloaded.videoQuality.mode == .ultra)
            #expect(reloaded.videoQuality.customBitrate == 37_000_000)
            #expect(reloaded.makeServerConfig().videoQuality == reloaded.videoQuality)
        }
    }

    @Test func defaultEditsPublishNewClientTargets() {
        withDefaults { defaults in
            let prefs = AppPreferences(defaults: defaults)
            var targets: [(VideoQualitySettings, Int)] = []
            prefs.applyDefaultVideoTargetsLiveHandler = { targets.append(($0, $1)) }
            prefs.videoQuality.mode = .high
            prefs.videoFPS = 30
            #expect(targets.count == 2)
            #expect(targets.last?.0 == prefs.videoQuality)
            #expect(targets.last?.1 == 30)
        }
    }

    @Test func clientEditsKeepTheirScopeAndOtherSettings() {
        withDefaults { defaults in
            let prefs = AppPreferences(defaults: defaults)
            prefs.rememberTestConnection(clientName: "First", peerAddress: "10.0.0.1")
            prefs.rememberTestConnection(clientName: "Second", peerAddress: "10.0.0.2")
            let clientID = "client:first"
            let quality = VideoQualitySettings(mode: .custom, customBitrate: 50_000_000)
            var applied: RememberedSessionSettings?
            prefs.applyRememberedSessionSettingsLiveHandler = { applied = $0 }
            prefs.updateVideoQuality(quality, for: clientID)

            #expect(prefs.videoQuality(for: clientID) == quality)
            #expect(prefs.videoQuality(for: "client:second") == .default)
            #expect(prefs.videoQuality(for: nil) == .default)
            #expect(applied?.id == clientID)
            #expect(applied?.videoFPS == 60)

            let reloaded = AppPreferences(defaults: defaults)
            #expect(reloaded.videoQuality(for: clientID) == quality)
        }
    }

    @Test func forgottenClientEditorDoesNotRetargetDefaultsOrAnotherClient() {
        withDefaults { defaults in
            let prefs = AppPreferences(defaults: defaults)
            prefs.rememberTestConnection(clientName: "First", peerAddress: "10.0.0.1")
            prefs.rememberTestConnection(clientName: "Second", peerAddress: "10.0.0.2")
            prefs.forgetRememberedSessionSettings(id: "client:first")
            prefs.updateVideoQuality(VideoQualitySettings(mode: .high), for: "client:first")
            #expect(prefs.videoQuality(for: "client:first") == nil)
            #expect(prefs.videoQuality(for: "client:second") == .default)
            #expect(prefs.videoQuality(for: nil) == .default)
        }
    }

    @Test func newClientsInheritQualityModeAndRememberTheirOwnCustomBudget() {
        withDefaults { defaults in
            let prefs = AppPreferences(defaults: defaults)
            prefs.videoQuality = VideoQualitySettings(mode: .automatic, customBitrate: 37_000_000)
            prefs.rememberTestConnection(clientName: "First", peerAddress: "10.0.0.1")
            prefs.videoQuality = VideoQualitySettings(mode: .custom, customBitrate: 100_000_000)
            prefs.rememberTestConnection(clientName: "Second", peerAddress: "10.0.0.2")
            #expect(prefs.videoQuality(for: "client:first")?.mode == .automatic)
            #expect(prefs.videoQuality(for: "client:first")?.customBitrate == 37_000_000)
            #expect(prefs.videoQuality(for: "client:second")?.bitrateCeiling == 100_000_000)
        }
    }

    @Test(arguments: [VideoQualityMode.automatic, .original, .custom])
    func serverConfigPreservesEqualBitrateModes(mode: VideoQualityMode) {
        withDefaults { defaults in
            let prefs = AppPreferences(defaults: defaults)
            let quality = VideoQualitySettings(mode: mode, customBitrate: 20_000_000)
            prefs.videoQuality = quality
            #expect(prefs.makeServerConfig().videoQuality == quality)
        }
    }

    @Test func rememberedConnectionUsesSessionSettingsInsteadOfCurrentDefaults() {
        withDefaults { defaults in
            let prefs = AppPreferences(defaults: defaults)
            prefs.videoQuality = VideoQualitySettings(mode: .high)
            prefs.videoFPS = 30
            prefs.audioPlaybackDestination = .host

            var snapshot = SessionManager.ConnectionSnapshot.empty
            snapshot.clientName = "First"
            snapshot.peerAddress = "10.0.0.1"
            snapshot.videoQuality = VideoQualitySettings(mode: .automatic, customBitrate: 37_000_000)
            snapshot.configuredFPS = 60
            snapshot.audioPlaybackDestination = .controller
            prefs.rememberConnection(snapshot)

            let saved = prefs.rememberedSessionSettings.first
            #expect(saved?.videoQuality == snapshot.videoQuality)
            #expect(saved?.videoFPS == snapshot.configuredFPS)
            #expect(saved?.audioPlaybackDestination == snapshot.audioPlaybackDestination)
        }
    }
}
