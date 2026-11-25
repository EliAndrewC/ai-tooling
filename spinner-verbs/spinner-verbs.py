#!/usr/bin/env python3
"""spinner-verbs: turn a running-joke Google Doc of fake album and song titles into extra Claude Code
spinner verbs ("Making a suspiciously minor change...").

The doc is a table of contents ("Album Name    N") followed by one table per album ("Track #", "Title",
then number/title pairs). Each title, and each album name, gets a verdict in a private *ledger*; the
verbs marked yes are exported to a public list, and `apply` appends that list to Claude Code's
`spinnerVerbs` setting.

  spinner-verbs.py fetch        download + parse the doc, print albums and track counts
  spinner-verbs.py new          titles still to review (--record adds them to the ledger as unreviewed)
  spinner-verbs.py status       ledger counts by verdict, plus renamed/removed titles
  spinner-verbs.py list         ledger entries (--verdict V), as title -> verb
  spinner-verbs.py set TITLE V  record a verdict (TITLE: unique case-insensitive substring)
  spinner-verbs.py lint         flag verbs that reword the title or lose its punctuation (CLAUDE.md rules)
  spinner-verbs.py export       write the public verbs file from the ledger's "yes" entries
  spinner-verbs.py extras       the verbs extras.json's categories add (downloaded, not stored here)
  spinner-verbs.py apply        merge the DSK verbs + extras into ~/.claude/settings.json (append mode)

State (private: the ledger and any blocked coworker names) lives in $SPINNER_VERBS_STATE, default
~/.config/spinner-verbs/: `config.json` ({"doc": URL, "blocked_words": [...]}, both optional) and
`ledger.json`.
See CLAUDE.md next to this file for the review criteria.
"""
import argparse, json, os, re, sys, tempfile, unicodedata, urllib.request

HERE = os.path.dirname(os.path.realpath(__file__))
STATE = os.path.expanduser(os.environ.get("SPINNER_VERBS_STATE", "~/.config/spinner-verbs"))
VERBS_FILE = os.path.join(HERE, "verbs.json")
EXTRAS_FILE = os.path.join(HERE, "extras.json")
SETTINGS = os.path.expanduser("~/.claude/settings.json")
# The DSK doc is public by design (anyone can read it, only the band can edit it).
DSK_DOC = "https://docs.google.com/document/d/1kO6DRPxsuS4XvP8sjDwwgcAjuVuv5-oIGPIxuguu_Zc"
DEFAULT_DOC = os.environ.get("SPINNER_VERBS_DOC", DSK_DOC)
# Words a verb may never contain (substring, any case): crude is fine ("damn", "ass"), these aren't.
# Private extras, e.g. coworker names, go in $STATE/config.json as "blocked_words" (whole words).
PROFANITY = ("fuck", "shit")
VERDICTS = ("unreviewed", "yes", "no", "proposed-yes", "proposed-maybe", "proposed-no")


def die(msg):
    print(f"spinner-verbs: {msg}", file=sys.stderr)
    sys.exit(1)


# ---------- normalisation ----------
QUOTES = str.maketrans({"‘": "'", "’": "'", "“": '"', "”": '"', " ": " "})


def clean(s):
    return re.sub(r"\s+", " ", unicodedata.normalize("NFC", s).translate(QUOTES)).strip()


def key(album, title):
    """Identity of an entry. Album + title, because titles recur across albums ("Djanky"/"dJanky")."""
    return f"{clean(album).casefold()}|{clean(title).casefold()}"


# ---------- fetching ----------
def export_url(doc):
    m = re.search(r"/document/d/([A-Za-z0-9_-]+)", doc)
    doc_id = m.group(1) if m else doc
    return f"https://docs.google.com/document/d/{doc_id}/export?format=txt"


