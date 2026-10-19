#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  cat <<'USAGE'
Usage: scripts/latency/check-dictation-latency.sh

Runs dictation-latency.sh --from on the sample fixture and fails when its output differs
from fixtures/dictation-latency-sample.expected.
USAGE
  exit 0
fi

cd "$(dirname "$0")"
if ! diff -u fixtures/dictation-latency-sample.expected \
  <(./dictation-latency.sh --from fixtures/dictation-latency-sample.ndjson --runs 2); then
  echo "dictation-latency.sh output changed for the sample fixture." >&2
  exit 1
fi
