#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/latency/dictation-latency.sh [--last DURATION | --start "YYYY-MM-DD HH:MM:SS" [--end "YYYY-MM-DD HH:MM:SS"]] [--runs N] [--pid PID] [--from FILE]

Reads the latency signposts the app emits (subsystem com.openvocally.app,
category latency) from the unified log, OpenVocally process only (the package tests emit the same
signposts), and prints n, median, p95 (nearest rank) and max in milliseconds for each mark:

  LB-01                    press to visible recording feedback
  LB-01-hold               the same for a one-key hold; not counted against --runs
  LB-02                    release to pasted text
  pressToCaptureRequested  press to the capture start request

  --last   time window ending now, in log show syntax such as 10m or 1h (default: 10m)
  --start  window start instead of --last
  --end    window end (default: now)
  --runs   required LB-01 and LB-02 count (default: 10)
  --pid    count only this process. A Release and a Debug app both run as OpenVocally, so a
           dictation in one lands in the other's window without it.
  --from   read log show ndjson from FILE instead of the unified log

Then it splits LB-02 into stages per run. A run opens at pressToCaptureRequested and closes
at LB-02; runs without LB-02 are dropped. "other" is LB-02 minus the measured stages
(inbox hops and queueing). LB-02-audio is the recorded audio length.

Exits non-zero when LB-01 or LB-02 has fewer than --runs samples.
EOF
}

last="10m"
start=""
end=""
runs=10
pid=""
from=""
while (($# > 0)); do
  case "$1" in
    --help | -h)
      usage
      exit 0
      ;;
    --last | --start | --end | --runs | --pid | --from)
      (($# >= 2)) || {
        echo "Missing value for $1" >&2
        exit 64
      }
      case "$1" in
        --last) last="$2" ;;
        --start) start="$2" ;;
        --end) end="$2" ;;
        --runs) runs="$2" ;;
        --pid) pid="$2" ;;
        --from) from="$2" ;;
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

[[ -z "$pid" || "$pid" =~ ^[0-9]+$ ]] || {
  echo "--pid must be a process id." >&2
  exit 64
}
[[ -z "$pid" || -z "$from" ]] || {
  echo "--pid filters the unified log; it does not apply to --from." >&2
  exit 64
}
window=(--last "$last")
if [[ -n "$start" ]]; then
  window=(--start "$start")
  [[ -n "$end" ]] && window+=(--end "$end")
fi

read_log() {
  if [[ -n "$from" ]]; then
    cat "$from"
  else
    /usr/bin/log show --signpost --style ndjson "${window[@]}" \
      --predicate "subsystem == \"com.openvocally.app\" AND category == \"latency\" AND process == \"OpenVocally\"${pid:+ AND processID == $pid}"
  fi
}

samples="$(
  read_log |
    sed -nE 's/.*"eventMessage":"ms=([0-9.]+)".*"signpostName":"([A-Za-z0-9-]+)".*/\2 \1/p; s/.*"signpostName":"([A-Za-z0-9-]+)".*"eventMessage":"ms=([0-9.]+)".*/\1 \2/p'
)"

# Prints "n median p95 max" for the numbers on stdin, or "0 - - -".
stats() {
  sort -n | awk '{ v[NR] = $1 }
    END {
      if (NR == 0) { print "0 - - -"; exit }
      m = int((NR + 1) / 2); p = int((95 * NR + 99) / 100)
      printf "%d %s %s %s\n", NR, v[m], v[p], v[NR]
    }'
}

status=0
printf '%-24s %5s %10s %10s %10s\n' mark n median_ms p95_ms max_ms
for mark in LB-01 LB-01-hold LB-02 pressToCaptureRequested; do
  read -r n median p95 max < <(printf '%s\n' "$samples" | awk -v m="$mark" '$1 == m { print $2 }' | stats)
  printf '%-24s %5s %10s %10s %10s\n' "$mark" "$n" "$median" "$p95" "$max"
  if [[ "$mark" == LB-01 || "$mark" == LB-02 ]] && ((n < runs)); then
    echo "$mark: $n runs found, $runs required." >&2
    status=1
  fi
done

stages="tail resample transcribe process pasteSetup keyPost"
runs_table="$(
  printf '%s\n' "$samples" | awk -v stages="$stages" '
    BEGIN { ns = split(stages, s, " ") }
    function reset() { delete seen; for (i = 1; i <= ns; i++) seen[s[i]] = ""; audio = "" }
    BEGIN { reset() }
    $1 == "pressToCaptureRequested" { reset(); next }
    $1 == "LB-02-audio" { audio = $2; next }
    $1 ~ /^LB-02-/ { seen[substr($1, 7)] = $2; next }
    $1 == "LB-02" {
      other = $2
      for (i = 1; i <= ns; i++) {
        if (seen[s[i]] != "") { print s[i], seen[s[i]]; other -= seen[s[i]] }
      }
      printf "other %.2f\n", other
      if (audio != "") print "audio", audio
      reset()
    }'
)"

echo
echo "LB-02 stages"
printf '%-24s %5s %10s %10s %10s\n' stage n median_ms p95_ms max_ms
for stage in $stages other; do
  read -r n median p95 max < <(printf '%s\n' "$runs_table" | awk -v m="$stage" '$1 == m { print $2 }' | stats)
  printf '%-24s %5s %10s %10s %10s\n' "$stage" "$n" "$median" "$p95" "$max"
done
read -r n median _ max < <(printf '%s\n' "$runs_table" | awk '$1 == "audio" { print $2 }' | stats)
min="$(printf '%s\n' "$runs_table" | awk '$1 == "audio" { print $2 }' | sort -n | head -1)"
printf 'audio_ms n=%s median=%s min=%s max=%s\n' "$n" "$median" "${min:--}" "$max"
exit "$status"
