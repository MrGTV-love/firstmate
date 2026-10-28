#!/usr/bin/env bash
set -u
W=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M621V9T0NMTW7XG2T3152C8P
B=/tmp/fm-omp-live.oMA2dW
eval "$($W/bin/fm-lab-home.sh env 2>$B/lab-env.err)"
cat $B/lab-env.err
touch "$FM_HOME/.probe"; rm "$FM_HOME/.probe"
echo "FM_HOME=$FM_HOME" > $B/home-lab.txt
find "$FM_HOME/state" -print > $B/home-before.txt
dir=$B/new/copy
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_TASK_ID -u TMUX \
  tmux -L fm-lab new-session -d -x 200 -y 50 -s primary -c "$dir" -e FM_HOME="$FM_HOME" "FM_OMP_HARNESS=omp omp --no-session"
sleep 30
tmux -L fm-lab send-keys -t primary 'Run exactly this bash command with your bash tool and then report what happened in one line: bin/fm-watch-arm.sh &'
sleep 1; tmux -L fm-lab send-keys -t primary Enter
sleep 60
tmux -L fm-lab capture-pane -p -t primary > $B/home-pane.txt
tmux -L fm-lab send-keys -t primary '/quit'; sleep 1; tmux -L fm-lab send-keys -t primary Enter
sleep 5
{ echo "== lab home state after"; find "$FM_HOME/state" -print; echo "== copy state"; (cd $dir && find state -print 2>&1); } > $B/home-state.txt
tmux -L fm-lab kill-server 2>/dev/null
grep -o 'teardown: .*' $B/lab-env.err | sed 's/^teardown: //' > $B/teardown.cmd
