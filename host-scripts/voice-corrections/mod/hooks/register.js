// voice-corrections: fixes Eli's known voice-to-text mis-transcriptions in the prompt box, after he
// releases the space bar, before he presses Enter. See ../../CLAUDE.md for the whole design.
//
// Why polling: Claude Code puts dictated text in the box without any mods event (prompt.edit fires for
// keys and pastes only; probed 2026-10-27), so the mod reads the box every POLL_MS and treats a change
// no keystroke explains as dictation. Why the space-bar file: Eli pauses 10+ s mid-sentence with space
// held, so only "space is up" (spacebar-watch service) says a recording is over. The box is rewritten
// once space has been up and the box unchanged for SETTLE_MS (the final transcription pass lands ~0.4 s
// after release). prompt.submit applies the same correction if Enter comes first.
//
// Only dictated text is corrected: the span between the box before the dictation and after it. Typed
// text, pastes and recalled history are left alone. A key typed after dictated text whose correction is
// still waiting (a paragraph break) applies the correction first; one typed inside it cancels it, since
// Eli is fixing it by hand.
//
// Footnotes: a "(Third Dawn -> 3rd Dan)" in a submitted prompt (typed or dictated) is Eli teaching a new
// correction. On submit the mod adds it with the voice-corrections CLI (file lock, example and idempotency
// checks), applies it to this message, removes the footnote, and tells Claude in a context line.

//
// Draft autosave (2026-11-26): the same poll also keeps the unsent prompt on disk, typed or dictated, so
// a draft survives the session dying, and one that vanishes from the box without being sent (Esc Esc,
// Ctrl+C, history recall) is kept too. See saveDraft below and "Unsent drafts" in ../../CLAUDE.md.

import { compile, correct, correctSpan, diffSpan, findFootnotes, stripFootnote } from "./corrector.mjs"

const POLL_MS = 100
const SETTLE_MS = 1000
// Dictation counts only if space was seen held within this long before the first dictated text.
const SPACE_LEAD_MS = 3000
const CONFIG_CHECK_MS = 2000
// Drafts: the box is written to <drafts>/<session id>.txt at most this often, once it is DRAFT_MIN long.
const DRAFT_SAVE_MS = 2000
const DRAFT_MIN = 40
// A draft at least this long that is replaced or emptied without a submit gets its own .cleared file.
const DRAFT_LOST_MIN = 200
const DRAFT_KEEP_DAYS = 14

// Per-session state (one module instance per session)
const S = {
  dir: null,
  compiled: [],
  configMtime: -1,
  lastConfigCheck: -Infinity,
  debug: false,
  known: "",       // the box as last explained: a typed edit, our own fill, or a submit
  pending: null,   // { baseline, lastText, lastChange, start }: dictated text awaiting correction
  spaceDownAt: -Infinity,  // last tick that saw space held
  spaceSignal: false,      // the spacebar-watch file exists
  busy: false,
  logQueue: Promise.resolve(),
  // dir: null until session.start; last: the box at the previous tick; saved: what <id>.txt holds;
  // sent: the last submitted text as it stood in the box (so a sent prompt is never kept as "cleared")
  draft: { dir: null, id: "session", last: "", saved: "", savedAt: -Infinity, sent: null },
}

function log($, line) {
  if (!S.debug) return
  const stamp = new Date().toISOString()
  S.logQueue = S.logQueue.then(async () => {
    const path = S.dir + "/debug.log"
    const old = (await $.fs.exists(path)) ? await $.fs.read(path) : ""
    await $.fs.write(path, old.slice(-200000) + stamp + " " + line + "\n")
  }).catch(() => {})
}

// force: check the file's mtime now, not on the CONFIG_CHECK_MS schedule. Done right before every
// correction and submit, so a rule another session added a moment ago always applies.
async function loadConfig($, now, force = false) {
  if (!force && now - S.lastConfigCheck < CONFIG_CHECK_MS) return
  S.lastConfigCheck = now
  const path = S.dir + "/corrections.json"
  try {
    const st = await $.fs.stat(path)
    if (st.mtimeMs === S.configMtime) return
    S.configMtime = st.mtimeMs
    const config = JSON.parse(await $.fs.read(path))
    S.compiled = compile(config.rules)
    log($, `config: ${S.compiled.length} rules`)
  } catch (err) {
    if (S.configMtime !== null) log($, `config unreadable: ${err && err.message}`)
    S.configMtime = null
    S.compiled = []
  }
}

