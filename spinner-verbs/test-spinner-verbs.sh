#!/usr/bin/env bash
# Tests for spinner-verbs.py against a synthetic doc (never the real one: it is private).
# Ends with "N passed, 0 failed".
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SV="$HERE/spinner-verbs.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export SPINNER_VERBS_STATE="$T/state" SPINNER_VERBS_DOC=""
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

# The real export's quirks: BOM, CRLF, a stray first line, a duplicated contents number, an album
# with no separator before it (heading tab-indented after the previous track), a skipped track
# number, an empty track followed by an untabbed number, a multi-line title, a "*" footnote, curly
# quotes, and trailing empty slots in the open album.
printf '\xef\xbb\xbfjunk\r\nFirst Album        1\r\nSecond (Album)        2\r\nThird Album        2\r\nOpen Album        4\r\n' > "$T/doc.txt"
printf 'First Album\r\nTrack #\r\n\tTitle\r\n\t1\r\n\tThe Crypt\r\n\t2\r\n\t(Pew) Pew Pew\r\n\t4\r\n\tWise Cowardice\r\n\t________________\r\n' >> "$T/doc.txt"
printf 'Second (Album)\r\nTrack #\r\n\tTitle\r\n\t1\r\n\tA multi\r\n(line) title\r\n\t2\r\n\tSplit Caps*\r\n\t*a footnote\r\n\tThird Album\r\n' >> "$T/doc.txt"
printf 'Track #\r\n\tTitle\r\n\t1\r\n\tWe\xe2\x80\x99re Doing It\r\n\t2\r\n3\r\n\tAfter an empty one\r\n\t________________\r\n' >> "$T/doc.txt"
printf '\r\n\r\nOpen Album\r\n\r\n\r\nTrack #\r\n\tTitle\r\n\t1\r\n\tRefuriated beans\r\n\t2\r\n\t\r\n\r\n\t3\r\n\t\r\n' >> "$T/doc.txt"

out="$(python3 "$SV" fetch --file "$T/doc.txt" --json "$T/albums.json" 2>&1)"
check "fetch counts albums and songs" '[[ "$out" == *"4 albums, 8 songs"* ]]'
check "duplicate contents number kept" '[[ "$out" == *"  2  Third Album  (2 tracks)"* ]]'
check "open album's empty slots skipped" '[[ "$out" == *"Open Album  (1 tracks)"* ]]'
titles="$(python3 -c 'import json,sys; [print(t["track"], t["title"]) for a in json.load(open(sys.argv[1])) for t in a["tracks"]]' "$T/albums.json")"
check "skipped track number kept"        'grep -qx "4 Wise Cowardice" <<<"$titles"'
check "multi-line title joined"          'grep -qx "1 A multi (line) title" <<<"$titles"'
check "footnote dropped"                 'grep -qx "2 Split Caps\*" <<<"$titles"'
check "unseparated album not a title"    '! grep -q "Third Album" <<<"$titles"'
check "curly quote straightened"         'grep -qx "1 We'"'"'re Doing It" <<<"$titles"'
check "untabbed number after empty track" 'grep -qx "3 After an empty one" <<<"$titles"'

# A contents entry with no table is a loud failure that names it.
printf 'Lonely Album        5\r\n' > "$T/broken.txt"; cat "$T/doc.txt" >> "$T/broken.txt"
out="$(python3 "$SV" fetch --file "$T/broken.txt" 2>&1)"; rc=$?
check "missing album table fails" '[ $rc -ne 0 ] && [[ "$out" == *"Lonely Album"* && "$out" == *"fix:"* ]]'

# No doc configured: the error says how to configure one.
out="$(python3 "$SV" new 2>&1)"; rc=$?
check "no doc prints the fix" '[ $rc -ne 0 ] && [[ "$out" == *"config.json"* ]]'

