#!/usr/bin/env bash
# =============================================================================
#  uninstall.sh — remove everything install.sh put in place
# =============================================================================
#
#  Removes:
#    ~/.local/bin-wrap/claude
#    ~/.local/bin/claudet
#    ~/.cache/claude-wrapper.flag
#    the claude-code-extras marker block from your shell rc file
#
#  Leaves alone:
#    - Any file with a .bak-<timestamp> suffix (your previous contents).
#    - Anything under ~/.claude/ or ~/.local/share/claude/.
#    - ~/.local/bin-wrap/ if other files remain in it.
#    - ~/.local/bin/ (always shared with other tools).
# =============================================================================

set -euo pipefail

DRY_RUN=0
RC_OVERRIDE=""

usage() {
  cat <<EOF
usage: $(basename "$0") [-n] [--rc FILE] [-h]

Remove the files and rc-file block installed by install.sh.

Options:
  -n, --dry-run     Show actions without making changes.
      --rc FILE     Shell rc file to clean (default: autodetected from \$SHELL).
  -h, --help        Show this help and exit.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1; shift ;;
    --rc)         RC_OVERRIDE=${2:-}; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
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

remove_file "$HOME/.local/bin-wrap/claude"
remove_file "$HOME/.local/bin/claudet"
remove_file "${XDG_CACHE_HOME:-$HOME/.cache}/claude-wrapper.flag"

# rmdir bin-wrap only if empty (user may have their own files there).
if [[ -d "$HOME/.local/bin-wrap" ]] && [[ -z "$(ls -A "$HOME/.local/bin-wrap" 2>/dev/null)" ]]; then
  run rmdir "$HOME/.local/bin-wrap"
  (( DRY_RUN )) || log "removed empty dir $HOME/.local/bin-wrap"
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
