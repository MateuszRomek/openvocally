#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: .agents/skills/verify-openvocally/doctor.sh

Read-only. Reports whether the Debug app is worth driving: the built app and its version,
whether the build is older than the sources, running Debug copies, the Debug app lock holder,
the signing identity, the installed speech models and Screen Recording for screenshots.
Exits 1 when the app is not built or another script holds the lock.
EOF
  exit 0
fi

cd "$(dirname "$0")/../../.."
status=0
app=".build/DerivedData/Build/Products/Debug/OpenVocally.app"
support="$HOME/Library/Application Support/com.openvocally.app.debug"

if [[ -d "$app" ]]; then
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || echo '?')"
  echo "build: $app (version $version)"
  newer="$(find App OpenVocallyKit/Sources project.yml -newer "$app/Contents/MacOS/OpenVocally" -type f 2>/dev/null | head -3)"
  if [[ -n "$newer" ]]; then
    echo "build: stale, sources changed since the build, for example:"
    printf '  %s\n' $newer
  else
    echo "build: current"
  fi
else
  echo "build: missing. Any launch script builds it, or run make build."
  status=1
fi

running="$(ps -axo pid=,comm= | awk '/\.build\/DerivedData(-perf)?\/Build\/Products\/Debug\/OpenVocally\.app\/Contents\/MacOS\/OpenVocally$/ { print }')"
if [[ -n "$running" ]]; then
  echo "running Debug copies:"
  printf '%s\n' "$running" | sed 's/^/  /'
else
  echo "running Debug copies: none"
fi

lock=".build/debug-app.lock"
if [[ -d "$lock" ]]; then
  holder="$(cat "$lock/pid" 2>/dev/null || echo '?')"
  if kill -0 "$holder" 2>/dev/null; then
    echo "lock: held by pid $holder ($(ps -o command= -p "$holder" | cut -c1-100))"
    status=1
  else
    echo "lock: stale (pid $holder is gone); the next script takes it over"
  fi
else
  echo "lock: free"
fi

echo "signing: $(scripts/lib/signing-identity.sh)"

models="$support/local-models"
if [[ -d "$models" ]]; then
  echo "models in $models:"
  find "$models" -mindepth 2 -maxdepth 2 ! -name '.*' | sed "s|^$models/|  |"
else
  echo "models: none installed; the dictation harness needs one (open the app and pick one in Models)"
fi

if python3 -I -c 'import ctypes, sys; q = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics").CGPreflightScreenCaptureAccess; q.restype = ctypes.c_bool; sys.exit(0 if q() else 1)'; then
  echo "screen recording: granted to this terminal"
else
  echo "screen recording: not granted; screenshot scripts capture blank windows"
fi
exit "$status"
