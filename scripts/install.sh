#!/usr/bin/env bash
# Builds the Release app, signs it, and installs it. Configured by env vars:
#   INSTALL_DIR    target folder (default /Applications)
#   SIGN_IDENTITY  certificate common name, or "-" for ad-hoc; not a SHA-1 hash
#                  (default "OpenVocally Local Signing" when present, else "-")
#   LAUNCH         1 launches after install, 0 skips (default 1)

set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: scripts/install.sh

Builds the Release app, signs it and installs it. Environment variables:
  INSTALL_DIR    target folder (default /Applications)
  SIGN_IDENTITY  certificate common name, or "-" for ad-hoc; not a SHA-1 hash
                 (default "OpenVocally Local Signing" when present, else "-")
  LAUNCH         1 launches after install, 0 skips (default 1)
EOF
  exit 0
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/scripts/lib/signing-identity.sh"

INSTALL_DIR="${INSTALL_DIR:-/Applications}"
INSTALL_DIR="${INSTALL_DIR%/}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
LAUNCH="${LAUNCH:-1}"

log() {
  echo "[openvocally] $*"
}

fail() {
  echo "[openvocally] Error: $*" >&2
  exit 1
}

[[ -n "$INSTALL_DIR" ]] || fail "INSTALL_DIR is empty or /. Set it to a folder such as /Applications."
[[ "$(uname -s)" == "Darwin" ]] || fail "OpenVocally builds only on macOS."
[[ "$(uname -m)" == "arm64" ]] || fail "OpenVocally needs an Apple Silicon Mac (arm64); this is $(uname -m)."
command -v cmake >/dev/null 2>&1 || fail "cmake is missing. Install it: brew install cmake"
command -v xcodegen >/dev/null 2>&1 || fail "xcodegen is missing. Install it: brew install xcodegen"
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild is missing. Install Xcode and run: sudo xcode-select --switch /Applications/Xcode.app"

use_sudo=false
as_installer() {
  if [[ "$use_sudo" == true ]]; then sudo "$@"; else "$@"; fi
}
mkdir -p "$INSTALL_DIR" 2>/dev/null || true
if [[ ! -w "$INSTALL_DIR" ]]; then
  log "$INSTALL_DIR is not writable; using sudo."
  sudo -v || fail "Needs administrator rights to write to $INSTALL_DIR"
  use_sudo=true
  as_installer mkdir -p "$INSTALL_DIR"
fi

# ps reports resolved absolute paths, so the install path must be one too.
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd -P)"

identity_was_set=true
if [[ -z "$SIGN_IDENTITY" ]]; then
  identity_was_set=false
  SIGN_IDENTITY="$(local_signing_identity)"
fi

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  if [[ "$identity_was_set" == true ]]; then
    log "WARNING: signing ad-hoc because SIGN_IDENTITY=-."
  else
    log "WARNING: signing ad-hoc because \"$LOCAL_IDENTITY_NAME\" is not in your keychain."
  fi
  log "WARNING: each install looks like a new app to macOS, so Microphone and Accessibility grants stop matching."
  log "WARNING: run ./scripts/setup-signing.sh once to fix this."
else
  log "Signing identity: $SIGN_IDENTITY"
fi

entitlements="App/Resources/OpenVocally.entitlements"
if [[ "$SIGN_IDENTITY" == "$LOCAL_IDENTITY_NAME" ]]; then
  # The self-signed identity has no Team ID, so library validation would reject Sparkle.framework.
  entitlements="App/Resources/OpenVocally.local.entitlements"
fi

build_log="$PROJECT_ROOT/.build/install-xcodebuild.log"
derived_data="$PROJECT_ROOT/.build/DerivedData"
products="$derived_data/Build/Products/Release"
mkdir -p "$PROJECT_ROOT/.build"
# A renamed product would leave the old .app behind and make the lookup below ambiguous.
rm -rf "$products"

log "Building Release (log: $build_log)..."
if ! (
  cd "$PROJECT_ROOT" &&
    scripts/whisper/build-xcframework.sh &&
    xcodegen generate --quiet &&
    xcodebuild -project OpenVocally.xcodeproj -scheme OpenVocally -configuration Release \
      -derivedDataPath "$derived_data" \
      APP_SIGN_IDENTITY="$SIGN_IDENTITY" APP_ENTITLEMENTS="$entitlements" OTHER_CODE_SIGN_FLAGS=--timestamp=none build
) >"$build_log" 2>&1; then
  tail -n 40 "$build_log" >&2
  fail "The build failed. Full log: $build_log"
fi

