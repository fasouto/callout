// Every call on `$` is in this file so that `claude plugin validate` sees them.

import type { EngineInterface, Register, Timer } from 'claude-code'
import {
  CLAIM_LIFETIME_MS,
  READY_WAIT_MS,
  STORE_KEY,
  USAGE,
  type PendingReview,
  aliveArgv,
  baseName,
  claimArgv,
  deliveryFor,
  fileIn,
  isPendingReview,
  launchArgv,
  launchFolder,
  launchRoot,
  openingText,
  outcomeOf,
  overflowFile,
  parseRepliesBack,
  removeArgv,
  replySubject,
  reviewIdIn,
  toolResultText,
  waitArgv,
  withoutStale,
} from './reviews'

const COMMAND = 'callout'

const TOOL = {
  name: 'review_document',
  description: [
    'Opens a finished document in the Callout app, where the user marks it up by hand (strikes out, replaces, inserts, comments) before it goes out.',
    'Use it right after writing or substantially rewriting a document the user will send to someone else: a CV, a cover letter, a proposal, a blog post, a long email or message. Also when the user asks to review, annotate or mark up a document.',
    'Not for code, plans, short answers or chat replies.',
    'Open the PDF when you generated one (it is what the reader will see), otherwise the source file itself (Markdown, HTML, plain text). Feedback is always applied to the source, never to a PDF.',
    'The call returns as soon as the document is open. End your turn then: the user\'s feedback arrives later as a message from the callout plugin that starts with "Callout:". Do not open another review after applying feedback unless the user asks for one.',
  ].join(' '),
  inputSchema: {
    type: 'object',
    properties: {
      path: { type: 'string', description: 'Absolute path of the finished file: Markdown, plain text, HTML or PDF.' },
      title: { type: 'string', description: 'What the review window calls the document; the file name when left out.' },
    },
    required: ['path'],
  },
  isDeferred: false,
} as const

const ENGINE_EVENT_KEYS = new Set(['tool', 'tool_use_id', 'agentId', 'consent'])
const ALIVE_CHECK_MS = 30_000
const LAUNCH_TIMEOUT_MS = 15_000

let toolName: string | undefined
let shim: string | undefined
let tick: Timer | undefined
let polling = false
const aliveCheckedAt = new Map<string, number>()

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    if (!e.isInteractive || !(await $.fs.exists('/bin/sh'))) return started
    shim = `${$.plugin.root}/bin/callout`
    await $.command.register({
      name: COMMAND,
      description: "Open Claude's last reply in Callout to mark it up, or with a number an earlier one.",
      argumentHint: '[replies back]',
    })
    toolName = (await $.tool.register(TOOL)).tool
    await poll($)
    return started
  })

  on('session.end', ($, e, next) => {
    stopTick()
    return next(e)
  })

  on('command.run', { command: COMMAND }, async ($, e) => {
    const back = parseRepliesBack(e.args)
    if (back === undefined) return { text: USAGE }
    const session = await $.session.id()
    const opened = await open($, { session, kind: 'reply', subject: replySubject(back) }, [
      'last-reply',
      String(back),
      '--session',
      session,
      '--json',
    ])
    return { text: opened.ok ? openingText(opened.review) : opened.message }
  }).catch(() => ({ text: 'Callout could not start the review.' }))

  on('tool.call', async ($, e, next) => {
    if (toolName === undefined || e.tool !== toolName) return next(e)
    if (e.agentId !== undefined) return { deny: 'Callout reviews are opened from the main conversation only, not from a subagent.' }
    const args = Object.fromEntries(Object.entries(e).filter(([key]) => !ENGINE_EVENT_KEYS.has(key)))
    const path = typeof args.path === 'string' ? args.path : ''
    const title = typeof args.title === 'string' && args.title.trim() !== '' ? args.title.trim() : undefined
    if (!path.startsWith('/')) return { deny: `review_document takes the absolute path of the finished file; ${JSON.stringify(path)} is not one.` }
    if (!(await $.fs.exists(path))) return { deny: `There is no file at ${path}.` }
    const session = await $.session.id()
    const opened = await open($, { session, kind: 'document', subject: title ?? baseName(path), path }, [
      'review',
      path,
      '--session',
      session,
      '--json',
      ...(title === undefined ? [] : ['--title', title]),
    ])
    return opened.ok ? { result: toolResultText(opened.review) } : { deny: opened.message }
  }).catch(($, e, next) => (next.called ? next(e) : { deny: 'Callout could not start the review.' }))
}

type Opened = { ok: true; review: PendingReview } | { ok: false; message: string }

