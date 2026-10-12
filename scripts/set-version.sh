#!/bin/bash
# Single source of truth for the app version: the VERSION file at the repository root (semantic version X.Y.Z).
#
#   scripts/set-version.sh X.Y.Z            write VERSION, App/Info.plist, package.json (release-it, after the bump)
#   scripts/set-version.sh --check [vX.Y.Z]  exit 1 unless VERSION, App/Info.plist and package.json agree (and the tag)
#   scripts/set-version.sh --apply BUNDLE    stamp a built Pickup.app (used by `scripts/build-app.sh release`)
#   scripts/set-version.sh --print          print the effective version
#
# The effective version is $PICKUP_VERSION when set (CI overrides), otherwise the VERSION file.
# CFBundleShortVersionString = the version. CFBundleVersion = $PICKUP_BUILD_NUMBER when set, otherwise the version
# itself (a dotted string of up to three integers is a valid CFBundleVersion and stays monotonic with releases).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT/VERSION"
PLIST="$ROOT/App/Info.plist"
BUDDY=/usr/libexec/PlistBuddy   # only for --apply (macOS); reading uses python3 so --check also runs on Linux CI

die() { echo "set-version: $*" >&2; exit 1; }
is_semver() { [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; }

effective_version() {
  local v="${PICKUP_VERSION:-}"
  if [ -z "$v" ]; then
    [ -f "$VERSION_FILE" ] || die "VERSION file missing at $VERSION_FILE"
    v="$(tr -d '[:space:]' < "$VERSION_FILE")"
  fi
  is_semver "$v" || die "'$v' is not a plain semantic version X.Y.Z (no 'v' prefix, no pre-release suffix)"
  printf '%s\n' "$v"
}

build_number() {
  local b="${PICKUP_BUILD_NUMBER:-$1}"
  [[ "$b" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "PICKUP_BUILD_NUMBER '$b' must be up to three dot-separated integers"
  printf '%s\n' "$b"
}

write_plist() { # write_plist <plist> <version> <build>
  [ -f "$1" ] || die "plist not found: $1"
  "$BUDDY" -c "Set :CFBundleShortVersionString $2" "$1" >/dev/null || die "cannot set CFBundleShortVersionString in $1"
  "$BUDDY" -c "Set :CFBundleVersion $3" "$1" >/dev/null || die "cannot set CFBundleVersion in $1"
}

plist_version() { python3 -I -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb")).get("CFBundleShortVersionString",""))' "$1"; }

# package.json's version is informational (release-it reads the latest git tag); keep it in step with VERSION.
PACKAGE_JSON="$ROOT/package.json"
package_version() { [ -f "$PACKAGE_JSON" ] && python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$PACKAGE_JSON"; }
write_package_version() { # write_package_version <version>; edits only the top-level "version" line
  [ -f "$PACKAGE_JSON" ] || return 0
  V="$1" perl -0pi -e 's/^(  "version":\s*")[^"]*(")/$1$ENV{V}$2/m' "$PACKAGE_JSON"
  [ "$(package_version)" = "$1" ] || die "could not update the version in package.json"
}

case "${1:-}" in
  --print)
    effective_version ;;
  --check)
    v="$(effective_version)"
    plist_v="$(plist_version "$PLIST")"
    [ "$plist_v" = "$v" ] || die "App/Info.plist has $plist_v but VERSION says $v (run scripts/set-version.sh $v)"
    if [ -f "$PACKAGE_JSON" ] && [ -z "${PICKUP_VERSION:-}" ]; then
      pkg_v="$(package_version)"
      [ "$pkg_v" = "$v" ] || die "package.json has $pkg_v but VERSION says $v (run scripts/set-version.sh $v)"
    fi
    # 0.x: release-it's conventional preset must treat breaking changes as minor ("preMajor": true); from 1.0.0 on
    # it must not (docs/RELEASING.md, "Going 1.0.0").
    if [ -f "$ROOT/.release-it.json" ]; then
      pre_major="$(python3 -I -c 'import json,sys; p=json.load(open(sys.argv[1]))["plugins"]["@release-it/conventional-changelog"]["preset"]; print(str(p.get("preMajor", False)).lower() if isinstance(p, dict) else "false")' "$ROOT/.release-it.json")"
      if [ "${v%%.*}" = 0 ] && [ "$pre_major" != true ]; then die ".release-it.json needs \"preMajor\": true while the version is 0.x"; fi
      if [ "${v%%.*}" != 0 ] && [ "$pre_major" = true ]; then die "version $v is 1.0 or later: set \"preMajor\": false in .release-it.json"; fi
    fi
    if [ -n "${2:-}" ]; then
      [ "${2#v}" = "$v" ] || die "tag $2 does not match VERSION $v (tag the commit release-it created)"
    fi
    echo "set-version: VERSION, Info.plist, package.json${2:+ and tag $2} agree on $v" ;;
  --apply)
    bundle="${2:?--apply needs the path of a built .app}"
    v="$(effective_version)"; b="$(build_number "$v")"
    write_plist "$bundle/Contents/Info.plist" "$v" "$b"
    echo "set-version: stamped $bundle with $v (build $b)" ;;
  -h|--help|"")
    sed -n '2,12p' "$0"; [ -n "${1:-}" ] ;;
  -*)
    die "unknown option: $1" ;;
  *)
    v="$1"; v="${v#v}"
    is_semver "$v" || die "'$1' is not a semantic version X.Y.Z"
    printf '%s\n' "$v" > "$VERSION_FILE"
    # Edit the two values in place (PlistBuddy would reformat the hand-written App/Info.plist).
    V="$v" B="$(build_number "$v")" perl -0pi -e '
      s{(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*(</string>)}{$1$ENV{V}$2};
      s{(<key>CFBundleVersion</key>\s*<string>)[^<]*(</string>)}{$1$ENV{B}$2};
    ' "$PLIST"
    [ "$(plist_version "$PLIST")" = "$v" ] || die "could not update App/Info.plist"
    write_package_version "$v"
    echo "set-version: VERSION, App/Info.plist and package.json set to $v" ;;
esac
