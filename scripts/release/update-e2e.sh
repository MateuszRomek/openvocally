#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'EOF'
Usage: scripts/release/update-e2e.sh

Proves that a released app updates itself through Sparkle, with no clicks. Builds build 1 and
build 2 with scripts/release.sh (Developer ID signed, not notarized, not published) under the
test bundle ID com.openvocally.app.updatetest and a throwaway EdDSA key file. Serves the
appcast and archive on 127.0.0.1, installs build 1 in a temp folder and launches it with
automatic updates on. Passes when build 1 logs the update as ready to install (the state behind
Restart to Update), and after it quits, build 2 replaced it, verifies and launches.

Then the negative case: build 3 with the same public key, its archive signed by a different
EdDSA key, which build 2 must refuse.

Needs a Developer ID Application identity in the keychain. Removes its processes, temp
folders, server and the test bundle's defaults and caches on exit. Your own OpenVocally is never
touched.
EOF
  exit 0
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUNDLE_ID="com.openvocally.app.updatetest"
UPDATE_TIMEOUT=180

log() {
  echo "[update-e2e] $*"
}

fail() {
  echo "[update-e2e] FAIL: $*" >&2
  exit 1
}

# ps reports resolved paths, and /tmp is a symlink to /private/tmp.
work="$(cd "$(mktemp -d /tmp/openvocally-update-e2e.XXXXXX)" && pwd -P)"
install_dir="$work/install"
app="$install_dir/OpenVocally.app"
executable="$app/Contents/MacOS/OpenVocally"
server_pid=""

test_pids() {
  ps -axo pid=,command= | awk -v dir="$work/" -v id="$BUNDLE_ID" \
    '!/awk -v dir=/ && (index($0, dir) || index($0, id)) { print $1 }' | grep -vx "$$" || true
}

stop_test_processes() {
  local pids
  pids="$(test_pids)"
  [[ -z "$pids" ]] || kill -TERM $pids 2>/dev/null || true
  for _ in {1..20}; do
    [[ -n "$(test_pids)" ]] || return 0
    sleep 0.25
  done
  pids="$(test_pids)"
  [[ -z "$pids" ]] || kill -KILL $pids 2>/dev/null || true
}

cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  stop_test_processes
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  rm -rf "$HOME/Library/Preferences/$BUNDLE_ID.plist" "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/HTTPStorages/$BUNDLE_ID" \
    "$HOME/Library/Application Support/$BUNDLE_ID" "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState" \
    "$HOME/Library/WebKit/$BUNDLE_ID" "$work"
}
trap cleanup EXIT

new_key() {
  xcrun swift - >"$1" 2>/dev/null <<'SWIFT'
import CryptoKit
print(Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())
SWIFT
  [[ -s "$1" ]] || fail "Could not create a throwaway EdDSA key."
}

port="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
feed="$work/feed"
mkdir -p "$feed" "$install_dir"
base_url="http://127.0.0.1:$port"
new_key "$work/key.txt"
new_key "$work/other-key.txt"

release() {
  local build="$1" key="$2" appcast="$3"
  log "Building build $build (log: $work/release-$build.log)..."
  ALLOW_DIRTY=1 SKIP_NOTARIZE=1 NO_PUBLISH=1 SPARKLE_KEY_FILE="$key" APPCAST="$appcast" \
    BUNDLE_ID="$BUNDLE_ID" VERSION="0.0.$build" BUILD="$build" OUT_DIR="$work/build-$build" \
    FEED_URL="$base_url/appcast.xml" DOWNLOAD_URL_PREFIX="$base_url/" \
    "$PROJECT_ROOT/scripts/release.sh" >"$work/release-$build.log" 2>&1 ||
    {
      tail -n 20 "$work/release-$build.log" >&2
      fail "release.sh failed for build $build."
    }
}

release 1 "$work/key.txt" "$work/appcast-1.xml"
release 2 "$work/key.txt" "$feed/appcast.xml"
cp "$work/build-2/OpenVocally-0.0.2.zip" "$feed/"
ditto "$work/build-1/OpenVocally.app" "$app"

(cd "$feed" && exec python3 -I -m http.server "$port" --bind 127.0.0.1) >"$work/server.log" 2>&1 &
server_pid=$!
for _ in {1..40}; do
  curl -sf "$base_url/appcast.xml" >/dev/null && break
  sleep 0.25
done
curl -sf "$base_url/appcast.xml" >/dev/null || fail "The local feed server did not start on port $port."

installed_build() {
  defaults read "$app/Contents/Info" CFBundleVersion 2>/dev/null || echo none
}

app_pid() {
  ps -axo pid=,comm= | awk -v exe="$executable" '{ pid = $1; sub(/^[ \t]*[0-9]+[ \t]+/, ""); if ($0 == exe) print pid }'
}

# Sparkle skips the first launch and then waits a full interval; an old last-check time makes it
# check at once, and automatic updates install without asking.
launch_with_automatic_updates() {
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  defaults write "$BUNDLE_ID" SUHasLaunchedBefore -bool YES
  defaults write "$BUNDLE_ID" SUEnableAutomaticChecks -bool YES
  defaults write "$BUNDLE_ID" SUAutomaticallyUpdate -bool YES
  defaults write "$BUNDLE_ID" SULastCheckTime -date "2001-01-01 00:00:00 +0000"
  open -g -n "$app"
  for _ in {1..40}; do
    [[ -n "$(app_pid)" ]] && return 0
    sleep 0.25
  done
  fail "Build $(installed_build) did not launch from $app."
}

