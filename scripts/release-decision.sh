#!/bin/bash
# Decides whether the checked-out commit is released. ci.yml and release.yml both use this one rule, so the push run
# of ci.yml is skipped exactly when release.yml runs the same CI for the commit (docs/RELEASING.md).
#
#   scripts/release-decision.sh     prints "release=true|false" and "version=X.Y.Z" (GITHUB_OUTPUT format), a reason
#                                   on stderr
#
# A commit is released when all of these hold:
#   - the repository is macx/pickup (official builds only; forks never release),
#   - the tag vX.Y.Z of VERSION does not exist yet,
#   - it is a push that changes VERSION against its parent (every release commit from prepare-release does), or a
#     manual run (workflow_dispatch) of release.yml.
# Needs the parent commit and the tags (actions/checkout with fetch-depth: 0).
# Inputs: GITHUB_REPOSITORY, GITHUB_EVENT_NAME (set by GitHub Actions).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

version="$(scripts/set-version.sh --print)"
parent_version="$(git show HEAD^:VERSION 2>/dev/null | tr -d '[:space:]' || true)"
release=false
if [ "${GITHUB_REPOSITORY:-}" != macx/pickup ]; then
  reason="not the official repository (${GITHUB_REPOSITORY:-unset})"
elif git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
  reason="v$version is already released"
elif [ "${GITHUB_EVENT_NAME:-}" = workflow_dispatch ]; then
  release=true; reason="manual run, v$version not tagged yet"
elif [ "${GITHUB_EVENT_NAME:-}" != push ]; then
  reason="event ${GITHUB_EVENT_NAME:-unset} is neither a push nor a manual run"
elif [ "$parent_version" != "$version" ]; then
  release=true; reason="VERSION changed ${parent_version:-none} -> $version"
else
  reason="VERSION unchanged ($version)"
fi
echo "release=$release"
echo "version=$version"
echo "release-decision: release=$release: $reason" >&2
