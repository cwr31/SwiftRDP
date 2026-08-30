import CoreGraphics
import ColorSync
import Foundation

/// Runtime desktop source after resolving the configured policy.
public enum HostDisplayMode: String, Sendable {
    case physicalMirror
    case virtualMatchClient
}

/// One selectable resolution for the menu bar / live apply path.
public struct HostResolutionOption: Equatable, Sendable {
    /// Dimensions used when applying.
    /// Physical = CG “Looks like” points (`CGDisplayMode.width/height`);
    /// Virtual non-HiDPI = pixel desktop size; Virtual HiDPI = 2× pixel framebuffer size.
    public let width: Int
    public let height: Int
    /// Menu label size (physical / virtual “Looks like”; same as `width`/`height` when not HiDPI).
    public let pointWidth: Int
    public let pointHeight: Int
    /// Retina-style scaled mode (2× backing store on virtual; HiDPI twin on physical).
    public let hiDPI: Bool
    public let isCurrent: Bool

    public init(
        width: Int,
        height: Int,
        pointWidth: Int? = nil,
        pointHeight: Int? = nil,
        hiDPI: Bool = false,
        isCurrent: Bool = false
    ) {
        self.width = width
        self.height = height
        self.pointWidth = pointWidth ?? width
        self.pointHeight = pointHeight ?? height
        self.hiDPI = hiDPI
        self.isCurrent = isCurrent
    }

    /// System Settings style: `1512×982 (HiDPI)`.
    public var title: String {
        var label = "\(pointWidth)×\(pointHeight)"
        if hiDPI { label += " (HiDPI)" }
        if isCurrent { label += " ✓" }
        return label
    }
}

/// Pixel + logical sizing for Virtual Display create/refresh.
public struct VirtualDisplayParameters: Equatable, Sendable {
    public static let maxPixelWidth = 3840
    public static let maxPixelHeight = 2400

    public let pixelWidth: Int
    public let pixelHeight: Int
    public let preferHiDPI: Bool
    public let logicalWidth: Int
    public let logicalHeight: Int

    public init(
        pixelWidth: Int,
        pixelHeight: Int,
        preferHiDPI: Bool,
        logicalWidth: Int,
        logicalHeight: Int
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.preferHiDPI = preferHiDPI
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
    }

    public static func native(pixelWidth: Int, pixelHeight: Int) -> Self {
        let (w, h) = fitWithinPixelLimit(width: pixelWidth, height: pixelHeight)
        return Self(
            pixelWidth: w,
            pixelHeight: h,
            preferHiDPI: false,
            logicalWidth: w,
            logicalHeight: h
        )
    }

    static func fitWithinPixelLimit(width: Int, height: Int) -> (Int, Int) {
        let sourceWidth = max(width, 2)
        let sourceHeight = max(height, 2)
        let scale = min(
            1.0,
            min(
                Double(maxPixelWidth) / Double(sourceWidth),
                Double(maxPixelHeight) / Double(sourceHeight)
            )
        )
        let width = max((Int(Double(sourceWidth) * scale)) & ~1, 2)
        let height = max((Int(Double(sourceHeight) * scale)) & ~1, 2)
        return (width, height)
    }
}

/// Display presence + resolution listing/apply helpers (CoreGraphics).
public enum DisplayTopology {
    public enum ReconfigurationImpact: String, Equatable, Sendable {
        case none
        case geometry
        case topology
    }

    // CoreGraphics assigns these four-character codes to CGVirtualDisplay devices.
    private static let virtualVendorID: UInt32 = 0x756E_6B6E // "unkn"
    private static let virtualModelID: UInt32 = 0x7669_7274 // "virt"

    /// Presets offered when running on a Virtual Display (Match Client).
    public static let virtualPresets: [(Int, Int)] = [
        (1280, 720),
        (1280, 800),
        (1512, 982),
        (1920, 1080),
        (1920, 1200),
        (2560, 1440),
        (2560, 1600),
        (3024, 1964),
        (3840, 2160),
    ]

    /// True when an awake built-in panel is currently drawable.
    public static func hasAwakeBuiltInDisplay() -> Bool {
        physicalDisplayIDs().contains { CGDisplayIsBuiltin($0) != 0 }
    }

    /// True when at least one active physical panel is online.
    public static func hasUsablePhysicalDisplay() -> Bool {
        !physicalDisplayIDs().isEmpty
    }

    public static func preferredMode(policy: HostDisplayPolicy) -> HostDisplayMode {
        resolvedMode(policy: policy, hasPhysicalDisplay: hasUsablePhysicalDisplay())
    }

    static func resolvedMode(
        policy: HostDisplayPolicy,
        hasPhysicalDisplay: Bool
    ) -> HostDisplayMode {
        switch policy {
        case .virtual:
            return .virtualMatchClient
        case .automatic:
            return hasPhysicalDisplay ? .physicalMirror : .virtualMatchClient
        }
    }