# new: everything unreviewed, then only what the ledger lacks (matched case- and quote-insensitively).
out="$(python3 "$SV" new --file "$T/doc.txt" 2>&1)"
check "new lists all 12 entries" '[[ "$out" == *"12 unreviewed of 12"* ]]'
mkdir -p "$SPINNER_VERBS_STATE"
cat > "$SPINNER_VERBS_STATE/ledger.json" <<'EOF'
[{"album": "first album", "title": "(pew) pew pew", "verdict": "yes", "verb": "(Pew) Pew Pew'ing"},
 {"album": "Third Album", "title": "We’re doing it", "verdict": "proposed-yes", "verb": "Doing it"},
 {"album": "Open Album", "title": "Refuriated beans", "verdict": "yes", "verb": "Refuriating beans"},
 {"album": "Open Album", "title": "Refuriated beans (dup)", "verdict": "yes", "verb": "refuriating BEANS"},
 {"album": "Gone Album", "title": "Renamed since", "verdict": "no", "verb": ""}]
EOF
out="$(python3 "$SV" new --file "$T/doc.txt" 2>&1)"
check "new skips reviewed titles" '[[ "$out" == *"9 unreviewed of 12"* && "$out" != *"Pew"* ]]'
out="$(python3 "$SV" status --check-doc --file "$T/doc.txt" 2>&1)"
check "status flags titles gone from the doc" '[[ "$out" == *"no longer in doc (renamed or removed): Renamed since"* ]]'

out="$(python3 "$SV" new --record --file "$T/doc.txt" 2>&1)"
check "new --record keeps listing until judged" '[[ "$(python3 "$SV" new --file "$T/doc.txt" 2>&1)" == *"9 unreviewed of 12"* ]]'
python3 "$SV" set "a multi" proposed-no >/dev/null
check "a judged title leaves new" '[[ "$(python3 "$SV" new --file "$T/doc.txt" 2>&1)" == *"8 unreviewed of 12"* ]]'

# export: only "yes" by default, de-duplicated case-insensitively.
python3 "$SV" export --out "$T/verbs.json" >/dev/null
verbs_json() { python3 -c "import json,sys;print(json.dumps(json.load(open(sys.argv[1]))['verbs']))" "$1"; }
check "export keeps only yes, deduped" '[ "$(verbs_json "$T/verbs.json")" = "[\"(Pew) Pew Pew'"'"'ing\", \"Refuriating beans\"]" ]'
python3 "$SV" export --include-proposed --out "$T/preview.json" >/dev/null
check "export --include-proposed adds proposed-yes" 'grep -q "Doing it" "$T/preview.json"'

