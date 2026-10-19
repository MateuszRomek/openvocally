#!/usr/bin/env bash
set -euo pipefail

if [[ "${DEBUG_APP_LOCK_HELD:-}" != 1 && "${1:-}" != --help && "${1:-}" != -h ]]; then
  here="$(cd "$(dirname "$0")" && pwd)"
  exec "$here/../with-debug-app.sh" "$here/transcripts-latency.sh" "$@"
fi

usage() {
  cat <<'EOF'
Usage: scripts/latency/transcripts-latency.sh [--rows N|all] [--runs N] [--scenario open|sidebar|width|select]
       scripts/latency/transcripts-latency.sh --rows N --trace scroll|switch|sidebar
       scripts/latency/transcripts-latency.sh --record
       scripts/latency/transcripts-latency.sh --screenshots
       scripts/latency/transcripts-latency.sh --report FILE...

Measures the Home and Transcripts screens on a seeded database. The script builds the Debug
configuration with Release optimization (-O, whole module, into .build/DerivedData-perf), since the
harness is compiled only into Debug and an -Onone build would overstate the cost of Swift code,
GRDB included. It builds once, then opens that app once per size with the -transcriptsHarness
launch argument, and every scenario runs in that launch. The app opens seed-N.sqlite in the Debug
data folder, seeding it only when it is empty, and never the real openvocally.sqlite. The hotkeys, microphone and models do not start, and no input event is posted.
The window appears while a run lasts.

A launch opens Home and Transcripts 3 times each, saves 5 synthetic dictations on Home and at
each page count, loads Transcripts to 1, 5, 10 and 20 pages, scrolls the list for up to 3 s at
each page count, toggles the sidebar 10 times on Home and at 1 and 10 pages and opens and closes
the transcript detail 10 times at 10 pages while a display link records frame gaps and the
layout, switches screens, switches every 40 ms while saving at 20 pages (the hang repro),
shrinks the window to its minimum on Transcripts and records how much opening Home and Settings
grows it, and records the memory footprint. Before it quits, the app deletes every dictation it
saved; the run fails unless seed-N.sqlite is back to exactly N transcripts.
It takes about a minute per size; --scenario runs one part in 5 to 15 s instead. The script
prints, per size and measurement, n, median, p95 and max in milliseconds (MB for memory, points
or counts for layout rows); frame rows add the frames over 16.7 ms and over 33 ms. An open or
switch row ends at the first display frame after the screen reports its content shown.

A watchdog samples the main thread when a screen switch stalls for over 2 s, and samples then
kills an app that has not quit 15 s after its harness finished or 300 s after launch. Samples and
results go to .build/transcripts-latency/.

  --rows    seeded transcripts: 1000, 10000, 50000 or all (default: 50000, where the budgets apply)
  --runs    launches per size (default: 1)
  --scenario
            run one part of a launch: open opens Transcripts and Home 10 times each, sidebar
            toggles the sidebar 10 times on Home and on Transcripts, width opens and closes the
            transcript detail 10 times and then runs the minimum width check, select selects row 20
            at the window's minimum width
  --trace   one launch that records a Time Profiler trace with xctrace, then prints the top
            main-thread frames: scroll scrolls the list with 10 pages loaded, switch opens
            Home and Transcripts in turn, sidebar toggles the sidebar on Home
  --record  one 1000-row launch that collapses and expands the sidebar on Home while
            screencapture records the screen for 6 s
  --screenshots
            one 1000-row launch that captures the app's own window on Transcripts with nothing
            selected and with the first row selected, with screencapture -l, then opens and
            closes the detail 10 times and runs the minimum width check, and prints their table
  --report  only print the tables for earlier results files, one table per size. The size is
            read from the file name (STAMP-SIZE-runN.tsv); other names form one table each

Exits non-zero when a run did not finish.
EOF
}

rows=50000
runs=1
scenario=
trace=0
record=0
screenshots=0
report_files=()
while (($# > 0)); do
  case "$1" in
    --help | -h)
      usage
      exit 0
      ;;
    --trace)
      (($# >= 2)) || {
        echo "Missing value for $1" >&2
        exit 64
      }
      case "$2" in
        scroll) trace=1 ;;
        switch) trace=2 ;;
        sidebar) trace=3 ;;
        *)
          echo "--trace must be scroll, switch or sidebar." >&2
          exit 64
          ;;
      esac
      shift 2
      ;;
    --record)
      record=1
      shift
      ;;
    --screenshots)
      screenshots=1
      shift
      ;;
    --report)
      shift
      report_files=("$@")
      break
      ;;
    --rows | --runs | --scenario)
      (($# >= 2)) || {
        echo "Missing value for $1" >&2
        exit 64
      }
      case "$1" in
        --rows) rows="$2" ;;
        --runs) runs="$2" ;;
        --scenario)
          case "$2" in
            open | sidebar | width | select) scenario="$2" ;;
            *)
              echo "--scenario must be open, sidebar, width or select." >&2
              exit 64
              ;;
          esac
          ;;
      esac
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

