#!/usr/bin/env bash
# Live race driver for a parked lab primary (Claude Stop hook -> supervision host -> watcher).
# Usage: lab-race-driver.sh <tree> <label>
#   <tree>  plain checkout whose bin/ the lab Claude primary runs (target or base)
# Needs FM_HOME (marked lab home) and TMUX_TMPDIR (its private socket dir).
# Steps:
#   1. queue a main-owned row and run main's real presentation drain, so the
#      recovery marker enters handling and main's presentation hold is set
#      (the open handling turn of the recorded failure);
#   2. fire the registered one-shot custom check, so the real watcher closes
#      with a main-only "check:" wake and the real host hands it to main
#      while the marker still reads handling;
#   3. record what the Stop hook committed and what Claude received.
set -u
TREE=$1 LABEL=$2
S=$FM_HOME/state
snap() {
  echo "--- $1 ($(date +%H:%M:%S))"
  echo "marker: $(cat "$S/.watcher-down" 2>/dev/null)"
  echo "epoch:  $(head -n1 "$S/.claude-autoarm-epoch" 2>/dev/null)"
  echo "held:   $([ -e "$S/.main-eligible-rows.held" ] && echo present || echo absent)"
  echo "failure-notice: $([ -e "$S/.claude-autoarm-failure-notified" ] && cat "$S/.claude-autoarm-failure-notified" || echo absent)"
  echo "queue:"; sed 's/^/  /' "$S/.wake-queue" 2>/dev/null
}
echo "=== $LABEL tree=$TREE ($(git -C "$TREE" log --oneline -1))"
snap before
(
  cd "$TREE" || exit 1
  # shellcheck disable=SC1091
  . bin/fm-wake-lib.sh
  fm_wake_append check lab-main 'check: lab main-owned row presented by the open handling turn'
)
( cd "$TREE" && FM_SUPERVISION_ACTOR=main env -u NO_MISTAKES_GATE bash bin/fm-wake-drain.sh ) > "$S/lab-main-drain.out" 2>&1
echo "main drain presented: $(grep -c 'lab main-owned row' "$S/lab-main-drain.out") row line(s)"
snap after-main-drain
HOSTLOG_LINES=$(wc -l < "$S/.supervision-host.log")
: > "$S/labprobe.fire"
echo "fired labprobe at $(date +%H:%M:%S)"
for _ in $(seq 1 60); do
  [ ! -e "$S/labprobe.fire" ] && tail -n +"$((HOSTLOG_LINES + 1))" "$S/.supervision-host.log" | grep -q 'labprobe' && break
  sleep 1
done
sleep 3
echo "host log since fire:"; tail -n +"$((HOSTLOG_LINES + 1))" "$S/.supervision-host.log" | sed 's/^/  /'
snap after-host-close
