#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'HELP'
Usage: scripts/agents/agents-a11y.sh

Checks that every project in the Agents thread list is reachable without a mouse. Holds the Debug
app lock, opens the Debug app in the background with a fresh scratch -dataFolder and
-agentsScenario projects, and reads the Agents window's accessibility tree with
scripts/lib/ax-actions.swift. For each seeded project it checks that the header offers Rename to
VoiceOver and that a "More for <project>" button can take keyboard focus. Prints each failure,
quits the app, and exits 1 when any check fails. Keeps the tree in .build/agents/a11y-tree.txt. Posts no clicks or keys. The terminal running it
needs Accessibility access in System Settings.
HELP
  exit 0
fi

cd "$(dirname "$0")/../.."
if [[ "${DEBUG_APP_LOCK_HELD:-}" != 1 ]]; then
  exec scripts/with-debug-app.sh scripts/agents/agents-a11y.sh "$@"
fi

app="$PWD/.build/DerivedData/Build/Products/Debug/OpenVocally Dev.app"
executable="$app/Contents/MacOS/OpenVocally"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
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
# Debug builds from every checkout share one bundle ID, and the app allows one instance, so open
# would only wake another checkout's copy.
other="$(ps -axo comm= | grep '/OpenVocally Dev.app/Contents/MacOS/OpenVocally$' | grep -vxF "$executable" | head -n 1 || true)"
if [[ -n "$other" ]]; then
  echo "agents-a11y: another OpenVocally Dev is running: $other. Quit it and run again." >&2
  exit 1
fi

swiftc -O scripts/lib/ax-actions.swift -o "$scratch/ax-actions"
quit_app
trap 'quit_app; rm -rf "$scratch"' EXIT
open -g "$app" --args -dataFolder "$scratch/data" -agentsScenario projects -sidebarCollapsed NO \
  -ApplePersistenceIgnoreState YES
for _ in $(seq 1 120); do
  [[ -e "$scratch/data/agents-ready" ]] && break
  sleep 0.5
done
[[ -e "$scratch/data/agents-ready" ]] || { echo "agents-a11y: the Agents screen never got ready" >&2; exit 1; }

status=0
"$scratch/ax-actions" "$(running | head -n 1)" Agents >"$scratch/tree.txt" || status=$?
case "$status" in
  0) ;;
  2) echo "agents-a11y: give this terminal Accessibility access in System Settings" >&2; exit 1 ;;
  *) echo "agents-a11y: no Agents window" >&2; exit 1 ;;
esac
mkdir -p .build/agents
cp "$scratch/tree.txt" .build/agents/a11y-tree.txt

failed=0
for project in openvocally "Marketing Site" docs notes-api; do
  if ! grep -qF "AXHeading label=$project actions=" "$scratch/tree.txt" \
    || ! grep -F "AXHeading label=$project actions=" "$scratch/tree.txt" | grep -qF "Rename"; then
    echo "FAIL $project: the header offers VoiceOver no Rename action"
    failed=1
  fi
  if ! grep -F "label=More for $project " "$scratch/tree.txt" | grep -qF "focusable=yes"; then
    echo "FAIL $project: no focusable More for $project button"
    failed=1
  fi
done
[[ "$failed" == 0 ]] && echo "agents-a11y: every project is reachable by keyboard and VoiceOver"
exit "$failed"
