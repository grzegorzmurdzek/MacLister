#!/usr/bin/env python3
"""Checks the Polish translation against the sources.

  python3 Tools/check_localization.py

Finds every user-visible English text in Sources/ (tr("…"), trCount("…"), SwiftUI Text/Button/Toggle/
Label/Section/TextField/Picker/Menu/help literals and the few helpers that take a LocalizedStringKey),
then reports texts that Support/pl.lproj does not translate and format-specifier mismatches.
Exit status 1 when something is missing.
"""
import glob, os, plistlib, re, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
lit = r'"((?:[^"\\\n]|\\.)*)"'
patterns = [
    re.compile(r'\btr(?:Count)?\(' + lit),
    re.compile(r'\b(?:Text|Button|Toggle|Label|Section|TextField|SecureField|Picker|Menu|GroupBox|stat)\(' + lit),
    re.compile(r'\.help\(' + lit),
]
# texts that are the same in both languages
SAME = {"OK", "Regex", "Folder", "Mission Control", "Spotlight", "port", "ext", "SFTP", "FTP", "Audio", "Video", "Server", "Servers"}

keys = set()
for path in glob.glob(os.path.join(root, "Sources/MacLister/**/*.swift"), recursive=True):
    name = os.path.basename(path)
    if name.startswith("SelfTest") or name in ("Localization.swift", "LocalizationAudit.swift", "PreviewRender.swift"):
        continue
    text = open(path, encoding="utf-8").read()
    for pattern in patterns:
        for m in pattern.finditer(text):
            key = m.group(1).replace('\\"', '"')
            if len(key) > 1 and re.search("[A-Za-z]", key) and "\\(" not in key:
                keys.add(key)

strings = {}
with open(os.path.join(root, "Support/pl.lproj/Localizable.strings"), encoding="utf-8") as f:
    for line in f:
        m = re.match(r'"(.*)" = "(.*)";$', line.strip())
        if m:
            strings[m.group(1).replace('\\"', '"').replace('\\\\', '\\')] = m.group(2)
with open(os.path.join(root, "Support/pl.lproj/Localizable.stringsdict"), "rb") as f:
    plurals = set(plistlib.load(f))

missing = sorted(k for k in keys if k not in strings and k not in plurals and k not in SAME)
spec = re.compile(r"%(?!%)[@d]")
bad = [k for k, v in strings.items() if sorted(spec.findall(k)) != sorted(spec.findall(v))]
unused = sorted(k for k in strings if k not in keys)

print(f"{len(keys)} texts in the sources, {len(strings)} translations, {len(plurals)} plural entries")
for title, items in (("Not translated", missing), ("Format mismatch", bad)):
    if items:
        print(f"\n{title}:")
        for k in items:
            print("  ", k)
if unused:
    print(f"\n{len(unused)} translations are not found as literals (fine for texts built at run time).")
sys.exit(1 if missing or bad else 0)
