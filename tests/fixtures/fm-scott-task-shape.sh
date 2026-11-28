#!/usr/bin/env bash
# Builds a scratch, non-secret fixture with the SHAPE and RELATIONSHIPS of the Scott task
# (fm-slack-second-person-scott) at 2026-11-13: its task record, its worktree slot, its
# branch topology, its archive branches and its no-mistakes run binding. Synthetic commits
# with the same relations as the real ones; no real object ids, no auth, env or token file,
# no live state read at run time. Usage: make-scott-fixture.sh <empty-dest-dir>
# Everything is created under <dest>; nothing outside it is touched.
set -euo pipefail
DEST=${1:?usage: make-scott-fixture.sh <empty-dest-dir>}
[ -d "$DEST" ] && [ -z "$(ls -A "$DEST")" ] || { echo "error: $DEST must exist and be empty" >&2; exit 1; }
DEST=$(cd "$DEST" && pwd -P)
HERE=$(cd "$(dirname "$0")" && pwd)
TASK=fm-slack-second-person-scott
OLD=fm/$TASK
SUCC=fm/$TASK-v2
RUN_OLD=01FIXTUREOLDRUN0000000000A   # the first run: ended failed at the push step
RUN_NEW=01FIXTURENEWRUN0000000000B   # the second run: owns the successor branch, failed at test
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
commit() { # <n> <label>: n empty commits on the current branch
  local i; for ((i=1;i<=$1;i++)); do GIT_AUTHOR_DATE="2026-11-13T00:00:0${i}Z" GIT_COMMITTER_DATE="2026-11-13T00:00:0${i}Z" git commit -q --allow-empty -m "$2 $i"; done
}
PROJ=$DEST/project; GATE=$DEST/gate.git; SLOT=$DEST/slots/22/project; HOME_DIR=$DEST/home; STATE=$HOME_DIR/state
mkdir -p "$PROJ" "$DEST/slots/22" "$STATE/$TASK.inbox/handled" "$HOME_DIR/data/$TASK"
git init -q -b main "$PROJ" && cd "$PROJ"
commit 1 base                                      # M: origin/main with the merged base
M=$(git rev-parse HEAD)
git checkout -q -b "$OLD" "$M"; commit 4 submitted-S   # S: local task head, 4 commits over M
S=$(git rev-parse HEAD)
git checkout -q -b prhead "$M"; commit 8 pr-head       # B: the head pushed to the PR, 8 commits over M (diverged from S and P)
B=$(git rev-parse HEAD)
git checkout -q -b pipeline "$M"; commit 11 pipeline-P # P: the pipeline head (rebased onto M), 11 commits, diverged from S and B
P=$(git rev-parse HEAD)
commit 1 pipeline-fix; DF=$(git rev-parse HEAD)        # DF: P plus the one fix commit, run-owned, unpublished
git checkout -q "$OLD"
git branch -q "$SUCC" "$P"                              # the successor, equal to P (as made by Main 4474)
git branch -q "archive/$TASK-submitted-$(printf %.8s "$S")" "$S"
git branch -q "archive/$TASK-pipeline-$(printf %.8s "$P")" "$P"
git branch -q -D prhead pipeline
git update-ref "refs/remotes/origin/$OLD" "$B"          # the PR head, as seen by origin
git update-ref "refs/remotes/no-mistakes/$OLD" "$S"
git update-ref "refs/remotes/no-mistakes/$SUCC" "$P"
git checkout -q --detach "$M"
git worktree add -q "$SLOT" "$OLD"                      # the task's copy (pool slot 22) on the old branch
git checkout -q main 2>/dev/null || true
# The gate repo: what the no-mistakes daemon holds for the two runs (a bare repo with the same refs).
git init -q --bare "$GATE"
for r in "$M:refs/heads/main" "$B:refs/heads/$OLD" "$P:refs/heads/$SUCC" "$P:refs/no-mistakes/recover/$RUN_OLD" "$DF:refs/no-mistakes/recover/$RUN_NEW"; do
  git push -q "$GATE" "${r%%:*}:${r#*:}" 2>/dev/null || git -C "$GATE" fetch -q "$PROJ" "${r%%:*}" && git -C "$GATE" update-ref "${r#*:}" "${r%%:*}"
done
git -C "$GATE" update-ref "refs/no-mistakes/recover/$RUN_NEW" "$DF"
# The task record, shape of state/$TASK.meta with every path moved into the fixture and ids made up.
cat > "$STATE/$TASK.meta" <<META
window=fixture:w1:p1
endpoint_task_id=$TASK
worktree=$SLOT
project=$PROJ
harness=claude
kind=ship
mode=no-mistakes
yolo=off
branch=$OLD
tasktmp=$DEST/tmp/fm-$TASK
write_confinement=seatbelt-v1
claude_session_id=00000000-0000-4000-8000-000000000000
model=claude-sonnet-5-5[1m]
effort=high
jev_guard_policy=FIRSTMATE_JEV_GUARD_V1
egress=[]
skill_selection=picked
skill_selection_picked=firstmate-coding-guidelines
busy_gen=g0.0.0
spawn_gen=s0.0.0
launch_proof=env-v1
backend=herdr
dispatch_rule=rule_6
herdr_session=fixture
herdr_workspace_id=w1
herdr_tab_id=w1:t1
herdr_pane_id=w1:p1
META
# The brief: only the line that names the ship branch matters for succession (real file: data/$TASK/brief.md line 172).
mkdir -p "$HOME_DIR/data/$TASK"
printf '%s\n' "Fixture brief for $TASK" "Ship branch: $OLD" > "$HOME_DIR/data/$TASK/brief.md"
# The status log: the event verbs and keys of the real log, no free text from the real one.
cat > "$STATE/$TASK.status" <<STATUS
working [at=1]: fixture start
needs-decision [at=2] [key=nm-$RUN_NEW-review]: ask-user findings=F1
resolved [at=3] [key=nm-$RUN_NEW-review]: answered
blocked [at=4]: run $RUN_NEW ended failed at the test step; next action recover_custody would write local $SUCC; worker stopped
STATUS
# The run binding, as relationships (see README.md): the daemon's view of branch ownership.
cat > "$DEST/run-binding.txt" <<BIND
task=$TASK
copy=$SLOT
project=$PROJ
gate=$GATE
old_branch=$OLD            local=$S  gate_branch=$B  (pushed PR head, diverged from local and pipeline heads)
successor_branch=$SUCC     local=$P  gate_branch=$P  (equal to the archived pipeline head)
run_old=$RUN_OLD           failed at push; recover ref refs/no-mistakes/recover/$RUN_OLD = $P; released by Main; stays failed
run_new=$RUN_NEW           owns branch $SUCC; failed at test; recover ref refs/no-mistakes/recover/$RUN_NEW = $DF (P plus one unpublished fix commit)
branch_sync.state=pipeline_owned branch_sync.safety=blocked_pipeline_owned_recoverable branch_sync.next_action=recover_custody
local_head_of_successor=$P  pipeline_current_head=$DF  pipeline_submitted_head=$P  pushed_head=(empty)
worktree_branch_checked_out=$OLD  (the copy is on the OLD branch until Main's custody step)
BIND
echo "fixture ready under $DEST"
echo "  project:  $PROJ   copy: $SLOT   gate: $GATE"
echo "  state:    $STATE/$TASK.meta   run binding: $DEST/run-binding.txt"
