#!/usr/bin/env bash
# Probe: a committed .gitattributes in the PR selects git's built-in union driver.
set -u
ROOT=$1; RECORD="$ROOT/bin/fm-review-record.py"; URL=https://github.com/example/repo/pull/9
SCR=$(mktemp -d "${TMPDIR:-/tmp}/fm-union.XXXXXX"); trap 'rm -rf "$SCR"' EXIT
NM="$SCR/nm"; mkdir -p "$NM"
python3 -c 'import sqlite3, sys; sqlite3.connect(sys.argv[1]).executescript("CREATE TABLE repos (id TEXT, working_path TEXT); CREATE TABLE runs (id TEXT, repo_id TEXT, branch TEXT, pr_url TEXT); CREATE TABLE agent_invocations (run_id TEXT, agent TEXT, model TEXT, model_provider TEXT);")' "$NM/state.sqlite"
C="$SCR/c"; mkdir -p "$C/home/state"
g() { git -C "$C/wt" -c user.name=Lab -c user.email=lab@example.invalid "$@"; }
git init -q -b main "$C/wt"; printf 'line\n' > "$C/wt/app.txt"; g add app.txt; g commit -qm initial; BASE=$(g rev-parse HEAD)
printf 'worktree=%s\nkind=ship\nmodel=gpt-5.1\nbranch=fm/fixture\nmode=direct-PR\n' "$C/wt" > "$C/home/state/task-x1.meta"
g checkout -q -b pr; printf 'app.txt merge=union\n' > "$C/wt/.gitattributes"; printf 'pr line\n' > "$C/wt/app.txt"; g add -A; g commit -qm pr; R=$(g rev-parse HEAD)
g checkout -q -b trunk "$BASE"; printf 'base line\n' > "$C/wt/app.txt"; g add app.txt; g commit -qm base; TRUNK=$(g rev-parse HEAD)
g checkout -q pr; g merge -q --no-edit trunk >/dev/null 2>&1; echo "merge exit=$? (0 means union resolved it in the worktree)"; g status --short; cat "$C/wt/app.txt"; H=$(g rev-parse HEAD)
printf 'VERDICT: PASS head=%s\nx\n' "$R" > "$C/r.md"
FM_HOME="$C/home" "$RECORD" review --pr "$URL" --head "$R" --verdict PASS --reader-model sonnet --author-groups '{"ship":["gpt-5.1"]}' --loosens-deny-allow-list no --widens-guard no --customer-data-billing-spend no --report "$C/r.md" >/dev/null
echo "H=${H:0:12} R=${R:0:12}"
NM_HOME="$NM" FM_HOME="$C/home" "$RECORD" verify --pr "$URL" --head "$H" --task task-x1 --base "$TRUNK" 2>&1; echo "[exit $?]"
