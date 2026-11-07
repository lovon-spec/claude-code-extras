import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'

const NOW = new Date(2026, 10, 7, 6, 10, 0).getTime()
const SESSION_ID = 'abcd1234-5678-0000-0000-000000000000'

const TRANSCRIPT = JSON.stringify({
  type: 'assistant',
  timestamp: new Date(NOW - 60_000).toISOString(),
  message: {
    model: 'claude-opus-5-5',
    usage: {
      input_tokens: 1,
      cache_read_input_tokens: 500,
      cache_creation_input_tokens: 500,
      cache_creation: { ephemeral_1h_input_tokens: 500, ephemeral_5m_input_tokens: 0 },
    },
  },
})

const USAGE = {
  model: 'claude-opus-5-5',
  input_tokens: 1,
  output_tokens: 2,
  cache_read_input_tokens: 99,
  cache_creation_input_tokens: 0,
}

const band = (surface: 'desktop' | 'terminal') =>
  ({
    plugin: 'desktop-statusline',
    component: 'AbovePrompt',
    surface,
    props: {
      hasSurvey: false,
      isWorking: false,
      maxRows: 12,
      bodyColumns: 200,
      scroll: { offset: 0, bodyRows: 12 },
      view: {},
    },
  }) as const

const engine = (
  on: On,
  options: { isGitDenied?: boolean; runs?: string[][] } = {},
) => {
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.id', () => ({ value: SESSION_ID }))
  on('session.cwd', () => ({ value: '/repo' }))
  on('session.root', () => ({ value: '/repo' }))
  on('session.model', () => ({ value: 'claude-opus-5-5' }))
  on('session.usage', () => ({
    value: {
      startedAt: 0,
      context: { window: 1_000_000, tokens: 300_000, percent: 30 },
      rateLimits: [
        { kind: 'five_hour', percentUsed: 17 },
        { kind: 'seven_day', percentUsed: 22 },
      ],
    },
  }))
  on('session.measure', (_, e) => ({ changed: e.changed }))
  on('env.get', () => ({ value: '/home/vm' }))
  on('process.run', (_, e) => {
    options.runs?.push([...e.argv])

    if (options.isGitDenied && e.argv.includes('git')) {
      return { deny: 'git is unavailable' }
    }

    const stdout =
      e.argv[0] === 'id'
        ? 'vm\n'
        : e.argv[0] === 'hostname'
          ? 'mac\n'
          : e.argv[0] === 'tail'
            ? `${TRANSCRIPT}\n`
            : ''

    // Every git call fails, as outside a repository.
    return {
      value: {
        exitCode: e.argv.includes('git') ? 128 : 0,
        stdout,
        stderr: '',
        isStdoutTruncated: false,
        isStderrTruncated: false,
      },
    }
  })
  on('turn.step', async function* (_, e) {
    yield { kind: 'text', index: 0, text: 'hello', ref: 0 }

    return {
      turnId: e.turnId,
      index: e.index,
      answer: 'hello',
      toolUses: [],
      stopReason: 'end_turn',
      usage: USAGE,
    }
  })
}

const LINE = /vm@mac:\/repo/

test('the band draws the whole line on the desktop surface', async ($, on) => {
  engine(on)
  const clock = mock.clock(on, { now: NOW })

  await $.session.start({ cwd: '/repo', surface: 'desktop', isInteractive: true })
  await clock.advance(5000)

  const ui = await $.ui.mount(band('desktop'))
  const row = await ui.find({ type: 'Text', text: LINE })

  expect(row?.text).toContain('[Opus 5.5] ███░░░░░░░ 30%')
  expect(row?.text).toContain('⚡49%')
  expect(row?.text).toContain('⏳58:55')
  expect(row?.text).toContain('5h17% 7d22%')
  expect(row?.text).toContain('abcd1234')
  await ui.unmount()
})

