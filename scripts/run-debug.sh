#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/run-debug.sh [app arguments...]

Builds the Debug app, quits a running copy of that exact build, re-signs it with the "OpenVocally Local Signing" identity and opens it. A stable signature keeps the
Accessibility and Microphone grants across rebuilds. Without the identity the app
stays ad-hoc signed, and macOS may ask for both grants again after each build.
Create the identity with scripts/setup-signing.sh.

RUN_DEBUG_BACKGROUND=1 opens the app without bringing it to the front.

Arguments are passed to the app, for example
  scripts/run-debug.sh -overlayDemo YES -overlayPlacement islandTop
EOF
}

case "${1:-}" in
  --help | -h)
    usage
    exit 0
    ;;
esac

cd "$(dirname "$0")/.."
source scripts/lib/signing-identity.sh
identity="$(local_signing_identity)"
app="$PWD/.build/DerivedData/Build/Products/Debug/OpenVocally.app"
executable="$app/Contents/MacOS/OpenVocally"

scripts/whisper/build-xcframework.sh
xcodegen generate --quiet
# A separate debug dylib signed by a certificate with no Team ID fails library validation.
xcodebuild -project OpenVocally.xcodeproj -scheme OpenVocally -configuration Debug \
  -derivedDataPath .build/DerivedData ENABLE_DEBUG_DYLIB=NO build -quiet

for pid in $(ps -axo pid=,comm= | awk -v exe="$executable" '{ pid = $1; sub(/^[ \t]*[0-9]+[ \t]+/, ""); if ($0 == exe) print pid }'); do
  kill "$pid"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.3
  done
done

if [[ "$identity" != - ]]; then
  # The self-signed identity has no Team ID, so library validation would reject Sparkle.framework.
  codesign --force --sign "$identity" --timestamp=none --options runtime \
    --entitlements App/Resources/OpenVocally.local.entitlements "$app"
else
  echo "warning: \"$LOCAL_IDENTITY_NAME\" is not in the keychain; the app stays ad-hoc signed and may lose its permissions on every build." >&2
fi

open ${RUN_DEBUG_BACKGROUND:+-g} "$app" --args "$@"
