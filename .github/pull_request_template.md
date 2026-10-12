<!-- Title: a Conventional Commit, e.g. "feat: show the caller's photo in the banner" or "fix(hfp): ignore a second RING".
     Types: feat, fix, docs, refactor, test, chore, build, ci, perf, style, revert; "feat!:" for breaking changes.
     The title becomes the squash commit on main, the CHANGELOG entry and the input for the next version. Base branch: main. -->

## What and why

<!-- One or two sentences. Link the issue: "Fixes #123". -->

## How it was tested

- [ ] `scripts/verify.sh --quick` passes (build, lint, localization, unit tests, security checks)
- [ ] New or changed behaviour has a test (unit, scenario or UI test)
- [ ] UI changes: checked in English and German, light and dark (screenshots below)
- [ ] Bluetooth changes: tested with a real phone, or marked as "needs hardware test"

## Checklist

- [ ] Every new user-facing string is in `App/Resources/Localizable.xcstrings` with a German translation and a translator comment
- [ ] No real phone numbers, names, Bluetooth addresses or secrets in code, tests, logs or screenshots
- [ ] No network access, no new third-party runtime dependency
- [ ] Signing, entitlements, release scripts and workflows are unchanged (or the maintainer asked for it)
