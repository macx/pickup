#!/bin/bash
# Renders the Homebrew cask for a release and (optionally) publishes it to the tap repository macx/homebrew-tap.
#
#   scripts/update-cask.sh --version X.Y.Z [--asset FILE | --download] [--tap-dir DIR] [--pr | --push]
#
#   --version X.Y.Z  the released version (default: scripts/set-version.sh --print)
#   --asset FILE     compute the SHA-256 from a local Pickup-X.Y.Z.dmg (e.g. dist/ in the release job)
#   --download       download the DMG from the GitHub release URL in the cask and hash it (default when no --asset)
#   --tap-dir DIR    write Casks/pickup.rb into this local tap checkout (default: a temporary clone, or none in dry run)
#   --pr             clone the tap, commit on a branch "pickup-X.Y.Z" and open a pull request (needs gh)
#   --push           clone the tap, commit and push to its default branch directly
#   (neither)        DRY RUN: print the rendered cask and a diff against the template; nothing leaves this machine
#
# Environment:
#   HOMEBREW_TAP_TOKEN  fine-grained token with Contents (and for --pr: Pull requests) read/write on macx/homebrew-tap
#                       only. Needed for --pr/--push. Never printed.
#   PICKUP_TAP_REPO     default macx/homebrew-tap
#   PICKUP_RELEASE_REPO default macx/pickup (where the DMG is downloaded from)
#
# The template is packaging/homebrew/Casks/pickup.rb; only its `version` and `sha256` lines are rewritten.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$ROOT/packaging/homebrew/Casks/pickup.rb"
TAP_REPO="${PICKUP_TAP_REPO:-macx/homebrew-tap}"
RELEASE_REPO="${PICKUP_RELEASE_REPO:-macx/pickup}"

VERSION=""; ASSET=""; DOWNLOAD=0; TAP_DIR=""; MODE=dry-run
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:?--version needs X.Y.Z}"; shift ;;
    --asset) ASSET="${2:?--asset needs a file}"; shift ;;
    --download) DOWNLOAD=1 ;;
    --tap-dir) TAP_DIR="${2:?--tap-dir needs a directory}"; shift ;;
    --pr) MODE="pr" ;;
    --push) MODE="push" ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "update-cask: unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

die() { echo "update-cask: ERROR: $*" >&2; exit 1; }
sha256_of() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi; }

[ -n "$VERSION" ] || VERSION="$("$ROOT/scripts/set-version.sh" --print)"
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "'$VERSION' is not X.Y.Z"
[ -f "$TEMPLATE" ] || die "cask template missing: $TEMPLATE"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pickup-cask.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --- SHA-256 of the release DMG -----------------------------------------------------------------
URL="https://github.com/$RELEASE_REPO/releases/download/v$VERSION/Pickup-$VERSION.dmg"
if [ -n "$ASSET" ]; then
  [ -f "$ASSET" ] || die "asset not found: $ASSET"
  case "$(basename "$ASSET")" in
    "Pickup-$VERSION.dmg") ;;
    *UNSIGNED*|*NOT-NOTARIZED*) [ "$MODE" = dry-run ] || die "refusing to publish a cask for an unsigned/unnotarised asset: $ASSET"
                                echo "update-cask: note: $ASSET is not a release asset; fine for a dry run only" ;;
    *) echo "update-cask: note: asset name $(basename "$ASSET") differs from Pickup-$VERSION.dmg" ;;
  esac
  SHA="$(sha256_of "$ASSET")"
  SOURCE="$ASSET"
else
  DOWNLOAD=1
fi
if [ "$DOWNLOAD" = 1 ] && [ -z "$ASSET" ]; then
  echo "update-cask: downloading $URL"
  curl -fsSL --retry 3 -o "$WORK/release.dmg" "$URL" || die "download failed: $URL (is the release published and not a draft?)"
  SHA="$(sha256_of "$WORK/release.dmg")"
  SOURCE="$URL"
  # Cross-check with the published checksum file when it exists.
  if curl -fsSL --retry 3 -o "$WORK/release.sha256" "$URL.sha256" 2>/dev/null; then
    published="$(cut -d' ' -f1 < "$WORK/release.sha256")"
    [ "$published" = "$SHA" ] || die "downloaded DMG hash $SHA differs from the published $URL.sha256 ($published)"
  fi
fi
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || die "could not compute a SHA-256"

