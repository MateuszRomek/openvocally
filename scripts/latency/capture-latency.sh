#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/latency/capture-latency.sh [--device UID|default] [--runs N] [--mode cold|warm] [--idle MS] [--hold MS] [--press-lead MS] [--check-idle] [--device-change [--bluetooth]] [--speech-check]

Measures native capture start latency with the real AudioCapture library.
Builds the capture probe in release, wraps it in a signed app bundle
(com.openvocally.capture-probe) and launches it through open, so the probe
is its own microphone (TCC) responsible process.

  --device  input device UID, or default (default: default)
  --runs    presses to measure (default: 20)
  --mode    cold closes the mic between presses; warm keeps it warm 15 s (default: cold)
  --idle    milliseconds between presses (default: 1500 cold, 1000 warm)
  --hold    milliseconds each press is held (default: 500)
  --press-lead  backdates each press by this many milliseconds, like a hotkey
                event timestamp taken before the call reaches the probe (default: 0)
  --check-idle  one press, then report whether the device still runs with the
                engine stopped and prepared (kAudioDevicePropertyDeviceIsRunningSomewhere)
  --device-change  runs the device-change cases instead (unplug during a
                recording, plug in while warm, plug in during a recording) and fails
                when one misbehaves
  --bluetooth   with --device-change, runs only case 4 --runs times (default 20), 3 s apart:
                a Bluetooth profile switch at the press on a connected headset such as
                AirPods; it plays a quiet sound for about 3 s per run
  --speech-check  runs case 4 --runs times (default 4) while a person talks into the
                headset, prints the peak level and kept milliseconds of each recording,
                and fails when a run's peak is below minimumPeak in
                scripts/latency/speech-check.json

Prints median, p95 (nearest rank), max and n per metric. Exits non-zero when a run
errored, p95 of press to engine running is 100 ms or more, or any first kept sample
lands more than 120 ms after the press, or any kept duration is more than 15 ms
shorter than the hold (press to release) once a cold start's wait for the
first sample is taken out; that wait is gated by the 120 ms rule.
EOF
}

device="default"
runs=20
mode="cold"
idle=""
hold=500
press_lead=0
check_idle=()
device_change=()
cases=(1 2 3)
bluetooth=0
speech_check=0
runs_given=0
while (($# > 0)); do
  case "$1" in
    --help | -h)
      usage
      exit 0
      ;;
    --check-idle)
      check_idle=(--check-idle)
      shift
      ;;
    --device-change)
      device_change=(--device-change)
      shift
      ;;
    --bluetooth)
      bluetooth=1
      shift
      ;;
    --speech-check)
      speech_check=1
      device_change=(--device-change)
      bluetooth=1
      shift
      ;;
    --device | --runs | --mode | --idle | --hold | --press-lead)
      (($# >= 2)) || {
        echo "Missing value for $1" >&2
        exit 64
      }
      case "$1" in
        --device) device="$2" ;;
        --runs)
          runs="$2"
          runs_given=1
          ;;
        --mode) mode="$2" ;;
        --idle) idle="$2" ;;
        --hold) hold="$2" ;;
        --press-lead) press_lead="$2" ;;
      esac
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done
[[ "$mode" == cold || "$mode" == warm ]] || {
  echo "--mode is cold or warm" >&2
  exit 64
}
if [[ -z "$idle" ]]; then
  if [[ "$mode" == warm ]]; then idle=1000; else idle=1500; fi
fi

package="$(cd "$(dirname "${BASH_SOURCE[0]}")/capture-probe" && pwd)"
app="$package/.build/CaptureProbe.app"
if ((speech_check && !runs_given)); then runs=4; fi
if ((bluetooth)); then
  cases=()
  for ((i = 0; i < runs; i++)); do cases+=(4); done
