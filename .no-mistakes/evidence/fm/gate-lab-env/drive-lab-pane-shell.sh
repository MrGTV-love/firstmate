#!/usr/bin/env bash
# Same yaml recipe, but the session command is a shell, to show what a lab pane's scripts inherit.
set -u
cd /Users/charlesabrooker/.no-mistakes/worktrees/e2f2c2589455/01M5V67F71R43THE1MJNPXPAD2
unset FM_HOME
eval "$(bin/fm-lab-home.sh env 2>/tmp/fmlabpane.$$)"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE tmux -L fm-lab new-session -d -x 160 -y 20 -s primary -c "$PWD" -e FM_HOME="$FM_HOME" \
  'echo FM_HOME=$FM_HOME; echo TMUX=$TMUX; bin/fm-send.sh probe-target hi; echo send_exit=$?; sleep 30'
sleep 3
tmux -L fm-lab capture-pane -p -t primary | sed '/^[[:space:]]*$/d'
tmux -L fm-lab kill-server; sleep 1
bash -c "$(sed -n 's/^fm-lab-home: teardown: //p' /tmp/fmlabpane.$$)"; echo "teardown exit=$?; lab removed: $([ -e "$FM_HOME" ] && echo NO || echo yes)"
rm -f /tmp/fmlabpane.$$
