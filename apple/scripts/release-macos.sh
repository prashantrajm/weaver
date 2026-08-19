#!/usr/bin/env bash
# One-command macOS release: build → Developer ID sign → DMG → notarize →
# staple → Gatekeeper verify.
#
# Distribution is Developer ID direct (not the Mac App Store) because the app
# installs a root CA into the System keychain via an admin prompt.
#
# There is no auto-update channel in 0.0.1: no Sparkle, no appcast, no hosted
# version endpoint. Updates are a fresh download from the site.
#
# Required environment:
#   WEAVER_SIGN_IDENTITY    "Developer ID Application: Name (TEAMID)"
#   WEAVER_NOTARY_PROFILE   keychain profile from `xcrun notarytool store-credentials`
# Optional:
#   WEAVER_SKIP_NOTARIZE=1  build + sign + DMG only (dry run)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/Weaver.app"
DIST="$ROOT/build/dist"
ENTITLEMENTS="$ROOT/apps/macos/Resources/Weaver.entitlements"
PLIST="$ROOT/apps/macos/Resources/Info.plist"

die() { echo "error: $*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
[[ -n "${WEAVER_SIGN_IDENTITY:-}" ]] || die "WEAVER_SIGN_IDENTITY is not set (Developer ID Application identity)"
security find-identity -v -p codesigning | grep -qF "$WEAVER_SIGN_IDENTITY" \
    || die "signing identity not found in the keychain: $WEAVER_SIGN_IDENTITY"

if [[ "${WEAVER_SKIP_NOTARIZE:-0}" != "1" ]]; then
    [[ -n "${WEAVER_NOTARY_PROFILE:-}" ]] || die "WEAVER_NOTARY_PROFILE is not set (xcrun notarytool store-credentials)"
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw -o - "$PLIST")"

echo "▸ Releasing Weaver $VERSION (build $BUILD_NUMBER)"

# ------------------------------------------------------------------- build
rm -rf "$DIST"
mkdir -p "$DIST"
WEAVER_SKIP_SIGN=1 "$ROOT/scripts/package-app.sh" release

# --------------------------------------------------------------------- sign
# Hardened runtime + secure timestamp, both required by notarization.
echo "▸ Signing Weaver.app…"
codesign --force --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" --sign "$WEAVER_SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# ------------------------------------------------- notarize + staple (app)
# The app is notarized and stapled BEFORE the DMG is built, so the copy a user
# drags to /Applications carries its own ticket. Stapling only the DMG leaves
# the installed app relying on an online Gatekeeper check — which fails offline.
if [[ "${WEAVER_SKIP_NOTARIZE:-0}" != "1" ]]; then
    echo "▸ Notarizing Weaver.app (this waits for Apple)…"
    ditto -c -k --keepParent "$APP" "$DIST/Weaver.zip"
    xcrun notarytool submit "$DIST/Weaver.zip" --keychain-profile "$WEAVER_NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$DIST/Weaver.zip"
fi

# --------------------------------------------------------------------- DMG
DMG="$DIST/Weaver-$VERSION.dmg"
STAGE="$DIST/dmg-stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Weaver" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$WEAVER_SIGN_IDENTITY" "$DMG"
echo "▸ Built $DMG"

# ------------------------------------------------- notarize + staple (DMG)
if [[ "${WEAVER_SKIP_NOTARIZE:-0}" == "1" ]]; then
    echo "▸ WEAVER_SKIP_NOTARIZE=1 — stopping before notarization"
    exit 0
fi

echo "▸ Notarizing the DMG…"
xcrun notarytool submit "$DMG" --keychain-profile "$WEAVER_NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "▸ Gatekeeper verification"
spctl -a -vvv --type exec "$APP"
spctl -a -vvv --type install "$DMG" || true
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"

shasum -a 256 "$DMG" > "$DMG.sha256"

echo
echo "✅ Release artifacts in $DIST:"
ls -1 "$DIST"
