#!/bin/bash
# Assembles Paddock's web page into dist/site/ (or the folder given): site/index.html with the pictures the
# README uses, the app icon and the headline font. .github/workflows/pages.yml publishes the result.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/dist/site}"

rm -rf "$OUT"
mkdir -p "$OUT/images" "$OUT/fonts"
cp "$ROOT/site/index.html" "$OUT/index.html"
cp "$ROOT/site/social-preview.png" "$OUT/social-preview.png"
cp "$ROOT/Resources/AppIcon.svg" "$OUT/icon.svg"
cp "$ROOT/Resources/fonts/BricolageGrotesque.ttf" "$ROOT/Resources/fonts/BricolageGrotesque-OFL.txt" "$OUT/fonts/"
for picture in menu-running-light menu-running-dark mail-text-light logs-light dumps-light \
               settings-services-light settings-tasks-running-light; do
  cp "$ROOT/docs/images/$picture.png" "$OUT/images/$picture.png"
done
# No Jekyll: the files are served as they are.
touch "$OUT/.nojekyll"
echo "The page is in $OUT."
