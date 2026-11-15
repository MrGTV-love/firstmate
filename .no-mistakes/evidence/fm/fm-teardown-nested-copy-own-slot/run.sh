#!/usr/bin/env bash
# run.sh <teardown-script> <label> <variant> <claim> <shape> args...   (DROP -> drop file)
R=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M7GMMRYE7XV1A1TDF4RBH4WC; cd $R
E=/Users/charlesabrooker/.no-mistakes/evidence/01M7GMMRYE7XV1A1TDF4RBH4WC
TD=$1 label=$2 variant=$3 claim=$4 shape=$5; shift 5
eval "$(bin/fm-lab-home.sh env 2>/tmp/fm-live-drv/$label.lab)"; unset TMUX
W=$(mktemp -d /tmp/fm-live-w.XXXX); export PATH=$W/$label/stubs:$PATH
/tmp/fm-live-drv/world.sh $R $W $label $variant $claim $shape > /tmp/fm-live-drv/$label.build 2>&1 || { echo BUILD FAIL; cat /tmp/fm-live-drv/$label.build; }
C=$W/$label; export TREEHOUSE_ROOT=$C/pool
out=$E/live-$label.txt
/tmp/fm-live-drv/snap.sh $C > $C/before.snap
{ echo "# live scenario $label: teardown=$TD variant=$variant claim=$claim shape=$shape"; echo "## world"; cat $C/vars; echo "## BEFORE"; cat $C/before.snap; } > $out
args=(); for a in "$@"; do [ "$a" = DROP ] && a=$C/drop.txt; args+=("$a"); done
rc=0; env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  "$TD" task-x1 "${args[@]}" > $C/out 2> $C/err || rc=$?
/tmp/fm-live-drv/snap.sh $C > $C/after.snap
{ echo "## COMMAND: $TD task-x1 ${args[*]}"; echo "exit=$rc"; echo "## STDOUT"; cat $C/out; echo "## STDERR"; grep -v '^●' $C/err; echo "## AFTER"; cat $C/after.snap; echo "## DIFF before->after"; diff $C/before.snap $C/after.snap && echo "(no difference)"; } >> $out
sed -n '/## COMMAND/,$p' $out | grep -v '^file state/\.treehouse\|lock.queue'
tmux kill-server 2>/dev/null
L=$FM_HOME; $R/bin/fm-lab-home.sh teardown $L && rm -rf $L && rm -rf $W && echo "cleaned lab+world"