// "0" while space is held, else the epoch ms of the last release; null when the service isn't there.
async function readSpace($) {
  try {
    const v = Number((await $.fs.read(S.dir + "/spacebar")).trim())
    S.spaceSignal = Number.isFinite(v)
    return S.spaceSignal ? v : null
  } catch {
    S.spaceSignal = false
    return null
  }
}

// Keeps the unsent prompt on disk. <id>.txt is the box as of the last DRAFT_SAVE_MS (emptied once the
// box is: sent prompts are in ~/.claude/history.jsonl). <id>.<time>.cleared.txt is a long draft that
// left the box without being sent: less than half of it survives in the new text. Don't make this
// "never overwrite a longer draft": dictation and hand edits shrink the text all the time.
// Errors are swallowed by the caller: a draft that can't be saved must never stop a correction.
async function saveDraft($, now, text) {
  const d = S.draft
  if (!d.dir) return
  const prev = d.last
  d.last = text
  if (text !== prev && prev.length >= DRAFT_LOST_MIN && prev !== d.sent) {
    const { prefix, suffix } = diffSpan(prev, text)
    if (prefix.length + suffix.length < prev.length / 2) {
      const stamp = new Date(now).toISOString().slice(0, 19).replace(/:/g, "-") + "Z"  // UTC
      await $.fs.write(`${d.dir}/${d.id}.${stamp}.cleared.txt`, prev)
      log($, `draft kept: ${prev.length} chars left the box unsent`)
    }
  }
  const keep = text.length >= DRAFT_MIN ? text : ""
  if (keep === d.saved || now - d.savedAt < DRAFT_SAVE_MS) return
  d.savedAt = now
  await $.fs.write(`${d.dir}/${d.id}.txt`, keep)
  d.saved = keep
}

function isDictation(p) {
  // Without the service there's no way to tell dictation from e.g. recalled history; correct anyway
  // (corrections are idempotent, so already-corrected history is unchanged).
  return !S.spaceSignal || S.spaceDownAt >= p.start - SPACE_LEAD_MS
}

function fix(p, text) {
  return correctSpan(p.baseline, text, S.compiled)
}

async function tick($) {
  if (S.busy) return
  S.busy = true
  try {
    const now = await $.clock.now()
    await loadConfig($, now)
    const space = await readSpace($)
    if (space === 0) S.spaceDownAt = now
    const box = await $.prompt.read()
    await saveDraft($, now, box.text).catch(err => log($, `draft not saved: ${err && err.message}`))

    if (!S.pending && box.text !== S.known) {
      S.pending = { baseline: S.known, lastText: box.text, lastChange: now, start: now }
      log($, `dictation? baseline=${JSON.stringify(S.known)}`)
    } else if (S.pending && box.text !== S.pending.lastText) {
      S.pending.lastText = box.text
      S.pending.lastChange = now
      if (box.text === S.pending.baseline) S.pending = null  // cancelled (Esc) or undone
    }
    if (!S.pending || space === null || space === 0) return
    if (now - space < SETTLE_MS || now - S.pending.lastChange < SETTLE_MS) return

    const p = S.pending
    S.pending = null
    await loadConfig($, now, true)
    if (!isDictation(p)) {
      log($, `not dictation (space not held): ${JSON.stringify(p.lastText)}`)
      S.known = p.lastText
      return
    }
    const fixed = fix(p, p.lastText)
    if (fixed === p.lastText) {
      S.known = p.lastText
      log($, "nothing to correct")
      return
    }
    // Re-read right before writing, so a change since the tick began is never overwritten.
    const current = await $.prompt.read()
    if (current.text !== p.lastText) {
      S.pending = { ...p, lastText: current.text, lastChange: await $.clock.now() }
      return
    }
    const filled = await $.prompt.fill({ text: fixed, mode: "replace" })
    S.known = filled.isFilled ? filled.text : p.lastText
    log($, `corrected: ${JSON.stringify(p.lastText)} -> ${JSON.stringify(fixed)} filled=${filled.isFilled}`)
  } finally {
    S.busy = false
  }
}

