#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'HELP'
Usage: scripts/agents/agents-shots.sh [shot ...]

Builds the fake claude and codex CLIs (the FakeAgentCLI target in OpenVocallyKit) and installs
them to .build/agent-fakes/<scenario>/<claude|codex>. Runs --version on every installed fake and
fails if one fails. Writes one "<scenario> <provider> <path>" line per fake to
.build/agents/fakes.txt. Then, holding the Debug app lock, opens the Debug app in the background
once per row of the SHOTS table and captures that window to .build/agents/<shot>.png. Shots
default to every row. The table is empty until the Agents UI exists, so the script stops after
the fakes check. Posts no clicks or keys. Needs Screen Recording for the terminal when it takes shots.
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
# A row's launch arguments select the screen and point a provider's binary path at a fake
# under $root. The path must be absolute: open starts the app in /. Example row (the setting
# name depends on the Agents UI):
#   "claude-approval|Agents|-agentsClaudePath $root/command-approval/claude"
SHOTS=()
if ((${#SHOTS[@]} == 0)); then
  echo "agents-shots: no Agents UI shots exist yet."
  exit 0
fi

if [[ "${DEBUG_APP_LOCK_HELD:-}" != 1 ]]; then
  exec scripts/with-debug-app.sh scripts/agents/agents-shots.sh "$@"
fi

selected=("$@")
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
  read -r -a launch <<<"$args"
  if ((first)); then
    RUN_DEBUG_BACKGROUND=1 scripts/run-debug.sh "${launch[@]}" -ApplePersistenceIgnoreState YES
    first=0
  else
    quit_app
    open_shot "${launch[@]}"
  fi
  status=1
  for _ in $(seq 1 30); do
    sleep 0.5
    pid="$(running | head -n 1)"
    [[ -n "$pid" ]] || continue
    if window="$("$window_id" "$pid" "$title")"; then status=0; break; fi
  done
  sleep 1
  if ((status != 0)); then
    echo "agents-shots: no \"$title\" window for $name" >&2
    quit_app
    exit 1
  fi
  screencapture -x -o -l "$window" "$out/$name.png"
  echo "$out/$name.png"
done
quit_app
