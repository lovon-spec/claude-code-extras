# claude-code-extras

Small tools that patch over a regression in [Claude Code](https://claude.com/claude-code):
thinking summaries were silently disabled by default, and the `showThinkingSummaries`
setting in `~/.claude/settings.json` is currently ignored.

This repo bundles:

- a **wrapper** that re-enables thinking summaries by passing the (undocumented)
  `--thinking-display summarized` flag on every invocation, self-adapting if the
  flag is ever renamed or removed;
- a **`claudet`** command that pulls thinking blocks out of the current
  session's JSONL log — because the TUI's Ctrl+O only shows the most recent
  one, and older summaries are overwritten as new ones stream in;
- a **statusline** that renders cwd, model, context-window usage with a
  progress bar, git ahead/behind vs. main, and a clock (install is opt-out
  via `--no-statusline`);
- an idempotent **`install.sh`** / **`uninstall.sh`** pair that's safe to
  run on a machine with an existing Claude Code setup.

Tested on Linux (bash) and macOS (zsh), with Claude Code v2.1.114.

## Quick start

```bash
git clone https://github.com/lovon-spec/claude-code-extras.git
cd claude-code-extras
./install.sh          # idempotent; safe to re-run
source ~/.bashrc      # or ~/.zshrc
hash -r               # clear bash/zsh's command path cache
claude --version      # should work as before — flag is passed transparently
claudet 5             # last 5 thinking blocks from your most recent session
```

## What gets installed

| File | What it is | When to remove |
|---|---|---|
| `~/.local/bin-wrap/claude` | bash wrapper that exec's the real claude with `--thinking-display summarized` | when Claude Code fixes `showThinkingSummaries`, or when it renames the flag (wrapper will warn you on stderr) |
| `~/.local/bin/claudet` | python3 script: extracts thinking blocks from the latest session JSONL | whenever the wrapper is removed |
| PATH block in your shell rc | prepends `~/.local/bin-wrap` and `~/.local/bin` | framed by sentinel markers so `uninstall.sh` can remove it cleanly |
| `~/.cache/claude-wrapper.flag` | per-version cache of the flag probe result | auto-regenerates; safe to delete anytime |
| `~/.claude/statusline-command.sh` *(unless `--no-statusline`)* | renders cwd, model, context-window bar, git +/- vs main, clock | remove with `./uninstall.sh`, or pass `--no-statusline` to skip on install |
| `statusLine` block in `~/.claude/settings.json` *(unless `--no-statusline`)* | points CC at the statusline script, 2-second refresh | `uninstall.sh` only removes it if the `command` value is the one we wrote — user-customized statusLines are left alone |

Nothing else under `~/.claude/` is touched.

## claudet usage

```bash
claudet              # last 10 thinking blocks from *this tab's* session
claudet N            # last N blocks
claudet 0            # all blocks in the session
claudet -f           # follow mode: stream new blocks as they arrive
claudet -s SPEC      # session selector: path, full UUID, or UUID prefix
claudet -h           # help
```

Follow mode is the intended workflow for Claude Code's Ctrl+O overwrite
behavior: leave `claudet -f` running in a side pane, and every summary
scrolls past in a durable, scrollable buffer.

### Session auto-detection (multi-tab safe)

The statusline script writes each live session's transcript path to
`~/.cache/claude-sessions/<claude-pid>` on every refresh. `claudet` walks
its own parent process tree, finds the nearest `claude` ancestor, and
looks up that pid's cache entry — so `!claudet` from any tab targets
*that tab's* session, regardless of which other tabs are active.

If auto-detection fails (not running inside claude, or a brand-new tab
whose statusline hasn't ticked yet), `claudet` lists the live sessions
it knows about and asks you to pick with `-s <prefix>`. It never
silently falls back to "most recent globally" — a wrong session is more
confusing than a clear failure.

The statusline also shows the first 8 chars of the session id at the end
of the line, so you can visually distinguish tabs and have a reference
for `-s` on the rare cold-start race.

## Installer behavior

- **Idempotent.** Re-running the installer on a machine that's already set
  up is a no-op: files are kept, the rc-file marker block is detected and
  skipped.
- **Non-destructive.** Existing `~/.local/bin-wrap/claude` or `~/.local/bin/claudet`
  files are preserved by default. Pass `--force` to overwrite (your previous
  content is saved to `<file>.bak-<timestamp>`).
- **Home-only.** Refuses to run as root; touches only files under `$HOME`.
- **Shell-aware.** Picks `~/.bashrc` (bash) or `~/.zshrc` (zsh) from `$SHELL`
  by default; override with `--rc FILE`.
- **Dry-run.** Pass `--dry-run` to see every action without executing any.

## Uninstall

```bash
./uninstall.sh        # removes files + marker block, leaves your own dotfiles alone
```

The rc file is backed up to `<file>.bak-<timestamp>` before the marker block
is removed. `~/.local/bin-wrap/` is removed only if it's empty.

## Requirements

- bash (any version ≥ 3.2 — macOS stock bash is fine)
- python3 (for `claudet`)
- `readlink -f` (present on Linux, and on macOS 12.3+)
- Claude Code installed via the native installer (the wrapper's fallback
  logic expects `~/.local/share/claude/versions/<ver>`). Homebrew / npm
  installs will work through PATH-based lookup but haven't been tested.

## Why the wrapper self-adapts

The `--thinking-display summarized` flag is undocumented — it doesn't show
up in `claude --help`. If Anthropic renames or removes it, a plain alias
would cause `claude` to fail on every invocation with "unknown option". The
wrapper instead probes the flag once per installed version (caching the
verdict in `~/.cache/claude-wrapper.flag`) and silently drops the flag if
it's no longer accepted, so the wrapper never bricks your `claude` command.
On version upgrade, it re-probes and warns on stderr if the flag stops
working — that's the signal to uninstall.

## Why the wrapper lives in a dedicated dir

`~/.local/bin/claude` is a symlink Claude Code maintains itself: deleting
or overwriting it triggers self-repair from a running claude process or
the installer, wiping out anything placed there. The wrapper therefore
lives in `~/.local/bin-wrap/`, a directory Claude Code doesn't touch,
placed earlier in PATH.

## Limitations and known gotchas

- The wrapper needs `~/.local/bin/claude` (or another `claude` on PATH,
  or `~/.local/share/claude/versions/`) to find the real binary. On a
  fully fresh machine without Claude Code yet, the wrapper will install
  successfully and only start working after Claude Code is installed.
- `claudet -f` does not follow session switches — if you exit one Claude
  Code session and start another, Ctrl+C and re-run `claudet -f` to pick
  up the new session file.
- `readlink -f` is unavailable on macOS earlier than 12.3. Use Ventura or
  newer, or replace `readlink -f` in the wrapper with a python shim.
