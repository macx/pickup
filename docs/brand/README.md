# Pickup brand assets

**Usage terms:** the name "Pickup" and the Pickup icon (every file in this folder) belong to David Eiken
(icon artwork © 2026 David Eiken, all rights reserved). They are not covered by the MIT licence, which applies to the
source code only. Forks must use their own name and icon. You may show the unmodified icon when you link to, review
or write about the official Pickup app. Full rules: [`TRADEMARKS.md`](../../TRADEMARKS.md).
The mark is derived from the Lucide "phone-call" icon (ISC licence, see `THIRD_PARTY_NOTICES.md`).

## Files

| File | What |
|---|---|
| `pickup-icon-light-{4096,2048,1024}.png` | App icon, default (light) appearance, rendered by Apple's ictool with the real Liquid Glass look; transparent outside the tile. |
| `pickup-icon-dark-{4096,2048,1024}.png` | The same, dark appearance (ink tile). |
| `pickup-icon-{light,dark}-shadow-{4096,2048,1024}.png` | Marketing style: the tile on Apple's icon grid (824/1024 of the canvas) with a soft drop shadow, transparent background. |
| `pickup-icon-{clear-light,clear-dark,tinted-light,tinted-dark}-2048.png` | The system's clear and tinted appearances (default purple tint). |
| `readme-icon-{light,dark}.png` | README hero, 768 px for display at 256 pt (3x). |
| `pickup-icon-{light,dark}-flat.svg` | Clean vector icon without effects: continuous-corner tile, handset, arcs. The tile fills the view box. |
| `pickup-icon-{light,dark}-glass.svg` | Vector icon that imitates the glass look with SVG gradients and filters, on Apple's 1024 grid. |
| `pickup-glyph-{black,white}.svg` | The mark alone (handset and arcs), one colour: favicons, badges, monochrome use. |
| `appearances.png` | Overview of all system appearances (used in `docs/ICON.md`). |

Colours: arcs #F2571A on the light tile and #FF6A2B on the dark tile; handset #1C1814 (light) and #FFF8F1 (dark);
tile near-white #FFFDFA (rendered as Icon Composer's automatic gradient, about #FFFEFC → #F2F0EC) and the ink
gradient #2B2622 → #120F0D. The PNGs are 8-bit sRGB (ictool renders 16-bit; the conversion is not visible).

**The glass SVGs are an approximation.** Real Liquid Glass is rendered by the system (refraction, dynamic
specular highlights that follow the light, depth between layers) and cannot be expressed in SVG. The SVG version
has a soft drop shadow, an inner rim that is brightest at the top, a faint top sheen, and on the glyph a top-edge
highlight and a soft shadow. It was checked in headless Chrome, QuickLook and librsvg (rsvg-convert), which render it the same; macOS's CoreSVG
(NSImage, Finder previews) ignores the filters and shows it nearly flat. For anything that should look like the
real icon, use the PNGs.

## README header

```html
<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/brand/readme-icon-dark.png">
    <img src="docs/brand/readme-icon-light.png" width="256" height="256" alt="Pickup for Mac">
  </picture>
</p>
```

## Regenerate

```bash
swift scripts/generate-app-icon.swift      # only if the mark itself changed
scripts/generate-brand-assets.sh           # renders with ictool (Xcode), writes this folder
```

Review sheets go to `App/.build/icon-preview/brand/` (git-ignored). ImageMagick, if installed, recompresses the
PNGs losslessly.

## High-resolution renders are not in git
The 2048 px and 4096 px PNGs (about 22 MB together) are generated, not committed: run `scripts/generate-brand-assets.sh` to create them in this folder. They are git-ignored so the repository history stays small; the public repository will offer them as a downloadable brand kit in the GitHub Releases. The committed files are the SVGs, the README icons, the 1024 px renders and the overview `appearances.png`.
