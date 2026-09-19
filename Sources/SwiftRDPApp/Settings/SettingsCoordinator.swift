import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsCoordinator: ObservableObject {
    static let shared = SettingsCoordinator()

    @Published var section: SettingsSection? = .general
    @Published var restartPending = false

    private var settingsScene: NSHostingSceneRepresentation<Window<SettingsRootView>>?
    private weak var settingsWindow: NSWindow?
    private var settingsWindowCloseObserver: NSObjectProtocol?
    private var applicationDidBecomeActiveObserver: NSObjectProtocol?

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

        let notificationCenter = NotificationCenter.default
        settingsWindowCloseObserver = notificationCenter.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                guard self.isSettingsWindow(window) else { return }
                if self.settingsWindow === window {
                    self.settingsWindow = nil
                }
                self.syncActivationPolicy()
            }
        }

        applicationDidBecomeActiveObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.syncActivationPolicy()
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.syncActivationPolicy()
        }
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

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.settingsWindow = NSApp.windows.first(where: self.isSettingsWindowCandidate)
        }
    }

    private func isSettingsWindow(_ window: NSWindow) -> Bool {
        if let settingsWindow {
            return settingsWindow === window
        }

        return isSettingsWindowCandidate(window)
    }

    private func isSettingsWindowCandidate(_ window: NSWindow) -> Bool {
        return window.identifier?.rawValue == "settings"
            || window.title == L10n.t(.settingsWindowTitle)
    }

    private func syncActivationPolicy() {
        if let settingsWindow, settingsWindow.isVisible || settingsWindow.isMiniaturized {
            NSApp.setActivationPolicy(.regular)
            return
        }

        if let window = NSApp.windows.first(where: isSettingsWindowCandidate),
           window.isVisible || window.isMiniaturized {
            settingsWindow = window
            NSApp.setActivationPolicy(.regular)
            return
        }

        settingsWindow = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
