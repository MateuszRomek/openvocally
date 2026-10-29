#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'HELP'
Usage: scripts/design/gallery-shots.sh [section ...]

Holds the Debug app lock (scripts/with-debug-app.sh), builds the Debug app, then opens it in
the background on the Design Gallery once per section and captures only the gallery window
to .build/design-gallery/<section>.png. Each shot shows the Light, Dark and both Increase
Contrast columns. Posts no clicks or keys and never takes focus. Captures the window itself,
so other windows on top don't matter. Sections default to type spacing radius color
surface notch notch-reduce-motion components sidebar panels motion language. The notch
sections open the window over the main display's visible area and shrink to fit it. Needs
Screen Recording for the terminal.
HELP
  exit 0
fi

cd "$(dirname "$0")/../.."
if [[ "${DEBUG_APP_LOCK_HELD:-}" != 1 ]]; then
  exec scripts/with-debug-app.sh scripts/design/gallery-shots.sh "$@"
fi

sections=("$@")
((${#sections[@]})) || sections=(type spacing radius color surface notch notch-reduce-motion components sidebar panels motion language)
out="$PWD/.build/design-gallery"
mkdir -p "$out"
app="$PWD/.build/DerivedData/Build/Products/Debug/OpenVocally Dev.app"
executable="$app/Contents/MacOS/OpenVocally"
window_id="$PWD/.build/window-id"
swiftc -O scripts/lib/window-id.swift -o "$window_id"
screens="$PWD/.build/screens"
swiftc -O scripts/lib/screens.swift -o "$screens"
# The notch sections shrink to fit the window, so they open it over the main display's
# visible area to stay legible. The argument domain is read before the saved frame.
read -r _ _ _ _ _ vx vy vw vh _ < <("$screens" | head -n 1)

frame_args=()

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
# -ApplePersistenceIgnoreState: windows saved by a hand-run session would open instead of the gallery.
open_section() {
  for _ in $(seq 1 10); do
    open -g "$app" --args -designGallery YES -designGallerySection "$1" -ApplePersistenceIgnoreState YES \
      ${frame_args[@]+"${frame_args[@]}"} 2>/dev/null && return 0
    sleep 0.5
  done
  open -g "$app" --args -designGallery YES -designGallerySection "$1" -ApplePersistenceIgnoreState YES \
    ${frame_args[@]+"${frame_args[@]}"}
}

for section in "${sections[@]}"; do
  frame_args=()
  [[ "$section" == notch* ]] && frame_args=(-"NSWindow Frame design-gallery" "$vx $vy $vw $vh")
  if [[ "$section" == "${sections[0]}" ]]; then
    RUN_DEBUG_BACKGROUND=1 scripts/run-debug.sh -designGallery YES -designGallerySection "$section" \
      -ApplePersistenceIgnoreState YES ${frame_args[@]+"${frame_args[@]}"}
  else
    quit_app
    open_section "$section"
  fi
  status=1
  for _ in $(seq 1 30); do
    sleep 0.5
    pid="$(running | head -n 1)"
    [[ -n "$pid" ]] || continue
    if window="$("$window_id" "$pid" "Design Gallery")"; then status=0; break; fi
  done
  sleep 1
  if ((status != 0)); then
    echo "gallery-shots: no Design Gallery window for $section" >&2
    quit_app
    exit 1
  fi
  screencapture -x -o -l "$window" "$out/$section.png"
  echo "$out/$section.png"
done
quit_app
