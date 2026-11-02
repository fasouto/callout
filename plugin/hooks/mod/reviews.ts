// Nothing in this file calls `$`: `claude plugin validate` follows the engine
// calls in register.ts, and the logic here is tested without the engine.

export type ReviewKind = 'reply' | 'document'

export type PendingReview = {
  session: string
  kind: ReviewKind
  folder: string
  subject: string
  startedAt: number
  path?: string
  id?: string
}

export type Outcome =
  | { kind: 'feedback'; feedback: string }
  | { kind: 'edited'; text: string }
  | { kind: 'approved' }
  | { kind: 'silent'; reason: string }

export type Delivery = { submit: string } | { log: string }

export const STORE_KEY = 'reviews'
export const RECORD_LIFETIME_MS = 7 * 24 * 60 * 60 * 1000
export const CLAIM_LIFETIME_MS = 10 * 60 * 1000
export const READY_WAIT_MS = 3_000
export const INLINE_TEXT_LIMIT = 12 * 1024
/** What the callout tool writes to stderr once the app has the review. */
export const READY_MARK = 'is open in Callout'

export const FILES = {
  stdout: 'stdout',
  stderr: 'stderr',
  pid: 'pid',
  exit: 'exit',
  settled: 'settled',
  delivered: 'settled/delivered',
  edited: 'edited.md',
} as const

export function fileIn(folder: string, name: keyof typeof FILES): string {
  return `${folder}/${FILES[name]}`
}

export function launchRoot(home: string): string {
  return `${home.replace(/\/+$/, '')}/Library/Caches/Callout/launches`
}

export function launchFolder(root: string, session: string, now: number, nonce: string): string {
  return `${root}/${session.slice(0, 8)}-${now}-${nonce}`
}

export function replySubject(back: number): string {
  return back === 1 ? "Claude's last reply" : `Claude's reply ${back} back`
}

export function baseName(path: string): string {
  return path.slice(path.lastIndexOf('/') + 1)
}

export function parseRepliesBack(args: string): number | undefined {
  const text = args.trim()
  if (text === '') return 1
  if (!/^[0-9]+$/.test(text)) return undefined
  const back = Number(text)
  return back >= 1 ? back : undefined
}

export const USAGE = 'Usage: /callout [replies back]. The number says which reply to review: 2 is the one before the last, 3 the one before that; nothing reviews the last reply.'

// `$.process.run` ends at ten minutes and a `$.process.spawn` child dies with a
// module reload, and a review can outlast both, so the tool runs detached.
export const LAUNCH_SCRIPT = [
  'dir=$1; shift',
  'umask 077',
  'mkdir -p "$dir" && : > "$dir/stdout" && : > "$dir/stderr" || exit 1',
  '(',
  "  trap '' HUP",
  '  nohup "$@" < /dev/null > "$dir/stdout" 2> "$dir/stderr" &',
  '  child=$!',
  '  echo "$child" > "$dir/pid"',
  '  wait "$child"',
  '  code=$?',
  '  echo "$code" > "$dir/exit.tmp" && mv "$dir/exit.tmp" "$dir/exit"',
  ') < /dev/null > /dev/null 2>&1 &',
].join('\n')

export const WAIT_SCRIPT = [
  'dir=$1; n=$2; i=0',
  'while [ "$i" -lt "$n" ]; do',
  '  [ -e "$dir/exit" ] && exit 0',
  `  grep -q "${READY_MARK}" "$dir/stderr" 2>/dev/null && exit 0`,
  '  sleep 0.1',
  '  i=$((i+1))',
  'done',
  'exit 1',
].join('\n')

export function launchArgv(folder: string, toolArgv: readonly string[]): string[] {
  return ['/bin/sh', '-c', LAUNCH_SCRIPT, 'callout-launch', folder, ...toolArgv]
}

export function waitArgv(folder: string, timeoutMs: number): string[] {
  return ['/bin/sh', '-c', WAIT_SCRIPT, 'callout-wait', folder, String(Math.max(1, Math.ceil(timeoutMs / 100)))]
}

/** Succeeds for exactly one caller: `mkdir` is atomic. */
export function claimArgv(folder: string): string[] {
  return ['/bin/sh', '-c', 'mkdir "$1/settled" 2>/dev/null', 'callout-claim', folder]
}

export function aliveArgv(folder: string): string[] {
  return ['/bin/sh', '-c', 'kill -0 "$(cat "$1/pid")" 2>/dev/null', 'callout-alive', folder]
}

export function removeArgv(folder: string): string[] {
  return ['/bin/sh', '-c', 'rm -rf -- "$1"', 'callout-remove', folder]
}

export function reviewIdIn(stderr: string): string | undefined {
  return new RegExp(`callout: review ([0-9A-Fa-f-]{36}) ${READY_MARK}`).exec(stderr)?.[1]
}

function openVerb(review: Pick<PendingReview, 'id'>): string {
  return review.id === undefined ? 'is opening in Callout' : READY_MARK
}

export function openingText(review: Pick<PendingReview, 'subject' | 'id'>): string {
  return `${review.subject} ${openVerb(review)}. Your feedback comes back here as a message when you send it.`
}

export function toolResultText(review: Pick<PendingReview, 'subject' | 'id'>): string {
  return [
    `${review.subject} ${openVerb(review)}. End your turn now and wait: the user's response arrives later as a message from the callout plugin that starts with "Callout:".`,
    'Do not run callout, poll for the result, or open another review.',
  ].join(' ')
}

