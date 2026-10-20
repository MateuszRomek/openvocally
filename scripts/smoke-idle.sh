#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'EOF'
Usage: scripts/smoke-idle.sh

Holds the Debug app lock (scripts/with-debug-app.sh), then builds and opens the Debug app
in the background with scripts/run-debug.sh, so it never takes focus. Measures CPU from the
app's cumulative CPU time. Waits until two back-to-back 2 s windows are each under 20% of
one core, so launch work such as the model load does not count, and fails as "never
settled" after 60 s. Then measures one 10 s window and fails above 20%, which catches a
SwiftUI update loop that pins the main thread. Prints the settle time and the measured
percentage. Quits only the Debug executable it opened; it never touches the Release app.
EOF
  exit 0
fi

cd "$(dirname "$0")/.."
if [[ "${DEBUG_APP_LOCK_HELD:-}" != 1 ]]; then
  exec scripts/with-debug-app.sh scripts/smoke-idle.sh "$@"
fi

executable="$PWD/.build/DerivedData/Build/Products/Debug/OpenVocally Dev.app/Contents/MacOS/OpenVocally"
limit=20
settle_window=2
settle_timeout=60
measure_window=10

running() {
  ps -axo pid=,comm= | awk -v exe="$executable" '{ pid = $1; sub(/^[ \t]*[0-9]+[ \t]+/, ""); if ($0 == exe) print pid }'
}

# Cumulative CPU seconds of the pid, from the [[hh:]mm:]ss.hh form ps prints.
cpu_seconds() {
  ps -o time= -p "$1" | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; printf "%.2f\n", s }'
}

# CPU use of the pid over the next $2 seconds, as a percentage of one core.
cpu_percent() {
  local before after start end
  before="$(cpu_seconds "$1")" || return 1
  start="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
  sleep "$2"
  after="$(cpu_seconds "$1")" || return 1
  end="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
  [[ -n "$before" && -n "$after" ]] || return 1
  printf "%.1f\n" "$(echo "scale=3; 100 * ($after - $before) / ($end - $start)" | bc)"
}

below() { (($(echo "$1 <= $limit" | bc))); }

quit_app() {
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.25
  done
  kill -9 "$pid" 2>/dev/null || true
}

RUN_DEBUG_BACKGROUND=1 scripts/run-debug.sh
launched=$SECONDS
pid=""
for _ in $(seq 1 40); do
  pid="$(running | head -n 1)"
  [[ -n "$pid" ]] && break
  sleep 0.25
done
if [[ -z "$pid" ]]; then
  echo "smoke-idle: the Debug app is not running after launch." >&2
  exit 1
fi
trap quit_app EXIT

calm=0
cpu=""
while ((calm < 2)); do
  if ((SECONDS - launched >= settle_timeout)); then
    echo "smoke-idle: never settled; CPU stayed above ${limit}% for ${settle_timeout} s (last window ${cpu}%)." >&2
    echo "Sample it with: sample $pid 2, and look for a SwiftUI graph update loop on the main thread." >&2
    exit 1
  fi
  if ! cpu="$(cpu_percent "$pid" "$settle_window")"; then
    echo "smoke-idle: the Debug app exited while settling." >&2
    exit 1
  fi
  if below "$cpu"; then calm=$((calm + 1)); else calm=0; fi
done
settled=$((SECONDS - launched))

if ! cpu="$(cpu_percent "$pid" "$measure_window")"; then
  echo "smoke-idle: the Debug app exited while idle." >&2
  exit 1
fi
echo "Settled after ${settled} s. Idle CPU over ${measure_window} s: ${cpu}% of one core (limit ${limit}%)."
if ! below "$cpu"; then
  echo "smoke-idle: the idle app is busy. Sample it with: sample $pid 2, and look for a SwiftUI graph update loop on the main thread." >&2
  exit 1
fi
