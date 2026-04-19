#!/bin/sh
input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd')
model=$(echo "$input" | jq -r '.model.display_name // .model.id // "unknown"')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# Build a 10-char progress bar for context usage
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
