#!/usr/bin/env bash
# labrun.sh <name> [timeout-s]: run $W/drv/<name>.sh in the lab primary pane and wait for its rc.
export TMUX_TMPDIR=/tmp/fml.1PUuvn
n=$1; t=${2:-1500}
rm -f /Users/charlesabrooker/tmp/fm-lab-work.NBfwwR/out/$n.rc /Users/charlesabrooker/tmp/fm-lab-work.NBfwwR/out/$n.log
tmux -L fm-lab send-keys -t primary:0 "bash /Users/charlesabrooker/tmp/fm-lab-work.NBfwwR/drv/$n.sh > /Users/charlesabrooker/tmp/fm-lab-work.NBfwwR/out/$n.log 2>&1; echo \$? > /Users/charlesabrooker/tmp/fm-lab-work.NBfwwR/out/$n.rc" Enter
i=0; while [ ! -f /Users/charlesabrooker/tmp/fm-lab-work.NBfwwR/out/$n.rc ] && [ $i -lt $t ]; do sleep 2; i=$((i+2)); done
echo "rc=$(cat /Users/charlesabrooker/tmp/fm-lab-work.NBfwwR/out/$n.rc 2>/dev/null || echo TIMEOUT)"; cat /Users/charlesabrooker/tmp/fm-lab-work.NBfwwR/out/$n.log