# apply: preserves other settings and other people's verbs, is idempotent, replaces its own old list.
echo '{"model": "opus", "spinnerVerbs": {"mode": "append", "verbs": ["Mine"]}}' > "$T/settings.json"
python3 "$SV" apply --no-extras --verbs "$T/verbs.json" --settings "$T/settings.json" --dry-run >/dev/null
check "dry run changes nothing" 'grep -q "\"Mine\"\]" "$T/settings.json"'
python3 "$SV" apply --no-extras --verbs "$T/verbs.json" --settings "$T/settings.json" >/dev/null
get() { python3 -c "import json;s=json.load(open('$T/settings.json'));print(s.get('model'), s['spinnerVerbs']['mode'], s['spinnerVerbs']['verbs'])"; }
check "apply merges and keeps other keys" '[ "$(get)" = "opus append ['"'"'Mine'"'"', \"(Pew) Pew Pew'"'"'ing...\", '"'"'Refuriating beans...'"'"']" ]'
out="$(python3 "$SV" apply --no-extras --verbs "$T/verbs.json" --settings "$T/settings.json")"
check "apply is idempotent" '[[ "$out" == *"spinnerVerbs already up to date"* ]]'
echo '{"verbs": ["Refuriating beans", "Wok n rolling"]}' > "$T/verbs2.json"
out="$(python3 "$SV" apply --no-extras --verbs "$T/verbs2.json" --settings "$T/settings.json")"
check "apply drops its own removed verb, keeps others" '[[ "$out" == *"- (Pew) Pew Pew'"'"'ing..."* && "$out" == *"+ Wok n rolling..."* ]] && [ "$(get)" = "opus append ['"'"'Mine'"'"', '"'"'Refuriating beans...'"'"', '"'"'Wok n rolling...'"'"']" ]'
# Every verb is written ending in three periods (Claude Code then adds no U+2026 of its own), and
# an apply from before that rule (bare verbs in applied.json) is replaced, not duplicated.
printf '{"verbs": ["Bare", "Dotted...", "Uni\\u2026", "\\"Mid...\\" quote"]}' > "$T/dots.json"
rm "$T/settings.json"
python3 "$SV" apply --no-extras --verbs "$T/dots.json" --settings "$T/settings.json" >/dev/null
check "apply ends every verb in three periods" '[ "$(get)" = "None append ['"'"'Bare...'"'"', '"'"'Dotted...'"'"', '"'"'Uni...'"'"', '"'"'\"Mid...\" quote...'"'"']" ]'
echo '{"spinnerVerbs": {"mode": "append", "verbs": ["Mine", "Bare", "Dotted..."]}}' > "$T/settings.json"
echo '["Bare", "Dotted..."]' > "$SPINNER_VERBS_STATE/applied.json"
python3 "$SV" apply --no-extras --verbs "$T/dots.json" --settings "$T/settings.json" >/dev/null
check "apply replaces an earlier bare apply" '[ "$(get)" = "None append ['"'"'Mine'"'"', '"'"'Bare...'"'"', '"'"'Dotted...'"'"', '"'"'Uni...'"'"', '"'"'\"Mid...\" quote...'"'"']" ]'
rm "$T/settings.json"
python3 "$SV" apply --no-extras --verbs "$T/verbs.json" --settings "$T/settings.json" >/dev/null
check "apply creates missing settings in append mode" '[[ "$(get)" == "None append "* ]]'

# The parser reports lines it drops instead of losing them silently.
out="$(python3 "$SV" fetch --file "$T/doc.txt" 2>&1)"
check "dropped footnote is reported" '[[ "$out" == *"ignored line"*"*a footnote"* ]]'

# set: by unique substring; ambiguous or unknown titles fail with the fix; a yes needs a verb.
out="$(python3 "$SV" set "suspicious" yes 2>&1)"; rc=$?
check "set with no match fails" '[ $rc -ne 0 ] && [[ "$out" == *"0 titles match"* && "$out" == *"fix:"* ]]'
out="$(python3 "$SV" set "refuriated" no 2>&1)"; rc=$?
check "set with two different matches fails" '[ $rc -ne 0 ] && [[ "$out" == *"2 titles match"* ]]'
python3 "$SV" set "we're doing it" yes --verb "Doing it (right?)" >/dev/null
check "set records verdict and verb" '[[ "$(python3 "$SV" list --verdict yes)" == *"Doing it (right?)"* ]]'
out="$(python3 "$SV" set "Renamed since" proposed-yes 2>&1)"; rc=$?
check "set refuses a yes-ish verdict without a verb" '[ $rc -ne 0 ] && [[ "$out" == *"--verb"* ]]'
python3 - "$SPINNER_VERBS_STATE/ledger.json" <<'PY'
import json, sys; L = json.load(open(sys.argv[1])); L[0]["verdict"] = "yess"; json.dump(L, open(sys.argv[1], "w"))
PY
check "status flags an invalid verdict" '[[ "$(python3 "$SV" status)" == *"INVALID verdict '"'"'yess'"'"'"* ]]'

