---
name: fix-issue
description: Fix a GitHub issue of Pickup end to end - read it, reproduce it with a failing test, fix it, and open a pull request into main that says "Fixes #N". Use when given an issue number or URL.
---

# Fix an issue

1. **Read it:** `gh issue view <N> --comments`. Note the expected and the actual behaviour, macOS version and phone
   model. If it needs real hardware to reproduce (pairing, real calls), say so in the issue thread and ask the
   maintainer; never try hardware steps yourself.
2. **Branch:** `git switch main && git pull --ff-only && git switch -c fix/<N>-<short-slug>`.
3. **Reproduce with a test first.** Pick the lowest layer that shows the bug:
   - AT lines, call states, redaction, dialing rules → `Tests/PickupCoreTests` (scenario tests drive a scripted
     phone; fixtures replay real, already anonymised logs);
   - Bluetooth mapping → `Tests/PickupBluetoothTests` (fake links, no hardware);
   - app logic (contact search, keypad, number formatting) → `App/Tests/PickupAppTests`.
   Run it and see it fail: `swift test --filter <TestName>` (or `--package-path App`).
4. **Fix** with the smallest change that makes the test pass. Keep the rules in `CLAUDE.md` (no real personal data in
   tests, logs only through `DiagnosticLog`, no force unwraps of external data).
5. **Gate:** `scripts/verify.sh --quick`.
6. **Commit and open the pull request into main:**
   ```bash
   git commit -m "fix: <what the user sees, not the code>"
   git push -u origin HEAD
   gh pr create --base main --title "fix: <same subject>" --body "Fixes #<N>

   <cause in one or two sentences, how the test reproduces it>"
   ```
7. Do not merge. If the fix changes Bluetooth behaviour, add "needs hardware test" to the description.
