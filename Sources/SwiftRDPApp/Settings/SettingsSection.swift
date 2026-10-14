enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general
    case connections
    case display
    case input
    case audio
    case session
    case permissions
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.t(.sectionGeneral)
        case .connections: return L10n.t(.sectionConnections)
        case .display: return L10n.t(.sectionDisplay)
        case .input: return L10n.t(.sectionInput)
        case .audio: return L10n.t(.sectionAudio)
        case .session: return L10n.t(.sectionSession)
        case .permissions: return L10n.t(.sectionPermissions)
        case .logs: return L10n.t(.sectionLogs)
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .connections: return "point.3.connected.trianglepath.dotted"
        case .display: return "display"
        case .input: return "computermouse"
        case .audio: return "speaker.wave.2"
        case .session: return "macwindow.on.rectangle"
        case .permissions: return "lock.shield"
        case .logs: return "doc.text"
        }
    }
}

struct SettingsSectionGroup: Identifiable {
    let id: String
    let title: L10n.Key
    let sections: [SettingsSection]

    static let all: [Self] = [
        Self(id: "server", title: .settingsGroupServer, sections: [.general, .connections]),
        Self(id: "experience", title: .settingsGroupExperience, sections: [.display, .input, .audio, .session]),
        Self(id: "support", title: .settingsGroupSupport, sections: [.permissions, .logs]),
    ]
}
