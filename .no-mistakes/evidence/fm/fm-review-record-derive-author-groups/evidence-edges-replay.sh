#!/usr/bin/env bash
# Disposable live replay of pipeline-evidence edge cases against bin/fm-review-record.py.
set -u
ROOT=$1; NEW="$ROOT/bin/fm-review-record.py"; URL=https://github.com/example/repo/pull/250
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
run_case() { # name invocation-rows(python list literal or MISSING)
  local name=$1 rows=$2 W BASE HEAD
  W=$(mktemp -d "${TMPDIR:-/tmp}/fm-edge.XXXXXX"); mkdir -p "$W/fm/state" "$W/nm"
  git init -q -b main "$W/wt"; git -C "$W/wt" commit -q --allow-empty -m base; BASE=$(git -C "$W/wt" rev-parse HEAD)
  git -C "$W/wt" checkout -q -b fm/edge
  git -C "$W/wt" commit -q --allow-empty -m 'no-mistakes(review): pipeline fix'
  HEAD=$(git -C "$W/wt" rev-parse HEAD)
  printf 'worktree=%s\nproject=%s\nkind=ship\nmodel=gpt-6.1-codex\nbranch=fm/edge\n' "$W/wt" "$W/wt" > "$W/fm/state/edge.meta"
  if [ "$rows" != MISSING ]; then
    python3 - "$W/nm/state.sqlite" "$W/wt" "$BASE" "$HEAD" "$URL" "$rows" <<'PY'
import sqlite3, sys, ast
with sqlite3.connect(sys.argv[1]) as db:
    db.executescript('''CREATE TABLE repos (id TEXT, working_path TEXT);
CREATE TABLE runs (id TEXT, repo_id TEXT, branch TEXT, base_sha TEXT, head_sha TEXT, last_pushed_sha TEXT, pr_url TEXT);
CREATE TABLE agent_invocations (run_id TEXT, agent TEXT, model TEXT, model_provider TEXT, status TEXT);''')
    db.execute("INSERT INTO repos VALUES ('r', ?)", (sys.argv[2],))
    db.execute("INSERT INTO runs VALUES ('run1','r','fm/edge',?,?,?,?)", (sys.argv[3], sys.argv[4], sys.argv[4], sys.argv[5]))
    for row in ast.literal_eval(sys.argv[6]):
        db.execute("INSERT INTO agent_invocations VALUES ('run1',?,?,?,?)", row)
PY
  fi
  printf 'VERDICT: PASS head=%s\n' "$HEAD" > "$W/r.md"
  printf '\n=== %s ===\ninvocations: %s\n' "$name" "$rows"
  FM_HOME="$W/fm" FM_STATE_OVERRIDE="$W/fm/state" NM_HOME="$W/nm" "$NEW" review --pr "$URL" --head "$HEAD" --verdict PASS \
    --reader-model gpt-6.1-codex --author-groups '{"all":["claude-sonnet-5-5"]}' --loosens-deny-allow-list no --widens-guard no \
    --customer-data-billing-spend no --report "$W/r.md"
  echo "reader: gpt-6.1-codex (openai) PASS"
  FM_HOME="$W/fm" FM_STATE_OVERRIDE="$W/fm/state" NM_HOME="$W/nm" "$NEW" verify --pr "$URL" --head "$HEAD" --task edge --base "$BASE"
  echo "exit=$?"; [ -e "$W/nm/state.sqlite" ] || echo "state.sqlite still absent after verify (never created)"
  rm -rf "$W"
}
run_case "E1 completed claude row: OpenAI PASS covers no-mistakes:anthropic" "[('claude','claude-sonnet-5-5','anthropic','completed')]"
run_case "E2 cancelled claude row with empty model counts as anthropic, OpenAI PASS covers it" "[('claude','claude-sonnet-5-5','anthropic','completed'),('claude','',None,'cancelled')]"
run_case "E3 errored acp:omp row with empty model stays unknown and refuses" "[('claude','claude-sonnet-5-5','anthropic','completed'),('acp:omp','',None,'error')]"
run_case "E4 no pipeline database: pipeline commits stay unknown and refuse" MISSING
run_case "E5 pipeline row is openai: OpenAI reader cannot cover its own family" "[('codex','gpt-6.1-codex','openai','completed')]"
