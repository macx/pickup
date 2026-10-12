#!/bin/bash
# Security and hygiene checks for Pickup (docs/TESTING.md, "Security").
#
#   scripts/security-checks.sh [--strict] [--app PATH] [--require-app] [--release]
#
#   --strict       a missing tool counts as a failure (also when CI is set). Without it: SKIPPED.
#   --app PATH     bundle to audit (default: App/.build/Pickup.app when it exists).
#   --require-app  fail if there is no built app to audit.
#   --release      the app must have the hardened runtime and must not be debuggable.
#
# Checks: entitlements (files and built app), codesign verification, no networking frameworks or
# symbols linked, no external Swift package dependencies, forbidden patterns in non-test code,
# real personal data in tracked files, gitleaks and semgrep when installed.
# Needs only tools that ship with macOS plus python3 (already used by check-localization.sh).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

STRICT=0; [ -n "${CI:-}" ] && STRICT=1
APP=""; REQUIRE_APP=0; RELEASE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1 ;;
    --app) APP="${2:?--app needs a path}"; shift ;;
    --require-app) REQUIRE_APP=1 ;;
    --release) RELEASE=1; REQUIRE_APP=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -z "$APP" ] && [ -d App/.build/Pickup.app ] && APP="App/.build/Pickup.app"

PASSED=0; FAILED=0; SKIPPED=0
pass() { PASSED=$((PASSED + 1)); echo "  ok       $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAILED   $1"; }
note() { echo "  note     $1"; }
skip() { # skip <what> <install hint>
  SKIPPED=$((SKIPPED + 1))
  echo "  SKIPPED (tool missing): $1: install with $2"
}
section() { echo; echo "== $1"; }
indent() { sed 's/^/             /'; }

# --- Source file sets -------------------------------------------------------------------------
# Non-test production code. Spike sources are throwaway tools and are only scanned for personal data.
prod_files() { find Sources App/Sources -name '*.swift' -not -path '*/.build/*' 2>/dev/null; }

# Allowlist for the pattern scan: "<path>|<substring of the line>|<reason>". Keep it short and justified.
ALLOWLIST=(
  "Sources/PickupCore/PhoneNumberRedaction.swift|try! NSRegularExpression|compile-time constant regex"
  "App/Sources/Pickup/CallHUDView.swift|.first!.0|key rows are a non-empty static table"
  "Sources/PickupCore/DiagnosticLog.swift|privacy: .public|the single place that writes to the unified log, after redaction"
)
allowed() { # allowed <file> <line text>
  local entry path needle
  for entry in "${ALLOWLIST[@]}"; do
    path="${entry%%|*}"; needle="${entry#*|}"; needle="${needle%%|*}"
    [ "$path" = "$1" ] && [[ "$2" == *"$needle"* ]] && return 0
  done
  return 1
}

# --- 1. Entitlements ---------------------------------------------------------------------------
section "Entitlements"
ALLOWED_KEYS="com.apple.security.app-sandbox com.apple.security.device.bluetooth com.apple.security.personal-information.addressbook"
audit_entitlements() { # audit_entitlements <label> <plist-xml-on-stdin>
  local label="$1" result
  result=$(python3 -I -c '
import plistlib, sys
allowed = set(sys.argv[1].split())
raw = sys.stdin.buffer.read()
data = plistlib.loads(raw) if raw.strip() else {}
extra = sorted(k for k in data if k not in allowed)
for k in extra: print("EXTRA " + k)
print("SANDBOX " + ("on" if data.get("com.apple.security.app-sandbox") else "off"))
print("DEBUGGABLE " + ("yes" if data.get("com.apple.security.get-task-allow") else "no"))
' "$ALLOWED_KEYS") || { fail "$label: entitlements unreadable"; return; }
  local extras; extras=$(echo "$result" | sed -n 's/^EXTRA //p' | tr '\n' ' ')
  if [ -n "$extras" ]; then fail "$label: forbidden entitlements: $extras"; else pass "$label: only Bluetooth and Contacts (plus the sandbox flag)"; fi
  note "$label: App Sandbox $(echo "$result" | sed -n 's/^SANDBOX //p')"
}
for file in App/Pickup.entitlements App/Pickup-NoSandbox.entitlements App/Pickup-Release.entitlements; do
  # shellcheck disable=SC2094 # audit_entitlements only reads the file
  if [ -f "$file" ]; then audit_entitlements "$file" < "$file"; else fail "$file is missing"; fi
done

if [ -n "$APP" ] && [ -d "$APP" ]; then
  built=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$APP")
  note "built app: $APP (built $built; rebuild with scripts/build-app.sh if the sources changed since)"
  audit_entitlements "built app" < <(codesign -d --entitlements - --xml "$APP" 2>/dev/null)
  if codesign --verify --strict --deep "$APP" 2>/dev/null; then pass "codesign --verify --strict --deep"; else fail "codesign --verify --strict --deep failed for $APP"; fi
  flags=$(codesign -dv "$APP" 2>&1 | sed -n 's/.*flags=\(0x[0-9a-f]*\)(\(.*\)).*/\1 \2/p')
  note "signature flags: ${flags:-unknown}"
  if [[ "$flags" == *runtime* ]]; then pass "hardened runtime enabled"
  elif [ "$RELEASE" = 1 ]; then fail "hardened runtime is not enabled (required for release)"
  else note "hardened runtime is not enabled"; fi
  debuggable=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -c "get-task-allow" || true)
  if [ "$RELEASE" = 1 ] && [ "${debuggable:-0}" != 0 ]; then fail "release build is debuggable (get-task-allow)"; fi

  section "Networking (linked frameworks and symbols)"
  binary=$(find "$APP/Contents/MacOS" -maxdepth 1 -type f 2>/dev/null | sort | head -1)
  if [ -n "$binary" ]; then
    bad_libs=$(otool -L "$binary" | grep -E "CFNetwork|Network\.framework|NetworkExtension|WebKit|MultipeerConnectivity|SystemConfiguration|CoreWLAN|libcurl" || true)
    if [ -n "$bad_libs" ]; then fail "networking frameworks linked: $(echo "$bad_libs" | tr -d '\t' | tr '\n' ';')"; else pass "no networking frameworks linked"; fi
    bad_syms=$(nm -u "$binary" 2>/dev/null | grep -E "NSURLSession|NSURLConnection|CFHTTP|CFStreamCreatePairWithSocket|_nw_connection|_nw_listener|_getaddrinfo|_gethostbyname|WKWebView" || true)
    if [ -n "$bad_syms" ]; then fail "networking symbols referenced: $(echo "$bad_syms" | tr -s ' \n' ' ')"; else pass "no networking symbols referenced"; fi
  else
    fail "no executable found in $APP"
  fi
