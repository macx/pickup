# Releasing Pickup

How code gets from a pull request to `brew upgrade --cask pickup`. Everything is scripted; the steps marked
**(David)** need a person, an account or a browser.

## Repositories

| Repository | Visibility | Role |
|---|---|---|
| `macx/pickup` | public from day one | The product and its source of truth: code, Issues, Pull Requests, CI, releases. Own `CLAUDE.md` and skills (`.claude/skills/`) for small changes. |
| `macx/pickup-dev` | private | Idea and development container for Claude (agents, spikes, hardware log, concept). Larger tasks are developed against a clone of `macx/pickup` and land there as pull requests. Its workflows never run (repository guard). |
| `macx/homebrew-tap` | public | `Casks/pickup.rb`, written by the release workflow for signed releases. |

`macx/pickup` starts once with `scripts/export-initial.sh` (clean start, one commit, no history); after that, nothing
is synchronised from `pickup-dev`.

## Branch model: trunk-based

- **`main` is the only long-lived branch and the default branch.** Every change lands by pull request into `main`
  and is **squash-merged**: the pull request title becomes the commit on `main`, so it must be a Conventional Commit
  (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`, `build:`, `ci:`, `perf:`, `style:`, `revert:`;
  `feat!:` or a `BREAKING CHANGE:` footer for breaking changes). The `conventional title` check enforces it.
- Work branches are short-lived (`feat/…`, `fix/…`, `docs/…`); Claude opens pull requests with `--base main`.
- `release/vX.Y.Z` branches are created only by the `prepare-release` workflow.
- Optional local hook against bad commit subjects: `git config core.hooksPath .githooks`.

## Versioning

- Semantic versions, single source `VERSION`; `scripts/set-version.sh` keeps `App/Info.plist`
  (`CFBundleShortVersionString`, `CFBundleVersion`) and `package.json` in step; `--check` verifies them.
- **0.x while the app is unsigned.** The clean-start commit has `VERSION` 0.1.0. release-it's conventional preset
  runs with `"preMajor": true`: in 0.x a breaking change bumps the **minor** version and a feature or fix the
  **patch** version, so a breaking change never jumps to 1.0.0 by itself.
- **1.0.0 is set deliberately**, once releases are signed, notarised and on Homebrew and the CI/CD has been proven:
  in one pull request set `"preMajor": false` in `.release-it.json` (`scripts/set-version.sh --check` insists on it
  for versions ≥ 1.0.0 and on `true` below), merge it, then run `prepare-release` with **version `1.0.0`** (the
  workflow passes it to `release-it 1.0.0 --ci`). From then on normal semver applies.
- The latest version is read from the git tags (`vX.Y.Z`); release-it does not read `package.json`
  (`"npm": false`).

## How a release works

```
main ── PRs (squash) ──●──●──●───────────────●  "chore(release): v0.3.0 (#42)"  ── push to main ──> release.yml
                        \                     ↑ squash-merge by David
                         release/v0.3.0 ──●───┘  created by prepare-release (release-it: VERSION, Info.plist,
                                                 package.json, CHANGELOG.md, one commit, no tag); CI runs on the PR

release.yml:  plan ─> ci (all jobs, this commit) ─> release [environment "release", approval] ─> homebrew (signed only)
              plan: release only if the push changes VERSION and vX.Y.Z is not tagged (scripts/release-decision.sh)
              release: build; signed: sign + notarise + staple; unsigned (0.x only): ad-hoc, *-UNSIGNED files;
                       GitHub Release (notes = CHANGELOG section; pre-release while 0.x); publishing creates tag vX.Y.Z
```

1. **R1 (David)** Actions > `prepare-release` > Run workflow on `main`. Version: empty (computed from the
   Conventional Commits since the last tag) or `patch` / `minor` / `major` / `X.Y.Z`.
   The release commit must bump `VERSION`: only a push that changes `VERSION` is released. (The first release,
   `0.1.0`, was entered explicitly because release-it would have started from 0.0.0 without a tag.)
2. The workflow cuts `release/vX.Y.Z` from `main`, runs release-it there (`pnpm exec release-it [version] --ci`), pushes
   the branch and opens the pull request `chore(release): vX.Y.Z` into `main` with the changelog section and a
   checklist. Running it again replaces the branch and updates the pull request.
3. **R2 (David)** On that pull request: CI green; run the local gate with UI tests on the branch
   (`gh pr checkout <N> && scripts/verify.sh`; the UI tests take over the screen for about two minutes); hardware
   smoke test if Bluetooth code changed. Do not merge other pull requests in between (or re-run prepare-release).
4. **R3 (David)** Squash-merge it, keeping the title.
5. `release.yml` runs on that push: CI again on exactly this commit, then waits for **R4 (David): approve the
   `release` environment**. It builds, signs and notarises (signed) or packages `*-UNSIGNED` files (0.x without a
   certificate), creates the GitHub Release `vX.Y.Z` on that commit (pre-release while 0.x), uploads DMG, ZIP and
   `.sha256` files, and for signed releases updates `macx/homebrew-tap`.
6. **R5** Verification (below). Users: `brew upgrade --cask pickup` (signed releases).

If a release fails after the merge: fix the cause by a normal pull request, then either re-run the failed jobs
(transient: notary service, network) or run `release.yml` by hand on `main` (workflow_dispatch; it releases the
current `VERSION` if its tag does not exist). Never move a published tag.

## Files

| File | Purpose |
|---|---|
| `VERSION`, `scripts/set-version.sh` | Version source; writes/checks Info.plist and package.json, stamps built bundles (`--apply`), guards `preMajor`. |
| `scripts/build-app.sh release` | Release build: gate, version stamp, test-hook check, inside-out signing with Hardened Runtime and `App/Pickup-Release.entitlements` (only Contacts), audit. |
| `scripts/package-release.sh` | DMG + ZIP, notarisation, stapling, validation, SHA-256. `--dry-run`: ad-hoc, `*-UNSIGNED`, no credentials. |
| `scripts/changelog-section.sh` | One version's CHANGELOG section (release notes, release PR body). |
| `scripts/update-cask.sh` | Renders `packaging/homebrew/Casks/pickup.rb` and pushes it to the tap (default: dry run; refuses UNSIGNED assets). |
| `scripts/check-conventional-commits.sh` | Conventional Commits check (PR titles, ranges, commit-msg hook). |
| `scripts/ci-setup-pnpm.sh` | pnpm in CI via Node's corepack, version and SHA-512 from `package.json`; no third-party action. |
| `scripts/pin-actions.sh` | Checks/updates the commit-SHA pins of all GitHub Actions. |
| `scripts/export-initial.sh` | One-time clean start of `macx/pickup` (only in `pickup-dev`). |
| `.github/workflows/ci.yml` | CI jobs; also called by `release.yml`. |
| `.github/workflows/pr-title.yml` | `conventional title` check (re-runs when a title is edited). |
| `.github/workflows/prepare-release.yml` | Release branch + release pull request. |
| `.github/workflows/release.yml` | Tag, build, sign, notarise, GitHub Release, Homebrew. |
| `.github/dependabot.yml`, `.github/pull_request_template.md` | Weekly Actions / monthly pnpm updates (14-day cooldown, Conventional titles); PR checklist. |
| `package.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml`, `.release-it.json`, `CHANGELOG.md` | Release tooling (Node only for releasing). |
| `packaging/homebrew/` | Cask template; `tap/` holds README and CI for `macx/homebrew-tap`. |
| `packaging/public/` | (`pickup-dev` only) the public `CLAUDE.md` and skills that `export-initial.sh` puts at the root. |

### pnpm and supply chain
- `package.json` pins pnpm with its SHA-512 (`"packageManager": "pnpm@12.11.2+sha512.…"`) and the two dev
  dependencies exactly (release-it 21.1.0, @release-it/conventional-changelog 12.0.2); `pnpm-lock.yaml` is committed.
- `pnpm-workspace.yaml`: `minimumReleaseAge: 20160` (14 days), `trustPolicy: no-downgrade`, `blockExoticSubdeps`,
  `strictDepBuilds: true` with an empty `allowBuilds` (no dependency may run install scripts), `engineStrict`,
  `verifyDepsBeforeRun: error`, exact saves.
- CI installs only with `pnpm install --frozen-lockfile`; release-it runs with a checkout that holds no token
  (`persist-credentials: false`); the push uses the token only in that one `git` call.
- Locally: `brew install pnpm` (or corepack), `pnpm install --frozen-lockfile`. Updates arrive as Dependabot pull
  requests; `pnpm add -D <pkg>@<exact>` respects the 14-day age.

## Unsigned 0.x pre-releases and signed releases

| | Unsigned (now: no Developer ID yet) | Signed (after enrolment) |
|---|---|---|
| Trigger | `PICKUP_SIGN_IDENTITY` variable empty | variable set, secrets present |
| Versions | 0.x only (`plan` refuses ≥ 1.0.0 unsigned) | any |
| Files | `Pickup-X.Y.Z-UNSIGNED.{dmg,zip}` + `.sha256`, ad-hoc signed | `Pickup-X.Y.Z.{dmg,zip}` + `.sha256`, Developer ID, notarised, stapled |
| GitHub Release | pre-release, with a warning how to open it ("Open Anyway") | pre-release while 0.x, then latest |
| Homebrew | no cask | cask updated in `macx/homebrew-tap` |

## One-time setup (David)

### A. Public repository (now, no Apple account needed)
1. Make `README.md` public-ready in the workshop (no private concept link, no workshop sections; `export-initial.sh`
   refuses otherwise) and commit it.
2. GitHub > Settings > Emails: enable **Keep my email addresses private** and **Block command line pushes that
   expose my email**. Commits in `macx/pickup` use `84112+macx@users.noreply.github.com` (the export sets it in the
   new repository's git config).
3. `scripts/export-initial.sh` (dry run: file list, warnings, checks), then
   `scripts/export-initial.sh --apply --target ~/Projects/pickup` (one commit "chore: start the public repository",
   VERSION 0.1.0, branch `main`, remote `origin` set, nothing pushed).
4. Create the **public** repository `macx/pickup` on GitHub, empty (no README, licence or .gitignore), description
   "Pickup for Mac – Android calls on macOS". Then `git -C ~/Projects/pickup push -u origin main`.
5. Settings > General: default branch `main`; Pull Requests: allow **squash merging only** (untick merge commits and
   rebase merging), "Default commit message" = **Pull request title**; enable "Always suggest updating pull request
   branches" and "Automatically delete head branches". Features: Issues on.
6. Settings > Actions > General: "Allow macx, and select non-macx, actions and reusable workflows" with only "Allow
   actions created by GitHub"; tick **Require actions to be pinned to a full-length commit SHA**; Workflow
   permissions: **Read repository contents and packages permissions**; leave "Allow GitHub Actions to create and
   approve pull requests" **off** (pull requests are opened with `RELEASE_TOKEN`, not `GITHUB_TOKEN`).
7. Settings > Rules > Rulesets > New branch ruleset **`main`** (Enforcement: Active, target: default branch,
   bypass list: **empty**):
   - Restrict deletions; Block force pushes; Require linear history;
   - Require a pull request before merging: required approvals **0** (sole maintainer), require conversation
     resolution; allowed merge methods: **Squash**;
   - Require status checks to pass (and "Require branches to be up to date"): `conventional title`,
     `release tooling (pnpm, release-it)`, `lint (swiftlint)`, `localization check`,
     `build and test (unit, scenario, fuzz)`, `sanitizers (address, thread)`,
     `security (gitleaks, semgrep, security-checks)`, `build release app (unsigned dry run)`.
   With no bypass and no required approvals, David merges release and other pull requests normally once the checks
   pass.
8. New tag ruleset **`release tags`**, target pattern `v*`: restrict creations, updates and deletions; bypass list:
   **Repository admin** (the release workflow creates tags with David's `RELEASE_TOKEN`).
9. **`RELEASE_TOKEN`:** GitHub > Settings > Developer settings > Fine-grained tokens > Generate: name
   `pickup-release`, owner `macx`, expiration 1 year (calendar reminder), only repository `macx/pickup`; permissions
   **Contents: Read and write**, **Pull requests: Read and write** (Metadata read is automatic).
10. Settings > Environments:
    - **`prepare-release`**: deployment branches = Selected: `main`; secret `RELEASE_TOKEN`.
    - **`release`**: required reviewer `macx`; deployment branches = Selected: `main`; secret `RELEASE_TOKEN`
      (signing secrets follow in C).
11. Repository variables (Settings > Secrets and variables > Actions > Variables), optional:
    `PICKUP_MACOS_RUNNER` (default `xcode-27`), `PICKUP_DEVELOPER_DIR`, `PICKUP_TAP_MODE` (`push` | `pr` | `off`),
    `PICKUP_CI_UI_TESTS` (`true` enables the experimental UI-test job). Leave `PICKUP_SIGN_IDENTITY` unset for now.
12. First pre-release: R1 with version `0.1.0`, then R2-R5. Expect an unsigned pre-release `v0.1.0`.

### B. Homebrew tap (before the first signed release)
13. Create the public repository `macx/homebrew-tap` with `LICENSE` (MIT), `README.md` from
    `packaging/homebrew/tap/README.md` and `.github/workflows/ci.yml` from `packaging/homebrew/tap/.github/workflows/ci.yml`
    (same Actions policy as step 6; with `PICKUP_TAP_MODE=pr` also a `main` ruleset requiring the `audit` check).
14. Fine-grained token `pickup-homebrew-tap`: only `macx/homebrew-tap`, **Contents: Read and write** (+ **Pull
    requests: Read and write** for `pr` mode), 1 year. Store it as secret `HOMEBREW_TAP_TOKEN` in environment `release`.

### C. Apple signing (after enrolment)
15. **Enrol in the Apple Developer Program** (individual, 99 USD/year): <https://developer.apple.com/programs/enroll/>.
    Note the **Team ID** (Account > Membership details).
16. Xcode > Settings > Accounts > Manage Certificates > `+` > **Developer ID Application**. Check with
    `security find-identity -v -p codesigning`: `Developer ID Application: David Eiken (<TEAMID>)`.
17. Keychain Access > My Certificates > that certificate (with its private key) > Export > `DeveloperID.p12` with a
    long random password (password manager). `base64 -i DeveloperID.p12 | pbcopy`; delete the file afterwards.
18. <https://appstoreconnect.apple.com> > Users and Access > Integrations > App Store Connect API > Team Keys > `+`:
    name `pickup-notary`, access **Developer**; download `AuthKey_<KEYID>.p8` (only once), note Key ID and Issuer ID.
19. Environment `release` secrets: `PICKUP_DEVELOPER_ID_P12_BASE64`, `PICKUP_DEVELOPER_ID_P12_PASSWORD`,
    `PICKUP_NOTARY_KEY_P8` (whole file content), `PICKUP_NOTARY_KEY_ID`, `PICKUP_NOTARY_ISSUER_ID`. Repository
    variable `PICKUP_SIGN_IDENTITY` = `Developer ID Application: David Eiken (<TEAMID>)`. From the next release on,
    builds are signed and the cask is published.
20. Optional for local signed builds: `xcrun notarytool store-credentials pickup-notary --key AuthKey_<KEYID>.p8
    --key-id <KEYID> --issuer <ISSUER-ID>`, then `PICKUP_NOTARY_PROFILE=pickup-notary scripts/package-release.sh`.
21. After the first signed release passed the verification: go 1.0.0 (see *Versioning*).

## Testing the pipeline without credentials

```bash
PICKUP_SKIP_VERIFY=1 scripts/package-release.sh --dry-run   # dist/Pickup-X.Y.Z-UNSIGNED.{dmg,zip}
scripts/update-cask.sh --version X.Y.Z --asset some.dmg       # prints the rendered cask, writes nothing
scripts/check-conventional-commits.sh "feat: something"
scripts/pin-actions.sh --check
pnpm install --frozen-lockfile && pnpm release:dry-run         # on a release/* branch: next version + changelog
```

`PICKUP_SKIP_VERIFY=1` is accepted for release builds only when they are ad-hoc signed. CI builds the same unsigned
DMG and ZIP on every pull request and every push to main (artifact `pickup-unsigned-<sha>`, kept 7 days).

**One CI run per commit.** `release.yml` starts only for pushes that change `VERSION`. `scripts/release-decision.sh`
decides for both workflows whether a commit is released (official repository, `VERSION` changed against the parent,
tag missing; or a manual run of `release.yml`). For such a commit the `route` job of `ci.yml` skips the push run,
because `release.yml` runs the same CI for it; for every other commit the push run of `ci.yml` is the only one.

## Verification

1. Download DMG and ZIP from the release page; `shasum -a 256 -c Pickup-X.Y.Z.dmg.sha256`.
2. Signed: `xcrun stapler validate Pickup-X.Y.Z.dmg`; after installing,
   `spctl --assess --type execute -vv /Applications/Pickup.app` → `accepted`, `source=Notarized Developer ID`.
3. `codesign -dvv --entitlements - /Applications/Pickup.app`: `flags=0x10000(runtime)`, Team ID, secure timestamp,
   only the `addressbook` entitlement, no `get-task-allow`.
4. **Hardware (David):** open the downloaded app (quarantined, from the browser): Bluetooth prompt, the Pixel connects,
   incoming and outgoing calls work (this confirms IOBluetooth under the Hardened Runtime without
   `com.apple.security.device.bluetooth`), Contacts prompt and names, "Make Pickup the default for phone links".
5. Homebrew (signed): `brew install --cask macx/tap/pickup` on a Mac without Pickup; `brew uninstall --zap --cask
   pickup`; the tap CI runs `brew audit --cask --strict --online` and `brew livecheck`.

## Homebrew: own tap with Homebrew 7 (checked 2026-10-13, Homebrew 7.0.9)

- **Works.** A third-party tap repository named `homebrew-tap` with `Casks/pickup.rb` is supported
  (docs.brew.sh "How to Create and Maintain a Tap"). There is no official cask called `pickup`, so the short name is
  free; casks need globally unique names, so if an official `pickup` appears later, rename ours (`pickup-for-mac`).
- **Tap trust (Homebrew 6.0+):** code from non-official taps must be trusted before it is evaluated. Installing a
  fully qualified name, `brew install --cask macx/tap/pickup`, trusts exactly that cask; `brew tap macx/tap` alone
  does not, then `brew trust --cask macx/tap/pickup` (or `brew trust --tap macx/tap`) is needed. Trust is stored in
  `~/.homebrew/trust.json`. The tap README shows the fully qualified command.
- **Gatekeeper:** Homebrew 5.0 deprecated casks that fail Gatekeeper checks and announced disabling such casks in
  `homebrew/cask` from September 2026; it also deprecated `--no-quarantine`, so users cannot easily bypass
  Gatekeeper. Whether the disable rule is enforced for third-party taps is not stated in the release notes; we only
  publish signed and notarised builds to the tap, so it does not matter. Homebrew keeps the quarantine attribute on
  downloads.
- **What users see** for our signed, notarised and stapled DMG: `brew install` downloads, verifies the SHA-256 and
  copies `Pickup.app` to `/Applications`. On first launch macOS shows the usual one-time "Pickup is an app
  downloaded from the Internet. Are you sure you want to open it?" confirmation (no "Open Anyway" detour, no
  malware warning), then the Bluetooth and Contacts permission prompts. `brew upgrade --cask pickup` updates it.
- **Cask style:** Homebrew's style check requires `depends_on macos: :tahoe` (a bare symbol = this version or newer;
  `">= :tahoe"` is rejected). `depends_on arch: :arm64` because the build is arm64 only. `zap` removes
  `~/Library/Preferences/dev.eiken.pickup.plist`, `~/Library/Logs/Pickup`, `~/Library/Containers/dev.eiken.pickup`
  and `~/Library/Application Support/Pickup`. Homebrew 7 deprecates `preflight`/`postflight` blocks; we use none.
- **Official `homebrew/cask` later:** repository at least 30 days old and 30 forks, 30 watchers or 75 stars (90 / 90 /
  225 for a submission by the owner), must pass Gatekeeper (signed and notarised), stable releases only. Then submit
  `Casks/p/pickup.rb`, let Homebrew's autobump take over, set `PICKUP_TAP_MODE=off` and point the tap README to
  `brew install --cask pickup`.

## Known risks and limits

- **Not yet exercised:** Developer ID signing, notarisation, stapling, the CI keychain import, prepare-release and the
  tag/release creation have only run as dry runs or in local tests; the first real runs will need small fixes.
- **Runner:** `xcode-27` (macOS 27, Xcode 27) is a preview image; switch with `PICKUP_MACOS_RUNNER` when needed.
- **UI tests are a local gate** (R2); the CI job is opt-in and may not fail the build until the runner's
  Accessibility permission is proven.
- **corepack:** pnpm comes from the corepack bundled with the runner's Node (22/24). Node 25+ no longer bundles it;
  if a runner image drops it, `scripts/ci-setup-pnpm.sh` fails with a clear message.
- **Release PR freshness:** merging other pull requests while a release PR is open makes its changelog incomplete
  ("Require branches to be up to date" forces an update; re-run prepare-release instead of merging main into it).
- **Bluetooth entitlement:** omitted (Apple documents it only for the App Sandbox); verification step 4 confirms it.
- **Unsigned pre-releases** need "Open Anyway" in System Settings; they are not on Homebrew.
- **arm64 only.** No Intel build; the cask states it.
- **Expiring credentials:** `RELEASE_TOKEN` and `HOMEBREW_TAP_TOKEN` (1 year), Developer ID certificate (5 years),
  API key (until revoked). Rotate by replacing the environment secrets.
- **Unpinned CI tools:** swiftlint, gitleaks and semgrep come from Homebrew at their current versions.
