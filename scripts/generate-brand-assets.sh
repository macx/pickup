#!/bin/bash
# Regenerates docs/brand/ from App/Resources/Pickup.icon (run scripts/generate-app-icon.swift first if the mark
# changed): renders every appearance with Apple's ictool, then scripts/generate-brand-assets.swift writes the
# PNGs, SVGs and overview images. Review sheets go to App/.build/icon-preview/brand (git-ignored).
# Usage: scripts/generate-brand-assets.sh
set -euo pipefail
cd "$(dirname "$0")/.."
IC="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
RENDERS="$(mktemp -d)"
trap 'rm -rf "$RENDERS"' EXIT
render() { # <rendition> <file name> <size> [tint hue]
  local extra=()
  [ -n "${4:-}" ] && extra=(--tint-color "$4" --tint-strength 0.75)
  "$IC" App/Resources/Pickup.icon --export-image --output-file "$RENDERS/$2-$3.png" --platform macOS --rendition "$1" \
    --width "$3" --height "$3" --scale 1 "${extra[@]+"${extra[@]}"}" >/dev/null
}
for r in Default Dark; do for s in 4096 2048 1024 128 64 32 16; do render "$r" "$r" "$s"; done; done
for r in ClearLight ClearDark TintedLight TintedDark; do for s in 2048 1024 128 64 32 16; do render "$r" "$r" "$s"; done; done
# A second tint (green, hue 0.42) next to the default purple.
for r in TintedLight TintedDark; do for s in 1024 128 64 32 16; do render "$r" "${r}Green" "$s" 0.42; done; done
swift scripts/generate-brand-assets.swift "$RENDERS" docs/brand App/.build/icon-preview/brand
# Lossless recompression of the PNGs (ImageMagick, if installed): maximum zlib level, adaptive filters.
if command -v magick >/dev/null; then
  for f in docs/brand/*.png; do
    magick "$f" -define png:compression-level=9 -define png:compression-filter=5 -define png:compression-strategy=1 \
      -define png:exclude-chunks=date,time "$f.tmp.png" && mv "$f.tmp.png" "$f"
  done
fi
ls -l docs/brand
