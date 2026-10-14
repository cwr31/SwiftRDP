import AppKit
import SwiftRDPCore

@MainActor
final class CustomBitrateMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    var onCommit: (() -> Void)?
    private let prefs: AppPreferences

    init(prefs: AppPreferences) {
        self.prefs = prefs
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        let item = NSMenuItem()
        item.view = CustomBitrateMenuView(bitrate: VideoQualitySettings.defaultCustomBitrate) { _ in }
        menu.addItem(item)
    }

    func menuWillOpen(_ menu: NSMenu) {
        let manager = prefs.sessionManagerProvider?()
        let snapshot = prefs.isServerRunning && !prefs.isServerRestarting && manager?.hasActiveSession == true
            ? manager?.connectionSnapshot
            : nil
        let clientID = snapshot.map {
            let identity = SessionClientIdentity(clientName: $0.clientName, peerAddress: $0.peerAddress)
            prefs.rememberedSessionStore.ensure(
                identity: identity,
                defaultQuality: $0.videoQuality,
                defaultFPS: $0.configuredFPS,
                defaultAudioDestination: $0.audioPlaybackDestination
            )
            prefs.refreshRememberedSessionSettings()
            return identity.stableKey
        }
        let quality = prefs.videoQuality(for: clientID) ?? .default
        let item = NSMenuItem()
        item.view = CustomBitrateMenuView(bitrate: quality.customBitrate) { [weak self] bitrate in
            self?.prefs.applyCustomVideoBitrate(bitrate, for: clientID)
            self?.onCommit?()
        }
        menu.removeAllItems()
        menu.addItem(item)
    }
}
