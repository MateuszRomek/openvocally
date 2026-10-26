#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF_HELP'
Usage: scripts/check-unshipped-features.sh

Builds the OpenVocallyKit Agents product in Release and fails when Agents code reached it: when
the Agents or AgentsCore object defines a symbol other than Swift's reflection version, or when
the Storage object holds an agent_ table name. Agents compiles only in Debug, behind
FEATURE_AGENTS, so a file left outside its #if, or a target without the featureAgents setting
in Package.swift, fails here. Uses the package's own .build folder and launches no app.
EOF_HELP
  exit 0
fi

cd "$(dirname "$0")/.."
resolved=OpenVocallyKit/Package.resolved
saved="$(mktemp)"
cp "$resolved" "$saved"
# A standalone package build rewrites Package.resolved without the app's Sparkle pin.
trap 'cp "$saved" "$resolved"; rm -f "$saved"' EXIT
swift build --package-path OpenVocallyKit -c release --product Agents >/dev/null
bin="$(swift build --package-path OpenVocallyKit -c release --show-bin-path)"

failed=0
for module in Agents AgentsCore; do
  symbols="$(nm -U "$bin/$module.o" | grep -v ' ___swift_reflection_version$' || true)"
  if [[ -n "$symbols" ]]; then
    echo "check-unshipped-features: the Release $module module defines symbols. Wrap the file in #if FEATURE_AGENTS:" >&2
    printf '%s\n' "$symbols" | head -n 5 >&2
    failed=1
  fi
done
if strings -a "$bin/Storage.o" | grep -q 'agent_'; then
  echo "check-unshipped-features: the Release Storage module names an agent_ table. Wrap the file in #if FEATURE_AGENTS." >&2
  failed=1
fi
exit "$failed"
