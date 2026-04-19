#!/usr/bin/env bash
# =============================================================================
#  install.sh — idempotent installer for claude-code-extras
# =============================================================================
#
#  Installs:
#    ~/.local/bin-wrap/claude    the thinking-summary wrapper
#    ~/.local/bin/claudet        the session-log thinking extractor
#    + a PATH export block in your shell rc file, framed by sentinel markers
#      so uninstall.sh can remove it cleanly.
#
#  Safety:
#    - Existing files are preserved by default; use --force to overwrite
#      (the previous content is saved to <file>.bak-<timestamp>).
#    - The rc-file block is appended only if the sentinel marker is not
#      already present (idempotent re-run).
#    - Nothing under ~/.claude/ is touched.
#    - The script refuses to run as root (home-directory install only).
#
#  Safe to re-run. Safe to run on a friend's machine without destroying
#  their existing setup.
# =============================================================================

set -euo pipefail

FORCE=0
DRY_RUN=0
RC_OVERRIDE=""
INSTALL_STATUSLINE=1

usage() {
  cat <<EOF
usage: $(basename "$0") [-f] [-n] [--no-statusline] [--rc FILE] [-h]

Install the Claude Code thinking-summary wrapper and claudet helper.

By default also installs the statusline script into ~/.claude/ and merges
a statusLine block into ~/.claude/settings.json (non-destructive: skipped
if already configured, unless --force).

Options:
  -f, --force          Overwrite existing installed files + settings keys
                       (with .bak backups).
  -n, --dry-run        Show actions without making changes.
      --no-statusline  Skip the statusline script + settings merge.
      --rc FILE        Shell rc file to modify (default: autodetected from \$SHELL).
  -h, --help           Show this help and exit.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--force)       FORCE=1; shift ;;
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
BIN_WRAP_SRC="$REPO_DIR/bin-wrap/claude"
CLAUDET_SRC="$REPO_DIR/bin/claudet"
BIN_WRAP_DEST="$HOME/.local/bin-wrap/claude"
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

install_file() {
  local src=$1 dest=$2
  if [[ ! -f $src ]]; then
    echo "install.sh: source missing: $src" >&2
    exit 1
  fi
  if [[ -e $dest ]]; then
    if (( FORCE )); then
      backup_if_exists "$dest"
    else
      log "skip $dest (already exists; pass --force to overwrite)"
      return
    fi
  fi
  run mkdir -p "$(dirname "$dest")"
  run install -m 755 "$src" "$dest"
  (( DRY_RUN )) || log "installed $dest"
}

install_file "$BIN_WRAP_SRC" "$BIN_WRAP_DEST"
install_file "$CLAUDET_SRC" "$CLAUDET_DEST"

# ---- optional: statusline script + settings.json merge ---------------------
if (( INSTALL_STATUSLINE )); then
  STATUSLINE_SRC="$REPO_DIR/share/statusline-command.sh"
  STATUSLINE_DEST="$HOME/.claude/statusline-command.sh"
  SETTINGS="$HOME/.claude/settings.json"
  # Use an absolute path (expanded at install time) so we don't depend on
  # whether Claude Code performs shell-variable expansion on statusLine.command.
  STATUSLINE_CMD="bash $HOME/.claude/statusline-command.sh"

  install_file "$STATUSLINE_SRC" "$STATUSLINE_DEST"

  merge_args=(add-statusline --settings "$SETTINGS" --command "$STATUSLINE_CMD" --refresh 2)
  (( FORCE ))   && merge_args+=(--force)
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
export PATH="\$HOME/.local/bin-wrap:\$HOME/.local/bin:\$PATH"
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
if ! command -v claude >/dev/null 2>&1; then
  log "warning: 'claude' is not on PATH yet."
  log "         Install Claude Code first, then open a new terminal."
fi

if ! command -v python3 >/dev/null 2>&1; then
  log "warning: python3 is not on PATH — claudet requires it."
fi

log "done. Open a new terminal, or run: source $RC && hash -r"
