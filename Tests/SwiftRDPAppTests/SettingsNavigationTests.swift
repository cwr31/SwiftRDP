import SwiftUI
import Testing
@testable import SwiftRDPApp

@MainActor
struct SettingsNavigationTests {
    @Test func sidebarGroupsContainEverySectionExactlyOnce() {
        let groups = SettingsSectionGroup.all
        let sections = groups.flatMap(\.sections)
        #expect(sections == SettingsSection.allCases)
        #expect(Set(sections).count == sections.count)
        #expect(Set(groups.map(\.id)).count == groups.count)
        #expect(groups.allSatisfy { !$0.sections.isEmpty })
    }

    @Test func sidebarUsesTheExpectedServerExperienceAndSupportGroups() {
        let groups = SettingsSectionGroup.all
        #expect(groups.count == 3)
        #expect(groups[0].sections == [.general, .connections])
        #expect(groups[1].sections == [.display, .input, .audio, .session])
        #expect(groups[2].sections == [.permissions, .logs])
    }

    @Test func sidebarSelectionUpdatesTheExistingStateWithoutRequestingAnotherWindow() {
        let settings = SettingsState()
        let selection = Binding<SettingsSection?>(Binding(
            get: { settings.section },
            set: { settings.section = $0 }
        ))
        selection.wrappedValue = .display
        #expect(settings.section == .display)
        #expect(settings.presentationRequest == 0)

        selection.wrappedValue = nil
        #expect(settings.section == .display)
        #expect(settings.presentationRequest == 0)
    }
}
