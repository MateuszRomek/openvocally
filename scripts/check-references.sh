#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: scripts/check-references.sh

Fails when code, scripts, build files or docs cite a private tracker: a decision ID (D-12),
an issue number (#85) or "the owner". Comments must stand on their own.
EOF
  exit 0
fi

cd "$(dirname "$0")/.."
pattern='(^|[^A-Za-z0-9_-])D-[0-9]{1,3}([^0-9]|$)|(^|[^A-Za-z0-9_&$#{])#[0-9]{1,4}([^0-9A-Za-z]|$)|[Tt]he owner'
hits="$(git ls-files --cached --others --exclude-standard -- App OpenVocallyKit scripts Makefile project.yml .github docs README.md AGENTS.md CONTRIBUTING.md SECURITY.md |
  grep -vE '\.(wav|png|jpg|svg|mp3|json|resolved)$|^scripts/check-references\.sh$' |
  while IFS= read -r file; do [[ -f "$file" ]] && printf '%s\n' "$file"; done |
  xargs grep -nE "$pattern" || true)"
if [[ -n "$hits" ]]; then
  printf '%s\n' "$hits" >&2
  echo "$(printf '%s\n' "$hits" | wc -l | tr -d ' ') references to private trackers. State the reason in the comment itself." >&2
  exit 1
fi
