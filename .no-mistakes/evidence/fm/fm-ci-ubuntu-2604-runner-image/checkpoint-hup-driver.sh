#!/usr/bin/env bash
# Drive the real bin/fm-watch-checkpoint.sh (with the real fm-watch.sh) from code root $1.
# Case A: caller leaves HUP at default. HUP sent to the bound must stop the watcher early.
# Case B: caller ignores HUP (nohup style). HUP sent to the bound must change nothing.
# The empty lab home makes the real watcher report an overdue-item wake about 3s after
# start (exit 0, "check: open-loop-ledger"). That natural wake is not a HUP effect, so
# every observation happens 1.2s after the HUP, before it.
set -u
ROOT=$1
alive() { kill -0 "$1" 2>/dev/null; }
run_case() { # <label> <default|ignore>
  local label=$1 mode=$2 home cp bound wpid status i
  home=$(mktemp -d "${TMPDIR:-/tmp}/cpdrv.XXXXXX"); mkdir -p "$home/state" "$home/data" "$home/config"
  (
    [ "$mode" = ignore ] && trap '' HUP
    export FM_HOME=$home FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 TMPDIR=$home
    exec perl -e 'setpgrp(0,0); exec @ARGV' "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 8 >"$home/out" 2>"$home/err"
  ) &
  cp=$!
  for i in $(seq 1 100); do [ -s "$home/state/.watch.lock/pid" ] && [ -e "$home/state/.last-watcher-beat" ] && break; sleep 0.05; done
  wpid=$(cat "$home/state/.watch.lock/pid" 2>/dev/null)
  bound=$(pgrep -P "$cp" perl | head -1)
  echo "[$label] checkpoint=$cp bound=$bound watcher=$wpid caller_HUP=$mode"
  kill -HUP "$bound"
  sleep 1.2
  echo "[$label] 1.2s after HUP to the bound: watcher $(alive "$wpid" && echo ALIVE || echo GONE), checkpoint $(alive "$cp" && echo running || echo exited)"
  wait "$cp"; status=$?
  echo "[$label] checkpoint final exit status=$status; watcher after exit: $(alive "$wpid" && echo ALIVE || echo gone); lock dir: $([ -e "$home/state/.watch.lock" ] && echo present || echo absent)"
  echo "[$label] stdout: $(tr '\n' '|' < "$home/out")"
  kill -KILL "$wpid" 2>/dev/null
  rm -rf "$home"
}
run_case A-default-HUP default
run_case B-ignored-HUP ignore
