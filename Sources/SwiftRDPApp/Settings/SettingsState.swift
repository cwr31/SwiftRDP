import Observation

@MainActor
@Observable
final class SettingsState {
    var section: SettingsSection = .general
    var restartPending = false

    // Native menu actions request presentation; the SwiftUI scene owns the window.
    private(set) var presentationRequest = 0

    func requestOpen(
        section: SettingsSection? = nil,
        permissionsGranted: Bool = PermissionGate.allGranted
    ) {
        if let section {
            self.section = section
        } else if !permissionsGranted {
            self.section = .permissions
        }
        presentationRequest &+= 1
    }
}
