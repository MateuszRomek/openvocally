#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'HELP'
Usage: scripts/build-debug.sh [xcodebuild arguments...]

Builds the Debug app into .build/DerivedData, signed with the "OpenVocally Local Signing"
identity when the keychain has it, else ad hoc. Expects a generated project (make generate).
make build and scripts/run-debug.sh both build through it, so every build of the bundle keeps
the signature its Accessibility grant names.

A Debug app that is running keeps the grant only while the bundle on disk satisfies it. One
ad hoc build under it is enough to lose it, and an active event tap without the grant
blocks every key and click on the Mac. Xcode signs the bundle once, at the end of the build,
so the bundle is never ad hoc in between.
HELP
  exit 0
fi

cd "$(dirname "$0")/.."
source scripts/lib/signing-identity.sh
identity="$(local_signing_identity)"
signing=()
if [[ "$identity" != - ]]; then
  # The self-signed identity has no Team ID, so library validation would reject Sparkle.framework.
  signing=(APP_SIGN_IDENTITY="$identity" APP_ENTITLEMENTS=App/Resources/OpenVocally.local.entitlements
    OTHER_CODE_SIGN_FLAGS=--timestamp=none)
else
  echo "warning: \"$LOCAL_IDENTITY_NAME\" is not in the keychain; the app stays ad-hoc signed and may lose its permissions on every build." >&2
fi

# A separate debug dylib signed by a certificate with no Team ID fails library validation.
xcodebuild -project OpenVocally.xcodeproj -scheme OpenVocally -configuration Debug \
  -derivedDataPath .build/DerivedData ENABLE_DEBUG_DYLIB=NO ${signing[@]+"${signing[@]}"} build "$@"
