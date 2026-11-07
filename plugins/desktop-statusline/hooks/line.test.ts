import { expect, test } from 'claude-code/testing'

import type { Line } from '../types'
import { bar, EMPTY, modelName, readTranscript, secondsLeft, segments } from './line'

const NOW = new Date(2026, 10, 7, 6, 10, 0).getTime()

const FULL: Line = {
  ...EMPTY,
  now: NOW,
  user: 'vm',
  host: 'mac',
  cwd: '/repo',
  sessionId: 'abcd1234-5678',
  model: 'claude-opus-5-5',
  contextPercent: 30,
  fiveHour: { percent: 17 },
  sevenDay: { percent: 22 },
  git: {
    dirty: 3,
    ahead: 2,
    behind: 1,
    merge: 'clean',
    upstream: 0,
    primary: 'main',
    primaryUpstream: 4,
  },
  cache: {
    read: 9900,
    created: 90,
    input: 10,
    respondedAt: NOW - (3600 - 54 * 60 - 7) * 1000,
  },
  ttl: '1h',
}

const text = (line: Line) =>
  segments(line)
    .map(seg => seg.text)
    .join('')

const colorOf = (line: Line, pattern: RegExp) =>
  segments(line).find(seg => pattern.test(seg.text))?.color

test('the line reads as the CLI script prints it, in the same order', () => {
  expect(text(FULL)).toBe(
    'vm@mac:/repo ●3 [Opus 5.5] ███░░░░░░░ 30% +2/-1 ✓ ⇡0 main⇡4 ⚡99% ⏳54:07 5h17% 7d22% 2026-11-07 06:10:00 abcd1234',
  )
})

test('figures the engine does not have are left out', () => {
  expect(text({ ...EMPTY, now: NOW, cwd: '/repo', model: 'opus' })).toBe(
    '/repo [opus] 2026-11-07 06:10:00',
  )
})

test('a clean tree shows no dirty mark', () => {
  expect(text({ ...FULL, git: { dirty: 0 } })).not.toContain('●')
})

test('a merge that would conflict shows a warning', () => {
  const line = { ...FULL, git: { dirty: 0, ahead: 1, behind: 1, merge: 'conflict' as const } }

  expect(text(line)).toContain('+1/-1 ⚠')
  expect(colorOf(line, /⚠/)).toBe('error')
})

test('the context bar rounds as the script does and stays ten wide', () => {
  expect(bar(0)).toBe('░░░░░░░░░░')
  expect(bar(4)).toBe('░░░░░░░░░░')
  expect(bar(5)).toBe('█░░░░░░░░░')
  expect(bar(100)).toBe('██████████')
  expect(bar(130)).toBe('██████████')
})

test('the cache hit colors change at 90 and 50 percent', () => {
  const hit = (read: number) => ({
    ...FULL,
    cache: { read, created: 100 - read, input: 0, respondedAt: NOW },
  })

  expect(colorOf(hit(90), /⚡/)).toBe('success')
  expect(colorOf(hit(89), /⚡/)).toBe('warning')
  expect(colorOf(hit(50), /⚡/)).toBe('warning')
  expect(colorOf(hit(49), /⚡/)).toBe('error')
})

test('the countdown warns near expiry on a 1-hour cache', () => {
  const left = (seconds: number): Line => ({
    ...FULL,
    cache: { read: 1, created: 0, input: 0, respondedAt: NOW - (3600 - seconds) * 1000 },
  })

  expect(colorOf(left(301), /⏳/)).toBe('success')
  expect(colorOf(left(300), /⏳/)).toBe('warning')
  expect(colorOf(left(150), /⏳/)).toBe('error')
  expect(secondsLeft(left(61))).toBe(61)
})

test('a 5-minute cache counts from five minutes with its own threshold', () => {
  const line: Line = {
    ...FULL,
    ttl: '5m',
    cache: { read: 1, created: 0, input: 0, respondedAt: NOW - 240 * 1000 },
  }

  expect(text(line)).toContain('⏳1:00')
  expect(colorOf(line, /⏳/)).toBe('warning')
})

test('a cold cache shows the dim cross, and no cache tokens show no timer', () => {
  const cold: Line = {
    ...FULL,
    cache: { read: 1, created: 0, input: 0, respondedAt: NOW - 3601 * 1000 },
  }

  expect(text(cold)).toContain('⏳✗')
  expect(
    text({ ...FULL, cache: { read: 0, created: 0, input: 5, respondedAt: NOW } }),
  ).not.toContain('⏳')
  expect(text({ ...FULL, ttl: undefined })).not.toContain('⏳')
})

test('a rate window at 90 percent shows when it resets', () => {
  const line: Line = {
    ...FULL,
    fiveHour: { percent: 94, resetsAt: NOW + (3600 + 40 * 60) * 1000 },
    sevenDay: { percent: 70 },
  }

  expect(text(line)).toContain('5h94%(1h40) 7d70%')
  expect(colorOf(line, /5h/)).toBe('error')
  expect(colorOf(line, /7d/)).toBe('warning')
})

test('model ids read as the CLI names them', () => {
  expect(modelName('claude-opus-5-5')).toBe('Opus 5.5')
  expect(modelName('claude-fable-5-1')).toBe('Fable 5.1')
  expect(modelName('claude-sonnet-5')).toBe('Sonnet 5')
  expect(modelName('claude-opus-5-5[1m]')).toBe('Opus 5.5 (1M context)')
  expect(modelName('some-gateway-alias')).toBe('some-gateway-alias')
})

const record = (fields: Record<string, unknown>, usage: Record<string, unknown>) =>
  JSON.stringify({
    type: 'assistant',
    timestamp: '2026-11-07T11:00:00.000Z',
    message: { model: 'claude-opus-5-5', usage },
    ...fields,
  })

test('a transcript gives the newest main response and the TTL it wrote', () => {
  const reading = readTranscript(
    [
      '{"cut off line "usage"',
      record({}, {
        input_tokens: 1,
        cache_read_input_tokens: 10,
        cache_creation_input_tokens: 5,
        cache_creation: { ephemeral_1h_input_tokens: 5, ephemeral_5m_input_tokens: 0 },
      }),
      record({ timestamp: '2026-11-07T11:30:00.000Z' }, {
        input_tokens: 2,
        cache_read_input_tokens: 20,
        cache_creation_input_tokens: 0,
      }),
      record({ isSidechain: true, timestamp: '2026-11-07T11:40:00.000Z' }, {
        input_tokens: 99,
        cache_creation: { ephemeral_1h_input_tokens: 0, ephemeral_5m_input_tokens: 99 },
      }),
      record({ timestamp: '2026-11-07T11:50:00.000Z', message: { model: '<synthetic>', usage: { input_tokens: 0 } } }, {}),
      '',
    ].join('\n'),
  )

  expect(reading.ttl).toBe('1h')
  expect(reading.cache).toEqual({
    read: 20,
    created: 0,
    input: 2,
    respondedAt: Date.parse('2026-11-07T11:30:00.000Z'),
  })
})

test('a 5-minute write reads as 5m, and an empty transcript as nothing', () => {
  expect(
    readTranscript(
      record({}, {
        cache_creation: { ephemeral_1h_input_tokens: 0, ephemeral_5m_input_tokens: 7 },
      }),
    ).ttl,
  ).toBe('5m')
  expect(readTranscript('')).toEqual({})
})
