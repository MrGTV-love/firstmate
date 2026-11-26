. /Users/charlesabrooker/tmp/fm-lab-drv/env.sh
OUT=$E/live-10-revocation-drops-grant.txt; : > $OUT
PANE=$(tmux -L fm-lab display -p -t "fmses:fm-$TASK" '#{pane_pid}')
W=$(pgrep -P $(pgrep -P $(pgrep -P $PANE)) | head -1)
echo "stopping the lab worker at the Claude first-run theme screen: exact pid $W ($(ps -o comm= -p $W)), which this test's own relaunch started" >> $OUT
kill "$W"; while kill -0 "$W" 2>/dev/null; do sleep 0.5; done
sed -i '' -e '/^successor_branch=/d' -e '/^successor_proved_tip=/d' "$FM_HOME/state/$TASK.meta"
echo "record branch lines now: $(grep -E '^(branch|successor_branch|successor_proved_tip)=' "$FM_HOME/state/$TASK.meta" | tr '\n' ' ')" >> $OUT
f=$E/.pane-out; rm -f $f
tmux -L fm-lab send-keys -t fmses:drv "bash bin/fm-control.sh $TASK relaunch --note 'successor revoked by record edit' > $f 2>&1; echo exit=\$? >> $f" Enter
until grep -q '^exit=' $f 2>/dev/null; do sleep 2; done
grep -E '^(relaunched|error|exit=)' $f >> $OUT
cp "$FM_HOME/state/$TASK.write-confinement.sb" $E/live-profile-3-after-revocation.sb
norm() { sed -E -e 's/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/<SESSION>/g' -e 's#/tmp/fm-'"$TASK"'\+[0-9a-f]+#/tmp/fm-'"$TASK"'+<TOKEN>#g' "$1" | grep -v -E '^\(deny file-write\* \(literal "/private/tmp/claude-501/[^/"]+"\)\)$'; }
{ echo; echo "## launch 3 profile vs launch 1 profile (normalised; other sessions' Claude temp-folder denies left out)"; diff <(norm $E/live-profile-1-no-successor.sb) <(norm $E/live-profile-3-after-revocation.sb) && echo "identical grant set: the successor allow lines are gone"; echo; echo "## successor lines left in launch 3 profile: $(grep -c -- "$SUCC" $E/live-profile-3-after-revocation.sb)"; } >> $OUT
echo DONE >> $OUT
