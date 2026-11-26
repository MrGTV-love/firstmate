. /Users/charlesabrooker/tmp/fm-lab-drv/env.sh
FX=$(mktemp -d /Users/charlesabrooker/tmp/fm-lab-fx.XXXXXX); echo "$FX" > $E/.fx-path
TASK=labscott-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n'); echo "$TASK" > $E/.task-id
sed "s/^TASK=fm-slack-second-person-scott\$/TASK=$TASK/" tests/fixtures/fm-scott-task-shape.sh > "$FX.maker.sh"
bash "$FX.maker.sh" "$FX" >/dev/null && rm "$FX.maker.sh"
mv "$FX/home/state/$TASK.meta" "$FX/home/state/$TASK.status" "$FX/home/state/$TASK.inbox" "$FM_HOME/state/"
mv "$FX/home/data/$TASK" "$FM_HOME/data/"
sed -i '' -e "s#^window=.*#window=fmses:fm-$TASK#" -e '/^backend=/d' -e '/^herdr_/d' -e '/^launch_proof=/d' "$FM_HOME/state/$TASK.meta"
printf '%s\n' "" "# Task" "## Captain's intent" "Fixture task for the successor-branch proof." "" "## Firstmate spec" "Keep the task while its agent is replaced." >> "$FM_HOME/data/$TASK/brief.md"
echo "TASK=$TASK FX=$FX"
