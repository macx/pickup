---
name: release-checklist
description: Read-only check whether Pickup is ready for a release and what the next version would be; points the maintainer to the prepare-release workflow. Never tags, never releases, never merges. Use when asked "can we release?" or "what goes into the next release?".
---

# Release readiness (read-only)

Releases are made only by the maintainer through GitHub Actions (`docs/RELEASING.md`). This skill only reports.

1. **State of main:** `git fetch --tags origin && git switch main && git pull --ff-only`, then
   `git describe --tags --abbrev=0` (last release, if any) and `scripts/set-version.sh --check`.
2. **What would be released:** `git log --oneline <last-tag>..HEAD` (or the whole history before the first
   release). All subjects should be Conventional Commits:
   `scripts/check-conventional-commits.sh --range <last-tag>..HEAD`.
3. **Next version (no changes written):** `pnpm install --frozen-lockfile`, then
   `git switch -c release/check && pnpm exec release-it --release-version --ci; git switch main && git branch -D release/check`.
   In 0.x a breaking change bumps the minor version and a feature the patch version (`preMajor`); 1.0.0 is only set
   deliberately by the maintainer.
4. **CI on main:** `gh run list --branch main --limit 5` - the latest `ci` run must be green.
5. **Open blockers:** `gh issue list --label bug --state open`, `gh pr list --state open`.
6. **Report** to the maintainer: last version, proposed next version, the user-visible changes (feat/fix/perf),
   anything red, and whether a hardware smoke test is advisable (Bluetooth code changed since the last tag).
7. **Next step for the maintainer** (not for Claude): Actions > `prepare-release` > Run workflow on `main`
   (version empty, or explicit), review and squash-merge the release pull request; `release.yml` does the rest.

Never run `prepare-release`, never create tags or GitHub releases, never push to `main`.
