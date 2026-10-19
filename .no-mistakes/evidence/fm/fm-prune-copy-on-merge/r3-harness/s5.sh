#!/usr/bin/env bash
. "$(dirname "$0")/lab.sh"
lab_reset; lab_init; lab_tmux_start
out_begin S5-pushed-follow-up-commit-keeps-the-copy
say "### S5 (adversarial, the round-2 failure): a follow-up commit pushed after the merge but never merged. REAL teardown refuses it; the fallback must keep the copy with one wake BEFORE it stops the agent or ends the pane's treehouse subshell (which would return the slot to the pool and hide the commit)"
mkworld fu 103 || exit 1
printf 'follow-up\n' > "$WT/followup.txt"; git -C "$WT" add followup.txt; git -C "$WT" commit -q -m "follow-up after the merge"
git -C "$WT" push -q origin fm/fu 2>/dev/null
FU=$(git -C "$WT" rev-parse HEAD)
say "follow-up commit $FU is on origin: $(git -C "$W/origin.git" branch --contains "$FU" | tr -d ' *' | tr '\n' ' ')"
say "slot before (real treehouse status):"; (cd "$W/proj" && lab_run "$W" "$LAB/bin/treehouse" status 2>&1 | sed "s#$LAB#<LAB>#g") | tee -a "$OUT"
prune "$W" arm fu --run; say "arm exit=$?"
for i in $(seq 1 90); do grep -q 'reaped\|retained' "$DATA/fu/merge-prune.log" 2>/dev/null && break; sleep 1; done
sleep 2
dump_world fu
say "--- still-running processes of the task:"; ps -p "$WORKER" -o pid=,comm= 2>&1 | tee -a "$OUT"
say "--- slot after: HEAD=$(git -C "$WT" rev-parse --short HEAD 2>&1) branch=$(git -C "$WT" symbolic-ref -q --short HEAD 2>&1)"
say "--- real treehouse dry run (what a destroy would see now):"; (cd "$W/proj" && lab_run "$W" "$REALTH" destroy "$WT" --include-leased 2>&1 | sed "s#$LAB#<LAB>#g") | tee -a "$OUT"
say "--- two more attempts (must not add wakes or change anything)"
prune "$W" run fu --now; prune "$W" run fu --now
check "S5 REAL teardown refused the follow-up as not landed" grep -q 'REFUSED: the ship deliverable is not landed' "$W/td.log.out"
check "S5 teardown named the follow-up commit" grep -q 'follow-up after the merge' "$W/td.log.out"
check "S5 copy kept on disk" test -e "$WT"
check "S5 slot still on the task branch with the follow-up commit (not returned to the pool)" bash -c "[ \"\$(git -C '$WT' symbolic-ref -q --short HEAD)\" = fm/fu ] && [ \"\$(git -C '$WT' rev-parse HEAD)\" = '$FU' ]"
check "S5 task record kept" test -e "$STATE/fu.meta"
check "S5 treehouse destroy never called" test "$(destroy_calls fu)" = 0
check "S5 agent was not stopped (no exit verb)" test ! -s "$W/ctl.log"
check "S5 agent process still running" kill -0 "$WORKER"
check "S5 pane's idle shell not ended (window and shell still there)" bash -c "TMUX_TMPDIR='$TMUXDIR' tmux -L fm-lab list-windows -t firstmate -F '#W' | grep -qx fm-fu"
check "S5 nothing forced" nothing_forced fu
check "S5 exactly one wake after three attempts" test "$(wake_count fu)" = 1
check "S5 the wake names the copy and says the commit is not in the merged pull request" bash -c "grep -F '$WT' '$STATE/.wake-queue' | grep -q 'not in the merged pull request'"
check "S5 the follow-up commit is still on origin" bash -c "git -C '$W/origin.git' cat-file -e '$FU^{commit}'"
finish
