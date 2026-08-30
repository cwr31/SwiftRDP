import Foundation
import SwiftRDPCore

/// Thread-safe UserDefaults persistence used by both the UI and network sessions.
final class RememberedSessionStore: @unchecked Sendable {
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let key = "swiftrdp.rememberedSessionSettings"
    private var values: [String: RememberedSessionSettings]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([RememberedSessionSettings].self, from: data) {
            values = Dictionary(uniqueKeysWithValues: decoded.map {
                var settings = $0
                settings.videoBitrate = ServerConfig.normalizedVideoBitrate(settings.videoBitrate)
                return (settings.id, settings)
            })
        } else {
            values = [:]
        }
    }

    func settings(for identity: SessionClientIdentity) -> RememberedSessionSettings? {
        lock.lock()
        defer { lock.unlock() }
        return values[identity.stableKey]
    }

    func all() -> [RememberedSessionSettings] {
        lock.lock()
        defer { lock.unlock() }
        return values.values.sorted { $0.lastConnectedAt > $1.lastConnectedAt }
    }

    @discardableResult
    func ensure(
        identity: SessionClientIdentity,
        defaultBitrate: Int,
        defaultFPS: Int,
        defaultAudioDestination: AudioPlaybackDestination
    ) -> RememberedSessionSettings {
        lock.lock()
        defer { lock.unlock() }
        if var existing = values[identity.stableKey] {
            existing.clientName = identity.clientName
            existing.peerAddress = identity.peerAddress
            existing.lastConnectedAt = Date()
            values[identity.stableKey] = existing
            persistLocked()
            return existing
        }
        let created = RememberedSessionSettings(
            identity: identity,
            videoBitrate: defaultBitrate,
            videoFPS: defaultFPS,
            audioPlaybackDestination: defaultAudioDestination
        )
        values[created.id] = created
        persistLocked()
        return created
    }

    func update(_ settings: RememberedSessionSettings) {
        lock.lock()
        values[settings.id] = settings
        persistLocked()
        lock.unlock()
    }

    func remove(id: String) {
        lock.lock()
        values.removeValue(forKey: id)
        persistLocked()
        lock.unlock()
    }

    private func persistLocked() {
        let ordered = values.values.sorted { $0.lastConnectedAt > $1.lastConnectedAt }
        guard let data = try? JSONEncoder().encode(ordered) else { return }
        defaults.set(data, forKey: key)
    }
}