// Adds each "(A -> B)" footnote as a rule via the CLI beside the mod (host: the repo; containers:
// /host-scripts), applies it to the text, and strips the footnote. Returns the text and context lines.
async function learnFootnotes($, text) {
  const notes = []
  const cli = $.plugin.root + "/../voice-corrections"
  for (const f of findFootnotes(text)) {
    let added = false
    let why = ""
    try {
      const r = await $.process.run(["python3", cli, "add", f.from, f.to, "--note", "from Eli's (A -> B) footnote"])
      added = r.exitCode === 0
      why = (r.stderr || r.stdout).trim().split("\n").slice(-3).join(" ")
    } catch (err) {
      why = String(err && err.message)
    }
    text = stripFootnote(text, f.full)
    text = correct(text, compile([{ from: f.from, to: f.to }]))
    notes.push(added
      ? `voice-corrections: Eli's footnote "${f.full}" was added as a rule and applied to this message (footnote removed). Mention it in one line; no table row needed. If it was not a dictation fix, undo it: voice-corrections remove "${f.from}".`
      : `voice-corrections: Eli's footnote "${f.full}" was applied to this message (footnote removed) but NOT saved as a rule: ${why}. Add it yourself if it can be made to work (e.g. --near words), and say so in one line.`)
    log($, `footnote ${f.full}: added=${added} ${why}`)
  }
  if (notes.length) S.lastConfigCheck = -Infinity  // pick the new rule up on the next tick
  return { text, notes }
}

export function register(on) {
  on("session.start", async ($, e, next) => {
    const home = await $.env.get("HOME")
    S.dir = (home || "") + "/.claude/voice-corrections"
    S.debug = (await $.env.get("VOICE_CORRECTIONS_DEBUG")) === "1"
    await loadConfig($, await $.clock.now())
    try {
      S.draft.id = (await $.session.id()) || "session"
    } catch {}
    S.draft.dir = (home || "") + "/.claude/prompt-drafts"
    // Old drafts go after DRAFT_KEEP_DAYS ($.fs can't delete; a failure only means they stay).
    $.process.run(["find", S.draft.dir, "-type", "f", "-name", "*.txt", "-mtime", "+" + DRAFT_KEEP_DAYS, "-delete"]).catch(() => {})
    $.clock.every(POLL_MS, () => tick($).catch(err => log($, `tick failed: ${err && err.message}`)))
    log($, "started")
    return next(e)
  })

  on("prompt.edit", async ($, e, next) => {
    const p = S.pending
    if (p && e.inputText === " " && e.start === e.end) {
      // Warm-up spaces of a new hold: part of the dictation, not hand edits
      const result = await next(e)
      p.lastText = result.text
      return result
    }
    S.pending = null
    if (p && isDictation(p)) {
      await loadConfig($, await $.clock.now(), true)
      // A key typed after the dictated text (a paragraph break, more typing) lands on the corrected text.
      // One inside the dictated text is Eli fixing it by hand, so the correction is dropped.
      const { suffix } = diffSpan(p.baseline, e.text)
      const fixed = fix(p, e.text)
      const shift = fixed.length - e.text.length
      if (fixed !== e.text && e.start >= e.text.length - suffix.length) {
        log($, `corrected before a typed key: ${JSON.stringify(e.text)} -> ${JSON.stringify(fixed)}`)
        const result = await next({ ...e, text: fixed, cursor: e.cursor + shift, start: e.start + shift, end: e.end + shift })
        S.known = result.text
        return result
      }
      if (fixed !== e.text) log($, `typed inside pending dictation; left as is`)
    }
    const result = await next(e)
    S.known = result.text
    return result
  })

  on("prompt.submit", async ($, e, next) => {
    const p = S.pending
    S.pending = null
    S.known = ""
    S.draft.sent = e.text
    let text = e.text
    if (p) await loadConfig($, await $.clock.now(), true)
    if (p && isDictation(p)) {
      text = fix(p, text)
      if (text !== e.text) log($, `corrected at submit: ${JSON.stringify(e.text)} -> ${JSON.stringify(text)}`)
    }
    const learned = await learnFootnotes($, text)
    if (learned.text === e.text) return next(e)
    const context = learned.notes.length ? [...(e.context ?? []), ...learned.notes] : e.context
    return next({ ...e, text: learned.text, context })
  })
}