async function open($: EngineInterface, review: Omit<PendingReview, 'folder' | 'startedAt'>, toolArgs: readonly string[]): Promise<Opened> {
  const home = await $.env.get('HOME')
  if (home === undefined || shim === undefined) return { ok: false, message: 'Callout could not start the review: HOME is not set.' }
  const now = await $.clock.now()
  const folder = launchFolder(launchRoot(home), review.session, now, Math.random().toString(36).slice(2, 10))
  const record: PendingReview = { ...review, folder, startedAt: now }

  const all = await pendingReviews($)
  const kept = withoutStale(all, now)
  await $.store.set(STORE_KEY, [...kept, record])
  for (const stale of all.filter(r => !kept.includes(r))) await $.process.run(removeArgv(stale.folder))

  const launched = await $.process.run(launchArgv(folder, [shim, ...toolArgs]), { timeoutMs: LAUNCH_TIMEOUT_MS })
  if (launched.exitCode !== 0) {
    await forget($, record)
    return { ok: false, message: `Callout could not start the review: ${launched.stderr.trim() || `the launcher exited with status ${launched.exitCode}`}.` }
  }
  await $.process.run(waitArgv(folder, READY_WAIT_MS), { timeoutMs: READY_WAIT_MS + LAUNCH_TIMEOUT_MS })

  const output = await readOutput($, folder)
  if (output.exitCode !== undefined) {
    const outcome = outcomeOf(output.stdout, output.stderr, output.exitCode)
    if (outcome.kind === 'silent') {
      await forget($, record)
      await $.process.run(removeArgv(folder))
      return { ok: false, message: outcome.reason }
    }
  }
  const opened = await noteId($, record, output.stderr)
  startTick($)
  return { ok: true, review: opened }
}

async function readOutput($: EngineInterface, folder: string): Promise<{ stdout: string; stderr: string; exitCode: number | undefined }> {
  const exit = await readIfExists($, fileIn(folder, 'exit'))
  return {
    stdout: await readIfExists($, fileIn(folder, 'stdout')),
    stderr: await readIfExists($, fileIn(folder, 'stderr')),
    exitCode: exit.trim() === '' ? undefined : Number(exit.trim()),
  }
}

async function readIfExists($: EngineInterface, path: string): Promise<string> {
  return (await $.fs.exists(path)) ? $.fs.read(path) : ''
}

async function noteId($: EngineInterface, review: PendingReview, stderr: string): Promise<PendingReview> {
  const id = review.id ?? reviewIdIn(stderr)
  if (id === undefined || id === review.id) return review
  const named = { ...review, id }
  await updateReviews($, all => all.map(r => (r.folder === review.folder ? named : r)))
  return named
}

async function pendingReviews($: EngineInterface): Promise<PendingReview[]> {
  const stored = await $.store.get(STORE_KEY)
  return Array.isArray(stored) ? stored.filter(isPendingReview) : []
}

// The store is one file shared by every Claude Code process, so a write starts from a fresh read.
async function updateReviews($: EngineInterface, change: (all: PendingReview[]) => PendingReview[]): Promise<void> {
  await $.store.set(STORE_KEY, change(await pendingReviews($)))
}

async function forget($: EngineInterface, review: PendingReview): Promise<void> {
  await updateReviews($, all => all.filter(r => r.folder !== review.folder))
}

function startTick($: EngineInterface): void {
  tick ??= $.clock.every(1000, () => void poll($))
}

function stopTick(): void {
  tick?.cancel()
  tick = undefined
}

async function poll($: EngineInterface): Promise<void> {
  if (polling) return
  polling = true
  try {
    // Read on every pass: a /clear changes the id with no session.start.
    const session = await $.session.id()
    const mine = (await pendingReviews($)).filter(r => r.session === session)
    if (mine.length === 0) return stopTick()
    startTick($)
    for (const review of mine) await settle($, review)
  } finally {
    polling = false
  }
}

async function settle($: EngineInterface, pending: PendingReview): Promise<void> {
  const { folder } = pending
  if (!(await $.fs.exists(folder))) return forget($, pending)
  if (await $.fs.exists(fileIn(folder, 'settled'))) return claimedAlready($, pending)
  const review = await noteId($, pending, await readIfExists($, fileIn(folder, 'stderr')))
  const finished = (await $.fs.exists(fileIn(folder, 'exit'))) || (await stoppedWithoutResult($, review))
  if (!finished) return
  if ((await $.process.run(claimArgv(folder))).exitCode !== 0) return

  const output = await readOutput($, folder)
  const outcome = outcomeOf(output.stdout, output.stderr, output.exitCode)
  const file = overflowFile(review, outcome)
  if (file !== undefined && outcome.kind === 'edited') await $.fs.write(file, outcome.text)
  const delivery = deliveryFor(review, outcome)
  if ('submit' in delivery) await $.prompt.submit({ text: delivery.submit })
  else $.ui.log(delivery.log)
  await $.fs.write(fileIn(folder, 'delivered'), '')
  await forget($, review)
  if (file === undefined) await $.process.run(removeArgv(folder))
}

async function claimedAlready($: EngineInterface, review: PendingReview): Promise<void> {
  if (await $.fs.exists(fileIn(review.folder, 'delivered'))) return forget($, review)
  const claimed = await $.fs.stat(fileIn(review.folder, 'settled'))
  if ((await $.clock.now()) - claimed.mtimeMs < CLAIM_LIFETIME_MS) return
  const recover = review.id === undefined ? '' : `; \`callout result ${review.id}\` prints it`
  $.ui.log(`Callout: ${review.subject} finished, but its result was not delivered${recover}.`)
  await forget($, review)
  await $.process.run(removeArgv(review.folder))
}

async function stoppedWithoutResult($: EngineInterface, review: PendingReview): Promise<boolean> {
  const now = await $.clock.now()
  const checkedAt = aliveCheckedAt.get(review.folder) ?? review.startedAt
  if (now - checkedAt < ALIVE_CHECK_MS) return false
  aliveCheckedAt.set(review.folder, now)
  return (await $.process.run(aliveArgv(review.folder))).exitCode !== 0
}
