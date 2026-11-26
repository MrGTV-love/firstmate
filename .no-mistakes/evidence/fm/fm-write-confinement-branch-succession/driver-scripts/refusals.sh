. /Users/charlesabrooker/tmp/fm-lab-drv/env.sh
P=$(git -C "$FX/project" rev-parse refs/heads/$SUCC); M=$(git -C "$FX/project" rev-parse main)
OUT=$E/live-02-owner-refusals.txt; : > $OUT
git -C "$FX/project" branch "fm/${TASK}v2" "$P"
git -C "$FX/project" branch "fm/$TASK-other" "$P"
cp "$FM_HOME/state/$TASK.meta" "$FM_HOME/state/labother.meta"; sed -i '' -e "s#^branch=.*#branch=fm/$TASK-other#" -e "s#^window=.*#window=fmses:fm-labother#" -e "s#^worktree=.*#worktree=$FX/other#" -e "s#^endpoint_task_id=.*#endpoint_task_id=labother#" "$FM_HOME/state/labother.meta"
mkdir -p "$FM_HOME/data/labscout"; printf 'Fixture scout\n' > "$FM_HOME/data/labscout/brief.md"
sed -e "s#^kind=.*#kind=scout#" -e "s#^window=.*#window=fmses:fm-labscout#" -e "s#^endpoint_task_id=.*#endpoint_task_id=labscout#" -e '/^branch=/d' "$FM_HOME/state/$TASK.meta" > "$FM_HOME/state/labscout.meta"
cp "$FM_HOME/state/$TASK.meta" $E/live-record-before.meta; cp "$FM_HOME/data/$TASK/brief.md" $E/live-brief-before.md
try() { local label=$1; shift; local B A; B=$(fpall); { echo; echo "## $label"; echo "\$ ${PFX:-}fm-control $*"; fmc "$@" 2>&1 | grep -v '^fm-gate-refuse: gate agent lifecycle permitted only against lab home'; echo "exit=${PIPESTATUS[0]}"; A=$(fpall); if [ "$B" = "$A" ]; then echo "bytes of state, data, copy, project git, gate: unchanged"; else echo "BYTES CHANGED"; diff <(echo "$B") <(echo "$A"); fi; } >> $OUT; }
PFX="FM_TASK_ID=$TASK " ; export FM_TASK_ID=$TASK
try "R1 worker session (FM_TASK_ID set)" "$TASK" successor --branch "$SUCC" --tip "$P" --note x
unset FM_TASK_ID PFX
try "R2 first admission without --tip" "$TASK" successor --branch "$SUCC" --note x
try "R3 wildcard name" "$TASK" successor --branch "fm/$TASK-v*" --tip "$P" --note x
try "R4 name with a space" "$TASK" successor --branch "fm/$TASK-v 2" --tip "$P" --note x
try "R5 outside the name family: develop" "$TASK" successor --branch develop --tip "$P" --note x
try "R6 outside the name family: prefix-sharing fm/${TASK}v2 (no dash; ref exists)" "$TASK" successor --branch "fm/${TASK}v2" --tip "$P" --note x
try "R7 name equals the recorded branch" "$TASK" successor --branch "$OLD" --tip "$P" --note x
try "R8 another task's recorded branch (task labother; ref exists)" "$TASK" successor --branch "fm/$TASK-other" --tip "$P" --note x
try "R9 the default branch main" "$TASK" successor --branch main --tip "$P" --note x
try "R10 an archive name" "$TASK" successor --branch "archive/$TASK-pipeline-${P:0:8}" --tip "$P" --note x
try "R11 successor ref does not exist" "$TASK" successor --branch "fm/$TASK-v3" --tip "$P" --note x
try "R12 --tip is shared history (main's commit)" "$TASK" successor --branch "$SUCC" --tip "$M" --note x
try "R13 a scout task" labscout successor --branch "fm/labscout-v2" --tip "$P" --note x
try "R14 an unknown task" nosuchtask successor --branch "fm/nosuchtask-v2" --tip "$P" --note x
mkdir -p "$FX/project/scripts/git-stability"; : > "$FX/project/scripts/git-stability/provision_existing_slot.py"
try "R15 slot-governed project (scripts/git-stability/provision_existing_slot.py present)" "$TASK" successor --branch "$SUCC" --tip "$P" --note x
rm -rf "$FX/project/scripts"
cp "$FM_HOME/state/$TASK.meta" "$FM_HOME/state/$TASK.meta.keep"; echo "slot_manifest=$FX/fake-manifest.json" >> "$FM_HOME/state/$TASK.meta"
try "R16 record names slot_manifest=" "$TASK" successor --branch "$SUCC" --tip "$P" --note x
mv "$FM_HOME/state/$TASK.meta.keep" "$FM_HOME/state/$TASK.meta"
echo DONE >> $OUT
