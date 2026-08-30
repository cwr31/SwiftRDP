import Foundation
import SwiftRDPCore

/// Runs shell scripts with an administrator password prompt (Authorization Services via osascript).
enum PrivilegedShell {
    enum ShellError: LocalizedError {
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Administrator authorization was cancelled."
            case .failed(let msg): return msg
            }
        }
    }

    /// Execute a bash script as root. Returns stdout+stderr combined.
    @discardableResult
    static func run(_ script: String) throws -> String {
        // Escape for AppleScript string embedding.
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = """
        do shell script "\(escaped)" with administrator privileges
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ShellError.failed(error.localizedDescription)
        }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let combined = (stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            if combined.lowercased().contains("canceled") || combined.lowercased().contains("cancelled")
                || process.terminationStatus == 1 && combined.isEmpty {
                throw ShellError.cancelled
            }
            throw ShellError.failed(combined.isEmpty ? "Privileged command failed (\(process.terminationStatus))" : combined)
        }
        RDPLog.app.info("PrivilegedShell: ok")
        return stdout
    }

    /// Quote a path for safe inclusion in a shell script.
    static func quote(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
