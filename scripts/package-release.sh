#!/bin/bash
# Packages a release of Pickup: Pickup-<version>.dmg and Pickup-<version>.zip plus SHA-256 files in dist/.
#
#   scripts/package-release.sh [--dry-run] [--skip-build] [--no-notarize] [--out DIR]
#
#   --dry-run      no certificate, no credentials, no network: ad-hoc signed release build (PICKUP_ADHOC_RELEASE=1),
#                  no notarisation, artifacts named Pickup-<version>-UNSIGNED.{dmg,zip}. For testing the pipeline.
#                  Respects PICKUP_SKIP_VERIFY=1 (skip the gate; allowed only for ad-hoc builds).
#   --skip-build   package the existing App/.build/Pickup.app (must be a release build of the same version).
#   --no-notarize  sign but do not notarise or staple (artifacts named *-NOT-NOTARIZED). Debugging only.
#   --out DIR      output directory (default: dist/).
#
# Signed mode (the default) needs:
#   PICKUP_SIGN_IDENTITY   "Developer ID Application: <Name> (<TEAMID>)"; PICKUP_KEYCHAIN optional.
#   Notarisation credentials, EITHER an App Store Connect API key (preferred, used by CI):
#     PICKUP_NOTARY_KEY_PATH   path to AuthKey_<KEYID>.p8
#     PICKUP_NOTARY_KEY_ID     the key ID
#     PICKUP_NOTARY_ISSUER_ID  the issuer UUID (Users and Access > Integrations > App Store Connect API)
#   OR a keychain profile created once with `xcrun notarytool store-credentials <name>` (handy locally):
#     PICKUP_NOTARY_PROFILE    the profile name
#
# Flow (signed): build + sign the app (build-app.sh release) -> notarise a ZIP of the app -> staple the app ->
# create the DMG from the stapled app -> sign the DMG -> notarise the DMG -> staple the DMG -> ZIP the stapled app
# -> validate (codesign, spctl, stapler) -> SHA-256 files. Two notarisation rounds, so both the DMG and the app in
# the ZIP carry a stapled ticket and open offline.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DRY_RUN=0; SKIP_BUILD=0; NOTARIZE=1; OUT="$ROOT/dist"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; NOTARIZE=0 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --no-notarize) NOTARIZE=0 ;;
    --out) OUT="$(mkdir -p "${2:?--out needs a directory}" && cd "$2" && pwd)"; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "package-release: unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

