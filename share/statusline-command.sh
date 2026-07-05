#!/bin/sh
# =============================================================================
#  statusline-command.sh — Claude Code statusLine renderer
# =============================================================================
#
#  Renders: user@host : cwd ●N [model] █░░ 30% +N/-M ✓ ⇡n main⇡m ⚡99% ⏳4:32
#           5h17% 7d22% YYYY-mm-dd HH:MM:SS ABCD1234
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

# Cache + rate-limit numbers in one jq pass; -1 marks "not provided" (older
# Claude Code versions, or no API request yet this session). Every value is
# rounded to an integer — used_percentage arrives as a float at times
# (56.00000000000001), which would trip the shell's integer tests and
# silently hide the segment. Integer output also makes the unquoted
# set-splitting of the @tsv safe.
set -- $(echo "$input" | jq -r 'def r: (. // -1) + 0.5 | floor;
  [
    (.context_window.current_usage.cache_read_input_tokens | r),
    (.context_window.current_usage.cache_creation_input_tokens | r),
    (.context_window.current_usage.input_tokens | r),
    (.rate_limits.five_hour.used_percentage | r),
    (.rate_limits.five_hour.resets_at | r),
    (.rate_limits.seven_day.used_percentage | r),
    (.rate_limits.seven_day.resets_at | r)
  ] | @tsv' 2>/dev/null)
cu_read=${1:--1} cu_create=${2:--1} cu_input=${3:--1}
rl5_pct=${4:--1} rl5_reset=${5:--1} rl7_pct=${6:--1} rl7_reset=${7:--1}

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

# --- Dirty worktree (computed early so the ●N can sit right after cwd) ----
# `git status --porcelain` returns empty outside a git worktree, which the
# `-n "$dirty"` guard below silently handles. --no-optional-locks keeps the
# read from fighting concurrent git activity over the index lock every 2s.
dirty=$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)
if [ -n "$dirty" ]; then
  dirty_count=$(printf '%s' "$dirty" | grep -c .)
fi

# --- Render ----------------------------------------------------------------
printf '\033[01;32m%s@%s\033[00m:\033[01;34m%s\033[00m' \
  "$(whoami)" "$(hostname -s)" "$cwd"

if [ -n "$dirty" ]; then
  printf ' \033[00;33m●%s\033[00m' "$dirty_count"
fi

printf ' \033[00;35m[%s]\033[00m' "$model"

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
    # Prefer origin/<primary> as the comparison ref — local <primary> often
    # lags behind what's actually on the remote (common case: new worktree
    # created from origin/main while local main hasn't been pulled in a
    # while). Fall back to local <primary> for repos without an origin.
    if git -C "$cwd" rev-parse --verify --quiet "origin/$main_branch" >/dev/null 2>&1; then
      primary_ref="origin/$main_branch"
    else
      primary_ref="$main_branch"
    fi
    ahead=$(git -C "$cwd" rev-list --count "$primary_ref..HEAD" 2>/dev/null)
    behind=$(git -C "$cwd" rev-list --count "HEAD..$primary_ref" 2>/dev/null)
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
          main_sha=$(git -C "$cwd" rev-parse "$primary_ref" 2>/dev/null)
          merge_cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline-merge"
          mkdir -p "$merge_cache_dir"
          merge_cache_file="$merge_cache_dir/${head_sha}-${main_sha}"
          if [ -f "$merge_cache_file" ]; then
            state=$(cat "$merge_cache_file")
          else
            if git -C "$cwd" merge-tree --write-tree HEAD "$primary_ref" \
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

fi

