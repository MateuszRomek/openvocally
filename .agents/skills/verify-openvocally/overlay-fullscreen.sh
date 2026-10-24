#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'EOF'
Usage: .agents/skills/verify-openvocally/overlay-fullscreen.sh

Checks that the overlay still shows over a full-screen app after another full-screen Space
opened and closed while the overlay was hidden. That sequence once removed the overlay panel
from every full-screen Space until the app restarted.

Holds the Debug app lock, builds and opens the Debug app in the background with -overlayProbe,
and drives it from the probe file. Two helper apps built from fullscreen-window.swift do the
Space changes: A stays in full screen, B enters and leaves it. The script shows the overlay
on A's Space, hides it, lets B strand the panel, brings A back and shows the overlay again.

Passes when the overlay log's check for that last press reads "unoccluded true". Writes
.build/overlay-fullscreen/log.txt and shot.png, which should show the overlay over A's empty
window. Full-screen windows take over the main display for about 25 s, so don't run it while
the user is working. Quits only the Debug app and helpers it opened.
EOF
  exit 0
fi

cd "$(dirname "$0")/../../.."
if [[ "${DEBUG_APP_LOCK_HELD:-}" != 1 ]]; then
  exec scripts/with-debug-app.sh .agents/skills/verify-openvocally/overlay-fullscreen.sh "$@"
fi

executable="$PWD/.build/DerivedData/Build/Products/Debug/OpenVocally Dev.app/Contents/MacOS/OpenVocally"
out="$PWD/.build/overlay-fullscreen"
helpers="$out/helpers"
probe="$out/probe.txt"
mkdir -p "$helpers"
rm -f "$out/log.txt" "$out/shot.png"

build_helper() {
  local name="$1" app="$helpers/$1.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  swiftc -O .agents/skills/verify-openvocally/fullscreen-window.swift -o "$app/Contents/MacOS/$name"
  cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$name</string>
<key>CFBundleIdentifier</key><string>com.openvocally.verify.$name</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
  codesign -fs - "$app" 2>/dev/null
}
build_helper FullScreenA
build_helper FullScreenB
point="$("$helpers/FullScreenA.app/Contents/MacOS/FullScreenA" --point)"

running() {
  ps -axo pid=,comm= | awk -v exe="$1" '{ pid = $1; sub(/^[ \t]*[0-9]+[ \t]+/, ""); if ($0 == exe) print pid }'
}

cleanup() {
  echo "$point 0" >"$probe"
  for exe in "$executable" "$helpers/FullScreenA.app/Contents/MacOS/FullScreenA" \
    "$helpers/FullScreenB.app/Contents/MacOS/FullScreenB"; do
    for pid in $(running "$exe"); do kill "$pid" 2>/dev/null || true; done
  done
}
trap cleanup EXIT

press() {
  echo "$point 1" >"$probe"
  sleep 1.5
}

release() {
  echo "$point 0" >"$probe"
  sleep 1.5
}

echo "$point 0" >"$probe"
RUN_DEBUG_BACKGROUND=1 scripts/run-debug.sh -overlayProbe "$probe" >/dev/null
for _ in $(seq 1 40); do
  scripts/show-logs.sh overlay-demo 1m | grep -q "probe ready" && break
  sleep 0.5
done

open -n "$helpers/FullScreenA.app" --args 0 60
sleep 4
press
release
open -W -n "$helpers/FullScreenB.app" --args 3 6
sleep 1
open "$helpers/FullScreenA.app"
sleep 3

start="$(date "+%Y-%m-%d %H:%M:%S")"
press
screencapture -x "$out/shot.png" || true
sleep 1
release
/usr/bin/log show --start "$start" --info --style compact \
  --predicate 'subsystem == "com.openvocally.app" AND category == "overlay"' >"$out/log.txt"

check="$(grep "Overlay check" "$out/log.txt" | tail -n 1 || true)"
grep "replacing it" "$out/log.txt" || true
if [[ -z "$check" ]]; then
  echo "overlay-fullscreen: no overlay check logged for the last press. See $out/log.txt." >&2
  exit 1
fi
echo "${check#*\] }"
if [[ "$check" != *"unoccluded true"* ]]; then
  echo "overlay-fullscreen: FAIL. The overlay was hidden on the full-screen Space." >&2
  exit 1
fi
echo "overlay-fullscreen: PASS. Screenshot: $out/shot.png"
