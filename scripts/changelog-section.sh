#!/bin/bash
# Prints the CHANGELOG.md section of one version (the GitHub release notes in .github/workflows/release.yml).
#
#   scripts/changelog-section.sh X.Y.Z [CHANGELOG.md]
#
# Matches release-it/conventional-changelog headings such as "## [0.2.0](https://...) (2026-10-12)" or
# "## 0.2.0 (2026-10-12)" and stops at the next version heading. Exits 1 when the version has no section.
set -euo pipefail
VERSION="${1:?usage: changelog-section.sh X.Y.Z [CHANGELOG.md]}"
VERSION="${VERSION#v}"
FILE="${2:-$(cd "$(dirname "$0")/.." && pwd)/CHANGELOG.md}"
[ -f "$FILE" ] || { echo "changelog-section: $FILE not found" >&2; exit 1; }

section="$(awk -v v="$VERSION" '
  function is_heading(line) { return line ~ /^#+[ \t]+\[?[0-9]+\.[0-9]+\.[0-9]+/ }
  is_heading($0) {
    if (found) exit
    heading = $0; sub(/^#+[ \t]+\[?/, "", heading)
    if (index(heading, v) == 1 && substr(heading, length(v) + 1, 1) ~ /[\] (]|^$/) { found = 1; next }
  }
  found { print }
' "$FILE")"

if [ -z "$(printf '%s' "$section" | tr -d '[:space:]')" ]; then
  echo "changelog-section: no entry for $VERSION in $FILE" >&2
  exit 1
fi
printf '%s\n' "$section"
