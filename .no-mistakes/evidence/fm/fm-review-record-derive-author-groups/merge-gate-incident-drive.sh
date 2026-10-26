#!/usr/bin/env bash
# Drives the real bin/fm-pr-merge.sh for the PR-197 incident shape using the
# suite's fixture builders (disposable git repo, task home, forge stub for gh,
# disposable no-mistakes state.sqlite). Prints the merge helper's own output.
# Usage: merge-gate-incident-drive.sh <worktree>
. "$1/tests/fm-pr-merge-helpers.sh"
url=https://github.com/example/repo/pull/197
case_dir=$(make_case incident-drive)
rm "$case_dir/fakebin/git"            # real git: real commit evidence
: > "$case_dir/explicit-review"
base=$(git -C "$case_dir/wt" rev-parse refs/remotes/origin/main)
git -C "$case_dir/wt" commit -q --allow-empty -m 'no-mistakes(review): pipeline fix'
head=$(git -C "$case_dir/wt" rev-parse HEAD)
mkdir -p "$case_dir/user-home/.no-mistakes"
python3 - "$case_dir/user-home/.no-mistakes/state.sqlite" "$case_dir/wt" "$base" "$head" "$url" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    db.executescript('''CREATE TABLE repos (id TEXT, working_path TEXT);
CREATE TABLE runs (id TEXT, repo_id TEXT, branch TEXT, base_sha TEXT, head_sha TEXT, last_pushed_sha TEXT, pr_url TEXT);
CREATE TABLE agent_invocations (run_id TEXT, agent TEXT, model TEXT, model_provider TEXT, status TEXT);''')
    db.execute("INSERT INTO repos VALUES ('repo', ?)", (sys.argv[2],))
    db.execute("INSERT INTO runs VALUES ('run','repo','fm/fixture',?,?,?,?)", (sys.argv[3], sys.argv[4], sys.argv[4], sys.argv[5]))
    db.execute("INSERT INTO agent_invocations VALUES ('run','claude','claude-sonnet-5-5','anthropic','completed')")
PY
add_gh_mocks "$case_dir" "$head"
echo "--- commits outside base:"; git -C "$case_dir/wt" log --format='  %h %s' "$base..$head"
echo "--- ship meta model: $(sed -n 's/^model=//p' "$case_dir/state/task-x1.meta")"
echo "--- record the incident's only read: Claude PASS typed {\"all\":[\"openai-codex/gpt-6.1-sol\"]}"
record_review "$case_dir" "$url" "$head" --author-groups '{"all":["openai-codex/gpt-6.1-sol"]}'
echo "--- \$ fm-pr-merge.sh task-x1 $url"
rc=0; run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/out" 2> "$case_dir/err" || rc=$?
sed "s#$case_dir#\$CASE#g" "$case_dir/err"; echo "[exit $rc]"
echo "--- forge merge calls: $(grep -c '^pr merge ' "$case_dir/gh.log" || true)"
echo "--- add OpenAI read of pipeline group and Claude read of ship group"
record_review "$case_dir" "$url" "$head" --author-groups '{"ship":["gpt-5.1-codex"],"no-mistakes:anthropic":["claude-sonnet-5-5"]}' --covered-groups '["no-mistakes:anthropic"]' --reader-model gpt-5.1-codex
record_review "$case_dir" "$url" "$head" --author-groups '{"ship":["gpt-5.1-codex"],"no-mistakes:anthropic":["claude-sonnet-5-5"]}' --covered-groups '["ship"]'
echo "--- \$ fm-pr-merge.sh task-x1 $url"
rc=0; run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/out" 2> "$case_dir/err" || rc=$?
sed "s#$case_dir#\$CASE#g" "$case_dir/err" | tail -4; echo "[exit $rc]"
echo "--- forge merge calls:"; grep '^pr merge ' "$case_dir/gh.log"
