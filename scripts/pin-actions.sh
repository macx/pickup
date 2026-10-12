#!/bin/bash
# Pins every third-party GitHub Action to a full commit SHA with the version as a comment, e.g.
#   uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
#
#   scripts/pin-actions.sh --check             fail if any `uses:` is not pinned to a 40-character SHA (offline)
#   scripts/pin-actions.sh --resolve           print the latest release tag and its commit SHA for every action used
#   scripts/pin-actions.sh --write [owner/repo@tag ...]
#                                              rewrite the workflows: each given action (or, without arguments,
#                                              every action at its latest release) to the tag's commit SHA
#
# Scans .github/workflows/*.yml and packaging/homebrew/tap/.github/workflows/*.yml. --resolve and --write call the
# GitHub REST API read-only through `gh api` (logged-in gh or GH_TOKEN); they never change anything on GitHub.
# Local actions (./...) and docker:// references are ignored.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
die() { echo "pin-actions: ERROR: $*" >&2; exit 1; }

WORKFLOWS=()
while IFS= read -r -d '' f; do WORKFLOWS+=("$f"); done < <(find .github/workflows packaging/homebrew/tap/.github/workflows -name '*.yml' -print0 2>/dev/null)
[ "${#WORKFLOWS[@]}" -gt 0 ] || die "no workflow files found"

# All "owner/repo[/path]@ref" references.
refs() { grep -hoE 'uses:[[:space:]]*[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[^[:space:]#]+' "${WORKFLOWS[@]}" | sed -E 's/uses:[[:space:]]*//' | sort -u; }

resolve_tag() { # resolve_tag <owner/repo> <tag> -> commit sha (dereferences annotated tags)
  local repo="$1" tag="$2" type sha
  read -r type sha < <(gh api "repos/$repo/git/ref/tags/$tag" --jq '.object.type + " " + .object.sha') || return 1
  if [ "$type" = tag ]; then sha="$(gh api "repos/$repo/git/tags/$sha" --jq '.object.sha')"; fi
  printf '%s\n' "$sha"
}
latest_tag() { gh api "repos/$1/releases/latest" --jq .tag_name; }

case "${1:---check}" in
  --check)
    bad=0
    while IFS= read -r ref; do
      if [[ "${ref##*@}" =~ ^[0-9a-f]{40}$ ]]; then echo "  ok       $ref"; else echo "  UNPINNED $ref"; bad=1; fi
    done < <(refs)
    # Every pinned line should carry a version comment for humans and Dependabot.
    if grep -nE 'uses:[[:space:]]*[^ ]+@[0-9a-f]{40}[[:space:]]*$' "${WORKFLOWS[@]}"; then echo "  ^ pinned without a '# vX.Y.Z' comment"; bad=1; fi
    if [ "$bad" != 0 ]; then echo "pin-actions: unpinned actions found (run --write)"; exit 1; fi
    echo "pin-actions: all actions are pinned to commit SHAs" ;;
  --resolve)
    command -v gh >/dev/null || die "gh is required"
    while IFS= read -r ref; do
      action="${ref%@*}"; repo="$(echo "$action" | cut -d/ -f1-2)"
      tag="$(latest_tag "$repo")"; sha="$(resolve_tag "$repo" "$tag")"
      printf '%-45s latest %-10s %s\n' "$action" "$tag" "$sha"
    done < <(refs) ;;
  --write)
    command -v gh >/dev/null || die "gh is required"
    shift
    targets=("$@")
    if [ "${#targets[@]}" = 0 ]; then
      while IFS= read -r ref; do
        repo="$(echo "${ref%@*}" | cut -d/ -f1-2)"; targets+=("${ref%@*}@$(latest_tag "$repo")")
      done < <(refs)
    fi
    for t in "${targets[@]}"; do
      action="${t%@*}"; tag="${t##*@}"; repo="$(echo "$action" | cut -d/ -f1-2)"
      sha="$(resolve_tag "$repo" "$tag")" || die "cannot resolve $repo@$tag"
      [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "unexpected SHA for $repo@$tag: $sha"
      for f in "${WORKFLOWS[@]}"; do
        A="$action" S="$sha" T="$tag" perl -pi -e 's{(uses:\s*)\Q$ENV{A}\E@[^\s#]+(\s*#[^\n]*)?}{$1$ENV{A}\@$ENV{S} # $ENV{T}}g' "$f"
      done
      echo "pin-actions: $action -> $sha ($tag)"
    done
    "$0" --check ;;
  -h|--help) sed -n '2,14p' "$0" ;;
  *) die "unknown option: $1" ;;
esac
