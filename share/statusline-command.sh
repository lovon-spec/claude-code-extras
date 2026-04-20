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

# --- Git ahead/behind + merge-preview vs the primary branch ----------------
# Probes the branch name in priority order: origin's default (if set) → main
# → master. Skips silently if none found.
#
# When both ahead > 0 and behind > 0, additionally previews whether merging
# the primary branch in would conflict. Uses `git merge-tree --write-tree`
# (git ≥ 2.38) which runs the 3-way merge in memory — no touching of the
# working tree or index. The result is cached by (HEAD-sha, main-sha) so
# the expensive merge is only run when something actually moves.
git_info=$(git -C "$cwd" rev-parse --git-dir 2>/dev/null)
if [ -n "$git_info" ]; then
  # Detect the primary branch.
  main_branch=$(git -C "$cwd" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
  main_branch=${main_branch#origin/}
  if [ -z "$main_branch" ]; then
    for b in main master; do
      if git -C "$cwd" show-ref --verify --quiet "refs/heads/$b"; then
        main_branch=$b
        break
      fi
    done
  fi

  if [ -n "$main_branch" ]; then
    ahead=$(git -C "$cwd" rev-list --count "$main_branch..HEAD" 2>/dev/null)
    behind=$(git -C "$cwd" rev-list --count "HEAD..$main_branch" 2>/dev/null)
    if [ -n "$ahead" ] && [ -n "$behind" ]; then
      printf ' \033[00;32m+%s\033[00m/\033[00;31m-%s\033[00m' "$ahead" "$behind"

      # Merge-parity indicator: are HEAD and the primary branch mergeable?
      # Fires whenever the two diverge at all; the ✓/⚠ is symmetric — it
      # says nothing about direction, only whether a merge between them
      # would conflict.
      #   ahead=0, behind=0  → identical, no indicator
      #   ahead=0 XOR behind=0 → fast-forward in one direction, ✓ (trivial)
      #   ahead>0 AND behind>0 → real 3-way merge, ask merge-tree
      if { [ "$ahead" -gt 0 ] && [ "$behind" -eq 0 ]; } \
         || { [ "$ahead" -eq 0 ] && [ "$behind" -gt 0 ]; }; then
        printf ' \033[00;32m✓\033[00m'
      elif [ "$ahead" -gt 0 ] && [ "$behind" -gt 0 ]; then
        # Gate on git >= 2.38 (modern `merge-tree --write-tree` syntax).
        git_ver=$(git --version 2>/dev/null | awk '{print $3}' | head -1)
        git_major=${git_ver%%.*}
        _rest=${git_ver#*.}
        git_minor=${_rest%%.*}
        modern=0
        case "$git_major" in ''|*[!0-9]*) : ;; *)
          if [ "$git_major" -gt 2 ] 2>/dev/null; then
            modern=1
          elif [ "$git_major" -eq 2 ] && [ "$git_minor" -ge 38 ] 2>/dev/null; then
            modern=1
          fi
        ;; esac

        if [ "$modern" = "1" ]; then
          head_sha=$(git -C "$cwd" rev-parse HEAD 2>/dev/null)
          main_sha=$(git -C "$cwd" rev-parse "$main_branch" 2>/dev/null)
          merge_cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline-merge"
          mkdir -p "$merge_cache_dir"
          merge_cache_file="$merge_cache_dir/${head_sha}-${main_sha}"
          if [ -f "$merge_cache_file" ]; then
            state=$(cat "$merge_cache_file")
          else
            if git -C "$cwd" merge-tree --write-tree HEAD "$main_branch" \
                 >/dev/null 2>&1; then
              state=clean
            else
              state=conflict
            fi
            printf '%s' "$state" > "$merge_cache_file"
          fi
          case "$state" in
            clean)    printf ' \033[00;32m✓\033[00m' ;;
            conflict) printf ' \033[01;31m⚠\033[00m' ;;
          esac
        fi
      fi
    fi
  fi

  # --- Unpushed indicators (fetch-free; uses locally-cached upstream refs) --
  # Two separate counts, any or both can appear:
  #   ⇡N             — current branch has N commits past its upstream
  #                    (shown even for N=0 as long as an upstream exists,
  #                     matching the +N/-M style — a visible "0" signals
  #                     "the check ran", absence signals "no upstream set")
  #   <primary>⇡M    — primary branch has M commits past its upstream,
  #                    shown only when the current branch is not the primary
  #                    (avoids double-display when HEAD is on main itself)
  current_branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)

  if git -C "$cwd" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    cur_unpushed=$(git -C "$cwd" rev-list --count '@{upstream}..HEAD' 2>/dev/null)
    if [ -n "$cur_unpushed" ]; then
      printf ' \033[00;36m⇡%s\033[00m' "$cur_unpushed"
    fi
  fi

  if [ -n "$main_branch" ] && [ "$current_branch" != "$main_branch" ]; then
    if git -C "$cwd" rev-parse --abbrev-ref "${main_branch}@{upstream}" \
         >/dev/null 2>&1; then
      pri_unpushed=$(git -C "$cwd" rev-list --count \
        "${main_branch}@{upstream}..${main_branch}" 2>/dev/null)
      if [ -n "$pri_unpushed" ]; then
        printf ' \033[00;36m%s⇡%s\033[00m' "$main_branch" "$pri_unpushed"
      fi
    fi
  fi

  # Dirty worktree indicator — ●N (yellow) where N is the number of
  # modified/staged/untracked paths. Hidden when clean.
  # --no-optional-locks so concurrent git activity in the same worktree
  # doesn't fight over the index lock every 2s.
  dirty=$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)
  if [ -n "$dirty" ]; then
    dirty_count=$(printf '%s' "$dirty" | grep -c .)
    printf ' \033[00;33m●%s\033[00m' "$dirty_count"
  fi
fi

printf ' \033[00;90m%s\033[00m' "$(date '+%Y-%m-%d %H:%M:%S')"

# Short session id (first 8 chars) — dim, so it's identifying but not loud.
if [ -n "$session_id" ]; then
  sid_short=$(printf '%s' "$session_id" | cut -c1-8)
  printf ' \033[00;90m%s\033[00m' "$sid_short"
fi
