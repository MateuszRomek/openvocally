#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'HELP'
Usage: scripts/agents/agents-bench.sh [out.jsonl]
       scripts/agents/agents-bench.sh --screen [runs]

Measures the Agents thread list at scale, off screen. Runs the AgentsBenchmark test in
OpenVocallyKit, which seeds the large scenario (40 projects of 300 threads with 20 items each)
into a database file in a temporary folder and runs each case 10 times: "list", the thread list's
first value and its row count, and "append", whether one stored conversation item makes the list
emit again and how long that takes. Writes one JSON line per run to out.jsonl (default
.build/agents/bench.jsonl) and prints the median and max per case. Launches no app.

--screen holds the Debug app lock and opens the Debug app in the background runs times (default
10), each with a fresh scratch -dataFolder and -agentsScenario large. It reads the time from the
Agents screen's creation to its first list drawn, and the rows drawn, from the agents-ready file,
quits the app, and prints the median and max. Posts no clicks or keys.
HELP
  exit 0
fi

cd "$(dirname "$0")/../.."

if [[ "${1:-}" == "--screen" ]]; then
  if [[ "${DEBUG_APP_LOCK_HELD:-}" != 1 ]]; then
    exec scripts/with-debug-app.sh scripts/agents/agents-bench.sh "$@"
  fi
  runs="${2:-10}"
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
  # Debug builds from every checkout share one bundle ID, and the app allows one instance, so
  # open would only wake another checkout's copy and this run would time nothing.
  other="$(ps -axo comm= | grep '/OpenVocally Dev.app/Contents/MacOS/OpenVocally$' | grep -vxF "$executable" | head -n 1 || true)"
  if [[ -n "$other" ]]; then
    echo "agents-bench: another OpenVocally Dev is running: $other. Quit it and run again." >&2
    exit 1
  fi
  quit_app
  results=()
  for run in $(seq 1 "$runs"); do
    data="$scratch/run-$run"
    mkdir -p "$data"
    open -g "$app" --args -dataFolder "$data" -agentsScenario large -sidebarCollapsed NO \
      -ApplePersistenceIgnoreState YES
    for _ in $(seq 1 240); do
      [[ -e "$data/agents-ready" ]] && break
      sleep 0.5
    done
    line="$(grep '^ms=' "$data/agents-ready" 2>/dev/null || true)"
    quit_app
    [[ -n "$line" ]] || { echo "agents-bench: run $run wrote no timing" >&2; exit 1; }
    echo "run $run: $line (load $(sysctl -n vm.loadavg | awk '{ print $2 }'))"
    results+=("$line")
  done
  printf '%s\n' "${results[@]}" | python3 -I -c '
import statistics, sys
pairs = [dict(kv.split("=") for kv in line.split()) for line in sys.stdin if line.strip()]
ms = [float(p["ms"]) for p in pairs]
print(f"screen: median {statistics.median(ms):.1f} ms, max {max(ms):.1f} ms, n={len(ms)} rows={pairs[0]["rows"]}")'
  exit 0
fi
out="${1:-.build/agents/bench.jsonl}"
mkdir -p "$(dirname "$out")"
# The test runs in the package's folder, so it needs an absolute path.
out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"
rm -f "$out"

AGENTS_BENCH_OUT="$out" swift test --package-path OpenVocallyKit --filter 'AgentsBenchmark' >/dev/null
git checkout -- OpenVocallyKit/Package.resolved 2>/dev/null || true
[[ -s "$out" ]] || { echo "agents-bench: no results in $out" >&2; exit 1; }

python3 -I - "$out" <<'PY'
import json, statistics, sys
runs = [json.loads(line) for line in open(sys.argv[1])]
for case in ("list", "append"):
    rows = [r for r in runs if r["case"] == case]
    times = [float(r["ms"]) for r in rows if "ms" in r]
    extra = ""
    if case == "list":
        extra = f" rows={rows[0]['rows']}"
    else:
        extra = f" refired={sum(r['refired'] for r in rows)}/{len(rows)}"
    if times:
        print(f"{case}: median {statistics.median(times):.1f} ms, max {max(times):.1f} ms, n={len(times)}{extra}")
    else:
        print(f"{case}: no timings, n={len(rows)}{extra}")
PY
echo "$out"
