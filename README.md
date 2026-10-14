# SwiftRDP

English | [简体中文](README.zh-CN.md)

SwiftRDP is a native macOS RDP server and screen-sharing application written
in Swift.

## Features

- RDP server with TLS and optional CredSSP/NLA authentication.
- Native macOS screen capture and remote keyboard/mouse input.
- Bitmap, H.264, and progressive RemoteFX display paths.
- Adaptive video transport with configurable quality and frame rate ([control policy](docs/video-adaptation.md)).
- Reliable UDP2 graphics transport with TLS and Soft-Sync; input and control remain on TCP.
- Text, image, and file clipboard synchronization.
- System audio forwarding to the RDP client.
- Physical display selection and optional virtual-display mode.
- Menu bar application with connection history, remembered settings, and logs.

## Requirements

- macOS 26.0 or later.
- Swift 6.2 or a compatible Xcode toolchain.
- An RDP client such as Microsoft Remote Desktop or Windows `mstsc`.

Swift Package Manager resolves the SwiftNIO and SwiftNIO SSL dependencies
automatically.

## Build and test

```bash
git clone https://github.com/cwr31/SwiftRDP.git
cd SwiftRDP
swift test
swift build -c release --product SwiftRDPApp
```

The command-line server can be run directly for development:

```bash
swift run swift-rdp --user user --password 'choose-a-password'
```

Command-line arguments may be visible to local process-inspection tools. Do
not use a real account password there.

## Package and run the macOS app

The app needs Screen Recording and Accessibility permissions to capture the
desktop and inject remote input. Use the installer script to assemble a real
`.app` bundle and sign it with a non-ad-hoc Apple Development certificate:

```bash
cp scripts/local-signing.env.example .swift-rdp.local.env
chmod 600 .swift-rdp.local.env
bash scripts/install-and-run.sh
```

The script installs the app at `~/Applications/SwiftRDP.app`, keeps the bundle
identifier stable, verifies the signature, and launches the app. It discovers
the first Apple Development certificate automatically. If multiple
certificates are installed, set `SWIFTRDP_SIGN_IDENTITY` in
`.swift-rdp.local.env`; set `SWIFTRDP_EXPECTED_TEAM_ID` to pin the local Team
ID and preserve macOS privacy permissions across updates.

The local signing file and build output are ignored by Git. Never commit a
keychain password, certificate, private key, generated certificate, or files
from `~/Library/Application Support/SwiftRDP`.

## Connect

1. Start SwiftRDP on the Mac.
2. Grant Screen Recording and Accessibility access in System Settings if
   prompted.
3. In the RDP client, connect to the Mac's IP address on port `3389`.
4. Use the username and password shown in SwiftRDP settings.

One authenticated desktop is active at a time. A replacement connection takes
over only after authentication and connection finalization succeed.

Supporting clients automatically negotiate UDP2 for H.264/RemoteFX graphics.
TCP and UDP use the configured RDP port (`3389` by default). The Connections
page shows `TCP + UDP2` after Soft-Sync completes. If UDP cannot be established,
the session continues on TCP. See [multitransport](docs/multitransport.md) for
protocol details and verification.

The GUI generates a random password on first launch. The standalone
command-line target has development defaults, so always provide explicit
credentials before exposing it beyond a trusted local network. Prefer a VPN
or firewall rather than exposing an RDP port directly to the public Internet.

## Runtime data

SwiftRDP generates its self-signed TLS certificate
outside the repository:

```text
~/Library/Application Support/SwiftRDP/certs/
~/Library/Logs/SwiftRDP/
```

These files are machine-specific and should remain private.

## Contributing

Changes should include focused tests where practical. Run the full test suite
before submitting a pull request:

```bash
swift test
```

## License

SwiftRDP is licensed under the [MIT License](LICENSE).