# --- Prompt-cache TTL countdown ---------------------------------------------
# Claude Code's API requests keep a prompt cache alive; every request
# refreshes its TTL (5 minutes on API billing, 1 hour on subscription
# plans). While it's warm, the next message reuses the cached prefix —
# cheaper and faster; once it lapses the full context is re-written.
# The statusline JSON exposes no cache state, so two proxies are used:
#   freshness = transcript mtime ("last API activity": the JSONL is appended
#               on every turn and goes quiet exactly when the session idles —
#               including during long tool runs, when the cache genuinely
#               does decay);
#   TTL       = the most recent nonzero ephemeral_{5m,1h} cache-creation
#               entry in the transcript tail (1h → 3600s, else 300s).
# Rendered as:
#   ⚡99%    cache-hit ratio of the latest request (green ≥90, yellow ≥50,
#            red below — 0% = full re-write; normal on a session's first
#            request)
#   ⏳54:07  time left — green, yellow under WARN, red under WARN/2
#   ⏳✗      dim: cache has gone cold; the next message pays full price
# Knobs (environment):
#   CLAUDE_STATUSLINE_CACHE_TTL   seconds; 0 hides ⚡ and ⏳ entirely
#                                 (default: auto-detect as above)
#   CLAUDE_STATUSLINE_CACHE_WARN  warn threshold in seconds; 0 disables the
#                                 desktop notification (default: 60, or 300
#                                 when the detected TTL is one hour)
cache_ttl=${CLAUDE_STATUSLINE_CACHE_TTL:-}
case "$cache_ttl" in *[!0-9]*) cache_ttl="" ;; esac
ttl_remaining=""
hit_pct=""
if [ "$cache_ttl" != "0" ] && [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  # One tail read feeds the TTL-flavor detection, the freshness probe and
  # the cache hit-ratio fallback below.
  transcript_tail=$(tail -c 262144 "$transcript_path" 2>/dev/null)
  ttl_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline-ttl"
  if [ -z "$cache_ttl" ]; then
    ttl_cache_file=""
    [ -n "$session_id" ] && ttl_cache_file="$ttl_dir/$session_id.ttl"
    ttl_seen=$(printf '%s' "$transcript_tail" \
      | grep -o '"ephemeral_[15][mh]_input_tokens":[1-9][0-9]*' | tail -1)
    case "$ttl_seen" in
      *ephemeral_1h*) cache_ttl=3600 ;;
      *ephemeral_5m*) cache_ttl=300  ;;
      *)
        # No usage entry in the tail window — happens when one huge tool
        # result (an image read, a giant diff) fills the last 256K by
        # itself. Fall back to this session's last confident verdict
        # rather than mis-defaulting mid-session.
        [ -n "$ttl_cache_file" ] && cache_ttl=$(cat "$ttl_cache_file" 2>/dev/null)
        case "$cache_ttl" in ''|*[!0-9]*) cache_ttl=300 ;; esac
        ;;
    esac
    if [ -n "$ttl_cache_file" ] && [ -n "$ttl_seen" ] \
       && [ "$(cat "$ttl_cache_file" 2>/dev/null)" != "$cache_ttl" ]; then
      mkdir -p "$ttl_dir"
      printf '%s' "$cache_ttl" > "$ttl_cache_file"
    fi
  fi
  cache_warn=${CLAUDE_STATUSLINE_CACHE_WARN:-}
  case "$cache_warn" in *[!0-9]*) cache_warn="" ;; esac
  if [ -z "$cache_warn" ]; then
    if [ "$cache_ttl" -gt 300 ]; then cache_warn=300; else cache_warn=60; fi
  fi
  # Freshness = timestamp of the last usage-bearing record, NOT the file
  # mtime: Claude Code appends bookkeeping to idle transcripts (e.g.
  # away_summary system records), which would keep resetting the countdown
  # while the real cache decays. Records carrying cache_read_input_tokens
  # are actual API responses; escaped copies inside tool-result strings
  # don't match the unescaped pattern. The verdict is cached per session
  # (.act) for ticks where one huge tool result fills the whole tail
  # window; file mtime is the last resort for transcripts that predate
  # usage records.
  act_file=""
  [ -n "$session_id" ] && act_file="$ttl_dir/$session_id.act"
  api_ts=$(printf '%s' "$transcript_tail" | grep '"cache_read_input_tokens"' \
    | tail -1 | grep -o '"timestamp":"[^"]*"' | tail -1)
  api_ts=${api_ts#*:\"}
  api_ts=${api_ts%\"}
  t_api=""
  if [ -n "$api_ts" ]; then
    api_s=${api_ts%%.*}
    api_s=${api_s%Z}
    # GNU date (-d) first, BSD/macOS date (-j -f) second, same reasoning
    # as the stat fallback below.
    t_api=$(date -u -d "${api_s}Z" +%s 2>/dev/null \
      || date -j -u -f '%Y-%m-%dT%H:%M:%S' "$api_s" +%s 2>/dev/null)
    case "$t_api" in ''|*[!0-9]*) t_api="" ;; esac
  fi
  if [ -n "$t_api" ]; then
    if [ -n "$act_file" ] && [ "$(cat "$act_file" 2>/dev/null)" != "$t_api" ]; then
      mkdir -p "$ttl_dir"
      printf '%s' "$t_api" > "$act_file"
    fi
  elif [ -n "$act_file" ]; then
    t_api=$(cat "$act_file" 2>/dev/null)
    case "$t_api" in ''|*[!0-9]*) t_api="" ;; esac
  fi
  if [ -z "$t_api" ]; then
    # GNU stat (-c) first, BSD/macOS stat (-f) second. The order matters:
    # GNU stat also accepts -f, but as *filesystem* status — it would
    # succeed and return garbage, poisoning the fallback chain if tried
    # first.
    t_api=$(stat -c %Y "$transcript_path" 2>/dev/null \
      || stat -f %m "$transcript_path" 2>/dev/null)
    case "$t_api" in ''|*[!0-9]*) t_api="" ;; esac
  fi
  if [ -n "$t_api" ]; then
    ttl_remaining=$((cache_ttl - ($(date +%s) - t_api)))
    [ "$ttl_remaining" -lt 0 ] && ttl_remaining=0
  fi

  # Cache hit ratio of the most recent API request: the share of the prompt
  # that was read from cache rather than re-written (cache_creation) or sent
  # uncached (input). ⚡99% green after a warm turn is the "the cache
  # actually hit" receipt; ⚡0% red is a cold re-write (normal on the very
  # first request of a session, expensive mid-session). Primary source is
  # context_window.current_usage from the statusline JSON; older Claude
  # Code versions without it fall back to the last usage entry in the
  # transcript tail (the leading quote in the "input_tokens" pattern
  # anchors it so it can't match inside the longer cache_* field names, and
  # escaped copies inside string values (\"...\") don't match either).
  if [ "$cu_read" -lt 0 ] || [ "$cu_create" -lt 0 ] || [ "$cu_input" -lt 0 ]; then
    cu_read=$(printf '%s' "$transcript_tail" \
      | grep -o '"cache_read_input_tokens":[0-9][0-9]*' | tail -1)
    cu_create=$(printf '%s' "$transcript_tail" \
      | grep -o '"cache_creation_input_tokens":[0-9][0-9]*' | tail -1)
    cu_input=$(printf '%s' "$transcript_tail" \
      | grep -o '"input_tokens":[0-9][0-9]*' | tail -1)
    cu_read=${cu_read##*:} cu_create=${cu_create##*:} cu_input=${cu_input##*:}
  fi
  hit_ok=1
  for _v in "$cu_read" "$cu_create" "$cu_input"; do
    case "$_v" in ''|*[!0-9]*) hit_ok=0 ;; esac
  done
  if [ "$hit_ok" = 1 ]; then
    hit_total=$((cu_read + cu_create + cu_input))
    if [ "$hit_total" -gt 0 ]; then
      hit_pct=$((cu_read * 100 / hit_total))
    fi
  fi
