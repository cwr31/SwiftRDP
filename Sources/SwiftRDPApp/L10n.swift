import Foundation

/// In-app EN / 简体中文 strings driven by `AppPreferences.appLanguage`.
enum L10n {
    enum Language: String, CaseIterable, Identifiable {
        case english = "English"
        case simplifiedChinese = "简体中文"

        var id: String { rawValue }

        var isChinese: Bool { self == .simplifiedChinese }

        static func resolve(_ raw: String) -> Language {
            Language(rawValue: raw) ?? .english
        }
    }

    /// Updated from `AppPreferences` on the main thread; read from UI / menus.
    nonisolated(unsafe) private static var languageRaw = Language.english.rawValue

    static var language: Language {
        Language.resolve(languageRaw)
    }

    static func setLanguage(_ raw: String) {
        languageRaw = Language.resolve(raw).rawValue
    }

    static func t(_ key: Key) -> String {
        language.isChinese ? key.zh : key.en
    }

    static func format(_ key: Key, _ args: CVarArg...) -> String {
        String(format: t(key), locale: language.isChinese ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US"), arguments: args)
    }

    enum Key {
        // Settings sidebar / window
        case settingsWindowTitle
        case sectionGeneral, sectionConnections, sectionSession, sectionAudio, sectionPermissions, sectionDisplay, sectionInput, sectionLogs
        case settingsGroupServer, settingsGroupExperience, settingsGroupSupport

        // Permissions
        case permissionsIntro
        case permissionsRequired
        case screenRecording, accessibility
        case screenRecordingDetail, accessibilityDetail
        case granted, notGranted
        case openSystemSettings
        case refresh
        case allPermissionsGranted, actionNeeded
        case permissionsAlertTitle, permissionsAlertBody
        case openSettings, later

        // General
        case authentication
        case requireAuthNLA
        case authHelp
        case username, password
        case usernamePlaceholder, passwordPlaceholder
        case hidePassword, showPassword
        case credentialsEmptyError
        case applyAndRestart
        case savedRestartCredentials
        case activeUser
        case server, port
        case invalidPort, invalidTimeout
        case autoStartServer, launchAtLogin
        case session
        case idleTimeout
        case audioPlaybackDestination
        case audioController, audioHost, audioBoth
        case audioPlaybackHelp
        case power
        case preventSystemSleep, preventSystemSleepHelp
        case preventDisplaySleep, preventDisplaySleepHelp
        case language

        // Display
        case sectionH264, displayMode
        case displayModeBitmap, displayModeH264, displayModeRemoteFX
        case videoQuality
        case videoFPS
        case qualityMbps2, qualityMbps8, qualityMbps20
        case qualityMbps50, qualityMbps100, videoQualityHelp
        case fpsRateTitle
        case monitors, displaySource, displayToShare, autoPrimaryDisplay, displayN
        case displaySourceAutomatic, displaySourceVirtual
        case hostDisplayPolicyHelp
        case resolutionMenu, resolutionMenuPhysical, resolutionMenuVirtual, menuVideo, menuAudio
        case noResolutionOptions
        case videoAdaptationPriority
        case adaptationQualityFirst, adaptationFPSFirst

        // Input
        case mouseWheel, scrollSpeed, scrollSpeedHelp, invertScroll
        case remotePointer, remotePointerSize, remotePointerSizeHelp
        case keyboardMapping
        case keyboardMappingDirect, keyboardMappingWindows, keyboardMappingSwapOptionCommand
        case keyboardBindingPresets, keyboardBindingLoadPreset
        case keyboardBindingRemoteKey, keyboardBindingOutput, keyboardBindingDisabled

        // Logs
        case serverLog, empty, linesCount
        case verbose, follow, reveal
        case verboseHelp
        case filterPlaceholder, clear
        case noLogYet
        case noFilterMatch
        case logNotFound, logReadFailed

        // Menu bar
        case startServer, stopServer
        case openSettingsEllipsis, viewServerLog, checkPermissions
        case copyConnectionAddress, disconnectClient
        case quitApp
        case serverRunning, serverRestarting, restartInProgress, restartRequired, restartServer
        case copyAddress
        case serverStopped, noActiveSession
        case startServerHint
        case notRequired
        case listeningOnPort
        case connected
        case resolutionPort
        case tooltipStopped, tooltipListening
        case serverStartFailed, serverStartFailedBody
        case clientFallback

        // Connections settings
        case accessControl
        case knownPeersOnly, knownPeersOnlyHelp
        case connectionStatus, connectionNone
        case qualityStatus, qualityHealthy, qualityProbing, qualityCongested
        case qualityTarget, qualityQueue, qualityPressure, qualityUnknown, qualitySkipped
        case qualitySourceNetwork, qualitySourceServerQueue, qualitySourceClientQueue
        case qualitySourceDecoder, qualitySourceEncoder
        case connectionsHistory, connectionsHistoryEmpty, connectionsHistoryTruncated
        case clearHistory
        case connectionsStateActive, connectionsStateConnecting
        case connectedFor
        case rememberedConnections, rememberedConnectionsHelp, noRememberedConnections
        case followClientResolution, forgetConnection, lastConnected
        case historyDuration
        case historyOutcomeConnecting, historyOutcomeActive, historyOutcomeDisconnected
        case historyOutcomeAuthFailed, historyOutcomeAbandoned

        var en: String {
            switch self {
            case .settingsWindowTitle: return "SwiftRDP Settings"
            case .sectionGeneral: return "General"
            case .sectionConnections: return "Connections"
            case .sectionSession: return "Session"
            case .sectionAudio: return "Audio"
            case .sectionPermissions: return "Permissions"
            case .sectionDisplay: return "Display"
            case .sectionInput: return "Input"
            case .sectionLogs: return "Logs"
            case .settingsGroupServer: return "Server"
            case .settingsGroupExperience: return "Experience"
            case .settingsGroupSupport: return "Support"

            case .permissionsIntro:
                return "SwiftRDP needs these macOS permissions to run a remote session. Status refreshes automatically when you return from System Settings."
            case .permissionsRequired: return "Required"
            case .screenRecording: return "Screen Recording"
            case .accessibility: return "Accessibility"
            case .screenRecordingDetail: return "Capture this Mac’s display for the RDP client."
            case .accessibilityDetail: return "Inject keyboard and mouse from the remote client."
            case .granted: return "Granted"
            case .notGranted: return "Not Granted"
            case .openSystemSettings: return "Open System Settings…"
            case .refresh: return "Refresh"
            case .allPermissionsGranted: return "All required permissions granted"
            case .actionNeeded: return "Action needed"
            case .permissionsAlertTitle: return "Permissions Required"
            case .permissionsAlertBody:
                return "SwiftRDP needs:\n\n• Screen Recording — capture the Mac display for RDP\n• Accessibility — inject keyboard and mouse from the remote client\n\nYou can also check status anytime in Settings → Permissions."
            case .openSettings: return "Open Settings"
            case .later: return "Later"

            case .authentication: return "Authentication"
            case .requireAuthNLA: return "Require authentication (NLA)"
            case .authHelp: return "RDP clients (for example Microsoft Remote Desktop) sign in with this username and password."
            case .username: return "Username"
            case .password: return "Password"
            case .usernamePlaceholder: return "e.g. user"
            case .passwordPlaceholder: return "password"
            case .hidePassword: return "Hide password"
            case .showPassword: return "Show password"
            case .credentialsEmptyError: return "Username and password cannot be empty when authentication is on."
            case .applyAndRestart: return "Apply & Restart Server"
            case .savedRestartCredentials: return "Saved — restart to use new credentials"
            case .activeUser: return "Active: %@"
            case .server: return "Server"
            case .port: return "Port"
            case .invalidPort: return "Enter a port from 1 to 65535."
            case .invalidTimeout: return "Enter 0 or a positive number of minutes."
            case .autoStartServer: return "Auto-start Server"
            case .launchAtLogin: return "Launch at Login"
            case .session: return "Session"
            case .idleTimeout: return "Idle Timeout (minutes, 0 = off)"
            case .audioPlaybackDestination: return "Play audio on"
            case .audioController: return "Controller"
            case .audioHost: return "Controlled Mac"
            case .audioBoth: return "Both Devices"
            case .audioPlaybackHelp:
                return "Controller and Both stream 48 kHz stereo audio over RDP. Controller temporarily suppresses local hardware playback only while a client is connected."
            case .power: return "Power"
            case .preventSystemSleep: return "Prevent System Sleep"
            case .preventSystemSleepHelp: return "Keep the Mac awake while the RDP server is running (works with the lid closed)."
            case .preventDisplaySleep: return "Prevent Display Sleep"
            case .preventDisplaySleepHelp: return "Keep displays awake while the server is running. MacBooks keep the built-in panel on only while mirroring an awake physical display (not when clamshell virtual capture is active)."
            case .language: return "Language"

            case .sectionH264: return "H.264"
            case .displayMode: return "Display Mode"
            case .displayModeBitmap: return "Bitmap"
            case .displayModeH264: return "H.264"
            case .displayModeRemoteFX: return "RemoteFX"
            case .videoQuality: return "Video Quality"
            case .qualityMbps2: return "2 Mbps"
            case .qualityMbps8: return "8 Mbps"
            case .qualityMbps20: return "20 Mbps"
            case .qualityMbps50: return "50 Mbps"
            case .qualityMbps100: return "100 Mbps"
            case .videoQualityHelp:
                return "Bitrate ceiling. The controller adapts down when the link, client queue, or encoder is under pressure. H.264 remains compressed, not lossless."
            case .videoFPS: return "Frame Rate"
            case .fpsRateTitle: return "%d fps"
            case .monitors: return "Monitors"
            case .displaySource: return "Desktop source"
            case .displayToShare: return "Display to share"
            case .autoPrimaryDisplay: return "Primary physical display"
            case .displayN: return "Display %u"
            case .displaySourceAutomatic: return "Automatic"
            case .displaySourceVirtual: return "Always use virtual display"
            case .hostDisplayPolicyHelp: return "Automatic mirrors the selected hardware display when drawable, otherwise it uses a client-sized virtual desktop."
            case .resolutionMenu: return "Resolution"
            case .resolutionMenuPhysical: return "Physical display"
            case .resolutionMenuVirtual: return "Virtual display"
            case .menuVideo: return "Video"
            case .menuAudio: return "Audio"
            case .noResolutionOptions: return "No resolutions available"
            case .videoAdaptationPriority: return "When targets can't be met"
            case .adaptationQualityFirst: return "Quality first"
            case .adaptationFPSFirst: return "FPS first"

            case .mouseWheel: return "Mouse Wheel"
            case .scrollSpeed: return "Scroll Speed"
            case .scrollSpeedHelp: return "Multiplies remote wheel notches on this Mac. Takes effect immediately."
            case .invertScroll: return "Invert Scroll Direction"
            case .remotePointer: return "Remote Pointer"
            case .remotePointerSize: return "Pointer Size"
            case .remotePointerSizeHelp: return "Scales the pointer shown by RDP clients. Applies when you release the slider."

            case .keyboardMapping: return "Keyboard Mapping"
            case .keyboardMappingDirect: return "Direct (physical position)"
            case .keyboardMappingWindows: return "Windows shortcuts"
            case .keyboardMappingSwapOptionCommand: return "Swap ⌥ and ⌘"
            case .keyboardBindingPresets: return "Binding template"
            case .keyboardBindingLoadPreset: return "Load Template"
            case .keyboardBindingRemoteKey: return "Remote key"
            case .keyboardBindingOutput: return "Mac output"
            case .keyboardBindingDisabled: return "No action"

            case .serverLog: return "Server Log"
            case .empty: return "empty"
            case .linesCount: return "%d lines"
            case .verbose: return "Verbose"
            case .follow: return "Follow"
            case .reveal: return "Reveal"
            case .verboseHelp: return "Write INFO/DEBUG to server.log (ERROR always logged)"
            case .filterPlaceholder: return "Filter…"
            case .clear: return "Clear"
            case .noLogYet: return "No log output yet.\nStart the server or turn on Verbose to capture more detail."
            case .noFilterMatch: return "(no lines match filter)"
            case .logNotFound: return "Log file not found yet."
            case .logReadFailed: return "Could not read log file."

            case .startServer: return "Start Server"
            case .stopServer: return "Stop Server"
            case .openSettingsEllipsis: return "Open Settings…"
            case .viewServerLog: return "View Server Log…"
            case .checkPermissions: return "Check Permissions…"
            case .copyConnectionAddress: return "Copy Connection Address"
            case .disconnectClient: return "Disconnect Client"
            case .quitApp: return "Quit SwiftRDP"
            case .serverRunning: return "Server running"
            case .serverRestarting: return "Applying changes"
            case .restartInProgress: return "Restarting server…"
            case .restartRequired: return "Some changes take effect after a server restart."
            case .restartServer: return "Restart Server"
            case .copyAddress: return "Copy Address"
            case .serverStopped: return "Server stopped"
            case .noActiveSession: return "No active session"
            case .startServerHint: return "Start Server to accept RDP connections"
            case .notRequired: return "Not required"
            case .listeningOnPort: return "Listening on port %d"
            case .connected: return "Connected"
            case .resolutionPort: return "%d×%d · port %d"
            case .tooltipStopped: return "SwiftRDP — server stopped"
            case .tooltipListening: return "SwiftRDP — listening on port %d"
            case .serverStartFailed: return "Server Start Failed"
            case .serverStartFailedBody: return "Could not bind to port %d. Another RDP app may be using this port."
            case .clientFallback: return "client"

            case .accessControl: return "Access Control"
            case .knownPeersOnly: return "Only previously authenticated IPs"
            case .knownPeersOnlyHelp:
                return "When enabled, only IPs that have authenticated successfully before may connect. Turn it off to enroll a new IP."
            case .rememberedConnections: return "Remembered Connection Settings"
            case .rememberedConnectionsHelp:
                return "Each client keeps its own resolution, video quality, and frame rate. Menu changes made while connected are saved here."
            case .noRememberedConnections: return "Connect a client once to create its settings."
            case .followClientResolution: return "Follow client resolution"
            case .forgetConnection: return "Forget Connection"
            case .lastConnected: return "Last connected %@"
            case .connectionStatus: return "Connection"
            case .connectionNone: return "No client connected."
            case .qualityStatus: return "Video quality"
            case .qualityHealthy: return "Healthy"
            case .qualityProbing: return "Probing"
            case .qualityCongested: return "Congested"
            case .qualityTarget: return "Target %d fps · %.1f Mbps"
            case .qualityQueue: return "Client queue %@ · server queue %.0f ms"
            case .qualityPressure: return "%@ %.0f%%"
            case .qualityUnknown: return "unknown"
            case .qualitySkipped: return "Capture skipped %llu"
            case .qualitySourceNetwork: return "Network"
            case .qualitySourceServerQueue: return "Server queue"
            case .qualitySourceClientQueue: return "Client queue"
            case .qualitySourceDecoder: return "Decoder"
            case .qualitySourceEncoder: return "Encoder"
            case .connectionsHistory: return "History"
            case .connectionsHistoryEmpty: return "No connection history yet."
            case .connectionsHistoryTruncated: return "Showing latest 100 of %d entries."
            case .clearHistory: return "Clear History"
            case .connectionsStateActive: return "Active"
            case .connectionsStateConnecting: return "Connecting"
            case .connectedFor: return "Connected for %@"
            case .historyDuration: return "Duration: %@"
            case .historyOutcomeConnecting: return "Connecting"
            case .historyOutcomeActive: return "Active"
            case .historyOutcomeDisconnected: return "Disconnected"
            case .historyOutcomeAuthFailed: return "Auth failed"
            case .historyOutcomeAbandoned: return "Abandoned"
            }
        }

        var zh: String {
            switch self {
            case .settingsWindowTitle: return "SwiftRDP 设置"
            case .sectionGeneral: return "通用"
            case .sectionConnections: return "连接"
            case .sectionSession: return "会话"
            case .sectionAudio: return "音频"
            case .sectionPermissions: return "权限"
            case .sectionDisplay: return "显示"
            case .sectionInput: return "输入"
            case .sectionLogs: return "日志"
            case .settingsGroupServer: return "服务器"
            case .settingsGroupExperience: return "体验"
            case .settingsGroupSupport: return "支持"

            case .permissionsIntro:
                return "SwiftRDP 需要这些 macOS 权限才能进行远程会话。从“系统设置”返回后状态会自动刷新。"
            case .permissionsRequired: return "必需"
            case .screenRecording: return "屏幕录制"
            case .accessibility: return "辅助功能"
            case .screenRecordingDetail: return "捕获本机屏幕画面供 RDP 客户端使用。"
            case .accessibilityDetail: return "注入来自远程客户端的键盘和鼠标输入。"
            case .granted: return "已授权"
            case .notGranted: return "未授权"
            case .openSystemSettings: return "打开系统设置授权…"
            case .refresh: return "刷新"
            case .allPermissionsGranted: return "所需权限均已授予"
            case .actionNeeded: return "需要操作"
            case .permissionsAlertTitle: return "需要权限"
            case .permissionsAlertBody:
                return "SwiftRDP 需要：\n\n• 屏幕录制 — 捕获 Mac 屏幕用于 RDP\n• 辅助功能 — 注入远程客户端的键盘和鼠标\n\n也可随时在“设置 → 权限”中查看状态。"
            case .openSettings: return "打开设置"
            case .later: return "稍后"

            case .authentication: return "身份验证"
            case .requireAuthNLA: return "要求身份验证（NLA）"
            case .authHelp: return "RDP 客户端（例如 Microsoft Remote Desktop）使用此用户名和密码登录。"
            case .username: return "用户名"
            case .password: return "密码"
            case .usernamePlaceholder: return "例如 user"
            case .passwordPlaceholder: return "密码"
            case .hidePassword: return "隐藏密码"
            case .showPassword: return "显示密码"
            case .credentialsEmptyError: return "开启身份验证时，用户名和密码不能为空。"
            case .applyAndRestart: return "应用并重启服务器"
            case .savedRestartCredentials: return "已保存 — 重启后生效"
            case .activeUser: return "当前：%@"
            case .server: return "服务器"
            case .port: return "端口"
            case .invalidPort: return "请输入 1 到 65535 之间的端口。"
            case .invalidTimeout: return "请输入 0 或更大的分钟数。"
            case .autoStartServer: return "自动启动服务器"
            case .launchAtLogin: return "登录时启动"
            case .session: return "会话"
            case .idleTimeout: return "空闲超时（分钟，0 = 关闭）"
            case .audioPlaybackDestination: return "音频播放位置"
            case .audioController: return "控制端"
            case .audioHost: return "被控端"
            case .audioBoth: return "两端"
            case .audioPlaybackHelp:
                return "“控制端”和“两端”会通过 RDP 传输 48 kHz 立体声音频；选择“控制端”时，仅在客户端连接期间抑制被控 Mac 的硬件播放。"
            case .power: return "电源"
            case .preventSystemSleep: return "防止系统休眠"
            case .preventSystemSleepHelp: return "RDP 服务器运行时保持 Mac 不休眠（合盖后机器也可继续运行）。"
            case .preventDisplaySleep: return "防止屏幕休眠"
            case .preventDisplaySleepHelp: return "服务器运行期间保持显示器唤醒。MacBook 仅在镜像可用内建/外接物理屏时唤醒内建屏（合盖虚拟屏推流时不会强拉内屏）。"
            case .language: return "语言"

            case .sectionH264: return "H.264"
            case .displayMode: return "显示模式"
            case .displayModeBitmap: return "位图"
            case .displayModeH264: return "H.264"
            case .displayModeRemoteFX: return "RemoteFX"
            case .videoQuality: return "视频质量"
            case .qualityMbps2: return "2 Mbps"
            case .qualityMbps8: return "8 Mbps"
            case .qualityMbps20: return "20 Mbps"
            case .qualityMbps50: return "50 Mbps"
            case .qualityMbps100: return "100 Mbps"
            case .videoQualityHelp:
                return "码率上限。网络、客户端队列或编码器有压力时，控制器会自动降低码率或帧率。H.264 仍有压缩，不是无损。"
            case .videoFPS: return "帧率"
            case .fpsRateTitle: return "%d fps"
            case .monitors: return "显示器"
            case .displaySource: return "桌面来源"
            case .displayToShare: return "共享的显示器"
            case .autoPrimaryDisplay: return "主物理显示器"
            case .displayN: return "显示器 %u"
            case .displaySourceAutomatic: return "自动"
            case .displaySourceVirtual: return "始终使用虚拟屏"
            case .hostDisplayPolicyHelp: return "自动模式会镜像当前可绘制的首选硬件显示器，否则使用匹配客户端的虚拟桌面。"
            case .resolutionMenu: return "分辨率"
            case .resolutionMenuPhysical: return "物理屏"
            case .resolutionMenuVirtual: return "虚拟屏"
            case .menuVideo: return "视频"
            case .menuAudio: return "音频"
            case .noResolutionOptions: return "暂无可用分辨率"
            case .videoAdaptationPriority: return "无法同时达标时"
            case .adaptationQualityFirst: return "画质优先"
            case .adaptationFPSFirst: return "帧率优先"

            case .mouseWheel: return "鼠标滚轮"
            case .scrollSpeed: return "滚动速度"
            case .scrollSpeedHelp: return "乘以远程滚轮步进，在本机立即生效。"
            case .invertScroll: return "反转滚动方向"
            case .remotePointer: return "远程指针"
            case .remotePointerSize: return "指针大小"
            case .remotePointerSizeHelp: return "调整 RDP 客户端显示的指针大小，松开滑块后立即生效。"

            case .keyboardMapping: return "键盘映射"
            case .keyboardMappingDirect: return "直接映射（物理位置）"
            case .keyboardMappingWindows: return "Windows 快捷键"
            case .keyboardMappingSwapOptionCommand: return "交换 ⌥ 与 ⌘"
            case .keyboardBindingPresets: return "绑定模板"
            case .keyboardBindingLoadPreset: return "载入模板"
            case .keyboardBindingRemoteKey: return "远程按键"
            case .keyboardBindingOutput: return "Mac 输出"
            case .keyboardBindingDisabled: return "无操作"

            case .serverLog: return "服务器日志"
            case .empty: return "空"
            case .linesCount: return "%d 行"
            case .verbose: return "详细"
            case .follow: return "跟随"
            case .reveal: return "在访达中显示"
            case .verboseHelp: return "将 INFO/DEBUG 写入 server.log（ERROR 始终记录）"
            case .filterPlaceholder: return "筛选…"
            case .clear: return "清除"
            case .noLogYet: return "暂无日志。\n启动服务器或打开“详细”以捕获更多信息。"
            case .noFilterMatch: return "（没有匹配的行）"
            case .logNotFound: return "尚未找到日志文件。"
            case .logReadFailed: return "无法读取日志文件。"

            case .startServer: return "启动服务器"
            case .stopServer: return "停止服务器"
            case .openSettingsEllipsis: return "打开设置…"
            case .viewServerLog: return "查看服务器日志…"
            case .checkPermissions: return "检查权限…"
            case .copyConnectionAddress: return "复制连接地址"
            case .disconnectClient: return "断开客户端"
            case .quitApp: return "退出 SwiftRDP"
            case .serverRunning: return "服务器运行中"
            case .serverRestarting: return "正在应用更改"
            case .restartInProgress: return "正在重启服务器…"
            case .restartRequired: return "部分更改需要重启服务器后生效。"
            case .restartServer: return "重启服务器"
            case .copyAddress: return "复制地址"
            case .serverStopped: return "服务器已停止"
            case .noActiveSession: return "无活动会话"
            case .startServerHint: return "启动服务器以接受 RDP 连接"
            case .notRequired: return "不要求"
            case .listeningOnPort: return "正在监听端口 %d"
            case .connected: return "已连接"
            case .resolutionPort: return "%d×%d · 端口 %d"
            case .tooltipStopped: return "SwiftRDP — 服务器已停止"
            case .tooltipListening: return "SwiftRDP — 正在监听端口 %d"
            case .serverStartFailed: return "服务器启动失败"
            case .serverStartFailedBody: return "无法绑定端口 %d。可能有其他 RDP 应用占用了该端口。"
            case .clientFallback: return "客户端"

            case .accessControl: return "访问控制"
            case .knownPeersOnly: return "仅允许成功认证过的 IP"
            case .knownPeersOnlyHelp:
                return "开启后，只允许曾经成功认证的 IP 连接。接纳新 IP 时，请临时关闭此开关。"
            case .rememberedConnections: return "已记住的连接设置"
            case .rememberedConnectionsHelp:
                return "每个客户端分别保存分辨率、视频质量和帧率；连接期间通过菜单修改后会自动记住。"
            case .noRememberedConnections: return "客户端连接一次后，会在这里创建独立设置。"
            case .followClientResolution: return "跟随客户端分辨率"
            case .forgetConnection: return "忘记此连接"
            case .lastConnected: return "上次连接 %@"
            case .connectionStatus: return "连接状态"
            case .connectionNone: return "暂无客户端连接。"
            case .qualityStatus: return "视频质量"
            case .qualityHealthy: return "良好"
            case .qualityProbing: return "探测中"
            case .qualityCongested: return "拥塞"
            case .qualityTarget: return "目标 %d fps · %.1f Mbps"
            case .qualityQueue: return "客户端队列 %@ · 服务端队列 %.0f ms"
            case .qualityPressure: return "%@ %.0f%%"
            case .qualityUnknown: return "未知"
            case .qualitySkipped: return "捕获跳过 %llu 帧"
            case .qualitySourceNetwork: return "网络"
            case .qualitySourceServerQueue: return "服务端队列"
            case .qualitySourceClientQueue: return "客户端队列"
            case .qualitySourceDecoder: return "解码器"
            case .qualitySourceEncoder: return "编码器"
            case .connectionsHistory: return "历史记录"
            case .connectionsHistoryEmpty: return "暂无连接历史。"
            case .connectionsHistoryTruncated: return "显示最近 100 条，共 %d 条。"
            case .clearHistory: return "清除历史"
            case .connectionsStateActive: return "活动"
            case .connectionsStateConnecting: return "连接中"
            case .connectedFor: return "已连接 %@"
            case .historyDuration: return "时长：%@"
            case .historyOutcomeConnecting: return "连接中"
            case .historyOutcomeActive: return "活动"
            case .historyOutcomeDisconnected: return "已断开"
            case .historyOutcomeAuthFailed: return "身份验证失败"
            case .historyOutcomeAbandoned: return "已放弃"
            }
        }
    }
}

extension Notification.Name {
    static let appLanguageDidChange = Notification.Name("SwiftRDPAppLanguageDidChange")
}
