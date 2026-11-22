#!/bin/bash
# Makes a release of Paddock: the app, its zip, and the update feed that tells installed copies about it.
#
#   Scripts/release.sh <version>             build everything into dist/release/ and stop
#   Scripts/release.sh <version> --publish   the same, then commit, tag, push and create the GitHub Release
#
# <version> is the new version (1.2.3). The first run for a version writes it to VERSION and raises
# PaddockBuild.number, the one number Sparkle and the daemon's clients compare; running again for the same
# version rebuilds without raising it again.
#
# The update is signed with the EdDSA key in the login Keychain (made once with Sparkle's generate_keys; its
# public half is SUPublicEDKey in Resources/Info.plist). Without that key there is no release.
#
# Release notes: docs/releases/<version>.md, if it is there, is shown in the update window and on GitHub.
#
# The app is signed ad hoc, not with an Apple Developer ID. Scripts/install.sh is how it reaches another Mac
# without macOS questioning it; it reads the SHA256SUMS this script publishes beside the zip.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="gowelle/paddock"
ENGINE="$ROOT/Sources/PaddockCore/Engine.swift"
TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
OUT="$ROOT/dist/release"

fail() { echo "release.sh: $*" >&2; exit 1; }

VERSION="" PUBLISH=0
for argument in "$@"; do
  case "$argument" in
    --publish) PUBLISH=1 ;;
    -*) fail "unknown option $argument" ;;
    *) [ -z "$VERSION" ] || fail "one version, please."; VERSION="$argument" ;;
  esac
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: Scripts/release.sh <version like 1.2.3> [--publish]"
TAG="v$VERSION"
# Where the zip will be downloaded from. (Another address only to try an update against a local server.)
PREFIX="${PADDOCK_DOWNLOAD_PREFIX:-https://github.com/$REPO/releases/download/$TAG/}"

[ -x "$TOOLS/generate_appcast" ] && [ -x "$TOOLS/sign_update" ] \
  || fail "Sparkle's tools are missing from .build/artifacts. Run: swift package resolve"
"$TOOLS/generate_keys" -p >/dev/null 2>&1 \
  || fail "there is no update signing key in the login Keychain. It is made once, with: $TOOLS/generate_keys"
PUBLIC="$("$TOOLS/generate_keys" -p)"
grep -q "<string>$PUBLIC</string>" "$ROOT/Resources/Info.plist" \
  || fail "the Keychain's update key is not the one in Resources/Info.plist (SUPublicEDKey). Installed copies would refuse this update."

if [ "$PUBLISH" = 1 ]; then
  command -v gh >/dev/null || fail "--publish needs the gh command."
  [ "$(git -C "$ROOT" branch --show-current)" = "main" ] || fail "--publish releases from main; this is $(git -C "$ROOT" branch --show-current)."
  git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "the tag $TAG already exists."
fi

# The version and the build number: written once per version.
CURRENT="$(tr -d '[:space:]' < "$ROOT/VERSION")"
if [ "$CURRENT" != "$VERSION" ]; then
  [ -z "$(git -C "$ROOT" status --porcelain)" ] || fail "commit or put away your changes first; a release is built from a clean tree."
  NEWEST="$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)"
  [ "$NEWEST" = "$VERSION" ] || fail "$VERSION is not newer than $CURRENT."
  BUILD="$(sed -n 's/^ *public static let number = \([0-9][0-9]*\)$/\1/p' "$ENGINE")"
  [ -n "$BUILD" ] || fail "PaddockBuild.number was not found in Sources/PaddockCore/Engine.swift."
  sed -i '' "s/^\( *public static let number = \)$BUILD\$/\1$((BUILD + 1))/" "$ENGINE"
  echo "$VERSION" > "$ROOT/VERSION"
  echo "Version $CURRENT -> $VERSION, build $BUILD -> $((BUILD + 1))."
fi

"$ROOT/Scripts/bundle.sh"

ZIP="Paddock-$VERSION.zip"
rm -rf "$OUT"
mkdir -p "$OUT"
cp "$ROOT/dist/$ZIP" "$OUT/$ZIP"
NOTES="$ROOT/docs/releases/$VERSION.md"
if [ -f "$NOTES" ]; then cp "$NOTES" "$OUT/Paddock-$VERSION.md"; fi

echo "Writing the update feed…"
# Signs the zip with the Keychain's key and writes one entry for it. No deltas: every update is the whole app.
"$TOOLS/generate_appcast" --download-url-prefix "$PREFIX" --link "https://github.com/$REPO" \
  --embed-release-notes --maximum-deltas 0 -o "$OUT/appcast.xml" "$OUT" >/dev/null
[ -f "$OUT/appcast.xml" ] || fail "no update feed was written."
grep -q "sparkle:edSignature=" "$OUT/appcast.xml" || fail "the update feed has no signature for $ZIP."
grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$OUT/appcast.xml" \
  || fail "the update feed does not name version $VERSION."
SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$OUT/appcast.xml" | head -n 1)"
"$TOOLS/sign_update" --verify "$OUT/$ZIP" "$SIGNATURE" || fail "the signature in the feed does not verify $ZIP."
rm -f "$OUT/Paddock-$VERSION.md"
# What Scripts/install.sh checks the download against.
(cd "$OUT" && shasum -a 256 "$ZIP" > SHA256SUMS)

echo "dist/release/ holds $ZIP, SHA256SUMS and appcast.xml for $TAG."
if [ "$PUBLISH" = 0 ]; then
  echo "Nothing was published. To publish: Scripts/release.sh $VERSION --publish"
  exit 0
fi

git -C "$ROOT" add VERSION Sources/PaddockCore/Engine.swift
git -C "$ROOT" diff --cached --quiet || git -C "$ROOT" commit -q -m "Release $VERSION"
[ -z "$(git -C "$ROOT" status --porcelain)" ] || fail "the tree is not clean after the release commit; nothing was published."
git -C "$ROOT" tag "$TAG"
git -C "$ROOT" push -q origin main "$TAG"
if [ -f "$NOTES" ]; then
  gh release create "$TAG" "$OUT/$ZIP" "$OUT/SHA256SUMS" "$OUT/appcast.xml" -R "$REPO" --title "Paddock $VERSION" --notes-file "$NOTES"
else
  gh release create "$TAG" "$OUT/$ZIP" "$OUT/SHA256SUMS" "$OUT/appcast.xml" -R "$REPO" --title "Paddock $VERSION" --generate-notes
fi
echo "Paddock $VERSION is published. Installed copies find it within a day, or from Check for Updates…"