case "$rows" in
  all) sizes=(1000 10000 50000) ;;
  1000 | 10000 | 50000) sizes=("$rows") ;;
  *)
    echo "--rows must be 1000, 10000, 50000 or all." >&2
    exit 64
    ;;
esac

cd "$(dirname "$0")/../.."
app="$PWD/.build/DerivedData-perf/Build/Products/Debug/OpenVocally.app"
executable="$app/Contents/MacOS/OpenVocally"
out="$PWD/.build/transcripts-latency"

app_pid() {
  ps -axo pid=,comm= | awk -v exe="$executable" '{ pid = $1; sub(/^[ \t]*[0-9]+[ \t]+/, ""); if ($0 == exe) print pid }'
}

other_debug_app() {
  local path
  ps -axo comm= | awk -v exe="$executable" '$0 ~ /OpenVocally\.app\/Contents\/MacOS\/OpenVocally$/ && $0 != exe' |
    while read -r path; do
      if [[ "$(defaults read "${path%/MacOS/OpenVocally}/Info" CFBundleIdentifier 2>/dev/null)" == com.openvocally.app.debug ]]; then
        echo "$path"
      fi
    done
}

summarize() {
  awk -F '\t' '
    $1 == "done" { done++; if ($2 != 1) failed++; next }
    $1 == "failed" { print "failed step: " $3 > "/dev/stderr"; next }
    $1 ~ /^trace / { next }
    {
      if (!($1 in count)) order[++keys] = $1
      samples[$1, ++count[$1]] = $2 + 0
    }
    END {
      printf "%-40s %6s %9s %9s %9s %7s %7s\n", "measure", "n", "median", "p95", "max", ">16.7", ">33"
      for (k = 1; k <= keys; k++) {
        key = order[k]; n = count[key]; over16 = 0; over33 = 0
        for (i = 1; i <= n; i++) { sorted[i] = samples[key, i]; if (sorted[i] > 16.7) over16++; if (sorted[i] > 33) over33++ }
        for (i = 2; i <= n; i++) { v = sorted[i]; j = i - 1; while (j >= 1 && sorted[j] > v) { sorted[j + 1] = sorted[j]; j-- } sorted[j + 1] = v }
        if (key ~ /^frames /) {
          printf "%-40s %6d %9.2f %9.2f %9.2f %7d %7d\n", key, n, sorted[int((n + 1) / 2)], sorted[int((95 * n + 99) / 100)], sorted[n], over16, over33
        } else {
          printf "%-40s %6d %9.2f %9.2f %9.2f\n", key, n, sorted[int((n + 1) / 2)], sorted[int((95 * n + 99) / 100)], sorted[n]
        }
      }
      printf "%d runs finished, %d failed\n", done, failed
      if (done == 0 || failed > 0) exit 1
    }' "$@"
}

report() {
  local status=0 size file
  local -a sizes_seen=()
  for file in "$@"; do
    size="$(basename "$file" | sed -nE 's/^[0-9]+-[0-9]+-([0-9]+)-run[0-9]+\.tsv$/\1/p')"
    [[ -n "$size" ]] || size="$file"
    [[ " ${sizes_seen[*]-} " == *" $size "* ]] || sizes_seen+=("$size")
  done
  for size in "${sizes_seen[@]}"; do
    local -a group=()
    for file in "$@"; do
      [[ "$file" == *"-$size-run"*.tsv || "$file" == "$size" ]] && group+=("$file")
    done
    echo "== $size (${#group[@]} file(s))"
    summarize "${group[@]}" || status=1
    echo
  done
  return "$status"
}

