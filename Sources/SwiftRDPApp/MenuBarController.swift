import AppKit
import Combine
import SwiftRDPCore

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let prefs: AppPreferences
    private let onAction: (AppAction) -> Void
    private let customBitrateMenu: CustomBitrateMenuController
    private var statusItem: NSStatusItem?
    private var statusObservation: AnyCancellable?
    private var selectionObservation: AnyCancellable?
    private var qualityItems: [VideoQualityMode: NSMenuItem] = [:]
    private var fpsItems: [VideoFPSPreset: NSMenuItem] = [:]
    private var audioItems: [AudioPlaybackDestination: NSMenuItem] = [:]

    init(prefs: AppPreferences, onAction: @escaping (AppAction) -> Void) {
        self.prefs = prefs
        self.onAction = onAction
        customBitrateMenu = CustomBitrateMenuController(prefs: prefs)
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        customBitrateMenu.onCommit = { [weak self] in self?.refreshSelectionStates() }
        selectionObservation = prefs.objectWillChange.sink { [weak self] in
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated { self?.refreshSelectionStates() }
            }
        }
    }

    func install() {
        guard statusItem == nil else { return }
        refresh()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "SwiftRDP"
        item.menu = menu
        item.button?.setAccessibilityLabel("SwiftRDP")
        statusItem = item
        updateStatusIcon()
        statusObservation = prefs.$isServerRunning.combineLatest(prefs.$isServerRestarting)
            .sink { [weak self] running, restarting in
                self?.updateStatusIcon(running: running, restarting: restarting)
            }
    }

    func remove() {
        statusObservation = nil
        selectionObservation = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        onAction(.refreshStatus)
        refresh()
    }

    func refresh() {
        menu.removeAllItems()
        qualityItems.removeAll()
        fpsItems.removeAll()
        audioItems.removeAll()
        let snapshot = activeSnapshot
        let available = prefs.isServerRunning && !prefs.isServerRestarting

        addInfo(prefs.sessionStatusText, to: menu, prominent: true)
        let detail = prefs.isServerRestarting ? L10n.t(.restartInProgress)
            : prefs.isServerRunning ? L10n.format(.listeningOnPort, prefs.serverPort) : L10n.t(.startServerHint)
        addInfo(detail, to: menu)
        if let quality = snapshot?.quality {
            let title: String
            switch quality.state {
            case .unknown: title = L10n.t(.qualityUnknown)
            case .healthy: title = L10n.t(.qualityHealthy)
            case .probing: title = L10n.t(.qualityProbing)
            case .congested: title = L10n.t(.qualityCongested)
            }
            addInfo(title, to: menu)
            addInfo(L10n.format(.qualityTarget, quality.targetFPS, Double(quality.targetBitrate) / 1_000_000), to: menu)
        }
        menu.addItem(.separator())
        addAction(prefs.isServerRunning ? L10n.t(.stopServer) : L10n.t(.startServer), .toggleServer,
                  to: menu, enabled: !prefs.isServerRestarting, symbol: prefs.isServerRunning ? "stop.fill" : "play.fill")
        addAction(L10n.t(.copyConnectionAddress), .copyAddress, to: menu, enabled: available, symbol: "doc.on.doc")
        if snapshot != nil {
            addAction(L10n.t(.disconnectClient), .disconnect, to: menu, symbol: "xmark.circle")
        }

        let resolution = addSubmenu(L10n.t(.resolutionMenu), to: menu, enabled: snapshot != nil,
                                    symbol: "rectangle.on.rectangle")
        let options = prefs.sessionManagerProvider?()?.hostResolutionOptions() ?? []
        if options.isEmpty {
            addInfo(L10n.t(.noResolutionOptions), to: resolution)
        } else {
            for option in options {
                let title = "\(option.pointWidth)x\(option.pointHeight)" + (option.hiDPI ? " (HiDPI)" : "")
                let item = addAction(title, .resolution(option), to: resolution)
                item.state = option.isCurrent ? .on : .off
            }
        }

        let video = addSubmenu(L10n.t(prefs.displayMode == .h264 ? .videoQuality : .videoFPS),
                               to: menu, enabled: available, symbol: "photo")
        if prefs.displayMode == .h264 {
            for mode in VideoQualityMode.allCases {
                if mode == .custom {
                    let item = NSMenuItem(title: mode.title, action: nil, keyEquivalent: "")
                    item.submenu = customBitrateMenu.menu
                    video.addItem(item)
                    qualityItems[mode] = item
                } else {
                    qualityItems[mode] = addAction(mode.title, .quality(mode), to: video)
                }
            }
            video.addItem(.separator())
        }
        addInfo(L10n.t(.videoFPS), to: video)
        for fps in VideoFPSPreset.allCases.reversed() {
            fpsItems[fps] = addAction(fps.title, .fps(fps), to: video)
        }

        let audio = addSubmenu(L10n.t(.menuAudio), to: menu, enabled: available, symbol: "speaker.wave.2")
        for destination in AudioPlaybackDestination.allCases {
            let title: String
            switch destination {
            case .controller: title = L10n.t(.audioController)
            case .host: title = L10n.t(.audioHost)
            case .both: title = L10n.t(.audioBoth)
            }
            audioItems[destination] = addAction(title, .audio(destination), to: audio)
        }
        menu.addItem(.separator())
        addAction(L10n.t(.openSettingsEllipsis), .settings(nil), to: menu, symbol: "gearshape")
        addAction(L10n.t(.viewServerLog), .settings(.logs), to: menu, symbol: "doc.text")
        addAction(L10n.t(.checkPermissions), .settings(.permissions), to: menu, symbol: "lock.shield")
        menu.addItem(.separator())
        addAction(L10n.t(.quitApp), .quit, to: menu)
        refreshSelectionStates()
    }

    func refreshSelectionStates() {
        let snapshot = activeSnapshot
        let quality: VideoQualitySettings
        if let snapshot {
            quality = snapshot.videoQuality
        } else {
            quality = prefs.videoQuality
        }
        for (mode, item) in qualityItems { item.state = mode == quality.mode ? .on : .off }
        let fps = snapshot?.configuredFPS ?? prefs.videoFPS
        for (preset, item) in fpsItems { item.state = preset.rawValue == fps ? .on : .off }
        let destination = snapshot?.audioPlaybackDestination ?? prefs.audioPlaybackDestination
        for (candidate, item) in audioItems { item.state = candidate == destination ? .on : .off }
    }

    private var activeSnapshot: SessionManager.ConnectionSnapshot? {
        guard prefs.isServerRunning, !prefs.isServerRestarting,
              let manager = prefs.sessionManagerProvider?(), manager.hasActiveSession else { return nil }
        return manager.connectionSnapshot
    }

    private func updateStatusIcon(running: Bool? = nil, restarting: Bool? = nil) {
        let symbol = (restarting ?? prefs.isServerRestarting) ? "arrow.triangle.2.circlepath"
            : (running ?? prefs.isServerRunning) ? "display.and.arrow.down" : "display"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "SwiftRDP")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    private func addInfo(_ title: String, to menu: NSMenu, prominent: Bool = false) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if prominent {
            item.attributedTitle = NSAttributedString(string: title,
                attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        }
        menu.addItem(item)
    }

    @discardableResult
    private func addAction(_ title: String, _ action: AppAction, to menu: NSMenu,
                           enabled: Bool = true, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        item.isEnabled = enabled
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.addItem(item)
        return item
    }

    private func addSubmenu(_ title: String, to menu: NSMenu, enabled: Bool = true,
                            symbol: String) -> NSMenu {
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.isEnabled = enabled
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(item)
        return submenu
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? AppAction else { return }
        onAction(action)
        refreshSelectionStates()
    }
}
