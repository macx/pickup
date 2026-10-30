#!/bin/bash
# The local release gate (docs/TESTING.md). One command, fixed order, stops at the first failure.
#
#   scripts/verify.sh [--quick] [--strict] [--skip-ui] [--release] [--force] [--keep-going] [--verbose]
#
#   --quick       build + lint + localization + unit tests of the root and App packages + security checks.
#                 No spikes, no sanitizers, no stamp. For the edit-compile-test loop.
#   --strict      a missing tool (swiftlint, gitleaks, semgrep) fails the gate instead of printing
#                 SKIPPED. Also implied by CI=true.
#   --skip-ui     do not run the UI tests (ignored with --release once a UI test target exists).
#   --release     used by `scripts/build-app.sh release`: strictest mode, hardened-runtime audit,
#                 UI tests cannot be skipped once a target exists.
#   --force       ignore the stamp and run everything.
#   --keep-going  run every step even after a failure (the exit code is still non-zero).
#   --verbose     stream the output of every step instead of keeping it in .build/verify-logs/.
#
# Order: warnings-as-errors builds (root, App, spikes) -> lint -> localization -> unit/scenario/
# property tests (root, App, spikes) -> sanitizer runs (address, thread) -> security checks -> UI tests.
#
# On success (not with --quick) the git tree hash of the working directory is written to
# .build/verify-stamp. A later run on an identical tree prints "already verified" and exits 0, so
# build-app.sh does not repeat a passed gate. Details of the stamp: .build/verify-stamp.info.
#
# Each package builds in its own scratch directory (.build/verify, App/.build/verify, ...) so the gate
# never invalidates the incremental builds of `swift build` / `swift test` during development.
#
# Known sanitizer notes (see the end of this file for the full list):
#  - The thread sanitizer run covers the root package only; the App and spike packages touch AppKit and
#    IOBluetooth, which are not TSan-clean, and would only produce framework noise.
#  - Sanitizer runs need a fresh build (separate scratch directories .build/verify-asan, .build/verify-tsan).
# shellcheck disable=SC2329 # the step functions below are called indirectly through run_step
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

QUICK=0; STRICT=0; SKIP_UI=0; RELEASE=0; FORCE=0; KEEP_GOING=0; VERBOSE=0
[ -n "${CI:-}" ] && STRICT=1
for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1 ;;
    --strict) STRICT=1 ;;
    --skip-ui) SKIP_UI=1 ;;
    --release) RELEASE=1; STRICT=1 ;;
    --force) FORCE=1 ;;
    --keep-going) KEEP_GOING=1 ;;
    --verbose) VERBOSE=1 ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

mkdir -p .build/verify-logs
STAMP=".build/verify-stamp"
INFO=".build/verify-stamp.info"
WERROR=(-Xswiftc -warnings-as-errors)

# --- Tree hash of the working directory (tracked + untracked, minus ignored files) ---------------
# Uses a temporary index, so the real index and working tree are untouched (it does add blob
# objects to .git/objects, which is harmless).
tree_hash() {
  local index; index="$(mktemp -u "${TMPDIR:-/tmp}/pickup-index.XXXXXX")"
  cp "$(git rev-parse --git-path index)" "$index" 2>/dev/null || true
  GIT_INDEX_FILE="$index" git add -A . >/dev/null 2>&1
  GIT_INDEX_FILE="$index" git write-tree 2>/dev/null
  rm -f "$index"
}
TREE="$(tree_hash)"
if [ -z "$TREE" ]; then echo "verify: cannot compute the git tree hash (not a git repository?)" >&2; exit 2; fi

