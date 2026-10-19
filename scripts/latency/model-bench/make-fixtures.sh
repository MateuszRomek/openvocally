#!/bin/bash
# Synthesizes fixtures/*.wav from fixtures/fixtures.tsv with `say` (16 kHz mono PCM16).
# Usage: scripts/latency/model-bench/make-fixtures.sh [--help]
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: scripts/latency/model-bench/make-fixtures.sh

Regenerates the bench's own fixtures from fixtures/fixtures.tsv with macOS speech
synthesis, encoded as 16 kHz mono PCM16 WAV. after_s appends that many seconds of digital
silence. The voice `noise` makes 3 s of seeded pink noise with no speech. The committed WAVs
are the source of truth; voices change between macOS releases.
EOF
  exit 0
fi

here="$(cd "$(dirname "$0")" && pwd)"
out="$here/fixtures"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
encode=(-ar 16000 -ac 1 -c:a pcm_s16le -map_metadata -1 -fflags +bitexact -flags:a +bitexact)

tail -n +2 "$out/fixtures.tsv" | while IFS=$'\t' read -r id voice after text; do
  if [[ "$voice" == noise ]]; then
    ffmpeg -nostdin -v error -y -f lavfi -i "anoisesrc=color=pink:amplitude=0.05:seed=1:duration=3" \
      "${encode[@]}" "$out/$id.wav"
  else
    say -v "$voice" -o "$work/$id.aiff" "$text"
    ffmpeg -nostdin -v error -y -i "$work/$id.aiff" -af "apad=pad_dur=$after" "${encode[@]}" "$out/$id.wav"
  fi
  printf '%s %ss\n' "$id.wav" "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out/$id.wav")"
done
