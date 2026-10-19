#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" || $# -eq 0 ]]; then
  cat <<'EOF'
Usage: scripts/with-debug-app.sh <command> [args ...]

Runs the command while holding the Debug app lock, so only one script at a time builds,
launches or drives the Debug app. Waits up to WAIT seconds (default 900) for another holder,
then fails. A lock left by a process that no longer exists is taken over. A command that
already runs under the lock (DEBUG_APP_LOCK_HELD=1) runs straight away.
EOF
  exit 0
fi

if [[ "${DEBUG_APP_LOCK_HELD:-}" == 1 ]]; then
  exec "$@"
fi

cd "$(dirname "$0")/.."
lock="$PWD/.build/debug-app.lock"
mkdir -p .build
deadline=$((SECONDS + ${WAIT:-900}))
until mkdir "$lock" 2>/dev/null; do
  holder="$(cat "$lock/pid" 2>/dev/null || true)"
  if [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null; then
    rm -rf "$lock"
    continue
  fi
  if ((SECONDS >= deadline)); then
    echo "The Debug app is busy (lock held by pid ${holder:-unknown}): $lock" >&2
    exit 1
  fi
  sleep 2
done
echo $$ >"$lock/pid"
trap 'rm -rf "$lock"' EXIT
DEBUG_APP_LOCK_HELD=1 "$@"
