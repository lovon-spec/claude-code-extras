import type { CacheState, CacheTtl, GitState, Line, RateWindow } from '../types'

export type Seg = {
  text: string
  color?: string
  dim?: boolean
  bold?: boolean
}

export const EMPTY: Line = {
  now: 0,
  user: '',
  host: '',
  cwd: '',
  sessionId: '',
  model: '',
}

const GREEN = 'success'
const RED = 'error'
const YELLOW = 'warning'
const BLUE = 'suggestion'
const PURPLE = 'merged'
const CYAN = 'ide'

const pad = (n: number, width = 2) => String(n).padStart(width, '0')

/** `claude-opus-5-5[1m]` as the CLI's display name, `Opus 5.5 (1M context)`. */
export const modelName = (id: string): string => {
  const match =
    /^claude-(opus|sonnet|haiku|fable)-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?(\[1m\])?$/i.exec(
      id,
    )

  if (!match) {
    return id
  }

  const [, family = '', major, minor, wide] = match
  const name = family.charAt(0).toUpperCase() + family.slice(1).toLowerCase()
  const version = minor ? `${major}.${minor}` : major

  return `${name} ${version}${wide ? ' (1M context)' : ''}`
}

export const clock = (ms: number): string => {
  const d = new Date(ms)

  return (
    `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
    `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
  )
}

export const bar = (percent: number): string => {
  const filled = Math.min(10, Math.floor((percent + 5) / 10))

  return '█'.repeat(filled) + '░'.repeat(10 - filled)
}

/**
 * When the prompt cache goes cold: the last response plus the TTL.
 *
 * Undefined when the last response reported no cache tokens or the TTL is not
 * known yet, as the CLI's `prompt_cache.expires_at` is null then.
 */
export const cacheExpiry = (line: Line): number | undefined => {
  const { cache, ttl } = line

  if (!cache || !ttl || cache.read + cache.created === 0) {
    return undefined
  }

  return cache.respondedAt + (ttl === '5m' ? 300 : 3600) * 1000
}

export const cacheWarnSeconds = (ttl: CacheTtl | undefined): number =>
  ttl === '5m' ? 60 : 300

export const secondsLeft = (line: Line): number | undefined => {
  const expiry = cacheExpiry(line)

  return expiry === undefined
    ? undefined
    : Math.max(0, Math.floor((expiry - line.now) / 1000))
}

const gitSegments = (git: GitState | undefined): Seg[] => {
  if (!git) {
    return []
  }

  const segs: Seg[] = []

  if (git.ahead !== undefined && git.behind !== undefined) {
    segs.push(
      { text: ' ' },
      { text: `+${git.ahead}`, color: GREEN },
      { text: '/' },
      { text: `-${git.behind}`, color: RED },
    )

    if (git.merge === 'clean') {
      segs.push({ text: ' ✓', color: GREEN })
    } else if (git.merge === 'conflict') {
      segs.push({ text: ' ⚠', color: RED, bold: true })
    }
  }

  if (git.upstream !== undefined) {
    segs.push({ text: ` ⇡${git.upstream}`, color: CYAN })
  }

  if (git.primary !== undefined && git.primaryUpstream !== undefined) {
    segs.push({ text: ` ${git.primary}⇡${git.primaryUpstream}`, color: CYAN })
  }

  return segs
}

const hitSegment = (cache: CacheState | undefined): Seg[] => {
  if (!cache) {
    return []
  }

  const total = cache.read + cache.created + cache.input

  if (total <= 0) {
    return []
  }

  const percent = Math.floor((cache.read * 100) / total)
  const color = percent >= 90 ? GREEN : percent >= 50 ? YELLOW : RED

  return [{ text: ` ⚡${percent}%`, color, bold: color === RED }]
}

const ttlSegment = (line: Line): Seg[] => {
  const left = secondsLeft(line)

  if (left === undefined) {
    return []
  }

  if (left === 0) {
    return [{ text: ' ⏳✗', dim: true }]
  }

  const warn = cacheWarnSeconds(line.ttl)
  const color = left > warn ? GREEN : left > warn / 2 ? YELLOW : RED

  return [
    {
      text: ` ⏳${Math.floor(left / 60)}:${pad(left % 60)}`,
      color,
      bold: color === RED,
    },
  ]
}