export function outcomeOf(stdout: string, stderr: string, exitCode: number | undefined): Outcome {
  const result = parseResult(stdout)
  if (result === undefined) {
    const said = stdout.trim() || stderrMessage(stderr)
    const stopped = exitCode === undefined ? 'the callout tool stopped before the review finished' : `the callout tool exited with status ${exitCode} and no result`
    return { kind: 'silent', reason: said || stopped }
  }
  switch (result.decision) {
    case 'feedback':
      if (result.editedText !== undefined) return { kind: 'edited', text: result.editedText }
      if (result.feedback !== undefined) return { kind: 'feedback', feedback: result.feedback }
      return { kind: 'approved' }
    case 'approve':
      return { kind: 'approved' }
    default:
      return { kind: 'silent', reason: stderrMessage(stderr) || 'the review was cancelled' }
  }
}

type ToolResult = { decision: string; feedback?: string; editedText?: string }

function parseResult(stdout: string): ToolResult | undefined {
  const line = stdout.trim()
  if (!line.startsWith('{')) return undefined
  try {
    const parsed: unknown = JSON.parse(line)
    if (typeof parsed !== 'object' || parsed === null) return undefined
    const { decision, feedback, editedText } = parsed as Record<string, unknown>
    if (typeof decision !== 'string') return undefined
    return {
      decision,
      ...(typeof feedback === 'string' ? { feedback } : {}),
      ...(typeof editedText === 'string' ? { editedText } : {}),
    }
  } catch {
    return undefined
  }
}

function stderrMessage(stderr: string): string {
  return stderr
    .split('\n')
    .map(line => line.replace(/^callout: /, '').trim())
    .filter(line => line !== '' && !line.includes(READY_MARK))
    .join('\n')
}

const REPLY_GUIDANCE = [
  'Each numbered item quotes the exact text it refers to; an "Insert after" or "Comment after" item quotes the text beside a spot instead, where an insert\'s words go and a comment is a note about that spot, not text to add. "Expand" asks for more on the quoted passage and "Summarize" for the same in fewer words; "Keep as is" lists text that must not change; "General" applies to the whole reply.',
  'A deletion, replacement or insertion that edits the wording is a correction: apply it. A comment or an inserted note may instead be an instruction, a question, or something new the user is telling you: carry out the instruction, answer the question, take up the new point.',
  'Then reply with what you did about every item. Write out a revised reply only when the feedback corrects its text; when the user was answering the reply, do the work it asks for instead of rewriting the reply. Do not defend the original wording, and do not change anything the feedback did not ask to change.',
].join('\n\n')

function documentGuidance(path: string | undefined): string {
  const source = path === undefined ? 'the source file' : `the source file at ${path}`
  return [
    'Each numbered item quotes the exact text it refers to, with a page number for a PDF; search the source for the quote to find the place. An "Insert after" or "Comment after" item quotes the text beside a spot instead: an insert\'s words go there, and a comment is a note about that spot, not text to add. "Expand" asks for more on the quoted passage and "Summarize" for the same in fewer words; "Keep as is" lists text that must not change; "General" applies to the whole document.',
    `Apply every item to ${source} (or to the file it was generated from, never to a PDF), change nothing else, then regenerate the output if there is one. A comment that asks you something is a question: leave that text as it is and answer it. Finish with a short summary of what changed, item by item, with the answers to any questions.`,
  ].join('\n\n')
}

function editedTarget(review: PendingReview): string {
  return review.path === undefined
    ? 'Treat it as the corrected text of that reply.'
    : `Write it verbatim to ${review.path} (or to the file the document was generated from, then regenerate the output), and change nothing else.`
}

export function overflowFile(review: PendingReview, outcome: Outcome): string | undefined {
  return outcome.kind === 'edited' && outcome.text.length > INLINE_TEXT_LIMIT ? fileIn(review.folder, 'edited') : undefined
}

const DELIVERIES: { [K in Outcome['kind']]: (review: PendingReview, outcome: Extract<Outcome, { kind: K }>) => Delivery } = {
  feedback: (review, outcome) => ({
    submit: [
      `Callout: the user's feedback on ${review.subject}.`,
      outcome.feedback.trim(),
      review.kind === 'reply' ? REPLY_GUIDANCE : documentGuidance(review.path),
    ].join('\n\n'),
  }),
  edited: (review, outcome) => {
    const file = overflowFile(review, outcome)
    return {
      submit: [
        `Callout: the user edited ${review.subject} directly.`,
        file === undefined
          ? `${editedTarget(review)} The text:\n\n${outcome.text}`
          : `Read the edited text from ${file}. ${editedTarget(review)}`,
      ].join('\n\n'),
    }
  },
  approved: review => ({ submit: `Callout: the user approved ${review.subject} without changes.` }),
  silent: (review, outcome) => ({ log: `Callout: ${review.subject}: ${outcome.reason}` }),
}

export function deliveryFor(review: PendingReview, outcome: Outcome): Delivery {
  const deliver = DELIVERIES[outcome.kind] as (review: PendingReview, outcome: Outcome) => Delivery
  return deliver(review, outcome)
}

export function isPendingReview(value: unknown): value is PendingReview {
  if (typeof value !== 'object' || value === null) return false
  const record = value as Record<string, unknown>
  return (
    typeof record.session === 'string' &&
    (record.kind === 'reply' || record.kind === 'document') &&
    typeof record.folder === 'string' &&
    typeof record.subject === 'string' &&
    typeof record.startedAt === 'number'
  )
}

export function withoutStale(reviews: readonly PendingReview[], now: number): PendingReview[] {
  return reviews.filter(review => now - review.startedAt < RECORD_LIFETIME_MS)
}
