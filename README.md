# SwiftRDP

Native macOS RDP server and screen-sharing application.

## Build and run locally

The app must be signed with a non-ad-hoc Apple Development certificate so
macOS Screen Recording and Accessibility permissions can survive app updates.

1. Copy `scripts/local-signing.env.example` to `.swift-rdp.local.env`.
2. Set `SWIFTRDP_SIGN_IDENTITY` to the local signing certificate when more
   than one Apple Development certificate is installed.
3. Set `SWIFTRDP_EXPECTED_TEAM_ID` to pin the Team ID for stable local TCC
   permissions. Keep the file mode `600`.
4. Run `bash scripts/install-and-run.sh`.

The local environment file is ignored by Git. The signing script also
discovers the first Apple Development certificate when no identity is set,
and always rejects ad-hoc or Team-ID-less signatures.

The keychain password, if needed for non-interactive signing, should be
provided through `SWIFTRDP_KEYCHAIN_PASSWORD` in the shell environment or a
local shell profile, never committed to the repository.

## Tests

```bash
swift test
```
