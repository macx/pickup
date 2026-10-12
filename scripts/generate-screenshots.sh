#!/bin/bash
# Composes the README images in docs/images/ from the raw window captures (no screen access, safe to run).
# The raw captures come from scripts/capture-screenshots.sh, which TAKES OVER THE SCREEN; run that first.
# Usage: scripts/generate-screenshots.sh
set -euo pipefail
cd "$(dirname "$0")/.."
RAW=App/.build/screenshots/raw
[ -d "$RAW" ] || { echo "generate-screenshots: no raw captures in $RAW; run scripts/capture-screenshots.sh" >&2; exit 1; }
mkdir -p docs/images
rm -f docs/images/*.png
swift scripts/generate-screenshots.swift "$RAW" docs/images App/Resources/MenuBar/MenuBarConnected.pdf
# Lossless recompression (ImageMagick, if installed): drop the unused alpha channel, maximum zlib level.
if command -v magick >/dev/null; then
  for f in docs/images/*.png; do
    magick "$f" -alpha off -strip -define png:compression-level=9 -define png:compression-filter=5 \
      -define png:compression-strategy=1 "$f.tmp.png" && mv "$f.tmp.png" "$f"
  done
fi
ls -l docs/images/*.png
