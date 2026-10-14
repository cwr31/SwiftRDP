import SwiftRDPCore

enum AppAction {
    case refreshStatus, toggleServer, copyAddress, disconnect, quit
    case quality(VideoQualityMode)
    case fps(VideoFPSPreset)
    case audio(AudioPlaybackDestination)
    case resolution(HostResolutionOption)
    case settings(SettingsSection?)
}
