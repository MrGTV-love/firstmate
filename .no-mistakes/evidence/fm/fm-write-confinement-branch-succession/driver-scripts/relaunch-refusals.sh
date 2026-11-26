. /Users/charlesabrooker/tmp/fm-lab-drv/env.sh
OUT=$E/live-09-relaunch-refusals-before-stop.txt; : > $OUT
CP=$FX/slots/22/project; M=$(git -C "$FX/project" rev-parse main); C=$(git -C "$FX/project" rev-parse refs/heads/$SUCC)
PANE=$(tmux -L fm-lab display -p -t "fmses:fm-$TASK" '#{pane_pid}')
wpid() { pgrep -P $(pgrep -P $(pgrep -P $PANE)) 2>/dev/null | head -1; }
W0=$(wpid); echo "live worker pid before: $W0 ($(ps -o comm= -p $W0))" >> $OUT
inpane() { # label cmd
  local f=$E/.pane-out; rm -f $f
  tmux -L fm-lab send-keys -t fmses:drv "$2 > $f 2>&1; echo exit=\$? >> $f" Enter
  until grep -q '^exit=' $f 2>/dev/null; do sleep 2; done
  { echo; echo "## $1"; echo "\$ $2"; grep -v '^fm-gate-refuse' $f; } >> $OUT
}
cp "$FM_HOME/state/$TASK.meta" $E/.m2; cp "$FM_HOME/state/$TASK.write-confinement.sb" $E/.sb2
# A: successor reset onto other work (no longer contains the proved tip)
git -C "$FX/project" update-ref "refs/heads/$SUCC" "$M"
inpane "A. successor reset to main's commit, so its history lacks the proved tip; relaunch" "bash bin/fm-control.sh $TASK relaunch --note 'apply'"
W1=$(wpid); { echo "worker pid after: $W1 (same: $([ "$W0" = "$W1" ] && echo yes || echo NO))"; cmp -s $E/.m2 "$FM_HOME/state/$TASK.meta" && echo "record unchanged" || echo "RECORD CHANGED"; cmp -s $E/.sb2 "$FM_HOME/state/$TASK.write-confinement.sb" && echo "profile file unchanged" || echo "PROFILE CHANGED"; } >> $OUT
git -C "$FX/project" update-ref "refs/heads/$SUCC" "$C"
# B: hand-edited slot_manifest= on a task that records a successor
printf 'slot_manifest=%s\n' "$FX/hand-edited-manifest.json" >> "$FM_HOME/state/$TASK.meta"; cp "$FM_HOME/state/$TASK.meta" $E/.m3
inpane "B. record hand-edited to add slot_manifest= while it records a successor; relaunch" "bash bin/fm-control.sh $TASK relaunch --note 'apply'"
W2=$(wpid); { echo "worker pid after: $W2 (same: $([ "$W0" = "$W2" ] && echo yes || echo NO))"; cmp -s $E/.m3 "$FM_HOME/state/$TASK.meta" && echo "record unchanged" || echo "RECORD CHANGED"; cmp -s $E/.sb2 "$FM_HOME/state/$TASK.write-confinement.sb" && echo "profile file unchanged" || echo "PROFILE CHANGED"; } >> $OUT
cp $E/.m2 "$FM_HOME/state/$TASK.meta"
echo; echo "## successor-branch-admission guard events in the lab log" >> $OUT
jq -c 'select(.guard=="successor-branch-admission") | {decision,rule,route,successor,task}' "$FM_HOME/state/guard-events.jsonl" >> $OUT
echo DONE >> $OUT
