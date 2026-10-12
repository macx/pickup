# Pickup – guide for Claude and contributors

Pickup for Mac is a native macOS menu bar app (Swift, macOS 26+, Apple silicon) that shows and controls the calls of
an Android phone over Bluetooth Hands-Free Profile (HFP): see who is calling, accept, decline, dial (also from `tel:`
links) and hang up. The conversation itself stays on the phone.

## Principles (do not break them)
- **Remote control is the product.** Every change keeps accept/decline/dial/hang-up working. Call audio on the Mac is
  not part of the app.
- **No network access, no accounts, no cloud, no companion app.** Do not add networking APIs (`URLSession`,
  `Network.framework`, web views); `scripts/security-checks.sh` fails the build if you do.
- **No third-party runtime code.** The Swift packages have path dependencies only. Node (pnpm, release-it) is
  release tooling and never part of the app.
- **`PickupCore` has no IOBluetooth/AppKit dependency,** so the call logic stays testable without hardware.
- The UI follows Apple's Human Interface Guidelines and uses the native Liquid Glass APIs; no fallbacks for older macOS.

## Build and test
```bash
scripts/verify.sh --quick        # build (warnings as errors), swiftlint, localization, unit tests, security checks
swift test                       # core and Bluetooth packages
swift test --package-path App    # app logic
scripts/verify.sh                # full gate: + sanitizers and UI tests (UI tests take over the screen ~2 min)
PICKUP_NO_SANDBOX=1 PICKUP_SKIP_VERIFY=1 scripts/build-app.sh   # quick local debug build (App/.build/Pickup.app)
```
Tools: Xcode 27, `brew install swiftlint gitleaks semgrep`. Release tooling only: `pnpm install --frozen-lockfile`.
Tests never touch Bluetooth or real contacts; they use a scripted fake phone (`docs/TESTING.md`).

## Localization (English and German)
- Every user-facing string lives in `App/Resources/Localizable.xcstrings` (Info.plist strings in
  `InfoPlist.xcstrings`); use `String(localized:)` or `LocalizedStringKey`. No hard-coded UI strings, no sentences
  built by concatenation: use format strings with placeholders.
- Every new string gets a German translation **and** a translator comment in the same change.
  `scripts/check-localization.sh` fails otherwise.
- Format phone numbers, durations and dates with the user's locale. German strings are longer: check the layout.

## Security rules
- Untrusted input: AT lines from the phone, `tel:`/`callto:` URLs, pasted text, contact data.
- Never dial without an explicit user action. Service codes (`*`, `#`) are accepted only from the keypad; `tel:`
  links always ask first.
- Logs go through `DiagnosticLog` only, which redacts phone numbers. No `print`, `NSLog` or direct `Logger`.
- No `try!`, `as!`, `fatalError` or force unwraps of external data in production code.
- No real phone numbers, names, Bluetooth addresses, e-mail addresses or secrets anywhere: code, tests, fixtures,
  logs, screenshots, commit messages. Use the invented test data (Jane Doe, +49 30 0000123, aa-bb-cc-dd-ee-ff).

## Conventions
- English everywhere in the repository (code, comments, docs, commit messages, issues).
- **Conventional Commits** for commit subjects and pull request titles: `feat:`, `fix:`, `docs:`, `refactor:`,
  `test:`, `chore:`, `build:`, `ci:`, `perf:`, `style:`, `revert:`; `feat!:` or a `BREAKING CHANGE:` footer for
  breaking changes. CI rejects other titles (`scripts/check-conventional-commits.sh`).
- **Trunk-based:** `main` is the only long-lived branch. Work on a short-lived branch cut from `main` (`feat/…`,
  `fix/…`, `docs/…`) and open a small, focused pull request **into `main`** (`gh pr create --base main`). Pull
  requests are squash-merged; the title becomes the commit on `main`, so it must be a Conventional Commit.
  Branches `release/v*` belong to the release workflow.
- Every bug fix adds a regression test. Keep pull requests small; one concern per pull request.

## Ask the maintainer first (do not change on your own)
Signing, entitlements (`App/*.entitlements`), `Info.plist` privacy keys, release scripts (`scripts/build-app.sh`
release path, `package-release.sh`, `set-version.sh`, `update-cask.sh`), `.github/workflows/`, `.release-it.json`,
`package.json`/`pnpm-lock.yaml`, `packaging/`, `LICENSE` and `TRADEMARKS.md`.

## Claude must never
- push to `main` directly, merge pull requests, create or move tags, create GitHub releases, run or approve the
  prepare-release or release workflows;
- create repositories, change repository settings, secrets or rulesets;
- perform hardware steps (pairing, real calls), change system settings or defaults, run `sudo`, install software
  without asking;
- publish anything outside a pull request;
- add real personal data or secrets.

Hardware tests are done by the maintainer: when a change needs one, say so in the pull request.

## Skills
`.claude/skills/`: `small-change`, `fix-issue`, `add-localized-string`, `release-checklist`.
More: `README.md`, `docs/TESTING.md`, `docs/RELEASING.md`, `docs/ICON.md`.
