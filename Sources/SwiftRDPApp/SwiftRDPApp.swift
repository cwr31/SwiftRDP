import AppKit
import SwiftUI

@main
struct SwiftRDPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("SwiftRDP", id: "settings") {
            SettingsRootView(prefs: appDelegate.prefs, settings: appDelegate.settings)
                .onAppear { NSApp.setActivationPolicy(.regular) }
                .onDisappear { NSApp.setActivationPolicy(.accessory) }
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .onChange(of: appDelegate.settings.presentationRequest) {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L10n.t(.openSettingsEllipsis)) {
                    appDelegate.settings.requestOpen()
                }
                .keyboardShortcut(",")
            }
        }
    }
}
