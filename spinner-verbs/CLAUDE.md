# spinner-verbs

Turns a long-running office joke, a Google Doc listing a fake band's albums and songs, into extra
Claude Code spinner verbs ("Making a suspiciously minor change…"). Claude Code's `spinnerVerbs` setting
takes `{"mode": "append" | "replace", "verbs": [...]}`. `apply` always uses **append**, so the
built-in verbs stay (187 in Claude Code 2.1.332).

| File | What |
|---|---|
| `spinner-verbs.py` | `fetch` / `new` / `status` / `list` / `set` / `export` / `extras` / `apply` (run with `-h`) |
| `verbs.json` | the public DSK list: only verbs with verdict `yes` (written by `export`) |
| `extras.json` | categories pulled from another list (see "Extra verbs") |
| `test-spinner-verbs.sh` | tests on a synthetic doc; ends `N passed, 0 failed` |

The DSK doc is public by design (read-only to the world) and is the built-in default source.
**Private state is never committed here.** `$SPINNER_VERBS_STATE` (default `~/.config/spinner-verbs/`)
holds:
- `config.json`: optional `{"doc": URL, "blocked_words": [coworker names]}`
- `ledger.json`: every title ever seen, with verdict, verb and reason
- `applied.json`: what `apply` last wrote, so a dropped verb gets removed

They stay out of this repo: `config.json` lists coworker names, and only the chosen verbs belong in a
public list. Test fixtures are synthetic for the same reason.

## Using this yourself (someone other than the maintainer)

`apply` **appends** to the built-in verbs and never replaces them. It keeps the other settings, and a
rerun only removes verbs this tool added before.

```sh
./spinner-verbs.py apply --dry-run   # show what would change in ~/.claude/settings.json
./spinner-verbs.py apply             # band verbs + extra categories
./spinner-verbs.py apply --no-dsk    # only the extra categories
./spinner-verbs.py apply --no-extras # only the band verbs
./spinner-verbs.py extras -v         # list the extra categories' verbs
```

- **Choosing categories:** edit `categories` in `extras.json` using the exact headings from the source
  repo's README. Use the short-verb categories: the tool refuses the "… Phrases" ones, which are
  sentences.
- **Noir Detective** is an adapted category whose rewordings are private (see "Extra verbs"). Without
  them it's skipped with a note. Remove it from `adapted_categories` to silence the note.
- **Your own list of titles:** `fetch` / `new` / `lint` work on any Google Doc laid out the same way
  (a contents list, then one table per album). Pass `--doc URL`, then follow the workflow below.

## Updating the list (what a session does when asked)

1. `./spinner-verbs.py new --record` lists titles still to review: new in the doc, or still
   `unreviewed`. It adds the new ones to the ledger as `unreviewed`.
2. Judge each one against the criteria below and record **every** title, album names included:
   `set TITLE proposed-yes|proposed-maybe|proposed-no --verb "…" --why "…"`.
3. Run `lint`. It checks principles 1 and 4 below and flags verbs that reword the title, flip it from
   a noun phrase into a verb, turn an agent noun into a verb, or lose punctuation or a parenthetical
   capital. Fix each finding, or tell Eli why the exception is worth keeping. Verbs whose `why` starts
   with "Eli" are his own wording, and lint skips them.
4. Show Eli the proposed yes and maybe entries (`list --verdict proposed-yes`) as title → verb. His
   answers become `set TITLE yes|no`. Never mark a title `yes` without him.
5. Run `export`, then `apply --dry-run`, then `apply`. Commit `verbs.json` here.
6. `status --check-doc` lists ledger titles no longer in the doc (renamed or removed). Ask whether a
   renamed title keeps its verdict.

Verdicts: `yes` / `no` are settled by Eli; `proposed-*` are a session's first pass.

## What makes a good spinner verb

A spinner verb is a waiting message: "the agent is currently ___". There's **no cap** on DSK verbs:
every title that works goes in. The ratio to the built-ins is balanced by adding verbs from other
sources, never by cutting DSK ones.

1. **Most noun titles don't become verbs, unless there's an obvious verb version.** "The Crypt" →
   "Crypting" captures nothing. "Blackberry is Dumb" is an opinion, not an activity.
