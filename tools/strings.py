#!/usr/bin/env python3
"""Sync app/Resources/{it,en}.lproj/Localizable.strings with the keys the compiler finds.

Run after `swift build` in app/ (touch the Swift files first so every file is recompiled):
    python3 tools/strings.py            # report missing English translations
    python3 tools/strings.py --write    # also rewrite both files (Italian = keys, English kept)
New English translations go in tools/strings_en_new.json ({"key": "translation"}) before --write.
"""
import glob, json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "app")
DATA = os.path.join(APP, ".build/out/Intermediates.noindex/Retroteca.build/Debug/Retroteca-p.build/Objects-normal/arm64/*.stringsdata")
LINE = re.compile(r'^"((?:[^"\\]|\\.)*)" = "((?:[^"\\]|\\.)*)";$')

def unescape(s): return s.replace('\\n', '\n').replace('\\"', '"').replace('\\\\', '\\')
def escape(s): return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')

def read(path):
    table = {}
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            m = LINE.match(line.strip())
            if m: table[unescape(m.group(1))] = unescape(m.group(2))
    return table

keys = set()
for f in glob.glob(DATA):
    for entries in json.load(open(f)).get("tables", {}).values():
        keys.update(e["key"] for e in entries)
if not keys: sys.exit("no .stringsdata found: build app/ first")

en_path = os.path.join(APP, "Resources/en.lproj/Localizable.strings")
en = read(en_path)
new_path = os.path.join(ROOT, "tools/strings_en_new.json")
if os.path.exists(new_path): en.update(json.load(open(new_path, encoding="utf-8")))

missing = sorted(k for k in keys if k not in en)
removed = sorted(k for k in en if k not in keys)
print(f"{len(keys)} keys · missing English: {len(missing)} · unused: {len(removed)}")
for k in missing: print("  missing:", json.dumps(k, ensure_ascii=False))
if "--write" in sys.argv:
    if missing: sys.exit("add the missing translations to tools/strings_en_new.json first")
    for lang, table in (("en", en), ("it", {k: k for k in keys})):
        with open(os.path.join(APP, f"Resources/{lang}.lproj/Localizable.strings"), "w", encoding="utf-8") as out:
            for k in sorted(keys): out.write(f'"{escape(k)}" = "{escape(table[k])}";\n')
    if os.path.exists(new_path): os.remove(new_path)
    print("written")
