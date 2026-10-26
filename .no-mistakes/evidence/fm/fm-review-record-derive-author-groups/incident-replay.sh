#!/usr/bin/env bash
# Disposable live replay of the PR 197/242/250/253 incident against the real
# bin/fm-review-record.py (new) and the base-commit version (old).
set -u
ROOT=$1; OLD=$2
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-incident.XXXXXX")
trap 'chmod -R u+w "$W"; rm -rf "$W"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
NEW="$ROOT/bin/fm-review-record.py"
URL=https://github.com/example/repo/pull/197
mkdir -p "$W/fm/state" "$W/nm"
git init -q -b main "$W/wt"; git -C "$W/wt" commit -q --allow-empty -m base
BASE=$(git -C "$W/wt" rev-parse HEAD)
git -C "$W/wt" checkout -q -b fm/incident
git -C "$W/wt" commit -q --allow-empty -m 'feat: ship implementation'
git -C "$W/wt" commit -q --allow-empty -m 'no-mistakes(review): fix finding one'
git -C "$W/wt" commit -q --allow-empty -m 'no-mistakes(test): fix finding two'
HEAD=$(git -C "$W/wt" rev-parse HEAD)
printf 'worktree=%s\nproject=%s\nkind=ship\nmodel=openai-codex/gpt-6.1-sol\nbranch=fm/incident\nmode=no-mistakes\n' "$W/wt" "$W/wt" > "$W/fm/state/inc.meta"
python3 - "$W/nm/state.sqlite" "$W/wt" "$BASE" "$HEAD" "$URL" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    db.executescript('''CREATE TABLE repos (id TEXT, working_path TEXT);
CREATE TABLE runs (id TEXT, repo_id TEXT, branch TEXT, base_sha TEXT, head_sha TEXT, last_pushed_sha TEXT, pr_url TEXT);
CREATE TABLE agent_invocations (run_id TEXT, agent TEXT, model TEXT, model_provider TEXT, status TEXT);''')
    db.execute("INSERT INTO repos VALUES ('r', ?)", (sys.argv[2],))
    db.execute("INSERT INTO runs VALUES ('run1','r','fm/incident',?,?,?,?)", (sys.argv[3], sys.argv[4], sys.argv[4], sys.argv[5]))
    db.execute("INSERT INTO agent_invocations VALUES ('run1','claude','claude-sonnet-5-5','anthropic','completed')")
PY
chmod 444 "$W/nm/state.sqlite"; chmod 555 "$W/nm"
DBSUM=$(shasum -a 256 "$W/nm/state.sqlite" | cut -d' ' -f1)
rep() { printf 'VERDICT: %s head=%s\nreader report\n' "$1" "$HEAD" > "$W/r-$2.md"; echo "$W/r-$2.md"; }
env_run() { FM_HOME="$W/fm" FM_STATE_OVERRIDE="$W/fm/state" NM_HOME="$W/nm" HOME="$W/userhome" "$@"; }
record() { # verdict reader groups [extra...]
  local v=$1 r=$2 g=$3; shift 3
  env_run "$NEW" review --pr "$URL" --head "$HEAD" --verdict "$v" --reader-model "$r" --author-groups "$g" \
    --loosens-deny-allow-list no --widens-guard no --customer-data-billing-spend no --report "$(rep "$v" "$r$RANDOM")" "$@"
}
verify_new() { env_run "$NEW" verify --pr "$URL" --head "$HEAD" --task inc --base "${1:-$BASE}"; echo "exit=$?"; }
verify_old() { env_run python3 "$OLD" verify --pr "$URL" --head "$HEAD"; echo "exit=$?"; }
say() { printf '\n=== %s ===\n' "$*"; }

say "S1 incident replay: Main types {\"all\":[\"openai-codex/gpt-6.1-sol\"]}, only a Claude PASS exists"
echo "commits:"; git -C "$W/wt" log --format='  %h %s' "$BASE..$HEAD"
record PASS claude-opus-5-5 '{"all":["openai-codex/gpt-6.1-sol"]}'
echo "--- OLD gate (base commit 4c4ffde9) verify:"; verify_old
echo "--- NEW gate verify:"; verify_new

say "S2 adversarial: Main types only a ship group and claims covered-groups [\"ship\"]"
record PASS claude-opus-5-5 '{"ship":["openai-codex/gpt-6.1-sol"]}' --covered-groups '["ship"]'
verify_new

say "S3 fix route: an OpenAI PASS reads the derived no-mistakes:anthropic group"
record PASS gpt-6.1-codex '{"ship":["openai-codex/gpt-6.1-sol"],"no-mistakes:anthropic":["claude-sonnet-5-5"]}' --covered-groups '["no-mistakes:anthropic"]'
verify_new

say "S4 G2 read-only DB: database bytes unchanged and no journal/WAL files created"
echo "sha256 before=$DBSUM after=$(shasum -a 256 "$W/nm/state.sqlite" | cut -d' ' -f1)"; ls -la "$W/nm"

say "S5 base must be full 40/64 hex: short base refused"
verify_new "${BASE:0:12}"

say "S6 sticky exact-head FAIL: a FAIL then a later PASS still refuses"
record FAIL gemini-3-pro '{"ship":["openai-codex/gpt-6.1-sol"],"no-mistakes:anthropic":["claude-sonnet-5-5"]}'
record PASS gemini-3-pro '{"ship":["openai-codex/gpt-6.1-sol"],"no-mistakes:anthropic":["claude-sonnet-5-5"]}'
verify_new
echo "--- fresh exact-head captain words, then verify:"
env_run "$NEW" captain-word --pr "$URL" --head "$HEAD" --words 'Merge PR 197 at this head.'; verify_new
