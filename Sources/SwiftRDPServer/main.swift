import Foundation
import SwiftRDPCore

func printUsage() {
    print(
        """
        SwiftRDP — native macOS RDP server (independent implementation)

        Usage:
          swift-rdp [--port 3389] [--user USER] [--password PASS] [--no-nla] [--bind HOST]
                       [--gfx [bitmap|h264|rfx]] [--no-gfx]
                       [--no-clipboard] [--no-audio]
                       [--rfx]

        Options:
          --port        Listen port (default 3389)
          --bind        Bind address (default 0.0.0.0)
          --user        NLA username (default user)
          --password    NLA password (default password)
          --no-nla      TLS only (disable CredSSP/NLA)
          --fps         Capture FPS (default 15)
          --width       Force width (0 = client/request)
          --height      Force height
          --gfx         Enable graphics (optional mode: bitmap, h264, rfx)
          --no-gfx      Disable GFX/H.264 dynamic channel path
          --no-clipboard  Disable CLIPRDR
          --no-audio    Keep audio on the host; disable forwarding to the RDP client
          --rfx         RemoteFX Progressive encode path (DisplayMode=rfx)
          -h, --help    Show help

        Permissions required:
          • Screen Recording (System Settings → Privacy & Security)
          • Accessibility (for keyboard/mouse injection)

        Connect from Windows: mstsc → computer: <this-mac-ip>:<port>
        """
    )
}

@main
struct SwiftRDPMain {
    static func main() async {
        var config = ServerConfig()
        var args = Array(CommandLine.arguments.dropFirst())
        while let a = args.first {
            args.removeFirst()
            switch a {
            case "-h", "--help":
                printUsage()
                return
            case "--port":
                if let v = args.first, let p = Int(v) { config.port = p; args.removeFirst() }
            case "--bind":
                if let v = args.first { config.bindHost = v; args.removeFirst() }
            case "--user":
                if let v = args.first { config.username = v; args.removeFirst() }
            case "--password":
                if let v = args.first { config.password = v; args.removeFirst() }
            case "--no-nla":
                config.nlaEnabled = false
            case "--fps":
                if let v = args.first, let p = Int(v) { config.fps = p; args.removeFirst() }
            case "--width":
                if let v = args.first, let p = Int(v) { config.width = p; args.removeFirst() }
            case "--height":
                if let v = args.first, let p = Int(v) { config.height = p; args.removeFirst() }
            case "--gfx":
                config.gfxEnabled = true
                if let v = args.first, let mode = DisplayMode(rawValue: v.lowercased()) {
                    config.displayMode = mode
                    args.removeFirst()
                }
            case "--no-gfx":
                config.gfxEnabled = false
            case "--no-clipboard":
                config.clipboardEnabled = false
            case "--no-audio":
                config.audioPlaybackDestination = .host
            case "--rfx", "--rfx-progressive":
                config.displayMode = .rfx
                config.gfxEnabled = true
            default:
                print("Unknown argument: \(a)")
                printUsage()
                return
            }
        }

        RDPLog.app.info(
            "SwiftRDP starting — port=\(config.port) nla=\(config.nlaEnabled) mode=\(config.displayMode.rawValue) " +
            "clip=\(config.clipboardEnabled) " +
            "audio=\(config.audioPlaybackDestination.rawValue)"
        )
        let manager = SessionManager(config: config)
        do {
            try await manager.start()
        } catch {
            RDPLog.app.error("Failed to start: \(error)")
            exit(1)
        }

        signal(SIGINT) { _ in
            RDPLog.app.info("SIGINT — shutting down")
            exit(0)
        }

        // Run forever
        while true {
            try? await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
    }
}