# Blocked words: profanity built in (substring), private names from config.json (whole words).
python3 - "$SPINNER_VERBS_STATE/ledger.json" <<'PY'
import json, sys; L = json.load(open(sys.argv[1])); L[0]["verdict"] = "yes"; json.dump(L, open(sys.argv[1], "w"))
PY
echo '{"blocked_words": ["Bob"]}' > "$SPINNER_VERBS_STATE/config.json"
out="$(python3 "$SV" set "a multi" yes --verb "Fuckin' it up" 2>&1)"; rc=$?
check "set refuses profanity" '[ $rc -ne 0 ] && [[ "$out" == *"blocked word"* ]]'
out="$(python3 "$SV" set "a multi" yes --verb "Asking Bob" 2>&1)"; rc=$?
check "set refuses a private blocked name" '[ $rc -ne 0 ] && [[ "$out" == *"Bob"* ]]'
python3 "$SV" set "a multi" yes --verb "Bobbing along, damn it" >/dev/null
check "whole-word names only; damn is fine" '[[ "$(python3 "$SV" list --verdict yes)" == *"Bobbing along, damn it"* ]]'
python3 - "$SPINNER_VERBS_STATE/ledger.json" <<'PY'
import json, sys; L = json.load(open(sys.argv[1])); L[0]["verb"] = "Holy shitballs"; json.dump(L, open(sys.argv[1], "w"))
PY
out="$(python3 "$SV" export --out "$T/x.json" 2>&1)"; rc=$?
check "export refuses a hand-edited blocked verb" '[ $rc -ne 0 ] && [[ "$out" == *"shitballs"* && ! -e "$T/x.json" ]]'

# apply: a missing verbs file prints the fix; "replace" mode becomes "append"; a symlinked
# settings.json stays a symlink with its mode.
out="$(python3 "$SV" apply --no-extras --verbs "$T/nope.json" --settings "$T/settings.json" 2>&1)"; rc=$?
check "apply without verbs file prints the fix" '[ $rc -ne 0 ] && [[ "$out" == *"export"* ]]'
echo '{"spinnerVerbs": {"mode": "replace", "verbs": ["Mine"]}}' > "$T/real-settings.json"
chmod 640 "$T/real-settings.json"; ln -s "$T/real-settings.json" "$T/link-settings.json"
python3 "$SV" apply --no-extras --verbs "$T/verbs.json" --settings "$T/link-settings.json" >/dev/null
check "apply forces append mode" 'grep -q "\"append\"" "$T/real-settings.json"'
check "apply keeps a symlinked settings.json linked" '[ -L "$T/link-settings.json" ]'
check "apply keeps the settings file mode" '[ "$(stat -c %a "$T/real-settings.json")" = 640 ]'

# extras: verb tables from another list, downloaded at apply time; phrases refused; non-verbs skipped.
cat > "$T/extras-src.md" <<'EOF2'
### Movie Things (6)
| Verb |
|------|
| Abiding |
| Tying the room together |
| The dude abides. |
| Someone has been chasing this pointer for days |
| Not expecting the Spanish Inquisition |
| Not golfing |
### Movie Things Phrases (1)
| Phrase |
|---|
| This aggression will not stand |
### Other (1)
| Refuriating beans |
EOF2
printf '{"source": "file://%s", "categories": ["Movie Things", "Other"]}' "$T/extras-src.md" > "$T/extras.json"
out="$(python3 "$SV" extras --extras "$T/extras.json" 2>&1)"
check "extras parses verbs, skips a sentence" '[[ "$out" == *"5 extra verbs from 2 categories"* && "$out" == *"skipped '"'"'Someone has been chasing"* && "$out" == *"skipped '"'"'The dude abides.'"'"'"* ]]'
echo '{"verbs": ["Refuriating beans"]}' > "$T/dsk.json"
python3 "$SV" apply --verbs "$T/dsk.json" --extras "$T/extras.json" --settings "$T/ex-settings.json" >/dev/null
check "apply adds extras after DSK, deduped" '[ "$(python3 -c "import json;print(json.load(open(\"$T/ex-settings.json\"))[\"spinnerVerbs\"][\"verbs\"])")" = "['"'"'Refuriating beans...'"'"', '"'"'Abiding...'"'"', '"'"'Tying the room together...'"'"', '"'"'Not expecting the Spanish Inquisition...'"'"', '"'"'Not golfing...'"'"']" ]'
printf '{"source": "file://%s", "categories": ["Movie Things"], "exclude": ["not golfing"]}' "$T/extras-src.md" > "$T/extras-ex.json"
check "extras exclude list drops an entry" '[[ "$(python3 "$SV" extras -v --extras "$T/extras-ex.json" 2>&1)" != *"Not golfing"* ]]'
printf '{"source": "file://%s", "categories": ["Movie Things Phrases"]}' "$T/extras-src.md" > "$T/extras-bad.json"
out="$(python3 "$SV" extras --extras "$T/extras-bad.json" 2>&1)"; rc=$?
check "a phrases category is refused with the fix" '[ $rc -ne 0 ] && [[ "$out" == *"use the verb category"* ]]'
printf '{"source": "file://%s", "categories": ["Movie Thingz"]}' "$T/extras-src.md" > "$T/extras-bad.json"
out="$(python3 "$SV" extras --extras "$T/extras-bad.json" 2>&1)"; rc=$?
check "an unknown category is refused, naming close ones" '[ $rc -ne 0 ] && [[ "$out" == *"not found"* && "$out" == *"Movie Things"* ]]'

