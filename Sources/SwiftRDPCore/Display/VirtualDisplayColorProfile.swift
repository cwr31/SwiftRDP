@preconcurrency import ColorSync
import CoreGraphics
import Foundation

enum VirtualDisplayColorProfile {
    private static var sRGBProfileURL: CFURL {
        URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/sRGB Profile.icc") as CFURL
    }

    static func apply(to displayID: CGDirectDisplayID) {
        guard let device = device(for: displayID),
              let defaultProfileKey = kColorSyncDeviceDefaultProfileID?.takeUnretainedValue()
        else {
            RDPLog.display.error("VirtualDisplay: ColorSync UUID unavailable for id=\(displayID)")
            return
        }

        let profiles = [defaultProfileKey: sRGBProfileURL] as CFDictionary
        if ColorSyncDeviceSetCustomProfiles(device.deviceClass, device.uuid, profiles) {
            RDPLog.display.info("VirtualDisplay: assigned sRGB profile to id=\(displayID)")
        } else {
            RDPLog.display.error("VirtualDisplay: failed to assign sRGB profile to id=\(displayID)")
        }
    }

    private static func device(
        for displayID: CGDirectDisplayID
    ) -> (uuid: CFUUID, deviceClass: CFString)? {
        guard displayID != 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let deviceClass = kColorSyncDisplayDeviceClass?.takeUnretainedValue()
        else { return nil }
        return (uuid, deviceClass)
    }
}
