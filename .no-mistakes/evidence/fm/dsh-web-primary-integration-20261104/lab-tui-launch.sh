#!/usr/bin/env bash
# Live scenario: launch-owned DSH TUI primary started from a shell that carries
# an inherited native Web identity. Run from the gate worktree.
set -eu
eval "$(bin/fm-lab-home.sh env)"
printf 'FM_HOME=%s\nTMUX_TMPDIR=%s\n' "$FM_HOME" "$TMUX_TMPDIR"
git init -q "$FM_HOME"
printf 'lab primary fixture\n' > "$FM_HOME/AGENTS.md"
mkdir -p "$FM_HOME/bin" "$FM_HOME/lab-operator-home"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
  -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  tmux -L fm-lab new-session -d -s primary -x 200 -y 50 -c "$PWD" -e FM_HOME="$FM_HOME" \
  -e DSH_PROFILE=web -e DSH_SESSION_ID=parent-web-inherited-1234 -e DSH_SHELL=1 \
  -e FM_DSH_OPERATOR_HOME="$FM_HOME/lab-operator-home" \
  bash bin/fm-dsh-primary.sh --model deepseek/deepseek-v4-flash --effort low -- 'Reply with the single word READY. Do not run any tools.'
