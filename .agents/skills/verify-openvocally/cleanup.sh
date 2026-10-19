#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: .agents/skills/verify-openvocally/cleanup.sh

Quits the Debug builds of this checkout (.build/DerivedData and .build/DerivedData-perf) and
removes a Debug app lock whose holder is gone. Never touches the installed Release app or the
evidence folders under .build. Waits for the Debug app lock first, so it
never stops a run another script is driving.
EOF
  exit 0
fi

cd "$(dirname "$0")/../../.."
if [[ "${DEBUG_APP_LOCK_HELD:-}" != 1 ]]; then
  exec scripts/with-debug-app.sh .agents/skills/verify-openvocally/cleanup.sh
fi

for dir in DerivedData DerivedData-perf; do
  executable="$PWD/.build/$dir/Build/Products/Debug/OpenVocally.app/Contents/MacOS/OpenVocally"
  for pid in $(ps -axo pid=,comm= | awk -v exe="$executable" '{ pid = $1; sub(/^[ \t]*[0-9]+[ \t]+/, ""); if ($0 == exe) print pid }'); do
    kill "$pid"
    for _ in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.25
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "pid $pid did not quit in 5 s; stopping it." >&2
      kill -9 "$pid" 2>/dev/null || true
    fi
    echo "quit $executable (pid $pid)"
  done
done
echo "Evidence stays in .build: design-gallery, onboarding-shots, dictation-harness and transcripts-latency."
