#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'HELP'
Usage: scripts/agents/agents-shots.sh [shot ...]

Builds the fake claude and codex CLIs (the FakeAgentCLI target in OpenVocallyKit) and installs
them to .build/agent-fakes/<scenario>/<claude|codex>. Runs --version on every installed fake and
fails if one fails. Writes one "<scenario> <provider> <path>" line per fake to
.build/agents/fakes.txt. Then, holding the Debug app lock, opens the Debug app in the background
once per row of the SHOTS table, each with a fresh scratch -dataFolder, waits for the app's
agents-ready file and captures the Agents window to .build/agents/<shot>.png. Shots default to
every row. Increase Contrast shots are taken only while that system setting is on. Fails when the real Debug database (openvocally.sqlite, -wal, -shm) changed its
modification time or size during the run. Posts no clicks or keys. Needs Screen Recording for
the terminal.
HELP
  exit 0
fi

cd "$(dirname "$0")/../.."

root="$PWD/.build/agent-fakes"
out="$PWD/.build/agents"
mkdir -p "$out"

swift build --package-path OpenVocallyKit --target FakeAgentCLI
fake_cli="$(swift build --package-path OpenVocallyKit --show-bin-path)/FakeAgentCLI"
"$fake_cli" install "$root"

: >"$out/fakes.txt"
while read -r scenario provider; do
  [[ -n "$scenario" ]] || continue
  path="$root/$scenario/$provider"
  if ! "$path" --version >/dev/null; then
    echo "agents-shots: $path failed --version" >&2
    exit 1
  fi
  echo "$scenario $provider $path" >>"$out/fakes.txt"
done < <("$fake_cli" --list)
echo "$out/fakes.txt"

# One row per screenshot, separated by "|": PNG name | window title | launch arguments.
# @DATA@ becomes the row's fresh scratch data folder. Paths must be absolute: open starts the
# app in /. A provider's binary path can point at a fake under $root.
SHOTS=()
for scenario in empty projects folder-missing; do
  for appearance in light dark; do
    SHOTS+=("agents-$scenario-$appearance|Agents|-dataFolder @DATA@ -agentsScenario $scenario -debugAppearance $appearance -sidebarCollapsed NO")
  done
done
SHOTS+=("agents-large-dark|Agents|-dataFolder @DATA@ -agentsScenario large -debugAppearance dark -sidebarCollapsed NO")
SHOTS+=("agents-projects-collapsed|Agents|-dataFolder @DATA@ -agentsScenario projects -debugAppearance dark -sidebarCollapsed YES")
# No app can force Increase Contrast, so its shots follow the system setting and are taken only
# while it is on.
if [[ "$(defaults read com.apple.universalaccess increaseContrast 2>/dev/null)" == 1 ]]; then
  for scenario in empty projects folder-missing; do
    SHOTS+=("agents-$scenario-contrast|Agents|-dataFolder @DATA@ -agentsScenario $scenario -sidebarCollapsed NO")
  done
elif [[ "${DEBUG_APP_LOCK_HELD:-}" == 1 ]]; then
  echo "agents-shots: Increase Contrast is off in System Settings, so its shots are skipped"
fi

if [[ "${DEBUG_APP_LOCK_HELD:-}" != 1 ]]; then
  exec scripts/with-debug-app.sh scripts/agents/agents-shots.sh "$@"
fi

selected=("$@")
real_data="$HOME/Library/Application Support/com.openvocally.app.debug"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

real_db_state() {
  for file in openvocally.sqlite openvocally.sqlite-wal openvocally.sqlite-shm; do
    if [[ -e "$real_data/$file" ]]; then
      stat -f "$file %Fm %z" "$real_data/$file"
    else
      echo "$file absent"
    fi
  done
}
before="$(real_db_state)"

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

# Launch Services can still list the quit copy for a moment and refuse the open with -600.
# -ApplePersistenceIgnoreState: windows saved by a hand-run session would open instead of the shot.
open_shot() {
  for _ in $(seq 1 10); do
    open -g "$app" --args "$@" -ApplePersistenceIgnoreState YES 2>/dev/null && return 0
    sleep 0.5
  done
  open -g "$app" --args "$@" -ApplePersistenceIgnoreState YES
}

first=1
for row in "${SHOTS[@]}"; do
  IFS='|' read -r name title args <<<"$row"
  if ((${#selected[@]})) && [[ " ${selected[*]} " != *" $name "* ]]; then
    continue
  fi
  data="$scratch/$name"
  mkdir -p "$data"
  read -r -a launch <<<"${args//@DATA@/$data}"
  if ((first)); then
    RUN_DEBUG_BACKGROUND=1 scripts/run-debug.sh "${launch[@]}" -ApplePersistenceIgnoreState YES
    first=0
  else
    quit_app
    open_shot "${launch[@]}"
  fi
  status=1
  # The first launch after a build registers the app with Launch Services and takes longest.
  for _ in $(seq 1 120); do
    sleep 0.5
    [[ -e "$data/agents-ready" ]] || continue
    pid="$(running | head -n 1)"
    [[ -n "$pid" ]] || continue
    if window="$("$window_id" "$pid" "$title")"; then status=0; break; fi
  done
  if ((status != 0)); then
    echo "agents-shots: no ready \"$title\" window for $name" >&2
    quit_app
    exit 1
  fi
  if [[ ! -s "$data/openvocally.sqlite" ]]; then
    echo "agents-shots: $name did not write its scratch database" >&2
    quit_app
    exit 1
  fi
  screencapture -x -o -l "$window" "$out/$name.png"
  echo "$out/$name.png"
done
quit_app

after="$(real_db_state)"
if [[ "$before" != "$after" ]]; then
  echo "agents-shots: the real Debug database changed during the run" >&2
  diff <(echo "$before") <(echo "$after") >&2 || true
  exit 1
fi
echo "agents-shots: the real Debug database is unchanged"
