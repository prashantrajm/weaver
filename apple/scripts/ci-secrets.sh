#!/usr/bin/env bash
# Upload the signing + notarization secrets the Release workflow needs.
# Run once by a maintainer, on the Mac that holds the Developer ID cert.
#
#   apple/scripts/ci-secrets.sh <AuthKey.p8 path> <key id> <issuer id>
#
# Exports "Developer ID Application" (cert + private key) from the login
# keychain as a password-protected .p12 (Keychain Access will prompt), then
# stores everything as GitHub Actions repository secrets via `gh`.
#
# The API key MUST belong to the same team as the Developer ID certificate, or
# notarization is rejected. Check first:
#   xcrun notarytool history --key <p8> --key-id <id> --issuer <issuer>
set -euo pipefail

P8="${1:?AuthKey .p8 path}"; KEY_ID="${2:?key id}"; ISSUER="${3:?issuer id}"
[[ -f "$P8" ]] || { echo "no such file: $P8" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh CLI required" >&2; exit 1; }

IDENTITY="$(security find-identity -v -p codesigning | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/')"
[[ -n "$IDENTITY" ]] || { echo "no Developer ID Application identity in the keychain" >&2; exit 1; }
echo "Exporting: $IDENTITY"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
read -r -s -p "Password to protect the exported .p12: " P12_PASSWORD; echo
security export -k login.keychain-db -t identities -f pkcs12 -P "$P12_PASSWORD" -o "$TMP/cert.p12" \
  || { echo "export failed (approve the Keychain Access prompt, or export manually from Keychain Access)" >&2; exit 1; }

echo "Uploading secrets to $(gh repo view --json nameWithOwner -q .nameWithOwner)…"
base64 < "$TMP/cert.p12" | gh secret set DEVELOPER_ID_P12_BASE64
printf '%s' "$P12_PASSWORD" | gh secret set DEVELOPER_ID_P12_PASSWORD
base64 < "$P8" | gh secret set NOTARY_KEY_P8_BASE64
printf '%s' "$KEY_ID" | gh secret set NOTARY_KEY_ID
printf '%s' "$ISSUER" | gh secret set NOTARY_ISSUER_ID
echo "Done. Re-run the Release workflow (Actions → Release → Run workflow) if a merge already failed on missing secrets."
