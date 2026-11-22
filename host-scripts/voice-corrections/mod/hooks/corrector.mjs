// Applies Eli's voice-to-text corrections to a piece of dictated text. Pure functions, no mods API, so
// node can test them directly (test-corrector.mjs) and register.js can import them.
//
// The rules come from ~/.claude/voice-corrections/corrections.json, in order. Three kinds:
//   { "from": "Asawa Ishii", "to": "Isawa Ishi" }        whole words, case-insensitive
//   { "from": "role", "to": "roll", "near": [...], "not_near": [...], "window": 5 }
//                                                         only when a `near` word/phrase is within
//                                                         `window` words, and no `not_near` one is;
//                                                         a phrase may include the word itself ("open role")
//   { "pattern": ", you know,(?= )", "flags": "i", "to": "" }   a JS regular expression ($1 etc.)
// Optional on `from` rules: "case": "exact" matches only that exact spelling.
//
// Output case: a `to` with any capital letter is used as written (CLAUDE.md, Rokugan). An all-lowercase
// `to` is capitalized only at the start of a sentence, so "Role ..." -> "Roll ..." but "in Maine" ->
// "in main". Corrections must be idempotent: applying them twice gives the same text as once.

const WORD = "\\p{L}\\p{N}_'’"

function escapeRegex(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

// Whole-word match of `phrase`: not touching a letter, digit, underscore or apostrophe on either
// side, so "Don" never matches inside "Don't". Spaces in the phrase match any run of whitespace.
function wordRegex(phrase, flags) {
  const body = phrase.trim().split(/\s+/).map(escapeRegex).join("\\s+")
  return new RegExp(`(?<![${WORD}])${body}(?![${WORD}])`, flags)
}

function atSentenceStart(text, index) {
  const before = text.slice(0, index)
  return /^\s*$/.test(before) || /[.!?]["')\]]?\s+$/.test(before)
}

function caseFor(to, matched, text, index) {
  if (/\p{Lu}/u.test(to) || !to) return to
  if (/^\p{Lu}/u.test(matched) && atSentenceStart(text, index)) return to[0].toUpperCase() + to.slice(1)
  return to
}

function words(s) {
  return s.toLowerCase().match(new RegExp(`[${WORD}]+(?:[.-][${WORD}]+)*`, "gu")) || []
}

// True if any of `phrases` occurs as whole words in `context` (an array of lowercased words).
function contains(context, phrases) {
  const joined = " " + context.join(" ") + " "
  return phrases.some(p => joined.includes(" " + words(p).join(" ") + " "))
}

function contextOk(rule, text, index, length) {
  const window = rule.window || 5
  // Context stops at sentence ends, so one sentence's words don't trigger or veto the next one's.
  const head = text.slice(0, index).split(/[.!?;]+(?:\s+|$)/u).pop()
  const tail = text.slice(index + length).split(/[.!?;]+(?:\s+|$)/u)[0]
  const before = words(head).slice(-window)
  const after = words(tail).slice(0, window)
  // The matched words are part of the context, so a phrase can include them ("open role", "role call").
  const context = before.concat(words(text.slice(index, index + length)), after)
  if (rule.not_near && contains(context, rule.not_near)) return false
  if (rule.near && !contains(context, rule.near)) return false
  return true
}

export function compile(rules) {
  const compiled = []
  for (const rule of rules || []) {
    try {
      if (rule.pattern) {
        const flags = (rule.flags || "").replace(/[gu]/g, "") + "gu"
        compiled.push({ rule, re: new RegExp(rule.pattern, flags) })
      } else if (rule.from && typeof rule.to === "string") {
        const flags = rule.case === "exact" ? "gu" : "giu"
        compiled.push({ rule, re: wordRegex(rule.from, flags) })
      }
    } catch (err) {
      // A bad pattern skips that rule only; voice-corrections check reports it
    }
  }
  return compiled
}

export function correct(text, compiled) {
  for (const { rule, re } of compiled) {
    re.lastIndex = 0
    if (rule.pattern) {
      text = text.replace(re, rule.to)
      continue
    }
    const source = text
    text = source.replace(re, (matched, ...rest) => {
      const index = rest[rest.length - 2]
      if ((rule.near || rule.not_near) && !contextOk(rule, source, index, matched.length)) return matched
      return caseFor(rule.to, matched, source, index)
    })
  }
  return text
}

// Where `after` differs from `before`: the common prefix and suffix are kept, the middle is what was
// inserted or replaced (the dictated span). Returns { prefix, span, suffix } with prefix + span + suffix
// === after.
export function diffSpan(before, after) {
  let p = 0
  const max = Math.min(before.length, after.length)
  while (p < max && before[p] === after[p]) p++
  let s = 0
  while (s < max - p && before[before.length - 1 - s] === after[after.length - 1 - s]) s++
  return { prefix: after.slice(0, p), span: after.slice(p, after.length - s), suffix: after.slice(after.length - s) }
}

// Corrects only the part of `after` that differs from `before`. The span is widened to whole words
// (a dictated chunk can share its first letters with what was there), and the text before it is passed
// as context for sentence-start capitalization and `near` rules.
export function correctSpan(before, after, compiled) {
  let { prefix, span, suffix } = diffSpan(before, after)
  const head = prefix.match(new RegExp(`[${WORD}]*$`, "u"))[0]
  const tail = suffix.match(new RegExp(`^[${WORD}]*`, "u"))[0]
  prefix = prefix.slice(0, prefix.length - head.length)
  suffix = suffix.slice(tail.length)
  span = head + span + tail
  if (!span.trim()) return after
  // Correct prefix+span together so sentence starts and `near` context see what came before, then keep
  // the prefix exactly as it was (typed text is never changed).
  const fixed = correct(prefix + span, compiled)
  const fixedPrefix = fixed.slice(0, prefix.length)
  if (fixedPrefix !== prefix) {
    // A rule reached back into the prefix; fall back to the span on its own.
    return prefix + correct(span, compiled) + suffix
  }
  return fixed + suffix
}

// Eli's inline dictation fixes: "(Third Dawn -> 3rd Dan)". Each side is 1-5 words of letters, digits,
// apostrophes, hyphens or dots. A footnote counts only when its left side also appears in the message
// outside the parentheses, and has 3+ letters, so "(input -> output)" or "f(x -> y)" written about code
// isn't taken as a dictation fix.
// Returns [{ full, from, to }]; stripFootnote removes one from the text along with the space before it.
const FOOTNOTE = /\(\s*([\p{L}\p{N}'’.-]+(?:\s+[\p{L}\p{N}'’.-]+){0,4})\s*->\s*([\p{L}\p{N}'’.-]+(?:\s+[\p{L}\p{N}'’.-]+){0,4})\s*\)/gu

export function findFootnotes(text) {
  const found = []
  for (const m of text.matchAll(FOOTNOTE)) {
    const [full, from, to] = m
    if (from === to || (from.match(/\p{L}/gu) || []).length < 3) continue
    const rest = text.slice(0, m.index) + text.slice(m.index + full.length)
    if (!wordRegex(from, "iu").test(rest)) continue
    found.push({ full, from, to })
  }
  return found
}

export function stripFootnote(text, full) {
  const i = text.indexOf(full)
  if (i < 0) return text
  let start = i
  while (start > 0 && /[ \t]/.test(text[start - 1])) start--
  return text.slice(0, start) + text.slice(i + full.length)
}
