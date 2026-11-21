#!/bin/bash
# Builds Paddock for Intel and assembles the standalone dist/Paddock.app:
#   Contents/MacOS/{PaddockApp,paddockd,paddock,paddock-ports}
# (The app's executable is not called "Paddock": on a case-insensitive disk it would be the same file
# as the "paddock" command.)
#   Contents/Resources/{caddy,composer.phar,router/,php/<bundled>/default/,php-manifest.json,THIRD-PARTY-NOTICES,AppIcon.icns}
# then signs it ad hoc and verifies the signature.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor"
LOCK="$ROOT/Scripts/versions.lock"
APP="$ROOT/dist/Paddock.app"

fail() { echo "bundle.sh: $*" >&2; exit 1; }

# The one PHP series the app bundles is the one fetch-vendor.sh locked (php-<series>-cli).
PHP_SERIES="$(awk -F'\t' '$1 ~ /^php-[0-9]+\.[0-9]+-cli$/ { sub(/^php-/, "", $1); sub(/-cli$/, "", $1); print $1; exit }' "$LOCK" 2>/dev/null || true)"
[ -n "$PHP_SERIES" ] || fail "Scripts/versions.lock names no PHP build. Run Scripts/fetch-vendor.sh first."

for item in caddy composer.phar php-manifest.json router/server.php "php/$PHP_SERIES/default/php" "php/$PHP_SERIES/default/php-fpm"; do
  [ -e "$VENDOR/$item" ] || fail "Vendor/$item is missing. Run Scripts/fetch-vendor.sh first."
done
[ -f "$ROOT/VERSION" ] || fail "VERSION is missing at the repository root."
[ -f "$ROOT/Resources/AppIcon.icns" ] || fail "Resources/AppIcon.icns is missing. Run: swift Scripts/make-icon.swift"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

echo "Building release binaries for x86_64…"
swift build --package-path "$ROOT" -c release --arch x86_64
BIN="$(swift build --package-path "$ROOT" -c release --arch x86_64 --show-bin-path)"

echo "Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/php/$PHP_SERIES/default"

install -m 755 "$BIN/PaddockApp" "$APP/Contents/MacOS/PaddockApp"
install -m 755 "$BIN/paddockd" "$APP/Contents/MacOS/paddockd"
install -m 755 "$BIN/paddock" "$APP/Contents/MacOS/paddock"
# The port helper the setup prompt installs as /Library/PrivilegedHelperTools/app.paddock.ports.
install -m 755 "$BIN/paddock-ports" "$APP/Contents/MacOS/paddock-ports"

RES="$APP/Contents/Resources"
install -m 755 "$VENDOR/caddy" "$RES/caddy"
install -m 644 "$VENDOR/composer.phar" "$RES/composer.phar"
install -m 644 "$VENDOR/php-manifest.json" "$RES/php-manifest.json"
install -m 644 "$ROOT/THIRD-PARTY-NOTICES" "$RES/THIRD-PARTY-NOTICES"
# Built from Resources/AppIcon.svg by Scripts/make-icon.swift.
install -m 644 "$ROOT/Resources/AppIcon.icns" "$RES/AppIcon.icns"
# Vendor/router is a symlink into Resources/; copy real files.
cp -RL "$VENDOR/router" "$RES/router"
# Only the bundled series: Vendor/php may hold other versions cached for tests.
install -m 755 "$VENDOR/php/$PHP_SERIES/default/php" "$RES/php/$PHP_SERIES/default/php"
install -m 755 "$VENDOR/php/$PHP_SERIES/default/php-fpm" "$RES/php/$PHP_SERIES/default/php-fpm"

sed "s/VERSION_PLACEHOLDER/$VERSION/g" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "Signing (ad hoc)…"
# Nested executables first, then the bundle, which seals everything inside it.
for exe in "$RES/caddy" "$RES/php/$PHP_SERIES/default/php" "$RES/php/$PHP_SERIES/default/php-fpm" \
           "$APP/Contents/MacOS/paddockd" "$APP/Contents/MacOS/paddock" "$APP/Contents/MacOS/paddock-ports"; do
  codesign --force -s - "$exe"
done
codesign --force -s - --deep "$APP"
codesign --verify --deep --strict "$APP"

echo "dist/Paddock.app is ready (version $VERSION, PHP $PHP_SERIES)."
