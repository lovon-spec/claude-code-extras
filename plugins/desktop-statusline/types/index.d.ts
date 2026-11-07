export type CacheTtl = '5m' | '1h'

export type GitState = {
  /** Modified, staged or untracked files. */
  dirty: number
  /** Commits past the primary branch. */
  ahead?: number
  /** Commits the primary branch has that HEAD lacks. */
  behind?: number
  /** Whether merging HEAD and the primary branch would conflict. */
  merge?: 'clean' | 'conflict'
  /** Commits past the current branch's upstream. */
  upstream?: number
  /** The primary branch, when HEAD is not on it and it has an upstream. */
  primary?: string
  /** Commits the primary branch has past its own upstream. */
  primaryUpstream?: number
}

export type RateWindow = {
  percent: number
  /** Epoch milliseconds. */
  resetsAt?: number
}

/** The latest main-thread API response's prompt tokens. */
export type CacheState = {
  read: number
  created: number
  input: number
  /** Epoch milliseconds. */
  respondedAt: number
}

export type Line = {
  /** Epoch milliseconds of the last tick. */
  now: number
  user: string
  host: string
  cwd: string
  sessionId: string
  model: string
  contextPercent?: number
  fiveHour?: RateWindow
  sevenDay?: RateWindow
  git?: GitState
  cache?: CacheState
  ttl?: CacheTtl
  /** The cache expiry the last notification warned about. */
  notifiedFor?: number
  /** Why a figure could not be read, shown at the end of the line. */
  problem?: string
}

declare module 'claude-code' {
  interface PluginState {
    'desktop-statusline': { line: Shaped<Line> }
  }
}
