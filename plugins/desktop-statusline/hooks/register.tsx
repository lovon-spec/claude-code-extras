import { atom, read, update } from 'claude-code'
import type { Register, SessionUsage } from 'claude-code'

import type { GitState, Line, RateWindow } from '../types'
import {
  cacheWarnSeconds,
  EMPTY,
  readTranscript,
  secondsLeft,
  segments,
} from './line'

const line = atom({ plugin: 'desktop-statusline', key: 'line' } as const, EMPTY, {
  shape: 'line-1',
})

const TAIL_BYTES = '1000000'
const SLOW_EVERY_TICKS = 5
const GIT_MIN_MS = 5_000
const GIT_OUTSIDE_REPO_MS = 60_000

const usagePatch = (
  usage: Pick<SessionUsage, 'context' | 'rateLimits'>,
): Partial<Line> => {
  const rate = (kind: string): RateWindow | undefined => {
    const found = usage.rateLimits.find(one => one.kind === kind)

    if (!found) {
      return undefined
    }

    const resetsAt = found.resetsAt ? Date.parse(found.resetsAt) : Number.NaN

    return Number.isNaN(resetsAt)
      ? { percent: found.percentUsed }
      : { percent: found.percentUsed, resetsAt }
  }

  return {
    contextPercent: usage.context.percent,
    fiveHour: rate('five_hour'),
    sevenDay: rate('seven_day'),
  }
}