else
  if [ "$REQUIRE_APP" = 1 ]; then fail "no built app to audit (run scripts/build-app.sh)"
  else note "no built app found: skipped codesign, hardened runtime and linked-library checks (run scripts/build-app.sh first)"; fi
fi

section "Networking (source)"
net_hits=$(prod_files | xargs grep -nE "URLSession|URLRequest|NWConnection|NWListener|NWPathMonitor|CFSocket|WKWebView|import Network\b|import WebKit|import CFNetwork" 2>/dev/null || true)
if [ -n "$net_hits" ]; then fail "networking API used in production code:"; indent <<< "$net_hits"; else pass "no networking API in production code"; fi

# --- 2. Dependencies ---------------------------------------------------------------------------
section "Dependencies"
dep_bad=0
for manifest in Package.swift App/Package.swift spikes/apple-hfp/Package.swift; do
  if grep -nE '\.package\((url|name:[^)]*url):' "$manifest" >/dev/null 2>&1 || grep -nE '\.package\(url' "$manifest" >/dev/null 2>&1; then
    fail "$manifest declares a remote package dependency"; dep_bad=1
  fi
done
for resolved in Package.resolved App/Package.resolved spikes/apple-hfp/Package.resolved; do
  if [ -f "$resolved" ] && python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if not d.get("pins") and not d.get("object",{}).get("pins") else 1)' "$resolved"; then :; elif [ -f "$resolved" ]; then
    fail "$resolved pins external packages"; dep_bad=1
  fi
done
[ "$dep_bad" = 0 ] && pass "no external package dependencies (path dependencies only)"

