#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/signing-identity.sh"
IDENTITY_NAME="$LOCAL_IDENTITY_NAME"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

log() {
  echo "[openvocally] $*"
}

fail() {
  echo "[openvocally] Error: $*" >&2
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -e "s|@IDENTITY@|$IDENTITY_NAME|g" -e "s|@KEYCHAIN@|$KEYCHAIN|g" <<'EOF'
Create a self-signed code signing certificate named "@IDENTITY@" in your
login keychain, once per Mac. `make install` signs with it
automatically, so macOS keeps Microphone and Accessibility permissions across
rebuilds. No Apple Developer account is involved; the certificate never leaves
this Mac.

macOS asks for your password once, to trust the certificate for code signing.

Remove it later with:
  security delete-identity -c "@IDENTITY@" "@KEYCHAIN@"
EOF
  exit 0
fi

allow_codesign_without_prompts() {
  log "Letting codesign use the key without a prompt per file (enter your login password)..."
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -l "$IDENTITY_NAME" -t private "$KEYCHAIN" >/dev/null ||
    log "Could not pre-approve codesign. On the first build, enter your login password and click Always Allow (not Allow)."
}

has_identity() {
  [[ "$(local_signing_identity)" != - ]]
}

if has_identity; then
  log "\"$IDENTITY_NAME\" already exists and is valid for code signing."
  allow_codesign_without_prompts
  exit 0
fi

if security find-certificate -c "$IDENTITY_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  fail "A certificate named \"$IDENTITY_NAME\" exists but is not trusted for code signing.
Delete it and rerun this script:
  security delete-identity -c \"$IDENTITY_NAME\" \"$KEYCHAIN\""
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
P12_PASSWORD="$(uuidgen)"
export P12_PASSWORD

cat >"$work_dir/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY_NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

log "Creating the certificate..."
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
  -config "$work_dir/cert.cnf" -keyout "$work_dir/key.pem" -out "$work_dir/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$work_dir/key.pem" -in "$work_dir/cert.pem" \
  -name "$IDENTITY_NAME" -out "$work_dir/identity.p12" -passout env:P12_PASSWORD

log "Importing it into the login keychain..."
security import "$work_dir/identity.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
allow_codesign_without_prompts

log "Trusting it for code signing (macOS asks for your password)..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$work_dir/cert.pem"

has_identity ||
  fail "The certificate was imported but macOS does not list it as a valid signing identity."

log "Done. The next make install signs with \"$IDENTITY_NAME\"."
log "If an earlier install was signed ad-hoc, grant Microphone and Accessibility once more; later installs keep them."
