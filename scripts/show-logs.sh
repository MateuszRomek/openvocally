#!/bin/sh
set -eu
if [ "${1:-}" = "--help" ]; then
  cat <<'EOF'
Usage: scripts/show-logs.sh <category> [duration]

Prints the app's unified log for one Logger category (subsystem com.openvocally.app) over
the last duration, default 1h, for example 10m or 2h. Runs /usr/bin/log, because in zsh a
bare "log" is a shell builtin.
EOF
  exit 0
fi
if [ $# -lt 1 ]; then
  echo "Usage: scripts/show-logs.sh <category> [duration, default 1h]" >&2
  exit 2
fi
exec /usr/bin/log show --last "${2:-1h}" --info --style compact \
  --predicate "subsystem == \"com.openvocally.app\" AND category == \"$1\""
