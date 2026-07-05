#!/usr/bin/env bash
# =============================================================================
#  uninstall.sh — remove everything install.sh put in place
# =============================================================================
#
#  Removes:
#    ~/.local/bin/claudet
#    ~/.claude/statusline-command.sh + its settings.json block (see below)
#    the statusline cache dirs under ~/.cache/
#    the claude-code-extras marker block from your shell rc file
#
#  Leaves alone:
#    - Any file with a .bak-<timestamp> suffix (your previous contents).
#    - Anything else under ~/.claude/ or ~/.local/share/claude/.
#    - ~/.local/bin/ (always shared with other tools).
# =============================================================================

set -euo pipefail

DRY_RUN=0
RC_OVERRIDE=""
REMOVE_STATUSLINE=1

usage() {
  cat <<EOF
usage: $(basename "$0") [-n] [--no-statusline] [--rc FILE] [-h]

Remove the files and rc-file block installed by install.sh.

By default also removes ~/.claude/statusline-command.sh and the
claude-code-extras statusLine block from ~/.claude/settings.json — but
only if the settings.json value is the one install.sh wrote (a
user-modified statusLine.command is left alone).

Options:
  -n, --dry-run        Show actions without making changes.
      --no-statusline  Keep statusline script + settings.json entry in place.
      --rc FILE        Shell rc file to clean (default: autodetected from \$SHELL).
  -h, --help           Show this help and exit.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run)     DRY_RUN=1; shift ;;
    --no-statusline)  REMOVE_STATUSLINE=0; shift ;;
    --rc)             RC_OVERRIDE=${2:-}; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "uninstall.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -n $RC_OVERRIDE ]]; then
  RC="$RC_OVERRIDE"
else
  case "$(basename "${SHELL:-}")" in
    zsh)  RC="$HOME/.zshrc" ;;
    bash) RC="$HOME/.bashrc" ;;
    *)    RC="$HOME/.profile" ;;
  esac
fi

MARKER_START="# >>> claude-code-extras >>>"
MARKER_END="# <<< claude-code-extras <<<"

log() { printf '[uninstall] %s\n' "$*"; }

run() {
  if (( DRY_RUN )); then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

remove_file() {
  local f=$1
  if [[ -e $f ]]; then
    run rm -f "$f"
    (( DRY_RUN )) || log "removed $f"
  fi
}

remove_file "$HOME/.local/bin/claudet"

# ---- optional: statusline script + settings.json rollback ------------------
if (( REMOVE_STATUSLINE )); then
  STATUSLINE_DEST="$HOME/.claude/statusline-command.sh"
  SETTINGS="$HOME/.claude/settings.json"
  STATUSLINE_CMD="bash $HOME/.claude/statusline-command.sh"
  REPO_DIR=$(cd "$(dirname "$0")" && pwd)

  # Remove the script file only if it matches what we shipped — if the user
  # customized it, leave the file alone (they may want to keep the edits).
  if [[ -f "$STATUSLINE_DEST" ]]; then
    shipped="$REPO_DIR/share/statusline-command.sh"
    if [[ -f "$shipped" ]] && cmp -s "$shipped" "$STATUSLINE_DEST"; then
      remove_file "$STATUSLINE_DEST"
    else
      log "skip $STATUSLINE_DEST (customized or unknown; leaving alone)"
    fi
  fi

  unmerge_args=(remove-statusline --settings "$SETTINGS" --command "$STATUSLINE_CMD")
  (( DRY_RUN )) && unmerge_args+=(--dry-run)
  python3 "$REPO_DIR/tools/settings.py" "${unmerge_args[@]}"

  # Caches the statusline maintains; all regenerable, so removal is safe.
  for d in claude-sessions claude-statusline-ttl claude-statusline-merge; do
    cache="${XDG_CACHE_HOME:-$HOME/.cache}/$d"
    if [[ -d $cache ]]; then
      run rm -rf "$cache"
      (( DRY_RUN )) || log "removed cache $cache"
    fi
  done
fi

# Remove the marker block from rc.
if [[ -f $RC ]] && grep -qF "$MARKER_START" "$RC"; then
  log "removing marker block from $RC"
  # $$ suffix avoids clobbering an install-time backup if uninstall runs
  # in the same second (different PIDs → different backup filenames).
  run cp -p "$RC" "${RC}.bak-$(date +%Y%m%d-%H%M%S)-$$"
  if (( DRY_RUN )); then
    printf '[dry-run] would delete lines from %s matching /%s/ through /%s/\n' \
      "$RC" "$MARKER_START" "$MARKER_END"
  else
    # Portable sed delete between two markers (inclusive). BSD sed on macOS
    # needs -i '' ; GNU sed on Linux accepts -i without an argument. Use a
    # temp-file dance to work on both.
    tmp=$(mktemp)
    sed "/$MARKER_START/,/$MARKER_END/d" "$RC" > "$tmp"
    mv "$tmp" "$RC"
  fi
else
  log "no marker block in $RC (nothing to remove)"
fi

log "done. Open a new terminal, or run: source $RC && hash -r"
