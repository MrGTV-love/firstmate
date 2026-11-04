#!/usr/bin/env bash
# Live lab 2: real fm-spawn + fm-control relaunch and reconcile-only relaunch
# with a worker that uses the machine's normal Claude login (no CLAUDE_CONFIG_DIR override).
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/624bc6fbd7a5/01M6HK714J4FATY5VQP1RB486C
E=/Users/charlesabrooker/.no-mistakes/evidence/01M6HK714J4FATY5VQP1RB486C/lab-relaunch
mkdir -p "$E"
cd "$WT" || exit 1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TMUX TMUX_PANE CLAUDE_CONFIG_DIR
dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
LAB=$(bin/fm-lab-home.sh create "$dir") || { echo "lab create failed"; exit 1; }
TMUX_TMPDIR=$(bin/fm-lab-home.sh tmux-dir "$LAB") || { echo "tmux-dir failed"; exit 1; }
export FM_HOME="$LAB" TMUX_TMPDIR
owner=$(sed -n 's/^owner_pid=//p' "$LAB/.fm-lab-home")
echo "lab=$LAB socket=$TMUX_TMPDIR owner_pid=$owner self=$$"
[ "$owner" = "$$" ] || { echo "lab owner is not this live shell"; exit 1; }
SOCK="$TMUX_TMPDIR/tmux-$(id -u)/default"
SETTINGS_BEFORE=$(shasum -a 256 "$HOME/.claude/settings.json" 2>/dev/null | awk '{print $1}')
export FM_BACKEND=tmux DISABLE_AUTOUPDATER=1 TREEHOUSE_ROOT="$LAB/treehouse" TREEHOUSE_NO_UPDATE_CHECK=1
mkdir -p "$TREEHOUSE_ROOT"
CUE='use the existing Intent-to-test alignment criteria in the shared review rubric below during implementation and verification'
ID=labrl-docs
cleanup() {
  echo "== teardown"
  tmux -S "$SOCK" kill-server 2>/dev/null || true
  sleep 2
  pkill -TERM -f "$LAB" 2>/dev/null || true
  sleep 1
  "$WT/bin/fm-lab-home.sh" teardown "$LAB"; echo "lab teardown exit=$?"
  chmod -R u+w "$LAB" 2>/dev/null; rm -rf "$LAB"
  rm -rf /tmp/fm-$ID+* 2>/dev/null
  echo "lab-left: $(ls -d "$LAB" 2>/dev/null || echo none) socket-left: $(ls -d "$TMUX_TMPDIR" 2>/dev/null || echo none) procs-left: $(pgrep -f "$LAB" | tr '\n' ' ')"
  echo "settings.json unchanged: $([ "$SETTINGS_BEFORE" = "$(shasum -a 256 "$HOME/.claude/settings.json" 2>/dev/null | awk '{print $1}')" ] && echo yes || echo NO)"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

seed="$LAB/seed"; origin="$LAB/notes-origin.git"
mkdir -p "$seed/notes"
printf 'NOTES = []\n' > "$seed/notes/__init__.py"; printf '# notes\n' > "$seed/README.md"
git -C "$seed" init -q -b main && git -C "$seed" add -A && git -C "$seed" -c user.name=lab -c user.email=lab@example.invalid commit -q -m seed
git clone -q --bare "$seed" "$origin"; rm -rf "$seed"
git clone -q "$origin" "$LAB/projects/notes"
printf '# Projects\n\n- notes [local-only +yolo] - tiny lab notes library\n' > "$LAB/data/projects.md"
tmux new-session -d -s main -c "$LAB" || { echo "tmux server failed"; exit 1; }

bin/fm-brief.sh "$ID" notes --mode local-only >/dev/null 2>&1 || { echo "brief failed"; exit 1; }
TASK_TEXT="Fix the README title so it reads 'Notes library' instead of 'notes'." python3 - "$LAB/data/$ID/brief.md" <<'PY'
import os, sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
t = t.replace("{TASK}", os.environ["TASK_TEXT"], 1).replace("{FIRSTMATE_SPEC}", "Change only the first line of README.md and commit.", 1)
for k, v in {"{DOD_CAPABILITY}": "README shows the new title.",
             "{DOD_MANDATORY_ITEMS}": "M1. Source: the task text. Expected: README.md first line is '# Notes library'. Verify: head -1 README.md. Edge/negative: no other file changes. Evidence place: git diff. Authority: gate.",
             "{DOD_SUPPORTING_ITEMS}": "None.", "{DOD_HARD_GATES}": "Do not change files outside the notes repository.",
             "{DOD_HONESTY_RULE}": "Report an unrun check as unrun."}.items():
    t = t.replace(k, v, 1)
open(p, "w", encoding="utf-8").write(t)
PY
bin/fm-tasks-axi.sh add "$ID" "lab $ID" --kind ship --repo notes > "$E/tasks-add.out" 2>&1
echo "== fm-spawn $ID (normal Claude login)"
bin/fm-spawn.sh "$ID" "$LAB/projects/notes" --mode local-only --yolo on --harness claude --model sonnet --effort low > "$E/spawn.out" 2>&1
echo "spawn exit=$?"; grep -E '^spawned|error' "$E/spawn.out"
cp "$LAB/data/$ID/launch-brief.md" "$E/spawn-launch-brief.md"
win="firstmate:fm-$ID"

echo "== fm-control relaunch (retry while composer busy)"
rc=1
for try in $(seq 1 20); do
  sleep 20
  tmux capture-pane -p -t "$win" > "$E/pane-before-relaunch-$try.txt" 2>/dev/null
  bin/fm-control.sh "$ID" relaunch --note "lab relaunch progress note" > "$E/relaunch-$try.out" 2>&1; rc=$?
  echo "try=$try relaunch exit=$rc: $(grep -E '^error' "$E/relaunch-$try.out" | head -1 | cut -c1-160)"
  [ "$rc" -ne 0 ] || break
done
sleep 15
lb="$LAB/data/$ID/launch-brief.md"; cp "$lb" "$E/relaunch-launch-brief.md"
tmux capture-pane -p -t "$win" > "$E/pane-after-relaunch.txt" 2>/dev/null
echo "relaunch: exit=$rc note=$(grep -c 'lab relaunch progress note' "$lb") cue=$(grep -cF "$CUE" "$lb")"
awk -v cue="$CUE" '/^# Current worker role contract$/{r=NR} index($0,cue){c=NR} /^## Intent-to-test alignment$/{s=NR} END{printf "relaunch order: role=%d cue=%d section=%d\n", r,c,s}' "$lb"

echo "== stop the replacement owner, then reconcile-only relaunch"
grep -E '^(recovery|session|window|pid)=' "$LAB/state/$ID.meta" | sed 's/^/meta: /'
bin/fm-tasks-axi.sh show "$ID" > "$E/task-show.out" 2>&1; grep -iE 'status|state' "$E/task-show.out" | head -3
panepid=$(tmux display-message -p -t "$win" '#{pane_pid}')
for p in $(pgrep -P "$panepid"); do echo "stopping pane child $p: $(ps -o command= -p "$p" | cut -c1-80)"; kill -TERM "$p"; done
sleep 10
tmux capture-pane -p -t "$win" > "$E/pane-after-stop.txt" 2>/dev/null
rc=1
for try in 1 2 3; do
  bin/fm-control.sh "$ID" relaunch --reconcile-only --note "Read unread instructions; retain the genuine blocker." > "$E/reconcile-$try.out" 2>&1; rc=$?
  echo "try=$try reconcile-only exit=$rc: $(grep -E '^error' "$E/reconcile-$try.out" | head -1 | cut -c1-200)"
  [ "$rc" -ne 0 ] || break
  sleep 15
done
sleep 15
cp "$lb" "$E/reconcile-launch-brief.md"
tmux capture-pane -p -t "$win" > "$E/pane-after-reconcile.txt" 2>/dev/null
echo "reconcile: exit=$rc recovery=$(sed -n 's/^recovery=//p' "$LAB/state/$ID.meta") cue=$(grep -cF "$CUE" "$lb")"
awk -v cue="$CUE" '/^# Current worker role contract$/{r=NR} index($0,cue){c++; cl=NR} /^# Current reconciliation-only recovery contract$/{rc=NR} END{printf "reconcile order: role=%d cue=%d(count %d) recovery-contract=%d\n", r,cl,c,rc}' "$lb"
