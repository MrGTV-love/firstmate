#!/usr/bin/env bash
. "$(dirname "$0")/lab.sh"
lab_reset; lab_init; lab_tmux_start
out_begin S3-fallback-squash-merged-ends-pane-shell-and-destroys
say "### S3: the forge cannot be read, main moved on after the squash merge: REAL teardown refuses 'not landed'; the fallback proves the copy landed from refs/pull/N/head, stops the agent, ends the idle shell of the pane (SIGHUP), the REAL treehouse destroys the slot, the second teardown closes the task"
mkworld pane 102 || exit 1
main_moves_on pane; flaky_forge
say "slot: $WT"
say "pane tree before:"; ps -axo pid=,ppid=,comm= | awk -v p="$PANE" '{par[$1]=$2; c[$1]=$3} END{for(k in par){q=par[k]; for(n=0;n<32&&q>1;n++){ if(q==p){print "  " k " <- " par[k] " " c[k]; break} q=par[q]}}}' | tee -a "$OUT"
prune "$W" arm pane --run; say "arm exit=$?"
for i in $(seq 1 120); do grep -q 'reaped\|retained' "$DATA/pane/merge-prune.log" 2>/dev/null && break; sleep 1; done
sleep 2
dump_world pane
check "S3 first teardown refused as not landed (the fallback class)" grep -q 'REFUSED: the ship deliverable is not landed' "$W/td.log.out"
check "S3 the finished agent was stopped through the exit verb once" test "$(wc -l < "$W/ctl.log" | tr -d ' ')" = 1
check "S3 slot destroyed by the real treehouse with the reaper's exact call" grep -qx "destroy $WT --include-leased --yes" "$W/th.log"
check "S3 exactly one destroy call" test "$(destroy_calls pane)" = 1
check "S3 slot gone from disk" test ! -e "$WT"
check "S3 pane shell and window were still open when the second teardown began" grep -q 'copy_present=no tmux_windows=\[anchor fm-pane \]' "$W/td.log"
check "S3 nothing forced" nothing_forced pane
check "S3 task record closed, prune record gone" bash -c "[ ! -e '$STATE/pane.meta' ] && [ ! -e '$STATE/pane.merge-prune' ]"
check "S3 no wake" test "$(wake_count pane)" = 0
check "S3 log says removed by fallback then reaped" bash -c "grep -q 'fallback destroyed' '$DATA/pane/merge-prune.log' && grep -q 'reaped: removed by fallback' '$DATA/pane/merge-prune.log'"
finish
