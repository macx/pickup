# Developing Pickup

How to build, test and release Pickup. For what Pickup does, see the [README](../README.md). Contribution rules are in [`CLAUDE.md`](../CLAUDE.md) (also written for AI-assisted contributions) and in the pull request template.

## Prerequisites

Pickup targets **macOS 26 or newer** on Apple Silicon.

1. **Xcode 27** (the full app, not only the command line tools) from the App Store or <https://developer.apple.com/download/>. Select it with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` and accept the licence once (`sudo xcodebuild -license accept`). Check with `swift --version` (Swift 6.4 or newer).
2. **[Homebrew](https://brew.sh)** and the tools of the quality gate:

   ```bash
   brew install swiftlint gitleaks semgrep shellcheck actionlint
   ```

   | Tool | Used for |
   |---|---|
   | `swiftlint` | Style and safety lint (`.swiftlint.yml`) |
   | `gitleaks` | Secret scan of the working tree and history (`.gitleaks.toml`) |
   | `semgrep` | Static security rules (local rules under `scripts/semgrep/`, no network needed) |
   | `shellcheck`, `actionlint` | Linting of the scripts and the GitHub workflows |

   Without them the gate prints `SKIPPED (tool missing)` for those steps. In `--strict` mode and in CI a missing tool fails the gate, and `release` builds always require them.
3. For the **UI tests** the test runner needs the *Accessibility* permission (System Settings > Privacy & Security > Accessibility). The tests take over mouse and keyboard for about two minutes, so do not use the Mac while they run.
4. For release tooling only: **Node.js 22.22+ or 24** and **pnpm** (`brew install pnpm`; the version is pinned in `package.json`), then `pnpm install --frozen-lockfile`. The app itself has no runtime dependencies and uses no third-party packages.
5. To try it with real calls: an Android phone paired with the Mac over Bluetooth. On the phone, allow *Phone calls* for the Mac in the paired device's settings.

## Build, test, run

```bash
# Unit, scenario and fuzz tests
swift test                              # core and Bluetooth packages (repository root)
swift test --package-path App           # app logic

# The whole gate: warnings-as-errors builds, lint, localization, tests, sanitizers, security checks, UI tests
scripts/verify.sh                       # --quick for the edit-compile-test loop, --strict to fail on missing tools

# Build the app (runs the gate first; fails if it does not pass)
PICKUP_NO_SANDBOX=1 scripts/build-app.sh     # development build without the App Sandbox
open App/.build/Pickup.app
```

- `scripts/build-app.sh` only produces `Pickup.app` after `scripts/verify.sh` passed for the current source tree. `PICKUP_SKIP_VERIFY=1` skips the gate for quick local builds (with a warning); it is ignored for `scripts/build-app.sh release`.
- `PICKUP_NO_SANDBOX=1` is needed for *Make Pickup the default for phone links*, because that call fails inside the App Sandbox.
- Tests never touch Bluetooth or your real contacts. A scripted phone drives complete call scenarios.
- The test pyramid, the security checks and the CI/CD: [`TESTING.md`](TESTING.md).
- Releases (versioning with release-it, Developer ID signing, notarisation, DMG/ZIP, Homebrew tap): [`RELEASING.md`](RELEASING.md). Unsigned local test: `PICKUP_SKIP_VERIFY=1 scripts/package-release.sh --dry-run`.
- App logs: `~/Library/Logs/Pickup/` (sandboxed builds: `~/Library/Containers/dev.eiken.pickup/Data/Library/Logs/Pickup/`). Phone numbers and contact names are redacted in the logs.
- Icon and brand assets: [`ICON.md`](ICON.md), [`brand/`](brand/).

## Layout

| Path | Contents |
|---|---|
| `Sources/PickupCore` | Platform-neutral core: AT parser, `CallEngine`, transport protocol, redaction (no Bluetooth, testable) |
| `Sources/PickupBluetooth` | `AppleHFPTransport` on `IOBluetoothHandsFreeDevice` |
| `App/` | The menu bar app (SwiftUI/AppKit), String Catalog, icon, app tests, UI tests |
| `Tests/` | Unit, scenario, fuzz and log-canary tests for the core and Bluetooth packages |
| `scripts/` | `verify.sh` (quality gate), `build-app.sh`, `security-checks.sh`, localization check, release scripts |
| `packaging/homebrew/` | Homebrew cask template and the tap repository's README and CI |
| `.github/workflows/` | CI and release workflows |
| `docs/` | Testing, releasing, icon and brand documentation, screenshots |
