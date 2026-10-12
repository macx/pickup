#!/bin/bash
# Validates Conventional Commits (https://www.conventionalcommits.org) for Pickup. No dependencies.
#
#   scripts/check-conventional-commits.sh "<subject>" ...   check the given subjects (e.g. a PR title)
#   scripts/check-conventional-commits.sh --range A..B      check every non-merge commit subject in a git range
#   scripts/check-conventional-commits.sh --msg-file FILE   check the first line of a commit message (commit-msg hook:
#                                                           git config core.hooksPath .githooks, see docs/RELEASING.md)
#
# Format: <type>[(scope)][!]: <description>
#   types: feat fix docs refactor test chore build ci perf style revert
#   "!" or a "BREAKING CHANGE:" footer marks a major change. The description starts after ": " and is not empty.
# Exempt: merge commits created by GitHub or git ("Merge pull request #..", "Merge branch ..") and the
# fixup!/squash! subjects of an interactive rebase in progress (they never reach dev).
set -euo pipefail

TYPES='feat|fix|docs|refactor|test|chore|build|ci|perf|style|revert'
PATTERN="^(${TYPES})(\([a-z0-9][a-z0-9._/-]*\))?!?: [^[:space:]].*$"
MAX_LENGTH=100

usage() { sed -n '2,15p' "$0"; }
failures=0

check() { # check <subject> <label>
  local subject="$1" label="$2"
  case "$subject" in
    "Merge pull request #"*|"Merge branch "*|"Merge remote-tracking branch "*) echo "  skip  $label: merge commit"; return ;;
    "fixup! "*|"squash! "*|"amend! "*) echo "  skip  $label: rebase helper"; return ;;
  esac
  if [[ ! "$subject" =~ $PATTERN ]]; then
    echo "  FAIL  $label: \"$subject\""
    echo "        expected '<type>[(scope)][!]: <description>' with type one of: ${TYPES//|/, }"
    failures=$((failures + 1))
  elif [ "${#subject}" -gt "$MAX_LENGTH" ]; then
    echo "  FAIL  $label: subject is ${#subject} characters (max $MAX_LENGTH)"
    failures=$((failures + 1))
  else
    echo "  ok    $label: $subject"
  fi
}

[ $# -gt 0 ] || { usage; exit 2; }
case "$1" in
  -h|--help) usage; exit 0 ;;
  --range)
    range="${2:?--range needs A..B}"
    count=0
    while IFS=$'\t' read -r sha subject; do
      check "$subject" "${sha:0:8}"; count=$((count + 1))
    done < <(git log --no-merges --format='%H%x09%s' "$range")
    [ "$count" -gt 0 ] || echo "  note  no non-merge commits in $range"
    ;;
  --msg-file)
    file="${2:?--msg-file needs a file}"
    check "$(grep -v '^#' "$file" | head -n 1)" "commit message"
    ;;
  *)
    for subject in "$@"; do check "$subject" "subject"; done
    ;;
esac

if [ "$failures" -gt 0 ]; then
  echo "check-conventional-commits: $failures subject(s) do not follow Conventional Commits"
  exit 1
fi
echo "check-conventional-commits: all subjects follow Conventional Commits"
