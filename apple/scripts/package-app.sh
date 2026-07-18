#!/usr/bin/env bash
# Package the SwiftPM executable into a double-clickable Weaver.app bundle.
# Ad-hoc codesigned so it launches locally; Developer ID / notarization is a
# later distribution step.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --product Weaver

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/Weaver"
APP="$ROOT/build/Weaver.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$BIN_PATH" "$MACOS/Weaver"
cp "$ROOT/apps/macos/Resources/Info.plist" "$APP/Contents/Info.plist"

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
echo "Run:  open \"$APP\"   (or double-click it in Finder)"