die() { echo "package-release: ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

VERSION="$("$ROOT/scripts/set-version.sh" --print)"
APP="$ROOT/App/.build/Pickup.app"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pickup-package.XXXXXX")"
MOUNT=""
cleanup() {
  if [ -n "$MOUNT" ] && [ -d "$MOUNT" ]; then hdiutil detach "$MOUNT" -quiet -force >/dev/null 2>&1 || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- Mode and credentials -----------------------------------------------------------------------
if [ "$DRY_RUN" = 1 ]; then
  SUFFIX="-UNSIGNED"
  export PICKUP_ADHOC_RELEASE=1
  unset PICKUP_SIGN_IDENTITY
  echo "package-release: DRY RUN -- ad-hoc signed, not notarised. The artifacts are named *-UNSIGNED and must never be published."
else
  [ -n "${PICKUP_SIGN_IDENTITY:-}" ] || die "PICKUP_SIGN_IDENTITY is not set (\"Developer ID Application: ...\"). Use --dry-run to test without a certificate."
  SUFFIX=""
  [ "$NOTARIZE" = 0 ] && SUFFIX="-NOT-NOTARIZED"
  if [ "$NOTARIZE" = 1 ]; then
    if [ -n "${PICKUP_NOTARY_PROFILE:-}" ]; then
      NOTARY_AUTH=(--keychain-profile "$PICKUP_NOTARY_PROFILE")
      [ -n "${PICKUP_KEYCHAIN:-}" ] && NOTARY_AUTH+=(--keychain "$PICKUP_KEYCHAIN")
    elif [ -n "${PICKUP_NOTARY_KEY_PATH:-}" ] && [ -n "${PICKUP_NOTARY_KEY_ID:-}" ] && [ -n "${PICKUP_NOTARY_ISSUER_ID:-}" ]; then
      [ -f "$PICKUP_NOTARY_KEY_PATH" ] || die "PICKUP_NOTARY_KEY_PATH does not point to a file"
      NOTARY_AUTH=(--key "$PICKUP_NOTARY_KEY_PATH" --key-id "$PICKUP_NOTARY_KEY_ID" --issuer "$PICKUP_NOTARY_ISSUER_ID")
    else
      die "no notarisation credentials: set PICKUP_NOTARY_KEY_PATH + PICKUP_NOTARY_KEY_ID + PICKUP_NOTARY_ISSUER_ID, or PICKUP_NOTARY_PROFILE (see docs/RELEASING.md)"
    fi
  fi
fi
NAME="Pickup-$VERSION$SUFFIX"
DMG="$OUT/$NAME.dmg"
ZIP="$OUT/$NAME.zip"
mkdir -p "$OUT"
rm -f "$DMG" "$ZIP" "$DMG.sha256" "$ZIP.sha256"

# --- Build --------------------------------------------------------------------------------------
if [ "$SKIP_BUILD" = 0 ]; then
  step "Building the release app ($VERSION)"
  "$ROOT/scripts/build-app.sh" release
fi
[ -d "$APP" ] || die "no app at $APP (build it with scripts/build-app.sh release)"
built_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$built_version" = "$VERSION" ] || die "the app is version $built_version, VERSION says $VERSION (rebuild without --skip-build)"
# (grep without -q: an early exit would SIGPIPE the producer and, with pipefail, hide the match)
if strings "$APP/Contents/MacOS/Pickup" | grep PickupTestScenario >/dev/null; then
  die "the app is a debug build with test hooks; packaging needs a release build (drop --skip-build)"
fi
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep get-task-allow >/dev/null; then
  die "the app is debuggable (get-task-allow); not a release signature"
fi
if ! codesign -dvv "$APP" 2>&1 | grep -E 'flags=.*runtime' >/dev/null; then
  die "the app is not signed with the Hardened Runtime; packaging needs scripts/build-app.sh release"
fi

# --- Notarisation helper ------------------------------------------------------------------------
notarize() { # notarize <file> <label>
  local file="$1" label="$2" json id status
  step "Notarising $label (xcrun notarytool submit --wait; usually 1-10 minutes)"
  json="$WORK/notary-$label.json"
  if ! xcrun notarytool submit "$file" "${NOTARY_AUTH[@]}" --wait --timeout 45m --output-format json > "$json"; then
    echo "package-release: notarytool exited with an error; response:" >&2; cat "$json" >&2 || true
  fi
  id="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$json" 2>/dev/null || true)"
  status="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$json" 2>/dev/null || true)"
  echo "    submission ${id:-?}: ${status:-unknown}"
  if [ "$status" != "Accepted" ]; then
    if [ -n "$id" ]; then
      mkdir -p "$OUT/notary-logs"
      xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" "$OUT/notary-logs/$label-$id.json" >/dev/null 2>&1 || true
      echo "    notarisation log: $OUT/notary-logs/$label-$id.json" >&2
    fi
    die "notarisation of $label was not accepted (status '${status:-none}')"
  fi
}

# --- 1. Notarise and staple the app ------------------------------------------------------------
if [ "$NOTARIZE" = 1 ]; then
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/Pickup-notarize.zip"
  notarize "$WORK/Pickup-notarize.zip" app
  xcrun stapler staple "$APP" || die "stapling the app failed"
fi