# An automatic update is staged while the app runs and installs when it quits.
wait_for_download_then_quit() {
  local deadline=$((SECONDS + $1))
  while ((SECONDS < deadline)); do
    grep -q "GET /OpenVocally-" "$work/server.log" && break
    sleep 1
  done
  grep -q "GET /OpenVocally-" "$work/server.log" || return 1
  sleep 10
  local pid
  pid="$(app_pid)"
  [[ -z "$pid" ]] || kill -TERM $pid
  while ((SECONDS < deadline)) && [[ -n "$(app_pid)" ]]; do sleep 0.5; done
  return 0
}

# The running app logs this when Sparkle has staged the update and the sidebar shows Restart to
# Update. Clicking it would need synthetic input, so the test quits the app to install instead.
# It matches the PID, because the unified log reports the first path it saw for an identical binary.
wait_for_ready_to_install() {
  local since="$1" version="$2" deadline=$((SECONDS + $3)) pid="$4" line
  while ((SECONDS < deadline)); do
    line="$(/usr/bin/log show --start "$since" --info --style compact \
      --predicate "subsystem == \"com.openvocally.app\" AND category == \"updates\" AND processIdentifier == $pid" \
      2>/dev/null | grep -F "Update ready to install: $version" || true)"
    if [[ -n "$line" ]]; then
      echo "$line"
      return 0
    fi
    sleep 2
  done
  return 1
}

log "Launching build 1 from $app with the feed at $base_url..."
since="$(date '+%Y-%m-%d %H:%M:%S')"
launch_with_automatic_updates
ready="$(wait_for_ready_to_install "$since" 0.0.2 "$UPDATE_TIMEOUT" "$(app_pid)")" ||
  fail "Build 1 never reported the update as ready to install. Server log: $(cat "$work/server.log")"
log "PASS: build 1 published readyToInstall: ${ready##*] }"
pid="$(app_pid)"
[[ -z "$pid" ]] || kill -TERM $pid
deadline=$((SECONDS + UPDATE_TIMEOUT))
while ((SECONDS < deadline)) && [[ -n "$(app_pid)" ]]; do sleep 0.5; done
deadline=$((SECONDS + UPDATE_TIMEOUT))
while ((SECONDS < deadline)) && [[ "$(installed_build)" != 2 ]]; do sleep 1; done
[[ "$(installed_build)" == 2 ]] || fail "The installed app is still build $(installed_build) after quitting."
codesign --verify --deep --strict "$app" || fail "The updated app does not verify."
stop_test_processes
open -g -n "$app"
sleep 3
[[ -n "$(app_pid)" ]] || fail "The updated app does not launch."
log "PASS: Sparkle replaced build 1 with build $(installed_build), which verifies and launches."
stop_test_processes

# Same embedded public key, but the archive signed by another key. Sparkle accepts a new key only
# from an update that also changes the app's key and keeps its Developer ID, so that is no test.
release 3 "$work/key.txt" "$work/appcast-3.xml"
zip3="$work/build-3/OpenVocally-0.0.3.zip"
sparkle_bin="$PROJECT_ROOT/.build/ReleaseDerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
forged="$("$sparkle_bin/sign_update" --ed-key-file "$work/other-key.txt" -p "$zip3")" ||
  fail "sign_update could not sign with the second key."
python3 -I - "$work/appcast-3.xml" "$forged" "$feed/appcast.xml" <<'PY'
import re, sys
xml = open(sys.argv[1]).read()
forged, count = re.subn(r'sparkle:edSignature="[^"]*"', 'sparkle:edSignature="%s"' % sys.argv[2], xml)
assert count == 1, count
open(sys.argv[3], "w").write(forged)
PY
# The app requires a signed feed, so the forged feed is re-signed with the real key. Only the
# archive's signature is wrong, which is the case under test.
"$sparkle_bin/sign_update" --ed-key-file "$work/key.txt" "$feed/appcast.xml" >/dev/null ||
  fail "sign_update could not re-sign the forged feed."
"$sparkle_bin/sign_update" --ed-key-file "$work/key.txt" --verify "$feed/appcast.xml" >/dev/null ||
  fail "The re-signed forged feed does not verify."
rm -f "$feed"/*.zip
cp "$zip3" "$feed/"
: >"$work/server.log"
log "Launching build 2 with an update signed by a different EdDSA key..."
launch_with_automatic_updates
wait_for_download_then_quit "$UPDATE_TIMEOUT" || fail "Build 2 never downloaded build 3, so a refusal would prove nothing."
sleep 15
[[ "$(installed_build)" == 2 ]] || fail "Build $(installed_build) was installed from an update signed by the wrong key."
codesign --verify --deep --strict "$app" || fail "The app no longer verifies after the refused update."
log "PASS: the update signed by a different key was refused; build 2 is still installed."
