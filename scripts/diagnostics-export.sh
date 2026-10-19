#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'HELP'
Usage: scripts/diagnostics-export.sh

Holds the Debug app lock, builds and opens the Debug app in the background with
-diagnosticsExport, and waits for it to write the diagnostics file and quit. Before the
export the app logs a random secret with default privacy, the way a careless line would
carry a transcript. Fails when the file holds that secret, lacks the redacted line that
carried it, or holds this Mac's user name, full name or an audio device name. Prints the
log scope line, the summary and the build time. The file stays in .build/diagnostics-export.
HELP
  exit 0
fi

cd "$(dirname "$0")/.."
if [[ "${DEBUG_APP_LOCK_HELD:-}" != 1 ]]; then
  exec scripts/with-debug-app.sh scripts/diagnostics-export.sh "$@"
fi

out_dir="$PWD/.build/diagnostics-export"
out="$out_dir/diagnostics.txt"
mkdir -p "$out_dir"
rm -f "$out"
secret="leak-probe-$(uuidgen)"
started=$(date '+%Y-%m-%d %H:%M:%S')

RUN_DEBUG_BACKGROUND=1 scripts/run-debug.sh -diagnosticsExport "$out" -diagnosticsSecret "$secret"

for _ in $(seq 1 240); do
  [[ -s "$out" ]] && break
  sleep 0.5
done
[[ -s "$out" ]] || { echo "No diagnostics file after 120 s" >&2; exit 1; }

status=0
if grep -qF "$secret" "$out"; then
  echo "FAIL: the planted secret is in the file" >&2
  status=1
fi
if ! grep -qF "Planted secret: <private>" "$out"; then
  echo "FAIL: the redacted line that carried the secret is missing, so the check proves nothing" >&2
  status=1
fi
for name in "$(id -un)" "$(id -F)"; do
  if [[ ${#name} -ge 3 ]] &&
    NAME="$name" perl -CSD -ne 'BEGIN { $n = $ENV{NAME} } $f = 1 if /(?<![\p{L}\p{N}_.])\Q$n\E(?![\p{L}\p{N}_])/i; END { exit !$f }' "$out"; then
    echo "FAIL: the file contains the user name or full name ($(wc -c <<<"$name" | tr -d ' ') chars)" >&2
    status=1
  fi
done
while IFS= read -r name; do
  if [[ ${#name} -ge 3 ]] && grep -qiF "$name" "$out"; then
    echo "FAIL: the file contains an audio device name ($(wc -c <<<"$name" | tr -d ' ') chars)" >&2
    status=1
  fi
done < <(system_profiler SPAudioDataType 2>/dev/null | sed -nE 's/^ {8}([^ ].*):$/\1/p' | sort -u)

grep -E '^Logs: ' "$out"
/usr/bin/log show --start "$started" --style compact \
  --predicate 'subsystem == "com.openvocally.app" AND category == "diagnostics-harness"' |
  grep -oE 'Diagnostics export (written|failed).*' || true
echo "File: $out"
[[ $status -eq 0 ]] && echo "PASS"
exit $status
