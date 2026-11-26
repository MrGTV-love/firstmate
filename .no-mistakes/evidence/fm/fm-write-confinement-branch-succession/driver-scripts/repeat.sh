. /Users/charlesabrooker/tmp/fm-lab-drv/env.sh
OUT=$E/live-05-record-successor.txt
sed -i '' 's/^exit=$/exit=(not captured: the driver shell was zsh, where PIPESTATUS is empty; the receipt prints only on the success path, and the record diff below shows the write)/' $OUT
P=$(git -C "$FX/project" rev-parse refs/heads/$SUCC)
B=$(fpall); cp "$FM_HOME/state/$TASK.meta" $E/.m1; cp "$FM_HOME/data/$TASK/brief.md" $E/.b1
{ echo; echo "## Second identical call (idempotence)"; echo "\$ fm-control $TASK successor --branch $SUCC --note 'same again'"; fmc "$TASK" successor --branch "$SUCC" --note 'same again' 2>&1 | grep -v '^fm-gate-refuse'; echo "exit=${PIPESTATUS[0]}"; cmp -s $E/.m1 "$FM_HOME/state/$TASK.meta" && cmp -s $E/.b1 "$FM_HOME/data/$TASK/brief.md" && [ "$B" = "$(fpall)" ] && echo "record, brief, state, data, copy, project, gate: byte-identical after the repeat" || echo "CHANGED"; } >> $OUT
B=$(fpall)
git -C "$FX/project" branch "fm/$TASK-v9" "$P"
B=$(fpall)
{ echo; echo "## A different second successor (one per task)"; echo "\$ fm-control $TASK successor --branch fm/$TASK-v9 --tip $P --note x"; fmc "$TASK" successor --branch "fm/$TASK-v9" --tip "$P" --note x 2>&1 | grep -v '^fm-gate-refuse'; echo "exit=${PIPESTATUS[0]}"; [ "$B" = "$(fpall)" ] && echo "bytes: unchanged" || echo CHANGED; } >> $OUT
git -C "$FX/project" branch -D "fm/$TASK-v9" >/dev/null
echo DONE >> $OUT
