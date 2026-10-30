# README images
- `hero-dark.png`: the top-right corner of a Mac, cropped to the content: menu bar with the Pickup glyph, the open popover with the recent calls, the incoming-call banner and the call window with a second caller waiting. `light-dark.png`: banner and call HUD in both appearances.
- `banner-{light,dark}.png` (German: `banner-de-*`): incoming call. `call-hud-{light,dark}.png`: active call with timer and the ended state. `call-waiting-*`: a second caller during a call (three-way calling) and the call on hold with Swap.
- `popover-search-dark.png` (German: `popover-search-de-dark.png`): the popover with the recent calls and a name search with the keypad open. `settings-{light,dark}.png`: Settings.
- Everything is invented test data (scripted "Test Phone", Jane Doe, John Roe, Max Mustermann); the colourful wallpaper and the menu bar are synthetic.
- Regenerate: `PICKUP_SKIP_VERIFY=1 PICKUP_NO_SANDBOX=1 scripts/build-app.sh`, then `scripts/capture-screenshots.sh` (takes over the screen for about a minute, hands off), then `scripts/generate-screenshots.sh`.
- Capture each appearance with the Mac in that mode (`PICKUP_SHOT_APPEARANCES=Light` or `Dark`). Known limit on macOS 26: a capture of the popover window alone renders its Liquid Glass without a backdrop, which looks right in dark mode but flat grey in light mode, so the hero and popover images are dark only.
