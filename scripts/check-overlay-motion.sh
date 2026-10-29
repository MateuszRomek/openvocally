#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'HELP'
Usage: scripts/check-overlay-motion.sh [path ...]

Fails when overlay code animates with withAnimation or withTransaction. The notch animates by
structure instead: .animation(_:value:) keyed on the footprint for the shape, and on the content
for a swap (docs/design.md, The overlay). Scans OpenVocallyKit/Sources/Overlay by default.
HELP
  exit 0
fi

cd "$(dirname "$0")/.."

pattern='(^|[^A-Za-z0-9_])with(Animation|Transaction)([^A-Za-z0-9_]|$)'
planted='    withAnimation(animation) { model.scene = scene }'
message='animate with .animation(_:value:) keyed on the footprint or content; see docs/design.md'

if ! printf '%s\n' "$planted" | grep -qE "$pattern"; then
  echo "check-overlay-motion: the rule no longer catches: $planted" >&2
  exit 1
fi

roots=("$@")
((${#roots[@]})) || roots=(OpenVocallyKit/Sources/Overlay)

status=0
while IFS= read -r file; do
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    echo "$file:$hit: $message" >&2
    status=1
  done < <(grep -nE "$pattern" "$file" || true)
done < <(find "${roots[@]}" -name '*.swift' | sort)
exit "$status"