fi

# ⚡ cache-hit receipt for the latest request, rendered next to the ⏳ so
# the two tell one story: "will my next message hit?" and "did my last one?"
if [ -n "$hit_pct" ]; then
  if [ "$hit_pct" -ge 90 ]; then
    hit_color='00;32'
  elif [ "$hit_pct" -ge 50 ]; then
    hit_color='00;33'
  else
    hit_color='01;31'
  fi
  printf ' \033[%sm⚡%s%%\033[00m' "$hit_color" "$hit_pct"
fi

if [ -n "$ttl_remaining" ]; then
  if [ "$ttl_remaining" -gt 0 ]; then
    if [ "$ttl_remaining" -gt "$cache_warn" ]; then
      ttl_color='00;32'
    elif [ "$ttl_remaining" -gt $((cache_warn / 2)) ]; then
      ttl_color='00;33'
    else
      ttl_color='01;31'
    fi
    printf ' \033[%sm⏳%d:%02d\033[00m' \
      "$ttl_color" $((ttl_remaining / 60)) $((ttl_remaining % 60))
  else
    printf ' \033[00;90m⏳✗\033[00m'
  fi
fi

# --- Subscription rate-limit gauges ------------------------------------------
# 5-hour and 7-day window utilization from the statusline JSON (subscription
# plans). Dim while comfortable, yellow ≥ 70%, red ≥ 90%; at red the reset
# countdown is appended (e.g. 5h94%(1h40)) so you know when the window frees
# up. Hidden entirely when the JSON has no rate_limits (API billing) or
# CLAUDE_STATUSLINE_RATE_LIMITS=0.
if [ "${CLAUDE_STATUSLINE_RATE_LIMITS:-1}" != "0" ]; then
  rl_render() {  # $1 label, $2 used_percentage, $3 resets_at epoch
    [ "$2" -ge 0 ] 2>/dev/null || return 0
    if [ "$2" -ge 90 ]; then
      _rlc='01;31'
    elif [ "$2" -ge 70 ]; then
      _rlc='00;33'
    else
      _rlc='00;90'
    fi
    printf ' \033[%sm%s%s%%' "$_rlc" "$1" "$2"
    if [ "$2" -ge 90 ] && [ "$3" -gt 0 ] 2>/dev/null; then
      _rll=$(( $3 - $(date +%s) ))
      if [ "$_rll" -gt 0 ]; then
        printf '(%dh%02d)' $((_rll / 3600)) $((_rll % 3600 / 60))
      fi
    fi
    printf '\033[00m'
  }
  rl_render 5h "$rl5_pct" "$rl5_reset"
  rl_render 7d "$rl7_pct" "$rl7_reset"
