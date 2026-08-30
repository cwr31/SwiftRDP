#!/usr/bin/env bash
# Build SwiftRDP, overwrite-install to a fixed .app path, codesign, launch.
# Same path + same Bundle ID + same Apple Development identity => TCC grants
# (Screen Recording / Accessibility) survive code updates — no re-authorization.
#
# NEVER replace Contents/MacOS/SwiftRDP with a raw `cp` of an SPM binary —
# that leaves an ad-hoc (linker-signed) CDHash and macOS treats it as a new app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Keep signing identity details local. Copy scripts/local-signing.env.example
# to .swift-rdp.local.env, or provide the values through the environment.
ENV_SIGNING_IDENTITY="${SWIFTRDP_SIGN_IDENTITY:-}"
ENV_EXPECTED_TEAM_ID="${SWIFTRDP_EXPECTED_TEAM_ID:-}"
LOCAL_ENV_FILE="${SWIFTRDP_LOCAL_ENV_FILE:-$ROOT/.swift-rdp.local.env}"
if [[ -f "$LOCAL_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$LOCAL_ENV_FILE"
fi

APP_DIR="${SWIFTRDP_APP_DIR:-$HOME/Applications/SwiftRDP.app}"
PORT="${SWIFTRDP_PORT:-3389}"
BUNDLE_ID="com.swiftrdp.app"
IDENTITY="${ENV_SIGNING_IDENTITY:-${SWIFTRDP_SIGN_IDENTITY:-}}"
EXPECTED_TEAM_ID="${ENV_EXPECTED_TEAM_ID:-${SWIFTRDP_EXPECTED_TEAM_ID:-}}"
CONFIG="${SWIFTRDP_CONFIG:-release}"
BUILD_VERSION="${SWIFTRDP_BUILD_VERSION:-$(date '+%m%d%H%M')}"
LOGIN_KEYCHAIN="${SWIFTRDP_KEYCHAIN_PATH:-$HOME/Library/Keychains/login.keychain-db}"

if [[ ! "$BUILD_VERSION" =~ ^[0-9]{8}$ ]]; then
  echo "error: SWIFTRDP_BUILD_VERSION must contain exactly 8 digits (MMddHHmm)" >&2
  exit 1
fi

resolve_identity() {
  local want="$1"
  if security find-identity -v -p codesigning 2>/dev/null | grep -F "$want" >/dev/null; then
    echo "$want"
    return 0
  fi
  return 1
}

discover_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' \
    | awk 'NR == 1 { print }'
}

# Unlock login keychain when SWIFTRDP_KEYCHAIN_PASSWORD is set (e.g. in ~/.zshrc).
# Keeps the password out of the repo; required for non-interactive runs (Cursor agent).
unlock_login_keychain_if_configured() {
  local password="${SWIFTRDP_KEYCHAIN_PASSWORD:-}"
  if [[ -z "$password" ]]; then
    return 1
  fi
  if [[ ! -f "$LOGIN_KEYCHAIN" ]]; then
    echo "error: login keychain not found at $LOGIN_KEYCHAIN" >&2
    echo "  Set SWIFTRDP_KEYCHAIN_PATH if it lives elsewhere." >&2
    exit 1
  fi
  if ! security unlock-keychain -p "$password" "$LOGIN_KEYCHAIN" >/dev/null 2>&1; then
    echo "error: could not unlock login keychain (check SWIFTRDP_KEYCHAIN_PASSWORD)" >&2
    exit 1
  fi
  # Allow codesign to use the development private key without a GUI prompt.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" \
    "$LOGIN_KEYCHAIN" >/dev/null 2>&1 || true
  return 0
}

codesign_probe() {
  local probe="$1" identity="$2"
  codesign --force --sign "$identity" "$probe" 2>&1
}

SIGN_AS=""
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(discover_identity)"
fi
if [[ -z "$IDENTITY" ]]; then
  echo "error: no Apple Development signing identity found." >&2
  echo "  Set SWIFTRDP_SIGN_IDENTITY or configure .swift-rdp.local.env." >&2
  exit 1
fi
if SIGN_AS=$(resolve_identity "$IDENTITY"); then
  echo "==> Codesign identity: $SIGN_AS"
else
  echo "error: required Apple Development identity not found." >&2
  echo "  Wanted: $IDENTITY" >&2
  security find-identity -v -p codesigning 2>/dev/null >&2 || true
  echo "  Unlock the login keychain; ad-hoc signing is intentionally forbidden." >&2
  exit 1
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
SIGNING_PROBE="$WORK_DIR/codesign-probe"
cp /usr/bin/true "$SIGNING_PROBE"

if unlock_login_keychain_if_configured; then
  echo "==> Login keychain unlocked (SWIFTRDP_KEYCHAIN_PASSWORD)"
fi

SIGNING_PROBE_ERROR=""
PROBE_OK=false
if SIGNING_PROBE_ERROR=$(codesign_probe "$SIGNING_PROBE" "$SIGN_AS"); then
  PROBE_OK=true
elif unlock_login_keychain_if_configured; then
  echo "==> Retrying codesign after keychain unlock"
  SIGNING_PROBE_ERROR=""
  if SIGNING_PROBE_ERROR=$(codesign_probe "$SIGNING_PROBE" "$SIGN_AS"); then
    PROBE_OK=true
  fi
fi

if [[ "$PROBE_OK" != true ]]; then
  echo "error: signing certificate was found, but its private key is unavailable." >&2
  echo "  $SIGNING_PROBE_ERROR" >&2
  echo "  Unlock the login keychain, or set SWIFTRDP_KEYCHAIN_PASSWORD in your shell profile:" >&2
  echo "    export SWIFTRDP_KEYCHAIN_PASSWORD='…'   # ~/.zshrc — do not commit" >&2
  exit 1
fi

echo "==> Build version: $BUILD_VERSION ($(date '+%Y-%m-%d %H:%M:%S %Z'))"
echo "==> Building SwiftRDPApp ($CONFIG)"
if [[ "$CONFIG" == "release" ]]; then
  swift build -c release --product SwiftRDPApp
  BIN="$ROOT/.build/release/SwiftRDPApp"
  BUNDLE_SRC="$ROOT/.build/release/SwiftRDP_SwiftRDPApp.bundle"
  [[ -x "$ROOT/.build/arm64-apple-macosx/release/SwiftRDPApp" ]] && BIN="$ROOT/.build/arm64-apple-macosx/release/SwiftRDPApp"
  [[ -d "$ROOT/.build/arm64-apple-macosx/release/SwiftRDP_SwiftRDPApp.bundle" ]] && BUNDLE_SRC="$ROOT/.build/arm64-apple-macosx/release/SwiftRDP_SwiftRDPApp.bundle"
else
  swift build --product SwiftRDPApp
  BIN="$ROOT/.build/debug/SwiftRDPApp"
  BUNDLE_SRC="$ROOT/.build/debug/SwiftRDP_SwiftRDPApp.bundle"
  [[ -x "$ROOT/.build/arm64-apple-macosx/debug/SwiftRDPApp" ]] && BIN="$ROOT/.build/arm64-apple-macosx/debug/SwiftRDPApp"
  [[ -d "$ROOT/.build/arm64-apple-macosx/debug/SwiftRDP_SwiftRDPApp.bundle" ]] && BUNDLE_SRC="$ROOT/.build/arm64-apple-macosx/debug/SwiftRDP_SwiftRDPApp.bundle"
fi

[[ -x "$BIN" ]] || BIN="$ROOT/.build/$CONFIG/SwiftRDPApp"
[[ -d "$BUNDLE_SRC" ]] || BUNDLE_SRC="$ROOT/.build/$CONFIG/SwiftRDP_SwiftRDPApp.bundle"

if [[ ! -x "$BIN" ]]; then
  echo "error: built binary not found" >&2
  exit 1
fi

echo "==> Staging app bundle"
mkdir -p "$(dirname "$APP_DIR")"
STAGE="$WORK_DIR/stage"
STAGED_APP="$STAGE/SwiftRDP.app"

mkdir -p "$STAGED_APP/Contents/MacOS"
mkdir -p "$STAGED_APP/Contents/Resources"

cp "$ROOT/App/SwiftRDP/Info.plist" "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :SwiftRDPBuildVersion $BUILD_VERSION" \
  "$STAGED_APP/Contents/Info.plist"
STAGED_BUILD_VERSION=$(
  /usr/libexec/PlistBuddy -c "Print :SwiftRDPBuildVersion" \
    "$STAGED_APP/Contents/Info.plist"
)
if [[ "$STAGED_BUILD_VERSION" != "$BUILD_VERSION" ]]; then
  echo "error: staged build version '$STAGED_BUILD_VERSION' does not match '$BUILD_VERSION'" >&2
  exit 1
fi
echo "==> Staged app build: $STAGED_BUILD_VERSION"
cp "$BIN" "$STAGED_APP/Contents/MacOS/SwiftRDP"
chmod +x "$STAGED_APP/Contents/MacOS/SwiftRDP"

if [[ -d "$BUNDLE_SRC" ]]; then
  cp -R "$BUNDLE_SRC" "$STAGED_APP/Contents/Resources/"
fi

echo "==> Codesign (stable Team ID — required for TCC persistence)"
ENTITLEMENTS="$ROOT/App/SwiftRDP/SwiftRDP.entitlements"
CODESIGN_ARGS=(
  --force --deep
  --sign "$SIGN_AS"
  --identifier "$BUNDLE_ID"
  --options runtime
)
if [[ -f "$ENTITLEMENTS" ]]; then
  CODESIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
fi
codesign "${CODESIGN_ARGS[@]}" "$STAGED_APP"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
SIGN_DETAILS=$(codesign -dv --verbose=4 "$STAGED_APP" 2>&1)
echo "$SIGN_DETAILS" | head -20
if echo "$SIGN_DETAILS" | grep -q 'Signature=adhoc'; then
  echo "error: refusing to install an ad-hoc signed app" >&2
  exit 1
fi
ACTUAL_TEAM_ID=$(echo "$SIGN_DETAILS" | sed -n 's/^TeamIdentifier=//p')
if [[ -z "$ACTUAL_TEAM_ID" ]]; then
  echo "error: signed app has no TeamIdentifier; refusing to install it" >&2
  exit 1
fi
if [[ -n "$EXPECTED_TEAM_ID" && "$ACTUAL_TEAM_ID" != "$EXPECTED_TEAM_ID" ]]; then
  echo "error: refusing TeamIdentifier '$ACTUAL_TEAM_ID' (expected '$EXPECTED_TEAM_ID')" >&2
  exit 1
fi

echo "==> Stopping previous SwiftRDP (same app only)"
INSTALLED_EXECUTABLE="$APP_DIR/Contents/MacOS/SwiftRDP"
PIDS=$(pgrep -f -x "$INSTALLED_EXECUTABLE" 2>/dev/null || true)
if [[ -n "${PIDS:-}" ]]; then
  echo "    terminating installed PID(s): $PIDS"
  kill $PIDS 2>/dev/null || true
  for _ in $(seq 1 30); do
    LIVE_PIDS=""
    for PID in $PIDS; do
      if kill -0 "$PID" 2>/dev/null; then
        LIVE_PIDS="$LIVE_PIDS $PID"
      fi
    done
    [[ -z "$LIVE_PIDS" ]] && break
    sleep 0.1
  done
  if [[ -n "${LIVE_PIDS:-}" ]]; then
    echo "    installed app did not exit in 3s; killing PID(s):$LIVE_PIDS"
    kill -9 $LIVE_PIDS 2>/dev/null || true
    sleep 0.2
  fi
fi

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "error: port $PORT is still occupied after stopping the installed app" >&2
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >&2 || true
  exit 1
fi

echo "==> Overwrite-install → $APP_DIR"
rm -rf "$APP_DIR"
mv "$STAGED_APP" "$APP_DIR"
INSTALLED_BUILD_VERSION=$(
  /usr/libexec/PlistBuddy -c "Print :SwiftRDPBuildVersion" \
    "$APP_DIR/Contents/Info.plist"
)
if [[ "$INSTALLED_BUILD_VERSION" != "$BUILD_VERSION" ]]; then
  echo "error: installed build version '$INSTALLED_BUILD_VERSION' does not match '$BUILD_VERSION'" >&2
  exit 1
fi
echo "==> Installed app build: $INSTALLED_BUILD_VERSION"

echo "==> Prefs: port=$PORT auto-start on"
defaults write "$BUNDLE_ID" swiftrdp.serverPort -int "$PORT"
defaults write "$BUNDLE_ID" swiftrdp.autoStartServer -bool true
defaults write "$BUNDLE_ID" swiftrdp.hasLaunchedBefore -bool true
defaults read "$BUNDLE_ID" swiftrdp.authEnabled >/dev/null 2>&1 \
  || defaults write "$BUNDLE_ID" swiftrdp.authEnabled -bool true
defaults read "$BUNDLE_ID" swiftrdp.username >/dev/null 2>&1 \
  || defaults write "$BUNDLE_ID" swiftrdp.username -string "user"

echo "==> Launch $APP_DIR"
open "$APP_DIR"

for i in $(seq 1 30); do
  if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "==> Listening on :$PORT"
    lsof -nP -iTCP:"$PORT" -sTCP:LISTEN | head -3
    echo "==> Ready: build=$INSTALLED_BUILD_VERSION app=$APP_DIR"
    exit 0
  fi
  sleep 0.4
done

echo "warning: app launched but :$PORT not listening yet (check Screen Recording / Accessibility)" >&2
exit 0
