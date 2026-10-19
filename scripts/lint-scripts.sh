#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: scripts/lint-scripts.sh

Checks every tracked or new shell script: bash -n must parse it, and a script under
scripts/ must be executable and have a --help branch. Runs each --help with build, signing,
process and capture tools replaced by stubs, and fails when it exits non-zero, prints
nothing (under scripts/) or calls one of those tools.
EOF
  exit 0
fi

cd "$(dirname "$0")/.."
status=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/home" "$work/cwd"
for cmd in make xcodebuild xcodegen swift codesign security sudo tccutil ditto open kill pkill osascript openssl git swiftc screencapture xcrun ffmpeg say curl cmake; do
  printf '#!/bin/sh\necho "%s $*" >>"%s/called"\n' "$cmd" "$work" >"$work/bin/$cmd"
  chmod +x "$work/bin/$cmd"
done

while IFS= read -r script; do
  bash -n "$script" || status=1
  if [[ "$script" == scripts/* && ! -x "$script" ]]; then
    echo "$script is not executable. Run chmod +x on it." >&2
    status=1
  fi
  if ! grep -q -- '--help' "$script"; then
    if [[ "$script" == scripts/* ]]; then
      echo "$script has no --help branch. Add one that prints its usage and exits 0." >&2
      status=1
    fi
    continue
  fi
  rm -f "$work/called"
  if ! (cd "$work/cwd" && HOME="$work/home" PATH="$work/bin:$PATH" bash "$OLDPWD/$script" --help >"$work/help" 2>&1); then
    echo "$script --help exited non-zero." >&2
    status=1
  elif [[ "$script" == scripts/* && ! -s "$work/help" ]]; then
    echo "$script --help printed nothing." >&2
    status=1
  fi
  if [[ -s "$work/called" ]]; then
    echo "$script --help ran commands it should only describe:" >&2
    sed 's/^/  /' "$work/called" >&2
    status=1
  fi
done < <(git ls-files --cached --others --exclude-standard -- '*.sh')

if ((status != 0)); then
  echo "Shell script lint failed. Scripts under scripts/ must be executable and answer --help. A --help path must only print text: quote heredocs (<<'EOF') and never put backticks or \$( ) in help text." >&2
fi
exit "$status"