# --- Render -------------------------------------------------------------------------------------
RENDERED="$WORK/pickup.rb"
V="$VERSION" S="$SHA" perl -pe '
  s/^(\s*version\s+)"[^"]*"/$1"$ENV{V}"/;
  s/^(\s*sha256\s+)"[^"]*"/$1"$ENV{S}"/;
' "$TEMPLATE" > "$RENDERED"
if ! grep -q "version \"$VERSION\"" "$RENDERED" || ! grep -q "sha256 \"$SHA\"" "$RENDERED"; then
  die "rendering the cask failed (template lines changed?)"
fi
echo "update-cask: Pickup $VERSION, sha256 $SHA (from $SOURCE)"

if [ "$MODE" = dry-run ]; then
  echo "update-cask: DRY RUN, nothing is written or pushed. Rendered cask:"
  echo "-----"; cat "$RENDERED"; echo "-----"
  diff -u "$TEMPLATE" "$RENDERED" | sed 's/^/    /' || true
  if [ -n "$TAP_DIR" ]; then
    mkdir -p "$TAP_DIR/Casks" && cp "$RENDERED" "$TAP_DIR/Casks/pickup.rb"
    echo "update-cask: wrote $TAP_DIR/Casks/pickup.rb (local only)"
  fi
  exit 0
fi

# --- Publish (--pr / --push) --------------------------------------------------------------------
[ -n "${HOMEBREW_TAP_TOKEN:-}" ] || die "HOMEBREW_TAP_TOKEN is not set (fine-grained token for $TAP_REPO)"
export HOMEBREW_TAP_TOKEN   # read by the git credential helper below
if [ -z "$TAP_DIR" ]; then
  TAP_DIR="$WORK/tap"
  # The token goes through a credential helper environment variable, not the URL, so it never lands in
  # .git/config or in log output.
  git -c credential.helper= -c "credential.helper=!f() { echo username=x-access-token; echo \"password=\$HOMEBREW_TAP_TOKEN\"; }; f" \
    clone --quiet --depth 1 "https://github.com/$TAP_REPO.git" "$TAP_DIR" || die "cannot clone $TAP_REPO"
fi
if ! git -C "$TAP_DIR" diff --quiet || ! git -C "$TAP_DIR" diff --cached --quiet; then
  die "the tap checkout $TAP_DIR has local changes"
fi
mkdir -p "$TAP_DIR/Casks"
cp "$RENDERED" "$TAP_DIR/Casks/pickup.rb"
if git -C "$TAP_DIR" diff --quiet -- Casks/pickup.rb && [ -n "$(git -C "$TAP_DIR" ls-files Casks/pickup.rb)" ]; then
  echo "update-cask: the tap already has Pickup $VERSION with this checksum; nothing to do."; exit 0
fi
BRANCH="$(git -C "$TAP_DIR" rev-parse --abbrev-ref HEAD)"
[ "$MODE" = pr ] && BRANCH="pickup-$VERSION" && git -C "$TAP_DIR" checkout --quiet -B "$BRANCH"
git -C "$TAP_DIR" add Casks/pickup.rb
git -C "$TAP_DIR" -c user.name="${GIT_AUTHOR_NAME:-pickup-release-bot}" -c user.email="${GIT_AUTHOR_EMAIL:-pickup-release-bot@users.noreply.github.com}" \
  commit --quiet -m "pickup $VERSION"
git -C "$TAP_DIR" -c credential.helper= -c "credential.helper=!f() { echo username=x-access-token; echo \"password=\$HOMEBREW_TAP_TOKEN\"; }; f" \
  push --quiet origin "HEAD:refs/heads/$BRANCH" || die "push to $TAP_REPO failed (token scope? branch protection?)"
if [ "$MODE" = pr ]; then
  command -v gh >/dev/null 2>&1 || die "gh is needed for --pr"
  GH_TOKEN="$HOMEBREW_TAP_TOKEN" gh pr create --repo "$TAP_REPO" --head "$BRANCH" \
    --title "pickup $VERSION" --body "Automated update from the Pickup release workflow: version $VERSION, sha256 \`$SHA\`." \
    || die "opening the pull request failed"
  echo "update-cask: pull request opened on $TAP_REPO"
else
  echo "update-cask: pushed Pickup $VERSION to the origin of $TAP_DIR ($BRANCH)"
fi
