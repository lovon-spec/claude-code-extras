#!/bin/sh
# =============================================================================
#  tests/statusline.sh — offline test suite for share/statusline-command.sh
# =============================================================================
#
#  Feeds the statusline synthetic input JSON + fixture transcripts and
#  asserts on the rendered segments. No Claude Code, no network, no real
#  caches: XDG_CACHE_HOME is pointed at a scratch dir, notifications are
#  forced off. Works with BSD (macOS) and GNU userlands.
#
#  Run from anywhere:  sh tests/statusline.sh
#  Exit code 0 = all assertions passed.
# =============================================================================

REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$REPO/share/statusline-command.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/statusline-tests.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM
export XDG_CACHE_HOME="$WORK/cache"
export CLAUDE_STATUSLINE_NOTIFY=off
MARKDIR="$XDG_CACHE_HOME/claude-statusline-ttl"
NOW=$(date +%s)

PASS=0
FAIL=0

# ---- portable date helpers --------------------------------------------------
# GNU date (-d @epoch) first, BSD date (-r epoch) second — GNU's -r means
# "file mtime reference" and errors on a bare epoch, so the order is safe.
fmt_epoch() {  # $1 epoch, $2 format
  date -u -d "@$1" "$2" 2>/dev/null || date -u -r "$1" "$2" 2>/dev/null
}
fmt_epoch_local() {  # for touch -t, which wants local time
  date -d "@$1" "$2" 2>/dev/null || date -r "$1" "$2" 2>/dev/null
}
iso_ago()   { fmt_epoch "$((NOW - $1))" '+%Y-%m-%dT%H:%M:%S.000Z'; }
touch_ago() { touch -t "$(fmt_epoch_local "$((NOW - $1))" '+%Y%m%d%H%M.%S')" "$2"; }

# ---- fixture builders --------------------------------------------------------
usage_rec() {  # $1 age-seconds, $2 flavor (1h|5m) → one assistant API record
  _eph1h=0; _eph5m=0
  [ "$2" = "1h" ] && _eph1h=2400
  [ "$2" = "5m" ] && _eph5m=2400
  printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"input_tokens":3,"cache_read_input_tokens":210000,"cache_creation_input_tokens":2400,"cache_creation":{"ephemeral_1h_input_tokens":%s,"ephemeral_5m_input_tokens":%s}}}}\n' \
    "$(iso_ago "$1")" "$_eph1h" "$_eph5m"
}
away_rec() {  # $1 age-seconds → bookkeeping record with NO usage
  printf '{"type":"system","subtype":"away_summary","timestamp":"%s","content":"while you were away"}\n' \
    "$(iso_ago "$1")"
}

run() {  # $1 sid, $2 transcript, $3 extra-json → stripped statusline output
  printf '{"cwd":"%s","model":{"display_name":"T"},"session_id":"%s","transcript_path":"%s"%s}' \
      "$REPO" "$1" "$2" "${3:-}" \
    | sh "$SCRIPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
}

assert() {  # $1 label, $2 ERE the output must match, $3 output
  if printf '%s' "$3" | grep -Eq "$2"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  wanted /%s/\n  got: %s\n' "$1" "$2" "$3" >&2
  fi
}
refute() {  # $1 label, $2 ERE the output must NOT match, $3 output
  if printf '%s' "$3" | grep -Eq "$2"; then
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  must not match /%s/\n  got: %s\n' "$1" "$2" "$3" >&2
  else
    PASS=$((PASS + 1))
  fi
}

# ---- TTL countdown -----------------------------------------------------------
f="$WORK/fresh-1h.jsonl";  usage_rec 20 1h  > "$f"
out=$(run s-fresh "$f")
assert "1h cache fresh shows ~59:xx" '⏳59:[0-9]{2}' "$out"

f="$WORK/away.jsonl"; { usage_rec 3350 1h; away_rec 5; } > "$f"   # mtime = now
out=$(run s-away "$f")
assert "away_summary must not reset countdown" '⏳4:[0-9]{2}' "$out"
refute "away_summary must not show a full hour" '⏳59:' "$out"

f="$WORK/expired.jsonl"; { usage_rec 4000 1h; away_rec 2; } > "$f"
out=$(run s-exp "$f")
assert "expired cache shows ✗ despite fresh mtime" '⏳✗' "$out"

