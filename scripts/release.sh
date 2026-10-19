#!/usr/bin/env bash
# The release flow follows VoiceInk's scripts/release.sh (github.com/Beingpax/VoiceInk, GPL-3.0).

set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'EOF'
Usage: scripts/release.sh [release-notes-file]

Builds, signs with Developer ID, notarizes and staples OpenVocally, adds the update to
appcast.xml, builds a signed and notarized OpenVocally.dmg for the website, and after a y/N
prompt creates the GitHub release with the zip (for updates) and the DMG (for downloads). It never commits or pushes:
commit and push appcast.xml afterwards, because installed apps read the feed from main.

The version and build come from MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml.
Raise both before each release: MARKETING_VERSION is the version users see, and Sparkle
compares CURRENT_PROJECT_VERSION, so it must be higher than the last release's.
The optional notes file (.md, .html or .txt) goes into the appcast item and the release.

One-time setup:
  Sparkle key   <Sparkle bin>/generate_keys, then back it up with generate_keys -x <file>
  Notary        xcrun notarytool store-credentials openvocally

Environment variables:
  SIGN_IDENTITY        signing identity (default: the one "Developer ID Application" identity)
  NOTARY_PROFILE       notarytool keychain profile (default openvocally)
  SPARKLE_KEY_FILE     EdDSA private key file instead of the keychain key
  FEED_URL             feed URL baked into the app (default: appcast.xml on main)
  DOWNLOAD_URL_PREFIX  appcast download prefix (default: the GitHub release of this tag)
  APPCAST              appcast to update (default: appcast.xml in the repo)
  BUNDLE_ID            bundle ID (default com.openvocally.app)
  VERSION, BUILD       override the version and build from project.yml
  OUT_DIR              build output folder (default .build/release/<version>)
  SKIP_NOTARIZE=1      skip notarization, stapling and the Gatekeeper checks of the app
                       and the DMG; the DMG is still built and signed. Needs NO_PUBLISH=1
  NO_PUBLISH=1         stop before the GitHub release and skip the tag check
  ALLOW_DIRTY=1        allow uncommitted changes
EOF
  exit 0
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="MateuszRomek/openvocally"
ENTITLEMENTS="$PROJECT_ROOT/App/Resources/OpenVocally.entitlements"
EXPECTED_ENTITLEMENTS="com.apple.security.device.audio-input"

log() {
  echo "[release] $*"
}

fail() {
  echo "[release] Error: $*" >&2
  exit 1
}

if [[ "${SKIP_NOTARIZE:-0}" == 1 && "${NO_PUBLISH:-0}" != 1 ]]; then
  fail "SKIP_NOTARIZE=1 needs NO_PUBLISH=1, because a build that skipped notarization must not be published."
fi

notes_file="${1:-}"
if [[ -n "$notes_file" ]]; then
  [[ -f "$notes_file" ]] || fail "Release notes file not found: $notes_file"
  notes_file="$(cd "$(dirname "$notes_file")" && pwd)/$(basename "$notes_file")"
  case "$notes_file" in
    *.md | *.html | *.txt) ;;
    *) fail "Release notes must be .md, .html or .txt, because Sparkle picks them up by extension." ;;
  esac
fi

[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] || fail "Release builds need an Apple Silicon Mac."
for tool in xcodegen xcodebuild codesign ditto hdiutil python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is missing. See CONTRIBUTING.md for the build tools."
done

cd "$PROJECT_ROOT"

if [[ "${ALLOW_DIRTY:-0}" != 1 && -n "$(git status --porcelain)" ]]; then
  fail "The working tree has uncommitted changes. Commit or stash them, so the release matches a commit."
fi

project_setting() {
  sed -n "s/^ *$1: *\"\{0,1\}\([^\"]*\)\"\{0,1\} *$/\1/p" project.yml | head -n 1
}
version="${VERSION:-$(project_setting MARKETING_VERSION)}"
build="${BUILD:-$(project_setting CURRENT_PROJECT_VERSION)}"
[[ -n "$version" ]] || fail "No MARKETING_VERSION in project.yml."
[[ "$build" =~ ^[0-9]+$ ]] || fail "CURRENT_PROJECT_VERSION in project.yml must be a whole number, got '$build'."
tag="v$version"

appcast="${APPCAST:-$PROJECT_ROOT/appcast.xml}"
if [[ -f "$appcast" ]]; then
  highest="$(python3 -I - "$appcast" <<'PY'
import sys, xml.etree.ElementTree as ET
ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
builds = [int(e.text) for e in ET.parse(sys.argv[1]).iter(ns + "version") if e.text and e.text.strip().isdigit()]
for e in ET.parse(sys.argv[1]).iter("enclosure"):
    v = e.get(ns + "version")
    if v and v.isdigit():
        builds.append(int(v))