test('a main-thread request passes through whole and updates the cache figures', async ($, on) => {
  engine(on)
  const clock = mock.clock(on, { now: NOW })

  await $.session.start({ cwd: '/repo', surface: 'desktop', isInteractive: true })
  await clock.advance(1000)

  const chunks: unknown[] = []

  for await (const chunk of $.turn.step({
    turnId: 't',
    index: 0,
    model: 'claude-opus-5-5',
    messageCount: 1,
  })) {
    chunks.push(chunk)
  }

  expect(chunks).toEqual([{ kind: 'text', index: 0, text: 'hello', ref: 0 }])
  await clock.settle()

  const ui = await $.ui.mount(band('desktop'))
  const row = await ui.find({ type: 'Text', text: LINE })

  expect(row?.text).toContain('⚡99%')
  expect(row?.text).toContain('⏳60:00')
  await ui.unmount()
})

test('a subagent request leaves the main cache figures alone', async ($, on) => {
  engine(on)
  const clock = mock.clock(on, { now: NOW })

  await $.session.start({ cwd: '/repo', surface: 'desktop', isInteractive: true })
  await clock.advance(1000)

  for await (const _ of $.turn.step({
    turnId: 't',
    index: 0,
    model: 'claude-haiku-5-5',
    messageCount: 1,
    agentId: 'sub',
  })) {
    // Drained.
  }

  await clock.settle()

  const ui = await $.ui.mount(band('desktop'))
  const row = await ui.find({ type: 'Text', text: LINE })

  expect(row?.text).toContain('⚡49%')
  await ui.unmount()
})

test('on the desktop the expiry warning falls back to a Mac notification, once', async ($, on) => {
  const runs: string[][] = []

  engine(on, { runs })
  const clock = mock.clock(on, { now: NOW })

  // What the engine answers on the desktop, where no terminal notifies.
  on('ui.notify', () => ({ value: { isSent: false, reason: 'no-surface' } }))

  const shown = () => runs.filter(argv => argv[0] === 'osascript')

  await $.session.start({ cwd: '/repo', surface: 'desktop', isInteractive: true })
  await clock.settle()
  // The transcript's response was 60 s before NOW; its 1-hour cache reaches the
  // 5-minute warning 3240 s after NOW.
  await clock.advance(3230_000)
  expect(shown()).toEqual([])

  await clock.advance(120_000)
  expect(shown().length).toBe(1)

  const argv = shown()[0] ?? []

  expect(argv.at(-2)).toContain('send a message to keep it warm')
  expect(argv.at(-2)).toContain('(1k tokens to re-cache otherwise)')
  expect(argv.at(-1)).toBe('repo · abcd1234')
})

test('notifications the person turned off stay off', async ($, on) => {
  const runs: string[][] = []

  engine(on, { runs })
  const clock = mock.clock(on, { now: NOW })

  on('ui.notify', () => ({ value: { isSent: false, reason: 'disabled' } }))

  await $.session.start({ cwd: '/repo', surface: 'desktop', isInteractive: true })
  await clock.settle()
  await clock.advance(3350_000)

  expect(runs.filter(argv => argv[0] === 'osascript')).toEqual([])
})

test('the end of a turn stays the engine\'s to decide', async ($, on) => {
  engine(on)
  mock.clock(on, { now: NOW })
  on('classic.Stop', () => ({ block: 'engine says so' }))

  const answer = await $.classic.Stop({
    transcript_path: '/tmp/session.jsonl',
    stop_hook_active: false,
  })

  expect(answer.block).toBe('engine says so')
})

test('a git read that cannot run says so on the line', async ($, on) => {
  engine(on, { isGitDenied: true })
  const clock = mock.clock(on, { now: NOW })

  await $.session.start({ cwd: '/repo', surface: 'desktop', isInteractive: true })
  await clock.advance(2000)

  const ui = await $.ui.mount(band('desktop'))
  const row = await ui.find({ type: 'Text', text: LINE })

  expect(row?.text).toContain('⚠ git:')
  await ui.unmount()
})

test('the terminal keeps its own statusline', async ($, on) => {
  engine(on)
  const clock = mock.clock(on, { now: NOW })

  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>engine</Text>
  })

  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  await clock.advance(5000)

  const ui = await $.ui.mount(band('terminal'))

  expect((await ui.find({ type: 'Text', text: /engine/ }))?.text).toBe('engine')
  await ui.unmount()
})
