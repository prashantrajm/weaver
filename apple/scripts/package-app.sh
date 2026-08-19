#!/usr/bin/env bash
# Assemble the SwiftPM executable into a double-clickable Weaver.app bundle.
#
# This is the *bundle assembly* step, shared by local dev and release:
#   - local dev:  ./scripts/package-app.sh          → ad-hoc signed, runs locally
#   - release:    scripts/release-macos.sh calls this with WEAVER_SKIP_SIGN=1 and
#                 then does the Developer ID signing itself.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Release builds go universal (Developer ID downloads must run on Intel Macs
# too); debug stays host-arch for turnaround speed. WEAVER_UNIVERSAL overrides.
ARCH_FLAGS=()
if [[ "${WEAVER_UNIVERSAL:-$([[ "$CONFIG" == "release" ]] && echo 1 || echo 0)}" == "1" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

LABEL="$CONFIG"; [[ ${#ARCH_FLAGS[@]} -gt 0 ]] && LABEL="$CONFIG, universal"
echo "Building ($LABEL)…"
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product Weaver

BIN_PATH="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/Weaver"
APP="$ROOT/build/Weaver.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$BIN_PATH" "$MACOS/Weaver"
cp "$ROOT/apps/macos/Resources/Info.plist" "$APP/Contents/Info.plist"

# App icon is optional; scripts/make-icons.sh generates it from the master
# artwork. Only reference it in Info.plist when it actually exists.
ICNS="$ROOT/apps/macos/Resources/AppIcon.icns"
if [[ -f "$ICNS" ]]; then
    cp "$ICNS" "$RES/AppIcon.icns"
    plutil -replace CFBundleIconFile -string "AppIcon" "$APP/Contents/Info.plist"
else
    echo "warning: apps/macos/Resources/AppIcon.icns missing — shipping without an app icon" >&2
fi

if [[ "${WEAVER_SKIP_SIGN:-0}" != "1" ]]; then
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "Built $APP"
echo "Run:  open \"$APP\"   (or double-click it in Finder)"
