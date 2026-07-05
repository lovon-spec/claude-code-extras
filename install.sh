#!/usr/bin/env bash
# =============================================================================
#  install.sh — idempotent installer for claude-code-extras
# =============================================================================
#
#  Installs:
#    ~/.local/bin/claudet                the session-log thinking extractor
#    ~/.claude/statusline-command.sh     (unless --no-statusline)
#    + a statusLine block merged into ~/.claude/settings.json
#    + a PATH export block in your shell rc file, framed by sentinel markers
#      so uninstall.sh can remove it cleanly.
#
#  Sync semantics: files this repo owns are updated in place whenever the
#  repo copy differs; the previous content is saved to <file>.bak-<ts>.
#  Re-running after a `git pull` is the intended upgrade path.
#
#  Safety:
#    - Refuses to run as root (home-directory install only).
#    - The rc-file block is appended only if the sentinel marker is not
#      already present (idempotent re-run).
#    - Safe to re-run at any time.
# =============================================================================

set -euo pipefail

DRY_RUN=0
RC_OVERRIDE=""
INSTALL_STATUSLINE=1

usage() {
  cat <<EOF
usage: $(basename "$0") [-n] [--no-statusline] [--rc FILE] [-h]

Install the claude-code-extras statusline and the claudet helper.
Re-running updates installed files in place (with .bak backups) — the
intended upgrade path after a git pull.

Options:
  -n, --dry-run        Show actions without making changes.
      --no-statusline  Skip the statusline script + settings merge.
      --rc FILE        Shell rc file to modify (default: autodetected from \$SHELL).
  -h, --help           Show this help and exit.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run)     DRY_RUN=1; shift ;;
    --no-statusline)  INSTALL_STATUSLINE=0; shift ;;
    --rc)             RC_OVERRIDE=${2:-}; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "install.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ $EUID -eq 0 ]]; then
  echo "install.sh: refusing to run as root (installs into \$HOME, not system dirs)." >&2
  exit 1
fi

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
CLAUDET_SRC="$REPO_DIR/bin/claudet"
CLAUDET_DEST="$HOME/.local/bin/claudet"

MARKER_START="# >>> claude-code-extras >>>"
MARKER_END="# <<< claude-code-extras <<<"

# Autodetect rc file from $SHELL if not overridden.
if [[ -n $RC_OVERRIDE ]]; then
  RC="$RC_OVERRIDE"
else
  case "$(basename "${SHELL:-}")" in
    zsh)  RC="$HOME/.zshrc" ;;
    bash) RC="$HOME/.bashrc" ;;
    *)    RC="$HOME/.profile" ;;
  esac
fi

log() { printf '[install] %s\n' "$*"; }

run() {
  if (( DRY_RUN )); then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

backup_if_exists() {
  # Suffix includes $$ so install + uninstall in rapid succession don't
  # clobber each other's backups (same-second collision on timestamp alone).
  local f=$1
  if [[ -e $f ]]; then
    run cp -p "$f" "${f}.bak-$(date +%Y%m%d-%H%M%S)-$$"
  fi
}

sync_file() {
  # Install $1 at $2; if $2 exists with different content, back it up and
  # replace it. Same content is a silent no-op.
  local src=$1 dest=$2
  if [[ ! -f $src ]]; then
    echo "install.sh: source missing: $src" >&2
    exit 1
  fi
  if [[ -e $dest ]] && cmp -s "$src" "$dest"; then
    log "up to date: $dest"
    return
  fi
  backup_if_exists "$dest"
  run mkdir -p "$(dirname "$dest")"
  run install -m 755 "$src" "$dest"
  (( DRY_RUN )) || log "installed $dest"
}

sync_file "$CLAUDET_SRC" "$CLAUDET_DEST"

# ---- optional: statusline script + settings.json merge ---------------------
if (( INSTALL_STATUSLINE )); then
  STATUSLINE_SRC="$REPO_DIR/share/statusline-command.sh"
  STATUSLINE_DEST="$HOME/.claude/statusline-command.sh"
  SETTINGS="$HOME/.claude/settings.json"
  # Use an absolute path (expanded at install time) so we don't depend on
  # whether Claude Code performs shell-variable expansion on statusLine.command.
  STATUSLINE_CMD="bash $HOME/.claude/statusline-command.sh"

  sync_file "$STATUSLINE_SRC" "$STATUSLINE_DEST"

  merge_args=(add-statusline --settings "$SETTINGS" --command "$STATUSLINE_CMD" --refresh 2)
  (( DRY_RUN )) && merge_args+=(--dry-run)
  python3 "$REPO_DIR/tools/settings.py" "${merge_args[@]}"
fi

# ---- rc-file modification ---------------------------------------------------
rc_block() {
  cat <<EOF

$MARKER_START
# Added by claude-code-extras installer.
# Remove by running uninstall.sh from the checkout, or by deleting
# everything between the marker lines from this file.
export PATH="\$HOME/.local/bin:\$PATH"
$MARKER_END
EOF
}

if [[ -f $RC ]] && grep -qF "$MARKER_START" "$RC"; then
  log "rc already configured: $RC (marker present)"
else
  log "adding PATH block to $RC"
  backup_if_exists "$RC"
  if (( DRY_RUN )); then
    printf '[dry-run] would append to %s:\n' "$RC"
    rc_block | sed 's/^/  | /'
  else
    rc_block >> "$RC"
  fi
fi

# ---- post-install sanity checks --------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  log "warning: python3 is not on PATH — claudet requires it."
fi

if (( INSTALL_STATUSLINE )) && ! command -v jq >/dev/null 2>&1; then
  log "warning: jq is not on PATH — the statusline requires it."
fi

log "done. Open a new terminal, or run: source $RC && hash -r"
