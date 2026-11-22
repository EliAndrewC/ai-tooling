import { expect, mock, test } from 'claude-code/testing'

const DIR = '/home/test/.claude/voice-corrections'
const RULES = JSON.stringify({ rules: [
  { from: 'role', to: 'roll', near: ['dice', 'tact'] },
  { from: 'Asawa', to: 'Isawa' },
] })

// A fake world: the prompt box, the space-bar file, and what the mod wrote into the box.
function world(on, opts: { space?: boolean } = {}) {
  const clock = mock.clock(on, { now: 1_000_000 })
  mock.env(on, { HOME: '/home/test' })
  const w = { box: '', space: String(1_000_000 - 5000), fills: [] as string[], clock }
  on('fs.stat', () => ({ value: { kind: 'file', size: 1, mtimeMs: 1, isLink: false } }))
  on('fs.exists', () => ({ value: false }))
  on('fs.write', () => ({ value: undefined }))
  on('fs.read', ($, e) => {
    if (e.path.endsWith('corrections.json')) return { value: RULES }
    if (e.path.endsWith('spacebar')) return opts.space === false ? { deny: 'ENOENT' } : { value: w.space }
    return { deny: 'unexpected read ' + e.path }
  })
  on('prompt.read', () => ({ value: { text: w.box, cursor: w.box.length } }))
  on('prompt.fill', ($, e) => { w.fills.push(e.text); w.box = e.text; return { isFilled: true } })
  on('prompt.submit', ($, e) => ({ text: e.text }))
  on('session.start', () => ({ cwd: '/work' }))
  return w
}

async function start($) {
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
}

test('rewrites dictated text once space is up and the box has settled', async ($, on) => {
  const w = world(on)
  await start($)
  w.space = '0'                                   // hold space
  await w.clock.advance(300)
  w.box = 'make an open role'                     // provisional text streams in
  await w.clock.advance(300)
  w.box = 'make an open role for tact'
  await w.clock.advance(5000)                     // a long pause while still holding: no rewrite
  expect(w.fills).toEqual([])
  w.space = String(w.clock.now())                 // release
  await w.clock.advance(500)
  expect(w.fills).toEqual([])                     // not yet a full second
  await w.clock.advance(700)
  expect(w.fills).toEqual(['make an open roll for tact'])
})

test('leaves text alone that appeared without the space bar being held', async ($, on) => {
  const w = world(on)
  await start($)
  w.box = 'the role of dice'                      // e.g. recalled history
  await w.clock.advance(3000)
  expect(w.fills).toEqual([])
})

test('corrects at submit when Enter comes before the box settles', async ($, on) => {
  const w = world(on)
  await start($)
  w.space = '0'
  await w.clock.advance(200)
  w.box = 'an Asawa shugenja'
  await w.clock.advance(200)
  w.space = String(w.clock.now())
  await w.clock.advance(200)
  const out = await $.prompt.submit({ text: 'an Asawa shugenja' })
  expect(out.text).toBe('an Isawa shugenja')
  expect(w.fills).toEqual([])
})

test('without the space-bar service, corrects at submit only', async ($, on) => {
  const w = world(on, { space: false })
  await start($)
  w.box = 'an Asawa shugenja'
  await w.clock.advance(3000)
  expect(w.fills).toEqual([])
  const out = await $.prompt.submit({ text: 'an Asawa shugenja' })
  expect(out.text).toBe('an Isawa shugenja')
})

test('a typed prompt is submitted unchanged', async ($, on) => {
  const w = world(on)
  await start($)
  const out = await $.prompt.submit({ text: 'an Asawa shugenja' })
  expect(out.text).toBe('an Asawa shugenja')
})

