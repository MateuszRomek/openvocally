#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/latency/dictation-harness.sh [--runs N] [--fixture ID] [--mode ptt|toggle] [--model ID|all]

Proves the real dictation pipeline, overlay and speech model without a human, a microphone,
Accessibility or a real paste. Builds the Debug app and launches it with -dictationHarness:
each run plays a WAV fixture from scripts/fixtures/ as the microphone, holds the shortcut for
the fixture's length, records the paste instead of posting Cmd+V, and checks the text against
the fixture's reference. The overlay shows briefly on screen; no key event is posted.

  --runs     runs to play (default 5, max 10)
  --fixture  fixture id from scripts/fixtures/fixtures.tsv (default en-short)
  --mode     ptt (hold) or toggle (default ptt)
  --model    model id from ModelID in OpenVocallyKit/Sources/Models/ModelCatalog.swift, or all
             for every model one after another (default: the active model). The app loads the
             model for the runs and keeps its active model. A model that isn't installed is
             reported as skipped.
  TIMEOUT    seconds to wait for the app to finish (default 300)

The app writes history to a scratch data folder under TMPDIR, never the real one, and reads
the installed models. Evidence (scenario, results.jsonl, latency.txt) stays in
.build/dictation-harness/<timestamp>/, in one folder per model with --model. The summary prints
one row per model: the median and max of LB-01, LB-02 and the word error rate.

Exits non-zero when a run has no text, its word error rate is over 0.1 (one wrong word in
ten; the 17-word en-short sentence allows one substitution), or the LB-01 or LB-02 count in
the unified log differs from the run count.
EOF
}

runs=5
fixture_id="en-short"
mode="ptt"
model=""
while (($# > 0)); do
  case "$1" in
    --help | -h)
      usage
      exit 0
      ;;
    --runs | --fixture | --mode | --model)
      (($# >= 2)) || {
        echo "Missing value for $1" >&2
        exit 64
      }
      case "$1" in
        --runs) runs="$2" ;;
        --fixture) fixture_id="$2" ;;
        --mode) mode="$2" ;;
        --model) model="$2" ;;
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

[[ "$runs" =~ ^[0-9]+$ ]] && ((runs >= 1 && runs <= 10)) || {
  echo "--runs must be 1 to 10." >&2
  exit 64
}
case "$mode" in
  ptt) app_mode="pushToTalk" ;;
  toggle) app_mode="toggle" ;;
  *)
    echo "--mode must be ptt or toggle." >&2
    exit 64
    ;;
esac

cd "$(dirname "$0")/../.."
catalog="$(sed -n '/^public enum ModelID/,/^}/s/^  case [A-Za-z0-9]* = "\(.*\)"$/\1/p' OpenVocallyKit/Sources/Models/ModelCatalog.swift)"
[[ -n "$catalog" ]] || {
  echo "No model ids found in ModelCatalog.swift." >&2
  exit 1
}
models=()
case "$model" in
  "") models=("") ;;
  all) while IFS= read -r id; do models+=("$id"); done <<<"$catalog" ;;
  *)
    grep -qxF -- "$model" <<<"$catalog" || {
      echo "Unknown model: $model. Known models: all $(tr '\n' ' ' <<<"$catalog")" >&2
      exit 64
    }
    models=("$model")
    ;;
esac

if [[ "${DEBUG_APP_LOCK_HELD:-}" != 1 ]]; then
  exec scripts/with-debug-app.sh scripts/latency/dictation-harness.sh --runs "$runs" --fixture "$fixture_id" \
    --mode "$mode" ${model:+--model "$model"}
fi

row="$(awk -F'\t' -v id="$fixture_id" 'NR > 1 && $1 == id' scripts/fixtures/fixtures.tsv)"
[[ -n "$row" ]] || {
  echo "Unknown fixture: $fixture_id (see scripts/fixtures/fixtures.tsv)" >&2
  exit 64
}
fixture="$PWD/scripts/fixtures/$fixture_id.wav"
expected="$(printf '%s' "$row" | cut -f4)"

root="$PWD/.build/dictation-harness/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$root"
# The app may not read the repo when it sits in a privacy-protected folder such as Desktop, so
# everything it opens lives in a scratch folder, and the evidence is copied back.
scratch_root="$(mktemp -d "${TMPDIR:-/tmp}/dictation-harness.XXXXXX")"
trap 'rm -rf "$scratch_root"' EXIT
cp "$fixture" "$scratch_root/"
fixture="$scratch_root/$(basename "$fixture")"
executable="$PWD/.build/DerivedData/Build/Products/Debug/OpenVocally.app/Contents/MacOS/OpenVocally"
rows="$scratch_root/rows.tsv"
: >"$rows"

app_pid() {
  ps -axo pid=,comm= | awk -v exe="$executable" '{ pid = $1; sub(/^[ \t]*[0-9]+[ \t]+/, ""); if ($0 == exe) print pid }' | head -1
}

