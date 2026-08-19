#!/usr/bin/env bash
# Regenerate app icons from the master artwork (repo root app.png).
#
#   macOS → apps/macos/Resources/AppIcon.icns  (transparent squircle, inset on
#           the 1024 canvas the way macOS icons are drawn)
#   iOS   → apps/ios/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png
#           (opaque single-size; iOS masks the corners itself)
#
# The master art has its rounded corners painted over an opaque black
# background, so we flood-fill the corners to alpha first.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
SRC="${1:-$REPO/app.png}"
[[ -f "$SRC" ]] || { echo "error: master artwork not found: $SRC" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 - "$SRC" "$WORK" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFilter

src_path, work = sys.argv[1], sys.argv[2]
src = Image.open(src_path).convert("RGB")
w, h = src.size

# Corner background → alpha (flood fill from each corner).
probe, MAGENTA = src.copy(), (255, 0, 255)
for corner in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]:
    ImageDraw.floodfill(probe, corner, MAGENTA, thresh=60)
mask = Image.new("L", (w, h))
mask.putdata([0 if p == MAGENTA else 255 for p in probe.getdata()])
mask = mask.filter(ImageFilter.GaussianBlur(1.2))

art = src.copy()
art.putalpha(mask)

# macOS: 824pt of art on a 1024 canvas (the standard macOS icon grid).
CANVAS, INSET = 1024, 824
canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
scaled = art.resize((INSET, INSET), Image.LANCZOS)
canvas.paste(scaled, ((CANVAS - INSET) // 2, (CANVAS - INSET) // 2), scaled)
canvas.save(f"{work}/macos-1024.png")

# iOS: full-bleed, opaque (no alpha allowed), corners filled with the art's
# own background colour so the system mask has something to cut into.
bg = src.getpixel((w // 2, 25))
ios = Image.new("RGB", (1024, 1024), bg)
flat = art.resize((1024, 1024), Image.LANCZOS)
ios.paste(flat, (0, 0), flat)
ios.save(f"{work}/ios-1024.png")
PY

# ------------------------------------------------------------------ macOS
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
    set -- $spec
    sips -z "$1" "$1" "$WORK/macos-1024.png" --out "$ICONSET/icon_$2.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT/apps/macos/Resources/AppIcon.icns"
echo "wrote apps/macos/Resources/AppIcon.icns"

# -------------------------------------------------------------------- iOS
APPICONSET="$ROOT/apps/ios/App/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$APPICONSET"
cp "$WORK/ios-1024.png" "$APPICONSET/icon-1024.png"
echo "wrote apps/ios/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