# --- 2. DMG -------------------------------------------------------------------------------------
# Layout: Pickup.app and an Applications symlink, volume named "Pickup <version>", Pickup's icon as the volume icon.
# No Finder window positions or background picture: that needs Finder scripting (it opens windows) and the plain
# two-icon view is what most Mac apps ship.
step "Creating $NAME.dmg"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Pickup.app"
ln -s /Applications "$STAGE/Applications"
VOLNAME="Pickup $VERSION"
RW="$WORK/rw.dmg"
hdiutil create -quiet -fs APFS -volname "$VOLNAME" -srcfolder "$STAGE" -format UDRW -ov "$RW" || die "hdiutil create failed"
if [ -f "$APP/Contents/Resources/Pickup.icns" ]; then
  MOUNT="$WORK/mnt"; mkdir -p "$MOUNT"
  # -nobrowse/-noautoopen: the volume does not show up in Finder and no window opens.
  if hdiutil attach "$RW" -quiet -nobrowse -noautoopen -mountpoint "$MOUNT"; then
    cp "$APP/Contents/Resources/Pickup.icns" "$MOUNT/.VolumeIcon.icns"
    if SETFILE="$(xcrun -f SetFile 2>/dev/null)"; then
      "$SETFILE" -c icnC "$MOUNT/.VolumeIcon.icns" 2>/dev/null || true
      "$SETFILE" -a C "$MOUNT" || echo "    note: could not set the custom-icon flag; the volume keeps the default icon"
    else
      echo "    note: SetFile not found (Xcode); the volume keeps the default icon"
    fi
    hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -quiet -force
    MOUNT=""
  else
    echo "    note: could not mount the image to set the volume icon; continuing without it"
    MOUNT=""
  fi
fi
hdiutil convert -quiet "$RW" -format ULFO -o "$DMG" || die "hdiutil convert failed"

if [ "$DRY_RUN" = 1 ]; then
  codesign --force --sign - "$DMG"
else
  sign_dmg=(--force --sign "$PICKUP_SIGN_IDENTITY" --timestamp)
  [ -n "${PICKUP_KEYCHAIN:-}" ] && sign_dmg+=(--keychain "$PICKUP_KEYCHAIN")
  codesign "${sign_dmg[@]}" "$DMG" || die "signing the DMG failed"
fi
if [ "$NOTARIZE" = 1 ]; then
  notarize "$DMG" dmg
  xcrun stapler staple "$DMG" || die "stapling the DMG failed"
fi

# --- 3. ZIP -------------------------------------------------------------------------------------
step "Creating $NAME.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP" || die "ditto failed"

# --- 4. Validate --------------------------------------------------------------------------------
step "Validating"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /' || die "codesign verification of the app failed"
codesign --verify --strict --verbose=2 "$DMG" 2>&1 | sed 's/^/    /' || die "codesign verification of the DMG failed"
check_zip="$WORK/zipcheck"; mkdir -p "$check_zip"
ditto -x -k "$ZIP" "$check_zip" || die "cannot unpack $ZIP"
codesign --verify --deep --strict "$check_zip/Pickup.app" || die "the app inside the ZIP does not verify"
if [ "$NOTARIZE" = 1 ]; then
  spctl --assess --type execute --verbose=4 "$APP" 2>&1 | sed 's/^/    /'
  spctl --assess --type execute "$APP" || die "Gatekeeper rejects the app (spctl --assess --type execute)"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG" 2>&1 | sed 's/^/    /'
  spctl --assess --type open --context context:primary-signature "$DMG" || die "Gatekeeper rejects the DMG"
  xcrun stapler validate "$APP" || die "the app has no valid stapled ticket"
  xcrun stapler validate "$DMG" || die "the DMG has no valid stapled ticket"
  spctl --assess --type execute "$check_zip/Pickup.app" || die "Gatekeeper rejects the app from the ZIP"
else
  # Expected to be rejected: not notarised. Shown for information only.
  echo "    spctl (expected: rejected, not notarised): $(spctl --assess --type execute "$APP" 2>&1 | tr '\n' ' ')"
fi

# --- 5. Checksums -------------------------------------------------------------------------------
step "Checksums"
(cd "$OUT" && for f in "$NAME.dmg" "$NAME.zip"; do shasum -a 256 "$f" > "$f.sha256"; cat "$f.sha256"; done)

echo
if [ "$DRY_RUN" = 1 ]; then result="DRY RUN, UNSIGNED"
elif [ "$NOTARIZE" = 1 ]; then result="signed and notarised"
else result="signed, NOT notarised"; fi
echo "package-release: done ($result)"
for f in "$DMG" "$ZIP" "$DMG.sha256" "$ZIP.sha256"; do
  printf '    %-60s %s\n' "${f#"$ROOT"/}" "$(du -h "$f" | cut -f1)"
done
