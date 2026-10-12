#!/bin/bash
# Makes the pnpm version pinned in package.json ("packageManager": "pnpm@X.Y.Z+sha512.<hash>") available in CI,
# without a third-party action: Node's bundled corepack downloads exactly that version and checks the hash.
# The shims go into a directory under $RUNNER_TEMP (no sudo, nothing written into the Node installation), which is
# added to $GITHUB_PATH for the following steps.
#
#   scripts/ci-setup-pnpm.sh
#
# Locally you do not need this script: install pnpm with Homebrew (`brew install pnpm`) or corepack yourself.
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "ci-setup-pnpm: ERROR: $*" >&2; exit 1; }

spec="$(node -e 'process.stdout.write(require("./package.json").packageManager || "")')"
[[ "$spec" =~ ^pnpm@([0-9]+\.[0-9]+\.[0-9]+)\+sha512\.[0-9a-f]{128}$ ]] \
  || die "package.json needs \"packageManager\": \"pnpm@X.Y.Z+sha512.<hex>\" (got '$spec')"
want="${BASH_REMATCH[1]}"

command -v corepack >/dev/null 2>&1 || die "corepack is not available with $(node --version) (Node 25+ no longer bundles it; use Node 24 or install corepack from npm)"
bin="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/corepack-bin"
mkdir -p "$bin"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 COREPACK_ENABLE_STRICT=1
corepack enable --install-directory "$bin" pnpm
got="$("$bin/pnpm" --version)"
[ "$got" = "$want" ] || die "corepack provided pnpm $got, package.json pins $want"
if [ -n "${GITHUB_PATH:-}" ]; then echo "$bin" >> "$GITHUB_PATH"; fi
echo "ci-setup-pnpm: pnpm $got (corepack $(corepack --version), node $(node --version)) in $bin"
