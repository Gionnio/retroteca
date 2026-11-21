#!/bin/bash
# No games, firmware or keys in the repository, and none of the wording listed in dev/tools/legal-words.txt.
# Run by build_app.sh; exits non-zero when something is found.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0

# 1. Game, disc, BIOS, firmware and key files must never be tracked (.md is Markdown here, not Mega Drive).
EXT=$(python3 -c "import json;d=json.load(open('catalog/platforms.json'));print('|'.join(sorted({e for p in d['platforms'] for e in p.get('extensions',[])+p.get('shared',[]) if e not in ('zip','7z','m3u','cue','md')})))")
[ -n "$EXT" ] || { echo "❌ Could not read catalog/platforms.json"; exit 1; }
files=$(git ls-files | grep -iE "\.(${EXT}|bin|img|keys|key|pfx|p12|nca|ncz|pkg|rap|pup|bios)$" | grep -vE "^app/Tests/.*Fixtures/" || true)
if [ -n "$files" ]; then echo "❌ Game, BIOS, firmware or key files tracked:"; echo "$files"; fail=1; fi
named=$(git ls-files | grep -iE "(^|/)(bios|firmware|prod\.keys|title\.keys|scph[0-9]+)" || true)
if [ -n "$named" ]; then echo "❌ BIOS/firmware/key-looking files tracked:"; echo "$named"; fail=1; fi

# 2. Wording and sites that must never appear: the list is kept with the development documents (dev/, private).
WORDS_FILE="dev/tools/legal-words.txt"
if [ -f "$WORDS_FILE" ]; then
    WORDS=$(tr -d '\n' < "$WORDS_FILE")
    hits=$(git ls-files -co --exclude-standard | grep -vE "^dev/|\.(png|jpg|icns|webp)$" | xargs grep -nIiE "$WORDS" 2>/dev/null || true)
    if [ -n "$hits" ]; then echo "❌ Wording that must not be published:"; echo "$hits"; fail=1; fi
else
    echo "• Wording check skipped: $WORDS_FILE is not here"
fi

[ $fail = 0 ] && echo "✓ Legal check passed"
exit $fail
