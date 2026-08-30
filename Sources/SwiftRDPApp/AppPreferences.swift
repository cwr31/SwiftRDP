import Foundation
import Darwin
import SwiftRDPCore
import Combine

/// UserDefaults-backed preferences for the settings surface.
@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    private let defaults = UserDefaults.standard

    // MARK: Keys

    enum Key {
        private static let prefix = "swiftrdp."
        static let serverPort = prefix + "serverPort"
        static let authEnabled = prefix + "authEnabled"
        static let knownPeersOnly = prefix + "knownPeersOnly"
        static let username = prefix + "username"
        static let password = prefix + "password"
        static let autoStartServer = prefix + "autoStartServer"
        static let launchAtLogin = prefix + "launchAtLogin"
        static let idleTimeout = prefix + "idleTimeout"
        static let displayMode = prefix + "displayMode"
        static let hostDisplayPolicy = prefix + "hostDisplayPolicy"
        static let selectedDisplayIdentity = prefix + "selectedDisplayIdentity"
        static let videoBitrate = prefix + "videoBitrate"
        static let videoFPS = prefix + "videoFPS"
        static let videoAdaptationPriority = prefix + "videoAdaptationPriority"
        static let audioPlaybackDestination = prefix + "audioPlaybackDestination"
        static let appLanguage = prefix + "appLanguage"
        static let hasLaunchedBefore = prefix + "hasLaunchedBefore"
        static let gfxEnabled = prefix + "gfxEnabled"
        static let asyncEncoding = prefix + "asyncEncoding"
        static let tlsVersionMode = prefix + "tlsVersionMode"
        static let devLog = prefix + "devLog"
        static let wheelScrollSpeed = prefix + "wheelScrollSpeed"
        static let invertWheelScroll = prefix + "invertWheelScroll"
        static let remotePointerScale = prefix + "remotePointerScale"
        static let keyboardBindings = prefix + "keyboardBindings"
        static let preventSystemSleep = prefix + "preventSystemSleep"
        static let preventDisplaySleep = prefix + "preventDisplaySleep"
    }

    @Published var serverPort: Int {
        didSet { defaults.set(serverPort, forKey: Key.serverPort) }
    }
    @Published var authEnabled: Bool {
        didSet { defaults.set(authEnabled, forKey: Key.authEnabled) }
    }
    @Published var knownPeersOnly: Bool {
        didSet {
            defaults.set(knownPeersOnly, forKey: Key.knownPeersOnly)
            applyKnownPeersOnlyLiveHandler?(knownPeersOnly)
        }
    }
    @Published var username: String {
        didSet {
            defaults.set(username, forKey: Key.username)
            credentialsDirty = true
        }
    }
    @Published var password: String {
        didSet {
            credentialsDirty = true
        }
    }

    /// True after username/password change until applied via restart.
    @Published var credentialsDirty = false

    /// AppDelegate assigns this to stop/start with fresh ServerConfig.
    var applyAndRestartHandler: (() -> Void)?
    /// Live-apply adaptation priority to running sessions (no restart).
    var applyVideoAdaptationPriorityLiveHandler: ((VideoAdaptationPriority) -> Void)?
    var applyAudioPlaybackDestinationLiveHandler: ((AudioPlaybackDestination) -> Void)?
    var applyRemotePointerScaleHandler: ((Double) -> Void)?
    var applyKnownPeersOnlyLiveHandler: ((Bool) -> Void)?

    func applyCredentialsAndRestart() {
        defaults.set(password, forKey: Key.password)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftRDP", isDirectory: true)
        let ntlmDir = support.appendingPathComponent("ntlm", isDirectory: true)
        NTLMServer.invalidateStoredHashes(in: ntlmDir)
        NTLMServer.storeHash(username: username, password: password, in: ntlmDir)
        credentialsDirty = false
        applyAndRestartHandler?()
    }
    @Published var autoStartServer: Bool {
        didSet { defaults.set(autoStartServer, forKey: Key.autoStartServer) }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
            LaunchAtLogin.setEnabled(launchAtLogin)
        }
    }
    @Published var idleTimeout: Int {
        didSet { defaults.set(idleTimeout, forKey: Key.idleTimeout) }
    }
    @Published var displayMode: DisplayMode {
        didSet { defaults.set(displayMode.rawValue, forKey: Key.displayMode) }
    }
    @Published var hostDisplayPolicy: HostDisplayPolicy {
        didSet { defaults.set(hostDisplayPolicy.rawValue, forKey: Key.hostDisplayPolicy) }
    }
    @Published var selectedDisplayIdentity: String {
        didSet { defaults.set(selectedDisplayIdentity, forKey: Key.selectedDisplayIdentity) }
    }
    @Published var videoBitrate: Int {
        didSet { defaults.set(videoBitrate, forKey: Key.videoBitrate) }
    }
    @Published var videoFPS: Int {
        didSet { defaults.set(videoFPS, forKey: Key.videoFPS) }
    }
    @Published var videoAdaptationPriority: VideoAdaptationPriority {
        didSet {
            defaults.set(videoAdaptationPriority.rawValue, forKey: Key.videoAdaptationPriority)
            applyVideoAdaptationPriorityLiveHandler?(videoAdaptationPriority)
        }
    }
    @Published var audioPlaybackDestination: AudioPlaybackDestination {
        didSet {
            defaults.set(audioPlaybackDestination.rawValue, forKey: Key.audioPlaybackDestination)
            applyAudioPlaybackDestinationLiveHandler?(audioPlaybackDestination)
        }
    }
    @Published var asyncEncoding: Bool {
        didSet { defaults.set(asyncEncoding, forKey: Key.asyncEncoding) }
    }
    @Published var tlsVersionMode: TLSVersionMode {
        didSet { defaults.set(tlsVersionMode.rawValue, forKey: Key.tlsVersionMode) }
    }
    @Published var devLog: Bool {
        didSet {
            defaults.set(devLog, forKey: Key.devLog)
            RDPLog.verbose = devLog
        }
    }
    @Published var appLanguage: String {
        didSet {
            defaults.set(appLanguage, forKey: Key.appLanguage)
            L10n.setLanguage(appLanguage)
            NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
        }
    }
    /// Multiplier for remote mouse-wheel notches (1.0 = natural Windows WHEEL_DELTA).
    @Published var wheelScrollSpeed: Double {
        didSet {
            defaults.set(wheelScrollSpeed, forKey: Key.wheelScrollSpeed)
            MouseHandler.scrollSpeed = wheelScrollSpeed
        }
    }
    /// Flip vertical/horizontal wheel direction on the Mac host.
    @Published var invertWheelScroll: Bool {
        didSet {
            defaults.set(invertWheelScroll, forKey: Key.invertWheelScroll)
            MouseHandler.invertScroll = invertWheelScroll
        }
    }
    @Published var remotePointerScale: Double {
        didSet {
            let normalized = CursorTracker.normalizedScale(remotePointerScale)
            defaults.set(normalized, forKey: Key.remotePointerScale)
        }
    }

    func applyRemotePointerScale() {
        applyRemotePointerScaleHandler?(
            CursorTracker.normalizedScale(remotePointerScale)
        )
    }
    /// Complete remote-key → Mac-key binding table.
    @Published private(set) var keyboardBindings: [RemoteKeyboardKey: MacKeyboardKey] {
        didSet {
            if let data = try? JSONEncoder().encode(keyboardBindings) {
                defaults.set(data, forKey: Key.keyboardBindings)
            }
            KeyboardHandler.bindings = keyboardBindings
        }
    }

    func setKeyboardBinding(_ binding: MacKeyboardKey, for key: RemoteKeyboardKey) {
        keyboardBindings[key] = binding
    }

    func applyKeyboardPreset(_ preset: KeyboardMappingPreset) {
        keyboardBindings = preset.bindings
    }

    /// Live SessionManager access for Connections UI (set by AppDelegate).
    var sessionManagerProvider: (() -> SessionManager?)?

    /// Shared connection history and successfully authenticated IP store.
    let connectionAudit = ConnectionAudit.shared

    nonisolated let rememberedSessionStore = RememberedSessionStore()
    @Published private(set) var rememberedSessionSettings: [RememberedSessionSettings] = []
    var applyRememberedSessionSettingsLiveHandler: ((RememberedSessionSettings) -> Void)?

    func rememberConnection(clientName: String, peerAddress: String) {
        let identity = SessionClientIdentity(clientName: clientName, peerAddress: peerAddress)
        _ = rememberedSessionStore.ensure(
            identity: identity,
            defaultBitrate: videoBitrate,
            defaultFPS: videoFPS,
            defaultAudioDestination: audioPlaybackDestination
        )
        refreshRememberedSessionSettings()
    }

    func updateRememberedSessionSettings(_ settings: RememberedSessionSettings) {
        rememberedSessionStore.update(settings)
        refreshRememberedSessionSettings()
        applyRememberedSessionSettingsLiveHandler?(settings)
    }

    func forgetRememberedSessionSettings(id: String) {
        rememberedSessionStore.remove(id: id)
        refreshRememberedSessionSettings()
    }

    func refreshRememberedSessionSettings() {
        let latest = rememberedSessionStore.all()
        if rememberedSessionSettings != latest {
            rememberedSessionSettings = latest
        }
    }

    /// True when server is listening (UI state; not persisted).
    /// Live-apply power assertions (no restart).
    var applyPowerAssertionsLiveHandler: ((Bool, Bool) -> Void)?

    @Published var preventSystemSleep: Bool {
        didSet {
            defaults.set(preventSystemSleep, forKey: Key.preventSystemSleep)
            applyPowerAssertionsLiveHandler?(preventSystemSleep, preventDisplaySleep)
        }
    }
    @Published var preventDisplaySleep: Bool {
        didSet {
            defaults.set(preventDisplaySleep, forKey: Key.preventDisplaySleep)
            applyPowerAssertionsLiveHandler?(preventSystemSleep, preventDisplaySleep)
        }
    }

    @Published var isServerRunning = false
    @Published var isServerRestarting = false
    /// Human-readable session line for the status menu.
    @Published var sessionStatusText = "No active session"

    private init() {
        let d = UserDefaults.standard
        if !d.bool(forKey: Key.hasLaunchedBefore) {
            d.set(true, forKey: Key.hasLaunchedBefore)
            d.set(3389, forKey: Key.serverPort)
            d.set(true, forKey: Key.authEnabled)
            d.set(false, forKey: Key.knownPeersOnly)
            d.set("user", forKey: Key.username)
            d.set(Self.generatePassword(), forKey: Key.password)
            d.set(true, forKey: Key.autoStartServer)
            d.set(false, forKey: Key.launchAtLogin)
            d.set(0, forKey: Key.idleTimeout)
            d.set(DisplayMode.h264.rawValue, forKey: Key.displayMode)
            d.set(HostDisplayPolicy.automatic.rawValue, forKey: Key.hostDisplayPolicy)
            d.set("", forKey: Key.selectedDisplayIdentity)
            d.set(VideoQualityPreset.default.rawValue, forKey: Key.videoBitrate)
            d.set(VideoFPSPreset.default.rawValue, forKey: Key.videoFPS)
            d.set(VideoAdaptationPriority.qualityFirst.rawValue, forKey: Key.videoAdaptationPriority)
            d.set(AudioPlaybackDestination.both.rawValue, forKey: Key.audioPlaybackDestination)
            d.set("English", forKey: Key.appLanguage)
            d.set(true, forKey: Key.gfxEnabled)
            d.set(true, forKey: Key.asyncEncoding)
            d.set(TLSVersionMode.tls12.rawValue, forKey: Key.tlsVersionMode)
            d.set(false, forKey: Key.devLog)
            d.set(1.0, forKey: Key.wheelScrollSpeed)
            d.set(false, forKey: Key.invertWheelScroll)
            d.set(2.0, forKey: Key.remotePointerScale)
            d.set(true, forKey: Key.preventSystemSleep)
            d.set(false, forKey: Key.preventDisplaySleep)
        }

        let resolvedPassword: String
        if let storedPassword = d.string(forKey: Key.password) {
            resolvedPassword = storedPassword
        } else {
            resolvedPassword = Self.generatePassword()
            d.set(resolvedPassword, forKey: Key.password)
        }

        serverPort = d.object(forKey: Key.serverPort) as? Int ?? 3389
        authEnabled = d.object(forKey: Key.authEnabled) as? Bool ?? true
        knownPeersOnly = d.bool(forKey: Key.knownPeersOnly)
        username = d.string(forKey: Key.username) ?? "user"
        password = resolvedPassword
        autoStartServer = d.object(forKey: Key.autoStartServer) as? Bool ?? true
        launchAtLogin = d.bool(forKey: Key.launchAtLogin)
        idleTimeout = d.object(forKey: Key.idleTimeout) as? Int ?? 0
        let modeRaw = d.string(forKey: Key.displayMode) ?? DisplayMode.h264.rawValue
        displayMode = DisplayMode(rawValue: modeRaw) ?? .h264
        let hostPolicyRaw = d.string(forKey: Key.hostDisplayPolicy)
            ?? HostDisplayPolicy.automatic.rawValue
        hostDisplayPolicy = HostDisplayPolicy(rawValue: hostPolicyRaw) ?? .automatic
        selectedDisplayIdentity = d.string(forKey: Key.selectedDisplayIdentity) ?? ""
        let storedBitrate = d.object(forKey: Key.videoBitrate) as? Int ?? VideoQualityPreset.default.rawValue
        videoBitrate = VideoQualityPreset(rawValue: storedBitrate)?.rawValue
            ?? VideoQualityPreset.default.rawValue
        videoFPS = d.object(forKey: Key.videoFPS) as? Int ?? VideoFPSPreset.default.rawValue
        let priorityRaw = d.string(forKey: Key.videoAdaptationPriority)
            ?? VideoAdaptationPriority.qualityFirst.rawValue
        videoAdaptationPriority = VideoAdaptationPriority(rawValue: priorityRaw) ?? .qualityFirst
        let audioDestinationRaw = d.string(forKey: Key.audioPlaybackDestination)
            ?? AudioPlaybackDestination.both.rawValue
        audioPlaybackDestination = AudioPlaybackDestination(rawValue: audioDestinationRaw) ?? .both
        asyncEncoding = d.object(forKey: Key.asyncEncoding) as? Bool ?? true
        let tlsRaw = d.string(forKey: Key.tlsVersionMode) ?? TLSVersionMode.tls12.rawValue
        tlsVersionMode = TLSVersionMode(rawValue: tlsRaw) ?? .tls12
        devLog = d.object(forKey: Key.devLog) as? Bool ?? false
        appLanguage = d.string(forKey: Key.appLanguage) ?? "English"
        let speed = d.object(forKey: Key.wheelScrollSpeed) as? Double ?? 1.0
        wheelScrollSpeed = min(max(speed, 0.25), 3.0)
        invertWheelScroll = d.bool(forKey: Key.invertWheelScroll)
        remotePointerScale = CursorTracker.normalizedScale(
            d.object(forKey: Key.remotePointerScale) as? Double ?? 2.0
        )
        keyboardBindings = d.data(forKey: Key.keyboardBindings)
            .flatMap { try? JSONDecoder().decode([RemoteKeyboardKey: MacKeyboardKey].self, from: $0) }
            ?? KeyboardMappingPreset.direct.bindings
        // Defaults: keep Mac awake for RDP; allow panel blank (lid / idle).
        preventSystemSleep = d.object(forKey: Key.preventSystemSleep) as? Bool ?? true
        preventDisplaySleep = d.object(forKey: Key.preventDisplaySleep) as? Bool ?? false
        // Persist so toggles and defaults are visible in the plist immediately.
        d.set(audioPlaybackDestination.rawValue, forKey: Key.audioPlaybackDestination)
        d.set(preventSystemSleep, forKey: Key.preventSystemSleep)
        d.set(preventDisplaySleep, forKey: Key.preventDisplaySleep)

        RDPLog.verbose = devLog
        L10n.setLanguage(appLanguage)
        MouseHandler.scrollSpeed = wheelScrollSpeed
        MouseHandler.invertScroll = invertWheelScroll
        KeyboardHandler.bindings = keyboardBindings
        VirtualDisplayManager.setPowerPolicy(
            preventSystemSleep: preventSystemSleep,
            preventDisplaySleep: preventDisplaySleep
        )
        refreshRememberedSessionSettings()
    }

    private static func generatePassword(length: Int = 24) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789-_.!@#")
        var generator = SystemRandomNumberGenerator()
        return String((0..<max(length, 16)).map { _ in
            alphabet.randomElement(using: &generator)!
        })
    }

    func makeServerConfig() -> ServerConfig {
        return ServerConfig(
            port: serverPort,
            username: username,
            password: password,
            nlaEnabled: authEnabled,
            serverName: "SwiftRDP",
            fps: videoFPS,
            appSupportName: "SwiftRDP",
            gfxEnabled: true,
            clipboardEnabled: true,
            audioPlaybackDestination: audioPlaybackDestination,
            displayMode: displayMode,
            idleTimeout: idleTimeout,
            videoBitrate: ServerConfig.normalizedVideoBitrate(videoBitrate),
            tlsVersionMode: tlsVersionMode,
            asyncEncoding: asyncEncoding,
            selectedDisplayIdentity: selectedDisplayIdentity,
            hostDisplayPolicy: hostDisplayPolicy,
            remotePointerScale: remotePointerScale,
            devLog: devLog,
            videoAdaptationPriority: videoAdaptationPriority,
            knownPeersOnly: knownPeersOnly
        )
    }

    /// Local IPv4 addresses suitable for "Copy connection".
    func connectionAddresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return ["127.0.0.1:\(serverPort)"] }
        defer { freeifaddrs(ifaddr) }
        var ptr = first
        while true {
            let iface = ptr.pointee
            if iface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: hostname)
                    if ip != "127.0.0.1" && !ip.hasPrefix("169.254.") {
                        result.append("\(ip):\(serverPort)")
                    }
                }
            }
            guard let next = iface.ifa_next else { break }
            ptr = next
        }
        if result.isEmpty { result.append("127.0.0.1:\(serverPort)") }
        return result
    }
}