# Plays the scenario on one model ("" for the active one) and appends its row to $rows.
# Returns 1 when a run or a latency check failed.
play() {
  local id="$1" evidence scratch scenario results latency pid start end deadline status=0
  evidence="$root${id:+/$id}"
  scratch="$scratch_root/${id:-active}"
  mkdir -p "$evidence" "$scratch/data"
  scenario="$scratch/scenario.json"
  results="$scratch/results.jsonl"
  latency="$evidence/latency.txt"
  echo "== ${id:-active model}"
  python3 -I -c '
import json, sys
runs, fixture, mode, expected, model = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
run = {"fixture": fixture, "mode": mode, "expected": expected}
scenario = {"maxWordErrorRate": 0.1, "runs": [run] * runs}
if model:
    scenario["model"] = model
json.dump(scenario, sys.stdout, ensure_ascii=False)
' "$runs" "$fixture" "$app_mode" "$expected" "$id" >"$scenario"
  cp "$scenario" "$evidence/"

  start="$(date '+%Y-%m-%d %H:%M:%S')"
  RUN_DEBUG_BACKGROUND=1 scripts/run-debug.sh -dictationHarness "$scenario" -harnessOutput "$results" \
    -dataFolder "$scratch/data" -ApplePersistenceIgnoreState YES || {
    echo "scripts/run-debug.sh failed." >&2
    printf '%s\tfailed\n' "${id:-active}" >>"$rows"
    return 1
  }

  pid=""
  for _ in $(seq 1 50); do
    pid="$(app_pid)"
    [[ -n "$pid" ]] && break
    sleep 0.2
  done
  if [[ -z "$pid" ]]; then
    echo "The Debug app did not start." >&2
    printf '%s\tfailed\n' "${id:-active}" >>"$rows"
    return 1
  fi

  deadline=$((SECONDS + ${TIMEOUT:-300}))
  until grep -q '"summary":true' "$results" 2>/dev/null; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "The Debug app quit without a summary line." >&2
      printf '%s\tfailed\n' "${id:-active}" >>"$rows"
      return 1
    fi
    if ((SECONDS >= deadline)); then
      echo "No summary line after ${TIMEOUT:-300} s; stopping pid $pid." >&2
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 30); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
      done
      printf '%s\tfailed\n' "${id:-active}" >>"$rows"
      return 1
    fi
    sleep 1
  done
  for _ in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  sleep 1
  end="$(date '+%Y-%m-%d %H:%M:%S')"

  if grep -q '"skipped":' "$results"; then
    echo "Skipped: $(python3 -I -c 'import json, sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["skipped"])' "$results")"
    printf '%s\tskipped\n' "$id" >>"$rows"
    return 0
  fi

  echo "Results: $evidence/results.jsonl"
  python3 -I -c '
import json, sys
lines = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
runs = [line for line in lines if "run" in line]
summary = lines[-1]
ok = True
for run in runs:
    wer = run.get("wordErrorRate")
    print("run %s: match=%s wer=%s lb01=%s lb02=%s failure=%s text=%r" % (
        run["run"], run["match"], wer if wer is None else round(wer, 3), run.get("lb01Ms"),
        run.get("lb02Ms"), run.get("failure"), run["text"]))
    if not run["text"] or not run["match"]:
        ok = False
if summary.get("failure"):
    print("harness failure: %s" % summary["failure"])
    ok = False
if len(runs) != int(sys.argv[2]):
    print("%d runs reported, %s expected" % (len(runs), sys.argv[2]))
    ok = False
sys.exit(0 if ok else 1)
' "$results" "$runs" || status=1

  scripts/latency/dictation-latency.sh --start "$start" --end "$end" --runs "$runs" --pid "$pid" | tee "$latency" || status=1
  local mark n
  for mark in LB-01 LB-02; do
    n="$(awk -v m="$mark" '$1 == m { print $2; exit }' "$latency")"
    if [[ "$n" != "$runs" ]]; then
      echo "$mark: $n signposts, $runs expected." >&2
      status=1
    fi
  done
  python3 -I -c '
import json, statistics, sys
marks = {}
for line in open(sys.argv[2], encoding="utf-8"):
    cols = line.split()
    if len(cols) == 5 and cols[0] in ("LB-01", "LB-02"):
        marks.setdefault(cols[0], (cols[2], cols[4]))
rates = [json.loads(line).get("wordErrorRate") for line in open(sys.argv[3], encoding="utf-8") if "\"run\"" in line]
rates = [rate for rate in rates if rate is not None]
wer = ("%.3f" % statistics.median(rates), "%.3f" % max(rates)) if rates else ("-", "-")
lb01, lb02 = marks.get("LB-01", ("-", "-")), marks.get("LB-02", ("-", "-"))
print("\t".join([sys.argv[1], "failed" if sys.argv[4] != "0" else "ok", *lb01, *lb02, *wer]))
' "$(python3 -I -c 'import json, sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1]).get("model") or "active")' "$results")" \
    "$latency" "$results" "$status" >>"$rows"
  return "$status"
}

status=0
for id in "${models[@]}"; do
  play "$id" || status=1
  cp -f "$scratch_root/${id:-active}/results.jsonl" "$root${id:+/$id}/" 2>/dev/null || true
done
if ! grep -qv $'\tskipped$' "$rows"; then
  echo "No model played: every model asked for is skipped." >&2
  status=1
fi

echo
printf '%-28s %-8s %12s %10s %12s %10s %10s %8s\n' model result LB-01_median LB-01_max LB-02_median LB-02_max WER_median WER_max
while IFS=$'\t' read -r id result lb01_median lb01_max lb02_median lb02_max wer_median wer_max; do
  printf '%-28s %-8s %12s %10s %12s %10s %10s %8s\n' "$id" "$result" "${lb01_median:--}" "${lb01_max:--}" \
    "${lb02_median:--}" "${lb02_max:--}" "${wer_median:--}" "${wer_max:--}"
done <"$rows"
echo "Evidence: $root"
exit "$status"
