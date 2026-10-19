#!/usr/bin/env bash
. "$(dirname "$0")/lab.sh"
lab_reset; lab_init; lab_tmux_start
out_begin S1-merge-arms-and-prunes
say "### S1: a merged task's copy is pruned right after the merge: arm --run (the call bin/fm-pr-merge.sh makes), REAL teardown, REAL treehouse, REAL tmux pane"
mkworld happy 101 || exit 1
say "slot: $WT"
say "slot before (real treehouse status):"; (cd "$W/proj" && lab_run "$W" "$LAB/bin/treehouse" status 2>&1 | sed "s#$LAB#<LAB>#g") | tee -a "$OUT"
say "pane tree before:"; ps -axo pid=,ppid=,comm= | awk -v p="$PANE" '{par[$1]=$2; c[$1]=$3} END{for(k in par){q=par[k]; for(n=0;n<32&&q>1;n++){ if(q==p){print "  " k " <- " par[k] " " c[k]; break} q=par[q]}}}' | tee -a "$OUT"
say "--- arm happy --run"
prune "$W" arm happy --run; say "arm exit=$?"
for i in $(seq 1 90); do grep -q 'reaped' "$DATA/happy/merge-prune.log" 2>/dev/null && break; sleep 1; done
dump_world happy
check "S1 task record closed (meta gone)" test ! -e "$STATE/happy.meta"
check "S1 prune record removed" test ! -e "$STATE/happy.merge-prune"
check "S1 log says reaped: teardown completed" grep -q 'reaped: teardown completed' "$DATA/happy/merge-prune.log"
check "S1 no wake raised" test "$(wake_count happy)" = 0
check "S1 nothing forced (no --include-unlanded/--include-in-use/destroy --force)" nothing_forced happy
check "S1 teardown asked for the task by name with the automatic-reap admission" grep -q 'args=\[happy\] admission=1' "$W/td.log"
check "S1 slot returned to the real pool: clean, off the task branch" bash -c "[ -z \"\$(git -C '$WT' status --porcelain --untracked-files=all)\" ] && ! git -C '$WT' symbolic-ref -q HEAD"
check "S1 tmux window closed by teardown" bash -c "! TMUX_TMPDIR='$TMUXDIR' tmux -L fm-lab list-windows -t firstmate -F '#W' | grep -qx fm-happy"
finish
