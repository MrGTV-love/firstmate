#!/usr/bin/env bash
# Start a real Claude primary on the lab socket using the .no-mistakes.yaml recipe.
set -u
cd /Users/charlesabrooker/.no-mistakes/worktrees/e2f2c2589455/01M5V67F71R43THE1MJNPXPAD2
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M5V67F71R43THE1MJNPXPAD2
unset FM_HOME
eval "$(bin/fm-lab-home.sh env 2>"$EV/primary-env.stderr.txt")"
cat "$EV/primary-env.stderr.txt"
touch "$FM_HOME/config/supervision-host"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE tmux -L fm-lab new-session -d -x 200 -y 50 -s primary -c "$PWD" -e FM_HOME="$FM_HOME" claude
cap() { tmux -L fm-lab capture-pane -p -t primary; }
for i in $(seq 1 30); do sleep 1; cap | grep -qiE 'trust|❯|>' && break; done
echo "===== pane after launch"; cap
if cap | grep -qi 'trust'; then tmux -L fm-lab send-keys -t primary Down; sleep 1; tmux -L fm-lab send-keys -t primary Enter; sleep 8; echo "===== after trust Yes"; cap; fi
sleep 6
tmux -L fm-lab send-keys -t primary '!' ; sleep 1
tmux -L fm-lab send-keys -t primary -l 'echo FM_HOME=$FM_HOME; echo TMUX=$TMUX; bin/fm-send.sh probe-target hi; echo send_exit=$?'
sleep 1; tmux -L fm-lab send-keys -t primary Enter
for i in $(seq 1 30); do sleep 1; cap | grep -q 'send_exit=' && cap | grep -qE 'send_exit=[0-9]' && break; done
sleep 2
echo "===== pane after lifecycle probe"; cap
tmux -L fm-lab kill-server; sleep 1
TD=$(sed -n 's/^fm-lab-home: teardown: //p' "$EV/primary-env.stderr.txt")
bash -c "$TD"; echo "teardown exit=$?"
echo "lab removed: $([ -e "$FM_HOME" ] && echo NO || echo yes); socket dir removed: $([ -e "$TMUX_TMPDIR" ] && echo NO || echo yes)"
