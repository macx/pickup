#!/bin/bash
# !!! TAKES OVER THE SCREEN FOR ABOUT 70 SECONDS !!!
# Launches the debug build of Pickup again and again with invented test data (scripted "Test Phone",
# Jane Doe, John Roe, ...), opens the popover, the incoming-call banner, the call HUD and Settings, and
# captures ONLY Pickup's own windows (screencapture -l <window id>, no desktop, no menu bar). Hands off
# the Mac while it runs. Raw 2x captures go to App/.build/screenshots/raw (git-ignored); then run
# scripts/generate-screenshots.sh to compose docs/images/.
#
# Needs: a debug build (PICKUP_SKIP_VERIFY=1 PICKUP_NO_SANDBOX=1 scripts/build-app.sh), the Accessibility
# permission for the terminal (to press "Accept" through the accessibility API), Screen Recording for
# screencapture. Never changes the system appearance or language: both are per-app launch arguments.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BIN="$ROOT/App/.build/Pickup.app/Contents/MacOS/Pickup"
OUT="$ROOT/App/.build/screenshots/raw"
HELPER="$ROOT/App/.build/screenshots/helper"

[ -x "$APP_BIN" ] || { echo "capture: build the debug app first (scripts/build-app.sh)" >&2; exit 1; }
LC_ALL=C grep -a -q PickupTestScenario "$APP_BIN" || { echo "capture: $APP_BIN is not a debug build" >&2; exit 1; }
if pgrep -f "Pickup.app/Contents/MacOS/Pickup" >/dev/null; then
  echo "capture: quit the running Pickup first" >&2; exit 1
fi
mkdir -p "$OUT" "$(dirname "$HELPER")"
# Fresh captures only (a stale file from an earlier run must never end up in an image).
for appearance in ${PICKUP_SHOT_APPEARANCES:-Light Dark}; do
  rm -f "$OUT"/*-"$(echo "$appearance" | tr '[:upper:]' '[:lower:]')"-*.png
done
# The popover follows the menu bar's appearance: capture each appearance with the Mac in that mode.
swiftc -O "$ROOT/scripts/capture-screenshots-helper.swift" -o "$HELPER"

PID=""
cleanup() { [ -n "$PID" ] && kill "$PID" 2>/dev/null || true; pkill -f "Pickup.app/Contents/MacOS/Pickup" 2>/dev/null || true; }
trap cleanup EXIT

# launch <appearance> <lang> <extra args...>
# Light: -NSRequiresAquaSystemAppearance YES (-AppleInterfaceStyle Light is not a valid value and follows the
# system). Dark: -AppleInterfaceStyle Dark. Both live only in this process's argument domain.
launch() {
  local appearance="$1" lang="$2"; shift 2
  local style=(-NSRequiresAquaSystemAppearance YES)
  [ "$appearance" = Dark ] && style=(-AppleInterfaceStyle Dark)
  "$APP_BIN" "${style[@]}" -AppleLanguages "($lang)" -phoneLinkHintDismissed YES "$@" \
    >/dev/null 2>&1 &
  PID=$!
}
stop() { kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; PID=""; sleep 0.4; }

# shoot <name>: captures every Pickup window larger than the status item (no shadow, transparent corners).
shoot() {
  local name="$1" n=0
  while read -r id layer x y w h _; do
    [ "$w" -ge 120 ] && [ "$h" -ge 60 ] || continue
    n=$((n + 1))
    screencapture -x -o -l "$id" "$OUT/$name-$n.png"
    echo "  $name-$n.png  window $id layer $layer ${w}x${h} at $x,$y"
  done < <("$HELPER" windows "$PID")
  [ "$n" -gt 0 ] || echo "  WARNING: no window for $name"
}

for appearance in ${PICKUP_SHOT_APPEARANCES:-Light Dark}; do
  a=$(echo "$appearance" | tr '[:upper:]' '[:lower:]')
  for lang in en de; do
    echo "== $appearance $lang"
    # Popover: keypad open, search for a name.
    launch "$appearance" "$lang" -PickupTestScenario idle -PickupOpenPopover YES \
      -PickupDemoQuery ja -PickupDemoKeypad YES
    sleep 2.2; shoot "popover-search-$a-$lang"; stop
    # Popover: empty search field, the phone's recent calls (read about 2 s after the link came up).
    launch "$appearance" "$lang" -PickupTestScenario idle -PickupOpenPopover YES
    sleep 4; shoot "popover-empty-$a-$lang"; stop
    # Incoming banner (Jane Doe), then the HUD with a running timer, then the ended state.
    launch "$appearance" "$lang" -PickupTestScenario incoming-accept
    sleep 1.8; shoot "banner-$a-$lang"
    if [ "$lang" = en ]; then
      "$HELPER" press "$PID" banner-accept
      sleep 5.3; shoot "hud-$a-$lang"
      "$HELPER" advance
      sleep 0.8; shoot "hud-ended-$a-$lang"
    fi
    stop
    [ "$lang" = en ] || continue
    # Call waiting: Jane is active, John Roe is waiting (a phone with three-way calling), then John is
    # taken and Jane is on hold.
    launch "$appearance" "$lang" -PickupTestScenario call-waiting -PickupTestFastClock YES -PickupTestCallHold YES
    sleep 1.8; "$HELPER" press "$PID" banner-accept
    sleep 3.2; "$HELPER" advance
    sleep 1.2; shoot "waiting-$a-$lang"
    "$HELPER" press "$PID" hud-waiting-hold-accept
    sleep 2.5; shoot "held-$a-$lang"; stop
    # Settings.
    launch "$appearance" "$lang" -PickupTestScenario idle -PickupOpenSettings YES
    # Activate Pickup so the window is captured active (coloured traffic lights, accent colours).
    sleep 2.6; "$HELPER" front "$PID" || "$HELPER" front "$PID" || echo "  WARNING: settings window may be inactive"; sleep 0.7; shoot "settings-$a-$lang"; stop
  done
done
echo "Raw captures: $OUT"