fi

printf ' \033[00;90m%s\033[00m' "$(date '+%Y-%m-%d %H:%M:%S')"

# Short session id (first 8 chars) — dim, so it's identifying but not loud.
if [ -n "$session_id" ]; then
  sid_short=$(printf '%s' "$session_id" | cut -c1-8)
  printf ' \033[00;90m%s\033[00m' "$sid_short"
fi

# --- Cache-expiry desktop notification --------------------------------------
# Fires once per idle period (keyed by session id + transcript mtime) when
# the countdown first drops under the warn threshold, so a message can still
# land before the cache goes cold. Never fired once already expired — a "too
# late" ping is just noise. Relies on statusLine.refreshInterval to keep
# ticking while idle — without it this only runs on message events.
#
# Delivery (CLAUDE_STATUSLINE_NOTIFY, default `auto`):
#   osascript    macOS Notification Center (attributed to Script Editor;
#                macOS may ask for permission on first use)
#   notify-send  Linux desktop notification (libnotify)
#   osc          both OSC 777 and OSC 9 terminal escapes, written to the
#                claude process's terminal device: the local terminal
#                emulator itself raises the notification, so this works
#                UNCHANGED over ssh — the sequence rides the pty byte
#                stream home. Supported by
#                kitty / WezTerm / Ghostty / foot / urxvt (OSC 777) and
#                iTerm2 (OSC 9); ignored silently elsewhere (Apple
#                Terminal supports neither). Terminals speaking both
#                dialects may show the notification twice — pin osc777 or
#                osc9 to taste.
#   osc777|osc9  just that one escape dialect
#   bell         a plain terminal bell (BEL) — the one signal Apple
#                Terminal honors (beep + Dock badge), locally or over ssh
#   off          disable (same as CLAUDE_STATUSLINE_CACHE_WARN=0)
#   auto         "osc bell" when the session is remote (SSH_TTY /
#                SSH_CONNECTION set, or an sshd ancestor — sudo chains
#                commonly scrub the env), else osascript → notify-send →
#                "osc bell" by availability
# Values combine space-separated, e.g. CLAUDE_STATUSLINE_NOTIFY="osc9 bell".
if [ -n "$ttl_remaining" ] && [ "$ttl_remaining" -gt 0 ] \
   && [ "$cache_warn" -gt 0 ] && [ "$ttl_remaining" -le "$cache_warn" ] \
   && [ -n "$session_id" ]; then
  ttl_mark_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline-ttl"
  mkdir -p "$ttl_mark_dir"
  ttl_mark_file="$ttl_mark_dir/$session_id"
  if [ "$(cat "$ttl_mark_file" 2>/dev/null)" != "$t_api" ]; then
    printf '%s' "$t_api" > "$ttl_mark_file"
    # Markers are ~10 bytes each; prune ones from long-dead sessions. (A
    # live session idle >1 day has an expired cache, which the -gt 0 guard
    # above already silences — losing its marker re-notifies nobody.)
    find "$ttl_mark_dir" -type f -mtime +1 -delete 2>/dev/null
    ttl_where=$(basename "$cwd" | tr -cd 'A-Za-z0-9 ._-')
    ttl_title="Claude Code · $ttl_where · $sid_short"
    ttl_msg=$(printf 'Prompt cache expires in %d:%02d — send a message to keep it warm' \
      $((ttl_remaining / 60)) $((ttl_remaining % 60)))

    # Emit one OSC notification escape to the terminal. Claude Code spawns
    # the statusline with no controlling tty (/dev/tty won't open), so the
    # escape is written to the terminal device of the claude ancestor — the
    # process the session-cache block above already locates. Our sequences
    # contain exactly one ESC (the leader) and end in BEL, so the tmux
    # passthrough wrapper (which requires inner ESCs doubled; needs
    # `set -g allow-passthrough on` in tmux ≥ 3.3) can be built literally.
    [ -n "${claude_pid:-}" ] || claude_pid=$(find_claude_ancestor) || claude_pid=""
    osc_dev=""
    if [ -n "$claude_pid" ]; then
      osc_dev=$(ps -o tty= -p "$claude_pid" 2>/dev/null | tr -d ' ')
      # '??' (macOS) / '?' (Linux) / '-' mean "no terminal at all".
      case "$osc_dev" in ''|\?*|-) osc_dev="" ;; *) osc_dev="/dev/$osc_dev" ;; esac
    fi
    tty_write() {  # write $1 verbatim to the claude terminal, best-effort
      [ -n "$osc_dev" ] && [ -w "$osc_dev" ] || return 0
      { printf '%s' "$1" > "$osc_dev"; } 2>/dev/null || :
    }
    osc_notify() {
      case "$1" in
        osc777) _osc=$(printf ']777;notify;%s;%s\a' "$ttl_title" "$ttl_msg") ;;
        osc9)   _osc=$(printf ']9;%s — %s\a' "$ttl_title" "$ttl_msg") ;;
        *) return 0 ;;
      esac
      if [ -n "${TMUX:-}" ]; then
        tty_write "$(printf '\033Ptmux;\033\033%s\033\\' "$_osc")"
      else
        tty_write "$(printf '\033%s' "$_osc")"
      fi
    }
    # sudo/login chains commonly scrub SSH_* from the environment, so as a
    # fallback ask the process tree whether claude hangs off an sshd.
    ssh_ancestor() {
      _ap=${claude_pid:-$$}
      _ai=0
      while [ "$_ai" -lt 15 ]; do
        _ap=$(ps -o ppid= -p "$_ap" 2>/dev/null | tr -d ' ')
        [ -z "$_ap" ] && return 1
        [ "$_ap" -le 1 ] && return 1
        case "$(ps -o comm= -p "$_ap" 2>/dev/null)" in
          sshd*|*/sshd*) return 0 ;;
        esac
        _ai=$((_ai + 1))
      done
      return 1
    }

    ttl_notify=${CLAUDE_STATUSLINE_NOTIFY:-auto}
    if [ "$ttl_notify" = "auto" ]; then
      if [ -n "${SSH_TTY:-}${SSH_CONNECTION:-}" ] || ssh_ancestor; then
        ttl_notify="osc bell"
      elif command -v osascript >/dev/null 2>&1; then
        ttl_notify=osascript
      elif command -v notify-send >/dev/null 2>&1; then
        ttl_notify=notify-send
      else
        ttl_notify="osc bell"
      fi
    fi
    # stdout/stderr of backgrounded children must go to /dev/null: a child
    # inheriting the statusline's stdout pipe would keep it open and stall
    # the redraw. $ttl_notify is deliberately unquoted: space-separated
    # methods dispatch in order.
    for ttl_method in $ttl_notify; do
      case "$ttl_method" in
        osascript)
          osascript -e "display notification \"$ttl_msg\" with title \"Claude Code\" subtitle \"$ttl_where · $sid_short\" sound name \"Ping\"" >/dev/null 2>&1 &
          ;;
        notify-send)
          notify-send -a 'Claude Code' "$ttl_title" "$ttl_msg" >/dev/null 2>&1 &
          ;;
        osc)    osc_notify osc777; osc_notify osc9 ;;
        osc777|osc9) osc_notify "$ttl_method" ;;
        bell)   tty_write "$(printf '\a')" ;;
      esac
    done
  fi
fi
