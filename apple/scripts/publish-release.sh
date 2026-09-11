#!/usr/bin/env bash
# Publish a release from this Mac: run release-macos.sh (build → sign →
# notarize → DMG) and create the GitHub release for the version in Info.plist,
# with the matching CHANGELOG.md section as notes.
#
# Run after merging to main, from a clean checkout of main:
#   WEAVER_SIGN_IDENTITY="Developer ID Application: … (TEAMID)" \
#   WEAVER_NOTARY_PROFILE=weaver \
#   apple/scripts/publish-release.sh
#
# Refuses to publish if the tag already exists, if the tree is dirty, or if
# you're not on main (override the branch check with WEAVER_ALLOW_BRANCH=1).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
PLIST="$ROOT/apps/macos/Resources/Info.plist"
die() { echo "error: $*" >&2; exit 1; }

command -v gh >/dev/null || die "gh CLI required (brew install gh; gh auth login)"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
TAG="v$VERSION"

# ---------------------------------------------------------------- preflight
cd "$REPO_ROOT"
[[ -z "$(git status --porcelain)" ]] || die "working tree is dirty — commit or stash first"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" && "${WEAVER_ALLOW_BRANCH:-0}" != "1" ]]; then
    die "on '$BRANCH', not main (set WEAVER_ALLOW_BRANCH=1 to publish from a branch)"
fi
git fetch -q origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/$BRANCH")" ]] || die "local $BRANCH differs from origin/$BRANCH — push or pull first"
if gh release view "$TAG" >/dev/null 2>&1; then
    die "release $TAG already exists — bump CFBundleShortVersionString first"
fi

# ------------------------------------------------------------------- notes
NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
awk -v v="$VERSION" '
    $0 ~ "^## " { if (found) exit; if ($2 == v) { found = 1; next } }
    found { print }
' CHANGELOG.md > "$NOTES"
[[ -s "$NOTES" ]] || die "no '## $VERSION' section in CHANGELOG.md"
cat >> "$NOTES" <<NOTES_EOF

## Install

Download \`Weaver-$VERSION.dmg\` below, open it, and drag Weaver to Applications.
Signed with a Developer ID certificate and notarized by Apple. macOS 14 or later, universal binary.

SHA-256 in \`Weaver-$VERSION.dmg.sha256\`.
NOTES_EOF

# ------------------------------------------------------------ build + sign
echo "▸ Publishing Weaver $VERSION ($TAG) from $(git rev-parse --short HEAD)"
"$ROOT/scripts/release-macos.sh"

DMG="$ROOT/build/dist/Weaver-$VERSION.dmg"
[[ -f "$DMG" && -f "$DMG.sha256" ]] || die "expected $DMG and its .sha256 — did notarization run? (WEAVER_SKIP_NOTARIZE must be unset)"

# ----------------------------------------------------------------- release
echo "▸ Creating GitHub release $TAG"
gh release create "$TAG" \
    --target "$(git rev-parse HEAD)" \
    --title "Weaver $VERSION" \
    --notes-file "$NOTES" \
    "$DMG" "$DMG.sha256"
echo "✅ $(gh release view "$TAG" --json url -q .url)"
