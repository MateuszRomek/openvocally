#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/run-debug.sh [app arguments...]

Builds the Debug app with scripts/build-debug.sh, quits a running copy of that exact build and
opens it. The build signs it with the "OpenVocally Local Signing" identity, and a stable
signature keeps the Accessibility and Microphone grants across rebuilds. Without the identity
the app stays ad-hoc signed, and macOS may ask for both grants again after each build.
Create the identity with scripts/setup-signing.sh.

RUN_DEBUG_BACKGROUND=1 opens the app without bringing it to the front.

Arguments are passed to the app, for example
  scripts/run-debug.sh -overlayDemo YES -overlayPlacement islandTop
EOF
}

case "${1:-}" in
  --help | -h)
    usage
    exit 0
    ;;
esac

cd "$(dirname "$0")/.."
app="$PWD/.build/DerivedData/Build/Products/Debug/OpenVocally Dev.app"
executable="$app/Contents/MacOS/OpenVocally"

scripts/whisper/build-xcframework.sh
xcodegen generate --quiet
scripts/build-debug.sh -quiet

for pid in $(ps -axo pid=,comm= | awk -v exe="$executable" '{ pid = $1; sub(/^[ \t]*[0-9]+[ \t]+/, ""); if ($0 == exe) print pid }'); do
  kill "$pid"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.3
  done
done

open ${RUN_DEBUG_BACKGROUND:+-g} "$app" --args "$@"
