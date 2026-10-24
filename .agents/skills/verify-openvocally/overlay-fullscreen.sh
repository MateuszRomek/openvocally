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
Space changes and report them: A stays in full screen, B enters and leaves it. The script shows
the overlay on A's Space, hides it, waits for B to enter and leave full screen, brings A back
and shows the overlay again.

Exits 0 (PASS) when the overlay log's check for that last press reads "unoccluded true" and
"on active Space true". Exits 1 (FAIL) when it doesn't, and 2 when the Space sequence or the
app did not get ready, so the run proved nothing. Writes .build/overlay-fullscreen/log.txt and
shot.png, which should show the overlay over A's empty window. Full-screen windows take over
the main display for about 25 s, so don't run it while the user is working. Quits only the
Debug app and helpers it opened.
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
rm -f "$out/log.txt" "$out/shot.png" "$out/a.events" "$out/b.events"

swiftc -O .agents/skills/verify-openvocally/fullscreen-window.swift -o "$helpers/fullscreen-window"
build_helper() {
  local name="$1" app="$helpers/$1.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  cp "$helpers/fullscreen-window" "$app/Contents/MacOS/$name"
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
point="$("$helpers/fullscreen-window" --point)"

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

not_reproduced() {
  echo "overlay-fullscreen: NOT REPRODUCED. $1 The run proves nothing; rerun it." >&2
  exit 2
}

# Waits until the events file holds at least $3 lines equal to $2, for up to 15 s.
wait_for() {
  for _ in $(seq 1 60); do
    if [[ -f "$1" ]] && (($(grep -cx "$2" "$1" || true) >= $3)); then return 0; fi
    sleep 0.25
  done
  return 1
}

overlay_log() {
  /usr/bin/log show --start "$1" --info --style compact \
    --predicate "subsystem == \"com.openvocally.app\" AND category == \"$2\""
}

press() {
  echo "$point 1" >"$probe"
  sleep 1
}

release() {
  echo "$point 0" >"$probe"
  sleep 1
}

echo "$point 0" >"$probe"
launched="$(date "+%Y-%m-%d %H:%M:%S")"
RUN_DEBUG_BACKGROUND=1 scripts/run-debug.sh -overlayProbe "$probe" >/dev/null
ready=0
for _ in $(seq 1 30); do
  if [[ "$(overlay_log "$launched" overlay-demo)" == *"probe ready"* ]]; then
    ready=1
    break
  fi
  sleep 0.5
done
((ready)) || not_reproduced "The Debug app never logged probe ready."

open -n "$helpers/FullScreenA.app" --args 0 90 "$out/a.events"
wait_for "$out/a.events" entered 1 || not_reproduced "Helper A never entered full screen."
sleep 1
press
release
activations="$(grep -cx active "$out/a.events" || true)"
open -n "$helpers/FullScreenB.app" --args 3 8 "$out/b.events"
wait_for "$out/b.events" entered 1 || not_reproduced "Helper B never entered full screen."
wait_for "$out/b.events" exited 1 || not_reproduced "Helper B never left full screen."
open "$helpers/FullScreenA.app"
wait_for "$out/a.events" active $((activations + 1)) || not_reproduced "Helper A never came back to the front."
sleep 1.5

start="$(date "+%Y-%m-%d %H:%M:%S")"
press
screencapture -x "$out/shot.png" || true
release
overlay_log "$start" overlay >"$out/log.txt"

check="$(grep "Overlay check" "$out/log.txt" | tail -n 1 || true)"
[[ -n "$check" ]] || not_reproduced "No overlay check was logged for the last press. See $out/log.txt."
echo "${check#*\] }"
if [[ "$check" != *"unoccluded true"* || "$check" != *"on active Space true"* ]]; then
  echo "overlay-fullscreen: FAIL. The overlay was hidden on the full-screen Space." >&2
  exit 1
fi
echo "overlay-fullscreen: PASS. Screenshot: $out/shot.png"