print(max(builds, default=0))
PY
)" || fail "Could not read $appcast. Fix the XML or restore it from git."
  ((build > highest)) ||
    fail "Build $build is not above build $highest in $(basename "$appcast"). Raise CURRENT_PROJECT_VERSION in project.yml."
fi

if [[ "${NO_PUBLISH:-0}" != 1 ]]; then
  command -v gh >/dev/null 2>&1 || fail "gh is missing. Install it: brew install gh"
  if git ls-remote --exit-code --tags "https://github.com/$REPO.git" "refs/tags/$tag" >/dev/null 2>&1; then
    fail "Tag $tag already exists on GitHub. Raise MARKETING_VERSION in project.yml."
  fi
  # The release tag points at HEAD, so HEAD must already be on main on GitHub.
  head_sha="$(git rev-parse HEAD)"
  gh api "repos/$REPO/commits/$head_sha" --silent >/dev/null 2>&1 ||
    fail "Commit $head_sha is not on GitHub. Push it to main first."
  main_status="$(gh api "repos/$REPO/compare/$head_sha...main" --jq .status 2>/dev/null || true)"
  [[ "$main_status" == identical || "$main_status" == ahead ]] ||
    fail "Commit $head_sha is not on $REPO's main (compare status '${main_status:-unknown}'). Push it to main first."
fi

identity="${SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identities="$(security find-identity -v -p codesigning | sed -n 's/^ *[0-9]*) [0-9A-F]* "\(Developer ID Application: .*\)"$/\1/p' | sort -u)"
  count="$(grep -c . <<<"$identities" || true)"
  ((count == 1)) || fail "Found $count Developer ID Application identities. Set SIGN_IDENTITY to the one to use."
  identity="$identities"
fi
team_id="$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<<"$identity")"
[[ -n "$team_id" ]] || fail "'$identity' is not a Developer ID Application identity with a Team ID."
log "Releasing $tag (build $build), signed by $identity"

out_dir="${OUT_DIR:-$PROJECT_ROOT/.build/release/$version}"
derived_data="$PROJECT_ROOT/.build/ReleaseDerivedData"
build_log="$out_dir/xcodebuild.log"
rm -rf "$out_dir"
mkdir -p "$out_dir"

log "Resolving packages (log: $build_log)..."
if ! {
  scripts/whisper/build-xcframework.sh &&
    xcodegen generate --quiet &&
    xcodebuild -project OpenVocally.xcodeproj -scheme OpenVocally -derivedDataPath "$derived_data" \
      -resolvePackageDependencies
} >"$build_log" 2>&1; then
  tail -n 40 "$build_log" >&2
  fail "Package resolution failed. Full log: $build_log"
fi
sparkle_bin="$derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin"
[[ -x "$sparkle_bin/generate_appcast" ]] || fail "Sparkle's tools are missing from $sparkle_bin. Delete $derived_data and rerun."

# generate_keys has no file mode, so the public half of a key file comes from CryptoKit.
public_key_from_file() {
  xcrun swift - "$1" 2>/dev/null <<'SWIFT'
import CryptoKit
import Foundation
let text = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let seed = Data(base64Encoded: text.filter { !$0.isWhitespace })!
print(try! Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString())
SWIFT
}

