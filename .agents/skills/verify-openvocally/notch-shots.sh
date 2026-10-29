#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'HELP'
Usage: .agents/skills/verify-openvocally/notch-shots.sh [variant ...]

Captures the real dictation notch panel on every connected display for every scene, and
stitches each display and variant into one labelled contact sheet.

Holds the Debug app lock, builds the Debug app, and opens it in the background
once per variant with -notchProbe. For each display it aims the probe pointer at the display's
top centre, walks the scenes (hidden, connecting, starting, recording, stopping, transcribing,
pasting, complete, manual-paste and one failed-<reason> per failure) and captures only the
notch panel's window with screencapture -l, so nothing else on screen is captured. Posts no
clicks or keys, never takes focus and never moves the cursor.

Variants default to: default, light (-notchAppearance aqua), dark (darkAqua),
increase-contrast-light (highContrastAqua), increase-contrast-dark (highContrastDarkAqua) and
reduce-motion (-notchReduceMotion YES). no-menu-bar (-notchSeparateSpaces NO) gives only the
primary display a menu bar, so every display but the primary must show nothing. Join names
with + to combine them, such as dark+no-menu-bar.

After each scene it checks which displays' panels actually draw a scene, and fails when more
than one does, or when the drawn display is not the one the notch reports showing on.

Writes .build/notch-shots/<display>-<variant>/<scene>.png and the contact sheet
.build/notch-shots/<display>-<variant>.png, and prints each sheet path. Needs Screen Recording
for the terminal. Quits only the Debug app it opened.
HELP
  exit 0
fi

cd "$(dirname "$0")/../../.."
if [[ "${DEBUG_APP_LOCK_HELD:-}" != 1 ]]; then
  exec scripts/with-debug-app.sh .agents/skills/verify-openvocally/notch-shots.sh "$@"
fi

variants=("$@")
((${#variants[@]})) || variants=(default light dark increase-contrast-light increase-contrast-dark reduce-motion)
scenes=(hidden connecting starting recording stopping transcribing pasting complete manual-paste
  failed-microphonePermissionDenied failed-noInputDevice failed-startTimedOut failed-stopTimedOut
  failed-deviceLost failed-captureFailed failed-transcriptionError failed-noSpeech
  failed-modelNotInstalled failed-pasteNotSupported failed-pastePermissionDenied
  failed-pasteRuntimeError failed-nothingToPaste failed-manualPasteExpired)

app="$PWD/.build/DerivedData/Build/Products/Debug/OpenVocally Dev.app"
executable="$app/Contents/MacOS/OpenVocally"
out="$PWD/.build/notch-shots"
mkdir -p "$out"
swiftc -O scripts/lib/screens.swift -o "$PWD/.build/screens"
swiftc -O scripts/lib/contact-sheet.swift -o "$PWD/.build/contact-sheet"
scripts/build-debug.sh >/dev/null

probe="$out/probe.txt"
log="$out/log.txt"
streamer=""

running() {
  ps -axo pid=,comm= | awk -v exe="$executable" '{ pid = $1; sub(/^[ \t]*[0-9]+[ \t]+/, ""); if ($0 == exe) print pid }'
}

quit_app() {
  for pid in $(running); do
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.25
    done
  done
}

finish() {
  quit_app
  [[ -z "$streamer" ]] || kill "$streamer" 2>/dev/null || true
  [[ -z "$streamer" ]] || wait "$streamer" 2>/dev/null || true
}
trap finish EXIT

variant_args() {
  local name
  local -a names
  IFS=+ read -r -a names <<<"$1"
  for name in "${names[@]}"; do
    single_variant_args "$name"
  done
}

single_variant_args() {
  case "$1" in
    default) ;;
    light) echo -notchAppearance aqua ;;
    dark) echo -notchAppearance darkAqua ;;
    increase-contrast-light) echo -notchAppearance highContrastAqua ;;
    increase-contrast-dark) echo -notchAppearance highContrastDarkAqua ;;
    reduce-motion) echo -notchReduceMotion YES ;;
    no-menu-bar) echo -notchSeparateSpaces NO ;;
    *)
      echo "notch-shots: unknown variant $1" >&2
      exit 2
      ;;
  esac
}

# Waits for a log line containing $1 that arrived after line $2 of the log, and prints it.
wait_for() {
  for _ in $(seq 1 60); do
    line="$(tail -n +"$(($2 + 1))" "$log" | grep -F -- "$1" | tail -n 1 || true)"
    if [[ -n "$line" ]]; then
      echo "$line"
      return 0
    fi
    sleep 0.25
  done
  return 1
}

sheets=()
for variant in "${variants[@]}"; do
  args="$(variant_args "$variant" | tr '\n' ' ')"
  read -r -a extra <<<"$args"
  quit_app
  : >"$log"
  [[ -z "$streamer" ]] || kill "$streamer" 2>/dev/null || true
  [[ -z "$streamer" ]] || wait "$streamer" 2>/dev/null || true
  /usr/bin/log stream --level info --style compact \
    --predicate 'subsystem == "com.openvocally.app" AND category == "overlay-demo"' >"$log" &
  streamer=$!
  sleep 1
  read -r _ x y w h _ < <("$PWD/.build/screens" | head -n 1)
  echo "$((x + w / 2)) $((y + h - 1)) none" >"$probe"
  open -g "$app" --args -notchProbe "$probe" -ApplePersistenceIgnoreState YES ${extra[@]+"${extra[@]}"}
  if ! wait_for "notch probe ready" 0 >/dev/null; then
    echo "notch-shots: the Debug app never logged notch probe ready for $variant" >&2
    exit 1
  fi
  while read -r display x y w h _ _ _ _ notch; do
    name="display$display"
    ((notch)) && name="$name-notch"
    folder="$out/$name-$variant"
    rm -rf "$folder"
    mkdir -p "$folder"
    rows=()
    for scene in "${scenes[@]}"; do
      seen="$(wc -l <"$log")"
      echo "$((x + w / 2)) $((y + h - 1)) $scene" >"$probe"
      if ! line="$(wait_for "notch probe shown $scene display" "$seen")"; then
        echo "notch-shots: no notch probe shown line for $scene on $name ($variant)" >&2
        rows+=("$scene=")
        continue
      fi
      window="${line##* window }"
      drawn="${line##* drawn }"
      drawn="${drawn%% *}"
      shown_on="${line##* display }"
      shown_on="${shown_on%% *}"
      if [[ "$drawn" == *,* ]]; then
        echo "notch-shots: $scene on $name ($variant) drew on more than one display: $drawn" >&2
        exit 1
      fi
      if [[ "$drawn" != "$shown_on" ]]; then
        echo "notch-shots: $scene on $name ($variant) drew on $drawn but reports display $shown_on" >&2
        exit 1
      fi
      if [[ "$window" == none ]]; then
        rows+=("$scene (nothing shown)=")
        continue
      fi
      screencapture -o -x -l "$window" "$folder/$scene.png"
      rows+=("$scene=$folder/$scene.png")
    done
    sheet="$out/$name-$variant.png"
    "$PWD/.build/contact-sheet" "$sheet" "$name, $variant" "${rows[@]}"
    sheets+=("$sheet")
  done < <("$PWD/.build/screens")
done
printf '%s\n' "${sheets[@]}"
