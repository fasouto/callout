import { expect, mock, test, tier } from 'claude-code/testing'

tier('user')

const TOOL = 'mcp__callout__review_document'
const SESSION = { cwd: '/work', surface: 'terminal', isInteractive: true } as const
const RESULT = { id: '0B5B2D4C-8C6E-4F0E-9D6D-1F2A3B4C5D6E', decision: 'feedback', feedback: '## Feedback\n\n1. Shorter, please.' }
const READY = `callout: review ${RESULT.id} is open in Callout\n`

type World = ReturnType<typeof world>

function world(
  on: any,
  options: {
    files?: Map<string, string>
    store?: Record<string, unknown>
    sessionId?: string
    stderrOnLaunch?: string
    exitOnWait?: { stdout: string; code: number }
  } = {},
) {
  const files = options.files ?? new Map<string, string>()
  const runs: string[][] = []
  const submits: string[] = []
  const logs: string[] = []
  const registered: string[] = []
  const tools: string[] = []
  on('session.start', (_: any, e: any) => ({ cwd: e.cwd }))
  on('session.end', (_: any, e: any) => ({ sessionId: e.sessionId }))
  on('session.id', () => ({ value: options.sessionId ?? 's-1' }))
  on('command.register', (_: any, e: any) => {
    registered.push(e.name)
    return { value: { command: e.name } }
  })
  on('tool.register', (_: any, e: any) => {
    tools.push(e.name)
    return { value: { tool: TOOL } }
  })
  on('tool.call', () => ({ result: 'the engine ran it' }))
  mock.env(on, { HOME: '/Users/me' })
  mock.store(on, options.store ?? {})
  const clock = mock.clock(on)
  const isDir = (path: string) => [...files.keys()].some(key => key.startsWith(`${path}/`))
  on('fs.exists', (_: any, e: any) => ({ value: e.path === '/bin/sh' || files.has(e.path) || isDir(e.path) }))
  on('fs.read', (_: any, e: any) => (files.has(e.path) ? { value: files.get(e.path) } : { deny: `ENOENT: ${e.path}` }))
  on('fs.write', (_: any, e: any) => {
    files.set(e.path, e.text)
    return { value: undefined }
  })
  on('fs.stat', (_: any, e: any) => ({ value: { kind: 'dir', size: 0, mtimeMs: Number(files.get(e.path) ?? 0), isLink: false } }))
  on('process.run', (_: any, e: any) => {
    const argv: string[] = [...e.argv]
    runs.push(argv)
    const [, , , step, dir] = argv
    let exitCode = 0
    if (step === 'callout-launch') {
      files.set(`${dir}/stdout`, '')
      files.set(`${dir}/stderr`, options.stderrOnLaunch ?? READY)
      files.set(`${dir}/pid`, '4242\n')
    } else if (step === 'callout-wait' && options.exitOnWait) {
      files.set(`${dir}/stdout`, options.exitOnWait.stdout)
      files.set(`${dir}/exit`, `${options.exitOnWait.code}\n`)
    } else if (step === 'callout-claim') {
      if (files.has(`${dir}/settled`)) exitCode = 1
      else files.set(`${dir}/settled`, String(clock.now()))
    } else if (step === 'callout-remove') {
      for (const key of [...files.keys()]) if (key === dir || key.startsWith(`${dir}/`)) files.delete(key)
    }
    return { value: { exitCode, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('prompt.submit', (_: any, e: any) => {
    submits.push(e.text)
    return { text: e.text, origin: e.origin }
  })
  on('ui.log', (_: any, e: any) => {
    logs.push(e.text)
    return { value: undefined }
  })
  on('ui.toast', () => ({ value: undefined }))
  on('ui.status', () => ({ value: undefined }))
  return { files, runs, submits, logs, registered, tools, clock }
}

function launchOf(w: World): { argv: string[]; dir: string } {
  const argv = w.runs.find(a => a[3] === 'callout-launch')
  if (!argv) throw new Error('nothing was launched')
  return { argv, dir: argv[4]! }
}

function finish(w: World, dir: string, result: unknown = RESULT, code = 0): void {
  w.files.set(`${dir}/stdout`, `${JSON.stringify(result)}\n`)
  w.files.set(`${dir}/exit`, `${code}\n`)
}

test('/callout 2 launches the tool detached for the right reply and answers at once', async ($: any, on: any) => {
  const w = world(on)
  await $.session.start(SESSION)
  expect(w.registered).toEqual(['callout'])
  expect(w.tools).toEqual(['review_document'])

  const { text } = await $.command.run({ command: 'callout', args: '2' })
  expect(text).toBe("Claude's reply 2 back is open in Callout. Your feedback comes back here as a message when you send it.")

  const { argv, dir } = launchOf(w)
  expect(argv.slice(0, 2)).toEqual(['/bin/sh', '-c'])
  expect(dir.startsWith('/Users/me/Library/Caches/Callout/launches/s-1-')).toBe(true)
  expect(argv.slice(5)).toEqual([expect.stringMatching(/\/bin\/callout$/), 'last-reply', '2', '--session', 's-1', '--json'])
  expect(w.runs.some(a => a[3] === 'callout-wait' && a[4] === dir)).toBe(true)
  expect(w.submits).toEqual([])
})

test('/callout with a word answers the usage line and launches nothing', async ($: any, on: any) => {
  const w = world(on)
  await $.session.start(SESSION)
  const { text } = await $.command.run({ command: 'callout', args: 'two' })
  expect(text).toContain('Usage: /callout [replies back]')
  expect(w.runs).toEqual([])
})

test('a finished feedback review is submitted once, then its folder goes', async ($: any, on: any) => {
  const w = world(on)
  await $.session.start(SESSION)
  await $.command.run({ command: 'callout', args: '' })
  const { dir } = launchOf(w)

  await w.clock.advance(1_000)
  expect(w.submits).toEqual([])

  finish(w, dir)
  await w.clock.advance(1_000)
  expect(w.submits).toHaveLength(1)
  expect(w.submits[0]!.startsWith("Callout: the user's feedback on Claude's last reply.\n\n## Feedback\n\n1. Shorter, please.")).toBe(true)
  expect(w.submits[0]).toContain('reply with what you did about every item')
  expect(w.files.has(`${dir}/stdout`)).toBe(false)

  await w.clock.advance(3_000)
  expect(w.submits).toHaveLength(1)
})

test('a cancelled review submits nothing and leaves a log line', async ($: any, on: any) => {
  const w = world(on)
  await $.session.start(SESSION)
  await $.command.run({ command: 'callout', args: '' })
  const { dir } = launchOf(w)
  w.files.set(`${dir}/stderr`, `${READY}callout: The review was cancelled. No feedback was given.\n`)
  finish(w, dir, { id: RESULT.id, decision: 'cancel' })
  await w.clock.advance(1_000)
  expect(w.submits).toEqual([])
  expect(w.logs).toEqual(["Callout: Claude's last reply: The review was cancelled. No feedback was given."])
})

test('a tool that exits before the review opens answers with its own words', async ($: any, on: any) => {
  const w = world(on, {
    stderrOnLaunch: '',
    exitOnWait: { stdout: 'No earlier reply was found in this session, so there is nothing to review.\n', code: 0 },
  })
  await $.session.start(SESSION)
  const { text } = await $.command.run({ command: 'callout', args: '3' })
  expect(text).toBe('No earlier reply was found in this session, so there is nothing to review.')
  await w.clock.advance(2_000)
  expect(w.submits).toEqual([])
})

test('a review restored from the store after a reload is delivered', async ($: any, on: any) => {
  const dir = '/Users/me/Library/Caches/Callout/launches/s-1-0-abc'
  const files = new Map<string, string>([
    [`${dir}/stderr`, READY],
    [`${dir}/pid`, '1\n'],
  ])
  const record = { session: 's-1', kind: 'document', folder: dir, subject: 'cv.pdf', path: '/work/cv.pdf', startedAt: 0, id: RESULT.id }
  const w = world(on, { files, store: { reviews: [record, { ...record, session: 's-other', folder: '/elsewhere' }] } })
  await $.session.start(SESSION)
  finish(w, dir)
  await w.clock.advance(1_000)
  expect(w.submits).toHaveLength(1)
  expect(w.submits[0]!.startsWith("Callout: the user's feedback on cv.pdf.")).toBe(true)
  expect(w.submits[0]).toContain('Apply every item to the source file at /work/cv.pdf')
  expect(w.runs.some(a => a[3] === 'callout-claim' && a[4] === '/elsewhere')).toBe(false)
})

test('review_document denies a relative path and a missing file without launching', async ($: any, on: any) => {
  const w = world(on)
  await $.session.start(SESSION)
  const relative = await $.tool.call({ tool: TOOL, path: 'cv.md' })
  expect(relative.deny).toContain('absolute path')
  const missing = await $.tool.call({ tool: TOOL, path: '/work/missing.md' })
  expect(missing.deny).toBe('There is no file at /work/missing.md.')
  const fromAgent = await $.tool.call({ tool: TOOL, path: '/work/cv.md', agentId: 'a1' })
  expect(fromAgent.deny).toContain('subagent')
  expect(w.runs).toEqual([])
})

test('review_document opens the file with its title and the edits come back for the source', async ($: any, on: any) => {
  const w = world(on, { files: new Map([['/work/cv.md', '# CV']]) })
  await $.session.start(SESSION)
  const { result } = await $.tool.call({ tool: TOOL, path: '/work/cv.md', title: 'CV for Acme' })
  expect(result).toContain('CV for Acme is open in Callout. End your turn now')
  const { argv, dir } = launchOf(w)
  expect(argv.slice(6)).toEqual(['review', '/work/cv.md', '--session', 's-1', '--json', '--title', 'CV for Acme'])

  finish(w, dir, { id: RESULT.id, decision: 'feedback', editedText: '# CV\n\nShorter.' })
  await w.clock.advance(1_000)
  expect(w.submits).toEqual([expect.stringContaining('Write it verbatim to /work/cv.md')])
  expect(w.submits[0]).toContain('# CV\n\nShorter.')
})

test('a non-interactive session registers nothing', async ($: any, on: any) => {
  const w = world(on)
  await $.session.start({ ...SESSION, surface: null, isInteractive: false })
  expect(w.registered).toEqual([])
  expect(w.tools).toEqual([])
})

test('a review another process already claimed is not delivered again', async ($: any, on: any) => {
  const w = world(on)
  await $.session.start(SESSION)
  await $.command.run({ command: 'callout', args: '' })
  const { dir } = launchOf(w)
  finish(w, dir)
  w.files.set(`${dir}/settled`, String(w.clock.now()))
  await w.clock.advance(1_000)
  expect(w.submits).toEqual([])
  expect(w.runs.some(a => a[3] === 'callout-claim')).toBe(false)

  w.files.set(`${dir}/settled/delivered`, '')
  await w.clock.advance(1_000)
  expect(w.submits).toEqual([])
  expect(w.runs.some(a => a[3] === 'callout-claim')).toBe(false)
})
