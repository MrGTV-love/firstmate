#!/usr/bin/env bash
# Sandbox: a captain-held ship whose interrupted teardown left a pending retain
# record, rewritten to the merge-train close shape. Then the captain answers with
# the real bin/fm-captain-hold.sh. Shows what the held row records.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6G0SSW287C5ENA2421F4C38
. "$WT/tests/fm-captain-hold-lifecycle-helpers.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
train=https://github.com/example/repo/pull/9
member=https://github.com/example/repo/pull/7
gerrit_url=https://gerrit.example.com/c/project/+/12345
home=$(make_home train-retained-answer)
id=sample-train-retained-answer
repo="$home/projects/sample"
wt="$home/projects/$id"
fm_git_worktree "$repo" "$wt" fm/train-retained-answer
tasks_in "$home" add "$id" "Ship the held train member" --kind ship --repo sample --start >/dev/null
fm_write_meta "$home/state/$id.meta" \
  "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
  "project=$repo" "harness=codex" "model=gpt-5.1-codex" "kind=ship" "mode=no-mistakes" \
  "pr=$gerrit_url" "spawn_gen=fixture-$id"
printf 'done: change landed\n' > "$home/state/$id.status"
run_captain "$home" hold "$id" --reason "captain must choose the follow-up" >/dev/null
printf '#!/usr/bin/env bash\nexit 1\n' > "$home/fakebin/treehouse"; chmod +x "$home/fakebin/treehouse"
rc=0
PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" > "$home/teardown.out" 2> "$home/teardown.err" || rc=$?
marker="$home/state/$id.backlog-close"
echo "# captain-hold train marker sandbox at $(git -C "$WT" rev-parse HEAD)"
echo "teardown exit (treehouse return made to fail): $rc"
echo "--- pending record written by teardown:"; cat "$marker"
grep -v '^arg=' "$marker" > "$marker.new"
printf 'arg=--pr\narg=%s\narg=--note\narg=closed by merge train: %s\n' "$train" "$member" >> "$marker.new"
mv "$marker.new" "$marker"
echo "--- pending record rewritten to the merge-train close shape:"; cat "$marker"
printf 'Proceed with the landed change.\n' > "$home/answer.txt"
rc=0
run_captain "$home" answer "$id" --decision-file "$home/answer.txt" > "$home/answer.out" 2> "$home/answer.err" || rc=$?
echo "--- captain answer exit: $rc"
echo "--- answer stderr:"; cat "$home/answer.err"
echo "--- row after the answer:"; tasks_in "$home" show "$id" --full
echo "--- backlog lines for the row:"; grep -n -A3 -F "$id" "$home/data/backlog.md" 2>/dev/null || true
echo "--- ledger task.closed lines:"; grep -rh 'task.closed' "$home/state" "$home/data" 2>/dev/null | head -5 || true