if ((${#report_files[@]} > 0)); then
  report "${report_files[@]}"
  exit $?
fi

other="$(other_debug_app)"
if [[ -n "$other" ]]; then
  echo "Another OpenVocally Debug build is running and shares this bundle id:" >&2
  echo "  $other" >&2
  echo "Quit it first." >&2
  exit 1
fi
mkdir -p "$out"

scripts/whisper/build-xcframework.sh
xcodegen generate --quiet
xcodebuild -project OpenVocally.xcodeproj -scheme OpenVocally -configuration Debug \
  -derivedDataPath .build/DerivedData-perf ENABLE_DEBUG_DYLIB=NO ENABLE_TESTABILITY=NO \
  SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule GCC_OPTIMIZATION_LEVEL=s build -quiet >&2

watch_run() {
  local pid="$1" result="$2" label="$3" ticks=0 finished_at=-1 stalled=0
  while kill -0 "$pid" 2>/dev/null; do
    if [[ -f "$result.state" && "$(cat "$result.state")" == switching ]]; then
      stalled=$((stalled + 1))
      if ((stalled == 4)); then
        echo "A screen switch is past 2 s; sampling the main thread." >&2
        sample "$pid" 5 -file "$out/$label-switch.sample.txt" >/dev/null 2>&1 || true
      fi
    else
      stalled=0
    fi
    if ((finished_at < 0)) && [[ -s "$result" ]]; then
      finished_at=$ticks
    fi
    if { ((finished_at >= 0)) && ((ticks - finished_at > 30)); } || ((ticks > 600)); then
      echo "The app did not quit; sampling it to $out/$label-stuck.sample.txt, then killing it." >&2
      sample "$pid" 3 -file "$out/$label-stuck.sample.txt" >/dev/null 2>&1 || true
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
      return 1
    fi
    sleep 0.5
    ticks=$((ticks + 1))
  done
}

launch() {
  local rows="$1" result="$2"
  shift 2
  rm -f "$result" "$result.state"
  open "$app" --args -transcriptsHarness YES -seedTranscripts "$rows" -harnessOutput "$result" \
    -ApplePersistenceIgnoreState YES "$@" >&2
  local pid=""
  for _ in $(seq 1 50); do
    pid="$(app_pid)"
    [[ -n "$pid" ]] && break
    sleep 0.2
  done
  if [[ -z "$pid" ]]; then
    echo "The Debug app did not start." >&2
    exit 1
  fi
  echo "$pid"
}

stamp="$(date '+%Y%m%d-%H%M%S')"
if ((record == 1)); then
  result="$out/$stamp-sidebar-demo.tsv"
  pid="$(launch 1000 "$result" -harnessSidebarDemo YES)"
  for _ in $(seq 1 240); do
    [[ -f "$result.state" && "$(cat "$result.state")" == ready ]] && break
    sleep 0.5
  done
  screencapture -v -V 6 -x "$out/$stamp-sidebar-demo.mov" || echo "screencapture failed; it needs Screen Recording access." >&2
  watch_run "$pid" "$result" "$stamp-sidebar-demo" || true
  echo "$out/$stamp-sidebar-demo.mov"
  exit 0
fi
if ((screenshots == 1)); then
  result="$out/$stamp-screenshots.tsv"
  pid="$(launch 1000 "$result" -harnessScreenshots YES)"
  for shot in list detail; do
    for _ in $(seq 1 240); do
      [[ -f "$result.state" && "$(cat "$result.state")" == "$shot "* ]] && break
      sleep 0.5
    done
    window="$(cut -d ' ' -f 2 "$result.state")"
    screencapture -x -o -l "$window" "$out/$stamp-transcripts-$shot.png" ||
      echo "screencapture failed; it needs Screen Recording access." >&2
    echo "$out/$stamp-transcripts-$shot.png"
  done
  watch_run "$pid" "$result" "$stamp-screenshots" || true
  summarize "$result"
  exit $?
fi
if ((trace > 0)); then
  [[ "$rows" == all ]] && rows=50000
  case "$trace" in
    1) kind=scroll argument=-harnessTraceScroll ;;
    2) kind=switch argument=-harnessTraceSwitch ;;
    *) kind=sidebar argument=-harnessTraceSidebar ;;
  esac
  result="$out/$stamp-$rows-trace-$kind.tsv"
  pid="$(launch "$rows" "$result" "$argument" YES)"
  for _ in $(seq 1 240); do
    [[ -f "$result.state" && "$(cat "$result.state")" == ready ]] && break
    sleep 0.5
  done
  trace_file="$out/$stamp-$rows-$kind.trace"
  xcrun xctrace record --template 'Time Profiler' --attach "$pid" --time-limit 12s --output "$trace_file" >/dev/null
  watch_run "$pid" "$result" "$stamp-$rows-trace-$kind" || true
  xcrun xctrace export --input "$trace_file" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' >"$out/$stamp-$rows-profile.xml"
  python3 -I scripts/latency/top-main-frames.py "$out/$stamp-$rows-profile.xml"
  exit 0
fi

status=0
began=$SECONDS
for size in "${sizes[@]}"; do
  files=()
  size_began=$SECONDS
  for ((run = 1; run <= runs; run++)); do
    result="$out/$stamp-$size-run$run.tsv"
    pid="$(launch "$size" "$result" ${scenario:+-harnessScenario "$scenario"})"
    watch_run "$pid" "$result" "$stamp-$size-run$run" || status=1
    files+=("$result")
  done
  echo
  echo "== $size rows, $runs launch(es), $((SECONDS - size_began)) s"
  summarize "${files[@]}" || status=1
done
echo
echo "All sizes: $((SECONDS - began)) s after the build."
exit "$status"