info_value() { sed -n "s/^$1=//p" "$INFO" 2>/dev/null | head -1; }
if [ "$FORCE" = 0 ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$TREE" ]; then
  stamp_quick=$(info_value quick); stamp_skip_ui=$(info_value skip_ui); stamp_strict=$(info_value strict)
  if [ "${stamp_quick:-1}" = 0 ] \
     && { [ "${stamp_skip_ui:-1}" = 0 ] || [ "$SKIP_UI" = 1 ] && [ "$RELEASE" = 0 ]; } \
     && [ "${stamp_strict:-0}" -ge "$STRICT" ]; then
    echo "verify: tree $TREE already verified ($(info_value date)); nothing to do (use --force to run again)."
    exit 0
  fi
fi

# --- Step runner --------------------------------------------------------------------------------
RESULTS=()   # "status|name|seconds|note"
FAILED=0
GATE_START=$SECONDS

record() { RESULTS+=("$1|$2|$3|${4:-}"); }

run_step() { # run_step <name> <command...>
  local name="$1"; shift
  local log
  log=".build/verify-logs/$(echo "$name" | tr -c 'A-Za-z0-9\n' '-').log"
  echo "==> $name"
  local start=$SECONDS rc=0
  if [ "$VERBOSE" = 1 ]; then "$@" 2>&1 | tee "$log"; rc=${PIPESTATUS[0]}; else "$@" >"$log" 2>&1; rc=$?; fi
  local took=$((SECONDS - start))
  if [ "$rc" = 0 ]; then
    record PASS "$name" "$took"; echo "    passed (${took}s)"
  else
    record FAIL "$name" "$took" "see $log"; FAILED=1
    echo "    FAILED (${took}s), last lines of $log:"; tail -n 25 "$log" | sed 's/^/    | /'
    if [ "$KEEP_GOING" = 0 ]; then summary; echo "verify: FAILED"; exit 1; fi
  fi
}

skip_step() { # skip_step <name> <reason> [fails-in-strict]
  record SKIP "$1" 0 "$2"
  echo "==> $1"; echo "    SKIPPED: $2"
  if [ "${3:-}" = strict ] && [ "$STRICT" = 1 ]; then
    record FAIL "$1 (strict)" 0 "skipped step is a failure in strict mode"; FAILED=1
    if [ "$KEEP_GOING" = 0 ]; then summary; echo "verify: FAILED"; exit 1; fi
  fi
}

summary() {
  echo
  echo "---------------------------------------------------------------------"
  printf '%-6s %-44s %6s  %s\n' RESULT STEP SECONDS NOTE
  local entry
  for entry in "${RESULTS[@]}"; do
    IFS='|' read -r status name secs note <<<"$entry"
    printf '%-6s %-44s %6s  %s\n' "$status" "$name" "$secs" "$note"
  done
  echo "---------------------------------------------------------------------"
  echo "total $((SECONDS - GATE_START)) s, tree $TREE"
}

# --- Steps ---------------------------------------------------------------------------------------
build_root()   { swift build --build-tests --scratch-path .build/verify "${WERROR[@]}"; }
build_app()    { swift build --build-tests --package-path App --scratch-path App/.build/verify "${WERROR[@]}"; }
build_spikes() { swift build --build-tests --package-path spikes/apple-hfp --scratch-path spikes/apple-hfp/.build/verify "${WERROR[@]}"; }
test_root()    { swift test --skip-build --scratch-path .build/verify "${WERROR[@]}"; }
test_app()     { swift test --skip-build --package-path App --scratch-path App/.build/verify "${WERROR[@]}"; }
test_spikes()  { swift test --skip-build --package-path spikes/apple-hfp --scratch-path spikes/apple-hfp/.build/verify "${WERROR[@]}"; }
asan_root()    { swift test --sanitize=address --scratch-path .build/verify-asan; }
asan_app()     { swift test --sanitize=address --package-path App --scratch-path App/.build/verify-asan; }
tsan_root()    { swift test --sanitize=thread --scratch-path .build/verify-tsan; }
# The built-app audit (codesign, hardened runtime, linked libraries) runs on whatever bundle exists; for
# "release" build-app.sh audits the fresh bundle again with --release after it was built.
security()     { if [ "$STRICT" = 1 ]; then scripts/security-checks.sh --strict; else scripts/security-checks.sh; fi; }

lint() {
  # Always --strict, like CI: a warning that passes here but fails the pull request helps nobody.
  swiftlint lint --config .swiftlint.yml --quiet --strict
}

# UI tests: the XCUITest target does not exist yet (round 2). Detected by its directory.
UI_DIR="App/Tests/PickupUITests"
run_ui() {
  if [ -x scripts/run-ui-tests.sh ]; then scripts/run-ui-tests.sh; else echo "UI test target exists but scripts/run-ui-tests.sh is missing"; return 1; fi
}

echo "verify: tree $TREE, mode:$([ "$QUICK" = 1 ] && echo " quick")$([ "$STRICT" = 1 ] && echo " strict")$([ "$RELEASE" = 1 ] && echo " release")$([ "$SKIP_UI" = 1 ] && echo " skip-ui")$([ "$QUICK$STRICT$RELEASE$SKIP_UI" = 0000 ] && echo " full")"
echo

run_step "build root (warnings as errors)" build_root
run_step "build App (warnings as errors)" build_app
# The spikes exist only in the workshop repository (pickup-dev), not in the public export.
HAS_SPIKES=0; [ -f spikes/apple-hfp/Package.swift ] && HAS_SPIKES=1
if [ "$HAS_SPIKES" = 0 ]; then skip_step "build spikes" "no spikes/ in this repository"
elif [ "$QUICK" = 0 ]; then run_step "build spikes (warnings as errors)" build_spikes
else skip_step "build spikes" "--quick"; fi

if command -v swiftlint >/dev/null 2>&1; then run_step "lint (swiftlint)" lint
else skip_step "lint (swiftlint)" "tool missing: install with brew install swiftlint" strict; fi

run_step "localization check" scripts/check-localization.sh

run_step "tests root (core, bluetooth)" test_root
run_step "tests App" test_app
if [ "$HAS_SPIKES" = 0 ]; then skip_step "tests spikes" "no spikes/ in this repository"
elif [ "$QUICK" = 0 ]; then run_step "tests spikes" test_spikes
else skip_step "tests spikes" "--quick"; fi

if [ "$QUICK" = 0 ]; then
  run_step "sanitizer: address (root)" asan_root
  run_step "sanitizer: address (App)" asan_app
  run_step "sanitizer: thread (root)" tsan_root
else
  skip_step "sanitizers (address, thread)" "--quick"
fi

run_step "security checks" security

if [ ! -d "$UI_DIR" ]; then
  msg="no UI test target yet ($UI_DIR missing; XCUITest arrives in round 2)"
  [ "$RELEASE" = 1 ] && msg="$msg -- LOUD: a release gate must not skip UI tests once the target exists"
  skip_step "UI tests (XCUITest)" "$msg"
elif [ "$SKIP_UI" = 1 ] && [ "$RELEASE" = 0 ]; then
  skip_step "UI tests (XCUITest)" "--skip-ui"
elif [ "$QUICK" = 1 ]; then
  skip_step "UI tests (XCUITest)" "--quick"
else
  run_step "UI tests (XCUITest)" run_ui
fi

summary
if [ "$FAILED" != 0 ]; then echo "verify: FAILED"; exit 1; fi

if [ "$QUICK" = 1 ]; then
  echo "verify: quick run passed (no stamp written)"
else
  printf '%s\n' "$TREE" > "$STAMP"
  {
    echo "date=$(date '+%Y-%m-%d %H:%M:%S')"; echo "quick=0"; echo "skip_ui=$SKIP_UI"; echo "strict=$STRICT"; echo "release=$RELEASE"
    printf '%s\n' "${RESULTS[@]}" | sed 's/^/step=/'
  } > "$INFO"
  echo "verify: PASSED, stamp written to $STAMP"
fi
exit 0