apps=("$products"/*.app)
[[ ${#apps[@]} -eq 1 && -d "${apps[0]}" ]] || fail "Expected one .app in $products, found: ${apps[*]}"
app_path="${apps[0]}"
app_name="$(basename "$app_path" .app)"
executable_name="$(defaults read "$app_path/Contents/Info" CFBundleExecutable)"
bundle_id="$(defaults read "$app_path/Contents/Info" CFBundleIdentifier)"

codesign --verify --strict --deep "$app_path" 2>&1 ||
  fail "The app signature does not verify. Run: codesign --verify --deep --strict --verbose=2 '$app_path'"
signature_info="$(codesign -dvv "$app_path" 2>&1)"
identifier="$(sed -n 's/^Identifier=//p' <<<"$signature_info")"
[[ "$identifier" == "$bundle_id" ]] || fail "Signed with identifier '$identifier', expected '$bundle_id'."
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  leaf="$(sed -n 's/^Authority=//p' <<<"$signature_info" | head -n 1)"
  [[ "$leaf" == "$SIGN_IDENTITY" ]] || fail "Signed by '$leaf', expected '$SIGN_IDENTITY'."
fi
log "Built and verified: $app_path"

install_path="$INSTALL_DIR/$app_name.app"
staging_path="$INSTALL_DIR/.$app_name.app.installing"
backup_path="$INSTALL_DIR/.$app_name.app.previous"
executable_path="$install_path/Contents/MacOS/$executable_name"

# A run that crashed between the two moves leaves only the backup; put it back first.
if [[ -d "$backup_path" && ! -e "$install_path" ]]; then
  log "Restoring $install_path from an interrupted earlier install."
  as_installer mv "$backup_path" "$install_path"
fi
as_installer rm -rf "$staging_path" "$backup_path"

if [[ -e "$install_path" ]]; then
  existing_id="$(defaults read "$install_path/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
  [[ "$existing_id" == "$bundle_id" ]] ||
    fail "$install_path is a different app (${existing_id:-no bundle ID}), not replacing it."
fi

# Other copies share the process name, so compare exact executable paths.
pids_at_install_path() {
  local pid
  for pid in $(pgrep -u "$UID" -x "$executable_name" || true); do
    [[ "$(ps -o comm= -p "$pid" 2>/dev/null)" == "$executable_path" ]] && echo "$pid"
  done
  return 0
}

designated_requirement() {
  codesign -d -r- "$1" 2>/dev/null | sed -n 's/^#* *designated => //p' || true
}

had_previous_install=false
previous_requirement=""
if [[ -d "$install_path" ]]; then
  had_previous_install=true
  previous_requirement="$(designated_requirement "$install_path")"
fi

quit_running_app() {
  local pids
  pids="$(pids_at_install_path)"
  [[ -n "$pids" ]] || return 0
  log "Quitting $app_name running from $install_path..."
  kill -TERM $pids 2>/dev/null || true
  for _ in {1..20}; do
    [[ -n "$(pids_at_install_path)" ]] || return 0
    sleep 0.5
  done
  pids="$(pids_at_install_path)"
  [[ -n "$pids" ]] && kill -KILL $pids 2>/dev/null || true
  sleep 1
  [[ -z "$(pids_at_install_path)" ]] || fail "$app_name is still running from $install_path. Quit it, then rerun."
}

quit_running_app

as_installer ditto "$app_path" "$staging_path" || fail "Could not copy the app into $INSTALL_DIR"
as_installer xattr -dr com.apple.quarantine "$staging_path" 2>/dev/null || true
if ! codesign --verify --strict --deep "$staging_path" 2>&1; then
  as_installer rm -rf "$staging_path"
  fail "The copied app in $INSTALL_DIR does not verify. Nothing was replaced."
fi

if [[ -d "$install_path" ]]; then
  as_installer mv "$install_path" "$backup_path"
  if ! as_installer mv "$staging_path" "$install_path"; then
    as_installer mv "$backup_path" "$install_path"
    fail "Could not replace $install_path. The previous app was restored."
  fi
  as_installer rm -rf "$backup_path"
else
  as_installer mv "$staging_path" "$install_path"
fi
log "Installed: $install_path"

# A reset is a destructive OS change, so print it and leave it to the user.
new_requirement="$(designated_requirement "$install_path")"
if [[ "$had_previous_install" == true && "$previous_requirement" != "$new_requirement" ]]; then
  log "The signature changed, so macOS may silently ignore the old Microphone and Accessibility grants."
  log "If dictation or paste stops working, reset them:"
  for service in Accessibility Microphone ListenEvent PostEvent; do
    log "  tccutil reset $service $bundle_id" # allowed: printed, not run
  done
fi

if [[ "$LAUNCH" == "1" ]]; then
  open "$install_path"
  sleep 3
  [[ -n "$(pids_at_install_path)" ]] ||
    fail "$app_name exited right after launch. Run it from a terminal to see why: '$executable_path'"
  log "$app_name is running from $install_path."
fi
