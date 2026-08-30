import Foundation
import os

/// Facade over Apple Unified Logging (`os.Logger`), plus an async file / stdout mirror
/// for RDP connection post-mortems.
///
/// ### Channels (`os.Logger` category)
/// Prefer the typed channel (`RDPLog.gfx.info(…)`) so Console.app can filter by category.
///
/// | Level  | Console.app | stdout + `server.log` |
/// |--------|-------------|------------------------|
/// | error  | always      | always                 |
/// | notice | always      | always                 |
/// | info   | always      | when `verbose`         |
/// | debug  | when `verbose` | when `verbose`      |
///
/// File path: `~/Library/Logs/<appSupportName>/server.log` (truncated on each `enableFileLogging`).
/// Mirror lines are timestamped (`yyyy-MM-dd'T'HH:mm:ss.SSS'Z'`) and written on a serial queue
/// so encode / ACK threads never block on `FileHandle` I/O.
public enum RDPLog {
    public static let subsystem = "app.swift-rdp"
    public static let defaultAppSupportName = "SwiftRDP"
    public static let fileName = "server.log"

    /// When true, INFO/DEBUG are mirrored to stdout and `server.log`. ERROR/NOTICE always mirror.
    /// Bound to Settings → Verbose / `ServerConfig.devLog`.
    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var verboseValue = false

    public static var verbose: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return verboseValue
        }
        set {
            stateLock.lock()
            verboseValue = newValue
            stateLock.unlock()
        }
    }

    // MARK: - Categories

    public enum Category: String, Sendable {
        case server
        case capture
        case display
        case gfx
        case rdp
        case auth
        case io
        case channels
        case input
        case app
    }

    /// Per-category logger. Share the process-wide mirror / verbose flag.
    public struct Channel: @unchecked Sendable {
        public let category: Category
        fileprivate let logger: Logger

        fileprivate init(_ category: Category) {
            self.category = category
            self.logger = Logger(subsystem: RDPLog.subsystem, category: category.rawValue)
        }

        public func info(_ message: @autoclosure () -> String) {
            let m = message()
            logger.info("\(m, privacy: .public)")
            if RDPLog.verbose { RDPLog.enqueueMirror("INFO", category.rawValue, m) }
        }

        public func debug(_ message: @autoclosure () -> String) {
            guard RDPLog.verbose else { return }
            let m = message()
            logger.debug("\(m, privacy: .public)")
            RDPLog.enqueueMirror("DEBUG", category.rawValue, m)
        }

        public func error(_ message: @autoclosure () -> String) {
            let m = message()
            logger.error("\(m, privacy: .public)")
            RDPLog.enqueueMirror("ERROR", category.rawValue, m, flush: true)
        }

        /// Always mirrors to `server.log` (unlike `info`, which needs Verbose).
        /// Use for session health breadcrumbs that must be diagnosable without DevLog.
        public func notice(_ message: @autoclosure () -> String) {
            let m = message()
            logger.notice("\(m, privacy: .public)")
            RDPLog.enqueueMirror("NOTICE", category.rawValue, m, flush: true)
        }

        /// Protocol-phase breadcrumbs (e.g. "TLS Handshake") — logged as INFO.
        public func phase(_ name: String) {
            info("Phase: \(name)")
        }
    }

    public static let server = Channel(.server)
    public static let capture = Channel(.capture)
    public static let display = Channel(.display)
    public static let gfx = Channel(.gfx)
    public static let rdp = Channel(.rdp)
    public static let auth = Channel(.auth)
    public static let io = Channel(.io)
    public static let channels = Channel(.channels)
    public static let input = Channel(.input)
    public static let app = Channel(.app)

    // MARK: - Paths

    public static func logDirectoryURL(appSupportName: String = defaultAppSupportName) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(appSupportName)", isDirectory: true)
    }

    public static func logFileURL(appSupportName: String = defaultAppSupportName) -> URL {
        logDirectoryURL(appSupportName: appSupportName).appendingPathComponent(fileName)
    }

    /// Directory currently used by an active file mirror (after `enableFileLogging`).
    public static var activeLogFileURL: URL {
        stateLock.lock()
        defer { stateLock.unlock() }
        return logFileURL(appSupportName: activeAppSupportName)
    }

    /// Mirror logs to `~/Library/Logs/<appSupportName>/server.log`.
    /// Truncates any previous file so restarts don't mix sessions.
    public static func enableFileLogging(appSupportName: String = defaultAppSupportName) {
        stateLock.lock()
        activeAppSupportName = appSupportName
        stateLock.unlock()

        mirrorQueue.sync {
            try? fileHandle?.close()
            fileHandle = nil

            let logs = logDirectoryURL(appSupportName: appSupportName)
            try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let file = logFileURL(appSupportName: appSupportName)
            if FileManager.default.fileExists(atPath: file.path) {
                try? FileManager.default.removeItem(at: file)
            }
            FileManager.default.createFile(atPath: file.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: file)
            let banner =
                "---- SwiftRDP log start \(isoTimestamp(Date())) ----\n"
            if let data = banner.data(using: .utf8) {
                fileHandle?.write(data)
            }
            pendingFlush = false
            linesSinceFlush = 0
        }
    }

    // MARK: - Mirror (async)

    private static let mirrorQueue = DispatchQueue(label: "app.swift-rdp.log.mirror")
    nonisolated(unsafe) private static var fileHandle: FileHandle?
    nonisolated(unsafe) private static var activeAppSupportName = defaultAppSupportName
    nonisolated(unsafe) private static var pendingFlush = false
    nonisolated(unsafe) private static var linesSinceFlush = 0
    /// Reused only on `mirrorQueue`.
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()

    private static func isoTimestamp(_ date: Date) -> String {
        // Called from mirrorQueue (or enableFileLogging's sync block on that queue).
        timestampFormatter.string(from: date)
    }

    private static func enqueueMirror(
        _ level: String,
        _ category: String,
        _ message: String,
        flush: Bool = false
    ) {
        let captured = Date()
        mirrorQueue.async {
            let line =
                "\(isoTimestamp(captured)) [\(level)] [\(category)] \(message)\n"
            fputs(line, stdout)
            if let data = line.data(using: .utf8) {
                fileHandle?.write(data)
            }
            linesSinceFlush += 1
            if flush {
                fflush(stdout)
                try? fileHandle?.synchronize()
                pendingFlush = false
                linesSinceFlush = 0
            } else if linesSinceFlush >= 32 {
                fflush(stdout)
                pendingFlush = false
                linesSinceFlush = 0
            } else if !pendingFlush {
                pendingFlush = true
                mirrorQueue.asyncAfter(deadline: .now() + 0.1) {
                    guard pendingFlush else { return }
                    fflush(stdout)
                    pendingFlush = false
                    linesSinceFlush = 0
                }
            }
        }
    }
}

// MARK: - Signposts (Instruments)

/// Lightweight signpost helpers for encode / send latency in Instruments.
/// Prefer these over per-frame log lines when profiling the hot path.
public enum RDPSignpost {
    public static let gfx = OSSignposter(
        logger: Logger(subsystem: RDPLog.subsystem, category: "gfx")
    )
    public static let capture = OSSignposter(
        logger: Logger(subsystem: RDPLog.subsystem, category: "capture")
    )

    public static func beginGFX(_ name: StaticString) -> OSSignpostIntervalState {
        gfx.beginInterval(name)
    }

    public static func endGFX(_ name: StaticString, _ state: OSSignpostIntervalState) {
        gfx.endInterval(name, state)
    }
}