    public static func reconfigurationImpact(
        flags: CGDisplayChangeSummaryFlags,
        autoSelectPrimary: Bool
    ) -> ReconfigurationImpact {
        if flags.contains(.addFlag)
            || flags.contains(.removeFlag)
            || flags.contains(.enabledFlag)
            || flags.contains(.disabledFlag)
            || flags.contains(.mirrorFlag)
            || flags.contains(.unMirrorFlag) {
            return .topology
        }
        if flags.contains(.setModeFlag)
            || flags.contains(.desktopShapeChangedFlag)
            || (autoSelectPrimary && flags.contains(.setMainFlag)) {
            return .geometry
        }
        return .none
    }

    /// Online + active + awake hardware displays.
    public static func physicalDisplayIDs() -> [CGDirectDisplayID] {
        onlineDisplayIDs().filter { id in
            if CGDisplayIsActive(id) == 0 { return false }
            if CGDisplayIsAsleep(id) != 0 { return false }
            return !isVirtualDisplay(
                vendorID: CGDisplayVendorNumber(id),
                modelID: CGDisplayModelNumber(id)
            )
        }
    }

    static func isVirtualDisplay(vendorID: UInt32, modelID: UInt32) -> Bool {
        (vendorID == virtualVendorID && modelID == virtualModelID)
            || (vendorID == VirtualDisplayIdentity.vendorID
                && modelID == VirtualDisplayIdentity.productID)
    }

    struct PhysicalDisplayDescriptor: Equatable, Sendable {
        let id: CGDirectDisplayID
        let identity: String
    }

