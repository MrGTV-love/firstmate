#!/usr/bin/env bash
# Live driver: fm-spawn's Anthropic-credential guard records an attributed deny.
# The credential is a fake placeholder string, never a real key.
set -u
WT=${1:?worktree}
cd "$WT"
eval "$(bin/fm-lab-home.sh env 2>/tmp/fm-lab-env.$$)"
TEARDOWN=$(grep -o '[^ ]*/bin/fm-lab-home.sh teardown .*' /tmp/fm-lab-env.$$ | head -1); rm -f /tmp/fm-lab-env.$$
trap 'tmux -L fm-lab kill-server 2>/dev/null; eval "$TEARDOWN" >/dev/null 2>&1' EXIT
P=$FM_HOME/projects/demo
git init -q -b main "$P"; echo x > "$P/x"; git -C "$P" add x
GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=l@x.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=l@x.invalid git -C "$P" commit -qm init
LOG=$FM_HOME/state/guard-events.jsonl
rc=0
env -u FM_TASK_ID -u ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY=fake-placeholder-not-a-key FM_SPAWN_NO_GUARD=internal \
  bin/fm-spawn.sh probe-key "$P" claude --mode no-mistakes --yolo off >"$FM_HOME/spawn.out" 2>&1 </dev/null || rc=$?
echo "spawn exit=$rc"
grep -m2 -E 'error|refus' "$FM_HOME/spawn.out" | sed 's/fake-placeholder-not-a-key/<fake>/g' | cut -c1-220
jq -c 'select(.guard=="claude-api-billing") | {guard,decision,rule,task,override}' "$LOG" 2>/dev/null
echo "launched windows: $(tmux -L fm-lab list-windows -a 2>/dev/null | wc -l | tr -d ' ')"
