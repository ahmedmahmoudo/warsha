#!/bin/bash
# Puts the download site together in website/dist: the brand kit's web root (icons, manifest,
# link preview), the two brand images the page shows, and the page itself. GitHub Pages serves
# that folder (.github/workflows/site.yml); to look at it here:
#
#   website/build.sh && python3 -m http.server -d website/dist 5190
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/website/dist"
rm -rf "$OUT" && mkdir -p "$OUT"
cp -R "$ROOT/design/website/public/." "$OUT/"
cp "$ROOT/design/website/brand/logo-mark.svg" "$ROOT/design/website/brand/macos-app-icon.svg" "$OUT/"
cp "$ROOT/website/index.html" "$ROOT/website/style.css" "$OUT/"
echo "Built $OUT"
