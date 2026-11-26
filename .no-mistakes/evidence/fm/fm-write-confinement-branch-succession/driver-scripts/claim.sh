. /Users/charlesabrooker/tmp/fm-lab-drv/env.sh
OUT=$E/live-11-claimed-successor-refuses-other-task.txt; : > $OUT
P=$(git -C "$FX/project" rev-parse "archive/$TASK-pipeline-6db21b5e")
{ echo "## Re-record the successor (Main)"; fmc "$TASK" successor --branch "$SUCC" --tip "$P" --note 're-record for the claim check' 2>&1 | grep -E '^(successor-|error)'; } >> $OUT
# a second ship task 'labre' on its own branch and copy
git -C "$FX/project" worktree add -q "$FX/re-old" -b fm/labre "$(git -C "$FX/project" rev-parse main)"
mkdir -p "$FM_HOME/data/labre"; printf '%s\n' "# Task" "## Captain's intent" "Second lab task." "" "## Firstmate spec" "x" "Ship branch: fm/labre" > "$FM_HOME/data/labre/brief.md"
printf '%s\n' "window=fmses:fm-labre" "endpoint_task_id=labre" "worktree=$FX/re-old" "project=$FX/project" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" "branch=fm/labre" > "$FM_HOME/state/labre.meta"
# a replacement copy whose branch is this task's recorded successor
git -C "$FX/project" worktree add -q --detach "$FX/re-new" "$SUCC"
git -C "$FX/re-new" symbolic-ref HEAD "refs/heads/$SUCC"
B=$(fpall)
{ echo; echo "## Task labre tries to reassociate onto a copy on $SUCC (recorded as $TASK's successor)"; echo "\$ fm-control labre reassociate --worktree $FX/re-new --note x"; fmc labre reassociate --worktree "$FX/re-new" --note x 2>&1 | grep -v '^fm-gate-refuse'; echo "exit=${PIPESTATUS[0]}"; [ "$B" = "$(fpall)" ] && echo "bytes of state, data, copy, project git, gate: unchanged" || echo CHANGED; } >> $OUT
echo >> $OUT; jq -c 'select(.guard=="successor-branch-admission") | {decision,rule,successor,task}' "$FM_HOME/state/guard-events.jsonl" | tail -2 >> $OUT
echo DONE >> $OUT
