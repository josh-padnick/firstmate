#!/usr/bin/env bash
# Live Grok rendered-busy drift guard.
#
# Run explicitly with FM_GROK_BUSY_LIVE_E2E=1.
# It launches a real Grok turn in an isolated tmux server, requires both
# independently observed active-turn signals, drives the production classifier,
# and then proves the settled pane no longer matches.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${FM_GROK_BUSY_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_GROK_BUSY_LIVE_E2E=1 to run the live Grok busy-state guard"
  exit 0
fi

command -v tmux >/dev/null 2>&1 \
  || { echo "not ok - FM_GROK_BUSY_LIVE_E2E=1 but tmux is not installed" >&2; exit 1; }
command -v grok >/dev/null 2>&1 \
  || { echo "not ok - FM_GROK_BUSY_LIVE_E2E=1 but Grok is not installed" >&2; exit 1; }

SOCKET="fm-grok-busy-live-$$"
SESSION=grokbusy
VERSION=$(grok --version 2>/dev/null | head -1)
CAPTURE=
WAITING_CAPTURE=
STOP_CAPTURE=

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 180 -y 45 -c "$ROOT" -- \
  grok --always-approve 'Use the shell tool to run sleep 5, then reply with exactly DONE.' \
  || { echo "not ok - Grok ($VERSION): isolated launch failed" >&2; exit 1; }

i=0
while [ "$i" -lt 450 ]; do
  CAPTURE=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null || true)
  if printf '%s' "$CAPTURE" | grep -F 'Waiting for response…' >/dev/null \
    && printf '%s' "$CAPTURE" | grep -F '[stop]' >/dev/null; then
    break
  fi
  i=$((i + 1))
  sleep 0.1
done

printf '%s' "$CAPTURE" | grep -F 'Waiting for response…' >/dev/null \
  || { echo "not ok - Grok ($VERSION): live turn never rendered Waiting for response…" >&2; exit 1; }
printf '%s' "$CAPTURE" | grep -F '[stop]' >/dev/null \
  || { echo "not ok - Grok ($VERSION): live turn never rendered its independent [stop] signal" >&2; exit 1; }
WAITING_CAPTURE=$(printf '%s\n' "$CAPTURE" | awk '
  /Waiting for response…/ { sub(/[[:space:]]*\[stop\]/, "") }
  { print }
')
STOP_CAPTURE=$(printf '%s\n' "$CAPTURE" | awk '
  /Waiting for response…/ { sub(/Waiting for response…[[:space:]]*/, "") }
  { print }
')
printf '%s' "$WAITING_CAPTURE" | grep -F '[stop]' >/dev/null \
  && { echo "not ok - Grok ($VERSION): waiting-response probe still contains [stop]" >&2; exit 1; }
printf '%s' "$STOP_CAPTURE" | grep -F 'Waiting for response…' >/dev/null \
  && { echo "not ok - Grok ($VERSION): stop probe still contains Waiting for response…" >&2; exit 1; }
printf '%s' "$WAITING_CAPTURE" | grep -F 'Waiting for response…' >/dev/null \
  || { echo "not ok - Grok ($VERSION): waiting-response probe lost its intended signal" >&2; exit 1; }
printf '%s' "$STOP_CAPTURE" | grep -F '[stop]' >/dev/null \
  || { echo "not ok - Grok ($VERSION): stop probe lost its intended signal" >&2; exit 1; }
[ "$(fm_busy_classify tmux live:grok grok live-grok /nonexistent "$WAITING_CAPTURE")" = "busy grok-regex" ] \
  || { echo "not ok - Grok ($VERSION): production classifier missed the isolated waiting-response signal" >&2; exit 1; }
[ "$(fm_busy_classify tmux live:grok grok live-grok /nonexistent "$STOP_CAPTURE")" = "busy grok-regex" ] \
  || { echo "not ok - Grok ($VERSION): production classifier missed the isolated stop signal" >&2; exit 1; }

i=0
while [ "$i" -lt 600 ]; do
  CAPTURE=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null || true)
  if printf '%s' "$CAPTURE" | grep -F 'DONE' >/dev/null \
    && [ "$(fm_busy_classify tmux live:grok grok live-grok /nonexistent "$CAPTURE")" = "idle grok-regex" ]; then
    break
  fi
  i=$((i + 1))
  sleep 0.1
done

printf '%s' "$CAPTURE" | grep -F 'DONE' >/dev/null \
  || { echo "not ok - Grok ($VERSION): probe turn did not complete" >&2; exit 1; }
[ "$(fm_busy_classify tmux live:grok grok live-grok /nonexistent "$CAPTURE")" = "idle grok-regex" ] \
  || { echo "not ok - Grok ($VERSION): settled pane still classified busy" >&2; exit 1; }

echo "ok - Grok ($VERSION): each live signal independently classifies busy, then settles idle"
