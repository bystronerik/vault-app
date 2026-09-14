#!/usr/bin/env python3
"""Check CalculatorVault/Localizable.xcstrings against the Swift code. Run it after the build-for-testing step of lefthook.yml."""
import glob, json, os, re, sys

errors = []


def no_duplicates(pairs):
    keys = [k for k, _ in pairs]
    errors.extend(f"duplicate key: {k}" for k in {k for k in keys if keys.count(k) > 1})
    return dict(pairs)


strings = json.load(open("CalculatorVault/Localizable.xcstrings"), object_pairs_hook=no_duplicates)["strings"]
code = "\n".join(open(p).read() for p in glob.glob("CalculatorVault/**/*.swift", recursive=True))
used = set(re.findall(r"\.(\w+)", re.sub(r"//[^\n]*|/\*.*?\*/", "", code, flags=re.S)))  # Commented-out code does not count.
for key, entry in strings.items():
    en = entry.get("localizations", {}).get("en", {})
    if not re.fullmatch(r"[a-z][A-Za-z0-9]*(\.[a-z][A-Za-z0-9]*)+", key):
        errors.append(f"key is not dotted lowerCamelCase: {key}")
    elif re.sub(r"\.(\w)", lambda m: m[1].upper(), key) not in used:
        errors.append(f"key not used in code: {key}")
    if entry.get("extractionState") != "manual":
        errors.append(f'key does not have "extractionState" : "manual": {key}')
    if not (en.get("stringUnit", {}).get("value") or "variations" in en):
        errors.append(f"key has no en value: {key}")
    if not entry.get("comment"):
        errors.append(f"key has no comment: {key}")

# The compiler writes each localizable string literal (Text("..."), error = "...", and others) to a .stringsdata file.
for path in glob.glob("build/periphery/Build/Intermediates.noindex/CalculatorVault.build/*/CalculatorVault.build/Objects-normal/*/*.stringsdata"):
    data = json.load(open(path))
    if "/DerivedSources/" in data["source"] or not os.path.exists(data["source"]):
        continue
    for table in data["tables"].values():
        for e in table:
            errors.append(f'{data["source"]}:{e["location"]["startingLine"]}: string literal "{e["key"]}"; use a generated symbol')

for e in sorted(set(errors)):
    print(f"Localizable.xcstrings: {e}")
sys.exit(1 if errors else 0)
