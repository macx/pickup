#!/bin/bash
# Runs the UI tests (docs/TESTING.md, section 4) against the DEBUG Pickup.app with the scripted phone.
#
#   scripts/run-ui-tests.sh [--filter <XCTest filter>] [--no-build]
#
# The tests drive the real app through the macOS Accessibility API (XCUIAutomation cannot run from a
# SwiftPM test bundle). They take over the screen, mouse cursor and keyboard focus for about two
# minutes: do not use the Mac meanwhile. The process that runs this script (Terminal, iTerm, Claude
# Code ...) needs the Accessibility permission.
# Refuses to run against a release build (the scripted phone only exists in debug builds).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
ROOT="$(pwd)"
PACKAGE="App/Tests/PickupUITests"
APP="$ROOT/App/.build/Pickup.app"
SCREENSHOTS="$ROOT/.build/ui-screenshots"
FILTER=(); BUILD=1
while [ $# -gt 0 ]; do
  case "$1" in
    --filter) FILTER=(--filter "${2:?--filter needs a value}"); shift ;;
    --no-build) BUILD=0 ;;
    release|--release) echo "ui tests: refusing to run against a release build (the scripted phone is compiled out of release)." >&2; exit 2 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

has_test_hooks() { [ -x "$APP/Contents/MacOS/Pickup" ] && strings "$APP/Contents/MacOS/Pickup" | grep "PickupTestScenario" >/dev/null; }

# Build the debug app when it is missing, stale or a release build. PICKUP_SKIP_VERIFY avoids the gate
# calling itself (verify.sh -> run-ui-tests.sh -> build-app.sh -> verify.sh).
stale() {
  [ ! -d "$APP" ] && return 0
  has_test_hooks || return 0
  [ -n "$(find App/Sources App/Package.swift App/Resources App/Info.plist -newer "$APP/Contents/MacOS/Pickup" -type f 2>/dev/null | head -1)" ] && return 0
  [ -n "$(find Sources -newer "$APP/Contents/MacOS/Pickup" -type f 2>/dev/null | head -1)" ] && return 0
  return 1
}
if [ "$BUILD" = 1 ] && stale; then
  echo "ui tests: building the debug app ..."
  PICKUP_SKIP_VERIFY=1 PICKUP_NO_SANDBOX=1 scripts/build-app.sh debug >/dev/null || { echo "ui tests: app build failed" >&2; exit 1; }
fi
if ! has_test_hooks; then
  echo "ui tests: $APP is not a debug build with test hooks (no PickupTestScenario); refusing to run." >&2
  exit 2
fi

echo "ui tests: building the test package ..."
swift build --build-tests --package-path "$PACKAGE" -Xswiftc -warnings-as-errors >/dev/null || { echo "ui tests: test package build failed" >&2; exit 1; }

# Accessibility permission, checked before anything is launched.
if ! swift test --skip-build --package-path "$PACKAGE" --filter AccessibilityPermissionTests >/dev/null 2>&1; then
  cat >&2 <<'MSG'

UI-TESTS: Die Bedienungshilfen-Berechtigung fehlt.
  1. Systemeinstellungen > Datenschutz & Sicherheit > Bedienungshilfen oeffnen.
  2. Das Programm aktivieren, aus dem dieses Skript gestartet wird (Terminal, iTerm, Claude Code, ...).
  3. Das Skript danach erneut starten.
Es wurde nichts gestartet und kein Test ausgefuehrt.
MSG
  exit 3
fi

mkdir -p "$SCREENSHOTS"; rm -f "$SCREENSHOTS"/*.png
echo
echo "UI-Tests laufen jetzt (ca. 2 Minuten): Bildschirm, Maus und Tastatur nicht benutzen."
START=$SECONDS
PICKUP_APP="$APP" PICKUP_UI_SCREENSHOTS="$SCREENSHOTS" swift test --skip-build --package-path "$PACKAGE" ${FILTER[@]+"${FILTER[@]}"} 2>&1 | tee "$ROOT/.build/ui-tests.log" | grep -E "error:|Test Case .*(passed|failed)|Executed [0-9]+ tests|NOTE:" | sed -e 's|.*/Cases/||'
RC=${PIPESTATUS[0]}
pkill -x Pickup 2>/dev/null || true
echo "ui tests: $((SECONDS - START)) s, full log .build/ui-tests.log, screenshots in $SCREENSHOTS ($(find "$SCREENSHOTS" -type f -name '*.png' 2>/dev/null | wc -l | tr -d ' ') files)"
if grep -qE "Test Case .*skipped" "$ROOT/.build/ui-tests.log"; then echo "ui tests: tests were skipped, which counts as a failure"; RC=1; fi
exit "$RC"
