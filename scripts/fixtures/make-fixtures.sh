#!/bin/bash
# Regenerates fixtures/*.wav from fixtures.tsv with macOS speech synthesis.
# The committed WAVs are the source of truth. Voices change between macOS
# releases, so rerun this only when adding or editing a fixture.
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: scripts/fixtures/make-fixtures.sh

Regenerates fixtures/*.wav from fixtures.tsv with macOS speech synthesis and ffmpeg. The
committed WAVs are the source of truth and voices change between macOS releases, so run
this only when adding or editing a fixture, then rerun record-baseline.sh.
EOF
  exit 0
fi

here="$(cd "$(dirname "$0")" && pwd)"
out="$here/fixtures"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

encode=(-ar 16000 -ac 1 -c:a pcm_s16le -map_metadata -1 -fflags +bitexact -flags:a +bitexact)

tail -n +2 "$here/fixtures.tsv" | while IFS=$'\t' read -r id voice noise text; do
  if [ "$id" = "silence" ]; then
    ffmpeg -nostdin -v error -y -f lavfi -i anullsrc=r=16000:cl=mono -t 3 "${encode[@]}" "$out/$id.wav"
    continue
  fi

  say -v "$voice" -o "$work/$id.aiff" "$text"
  case "$noise" in
    none)
      ffmpeg -nostdin -v error -y -i "$work/$id.aiff" "${encode[@]}" "$out/$id.wav"
      ;;
    pink)
      ffmpeg -nostdin -v error -y -i "$work/$id.aiff" \
        -f lavfi -i anoisesrc=color=pink:seed=42:amplitude=0.08:sample_rate=16000 \
        -filter_complex "[0:a]aresample=16000[s];[s][1:a]amix=inputs=2:duration=first:normalize=0" \
        "${encode[@]}" "$out/$id.wav"
      ;;
    *)
      echo "Unknown noise '$noise' for fixture $id" >&2
      exit 1
      ;;
  esac
done

for f in "$out"/*.wav; do
  printf '%s %ss\n' "$(basename "$f")" "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f")"
done