# lint: Eli's edit rules. Inflections pass; rewording, reordering, agent nouns, lost capitals flag.
cat > "$SPINNER_VERBS_STATE/ledger.json" <<'EOF2'
[{"album": "x", "title": "Make it Tso", "verdict": "yes", "verb": "Making it Tso", "why": ""},
 {"album": "x", "title": "Refuriated beans", "verdict": "yes", "verb": "Refuriating beans", "why": ""},
 {"album": "x", "title": "Do the Google Thing", "verdict": "yes", "verb": "Doing the Google thing", "why": ""},
 {"album": "x", "title": "Glitch neglect", "verdict": "yes", "verb": "Neglecting glitches", "why": ""},
 {"album": "x", "title": "Transcendental Number Pusher", "verdict": "yes", "verb": "Pushing transcendental numbers", "why": ""},
 {"album": "x", "title": "Boom goes the JIRA sledgehammer", "verdict": "yes", "verb": "Swinging the JIRA sledgehammer", "why": ""},
 {"album": "x", "title": "Better off (Deal with it!)", "verdict": "yes", "verb": "Being better off (deal with it!)", "why": ""},
 {"album": "x", "title": "Value Add", "verdict": "yes", "verb": "Something else entirely", "why": "Eli's edit"}]
EOF2
out="$(python3 "$SV" lint 2>&1)"
check "lint passes inflections" '[[ "$out" != *"Making it Tso"* && "$out" != *"Refuriating"* && "$out" != *"Google"* ]]'
check "lint flags a reordered noun phrase" '[[ "$out" == *"Neglecting glitches"*"reordered"* ]]'
check "lint flags an agent noun made a verb" '[[ "$out" == *"agent noun '"'"'Pusher'"'"'"* ]]'
check "lint flags dropped title words" '[[ "$out" == *"dropped: Boom, goes"* ]]'
check "lint flags a lost parenthetical capital" '[[ "$out" == *"(deal with it!)"*"lost its capital"* ]]'
python3 - "$SPINNER_VERBS_STATE/ledger.json" <<'PY'
import json, sys; L = json.load(open(sys.argv[1]))
L.append({"album": "x", "title": "In your spare time", "verdict": "yes", "verb": "Doing it in your spare time", "why": ""})
json.dump(L, open(sys.argv[1], "w"))
PY
out="$(python3 "$SV" lint 2>&1)"
check "lint flags you/your for the perspective rule" '[[ "$out" == *"in your spare time"*"contains you/your"* ]]'
check "lint skips verbs Eli wrote" '[[ "$out" != *"Something else"* ]]'

