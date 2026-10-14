import AppKit
import Testing
@testable import SwiftRDPApp

@MainActor
struct SettingsStateTests {
    private func withPreferences(_ test: (AppPreferences) throws -> Void) rethrows {
        let suite = "SwiftRDPSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: AppPreferences.Key.hasLaunchedBefore)
        defer { defaults.removePersistentDomain(forName: suite) }
        try test(AppPreferences(defaults: defaults))
    }

    @Test func initialStateHasNoPresentationRequest() {
        let settings = SettingsState()
        #expect(settings.section == .general)
        #expect(!settings.restartPending)
        #expect(settings.presentationRequest == 0)
    }

    @Test func repeatedOpenRequestsAreDistinctEvenForTheSameSection() {
        let settings = SettingsState()
        settings.requestOpen(section: .logs, permissionsGranted: true)
        #expect(settings.section == .logs)
        #expect(settings.presentationRequest == 1)

        settings.requestOpen(section: .logs, permissionsGranted: true)
        #expect(settings.section == .logs)
        #expect(settings.presentationRequest == 2)
    }

    @Test func ordinaryOpenPreservesTheSelectedSection() {
        let settings = SettingsState()
        settings.section = .display
        settings.requestOpen(permissionsGranted: true)
        #expect(settings.section == .display)
        #expect(settings.presentationRequest == 1)
    }

    @Test func missingPermissionsSelectPermissionsWithoutOverridingExplicitDestinations() {
        let settings = SettingsState()
        settings.requestOpen(permissionsGranted: false)
        #expect(settings.section == .permissions)

        settings.requestOpen(section: .logs, permissionsGranted: false)
        #expect(settings.section == .logs)
        #expect(settings.presentationRequest == 2)
    }

    @Test func changingSectionsDoesNotRequestAnotherWindow() {
        let settings = SettingsState()
        settings.section = .input
        settings.restartPending = true
        #expect(settings.presentationRequest == 0)
    }

    @Test func nativeMenuForwardsSettingsActionsWithoutCreatingWindows() throws {
        let app = NSApplication.shared
        let windowCount = app.windows.count
        let settings = SettingsState()
        var actions: [AppAction] = []
        let controller = MenuBarController(prefs: .shared) { action in
            actions.append(action)
            if case .settings(let section) = action {
                settings.requestOpen(section: section, permissionsGranted: true)
            }
        }
        controller.refresh()
        let commands: [(L10n.Key, SettingsSection)] = [
            (.openSettingsEllipsis, .general),
            (.viewServerLog, .logs),
            (.checkPermissions, .permissions),
        ]
        for (index, command) in commands.enumerated() {
            let menuIndex = try #require(controller.menu.items.firstIndex { $0.title == L10n.t(command.0) })
            controller.menu.performActionForItem(at: menuIndex)
            #expect(actions.count == index + 1)
            #expect(settings.section == command.1)
            #expect(settings.presentationRequest == index + 1)
            #expect(app.windows.count == windowCount)
        }
    }

    @Test func menuRequestsFreshStatusBeforeBuildingItsContents() {
        withPreferences { prefs in
            var requests = 0
            let controller = MenuBarController(prefs: prefs) { action in
                guard case .refreshStatus = action else {
                    Issue.record("Unexpected application action")
                    return
                }
                requests += 1
                prefs.sessionStatusText = "Fresh status"
            }
            controller.menuNeedsUpdate(controller.menu)
            #expect(requests == 1)
            #expect(controller.menu.item(at: 0)?.title == "Fresh status")
        }
    }

    @Test func applicationActionsAndReopenUseTheSameSettingsState() {
        withPreferences { prefs in
            let app = NSApplication.shared
            let delegate = AppDelegate(prefs: prefs)
            delegate.handleMenuAction(.settings(.display))
            #expect(delegate.settings.section == .display)
            #expect(delegate.settings.presentationRequest == 1)

            #expect(!delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false))
            #expect(delegate.settings.presentationRequest == 2)
            #expect(!delegate.applicationShouldHandleReopen(app, hasVisibleWindows: true))
            #expect(delegate.settings.presentationRequest == 3)
        }
    }

    @Test func stoppedServerClearsPendingRestartWithoutAnOpenSettingsView() {
        withPreferences { prefs in
            let delegate = AppDelegate(prefs: prefs)
            delegate.settings.restartPending = true
            delegate.handleMenuAction(.refreshStatus)
            #expect(!delegate.settings.restartPending)
        }
    }

    @Test func closingSettingsDoesNotTerminateTheMenuBarServer() {
        withPreferences { prefs in
            let delegate = AppDelegate(prefs: prefs)
            #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        }
    }
}
