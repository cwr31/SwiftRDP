import SwiftUI

@main
struct SwiftRDPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var prefs = AppPreferences.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(prefs: prefs)
        } label: {
            Image(systemName: menuBarSymbol)
                .accessibilityLabel("SwiftRDP")
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuBarSymbol: String {
        if prefs.isServerRestarting { return "arrow.triangle.2.circlepath" }
        if prefs.isServerRunning { return "display.and.arrow.down" }
        return "display"
    }
}