def load_config():
    path = os.path.join(STATE, "config.json")
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def fetch_text(args):
    if args.file:
        with open(args.file, encoding="utf-8-sig") as f:
            return f.read()
    doc = args.doc or load_config().get("doc") or DEFAULT_DOC
    if not doc:
        die(f"no doc given. fix: pass --doc URL, or write {{\"doc\": \"URL\"}} to {STATE}/config.json")
    url = export_url(doc)
    try:
        with urllib.request.urlopen(url, timeout=30) as r:
            ctype = r.headers.get("Content-Type", "")
            body = r.read().decode("utf-8-sig")
    except Exception as e:  # noqa: BLE001
        die(f"fetching {url} failed: {e}. fix: check the network, or download File > Download > "
            "Plain text and pass --file PATH")
    if "text/plain" not in ctype or body.lstrip().startswith("<"):
        die(f"{url} returned {ctype or 'no content type'}, not plain text: the doc is probably not "
            "shared publicly. fix: Share > General access > 'Anyone with the link' (Viewer), or "
            "download File > Download > Plain text and pass --file PATH")
    return body


# ---------- parsing ----------
TOC_RE = re.compile(r"^(.*\S)\s{2,}(\d+)$")
SEP_RE = re.compile(r"^_{10,}$")
NUM_RE = re.compile(r"^\d{1,3}$")


def parse(text):
    """Return [{"album": name, "number": N, "tracks": [{"track": n, "title": t}]}] in doc order.

    Handles the real doc's quirks: CRLF + BOM, duplicate contents numbers, an album that starts with
    no separator line (its name tab-indented right after the previous album's last title), skipped
    and empty track numbers, untabbed numbers, multi-line titles, and "*" footnote lines."""
    lines = [l.rstrip("\r") for l in text.replace("﻿", "").split("\n")]
    toc, i = [], 0
    # Contents list: "Name<2+ spaces>N" lines. Stray lines before it (the real doc has one) are skipped.
    while i < len(lines):
        m = TOC_RE.match(lines[i].strip())
        if m:
            toc.append((clean(m.group(1)), int(m.group(2))))
        elif toc and lines[i].strip():
            break
        i += 1
    if not toc:
        die("no contents list found (lines like 'Album Name    12'). fix: check the doc's format, or "
            "pass --file with a plain-text export")
    names = {n.casefold(): (n, num) for n, num in toc}

    def heading_at(j):
        """Album name if lines[j] is an album heading: a contents name whose next text is 'Track #'."""
        name = clean(lines[j])
        if name.casefold() not in names:
            return None
        k = j + 1
        while k < len(lines) and not lines[k].strip():
            k += 1
        return names[name.casefold()] if k < len(lines) and lines[k].strip() == "Track #" else None

    albums, cur, track, buf = [], None, None, []

    def flush():
        if cur is not None and track is not None:
            title = clean(" ".join(buf))
            if title:
                cur["tracks"].append({"track": track, "title": title})

    for j in range(i, len(lines)):
        raw = lines[j].strip()
        h = heading_at(j)
        if h:
            flush()
            cur, track, buf = {"album": h[0], "number": h[1], "tracks": []}, None, []
            albums.append(cur)
            continue
        if cur is None or raw in ("Track #", "Title"):
            continue
        if SEP_RE.match(raw):
            flush()
            track, buf = None, []
            continue
        if NUM_RE.match(raw):
            flush()
            track, buf = int(raw), []
            continue
        if raw and track is not None and not raw.startswith("*"):
            buf.append(raw)
        elif raw:
            print(f"spinner-verbs: warning: ignored line {j + 1} in {cur['album']!r}: {raw!r}",
                  file=sys.stderr)
    flush()
    if len(albums) != len(toc):
        missing = [n for n, _ in toc if n.casefold() not in {a["album"].casefold() for a in albums}]
        die(f"parsed {len(albums)} albums but the contents list has {len(toc)}; no table found for: "
            f"{missing}. fix: the album's heading must match its contents line exactly and be "
            "followed by a 'Track #' line")
    return albums


def entries(albums):
    """Flatten to reviewable entries: each album name, then its tracks."""
    out = []
    for a in albums:
        out.append({"album": a["album"], "track": None, "title": a["album"], "kind": "album"})
        for t in a["tracks"]:
            out.append({"album": a["album"], "track": t["track"], "title": t["title"], "kind": "song"})
    return out