    private static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else {
            return []
        }
        return Array(ids.prefix(Int(count)))
    }

    /// Identity that survives display sleep/wake and CGDirectDisplayID reassignment.
    public static func stableDisplayIdentity(for displayID: CGDirectDisplayID) -> String {
        if let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID),
           let uuid = CFUUIDCreateString(nil, cfUUID.takeRetainedValue()) {
            return "uuid:\(uuid as String)"
        }
        return "v\(CGDisplayVendorNumber(displayID))-m\(CGDisplayModelNumber(displayID))-s\(CGDisplaySerialNumber(displayID))"
    }

    static func selectPhysicalDisplayID(
        from displays: [PhysicalDisplayDescriptor],
        preferredIdentity: String,
        mainDisplayID: CGDirectDisplayID
    ) -> CGDirectDisplayID? {
        guard !displays.isEmpty else { return nil }
        if !preferredIdentity.isEmpty,
           let preferred = displays.first(where: { $0.identity == preferredIdentity }) {
            return preferred.id
        }
        if let main = displays.first(where: { $0.id == mainDisplayID }) {
            return main.id
        }
        return displays[0].id
    }

    public static func physicalDisplayID(preferredIdentity: String = "") -> CGDirectDisplayID? {
        let displays = physicalDisplayIDs().map {
            PhysicalDisplayDescriptor(id: $0, identity: stableDisplayIdentity(for: $0))
        }
        return selectPhysicalDisplayID(
            from: displays,
            preferredIdentity: preferredIdentity,
            mainDisplayID: CGMainDisplayID()
        )
    }

    /// Modes for the physical panel, unique by “Looks like” point size (HiDPI preferred).
    public static func physicalResolutionOptions(
        displayID: CGDirectDisplayID
    ) -> [HostResolutionOption] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode],
              let current = CGDisplayCopyDisplayMode(displayID)
        else {
            return []
        }
        let curPointsW = current.width
        let curPointsH = current.height
        var best: [String: CGDisplayMode] = [:]
        for mode in modes {
            let pointsW = mode.width
            let pointsH = mode.height
            guard pointsW >= 800, pointsH >= 600 else { continue }
            guard mode.isUsableForDesktopGUI() else { continue }
            let hiDPI = isHiDPIMode(mode)
            let key = "\(pointsW)x\(pointsH)"
            if let existing = best[key] {
                if hiDPI, !isHiDPIMode(existing) {
                    best[key] = mode
                }
            } else {
                best[key] = mode
            }
        }
        return best.values
            .map { mode in
                HostResolutionOption(
                    width: mode.width,
                    height: mode.height,
                    pointWidth: mode.width,
                    pointHeight: mode.height,
                    hiDPI: isHiDPIMode(mode),
                    isCurrent: mode.width == curPointsW && mode.height == curPointsH
                )
            }
            .sorted { lhs, rhs in
                if lhs.pointWidth != rhs.pointWidth { return lhs.pointWidth < rhs.pointWidth }
                return lhs.pointHeight < rhs.pointHeight
            }
    }

    public static func virtualResolutionOptions(
        currentLogicalWidth: Int,
        currentLogicalHeight: Int,
        currentHiDPI: Bool = false,
        clientWidth: Int = 0,
        clientHeight: Int = 0
    ) -> [HostResolutionOption] {
        var seen = Set<String>()
        var options: [HostResolutionOption] = []
        func appendLogical(_ w: Int, _ h: Int) {
            let lw = max(w & ~1, 2)
            let lh = max(h & ~1, 2)
            guard lw >= 800, lh >= 600 else { return }

            let nativeKey = "\(lw)x\(lh)_native"
            if lw <= VirtualDisplayParameters.maxPixelWidth,
               lh <= VirtualDisplayParameters.maxPixelHeight,
               seen.insert(nativeKey).inserted {
                options.append(HostResolutionOption(
                    width: lw,
                    height: lh,
                    isCurrent: !currentHiDPI
                        && lw == currentLogicalWidth
                        && lh == currentLogicalHeight
                ))
            }

            let pw = lw * 2
            let ph = lh * 2
            guard pw <= VirtualDisplayParameters.maxPixelWidth,
                  ph <= VirtualDisplayParameters.maxPixelHeight else { return }
            let hidpiKey = "\(lw)x\(lh)_hidpi"
            if seen.insert(hidpiKey).inserted {
                options.append(HostResolutionOption(
                    width: pw,
                    height: ph,
                    pointWidth: lw,
                    pointHeight: lh,
                    hiDPI: true,
                    isCurrent: currentHiDPI
                        && lw == currentLogicalWidth
                        && lh == currentLogicalHeight
                ))
            }
        }
        if clientWidth >= 800, clientHeight >= 600 {
            appendLogical(clientWidth, clientHeight)
        }
        for preset in virtualPresets {
            appendLogical(preset.0, preset.1)
        }
        if currentLogicalWidth >= 800, currentLogicalHeight >= 600 {
            appendLogical(currentLogicalWidth, currentLogicalHeight)
        }
        return options.sorted { lhs, rhs in
            if lhs.pointWidth != rhs.pointWidth { return lhs.pointWidth < rhs.pointWidth }
            if lhs.pointHeight != rhs.pointHeight { return lhs.pointHeight < rhs.pointHeight }
            if lhs.hiDPI != rhs.hiDPI { return !lhs.hiDPI }
            return false
        }
    }

    public static func isHiDPIMode(_ mode: CGDisplayMode) -> Bool {
        mode.pixelWidth > mode.width || mode.pixelHeight > mode.height
    }

    /// Switch the physical panel via CoreGraphics to a “Looks like” mode.
    @discardableResult
    public static func applyPhysicalResolution(
        displayID: CGDirectDisplayID,
        width: Int,
        height: Int,
        preferHiDPI: Bool = true
    ) -> Bool {
        let listOptions = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, listOptions) as? [CGDisplayMode] else {
            return false
        }
        let candidates = modes.filter { mode in
            mode.width == width
                && mode.height == height
                && mode.isUsableForDesktopGUI()
        }
        let target: CGDisplayMode?
        if preferHiDPI {
            target = candidates.first(where: isHiDPIMode) ?? candidates.first
        } else {
            target = candidates.first(where: { !isHiDPIMode($0) }) ?? candidates.first
        }
        guard let target else {
            RDPLog.display.error(
                "DisplayTopology: no usable mode \(width)x\(height) on display \(displayID)"
            )
            return false
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            RDPLog.display.error("DisplayTopology: CGBeginDisplayConfiguration failed")
            return false
        }
        let err = CGConfigureDisplayWithDisplayMode(config, displayID, target, nil)
        guard err == .success else {
            CGCancelDisplayConfiguration(config)
            RDPLog.display.error(
                "DisplayTopology: configure \(width)x\(height) failed err=\(err.rawValue)"
            )
            return false
        }
        let complete = CGCompleteDisplayConfiguration(config, .permanently)
        if complete != .success {
            RDPLog.display.error(
                "DisplayTopology: complete \(width)x\(height) failed err=\(complete.rawValue)"
            )
            return false
        }
        let pw = pixelWidth(target)
        let ph = pixelHeight(target)
        let tag = isHiDPIMode(target) ? " HiDPI" : ""
        RDPLog.display.notice(
            "DisplayTopology: physical display \(displayID) → \(width)x\(height)\(tag) " +
            "(pixels \(pw)x\(ph))"
        )
        return true
    }

    private static func pixelWidth(_ mode: CGDisplayMode) -> Int {
        mode.pixelWidth > 0 ? mode.pixelWidth : mode.width
    }

    private static func pixelHeight(_ mode: CGDisplayMode) -> Int {
        mode.pixelHeight > 0 ? mode.pixelHeight : mode.height
    }

    /// Current physical panel label for status UI, e.g. `1512×982 (HiDPI)`.
    public static func currentPhysicalResolutionTitle(preferredIdentity: String = "") -> String? {
        guard let displayID = physicalDisplayID(preferredIdentity: preferredIdentity),
              let mode = CGDisplayCopyDisplayMode(displayID)
        else {
            return nil
        }
        var label = "\(mode.width)×\(mode.height)"
        if isHiDPIMode(mode) { label += " (HiDPI)" }
        return label
    }
}
