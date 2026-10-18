#!/usr/bin/env bash
# Scenario N: the real watcher runs `sweep --auto` by itself on FM_LAVISH_AUTO_RETIRE_INTERVAL,
# and retiring a board stops its resident listener process.
set -u
ROOT=$1; EV=$2
cd "$ROOT"
. "$EV/sweep-fixture.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); echo "$LAB" > "$EV/.nlab"
bin/fm-lab-home.sh create "$LAB" >/dev/null; mkdir -p "$LAB/fakebin" "$LAB/procevent-claims"
printf '#!/bin/sh\nexit 0\n' > "$LAB/fakebin/lavish-axi"; chmod +x "$LAB/fakebin/lavish-axi"
# A quiet resident listener: stays alive and never produces an event, like an idle Lavish poll.
cat > "$LAB/quiet-listener.sh" <<'SH'
#!/usr/bin/env bash
echo $$ > "$QUIET_PIDDIR/$(basename "$3").pid"
exec sleep 600
SH
chmod +x "$LAB/quiet-listener.sh"; mkdir -p "$LAB/pids"
export PATH="$LAB/fakebin:$PATH" FM_HOME=$LAB FM_PROCEVENT_CLAIM_ROOT=$LAB/procevent-claims LAVISH_AXI_STATE_DIR=$LAB/lavish-state QUIET_PIDDIR=$LAB/pids
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE NO_MISTAKES_GATE FM_POLL
reg() { local name=$1 st=$2 art sid
  art=$(mk_board "$LAB" "$name"); mk_session "$LAB/lavish-state" "$art" "$st" 0 -
  sid=$(bin/fm-procevent-lavish.sh source-id "$art")
  bin/fm-procevent.sh register lavish "$sid" -- "$LAB/quiet-listener.sh" poll "$art" >/dev/null
  rm -f "$art"; printf '%s\n' "$sid"; }
src() { find "$LAB/state" -name "$1.source" 2>/dev/null | grep -q . && echo registered || echo RETIRED; }
echo "### Scenario N: watcher-driven automatic retirement (interval 4s, poll 1s), board files all deleted"
ended_id=$(reg watch-ended-gone ended)
open_id=$(reg watch-open-gone open)
echo "before watcher: watch-ended-gone=$(src $ended_id) watch-open-gone=$(src $open_id)"
env FM_OPEN_LOOPS_BIN=/usr/bin/true FM_HOME="$LAB" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_LAVISH_AUTO_RETIRE_INTERVAL=4 FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 \
  FM_HOME_SUMMARY_INTERVAL=99999999 FM_OPEN_LOOPS_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_IDLE_REAP_INTERVAL=0 FM_TYPESAFE_HEALTH_INTERVAL=0 \
  bin/fm-watch.sh > "$LAB/watch.out" 2> "$LAB/watch.err" &
W=$!
t0=$(date +%s)
sleep 2
echo "+2s (inside first interval, no sweep yet): watch-ended-gone=$(src $ended_id); watcher alive=$(kill -0 $W 2>/dev/null && echo yes || echo no); deadline file: $(cat "$LAB/state/.lavish-auto-retire-next" 2>&1)"
for i in $(seq 1 120); do [ "$(src $ended_id)" = RETIRED ] && break; sleep 1; done
echo "after $(( $(date +%s) - t0 ))s: watch-ended-gone=$(src $ended_id) watch-open-gone=$(src $open_id)"
sleep 9   # at least one more sweep window
echo "after another sweep window: watch-open-gone=$(src $open_id) (live session must stay registered); watcher alive=$(kill -0 $W 2>/dev/null && echo yes || echo no)"
echo "--- state/lavish-auto-retire.log:"; sed "s#$LAB/boards/##" "$LAB/state/lavish-auto-retire.log" 2>&1
echo "--- resident listener processes (pid files -> alive?):"
for f in "$LAB"/pids/*.pid; do [ -f "$f" ] || continue; p=$(cat "$f"); echo "  $(basename "$f" .html.pid): pid $p $(kill -0 "$p" 2>/dev/null && echo ALIVE || echo stopped)"; done
echo "--- watcher output:"; cat "$LAB/watch.out" "$LAB/watch.err" | head -5
kill $W 2>/dev/null; wait $W 2>/dev/null