# ---------- ledger ----------
def ledger_path():
    return os.path.join(STATE, "ledger.json")


def load_ledger():
    try:
        with open(ledger_path()) as f:
            return json.load(f)
    except FileNotFoundError:
        return []


def write_json(path, data):
    """Atomic write. Follows a symlink (so a linked settings.json stays linked) and keeps the mode."""
    path = os.path.realpath(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    mode = os.stat(path).st_mode & 0o7777 if os.path.exists(path) else 0o644
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-")
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def blocked(verb):
    """The blocked word a verb contains, or None."""
    low = verb.casefold()
    for w in PROFANITY:
        if w in low:
            return w
    for w in load_config().get("blocked_words", []):
        if re.search(rf"(?<![A-Za-z]){re.escape(w.casefold())}(?![A-Za-z])", low):
            return w
    return None


def verbs_from_ledger(ledger, include_proposed=False):
    ok = ("yes", "proposed-yes") if include_proposed else ("yes",)
    seen, out = set(), []
    for e in ledger:
        v = e.get("verb")
        if e.get("verdict") in ok and v and v.casefold() not in seen:
            seen.add(v.casefold())
            out.append(v)
    return out


# ---------- commands ----------
def cmd_fetch(args):
    albums = parse(fetch_text(args))
    for a in albums:
        print(f"{a['number']:>3}  {a['album']}  ({len(a['tracks'])} tracks)")
    n = sum(len(a["tracks"]) for a in albums)
    print(f"{len(albums)} albums, {n} songs")
    if args.json:
        write_json(args.json, albums)


def cmd_new(args):
    doc = entries(parse(fetch_text(args)))
    ledger = load_ledger()
    known = {key(e["album"], e["title"]) for e in ledger}
    added = [e for e in doc if key(e["album"], e["title"]) not in known]
    if args.record and added:
        ledger += [{**e, "verdict": "unreviewed", "verb": "", "why": ""} for e in added]
        write_json(ledger_path(), ledger)
    pending = {key(e["album"], e["title"]) for e in ledger if e.get("verdict") == "unreviewed"}
    new = [e for e in doc if key(e["album"], e["title"]) not in known or
           key(e["album"], e["title"]) in pending]
    if args.json:
        print(json.dumps(new, indent=2, ensure_ascii=False))
    else:
        for e in new:
            where = e["album"] if e["kind"] == "album" else f"{e['album']} #{e['track']}"
            print(f"[{e['kind']}] {e['title']}    ({where})")
        print(f"{len(new)} unreviewed of {len(doc)}", file=sys.stderr)


def cmd_status(args):
    ledger = load_ledger()
    counts = {}
    for e in ledger:
        counts[e.get("verdict", "?")] = counts.get(e.get("verdict", "?"), 0) + 1
    for v in VERDICTS:
        print(f"{v:>15}: {counts.get(v, 0)}")
    for e in ledger:
        if e.get("verdict") not in VERDICTS:
            print(f"INVALID verdict {e.get('verdict')!r}: {e.get('title')} (fix: spinner-verbs.py set "
                  f"'{e.get('title')}' <{'|'.join(VERDICTS)}>)")
    if args.check_doc:
        doc = {key(e["album"], e["title"]) for e in entries(parse(fetch_text(args)))}
        gone = [e for e in ledger if key(e["album"], e["title"]) not in doc]
        for e in gone:
            print(f"no longer in doc (renamed or removed): {e['title']} ({e['album']})")


def cmd_list(args):
    for e in load_ledger():
        if args.verdict and e.get("verdict") != args.verdict:
            continue
        print(f"{e.get('verdict', '?'):>14}  {e['title']}  ->  {e.get('verb') or '-'}")


def cmd_set(args):
    ledger = load_ledger()
    needle = clean(args.title).casefold()
    hits = [e for e in ledger if clean(e["title"]).casefold() == needle] or \
           [e for e in ledger if needle in clean(e["title"]).casefold()]
    # The same title on two albums (a reprise) is one decision.
    if len({clean(e["title"]).casefold() for e in hits}) != 1:
        titles = "; ".join(e["title"] for e in hits[:10]) or "none"
        die(f"{len(hits)} titles match {args.title!r} ({titles}). fix: give more of the title")
    for e in hits:
        e["verdict"] = args.verdict
        if args.verb is not None:
            e["verb"] = args.verb
        if args.why is not None:
            e["why"] = args.why
        if e["verdict"] in ("yes", "proposed-yes", "proposed-maybe"):
            if not e.get("verb"):
                die(f"{e['title']!r} has no verb. fix: add --verb 'Doing the thing'")
            if blocked(e["verb"]):
                die(f"{e['verb']!r} contains the blocked word {blocked(e['verb'])!r}. fix: reword the "
                    "verb, or record the title as no")
    write_json(ledger_path(), ledger)
    print(f"{hits[0]['title']}: {args.verdict}  ->  {hits[0].get('verb') or '-'}")


# Subject/filler words a verb may drop ("We're doing it" -> "Doing it"); everything else should survive.
DROPPABLE = set("""a an the and of to in on for with at by is are be it its it's i i'm me my we we're
our you your let just gotta all""".split())
WORD = re.compile(r"[A-Za-z0-9]+(?:'[A-Za-z]+)?")


IRREGULAR = {"doing": "do", "does": "do", "done": "do", "going": "go", "goes": "go", "being": "be",
             "taking": "tak", "taken": "tak", "made": "mak", "forgotten": "forget"}


def stem(w):
    """Crude stem so inflections match: Making/Make, Refuriated/Refuriating, Hell'ing/Hell, Diffs/Diffing."""
    w = w.casefold().replace("'ing", "").replace("'", "")
    if w in IRREGULAR:
        return IRREGULAR[w]
    for suf, rep in (("ying", "y"), ("ied", "y"), ("ing", ""), ("ed", ""), ("es", ""), ("s", ""), ("e", "")):
        if w.endswith(suf) and len(w) - len(suf) >= 3:
            return w[: -len(suf)] + rep
    return w


def kept(word, vstems):
    s = stem(word)
    return any(s == v or (min(len(s), len(v)) >= 3 and (s.startswith(v) or v.startswith(s))) for v in vstems)


def lint_entry(e):
    """Problems with a verb, by the CLAUDE.md rules Eli's edits established."""
    title, verb, out = clean(e["title"]), clean(e.get("verb") or ""), []
    vstems = {stem(w) for w in WORD.findall(verb)}
    lost = [w for w in WORD.findall(title) if w.casefold() not in DROPPABLE and not kept(w, vstems)]
    if lost:
        out.append(f"title words reworded or dropped: {', '.join(lost)} (rule: keep the title's words, "
                   "put a verb in front)")
    vexact = {w.casefold() for w in WORD.findall(verb)}
    for w in WORD.findall(title):
        ing = {stem(v) for v in WORD.findall(verb) if v.casefold().endswith(("ing", "'ing"))}
        if re.search(r"[a-z](er|or)$", w, re.I) and w.casefold() not in vexact and kept(w, ing):
            out.append(f"agent noun {w!r} turned into a verb (rule: keep the noun, put a verb in front, "
                       "like 'Engaging the transcendental number pusher')")
    content = [stem(w) for w in WORD.findall(title) if w.casefold() not in DROPPABLE]
    vorder = [stem(w) for w in WORD.findall(verb)]
    def same(c, v):
        return c == v or (min(len(c), len(v)) >= 3 and (c.startswith(v) or v.startswith(c)))
    last, reordered = -1, False
    for c in content:  # each title word must appear after the previous one; earlier-only = reordered
        nxt = next((i for i in range(last + 1, len(vorder)) if same(c, vorder[i])), None)
        if nxt is not None:
            last = nxt
        elif any(same(c, v) for v in vorder):
            reordered = True
    if reordered:
        out.append("title words reordered: a noun phrase turned into a verb (rule: keep the phrase, "
                   "put a verb in front)")
    if re.search(r"\b(you|your|you're|yours)\b", verb, re.I):
        out.append("contains you/your: if it's said to the developer, the agent is the developer, so use "
                   "I/my ('Doing it \"in my spare time\"'); a generic you or a your-mom joke stays")
    tp = re.findall(r"\(([^)]*)\)", title)
    vp = re.findall(r"\(([^)]*)\)", verb)
    for a in tp:
        match = next((b for b in vp if b.casefold() == a.casefold()), None)
        if match is not None and a[:1].isupper() and match[:1].islower():
            out.append(f"parenthetical lost its capital: ({match}) (rule: its own sentence keeps it)")
    for mark in ("!", "?", "...", ":)", "*"):
        if mark in title and mark not in verb:
            out.append(f"lost {mark!r} from the title (rule: punctuation is part of the joke)")
    return out


def cmd_lint(args):
    n = 0
    for e in load_ledger():
        if e.get("verdict") not in ("yes", "proposed-yes", "proposed-maybe") and not args.all:
            continue
        if not e.get("verb"):
            continue
        # A verb Eli wrote or edited himself is settled, even where it breaks a rule on purpose.
        if (e.get("why") or "").startswith("Eli") and not args.all:
            continue
        for problem in lint_entry(e):
            n += 1
            print(f"{e['title']}  ->  {e['verb']}\n    {problem}")
    print(f"{n} lint findings", file=sys.stderr)


def cmd_export(args):
    verbs = verbs_from_ledger(load_ledger(), args.include_proposed)
    bad = [(v, blocked(v)) for v in verbs if blocked(v)]
    if bad:
        die("blocked words in verbs: " + "; ".join(f"{v!r} ({w})" for v, w in bad) +
            ". fix: `set TITLE no` or reword with `set TITLE yes --verb ...`")
    write_json(args.out, {"verbs": verbs})
    print(f"wrote {len(verbs)} verbs to {args.out}")


# ---------- extra verbs from another list ----------
VERBISH = re.compile(r"(ing|in')$", re.I)
# A gerund in second place counts ("Not expecting the Spanish Inquisition") unless the entry opens like a
# sentence's subject ("I've been chasing...", "The build was...").
SENTENCE_START = set("i i've i'm the this that a an she he we it they someone nobody every another two".split())


def load_extras(path, text=None):
    """[(category, verb)] for the categories in extras.json, parsed from the source README's tables
    ("### Name (N)" then "| verb |" rows). Entries that aren't verb phrases are dropped with a warning."""
    with open(path) as f:
        cfg = json.load(f)
    if text is None:
        try:
            with urllib.request.urlopen(cfg["source"], timeout=30) as r:
                text = r.read().decode("utf-8")
        except Exception as e:  # noqa: BLE001
            die(f"downloading {cfg['source']} failed: {e}. fix: check the network, or run apply with "
                "--no-extras to apply only the DSK verbs")
    tables, cur = {}, None
    for line in text.splitlines():
        m = re.match(r"^###\s+(.+?)\s*\((\d+)\)\s*$", line)
        if m:
            cur = m.group(1)
            tables[cur] = []
            continue
        if line.startswith("#"):
            cur = None
        elif cur and line.startswith("|"):
            cell = line.strip().strip("|").strip()
            if cell and not re.fullmatch(r"[-: ]+|Verbs?|Phrases?|Entry", cell):
                tables[cur].append(cell)
    out, exclude = [], {x.casefold() for x in cfg.get("exclude", [])}
    adapted = set(cfg.get("adapted_categories", []))
    adaptations = load_adaptations()
    for c in cfg["categories"] + [a for a in cfg.get("adapted_categories", []) if a not in cfg["categories"]]:
        if c.endswith("Phrases") and c not in adapted:
            die(f"extras.json category {c!r} is a phrases list (sentences). fix: use the verb category, "
                f"{c[:-len(' Phrases')]!r}")
        if c not in tables:
            close = [t for t in tables if c.casefold().split()[0] in t.casefold()][:5]
            die(f"category {c!r} not found in {cfg['source']}. fix: use its exact heading; similar: {close}")
        if c in adapted:
            # Each entry reworded by hand into a verb (or struck) in the private adaptations file: the
            # rewordings are derived from an unlicensed list, so they never go in this public repo.
            if adaptations.get(c, {}).get("_status") == "proposed":
                print(f"spinner-verbs: warning: adapted category {c!r} is still proposed, so it's left out. "
                      f"fix: once Eli approves it, delete its \"_status\" key in {adaptations_path()}",
                      file=sys.stderr)
                continue
            amap = {clean(k).casefold(): v for k, v in adaptations.get(c, {}).items() if k != "_status"}
            pending = 0
            for v in tables[c]:
                if clean(v).casefold() not in amap:
                    pending += 1
                elif amap[clean(v).casefold()]:
                    out.append((c, amap[clean(v).casefold()]))
            if pending:
                print(f"spinner-verbs: warning: {pending} entries in adapted category {c!r} have no "
                      f"adaptation yet. fix: `extras --pending` lists them; add each to "
                      f"{adaptations_path()} as \"original\": \"verb\" (or null to strike)", file=sys.stderr)
            continue
        for v in tables[c]:
            words = [w.strip(",.!?\"'") for w in v.split()]
            # A verb phrase starts with a gerund ("Grepping the streets for a clue"); a short one may lead
            # with a modifier ("Not golfing", "Mr. Plowing"). "I've been chasing this pointer for days"
            # contains a gerund but is a sentence.
            lead = words[1:2] if words[0].casefold() not in SENTENCE_START else []
            is_verb = (VERBISH.search(words[0]) or any(VERBISH.search(w) for w in lead) or
                       (len(words) <= 3 and any(VERBISH.search(w) for w in words)))
            if not is_verb or v.rstrip()[-1:] in ".?":
                print(f"spinner-verbs: warning: skipped {v!r} ({c}): not a verb phrase", file=sys.stderr)
            elif v.casefold() in exclude:
                pass
            elif blocked_profanity(v):
                print(f"spinner-verbs: warning: skipped {v!r} ({c}): blocked word", file=sys.stderr)
            else:
                out.append((c, v))
    return out


def adaptations_path():
    return os.path.join(STATE, "adaptations.json")


def load_adaptations():
    try:
        with open(adaptations_path()) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def blocked_profanity(verb):
    return next((w for w in PROFANITY if w in verb.casefold()), None)


def cmd_extras(args):
    if args.pending:
        with open(args.extras) as f:
            cfg = json.load(f)
        with urllib.request.urlopen(cfg["source"], timeout=30) as r:
            text = r.read().decode("utf-8")
        ad = load_adaptations()
        for c in cfg.get("adapted_categories", []):
            m = re.search(rf"^###\s+{re.escape(c)}\s*\(\d+\)\s*$(.*?)(?=^###\s)", text, re.M | re.S)
            known = {clean(k).casefold() for k in ad.get(c, {}) if k != "_status"}
            for line in (m.group(1) if m else "").splitlines():
                cell = line.strip().strip("|").strip()
                if line.startswith("|") and cell and not re.fullmatch(r"[-: ]+|Verbs?|Phrases?|Entry", cell) \
                        and clean(cell).casefold() not in known:
                    print(f"{c}\t{cell}")
        return
    rows = load_extras(args.extras)
    by = {}
    for c, v in rows:
        by.setdefault(c, []).append(v)
    for c, vs in by.items():
        print(f"{len(vs):>4}  {c}: {', '.join(vs) if args.verbose else ''}".rstrip(": "))
    print(f"{len(rows)} extra verbs from {len(by)} categories")


def cmd_apply(args):
    try:
        with open(args.verbs) as f:
            verbs = json.load(f)["verbs"]
    except FileNotFoundError:
        die(f"{args.verbs} does not exist. fix: run `spinner-verbs.py export` first (it writes the "
            "ledger's yes verbs there)")
    dsk = len(verbs)
    if not args.no_extras:
        seen = {v.casefold() for v in verbs}
        for _, v in load_extras(args.extras):
            if v.casefold() not in seen:
                seen.add(v.casefold())
                verbs.append(v)
    print(f"{dsk} DSK verbs + {len(verbs) - dsk} extras = {len(verbs)} (plus Claude Code's built-ins)")
    try:
        with open(args.settings) as f:
            settings = json.load(f)
    except FileNotFoundError:
        settings = {}
    applied_path = os.path.join(STATE, "applied.json")
    try:
        with open(applied_path) as f:
            previously = set(json.load(f))
    except FileNotFoundError:
        previously = set()
    sv = settings.get("spinnerVerbs") or {}
    # Keep verbs someone else added; drop only the ones this tool wrote last time.
    others = [v for v in sv.get("verbs", []) if v not in previously and v not in verbs]
    # Always append: the point is to add to the built-in verbs, never to replace them.
    if sv.get("mode", "append") != "append":
        print(f"spinnerVerbs mode was {sv.get('mode')!r}; setting it to 'append' so the built-ins stay")
    new = {"mode": "append", "verbs": others + verbs}
    if new == sv:
        print("spinnerVerbs already up to date")
        return
    added = [v for v in verbs if v not in sv.get("verbs", [])]
    removed = [v for v in sv.get("verbs", []) if v not in new["verbs"]]
    for v in added:
        print(f"+ {v}")
    for v in removed:
        print(f"- {v}")
    if args.dry_run:
        print("(dry run: settings not changed)")
        return
    settings["spinnerVerbs"] = new
    write_json(args.settings, settings)
    write_json(applied_path, verbs)
    print(f"{args.settings}: spinnerVerbs now {len(new['verbs'])} verbs, mode {new['mode']}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    src = argparse.ArgumentParser(add_help=False)
    src.add_argument("--doc", help="Google Doc URL or id (default: $STATE/config.json's doc, else "
                     "$SPINNER_VERBS_DOC, else the DSK doc)")
    src.add_argument("--file", help="read a plain-text export instead of downloading")
    s = sub.add_parser("fetch", parents=[src]); s.add_argument("--json", help="also write parsed albums here")
    s.set_defaults(fn=cmd_fetch)
    s = sub.add_parser("new", parents=[src]); s.add_argument("--json", action="store_true")
    s.add_argument("--record", action="store_true", help="add them to the ledger as 'unreviewed'")
    s.set_defaults(fn=cmd_new)
    s = sub.add_parser("status", parents=[src])
    s.add_argument("--check-doc", action="store_true", help="also list ledger titles gone from the doc")
    s.set_defaults(fn=cmd_status)
    s = sub.add_parser("list"); s.add_argument("--verdict", choices=VERDICTS)
    s.set_defaults(fn=cmd_list)
    s = sub.add_parser("set"); s.add_argument("title"); s.add_argument("verdict", choices=VERDICTS)
    s.add_argument("--verb"); s.add_argument("--why")
    s.set_defaults(fn=cmd_set)
    s = sub.add_parser("lint"); s.add_argument("--all", action="store_true", help="include no's and verbs Eli wrote himself")
    s.set_defaults(fn=cmd_lint)
    s = sub.add_parser("export"); s.add_argument("--out", default=VERBS_FILE)
    s.add_argument("--include-proposed", action="store_true", help="preview: count proposed-yes too")
    s.set_defaults(fn=cmd_export)
    s = sub.add_parser("extras"); s.add_argument("--extras", default=EXTRAS_FILE)
    s.add_argument("-v", "--verbose", action="store_true", help="list the verbs too")
    s.add_argument("--pending", action="store_true", help="adapted-category entries with no adaptation yet")
    s.set_defaults(fn=cmd_extras)
    s = sub.add_parser("apply"); s.add_argument("--verbs", default=VERBS_FILE)
    s.add_argument("--extras", default=EXTRAS_FILE)
    s.add_argument("--no-extras", action="store_true", help="only the DSK verbs")
    s.add_argument("--settings", default=SETTINGS); s.add_argument("--dry-run", action="store_true")
    s.set_defaults(fn=cmd_apply)
    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
