import ServiceManagement
import SwiftRDPCore

enum LaunchAtLogin {
    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                RDPLog.app.info("LaunchAtLogin: registered")
            } else {
                try SMAppService.mainApp.unregister()
                RDPLog.app.info("LaunchAtLogin: unregistered")
            }
        } catch {
            RDPLog.app.error("LaunchAtLogin: SMAppService failed (\(error))")
        }
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