export const register: Register = on => {
  let isStarted = false
  let ticks = 0
  let isGitBusy = false
  let gitNextAt = 0
  let transcriptPath: string | undefined
  let refreshAtTurnEnd: (() => Promise<void>) | undefined
  const merges = new Map<string, 'clean' | 'conflict'>()

  on('session.start', async ($, e, next) => {
    const result = await next(e)

    const patch = (values: Partial<Line>) =>
      update($, line, current => ({ ...current, ...values }))

    // A figure that cannot be read says so on the line rather than vanish.
    const report = async (what: string, error: unknown) => {
      const reason = error instanceof Error ? error.message : String(error)

      await patch({ problem: `${what}: ${reason}` }).catch(() => undefined)
    }

    const output = async (argv: string[]): Promise<string | undefined> => {
      const { exitCode, stdout } = await $.process.run(argv, {
        timeoutMs: 30_000,
      })

      return exitCode === 0 ? stdout.trim() : undefined
    }

    const readGit = async (cwd: string): Promise<GitState | undefined> => {
      // Lowered priority and no optional locks, so a read never competes with
      // other work in the repository.
      const git = (...args: string[]) =>
        output(['nice', '-n', '10', 'git', '-C', cwd, ...args])
      const count = async (range: string) => {
        const text = await git('rev-list', '--count', range)

        return text === undefined ? undefined : Number(text)
      }

      if ((await git('rev-parse', '--git-dir')) === undefined) {
        return undefined
      }

      const status = await git('--no-optional-locks', 'status', '--porcelain')
      const state: GitState = {
        dirty: status ? status.split('\n').length : 0,
      }

      let primary = (
        await git('symbolic-ref', '--short', 'refs/remotes/origin/HEAD')
      )?.replace(/^origin\//, '')

      if (!primary) {
        for (const branch of ['main', 'master']) {
          if (
            (await git('show-ref', '--verify', '--quiet', `refs/heads/${branch}`)) !==
            undefined
          ) {
            primary = branch
            break
          }
        }
      }

      if (primary) {
        const remoteRef = `origin/${primary}`
        const ref =
          (await git('rev-parse', '--verify', '--quiet', remoteRef)) !== undefined
            ? remoteRef
            : primary

        state.ahead = await count(`${ref}..HEAD`)
        state.behind = await count(`HEAD..${ref}`)

        if (state.ahead !== undefined && state.behind !== undefined) {
          if ((state.ahead > 0) !== (state.behind > 0)) {
            state.merge = 'clean'
          } else if (state.ahead > 0) {
            const head = await git('rev-parse', 'HEAD')
            const base = await git('rev-parse', ref)
            const key = `${head}-${base}`
            let merge = merges.get(key)

            if (!merge) {
              const { exitCode } = await $.process.run(
                ['nice', '-n', '10', 'git', '-C', cwd, 'merge-tree', '--write-tree', 'HEAD', ref],
                { timeoutMs: 30_000 },
              )

              // 0 merges, 1 conflicts; anything else (a git before 2.38 has no
              // --write-tree) says nothing about the merge.
              merge =
                exitCode === 0 ? 'clean' : exitCode === 1 ? 'conflict' : undefined

              if (merge) {
                merges.set(key, merge)
              }
            }

            state.merge = merge
          }
        }
      }

      const current = await git('rev-parse', '--abbrev-ref', 'HEAD')

      if ((await git('rev-parse', '--abbrev-ref', '@{upstream}')) !== undefined) {
        state.upstream = await count('@{upstream}..HEAD')
      }

      if (
        primary &&
        current !== primary &&
        (await git('rev-parse', '--abbrev-ref', `${primary}@{upstream}`)) !==
          undefined
      ) {
        state.primary = primary
        state.primaryUpstream = await count(`${primary}@{upstream}..${primary}`)
      }

      return state
    }

    const refreshGit = async (now: number) => {
      if (isGitBusy || now < gitNextAt) {
        return
      }

      const { cwd } = await read($, line)

      if (!cwd) {
        return
      }

      isGitBusy = true

      try {
        const git = await readGit(cwd)
        const took = (await $.clock.now()) - now

        gitNextAt =
          now + (git ? Math.max(GIT_MIN_MS, took * 6) : GIT_OUTSIDE_REPO_MS)
        await patch({ git, problem: undefined })
      } catch (error) {
        gitNextAt = now + GIT_OUTSIDE_REPO_MS
        await report('git', error)
      } finally {
        isGitBusy = false
      }
    }

    const defaultTranscriptPath = async (current: Line) => {
      const [root, home, configDir] = await Promise.all([
        $.session.root(),
        $.env.get('HOME'),
        $.env.get('CLAUDE_CONFIG_DIR'),
      ])
      const base = configDir ?? (home ? `${home}/.claude` : undefined)

      return base && current.sessionId
        ? `${base}/projects/${root.replace(/[^a-zA-Z0-9]/g, '-')}/${current.sessionId}.jsonl`
        : undefined
    }

    const refreshFromTranscript = async () => {
      const current = await read($, line)
      const path = transcriptPath ?? (await defaultTranscriptPath(current))

      if (!path) {
        return
      }

      const tail = await output(['tail', '-c', TAIL_BYTES, path])

      if (!tail) {
        return
      }

      const { cache, ttl } = readTranscript(tail)

      await update($, line, latest => ({
        ...latest,
        ttl: ttl ?? latest.ttl,
        cache:
          cache && cache.respondedAt > (latest.cache?.respondedAt ?? 0)
            ? cache
            : latest.cache,
      }))
    }

    refreshAtTurnEnd = refreshFromTranscript

    const refreshSession = async () => {
      const [sessionId, cwd, model, usage] = await Promise.all([
        $.session.id(),
        $.session.cwd(),
        $.session.model(),
        $.session.usage(),
      ])

      await update($, line, current => {
        // /clear starts a new conversation under the same process.
        const isNewSession = current.sessionId !== '' && current.sessionId !== sessionId

        return {
          ...current,
          ...usagePatch(usage),
          sessionId,
          cwd,
          model,
          cache: isNewSession ? undefined : current.cache,
          notifiedFor: isNewSession ? undefined : current.notifiedFor,
        }
      })

      const { cache, ttl } = await read($, line)

      if (!ttl || !cache) {
        await refreshFromTranscript()
      }
    }

    const warnBeforeExpiry = async () => {
      const current = await read($, line)
      const left = secondsLeft(current)
      const { cache } = current

      if (
        !cache ||
        left === undefined ||
        left <= 0 ||
        left > cacheWarnSeconds(current.ttl)
      ) {
        return
      }

      const expiry = cache.respondedAt + (current.ttl === '5m' ? 300 : 3600) * 1000

      if (current.notifiedFor === expiry) {
        return
      }

      await patch({ notifiedFor: expiry })

      const where = current.cwd.split('/').pop() ?? ''
      const recache = cache.read + cache.created + cache.input
      const countdown = `${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}`
      const cost =
        recache > 0 ? ` (${Math.floor(recache / 1000)}k tokens to re-cache otherwise)` : ''

      const message = `Prompt cache expires in ${countdown} — send a message to keep it warm${cost}`
      const place = `${where} · ${current.sessionId.slice(0, 8)}`
      const sent = await $.ui.notify(message, { title: `Claude Code · ${place}` })

      // The desktop has no terminal for that channel (`no-surface`), so this
      // delivers as the CLI script does on a local Mac; argv keeps the text
      // out of the AppleScript source. A person's `disabled` stands.
      if (
        !sent.isSent &&
        (sent.reason === 'no-surface' || sent.reason === 'no-channel')
      ) {
        const isShown = await $.process
          .run(
            [
              'osascript',
              '-e',
              'on run argv',
              '-e',
              'display notification (item 1 of argv) with title "Claude Code" subtitle (item 2 of argv) sound name "Ping"',
              '-e',
              'end run',
              message,
              place,
            ],
            { timeoutMs: 10_000 },
          )
          .then(({ exitCode }) => exitCode === 0)
          .catch(() => false)

        if (!isShown) {
          $.ui.toast(message, { timeoutMs: 15_000 })
        }
      }
    }

    const tick = async () => {
      const now = await $.clock.now()

      ticks += 1
      await patch({ now })
      await warnBeforeExpiry()

      if (ticks % SLOW_EVERY_TICKS === 0) {
        await refreshSession()
      }

      void refreshGit(now)
    }

    if (!isStarted) {
      isStarted = true

      void (async () => {
        const [user, host] = await Promise.all([
          output(['id', '-un']),
          output(['hostname', '-s']),
        ])

        await patch({ user: user ?? '', host: host ?? '' })
        await refreshSession()
        await refreshFromTranscript()
      })().catch(error => report('start', error))

      $.clock.every(1000, () => {
        void tick().catch(error => report('update', error))
      })
    }

    return result
  })

  // Only the main conversation's requests count: a subagent has its own cache.
  on('turn.step', async function* ($, e, next) {
    const result = yield* next(e)

    if (!e.agentId && result.usage) {
      try {
        const now = await $.clock.now()
        const { cache_read_input_tokens, cache_creation_input_tokens, input_tokens } =
          result.usage
        const usage = await $.session.usage()

        await update($, line, current => ({
          ...current,
          ...usagePatch(usage),
          now,
          cache: {
            read: cache_read_input_tokens,
            created: cache_creation_input_tokens,
            input: input_tokens,
            respondedAt: now,
          },
        }))
      } catch {
        // The statusline never gets in the way of a turn.
      }
    }

    return result
  })

  on('session.measure', async ($, e, next) => {
    await update($, line, current => ({ ...current, ...usagePatch(e) }))

    return next(e)
  })

  // The API reports the TTL on the transcript's usage alone, and the turn's
  // last response is on disk by the time the settings hooks' Stop runs. This
  // only starts the read and answers at once: a statusline must not hold up
  // the end of a turn, nor decide anything about it.
  on('classic.Stop', ($, e, next) => {
    transcriptPath = e.transcript_path
    void refreshAtTurnEnd?.().catch(() => undefined)

    return next(e)
  }).catch(($, e, next) => next(e))

  // The CLI has its own statusline; only the desktop surface needs this one.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.surface !== 'desktop' || e.props.hasSurvey) {
      return next(e)
    }

    const current = await read($, line)

    if (!current.cwd) {
      return next(e)
    }

    const { Box, Text } = $.ui.resolve(e)

    return (
      <Box>
        <Text mono tabular size="caption">
          {segments(current).map(seg => (
            <Text
              color={seg.color}
              dimColor={seg.dim}
              weight={seg.bold ? 'semibold' : undefined}
            >
              {seg.text}
            </Text>
          ))}
        </Text>
      </Box>
    )
  })
}
