#!/usr/bin/env bash
# Sourced by the build scripts. Run directly, it prints the identity they sign with.

LOCAL_IDENTITY_NAME="OpenVocally Local Signing"

# Prints the local signing identity in the keychain, or "-" when there is none.
local_signing_identity() {
  if security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$LOCAL_IDENTITY_NAME\""; then
    printf '%s\n' "$LOCAL_IDENTITY_NAME"
  else
    printf '%s\n' -
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ "${1:-}" == "--help" ]]; then
    cat <<'HELP'
Usage: scripts/lib/signing-identity.sh

Prints the local code signing identity the build scripts use: "OpenVocally Local Signing",
else "-" for ad hoc. Create it with scripts/setup-signing.sh.
HELP
    exit 0
  fi
  local_signing_identity
fi
