# README images
- `hero.png` / `hero-dark.png`: the top-right corner of a Mac: menu bar with the Pickup glyph, the incoming-call banner and (when a capture in that appearance exists) the open popover. `light-dark.png`: banner and call HUD in both appearances.
- `banner-{light,dark}.png` (German: `banner-de-*`): incoming call. `call-hud-{light,dark}.png`: active call with timer and the ended state. `call-waiting-*`: a second caller during a call.
- `popover-search-dark.png` (German: `popover-search-de-dark.png`): the empty popover and a name search with the keypad open. `settings-{light,dark}.png`: Settings.
- Everything is invented test data (scripted "Test Phone", Jane Doe, John Roe); the wallpaper and menu bar are synthetic.
- Regenerate: `PICKUP_SKIP_VERIFY=1 PICKUP_NO_SANDBOX=1 scripts/build-app.sh`, then `scripts/capture-screenshots.sh` (takes over the screen for about a minute, hands off), then `scripts/generate-screenshots.sh`.
- The popover follows the menu bar's appearance, not the app's: the light popover images (and the popover in `hero.png`) need a capture run with the Mac in Light Mode.