# Adapted categories: reworded entries come from the private adaptations file; proposed ones stay out.
printf '{"source": "file://%s", "categories": ["Other"], "adapted_categories": ["Movie Things Phrases"]}' "$T/extras-src.md" > "$T/extras-ad.json"
out="$(python3 "$SV" extras --extras "$T/extras-ad.json" 2>&1)"
check "without private rewordings, an adapted category is skipped with a note" '[[ "$out" == *"rewordings are private"* && "$out" == *"1 extra verbs"* ]]'
echo '{"Movie Things Phrases": {}}' > "$SPINNER_VERBS_STATE/adaptations.json"
out="$(python3 "$SV" extras --extras "$T/extras-ad.json" 2>&1)"
check "undecided entries are pending, not added" '[[ "$out" == *"1 entries in adapted category"* && "$out" == *"1 extra verbs"* ]]'
echo '{"Movie Things Phrases": {"_status": "proposed", "This aggression will not stand": "Not letting this aggression stand"}}' > "$SPINNER_VERBS_STATE/adaptations.json"
out="$(python3 "$SV" extras -v --extras "$T/extras-ad.json" 2>&1)"
check "a proposed adapted category stays out" '[[ "$out" == *"still proposed"* && "$out" != *"Not letting"* ]]'
echo '{"Movie Things Phrases": {"This aggression will not stand": "Not letting this aggression stand"}}' > "$SPINNER_VERBS_STATE/adaptations.json"
out="$(python3 "$SV" extras -v --extras "$T/extras-ad.json" 2>&1)"
check "an approved adaptation is used" '[[ "$out" == *"Not letting this aggression stand"* && "$out" == *"2 extra verbs"* ]]'

# builtins: a snapshot of Claude Code's own verbs, read from its executable, switches apply to
# replace mode with that copy first; all end in three periods; a custom verb already built in is
# not repeated; without a snapshot apply appends (checked above).
printf 'junk\0function c(){let o=R().spinnerVerbs;if(!o)return b;return[...b,...o.verbs]}var b=["Baking","Beboppin%s","Flamb\\xE9ing",%s];more' "'" "$(printf '"V%s",' $(seq 1 20) | sed 's/,$//')" > "$T/claude-9.9.9"
out="$(python3 "$SV" builtins)"
check "builtins without a snapshot says apply appends" '[[ "$out" == *"no snapshot"* ]]'
out="$(python3 "$SV" builtins --snapshot --binary "$T/claude-9.9.9")"
check "builtins --snapshot reads the list from the executable" '[[ "$out" == "23 built-in verbs"* ]] && [[ "$(python3 "$SV" builtins)" == *"23 built-in verbs from Claude Code claude-9.9.9"* ]]'
echo '{"verbs": ["Refuriating beans", "baking"]}' > "$T/b-verbs.json"
echo '{"spinnerVerbs": {"mode": "append", "verbs": ["Mine"]}}' > "$T/b-settings.json"
out="$(python3 "$SV" apply --no-extras --verbs "$T/b-verbs.json" --settings "$T/b-settings.json")"
bget() { python3 -c "import json;s=json.load(open('$T/b-settings.json'))['spinnerVerbs'];v=s['verbs'];print(s['mode'], len(v), v[:4], v[-1], all(x.endswith('...') for x in v[1:]))"; }
check "apply with a snapshot replaces the built-ins with the dotted copy" '[ "$(bget)" = "replace 25 ['"'"'Mine'"'"', '"'"'Baking...'"'"', \"Beboppin'"'"'...\", '"'"'Flambéing...'"'"'] Refuriating beans... True" ] && [[ "$out" == *"1 already built in"* ]]'
out="$(python3 "$SV" apply --no-extras --verbs "$T/b-verbs.json" --settings "$T/b-settings.json")"
check "apply with a snapshot is idempotent" '[[ "$out" == *"already up to date"* ]]'
echo 'nothing here' > "$T/claude-0"
out="$(python3 "$SV" builtins --snapshot --binary "$T/claude-0" 2>&1)"; rc=$?
check "builtins --snapshot on an unknown layout prints the fix" '[ $rc -ne 0 ] && [[ "$out" == *"fix:"*"extract_builtins"* ]] && [[ "$(python3 "$SV" builtins)" == *"23 built-in"* ]]'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
