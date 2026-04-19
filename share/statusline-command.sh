#!/bin/sh
# =============================================================================
#  statusline-command.sh — Claude Code statusLine renderer
# =============================================================================
#
#  Renders: user@host : cwd [model] █░░ 30%  +N/-M  YYYY-mm-dd HH:MM:SS ABCD1234
#
#  Also writes the current session's transcript_path to
#      $XDG_CACHE_HOME/claude-sessions/<claude-pid>
#  so that `claudet` (sibling tool) can auto-target the session of whichever
#  tab it was called from, instead of guessing by mtime across all sessions.
#  Stale entries (for claude processes that have since exited) are cleaned
#  opportunistically on each refresh.
# =============================================================================

input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd')
model=$(echo "$input" | jq -r '.model.display_name // .model.id // "unknown"')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
session_id=$(echo "$input" | jq -r '.session_id // empty')
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')

# --- Record current session for claudet auto-detection ----------------------
# Claude Code spawns the statusline as: claude -> sh -c -> bash -> script,
# so $PPID is the intermediate sh, not claude. Walk up through the parents
# until we hit a process whose comm is `claude`, and use THAT pid as the
# cache key — that's what claudet will look for when it walks its own
# parents the same way.
find_claude_ancestor() {
  _pid=$$
  _i=0
  while [ "$_i" -lt 10 ]; do
    _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
    [ -z "$_pid" ] && return 1
    [ "$_pid" -le 1 ] && return 1
    _comm=$(ps -o comm= -p "$_pid" 2>/dev/null | awk '{print $1}')
    case "$_comm" in
      claude|*/claude) printf '%s\n' "$_pid"; return 0 ;;
    esac
    _i=$((_i + 1))
  done
  return 1
}

if [ -n "$transcript_path" ]; then
  claude_pid=$(find_claude_ancestor) || claude_pid=""
  if [ -n "$claude_pid" ]; then
    cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-sessions"
    mkdir -p "$cache_dir"
    printf '%s\n' "$transcript_path" > "$cache_dir/$claude_pid"
    # Clean entries whose pid is no longer a running claude process.
    for f in "$cache_dir"/*; do
      [ -f "$f" ] || continue
      pid=$(basename "$f")
      case "$pid" in *[!0-9]*) rm -f "$f"; continue;; esac
      # ps -o comm= is empty if the pid doesn't exist. `comm` is truncated to
      # 15 chars on Linux but "claude" fits. Strip any leading path.
      comm=$(ps -o comm= -p "$pid" 2>/dev/null | awk '{print $1}')
      case "$comm" in claude|*/claude) : ;; *) rm -f "$f" ;; esac
    done
  fi
fi

# --- Context-window progress bar -------------------------------------------
if [ -n "$used_pct" ]; then
  filled=$(echo "$used_pct" | awk '{printf "%d", int($1 / 10 + 0.5)}')
  [ "$filled" -gt 10 ] && filled=10
  empty=$((10 - filled))
  bar=""
  i=0
  while [ "$i" -lt "$filled" ]; do
    bar="${bar}█"
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "$empty" ]; do
    bar="${bar}░"
    i=$((i + 1))
  done
  pct_display=$(echo "$used_pct" | awk '{printf "%.0f%%", $1}')
fi

# --- Render ----------------------------------------------------------------
printf '\033[01;32m%s@%s\033[00m:\033[01;34m%s\033[00m \033[00;35m[%s]\033[00m' \
  "$(whoami)" "$(hostname -s)" "$cwd" "$model"

if [ -n "$used_pct" ]; then
  printf ' \033[00;36m%s\033[00m \033[00;33m%s\033[00m' "$bar" "$pct_display"
fi

# Git ahead/behind relative to main
git_info=$(git -C "$cwd" rev-parse --git-dir 2>/dev/null)
if [ -n "$git_info" ]; then
  ahead=$(git -C "$cwd" rev-list --no-walk --count main..HEAD 2>/dev/null)
  behind=$(git -C "$cwd" rev-list --no-walk --count HEAD..main 2>/dev/null)
  if [ -n "$ahead" ] && [ -n "$behind" ]; then
    printf ' \033[00;32m+%s\033[00m/\033[00;31m-%s\033[00m' "$ahead" "$behind"
  fi
fi

printf ' \033[00;90m%s\033[00m' "$(date '+%Y-%m-%d %H:%M:%S')"

# Short session id (first 8 chars) — dim, so it's identifying but not loud.
if [ -n "$session_id" ]; then
  sid_short=$(printf '%s' "$session_id" | cut -c1-8)
  printf ' \033[00;90m%s\033[00m' "$sid_short"
fi