2. **Prefer the least change that keeps the title recognizable.** An existing gerund is best
   ("Codifying workarounds"). Next comes an imperative turned gerund ("Finish Strong" → "Finishing
   strong :)"). Next, one added verb with the whole title kept ("Making a suspiciously minor change").
   If half the title has to go, it's a no.
3. **It names something work, or the agent, does.** That covers real principles ("Applying the
   Principle of Least Anger"), ones the team coined ("Exhibiting wise cowardice"), or self-contained
   wordplay that needs no backstory ("Refuriating beans", "(Pew) Pew Pew'ing"). You don't need to know
   the story behind a title to use it.
4. **References are fine; a title that's only about life outside work isn't.** Card names, games and
   pop culture are fair game ("Appropriately council-rooming" is the Dominion card; Pentavus, Leeroy
   Jenkins, Dory). "I'm just like you, but I draw GOOD cards" is still a no: it's about the card game
   itself, and the verb would drop most of the title.
5. **Never a coworker's name.** The list is public. `config.json`'s `blocked_words` holds the names, and
   `set` and `export` refuse a verb containing one.
6. **Crude is fine ("damn", "ass", "testacular"); "shit" and "fuck" are not.** Both are built into the
   tool's blocked words.
7. **Capitalization follows the band's convention.** Titles are sentence case, because they're phrases
   someone might say ("Mattermost matters most", "Muddling along as we always have"). Proper nouns keep
   their capitals: named principles, departments, scales, problems ("The Inverse Conway Maneuver", "The
   Worry Police", "The Leeroy Scale"), and riffs on titled works ("An Immodest Proposal", after Swift's
   "A Modest Proposal"). The doc is inconsistent, so judge each title. Inside a verb, the
   article goes lowercase: "Executing the Inverse Conway Maneuver".

8. **A code identifier stays verbatim; add 'ing to the end instead of rewording.** "raise Hell" uses the
   Python keyword, so it becomes "raise Hell'ing", not "Raising hell". "un-twisted" means the Twisted
   framework, so it becomes "un-Twisted'ing". A pun on a name works the same way: "Martin Luther
   Ping'ing", not "Martin Luther pinging". (Pew) Pew Pew'ing follows the same pattern.
   A noun that names a thing keeps its noun and gets a verb in front: "Engaging the transcendental
   number pusher", "Jumping on the squashing band wagon".
9. **Keep the title's own voice.** Edit a parenthetical only enough to read as part of the verb: "Doing
   things right (a story point modifier)". A parenthetical that is its own sentence keeps its capital:
   "(Deal with it!)".

**Principles from Eli's edits** (rounds 4–9; `lint` checks 1, 4 and 7):
1. **Keep the title's words and put a verb in front; don't turn its noun into a verb.** "Engaging the
   transcendental number pusher", not "Pushing transcendental numbers". "Jumping on the squashing
   band wagon". "Clicking 'I Understand the Risks'" (it's a button label). A verb that rewrites the
   title gets struck ("Swinging the JIRA sledgehammer").
2. **Names, identifiers and puns on names stay exactly as written, with 'ing added** (rule 8 above).
3. **A riff on a famous phrase is struck if the verb form breaks it** ("considered harmful", "Always Be
   Closing", "Don't Not Decline"). It stays if a verb in front keeps it intact ("Making an Immodest
   Proposal").
4. **Punctuation is part of the joke.** Keep "(!)", "...", "**…**", and a parenthetical's capital when
   the parenthetical is its own sentence. A parallel joke stays parallel: "Value adding (more like
   value sadding)".
5. **The added verb has to fit the situation**: "Fixing 8 nested levels of 'never could have
   worked'", not "Writing".

6. **A nounified verb is the joke; don't verb it back.** "Smooth Scrollie" is a scrolly that scrolls
   smoothly. As a verb it collapses to "scrolling smoothly" and the joke is gone, so strike it.
   (Different from principle 1: here the noun was made from a verb on purpose.)

7. **The agent is the developer, so "you/your" said to the developer becomes I/my**: "Doing it 'in my
   spare time'". A generic "you" ("sometimes you got to") and a your-mom joke stay as they are.
   "We/our" stays too, because the agent is on the team. `lint` flags every you/your for a check.

Glossary for judging titles: a **linger** is staying after stand-up to keep talking about something
that came up in it. **Puppet** is the configuration-management tool. **Twisted** is the Python web
framework.

Families (decided):
- "Done, not X": **no**, all of them, including "Installed, not restarted" and "Documented, not working".
- "Why don't you X about it?": **no**.
- "X-driven development" → "Practicing X-driven development"
- "Always Be X": **no**, all of them.
- "The X Problem" → "Solving the X Problem"
- "X, considered Y": **no**. It riffs on "X considered harmful", and the verb form loses the reference.

## Extra verbs

To keep the ratio around one DSK verb per 3–4 others, `apply` also adds verbs from
github.com/wynandw87/claude-code-spinner-verbs. Only the category names chosen in `extras.json` are
committed here. The verbs are **downloaded when `apply` runs, never copied into this repo**, because that
repo has no license.

Rules for this source:
- Verb categories only. The "… Phrases" categories are sentences, and the tool refuses them.
- Any entry that isn't a verb phrase is skipped with a warning. An entry counts as a verb phrase if it
  starts with an -ing verb, has one second after a modifier ("Not expecting the Spanish Inquisition"),
  or is a short phrase of three words or fewer ("Mr. Plowing"). A noun phrase that slips through goes in
  `extras.json`'s `exclude` list.
- **Adapted categories** (`adapted_categories` in `extras.json`; currently Noir Detective) mix verb
  phrases with sentences. Each entry is reworded into a verb phrase using the DSK principles, or struck.
  The rewordings are in the private `$SPINNER_VERBS_STATE/adaptations.json` as `"original": "verb"`, or
  `null` to strike, because they're derived from an unlicensed list. `extras --pending` lists entries
  with no decision. A category whose `"_status"` is `"proposed"` stays out until Eli approves it.
- **Short verbs only, judged by category.** Eli picks the short-verb categories and approves each one as
  a whole, so there's no per-entry review and no word cap. "Waiting at the bus stop with Totoro" is
  fine because it comes from a short-verb category. Eli doesn't want the long-phrase categories. Watch out for look-alike category
  names: "Detective / Noir" (11 short verbs) is in. "Noir Detective" (71 one-liners about code) is in only
  as an adapted category, entry by entry.
- The built-in profanity block applies. The coworker-name block applies only to DSK verbs ("Questioning
  Larry" is a Lebowski character).
- `extras` shows what the chosen categories add (`-v` lists the verbs).
- To apply only the DSK verbs: `apply --no-extras`.

As of 2026-11-25, the totals are 187 built-ins, 244 DSK and 271 extras from 13 categories (34 adapted from Noir Detective): 702 in all,
or one DSK verb in 2.9.

**Regression set (Eli's own verdicts).** Any rule change must still give these:

| Title | Verdict | Verb / reason |
|---|---|---|
| The Crypt | no | "Crypting" captures nothing |
| (Pew) Pew Pew | yes | (Pew) Pew Pew'ing |
| Principle of Least Anger | yes | Applying the Principle of Least Anger |
| Blackberry is Dumb | no | an opinion, nothing to do |
| Wise Cowardice | yes | Exhibiting wise cowardice |
| I'm just like you, but I draw GOOD cards | no | about the game itself, and needs rewording |
| Appropriately Council Roomed | yes | Appropriately council-rooming (references are fine) |
| robusted | yes | Robusting (to make robust, not a coworker's name) |
| raise Hell | yes | raise Hell'ing (Python keyword kept) |
| un-twisted | yes | un-Twisted'ing (the Twisted framework) |
| An Immodest Proposal | yes | Making an Immodest Proposal (riff on a titled work) |
| crow, considered eaten | no | "considered harmful" riff, lost as a verb |
| Refuriated beans | yes | Refuriating beans |
| A suspiciously minor change | yes | Making a suspiciously minor change |

## Testing

- `bash test-spinner-verbs.sh` should end `53 passed, 0 failed`.
- Against the real doc, `./spinner-verbs.py fetch` prints every album with its track count. If the album
  count doesn't match the doc's contents list, it fails and names the album it couldn't find. It warns
  about any non-empty line it drops: today that's only one footnote line.
- `apply --dry-run` shows the `+`/`-` changes to `settings.json` without writing.
