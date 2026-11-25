#!/usr/bin/env bash
# Drives the real bin/fm-review-record.py over a disposable FM_HOME and git fixture
# to show the ordering rule the task-delivery skill states.
set -u
RECORD="$1/bin/fm-review-record.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-headorder.XXXXXX"); trap 'rm -rf "$T"' EXIT
URL=https://github.com/example/repo/pull/378
mkdir -p "$T/nm" "$T/home/state"
python3 -c 'import sqlite3,sys; sqlite3.connect(sys.argv[1]).executescript("CREATE TABLE repos (id TEXT, working_path TEXT); CREATE TABLE runs (id TEXT, repo_id TEXT, branch TEXT, pr_url TEXT); CREATE TABLE agent_invocations (run_id TEXT, agent TEXT, model TEXT, model_provider TEXT);")' "$T/nm/state.sqlite"
g() { git -C "$T/wt" -c user.name=Fixture -c user.email=f@example.invalid "$@"; }
mkdir -p "$T/wt"; git -C "$T/wt" init -q -b main; echo a > "$T/wt/f"; g add f; g commit -qm initial
BASE=$(g rev-parse HEAD)
echo b >> "$T/wt/f"; g commit -qam 'ship implementation'; PRE=$(g rev-parse HEAD)
printf 'worktree=%s\nkind=ship\nmodel=claude-opus-4\nbranch=fm/fixture\nmode=direct-PR\n' "$T/wt" > "$T/home/state/task-x1.meta"
review() { printf 'VERDICT: PASS head=%s\n' "$1" > "$T/r.md"; FM_HOME="$T/home" "$RECORD" review --pr "$URL" --head "$1" --verdict PASS --reader-model gpt-5.1 --author-groups '{"all":["claude-opus-4"]}' --loosens-deny-allow-list no --widens-guard no --customer-data-billing-spend no --report "$T/r.md"; }
verify() { NM_HOME="$T/nm" FM_HOME="$T/home" "$RECORD" verify --pr "$URL" --head "$1" --task task-x1 --base "$BASE" --review-only --json; echo "exit=$?"; }
echo "## Step 1: different-family PASS recorded on the PRE-RUN head $PRE"; review "$PRE"; echo "exit=$?"
echo; echo "## Step 2: the pipeline run adds a fix commit; the green PR head moves"
echo c >> "$T/wt/f"; g commit -qam 'fix review finding'; GREEN=$(g rev-parse HEAD); echo "green head = $GREEN"
echo; echo "## Step 3 (adversarial): merge-gate verify of the GREEN head with only the pre-run PASS"; verify "$GREEN"
echo; echo "## Step 4: verify of the pre-run head still matches (shows the PASS is head-bound, not missing)"; verify "$PRE"
echo; echo "## Step 5: different-family review re-reads the GREEN head and records PASS"; review "$GREEN"; echo "exit=$?"
echo; echo "## Step 6: merge-gate verify of the GREEN head"; verify "$GREEN"