const rateSegment = (
  label: string,
  rate: RateWindow | undefined,
  now: number,
): Seg[] => {
  if (!rate) {
    return []
  }

  const percent = Math.round(rate.percent)
  let text = ` ${label}${percent}%`

  if (percent >= 90 && rate.resetsAt !== undefined) {
    const left = Math.floor((rate.resetsAt - now) / 1000)

    if (left > 0) {
      text += `(${Math.floor(left / 3600)}h${pad(Math.floor((left % 3600) / 60))})`
    }
  }

  if (percent >= 90) {
    return [{ text, color: RED, bold: true }]
  }

  return percent >= 70 ? [{ text, color: YELLOW }] : [{ text, dim: true }]
}

/** The statusline in the script's order, each run with its own color. */
export const segments = (line: Line): Seg[] => {
  const segs: Seg[] = []

  if (line.user || line.host) {
    segs.push(
      { text: `${line.user}@${line.host}`, color: GREEN, bold: true },
      { text: ':' },
    )
  }

  segs.push({ text: line.cwd, color: BLUE, bold: true })

  if (line.git && line.git.dirty > 0) {
    segs.push({ text: ` ●${line.git.dirty}`, color: YELLOW })
  }

  segs.push({ text: ` [${modelName(line.model)}]`, color: PURPLE })

  if (line.contextPercent !== undefined) {
    const percent = Math.round(line.contextPercent)

    segs.push(
      { text: ` ${bar(percent)}`, color: CYAN },
      { text: ` ${percent}%`, color: YELLOW },
    )
  }

  segs.push(
    ...gitSegments(line.git),
    ...hitSegment(line.cache),
    ...ttlSegment(line),
    ...rateSegment('5h', line.fiveHour, line.now),
    ...rateSegment('7d', line.sevenDay, line.now),
    { text: ` ${clock(line.now)}`, dim: true },
  )

  if (line.sessionId) {
    segs.push({ text: ` ${line.sessionId.slice(0, 8)}`, dim: true })
  }

  if (line.problem) {
    segs.push({ text: ` ⚠ ${line.problem.slice(0, 80)}`, color: YELLOW })
  }

  return segs
}

export type TranscriptReading = {
  cache?: CacheState
  ttl?: CacheTtl
}

type TranscriptUsage = {
  input_tokens?: number
  cache_read_input_tokens?: number
  cache_creation_input_tokens?: number
  cache_creation?: {
    ephemeral_1h_input_tokens?: number
    ephemeral_5m_input_tokens?: number
  }
}

type TranscriptRecord = {
  type?: string
  timestamp?: string
  isSidechain?: boolean
  isApiErrorMessage?: boolean
  message?: { model?: string; usage?: TranscriptUsage }
}

/**
 * The newest main-thread response in the end of a transcript, and the TTL its
 * latest cache write used. The API reports the TTL only on a write, so this
 * walks back past responses that wrote nothing. The tail's first line may be
 * cut, which the parse skips.
 */
export const readTranscript = (tail: string): TranscriptReading => {
  const reading: TranscriptReading = {}
  const lines = tail.split('\n')

  for (let i = lines.length - 1; i >= 0; i -= 1) {
    const text = lines[i]

    if (!text || !text.includes('"usage"')) {
      continue
    }

    let record: TranscriptRecord

    try {
      record = JSON.parse(text) as TranscriptRecord
    } catch {
      continue
    }

    const usage = record.message?.usage

    if (
      record.type !== 'assistant' ||
      record.isSidechain ||
      record.isApiErrorMessage ||
      record.message?.model === '<synthetic>' ||
      !usage
    ) {
      continue
    }

    if (!reading.cache) {
      const respondedAt = Date.parse(record.timestamp ?? '')

      if (!Number.isNaN(respondedAt)) {
        reading.cache = {
          read: usage.cache_read_input_tokens ?? 0,
          created: usage.cache_creation_input_tokens ?? 0,
          input: usage.input_tokens ?? 0,
          respondedAt,
        }
      }
    }

    if ((usage.cache_creation?.ephemeral_1h_input_tokens ?? 0) > 0) {
      reading.ttl = '1h'
      break
    }

    if ((usage.cache_creation?.ephemeral_5m_input_tokens ?? 0) > 0) {
      reading.ttl = '5m'
      break
    }
  }

  return reading
}
