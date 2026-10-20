#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'HELP'
Usage: scripts/onboarding/shots.sh [step ...]

Holds the Debug app lock (scripts/with-debug-app.sh), builds the Debug app, then opens it in the background on each onboarding step and captures
only its window to .build/onboarding-shots/<step>.png. Posts no clicks or keys and never takes
focus. Captures the window itself, so other windows on top don't matter. Steps default to welcome permissions
overlay shortcut model tryIt. Needs Screen Recording for the terminal.
HELP
  exit 0
fi

cd "$(dirname "$0")/../.."
if [[ "${DEBUG_APP_LOCK_HELD:-}" != 1 ]]; then
  exec scripts/with-debug-app.sh scripts/onboarding/shots.sh "$@"
fi
steps=("$@")
((${#steps[@]})) || steps=(welcome permissions overlay shortcut model tryIt)
out="$PWD/.build/onboarding-shots"
mkdir -p "$out"
app="$PWD/.build/DerivedData/Build/Products/Debug/OpenVocally Dev.app"
executable="$app/Contents/MacOS/OpenVocally"
window_id="$PWD/.build/window-id"
swiftc -O scripts/lib/window-id.swift -o "$window_id"

running() {
  ps -axo pid=,comm= | awk -v exe="$executable" '{ pid = $1; sub(/^[ \t]*[0-9]+[ \t]+/, ""); if ($0 == exe) print pid }'
}

quit_app() {
  for pid in $(running); do
    kill "$pid"
    for _ in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.25
    done
  done
}

for step in "${steps[@]}"; do
  if [[ "$step" == "${steps[0]}" ]]; then
    RUN_DEBUG_BACKGROUND=1 scripts/run-debug.sh -onboarding YES -onboardingStep "$step" -ApplePersistenceIgnoreState YES
  else
    quit_app
    open -g "$app" --args -onboarding YES -onboardingStep "$step" -ApplePersistenceIgnoreState YES
  fi
  sleep 2.5
  pid="$(running | head -n 1)"
  if ! window="$("$window_id" "$pid")"; then
    echo "onboarding-shots: no window for $step" >&2
    quit_app
    exit 1
  fi
  screencapture -x -o -l "$window" "$out/$step.png"
  echo "$out/$step.png"
done
quit_app