key_args=()
if [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then
  [[ -f "$SPARKLE_KEY_FILE" ]] || fail "SPARKLE_KEY_FILE does not exist: $SPARKLE_KEY_FILE"
  key_args=(--ed-key-file "$SPARKLE_KEY_FILE")
  public_key="$(public_key_from_file "$SPARKLE_KEY_FILE")" ||
    fail "$SPARKLE_KEY_FILE is not a Sparkle EdDSA key file (base64 of a 32-byte seed)."
else
  public_key="$("$sparkle_bin/generate_keys" -p 2>/dev/null)" || {
    echo "[release] Error: No Sparkle EdDSA key in your keychain. Create it once:" >&2
    echo "[release]   '$sparkle_bin/generate_keys'" >&2
    echo "[release] Then back it up somewhere safe; losing it means installed apps can't update:" >&2
    echo "[release]   '$sparkle_bin/generate_keys' -x sparkle-private-key.txt" >&2
    exit 1
  }
fi
[[ "$public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail "Got an unexpected Sparkle public key: '$public_key'."

feed_url="${FEED_URL:-https://raw.githubusercontent.com/$REPO/main/appcast.xml}"
download_prefix="${DOWNLOAD_URL_PREFIX:-https://github.com/$REPO/releases/download/$tag/}"
bundle_id="${BUNDLE_ID:-com.openvocally.app}"
products="$derived_data/Build/Products/Release"
rm -rf "$products"

log "Building Release..."
if ! xcodebuild -project OpenVocally.xcodeproj -scheme OpenVocally -configuration Release \
  -derivedDataPath "$derived_data" \
  APP_SIGN_IDENTITY="$identity" OTHER_CODE_SIGN_FLAGS=--timestamp CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  APP_BUNDLE_ID="$bundle_id" MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
  UPDATE_FEED_URL="$feed_url" UPDATE_PUBLIC_KEY="$public_key" build >>"$build_log" 2>&1; then
  tail -n 40 "$build_log" >&2
  fail "The build failed. Full log: $build_log"
fi

app="$out_dir/OpenVocally.app"
ditto "$products/OpenVocally.app" "$app"

sign() {
  codesign --force --sign "$identity" --options runtime --timestamp "$@" ||
    fail "codesign failed for ${*: -1}. Check that the Developer ID certificate and its private key are in the login keychain."
}

# Sparkle's documented order for Developer ID: XPC services, helpers, framework, then the app.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
sign "$sparkle/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
sign "$sparkle/Versions/B/Autoupdate"
sign "$sparkle/Versions/B/Updater.app"
sign "$sparkle"
for framework in "$app"/Contents/Frameworks/*; do
  [[ "$framework" == "$sparkle" ]] || sign "$framework"
done
sign --entitlements "$ENTITLEMENTS" "$app"

log "Checking signatures..."
codesign --verify --deep --strict --verbose=2 "$app" >/dev/null 2>&1 ||
  fail "The app does not verify. Run: codesign --verify --deep --strict --verbose=4 '$app'"
macho_count=0
while IFS= read -r -d '' file; do
  file -b "$file" | grep -q 'Mach-O' || continue
  macho_count=$((macho_count + 1))
  info="$(codesign -dvv "$file" 2>&1)" || fail "$file is not signed."
  grep -qx "Authority=$identity" <<<"$info" || fail "$file is not signed by $identity."
  grep -q '^Timestamp=' <<<"$info" || fail "$file has no secure timestamp. Sign it with --timestamp."
  grep -q '^CodeDirectory.*flags=.*runtime' <<<"$info" || fail "$file lacks the hardened runtime. Sign it with --options runtime."
  entitlements="$(codesign -d --entitlements - --xml "$file" 2>/dev/null || true)"
  for banned in com.apple.security.cs.disable-library-validation com.apple.security.get-task-allow; do
    ! grep -q "$banned" <<<"$entitlements" || fail "$file has the $banned entitlement, which a release must not carry."
  done
done < <(find "$app" -type f -perm -u+x -print0)
app_entitlements="$(codesign -d --entitlements - --xml "$app" 2>/dev/null |
  python3 -I -c 'import plistlib, sys; print(" ".join(sorted(plistlib.loads(sys.stdin.buffer.read() or b"<plist><dict/></plist>"))))')"
[[ "$app_entitlements" == "$EXPECTED_ENTITLEMENTS" ]] ||
  fail "The app's entitlements are '$app_entitlements', expected exactly '$EXPECTED_ENTITLEMENTS'."
log "$macho_count Mach-O files are signed by Developer ID with a timestamp and the hardened runtime."

zip="$out_dir/OpenVocally-$version.zip"
dmg="$out_dir/OpenVocally.dmg"

notarize() {
  log "Notarizing $(basename "$1") (this takes a few minutes)..."
  local result submission_id status
  result="$(xcrun notarytool submit "$1" --wait --keychain-profile "$profile" --output-format json)" || true
  submission_id="$(python3 -I -c 'import json, sys; print(json.load(sys.stdin).get("id", ""))' <<<"$result" 2>/dev/null || true)"
  status="$(python3 -I -c 'import json, sys; print(json.load(sys.stdin).get("status", ""))' <<<"$result" 2>/dev/null || true)"
  if [[ "$status" != "Accepted" ]]; then
    echo "$result" >&2
    [[ -n "$submission_id" ]] && xcrun notarytool log "$submission_id" --keychain-profile "$profile" >&2
    fail "Notarization of $(basename "$1") ended with status '${status:-unknown}'. The log above names each rejected file."
  fi
}
if [[ "${SKIP_NOTARIZE:-0}" == 1 ]]; then
  log "WARNING: skipping notarization because SKIP_NOTARIZE=1. Do not publish this build."
else
  profile="${NOTARY_PROFILE:-openvocally}"
  xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 ||
    fail "No notarytool profile '$profile'. Create it once: xcrun notarytool store-credentials $profile"
  submission="$out_dir/notarize.zip"
  ditto -c -k --keepParent "$app" "$submission"
  notarize "$submission"
  rm -f "$submission"
  xcrun stapler staple "$app" || fail "Stapling failed. Rerun: xcrun stapler staple '$app'"
  spctl -a -vv -t exec "$app" 2>&1 | grep -q 'source=Notarized Developer ID' ||
    fail "Gatekeeper does not accept the app. Run: spctl -a -vv -t exec '$app'"
  log "Notarized, stapled and accepted by Gatekeeper."
fi
ditto -c -k --keepParent "$app" "$zip"

# The DMG holds the stapled app and an Applications link, so users install by dragging.
log "Building $(basename "$dmg")..."
scripts/release/build-dmg.sh "$app" "$dmg" >>"$build_log" 2>&1 || {
  tail -n 20 "$build_log" >&2
  fail "scripts/release/build-dmg.sh could not build the DMG. Full log: $build_log"
}
sign "$dmg"
codesign --verify --strict "$dmg" 2>/dev/null || fail "The DMG signature does not verify. Run: codesign --verify --strict -vv '$dmg'"
if [[ "${SKIP_NOTARIZE:-0}" != 1 ]]; then
  notarize "$dmg"
  xcrun stapler staple "$dmg" || fail "Stapling the DMG failed. Rerun: xcrun stapler staple '$dmg'"
  xcrun stapler validate "$dmg" >/dev/null || fail "The DMG has no valid ticket. Run: xcrun stapler validate '$dmg'"
  spctl -a -vv -t open --context context:primary-signature "$dmg" 2>&1 | grep -q 'source=Notarized Developer ID' ||
    fail "Gatekeeper does not accept the DMG. Run: spctl -a -vv -t open --context context:primary-signature '$dmg'"
  log "DMG notarized, stapled and accepted by Gatekeeper."
fi

log "Updating $(basename "$appcast")..."
staging="$out_dir/appcast"
mkdir -p "$staging"
cp "$zip" "$staging/"
[[ -f "$appcast" ]] && cp "$appcast" "$staging/appcast.xml"
[[ -n "$notes_file" ]] && cp "$notes_file" "$staging/OpenVocally-$version.${notes_file##*.}"
"$sparkle_bin/generate_appcast" ${key_args[@]+"${key_args[@]}"} --download-url-prefix "$download_prefix" \
  --maximum-versions 0 -o "$staging/appcast.xml" "$staging" >>"$build_log" 2>&1 ||
  fail "generate_appcast failed. See $build_log"

signature="$(python3 -I - "$staging/appcast.xml" "$build" <<'PY'
import sys, xml.etree.ElementTree as ET
ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
for item in ET.parse(sys.argv[1]).iter("item"):
    enclosure = item.find("enclosure")
    version = item.findtext(ns + "version") or (enclosure.get(ns + "version") if enclosure is not None else None)
    if version == sys.argv[2] and enclosure is not None:
        print(enclosure.get(ns + "edSignature", ""))
PY
)"
[[ -n "$signature" ]] || fail "The new appcast has no signed item for build $build. See $build_log"
"$sparkle_bin/sign_update" ${key_args[@]+"${key_args[@]}"} --verify "$zip" "$signature" >/dev/null 2>&1 ||
  fail "The appcast signature does not match $zip. Rerun the release."
grep -q 'sparkle-signatures:' "$staging/appcast.xml" ||
  fail "The new appcast has no feed signature. Check SURequireSignedFeed in project.yml and see $build_log"
log "Staged appcast with verified EdDSA signatures: $staging/appcast.xml"
log "Release archive: $zip"
log "Website download: $dmg"

if [[ "${NO_PUBLISH:-0}" == 1 ]]; then
  cp "$staging/appcast.xml" "$appcast"
  log "Appcast updated: $appcast"
  exit 0
fi

read -r -p "Publish $tag to GitHub? [y/N] " answer
if [[ "$answer" != [yY] ]]; then
  log "Not published. $(basename "$appcast") is unchanged."
  exit 0
fi
notes_args=(--notes "OpenVocally $version")
[[ -n "$notes_file" ]] && notes_args=(--notes-file "$notes_file")
# The DMG keeps a version-less name, so releases/latest/download/OpenVocally.dmg always works.
gh release create "$tag" "$zip" "$dmg" --repo "$REPO" --target "$head_sha" --title "OpenVocally $version" "${notes_args[@]}" ||
  fail "gh release create failed. Fix the cause, then rerun: gh release create $tag '$zip' '$dmg' --repo $REPO --target $head_sha, then copy '$staging/appcast.xml' to '$appcast'"
cp "$staging/appcast.xml" "$appcast"
log "Appcast updated: $appcast"
log "Website download link: https://github.com/$REPO/releases/latest/download/OpenVocally.dmg"
log "Published $tag. Last step: commit and push appcast.xml to main, because installed apps read the feed there."