f="$WORK/blob.jsonl"; printf '{"type":"system","content":"no usage in window"}\n' > "$f"
mkdir -p "$MARKDIR"
printf '%s' "$((NOW - 3350))" > "$MARKDIR/s-blob.act"
printf '3600' > "$MARKDIR/s-blob.ttl"
out=$(run s-blob "$f")
assert "windowless tick falls back to cached .act" '⏳4:[0-9]{2}' "$out"

f="$WORK/5m.jsonl"; usage_rec 100 5m > "$f"
out=$(run s-5m "$f")
assert "5m flavor detected from transcript" '⏳3:[0-9]{2}' "$out"

f="$WORK/nousage.jsonl"; printf '{"type":"user","message":"hi"}\n' > "$f"; touch_ago 100 "$f"
out=$(run s-nou "$f")
assert "no usage anywhere defaults to 5m TTL via mtime" '⏳3:[0-9]{2}' "$out"

f="$WORK/fresh-1h.jsonl"
out=$(CLAUDE_STATUSLINE_CACHE_TTL=0 run s-off "$f")
refute "CACHE_TTL=0 hides the countdown" '⏳' "$out"
out=$(CLAUDE_STATUSLINE_CACHE_TTL=120 run s-ttl120 "$f")
assert "env TTL override wins over auto-detect" '⏳1:[0-9]{2}' "$out"
out=$(run s-miss "$WORK/does-not-exist.jsonl")
refute "missing transcript hides the countdown" '⏳' "$out"

# ---- ⚡ cache-hit receipt ------------------------------------------------------
f="$WORK/fresh-1h.jsonl"
cu() { printf ',"context_window":{"used_percentage":42,"current_usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}' "$1" "$2" "$3"; }
out=$(run s-hit "$f" "$(cu 2 1022 458201)")
assert "hit renders ⚡99%" '⚡99%' "$out"
out=$(run s-missed "$f" "$(cu 9 84000 0)")
assert "cold re-write renders ⚡0%" '⚡0%' "$out"
out=$(run s-part "$f" "$(cu 10 90000 100000)")
assert "partial hit renders ⚡52%" '⚡52%' "$out"
out=$(run s-fb "$f")
assert "no current_usage falls back to transcript (⚡98%)" '⚡98%' "$out"

# ---- rate-limit gauges ---------------------------------------------------------
RL_FLOAT=',"rate_limits":{"five_hour":{"used_percentage":56.00000000000001,"resets_at":99},"seven_day":{"used_percentage":29.5,"resets_at":99}}'
out=$(run s-rlf "$f" "$RL_FLOAT")
assert "float used_percentage still renders 5h" '5h56%' "$out"
assert "29.5 rounds up to 7d30%" '7d30%' "$out"
RL_HOT=",\"rate_limits\":{\"five_hour\":{\"used_percentage\":94,\"resets_at\":$((NOW + 5990))},\"seven_day\":{\"used_percentage\":71,\"resets_at\":99}}"
out=$(run s-rlh "$f" "$RL_HOT")
assert "red gauge appends reset countdown" '5h94%\(1h[0-9]{2}\)' "$out"
assert "yellow 7d has no countdown" '7d71% ' "$out"
out=$(run s-rln "$f")
refute "absent rate_limits hides gauges" '5h|7d' "$out"
out=$(CLAUDE_STATUSLINE_RATE_LIMITS=0 run s-rlo "$f" "$RL_FLOAT")
refute "RATE_LIMITS=0 hides gauges" '5h|7d' "$out"

# ---- notification marker lifecycle --------------------------------------------
f="$WORK/warn.jsonl"; usage_rec 3350 1h > "$f"
rm -f "$MARKDIR/s-mark" "$MARKDIR/s-mark.act"
run s-mark "$f" > /dev/null
m1=$(cat "$MARKDIR/s-mark" 2>/dev/null)
run s-mark "$f" > /dev/null
m2=$(cat "$MARKDIR/s-mark" 2>/dev/null)
assert "marker created under warn threshold" '^[0-9]+$' "$m1"
assert "marker stable across ticks (no re-notify)" "^$m1\$" "$m2"
usage_rec 3400 1h > "$f"   # new idle period (different api timestamp)
run s-mark "$f" > /dev/null
m3=$(cat "$MARKDIR/s-mark" 2>/dev/null)
refute "new idle period re-arms the marker" "^$m1\$" "$m3"

# ---- resilience ----------------------------------------------------------------
out=$(printf 'not json at all' | sh "$SCRIPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'; echo "rc=$?")
assert "malformed input still renders and exits 0" '@.*rc=0' "$out"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
