#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'HELP'
Usage: scripts/release/build-dmg.sh <app-path> <output-dmg>

Builds the drag-to-install disk image for an app: the app on the left, an Applications link on
the right, over the background in scripts/release/dmg-background.tiff, with the app's AppIcon.icns
as the volume icon. The volume is named OpenVocally, the image is APFS with LZFSE compression
(ULFO), and an existing output file is replaced. It does not sign the image: scripts/release.sh
signs, notarizes and staples it.

The layout comes from dmgbuild, which writes the Finder window settings into the image's
.DS_Store directly, with no Finder or AppleScript, so every build looks the same. The first run
installs dmgbuild, at the versions and hashes in scripts/release/dmgbuild-requirements.txt, into
a private venv under .build/dmgbuild-venv. Nothing is installed globally.

Layout settings: scripts/release/dmg-settings.py
Background source: scripts/release/dmg-background.swift (rerun it, then commit the TIFF)
HELP
  exit 0
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RELEASE_DIR="$PROJECT_ROOT/scripts/release"
REQUIREMENTS="$RELEASE_DIR/dmgbuild-requirements.txt"
VENV="$PROJECT_ROOT/.build/dmgbuild-venv"

log() {
  echo "[build-dmg] $*"
}

fail() {
  echo "[build-dmg] Error: $*" >&2
  exit 1
}

(($# == 2)) || fail "Expected an app and an output path. Run scripts/release/build-dmg.sh --help."
app="${1%/}"
dmg="$2"
[[ -d "$app" && "$app" == *.app ]] || fail "$app is not an app bundle."
icon="$app/Contents/Resources/AppIcon.icns"
[[ -f "$icon" ]] || fail "$app has no Contents/Resources/AppIcon.icns for the volume icon."
[[ -d "$(dirname "$dmg")" ]] || fail "The output folder $(dirname "$dmg") does not exist."
for tool in python3 hdiutil; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is missing. See CONTRIBUTING.md for the build tools."
done
# dmgbuild sets the volume icon and hides the .app extension with SetFile, and ignores its failure.
[[ -x /usr/bin/SetFile ]] || fail "/usr/bin/SetFile is missing. Install the Xcode Command Line Tools: xcode-select --install"

# The venv keeps a copy of the requirements it was built from, so a version bump rebuilds it.
if ! cmp -s "$REQUIREMENTS" "$VENV/requirements.txt" || [[ ! -x "$VENV/bin/dmgbuild" ]]; then
  log "Installing dmgbuild into $VENV..."
  rm -rf "$VENV"
  python3 -m venv "$VENV" || fail "python3 could not create a venv at $VENV."
  "$VENV/bin/python" -m pip install --quiet --disable-pip-version-check --require-hashes --only-binary :all: \
    -r "$REQUIREMENTS" || fail "pip could not install dmgbuild. Check the network and $REQUIREMENTS."
  cp "$REQUIREMENTS" "$VENV/requirements.txt"
fi

rm -f "$dmg"
log "Building $(basename "$dmg")..."
"$VENV/bin/dmgbuild" -s "$RELEASE_DIR/dmg-settings.py" -D app="$app" -D icon="$icon" \
  -D background="$RELEASE_DIR/dmg-background.tiff" OpenVocally "$dmg" ||
  fail "dmgbuild could not build $dmg. Its output above names the failing step."
[[ -f "$dmg" ]] || fail "dmgbuild exited without writing $dmg."