test('typing a key while a correction waits cancels it; warm-up spaces do not', async ($, on) => {
  const w = world(on)
  on('prompt.edit', ($, e) => {
    const text = e.text.slice(0, e.start) + e.inputText + e.text.slice(e.end)
    return { text, cursor: e.start + e.inputText.length }
  })
  await start($)
  // First dictation, then a second hold whose warm-up space is typed before its text streams in
  w.space = '0'
  await w.clock.advance(200)
  w.box = 'an Asawa'
  await w.clock.advance(200)
  await $.prompt.edit({ origin: { kind: 'composer' }, text: 'an Asawa', cursor: 8, start: 8, end: 8, inputText: ' ' })
  w.box = 'an Asawa shugenja'
  await w.clock.advance(200)
  w.space = String(w.clock.now())
  await w.clock.advance(1500)
  expect(w.fills).toEqual(['an Isawa shugenja'])

  // A dictation, then a key typed INSIDE it before it settles: Eli is fixing it by hand, left alone
  w.space = '0'
  await w.clock.advance(200)
  w.box = 'an Isawa shugenja and Asawa'
  await w.clock.advance(200)
  w.space = String(w.clock.now())
  await $.prompt.edit({ origin: { kind: 'composer' }, text: w.box, cursor: 3, start: 3, end: 3, inputText: 'x' })
  w.box = 'an xIsawa shugenja and Asawa'
  await w.clock.advance(2000)
  expect(w.fills).toEqual(['an Isawa shugenja'])
})

test('a paragraph break typed right after a dictation lands on the corrected text', async ($, on) => {
  const w = world(on)
  on('prompt.edit', ($, e) => {
    const text = e.text.slice(0, e.start) + e.inputText + e.text.slice(e.end)
    return { text, cursor: e.start + e.inputText.length }
  })
  await start($)
  w.space = '0'
  await w.clock.advance(200)
  w.box = 'an Asawa shugenja'
  await w.clock.advance(200)
  w.space = String(w.clock.now())
  await w.clock.advance(300)                      // Enter pressed well inside the 1 s settle time
  const r = await $.prompt.edit({ origin: { kind: 'composer' }, text: w.box, cursor: 17, start: 17, end: 17, inputText: '\n' })
  expect(r.text).toBe('an Isawa shugenja\n')
  w.box = r.text
  await w.clock.advance(2000)
  expect(w.fills).toEqual([])                     // nothing left to rewrite
})

test('a (A -> B) footnote is added as a rule, applied, and removed', async ($, on) => {
  const w = world(on)
  const runs: string[][] = []
  on('process.run', ($, e) => { runs.push(e.argv); return { value: { exitCode: 0, stdout: 'added', stderr: '' } } })
  await start($)
  const out = await $.prompt.submit({ text: 'how Rakugani budgeting works (Rakugani -> Rokugani)' })
  expect(out.text).toBe('how Rokugani budgeting works')
  expect(runs.length).toBe(1)
  expect(runs[0].slice(1, 5)).toEqual([runs[0][1], 'add', 'Rakugani', 'Rokugani'])
  expect(runs[0][1]).toMatch(/voice-corrections\/mod\/\.\.\/voice-corrections$|\/voice-corrections$/)
})

test('a refused footnote is still applied to the message', async ($, on) => {
  const w = world(on)
  on('process.run', () => ({ value: { exitCode: 1, stdout: '', stderr: 'voice-corrections: refused, not idempotent' } }))
  await start($)
  const out = await $.prompt.submit({ text: 'the Third Dawn technique (Third Dawn -> 3rd Dan)' })
  expect(out.text).toBe('the 3rd Dan technique')
})

test('a rule added mid-session applies to the very next dictation', async ($, on) => {
  const clock = mock.clock(on, { now: 1_000_000 })
  mock.env(on, { HOME: '/home/test' })
  const w = { box: '', space: String(1_000_000 - 5000), fills: [] as string[] }
  let rules = JSON.stringify({ rules: [] })
  let mtime = 1
  on('fs.stat', () => ({ value: { kind: 'file', size: 1, mtimeMs: mtime, isLink: false } }))
  on('fs.exists', () => ({ value: false }))
  on('fs.write', () => ({ value: undefined }))
  on('fs.read', ($, e) => e.path.endsWith('corrections.json') ? { value: rules } : { value: w.space })
  on('prompt.read', () => ({ value: { text: w.box, cursor: w.box.length } }))
  on('prompt.fill', ($, e) => { w.fills.push(e.text); w.box = e.text; return { isFilled: true } })
  on('session.start', () => ({ cwd: '/work' }))
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await clock.advance(500)
  rules = JSON.stringify({ rules: [{ from: 'perm AB', to: 'perf-ab' }] })   // another session adds a rule
  mtime = 2
  w.space = '0'                                   // ...and Eli dictates right away
  await clock.advance(200)
  w.box = 'run perm AB'
  await clock.advance(200)
  w.space = String(clock.now())
  await clock.advance(1500)
  expect(w.fills).toEqual(['run perf-ab'])
})
