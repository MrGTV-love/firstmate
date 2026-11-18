#!/usr/bin/env bash
# Live relaunch: record a successor in a lab home, then run the real
# `fm-control <task> relaunch` on a private tmux server so the real fm-spawn builds the
# write profile and starts a real, sandbox-exec-confined Claude worker. Then apply that
# generated profile to git in the copy. Scott-shaped scratch fixture with a renamed id.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M7MYQZDENGWZ8TC0F3BXCXBA
E=/Users/charlesabrooker/.no-mistakes/evidence/01M7MYQZDENGWZ8TC0F3BXCXBA
cd "$WT"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TMUX TMUX_PANE
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"
LAB=$FM_HOME
echo "== lab home: $LAB  TMUX_TMPDIR=$TMUX_TMPDIR"
export FM_GUARD_EVENT_LOG="$LAB/state/guard-events.jsonl"
T=fm-lab-succ-task
FIX=$(mktemp -d "${TMPDIR:-/tmp}/fm-scott-relaunch.XXXXXX")
sed "s/^TASK=fm-slack-second-person-scott\$/TASK=$T/" tests/fixtures/fm-scott-task-shape.sh > "$FIX.maker.sh"
mkdir "$FIX/fx"; bash "$FIX.maker.sh" "$FIX/fx" >/dev/null
P=$FIX/fx/project; SLOT=$FIX/fx/slots/22/project
cp -p "$FIX/fx/home/state/$T.meta" "$FIX/fx/home/state/$T.status" "$LAB/state/"
cp -Rp "$FIX/fx/home/state/$T.inbox" "$LAB/state/"
mkdir -p "$LAB/data/$T"; cp -p "$FIX/fx/home/data/$T/brief.md" "$LAB/data/$T/"
mkdir -p "$FIX/fx/tmp"
sed -i '' -e "s#^window=.*#window=fmlab:fm-$T#" -e '/^backend=/d' -e '/^herdr_/d' -e '/^launch_proof=/d' "$LAB/state/$T.meta"
printf '%s\n' "" "# Task" "## Captain's intent" "This is a disposable lab fixture for a test. Do nothing at all: do not run any command, do not edit any file. Reply with the single word idle and stop." "" "## Firstmate spec" "Do nothing. This worker is stopped by the test within a minute." >> "$LAB/data/$T/brief.md"
tmux new-session -d -s fmlab -c "$LAB" "sleep 3600"
tmux new-window -d -t fmlab: -n "fm-$T" -c "$SLOT" "env -i HOME=$HOME USER=$USER LANG=en_US.UTF-8 TERM=xterm-256color PATH=$PATH /bin/bash --noprofile --norc"
echo "== tmux (private) sessions:"; tmux ls
bash bin/fm-lock.sh; bash bin/fm-lock.sh status
TIP=$(git -C "$P" rev-parse "refs/heads/fm/$T-v2")
echo; echo "######## record the successor"
bash bin/fm-control.sh "$T" successor --branch "fm/$T-v2" --tip "$TIP" --note "lab relaunch proof"; echo "[exit=$?]"
NEXT_LINE=$(grep -c . /dev/null)
echo; echo "######## refs + copy before relaunch"
git -C "$P" for-each-ref --format='%(refname) %(objectname)' > "$FIX/refs.before"
git -C "$FIX/fx/gate.git" for-each-ref --format='%(refname) %(objectname)' > "$FIX/gate.before"
git -C "$SLOT" status --porcelain=v1 --ignored > "$FIX/copy.before"; git -C "$SLOT" rev-parse HEAD >> "$FIX/copy.before"
echo; echo "######## run the receipt's relaunch command"
time bash bin/fm-control.sh "$T" relaunch --note "apply recorded successor branch fm/$T-v2"; echo "[relaunch exit=$?]"
echo; echo "######## generated profile: refs/heads lines"
PROF="$LAB/state/$T.write-confinement.sb"
ls -l "$PROF"; grep -n 'refs/heads' "$PROF"
cp -p "$PROF" "$E/relaunch-generated-profile.sb" 2>/dev/null
echo; echo "######## worker process under sandbox-exec"
sleep 20
tmux list-windows -a -F '#{session_name}:#{window_name} pid=#{pane_pid} cmd=#{pane_current_command}'
for pid in $(tmux list-panes -a -F '#{pane_pid}'); do pgrep -P "$pid" -l -f . 2>/dev/null; ps -o pid=,command= -p "$pid" | cut -c1-300; done
ps -axo pid=,ppid=,command= | grep -E "sandbox-exec|claude" | grep -F "$T" | grep -v grep | cut -c1-400
echo "-- process tree under the task pane:"; for pid in $(tmux list-panes -t "fmlab:fm-$T" -F "#{pane_pid}"); do ps -axo pid=,ppid=,command= | awk -v p=$pid '$2==p || $1==p' | cut -c1-400; done
echo; echo "######## kill the private tmux server (stops the worker)"
tmux capture-pane -p -t "fmlab:fm-$T" 2>/dev/null | tail -15 > "$E/relaunch-worker-pane.txt"
tmux kill-server; sleep 1
echo; echo "######## refs/copy/gate after relaunch"
git -C "$P" for-each-ref --format='%(refname) %(objectname)' | diff "$FIX/refs.before" - && echo "project refs unchanged"
git -C "$FIX/fx/gate.git" for-each-ref --format='%(refname) %(objectname)' | diff "$FIX/gate.before" - && echo "gate refs unchanged"
{ git -C "$SLOT" status --porcelain=v1 --ignored; git -C "$SLOT" rev-parse HEAD; } | diff "$FIX/copy.before" - ; echo "(copy status diff above; worker wiring files expected)"
echo; echo "######## kernel: apply the GENERATED profile to git in the copy"
S2=$(git -C "$P" rev-parse "fm/$T")
for ref in "fm/$T-v2" "fm/$T-v3" "fm/$T-v2x" "x-fm/$T-v2" "fm/other-task" "fm/$T"; do
  out=$(/usr/bin/sandbox-exec -f "$PROF" git -C "$SLOT" update-ref "refs/heads/$ref" "$S2" 2>&1); rc=$?
  echo "update-ref refs/heads/$ref -> rc=$rc ${out:0:160}"
done
git -C "$P" for-each-ref --format='%(refname) %(objectname)' refs/heads
echo; echo "######## guard events"
jq -c 'select(.guard=="successor-branch-admission") | {decision,rule,route,successor}' "$FM_GUARD_EVENT_LOG"
echo "LAB=$LAB FIX=$FIX"
