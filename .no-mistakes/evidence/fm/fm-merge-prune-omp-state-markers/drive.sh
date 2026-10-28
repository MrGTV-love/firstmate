#!/usr/bin/env bash
# drive.sh <name> <copy-dir> <task-id-or-empty>
set -u
name=$1 dir=$2 task=$3
B=/tmp/fm-omp-live.oMA2dW
export TMUX_TMPDIR=$B/tmux; mkdir -p $TMUX_TMPDIR
sock=fmlive
envargs=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_TASK_ID -u TMUX)
cmd="omp --no-session"
[ -n "$task" ] && cmd="FM_TASK_ID=$task $cmd"
"${envargs[@]}" tmux -L $sock new-session -d -x 200 -y 50 -s $name -c "$dir" "FM_OMP_HARNESS=omp $cmd"
sleep 30
tmux -L $sock send-keys -t $name 'Run exactly this bash command with your bash tool and then report what happened in one line: bin/fm-watch-arm.sh &' 
sleep 1; tmux -L $sock send-keys -t $name Enter
sleep 60
tmux -L $sock capture-pane -p -t $name > $B/$name-pane.txt
tmux -L $sock send-keys -t $name '/quit' ; sleep 1; tmux -L $sock send-keys -t $name Enter
sleep 5
tmux -L $sock kill-session -t $name 2>/dev/null
echo "== $name state listing" > $B/$name-state.txt
(cd "$dir" && find state -print 2>&1; ls -la stub-arm-ran.txt 2>&1; git status --porcelain --ignored 2>&1) >> $B/$name-state.txt
