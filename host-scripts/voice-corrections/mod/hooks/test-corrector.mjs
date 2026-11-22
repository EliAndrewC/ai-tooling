// Unit tests for corrector.mjs, plus a check of the live corrections file's examples.
//   node host-scripts/voice-corrections/mod/hooks/test-corrector.mjs [corrections.json]
// With a corrections file, every rule's "examples" ([dictated, expected] pairs) must come out right,
// and every example must be idempotent. Exit status 1 on any failure.
import { compile, correct, correctSpan, diffSpan, findFootnotes, stripFootnote } from "./corrector.mjs"
import fs from "fs"

let failures = 0
function eq(actual, expected, what) {
  if (actual !== expected) {
    failures++
    console.log(`FAIL ${what}\n  expected: ${JSON.stringify(expected)}\n  actual:   ${JSON.stringify(actual)}`)
  }
}

const rules = compile([
  { from: "Asawa Ishii", to: "Isawa Ishi" },
  { from: "Ishii", to: "Ishi" },
  { from: "claude.md", to: "CLAUDE.md" },
  { from: "Maine", to: "main" },
  { from: "TM", to: "TN", case: "exact" },
  { from: "Don", to: "Dan", case: "exact", near: ["first", "second", "third", "technique"], window: 2 },
  { from: "role", to: "roll", near: ["dice", "tact", "contested", "open", "damage"], not_near: ["discord", "role-playing"] },
  { pattern: ", you know,(?= )", flags: "i", to: "" },
  { pattern: "[\\s,]*\\b(?:uh|um)[,.]?\\s*$", flags: "i", to: "" },
])

eq(correct("the Asawa Ishii third Don technique", rules), "the Isawa Ishi third Dan technique", "phrase and near")
eq(correct("an Ishii", rules), "an Ishi", "word")
eq(correct("Ishiii", rules), "Ishiii", "no partial word")
eq(correct("I don't know, Don", rules), "I don't know, Don", "apostrophe boundary, near missing")
eq(correct("edit claude.md and Claude.md", rules), "edit CLAUDE.md and CLAUDE.md", "capitalized to kept")
eq(correct("landed in Maine", rules), "landed in main", "lowercase to mid-sentence")
eq(correct("Maine is ahead.", rules), "Main is ahead.", "lowercase to at sentence start")
eq(correct("exceeds the TM, not tm", rules), "exceeds the TN, not tm", "exact case")
eq(correct("make an open role for tact", rules), "make an open roll for tact", "near hit")
eq(correct("Role the dice.", rules), "Roll the dice.", "sentence-start capital")
eq(correct("give him the Discord role for dice", rules), "give him the Discord role for dice", "not_near veto")
eq(correct("what role does he play", rules), "what role does he play", "no context")
const phrased = compile([{ from: "role", to: "roll", near: ["open role"], not_near: ["role call"] }])
eq(correct("it was an open role", phrased), "it was an open roll", "near phrase containing the word")
eq(correct("an open role call", phrased), "an open role call", "not_near phrase containing the word")
eq(correct("Not a role call. An open role.", phrased), "Not a role call. An open roll.", "context stops at the sentence end")
eq(correct("edit claude.md for the open role", phrased), "edit claude.md for the open roll", "a dot inside a word is not a sentence end")
eq(correct("I tend to say, you know, a lot", rules), "I tend to say a lot", "filler removed")
eq(correct("that is all. Uh,", rules), "that is all.", "trailing uh")
eq(correct("Uh, what now", rules), "Uh, what now", "leading uh kept")

for (const s of ["the Asawa Ishii third Don technique", "make an open role for tact", "say, you know, a lot. Um,"]) {
  const once = correct(s, rules)
  eq(correct(once, rules), once, `idempotent: ${s}`)
}

eq(JSON.stringify(diffSpan("abc", "abc def")), JSON.stringify({ prefix: "abc", span: " def", suffix: "" }), "diff append")
eq(JSON.stringify(diffSpan("ab   ", "ab hi")), JSON.stringify({ prefix: "ab ", span: "hi", suffix: "" }), "diff warm-up spaces")
eq(correctSpan("", "Role the dice for tact", rules), "Roll the dice for tact", "span: whole box")
eq(correctSpan("I typed role for dice. ", "I typed role for dice. Then an open role", rules),
  "I typed role for dice. Then an open roll", "span: typed prefix untouched")
eq(correctSpan("x Asawa", "x Asawa Ishii", rules), "x Isawa Ishi", "span widened into a phrase begun before it")
eq(correctSpan("start end", "start the third Don end", rules), "start the third Dan end", "span in the middle")

const fn = t => JSON.stringify(findFootnotes(t).map(f => [f.from, f.to]))
eq(fn("how Rakugani budgeting works (Rakugani -> Rokugani)"), '[["Rakugani","Rokugani"]]', "footnote found")
eq(fn("the Third Dawn technique (Third Dawn -> 3rd Dan) and more"), '[["Third Dawn","3rd Dan"]]', "multi-word footnote")
eq(fn("map each field (input -> output)"), "[]", "footnote whose left side isn't in the message")
eq(fn("call f(x -> y) in x"), "[]", "a left side under 3 letters is code, not dictation")
eq(fn("a (b, c -> d) e"), "[]", "punctuation inside is not a footnote")
eq(stripFootnote("how Rakugani works (Rakugani -> Rokugani). Next", "(Rakugani -> Rokugani)"), "how Rakugani works. Next", "footnote stripped")

const file = process.argv[2]
if (file) {
  const config = JSON.parse(fs.readFileSync(file, "utf8"))
  const live = compile(config.rules)
  if (live.length !== config.rules.length) {
    failures++
    console.log(`FAIL ${config.rules.length - live.length} rule(s) in ${file} did not compile`)
  }
  let n = 0
  for (const rule of config.rules) {
    for (const [input, expected] of rule.examples || []) {
      n++
      const once = correct(input, live)
      eq(once, expected, `example of ${rule.from || rule.pattern}: ${input}`)
      eq(correct(once, live), once, `idempotent example of ${rule.from || rule.pattern}`)
    }
  }
  console.log(`${file}: ${config.rules.length} rules, ${n} examples checked`)
}

console.log(failures ? `${failures} failure(s)` : "all passed")
process.exit(failures ? 1 : 0)
