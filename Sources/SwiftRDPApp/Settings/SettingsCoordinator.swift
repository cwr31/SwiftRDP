import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsCoordinator: ObservableObject {
    static let shared = SettingsCoordinator()

    @Published var section: SettingsSection? = .general
    @Published var restartPending = false

    private var settingsScene: NSHostingSceneRepresentation<Window<SettingsRootView>>?

    func install() {
        guard settingsScene == nil else { return }
        let scene = NSHostingSceneRepresentation {
            Window(L10n.t(.settingsWindowTitle), id: "settings") {
                SettingsRootView(
                    prefs: AppPreferences.shared,
                    coordinator: self
                )
            }
        }
        NSApp.addSceneRepresentation(scene)
        settingsScene = scene
    }

    func open(section: SettingsSection? = nil) {
        if let section {
            self.section = section
        } else if !PermissionGate.allGranted {
            self.section = .permissions
        }

        install()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsScene?.environment.openWindow(id: "settings")
    }
}
