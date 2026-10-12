---
name: small-change
description: Make a small, self-contained change to Pickup (a request or a GitHub issue) and open a Conventional-Commit pull request into main. Use for focused fixes, UI tweaks, docs or tests that fit in one pull request.
---

# Small change → pull request into main

1. **Understand the request.** If it is an issue: `gh issue view <N>`. Restate the change in one sentence. If it
   touches signing, entitlements, release scripts, workflows, `packaging/`, `LICENSE` or `TRADEMARKS.md`, stop and
   ask the maintainer (see `CLAUDE.md`).
2. **Branch from an up-to-date main:**
   ```bash
   git switch main && git pull --ff-only
   git switch -c <type>/<short-slug>      # e.g. fix/banner-long-names, docs/testing-typo
   ```
3. **Make the minimal change.** Follow the existing style. No new dependencies, no networking, no hard-coded UI
   strings (use the `add-localized-string` skill for new text). Add or adjust a test for every behaviour change.
4. **Run the quick gate** and fix everything it reports:
   ```bash
   scripts/verify.sh --quick
   ```
   For UI changes, say in the pull request that the maintainer should run `scripts/verify.sh` (UI tests take over
   the screen) and check English and German.
5. **Commit** with a Conventional Commit subject (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`,
   `build:`, `ci:`, `perf:`, `style:`, `revert:`; `!` for breaking changes):
   ```bash
   scripts/check-conventional-commits.sh "fix: keep long caller names on two lines"
   git commit -m "fix: keep long caller names on two lines"
   ```
6. **Open the pull request into main** with the same Conventional title and fill in the template:
   ```bash
   git push -u origin HEAD
   gh pr create --base main --title "fix: keep long caller names on two lines" --body-file <(...)
   ```
   Mention `Fixes #N` if it closes an issue, and "needs hardware test" if Bluetooth behaviour changed.
7. Stop there. Do not merge, do not push to main, do not tag.
