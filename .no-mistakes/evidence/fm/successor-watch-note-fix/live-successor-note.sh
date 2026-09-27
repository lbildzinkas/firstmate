#!/usr/bin/env bash
# Live reproduction of the Telegram inbox-note wake delay on a handling
# successor, driven through the real product entrypoints:
#   - bin/fm-watch-arm.sh started with FM_WATCH_PREDECESSOR_ARM_PID (the exact
#     handoff bin/fm-claude-stop-autoarm.sh start_handling_successor uses), and
#   - bin/fm-inbox.sh note (what the Telegram bridge saves each phone message as).
# Usage: live-successor-note.sh <label> <close-budget-secs>
# Exit codes: 0 = note closed the successor cycle within budget via
# `check: rearm-resurface` with a NEW generation; 4 = the note did NOT close the
# cycle within budget (the reported delay, pre-fix shape); 5 = setup failure.
set -u

ROOT=/Users/luizbildzinkas/.no-mistakes/worktrees/ddca4c0d9ada/01M3J4Q0E1FX2AVH06K9JA3NE2
EV=/Users/luizbildzinkas/.no-mistakes/evidence/01M3J4Q0E1FX2AVH06K9JA3NE2
LABEL=${1:?label}
BUDGET=${2:?close-budget-secs}
INHERITED_GEN=seed.1.aaa

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 5
cleanup() {
  [ -n "${ARM_PID:-}" ] && kill -TERM "$ARM_PID" 2>/dev/null
  [ -n "${ARM_PID:-}" ] && wait "$ARM_PID" 2>/dev/null
  local wp
  wp=$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null || true)
  [ -z "$wp" ] || kill -TERM "$wp" 2>/dev/null
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
  rm -rf "$LAB"
}
trap cleanup EXIT

"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 5
STATE="$LAB/state"
# The live pre-note state from the diagnosis: the predecessor's episode was
# delivered, handled, and acknowledged; the successor inherits that generation.
printf 'acked:handling:%s\n' "$INHERITED_GEN" > "$STATE/.watcher-down"
chmod 600 "$STATE/.watcher-down"
: > "$STATE/crew.meta"
# Hermetic tmux stand-in (this host has no tmux): empty window list, the same
# fake the product's own wake suite uses, so the watcher's pane scans see none.
mkdir -p "$LAB/fakebin"
cat > "$LAB/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "list-windows" ]; then exit 0; fi
if [ "${1:-}" = "display-message" ]; then exit 0; fi
exit 1
SH
chmod +x "$LAB/fakebin/tmux"

# A just-exited predecessor arm pid, as the Claude Stop hook passes it.
( sleep 0.2 ) & PREDECESSOR=$!
sleep 0.5

ARM_OUT="$LAB/arm.out"
: > "$ARM_OUT"
FM_WATCH_PREDECESSOR_ARM_PID=$PREDECESSOR FM_GUARD_GRACE=300 \
  nohup env FM_HOME="$LAB" FM_POLL=2 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 \
  FM_HEARTBEAT=600 FM_GATE_REFUSE_BYPASS=1 PATH="$LAB/fakebin:$PATH" \
  "$ROOT/bin/fm-watch-arm.sh" > "$ARM_OUT" 2>&1 </dev/null &
ARM_PID=$!

# Wait for the successor's confirmed start line.
i=0
while [ $i -lt 80 ]; do
  grep -Eq '^watcher: (started|attached) pid=[0-9]+' "$ARM_OUT" 2>/dev/null && break
  kill -0 "$ARM_PID" 2>/dev/null || break
  sleep 0.25; i=$((i + 1))
done
grep -Eq '^watcher: (started|attached) pid=[0-9]+' "$ARM_OUT" 2>/dev/null \
  || { echo "SETUP-FAIL: successor arm never confirmed: $(cat "$ARM_OUT")"; exit 5; }
START_LINE=$(grep -E '^watcher: (started|attached)' "$ARM_OUT" | head -1)

# Silence phase: with only the inherited generation standing, several polls
# must stay silent (the once-per-generation stand-down still holds).
sleep 10
SILENCE_MARKER=$(cat "$STATE/.watcher-down" 2>/dev/null || true)
if grep -q 'rearm-resurface' "$ARM_OUT" 2>/dev/null \
  || grep -q 'rearm-resurface' "$STATE/.watch-deliveries.log" 2>/dev/null; then
  echo "SETUP-FAIL: successor announced its inherited generation during silence"
  echo "SILENCE_MARKER=$SILENCE_MARKER"
  exit 5