# --- 3. Forbidden patterns in production code --------------------------------------------------
section "Forbidden patterns in non-test code (Sources, App/Sources)"
scan() { # scan <label> <regex>
  local label="$1" regex="$2" hits="" line file text
  while IFS= read -r line; do
    file="${line%%:*}"; text="${line#*:*:}"
    # Comments and explicit swiftlint exceptions do not count.
    [[ "$text" =~ ^[[:space:]]*// ]] && continue
    [[ "$text" == *"swiftlint:disable"* ]] && continue
    allowed "$file" "$text" && continue
    hits+="             $line"$'\n'
  done < <(prod_files | xargs grep -nE "$regex" 2>/dev/null || true)
  if [ -n "$hits" ]; then fail "$label"; printf '%s' "$hits"; else pass "$label: none"; fi
}
scan "try!"                       'try!'
scan "fatalError / preconditionFailure" '(fatalError|preconditionFailure)\('
scan "force cast (as!)"           ' as! '
scan "NSLog / print / dump"       '(^|[^A-Za-z_.])(NSLog|print|debugPrint|dump)\('
scan "force unwrap of external data (URL(string:)!, Int(...)!, .first!, .last!, [..]!)" '(URL\(string:[^)]*\)!|Int\([^)]*\)!|Double\([^)]*\)!|\.(first|last)!|\.(first|last)\(where:[^)]*\)!|dictionary\[[^]]*\]!|json\[[^]]*\]!)'
scan "public os_log privacy (only DiagnosticLog may use privacy: .public, after redaction)" 'privacy: \.public'
# DiagnosticLog is the one place allowed to write to the unified log; it redacts first.
filtered=$(prod_files | grep -v "Sources/PickupCore/DiagnosticLog.swift" | xargs grep -nE 'Logger\(|os_log\(' 2>/dev/null || true)
if [ -n "$filtered" ]; then fail "direct unified-log use outside DiagnosticLog:"; indent <<< "$filtered"; else pass "unified log only via DiagnosticLog"; fi

# --- 4. Personal data --------------------------------------------------------------------------
section "Personal data in tracked and untracked files"
FILES=$(mktemp); trap 'rm -f "$FILES"' EXIT
{ git ls-files; git ls-files --others --exclude-standard; } 2>/dev/null | sort -u \
  | grep -vE '\.(png|jpg|jpeg|icns|car|wav|aiff|caf|pklg|btsnoop|pdf|zip|ico)$' > "$FILES"
# Allowed fictional data: documented placeholders and the canaries of the tests.
FICTIONAL='(0000|555|2345678|1234567|0000000|\+?49 ?30 ?0000|\+?4930000|0300000|\+?4940000|\+?49 ?40 ?0000|\+4930918273|030918273|\+12025550|555-?01[0-9]{2})'
scan_data() { # scan_data <label> <regex> [filter-out regex]
  local label="$1" regex="$2" skip="${3:-^$}" hits
  hits=$(xargs grep -nHIE "$regex" < "$FILES" 2>/dev/null | grep -vE "$skip" | grep -vE "scripts/security-checks\.sh|\.gitleaks\.toml" || true)
  if [ -n "$hits" ]; then fail "$label"; echo "$hits" | head -10 | cut -c1-160 | sed 's/^/             /'; else pass "$label: none"; fi
}
scan_data "Bluetooth addresses of the real phone (OUI c0-1c-6a)" '[Cc]0[-:][1][Cc][-:]6[Aa][-:][0-9A-Fa-f]{2}[-:][0-9A-Fa-f]{2}[-:][0-9A-Fa-f]{2}'
scan_data "mobile or international numbers that are not invented" '(\+49 ?1[5-7][0-9][ 0-9/-]{6,}|(^|[^0-9+])01[5-7][0-9][ /-]?[0-9]{6,8}([^0-9]|$)|\+(1|44|33|43|41)[ -]?[0-9]{3}[ -]?[0-9]{3}[ -]?[0-9]{3,4})' "$FICTIONAL"
DENYLIST_REGEX="$( [ -s scripts/personal-data-denylist ] && grep -vE '^[[:space:]]*(#|$)' scripts/personal-data-denylist | paste -sd'|' - )"
if [ -n "$DENYLIST_REGEX" ]; then scan_data "local denylist (scripts/personal-data-denylist, not committed)" "$DENYLIST_REGEX"; fi
[ -n "$DENYLIST_REGEX" ] || note "optional: put real names/numbers one per line (extended regex) into scripts/personal-data-denylist (git-ignored) to scan for them too"
home_hits=$(xargs grep -lI "/Users/[a-z]" < "$FILES" 2>/dev/null | grep -vE "security-checks\.sh|\.gitleaks" || true)
[ -n "$home_hits" ] && note "home directory paths (/Users/<name>) appear in: $(echo "$home_hits" | tr '\n' ' ')"

# --- 5. External scanners ----------------------------------------------------------------------
section "External scanners"
if command -v gitleaks >/dev/null 2>&1; then
  if gitleaks detect --no-banner --redact --config .gitleaks.toml >/dev/null 2>&1; then pass "gitleaks (history)"; else fail "gitleaks found leaks (run: gitleaks detect --redact --config .gitleaks.toml -v)"; fi
  if gitleaks detect --no-banner --redact --no-git --config .gitleaks.toml >/dev/null 2>&1; then pass "gitleaks (working tree)"; else fail "gitleaks found leaks in the working tree"; fi
else
  skip "gitleaks (secret scan)" "brew install gitleaks"
fi
if command -v semgrep >/dev/null 2>&1; then
  if semgrep scan --quiet --error --metrics off --disable-version-check --config scripts/semgrep/pickup.yml Sources App/Sources >/dev/null 2>&1; then pass "semgrep (local rules, offline)"; else fail "semgrep reported findings (run: semgrep scan --metrics off --config scripts/semgrep/pickup.yml Sources App/Sources)"; fi
else
  skip "semgrep (static analysis)" "brew install semgrep"
fi

# --- Summary -----------------------------------------------------------------------------------
echo
echo "Security checks: $PASSED passed, $FAILED failed, $SKIPPED skipped (tool missing)"
if [ "$FAILED" -gt 0 ]; then exit 1; fi
if [ "$SKIPPED" -gt 0 ] && [ "$STRICT" = 1 ]; then echo "strict mode: skipped checks count as failures"; exit 1; fi
exit 0