fi
label="$mode"
((${#device_change[@]} == 0)) || label=device-change
((!speech_check)) || label=speech-check
results="$package/.build/capture-$label-$(date +%Y%m%d-%H%M%S).jsonl"

"$package/../../whisper/build-xcframework.sh" >&2
swift build -c release --package-path "$package" >&2
binary="$(swift build -c release --package-path "$package" --show-bin-path)/capture-probe"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$binary" "$app/Contents/MacOS/CaptureProbe"
cat >"$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.openvocally.capture-probe</string>
  <key>CFBundleName</key><string>CaptureProbe</string>
  <key>CFBundleExecutable</key><string>CaptureProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>The capture probe measures how fast the microphone starts.</string>
</dict>
</plist>
EOF
entitlements="$package/.build/capture-probe.entitlements"
cat >"$entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict>
</plist>
EOF

source "$(dirname "${BASH_SOURCE[0]}")/../lib/signing-identity.sh"
identity="$(local_signing_identity)"
codesign --force --options runtime --entitlements "$entitlements" --sign "$identity" "$app" >&2

# A second probe would share the mic and corrupt both runs.
if ps -axo comm= | grep -E '(^|/)(CaptureProbe|CaptureSessionProbe)$' >/dev/null; then
  echo "Another capture probe is running and holds the mic. Wait for it to finish or quit it." >&2
  exit 1
fi

echo "Running $label on $device (results: $results)" >&2
# open -W returns 0 whatever the probe exits with, so the result rows decide.
if ((${#device_change[@]} > 0)); then
  # Cases 1 to 3 share one process. Bluetooth runs get one process each, so a crash costs
  # one row.
  if ((bluetooth)); then batches=("${cases[@]}"); else batches=("$(IFS=,; echo "${cases[*]}")"); fi
  run=0
  if ((speech_check)); then
    echo "Talk into the headset without stopping from now until the check ends. Starting in 3 s." >&2
    sleep 3
  fi
  for batch in "${batches[@]}"; do
    # Back-to-back Bluetooth runs 3 s apart catch the headset still switching profiles.
    ((run == 0 || !bluetooth)) || sleep 3
    run=$((run + 1))
    ((!speech_check)) || echo "Run $run of ${#batches[@]}, keep talking." >&2
    touch "$results.$run.started"
    open -W -n "$app" --args --device-change "$batch" --out "$results.$run"
    if [[ -s "$results.$run" ]]; then
      cat "$results.$run" >>"$results"
    else
      # ReportCrash writes the report a few seconds after the process dies.
      report=""
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        report="$(find "$HOME/Library/Logs/DiagnosticReports" -name 'CaptureProbe*.ips' -newer "$results.$run.started" 2>/dev/null | head -1)"
        [[ -z "$report" ]] || break
        sleep 1
      done
      echo '{"scenario":"'"$batch"' (no result: the probe crashed or was killed)","passed":false,"detail":"crash report: '"${report:-none}"'"}' >>"$results"
    fi
  done
else
  open -W -n "$app" --args --device "$device" --runs "$runs" --mode "$mode" --idle "$idle" --hold "$hold" --press-lead "$press_lead" --out "$results" ${check_idle[@]+"${check_idle[@]}"}
fi

[[ -s "$results" ]] || {
  echo "The probe wrote no results." >&2
  exit 1
}
cat "$results"
if ((speech_check)); then
  /usr/bin/python3 -I -c '
import json, sys
threshold = json.load(open(sys.argv[3]))
minimum = threshold["minimumPeak"]
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
failed = len(rows) != int(sys.argv[2])
for number, row in enumerate(rows, 1):
    peak, kept = row.get("peak"), row.get("keptMs")
    heard = peak is not None and peak >= minimum
    failed = failed or not heard
    shown = "none" if peak is None else f"{peak:.4f}"
    kept_shown = "none" if kept is None else f"{kept:.0f}"
    print(("PASS" if heard else "FAIL") + f" run {number}: peak {shown}, kept {kept_shown} ms")
    if not heard:
        print("  " + row.get("detail", row.get("error", "")))
print(sum(1 for r in rows if (r.get("peak") or 0) >= minimum), "of", sys.argv[2], "runs heard speech (peak at least", str(minimum) + ")")
sys.exit(1 if failed else 0)
' "$results" "${#cases[@]}" "$package/../speech-check.json"
  exit
fi
if ((${#device_change[@]} > 0)); then
  /usr/bin/python3 -I -c '
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
for row in rows:
    print(("PASS " if row.get("passed") else "FAIL ") + row.get("scenario", "?") + ": " + row.get("detail", row.get("error", "")))
print(sum(1 for r in rows if r.get("passed")), "of", sys.argv[2], "passed")
sys.exit(0 if len(rows) == int(sys.argv[2]) and all(r.get("passed") for r in rows) else 1)
' "$results" "${#cases[@]}"
  exit
fi
if ((${#check_idle[@]} > 0)); then
  /usr/bin/python3 -I -c '
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
ok = len(rows) == 1 and "error" not in rows[0] and rows[0].get("deviceRunningSomewhereAfterStop") is False
if not ok:
    print("FAIL: the device still runs after the stop, or the idle check errored")
sys.exit(0 if ok else 1)
' "$results"
  exit
fi

summary_status=0
/usr/bin/python3 -I - "$results" "$runs" <<'EOF' || summary_status=$?
import json, math, sys

rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
errors = [r for r in rows if "error" in r]
runs = [r for r in rows if "error" not in r]

def stats(values):
    values = sorted(values)
    p95 = values[max(0, math.ceil(0.95 * len(values)) - 1)]
    return values[len(values) // 2], p95, values[-1]

failed = bool(errors)
if len(runs) + len(errors) != int(sys.argv[2]):
    print(f"FAIL: {len(runs) + len(errors)} of {sys.argv[2]} runs reported; the probe stopped early")
    failed = True
for error in errors:
    print(f"run {error['run']} errored: {error['error']}")
engine = [r["pressToEngineRunningMs"] for r in runs]
first = [r["pressToFirstSampleMs"] for r in runs if r.get("pressToFirstSampleMs") is not None]
release = [r["releaseToStopReturnedMs"] for r in runs]
shortfall = [r["holdMs"] - r["keptMs"] for r in runs]
tail = [r["holdMs"] - (r.get("pressToFirstSampleMs") or 0) - r["keptMs"] for r in runs]
for name, values in (("press_to_engine_running_ms", engine), ("press_to_first_kept_sample_ms", first),
                     ("release_to_stop_returned_ms", release), ("hold_minus_kept_ms", shortfall),
                     ("hold_minus_first_sample_minus_kept_ms", tail)):
    if values:
        median, p95, worst = stats(values)
        print(f"{name}: median {median:.1f} p95 {p95:.1f} max {worst:.1f} n {len(values)}")
    else:
        print(f"{name}: no data")
        failed = True
print(f"warm runs: {sum(1 for r in runs if r['wasWarm'])} of {len(runs)}")
if len(first) != len(runs):
    print("a run kept no samples")
    failed = True
if engine and stats(engine)[1] >= 100:
    print("FAIL: p95 press to engine running is 100 ms or more")
    failed = True
if first and max(first) > 120:
    print("FAIL: a first kept sample is later than 120 ms after the press")
    failed = True
if tail and max(tail) > 15:
    print("FAIL: a kept duration is more than 15 ms shorter than the hold")
    failed = True
sys.exit(1 if failed else 0)
EOF
exit "$summary_status"
