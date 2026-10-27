#!/usr/bin/env bash
# Live overlap driver for a parked lab primary (Claude Stop hook -> supervision host -> watcher).
# Usage: lab-overlap-driver.sh <tree> <label> [kill-successor|main-drain]
#   <tree>  plain checkout whose bin/ the lab Claude primary runs (target or base)
# Needs FM_HOME (marked lab home) and TMUX_TMPDIR (its private socket dir).
# Reproduces the recorded race: a real drain moves the shared recovery marker
# to handling AFTER the real watcher queued a main-only check wake and BEFORE
# the Stop hook commits the host's hand-back of that wake.
#   1. fire the registered one-shot custom check, so the real watcher closes
#      with a main-only "check:" wake and queues it;
#   2. the moment that row is queued, queue an old branch-owned row, grant it to a branch and run the
#      real branch drain, which enters handling while the host is still
#      starting its successor and has not printed the close yet;
#   3. optional kill-successor: SIGKILL each new lab watcher as it appears
#      until the hook commits, so no healthy watcher runs at commit time;
#   4. record what the Stop hook committed.
# Mode main-drain replaces steps 2-3 with main's own presentation drain in that
# window, so main's open turn holds every queued row beside a healthy watcher.
set -u
TREE=$1 LABEL=$2 KILL=${3:-}
S=$FM_HOME/state
snap() {
  echo "--- $1 ($(date +%H:%M:%S))"
  echo "marker: $(cat "$S/.watcher-down" 2>/dev/null)"
  echo "epoch:  $(head -n1 "$S/.claude-autoarm-epoch" 2>/dev/null)"
  echo "held:   $([ -e "$S/.main-eligible-rows.held" ] && echo present || echo absent)"
  echo "failure-notice: $([ -e "$S/.claude-autoarm-failure-notified" ] && cat "$S/.claude-autoarm-failure-notified" || echo absent)"
  echo "queue:"; sed 's/^/  /' "$S/.wake-queue" 2>/dev/null
}
echo "=== $LABEL tree=$TREE ($(git -C "$TREE" log --oneline -1)) ${KILL:+mode=$KILL}"
cd "$TREE" || exit 1
export NO_MISTAKES_GATE=
unset NO_MISTAKES_GATE
ts() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
snap before
EPOCH_BEFORE=$(head -n1 "$S/.claude-autoarm-epoch")
HOSTLOG_LINES=$(wc -l < "$S/.supervision-host.log")
: > "$S/labprobe.fire"
echo "fired labprobe at $(date +%H:%M:%S)"
for _ in $(seq 1 2400); do
  grep -q 'labprobe.check.sh' "$S/.wake-queue" && break
  sleep 0.02
done
echo "$(ts) watcher queued the main-only wake; host printed yet? $(tail -n +"$((HOSTLOG_LINES + 1))" "$S/.supervision-host.log" | grep -c labprobe); marker=$(cat "$S/.watcher-down")"
if [ "$KILL" = main-drain ]; then
  KILL=
  FM_SUPERVISION_ACTOR=main bash bin/fm-wake-drain.sh > "$S/lab-main-drain.out" 2>&1
  echo "main drain presented main-only wake: $(grep -c 'lab probe fired' "$S/lab-main-drain.out"); hold=$(cat "$S/.main-eligible-rows.held" 2>/dev/null)"
else
  ( . bin/fm-wake-lib.sh; fm_wake_append signal lab-branch.status 'signal: lab-branch.status old branch handling work' )
  BRANCH_SEQ=$(awk -F '\t' '$4 == "lab-branch.status" { s = $2 } END { print s }' "$S/.wake-queue")
  echo "$(ts) branch row seq=$BRANCH_SEQ"
  bash bin/fm-wake-grant.sh activate "$$" labgen
  bash bin/fm-wake-grant.sh publish labgen "$BRANCH_SEQ"
  FM_SUPERVISION_ACTOR=branch bash bin/fm-wake-drain.sh > "$S/lab-branch-drain.out" 2>&1
  echo "branch drain presented branch row: $(grep -c 'old branch handling work' "$S/lab-branch-drain.out"); presented main-only wake: $(grep -c 'lab probe fired' "$S/lab-branch-drain.out")"
fi
echo "host printed before the drain finished? $(tail -n +"$((HOSTLOG_LINES + 1))" "$S/.supervision-host.log" | grep -c labprobe)"
echo "$(ts) drain done"
last=
for _ in $(seq 1 3000); do
  if [ -n "$KILL" ]; then
    for p in $(pgrep -f "$TREE/bin/fm-watch.sh"); do kill -9 "$p" 2>/dev/null && echo "$(ts) killed watcher $p"; done
  fi
  m=$(cat "$S/.watcher-down" 2>/dev/null)
  [ "$m" = "$last" ] || { echo "$(ts) marker -> $m"; last=$m; }
  e=$(head -n1 "$S/.claude-autoarm-epoch")
  if [ "$e" != "$EPOCH_BEFORE" ]; then echo "$(ts) hook committed: $e (last marker seen: $last)"; break; fi
  sleep 0.01
done
sleep 2
echo "host log since fire:"; tail -n +"$((HOSTLOG_LINES + 1))" "$S/.supervision-host.log" | sed 's/^/  /'
[ ! -s "$S/.branch-eligible-owner" ] || bash bin/fm-wake-grant.sh deactivate "$$" labgen
snap after-hook-commit
