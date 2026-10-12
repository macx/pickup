#!/bin/bash
# Fails if a String Catalog key lacks a translated German (or English) value, or if a localizable
# string in App/Sources has no key in Localizable.xcstrings.
# Extraction uses the Swift compiler itself (-emit-localized-strings, exact: Text("…"), LocalizedStringKey,
# String(localized:) …). If that build fails, a regex scan of the sources is used as a fallback.
set -euo pipefail
cd "$(dirname "$0")/.."
STRINGS_DIR="$(pwd)/App/.build/l10n-strings"
rm -rf "$STRINGS_DIR" "$(pwd)/App/.build/l10n-build"; mkdir -p "$STRINGS_DIR"   # clean build: strings are emitted only when files compile
if swift build --package-path App --scratch-path "$(pwd)/App/.build/l10n-build" \
     -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$STRINGS_DIR" >/dev/null 2>&1; then
  export L10N_STRINGS_DIR="$STRINGS_DIR"
else
  echo "warning: compiler string extraction failed; falling back to regex scan" >&2
fi
python3 -I - App/Resources/*.xcstrings <<'PY'
import glob, re, os, json as _json
import json, sys
LANGS = ["en", "de"]
bad = 0
for path in sys.argv[1:]:
    data = json.load(open(path, encoding="utf-8"))
    for key, entry in data["strings"].items():
        if entry.get("shouldTranslate") is False:
            continue
        locs = entry.get("localizations", {})
        for lang in LANGS:
            unit = locs.get(lang, {}).get("stringUnit")
            if not unit or unit.get("state") != "translated" or not unit.get("value", "").strip():
                print(f"{path}: '{key}' has no translated '{lang}' value"); bad += 1
        if not entry.get("comment"):
            print(f"{path}: '{key}' has no translator comment"); bad += 1
        # placeholders must match between languages
        import re
        ph = lambda l: sorted(re.findall(r"%(?:\d+\$)?[@dfsl]+", locs.get(l, {}).get("stringUnit", {}).get("value", "")))
        if ph("en") != ph("de"):
            print(f"{path}: '{key}' placeholder mismatch between en and de"); bad += 1

# --- literals in code must exist in Localizable.xcstrings ---
def norm(k): return re.sub(r"%(?:\d+\$)?(?:l+)?[@dfsu]", "%@", k)
catalog = {norm(k) for k in json.load(open("App/Resources/Localizable.xcstrings", encoding="utf-8"))["strings"]}
strings_dir = os.environ.get("L10N_STRINGS_DIR")
if strings_dir:
    used = set()
    for f in glob.glob(strings_dir + "/*.stringsdata"):
        data = _json.load(open(f, encoding="utf-8"))
        if "/App/Sources/" not in data.get("source", ""): continue
        for entry in data.get("tables", {}).get("Localizable", []):
            used.add(norm(entry["key"]))
            if norm(entry["key"]) not in catalog:
                loc = entry.get("location", {})
                print(f"{data['source']}:{loc.get('startingLine', '?')}: '{entry['key']}' is not in Localizable.xcstrings"); bad += 1
    for key in sorted(catalog - used):
        print(f"note: catalog key not used by any source (stale?): '{key}'")
    if used:
        sys.exit(1 if bad else 0)
    print("warning: no strings extracted; falling back to regex scan")
# --- fallback: regex scan ---
def norm(k): return re.sub(r"%(?:\d+\$)?(?:l+)?[@dfsu]", "%@", k)
catalog = {norm(k) for k in json.load(open("App/Resources/Localizable.xcstrings", encoding="utf-8"))["strings"]}
CALL = re.compile(r'(?:\b(?:Text|Label|Button|Toggle|Picker|Section|Menu|LabeledContent|TextField|caption|hintLine|accessibilityLabel|accessibilityHint|help|navigationTitle)\(|\bString\(localized:\s*|\b(?:title|accessibilityLabel|prompt|hint):\s*)"')
def literal_at(src, i):
    out, depth = [], 0
    while i < len(src):
        c = src[i]
        if c == "\\" and src[i+1:i+2] == "(":
            depth, j = 1, i + 2
            while j < len(src) and depth:
                depth += {"(": 1, ")": -1}.get(src[j], 0); j += 1
            out.append("%@"); i = j; continue
        if c == "\\": out.append(src[i:i+2]); i += 2; continue
        if c == '"': return "".join(out)
        out.append(c); i += 1
    return None
for path in sorted(glob.glob("App/Sources/**/*.swift", recursive=True)):
    src = open(path, encoding="utf-8").read()
    for m in CALL.finditer(src):
        if src[max(0, m.start()-12):m.start()].endswith("verbatim"): continue
        key = literal_at(src, m.end())
        if key is None or key == "": continue
        key = key.replace('\\"', '"').replace("\\n", "\n")
        if norm(key) not in catalog:
            line = src.count("\n", 0, m.start()) + 1
            print(f"{path}:{line}: '{key}' is not in Localizable.xcstrings"); bad += 1
sys.exit(1 if bad else 0)
PY
echo "Localization check passed."