fi
[ "$SILENCE_MARKER" = "acked:handling:$INHERITED_GEN" ] \
  || { echo "SETUP-FAIL: marker changed during silence: $SILENCE_MARKER"; exit 5; }
kill -0 "$ARM_PID" 2>/dev/null \
  || { echo "SETUP-FAIL: successor arm exited before any note: $(cat "$ARM_OUT")"; exit 5; }

# The phone message: save a captain note with the real inbox bridge command.
NOTE_T0=$(date +%s)
NOTE_OUT=$(FM_HOME="$LAB" PATH="$LAB/fakebin:$PATH" \
  "$ROOT/bin/fm-inbox.sh" note "telegram bridge: successor must surface this note" 2>&1)
NOTE_ID=${NOTE_OUT#queued }
ROW=$(grep "$(printf '\tcheck\tinbox:')" "$STATE/.wake-queue" 2>/dev/null | tail -1 || true)
[ -n "$ROW" ] || { echo "SETUP-FAIL: note appended no durable check row: $NOTE_OUT"; exit 5; }

# Does the note close the successor cycle within budget?
CLOSED=no
i=0
while [ $i -lt $((BUDGET * 2)) ]; do
  kill -0 "$ARM_PID" 2>/dev/null || { CLOSED=yes; break; }
  sleep 0.5; i=$((i + 1))
done
LATENCY=$(( $(date +%s) - NOTE_T0 ))
[ "$CLOSED" = yes ] && wait "$ARM_PID" 2>/dev/null

FINAL_MARKER=$(cat "$STATE/.watcher-down" 2>/dev/null || true)
cp "$ARM_OUT" "$EV/$LABEL.arm.out"
[ -f "$STATE/.watch-cycle-exits.log" ] && tail -3 "$STATE/.watch-cycle-exits.log" > "$EV/$LABEL.cycle-exits.log"
[ -f "$STATE/.watch-deliveries.log" ] && tail -3 "$STATE/.watch-deliveries.log" > "$EV/$LABEL.deliveries.log"
tail -5 "$STATE/.wake-queue" > "$EV/$LABEL.wake-queue.tail"

{
  echo "LABEL=$LABEL"
  echo "TREE=$(cd "$ROOT" && git rev-parse --short HEAD) fm-watch.sh=$(cd "$ROOT" && git hash-object bin/fm-watch.sh | cut -c1-8) fm-wake-lib.sh=$(cd "$ROOT" && git hash-object bin/fm-wake-lib.sh | cut -c1-8)"
  echo "START=$START_LINE"
  echo "SILENCE_PHASE=10s marker=$SILENCE_MARKER announced=no"
  echo "NOTE_ID=$NOTE_ID NOTE_CMD_OUT=$NOTE_OUT"
  echo "QUEUE_ROW=$ROW"
  echo "CLOSED=$CLOSED LATENCY=${LATENCY}s BUDGET=${BUDGET}s"
  echo "FINAL_MARKER=$FINAL_MARKER"
  echo "ARM_REASON=$(grep -E '^(signal:|stale:|check:|heartbeat)' "$ARM_OUT" | head -1)"
} > "$EV/$LABEL.summary"

if [ "$CLOSED" != yes ]; then
  echo "DELAY-REPRODUCED: note did not close the successor cycle within ${BUDGET}s (marker=$FINAL_MARKER)"
  exit 4
fi
grep -q '^check: rearm-resurface' "$ARM_OUT" \
  || { echo "CLOSED-WITHOUT-ANNOUNCEMENT: $(cat "$ARM_OUT")"; exit 5; }
case "$FINAL_MARKER" in
  announced:downtime:*) ;;
  *) echo "BAD-MARKER: $FINAL_MARKER"; exit 5 ;;
esac
[ "${FINAL_MARKER##*:}" != "$INHERITED_GEN" ] \
  || { echo "REUSED-INHERITED-GEN: $FINAL_MARKER"; exit 5; }
echo "PASS: note closed the handling-successor cycle in ${LATENCY}s via check: rearm-resurface, marker=$FINAL_MARKER"
exit 0
