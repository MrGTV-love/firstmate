#!/usr/bin/env bash
# Live drive of bin/fm-review-record.py (the merge gate's review authority)
# against a disposable FM_HOME, real git repositories and a disposable
# no-mistakes state.sqlite built with the real no-mistakes table layout.
# Usage: live-author-gate-scenarios.sh <worktree> <base-commit>
set -u
WT=$1 BASECOMMIT=$2
NEW="$WT/bin/fm-review-record.py"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-author-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
unset NM_HOME FM_STATE_OVERRIDE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
mkdir -p "$LAB/old"
git -C "$WT" archive "$BASECOMMIT" bin | tar -x -C "$LAB/old"
OLD="$LAB/old/bin/fm-review-record.py"

say() { printf '\n=== %s\n' "$*"; }
run() { printf '$ %s\n' "$*" | sed "s#$LAB#\$LAB#g; s#$WT#\$WT#g"; "$@" 2>&1 | sed "s#$LAB#\$LAB#g; s#$WT#\$WT#g"; printf '[exit %s]\n' "${PIPESTATUS[0]}"; }

# make_world <name> <object-format> <ship-model> <nm-commits>
make_world() {
  local name=$1 fmt=$2 ship=$3 nm=$4 d="$LAB/$1"
  mkdir -p "$d/home/state" "$d/nm"
  git init -q --object-format="$fmt" -b main "$d/wt"
  git -C "$d/wt" commit -q --allow-empty -m 'base'
  git -C "$d/wt" update-ref refs/remotes/origin/main HEAD
  git -C "$d/wt" checkout -q -b fm/incident
  git -C "$d/wt" commit -q --allow-empty -m 'feat(bin): ship worker implementation'
  local i=1
  while [ "$i" -le "$nm" ]; do
    git -C "$d/wt" commit -q --allow-empty -m "no-mistakes(review): pipeline fix $i"
    i=$((i + 1))
  done
  printf '%s\n' "worktree=$d/wt" "project=$d/wt" kind=ship "model=$ship" branch=fm/incident spawn_gen=g1 > "$d/home/state/task-x1.meta"
  printf 'g1\t\t%s\n' "$ship" > "$d/home/state/task-x1.launch-models"
  BASE=$(git -C "$d/wt" rev-parse refs/remotes/origin/main)
  HEAD_SHA=$(git -C "$d/wt" rev-parse HEAD)
  D=$d
}

# make_db <dir> <pr> <base> <head> <agent|model|provider|exit_status>...
make_db() {
  local d=$1 pr=$2 base=$3 head=$4; shift 4
  python3 - "$d/nm/state.sqlite" "$d/wt" "$pr" "$base" "$head" "$@" <<'PY'
import sqlite3, sys
db_path, wt, pr, base, head, *invs = sys.argv[1:]
with sqlite3.connect(db_path) as db:
    db.executescript('''
CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE, upstream_url TEXT NOT NULL,
  fork_url TEXT, default_branch TEXT NOT NULL DEFAULT 'main', created_at INTEGER NOT NULL);
CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL REFERENCES repos(id) ON DELETE CASCADE,
  branch TEXT NOT NULL, head_sha TEXT NOT NULL, base_sha TEXT NOT NULL, worktree_dir TEXT,
  status TEXT NOT NULL DEFAULT 'pending', pr_url TEXT, last_pushed_sha TEXT,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
CREATE TABLE agent_invocations (id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  step_name TEXT NOT NULL, round INTEGER NOT NULL, purpose TEXT NOT NULL, agent TEXT NOT NULL,
  model TEXT, model_provider TEXT, session_mode TEXT NOT NULL, started_at INTEGER NOT NULL,
  completed_at INTEGER NOT NULL, duration_ms INTEGER NOT NULL, exit_status TEXT NOT NULL);''')
    db.execute("INSERT INTO repos VALUES ('r1', ?, 'https://github.com/example/firstmate', NULL, 'main', 1)", (wt,))
    db.execute("INSERT INTO runs VALUES ('run1','r1','fm/incident',?,?,NULL,'completed',?,?,1,1)", (head, base, pr, head))
    for i, inv in enumerate(invs):
        agent, model, provider, status = inv.split('|')
        db.execute("INSERT INTO agent_invocations VALUES (?, 'run1', 'review', 1, 'fix', ?, ?, ?, 'fresh', 1, 2, 1, ?)",
                   (f'inv{i}', agent, model or None if model != 'EMPTY' else '', provider or None, status))
PY
}

report() { printf 'VERDICT: %s head=%s\nlab reader report\n' "$2" "$3" > "$1"; }
rec() {  # rec <script> <home> <pr> <head> <verdict> <reader> <groups> [extra...]
  local s=$1 h=$2 pr=$3 head=$4 verdict=$5 reader=$6 groups=$7; shift 7
  report "$h/report-$reader-$verdict.md" "$verdict" "$head"
  FM_HOME="$h" python3 "$s" review --pr "$pr" --head "$head" --verdict "$verdict" --reader-model "$reader" \
    --author-groups "$groups" --loosens-deny-allow-list no --widens-guard no --customer-data-billing-spend no \
    --report "$h/report-$reader-$verdict.md" "$@"
}
verify_new() { FM_HOME="$1" NM_HOME="$2" python3 "$NEW" verify --pr "$3" --head "$4" --task task-x1 --base "$5"; }

PR=https://github.com/example/firstmate/pull/197

say "S1 incident replay: OpenAI ship worker + Claude no-mistakes pipeline commits, only a Claude PASS typed {\"all\":[\"openai-codex/gpt-6.1-sol\"]}"
make_world incident sha1 openai-codex/gpt-6.1-sol 3
make_db "$D" "$PR" "$BASE" "$HEAD_SHA" 'claude|claude-opus-5-5|anthropic|completed'
git -C "$D/wt" log --format='%h %s' "$BASE..$HEAD_SHA"
run rec "$NEW" "$D/home" "$PR" "$HEAD_SHA" PASS claude-opus-5-5 '{"all":["openai-codex/gpt-6.1-sol"]}'
DBHASH_BEFORE=$(shasum -a 256 "$D/nm/state.sqlite" | cut -d' ' -f1)
say "S1a BEFORE this change (base $BASECOMMIT copy of fm-review-record.py, same records): old gate"
run env FM_HOME="$D/home" python3 "$OLD" verify --pr "$PR" --head "$HEAD_SHA"
say "S1b AFTER this change: new gate derives authors from commits + pipeline DB"
run verify_new "$D/home" "$D/nm" "$PR" "$HEAD_SHA" "$BASE"
CMD=$(verify_new "$D/home" "$D/nm" "$PR" "$HEAD_SHA" "$BASE" 2>&1 | sed -n 's/.*record it with: //p')
CMD=${CMD%; inspect review-records.jsonl in the PR task home before retrying}

say "S2 follow the refusal's printed fix command with an OpenAI reader, then verify again"
report "$D/home/openai-read.md" PASS "$HEAD_SHA"
CMD=${CMD//OUTSIDE_FAMILY_MODEL/gpt-5.1-codex}
CMD=${CMD//LOCAL_READER_REPORT/$D/home/openai-read.md}
printf '$ %s\n' "$CMD" | sed "s#$LAB#\$LAB#g; s#$WT#\$WT#g"
eval "$CMD" 2>&1; echo "[exit $?]"
CMD=$(verify_new "$D/home" "$D/nm" "$PR" "$HEAD_SHA" "$BASE" 2>&1 | sed -n 's/.*record it with: //p')
CMD=${CMD%; inspect review-records.jsonl in the PR task home before retrying}
run verify_new "$D/home" "$D/nm" "$PR" "$HEAD_SHA" "$BASE"
say "S2b the typed all:[openai] Claude read never declared the Claude pipeline family, so ship needs its own read; follow the next printed command with a Claude reader"
report "$D/home/claude-ship-read.md" PASS "$HEAD_SHA"
CMD=${CMD//OUTSIDE_FAMILY_MODEL/claude-opus-5-5}
CMD=${CMD//LOCAL_READER_REPORT/$D/home/claude-ship-read.md}
printf '$ %s\n' "$CMD" | sed "s#$LAB#\$LAB#g; s#$WT#\$WT#g"
eval "$CMD" 2>&1; echo "[exit $?]"
run verify_new "$D/home" "$D/nm" "$PR" "$HEAD_SHA" "$BASE"
DBHASH_AFTER=$(shasum -a 256 "$D/nm/state.sqlite" | cut -d' ' -f1)
say "S7a pipeline DB untouched across verify runs (mode=ro)"
echo "sha256 before=$DBHASH_BEFORE"; echo "sha256 after =$DBHASH_AFTER"
[ "$DBHASH_BEFORE" = "$DBHASH_AFTER" ] && echo "UNCHANGED" || echo "CHANGED"
ls -1 "$D/nm"

say "S3 sticky exact-head FAIL: Gemini FAIL, then later PASS reads from both outside families"
PR2=https://github.com/example/firstmate/pull/198
make_world sticky sha1 openai-codex/gpt-6.1-sol 1
make_db "$D" "$PR2" "$BASE" "$HEAD_SHA" 'claude|claude-opus-5-5|anthropic|completed'
G='{"ship":["openai-codex/gpt-6.1-sol"],"no-mistakes:anthropic":["claude-opus-5-5"]}'
run rec "$NEW" "$D/home" "$PR2" "$HEAD_SHA" FAIL gemini-3-pro "$G"
run rec "$NEW" "$D/home" "$PR2" "$HEAD_SHA" PASS gpt-5.1-codex "$G"
run rec "$NEW" "$D/home" "$PR2" "$HEAD_SHA" PASS claude-opus-5-5 "$G"
run verify_new "$D/home" "$D/nm" "$PR2" "$HEAD_SHA" "$BASE"
say "S3b fresh exact-head captain words clear it"
run env FM_HOME="$D/home" python3 "$NEW" captain-word --pr "$PR2" --head "$HEAD_SHA" --words 'Merge PR 198 at this head.'
run verify_new "$D/home" "$D/nm" "$PR2" "$HEAD_SHA" "$BASE"

say "S4 errored acp:omp invocation with empty model stays unknown: PASS reads cannot cover it"
PR3=https://github.com/example/firstmate/pull/199
make_world omp sha1 openai-codex/gpt-6.1-sol 1
make_db "$D" "$PR3" "$BASE" "$HEAD_SHA" 'claude|claude-opus-5-5|anthropic|completed' 'acp:omp|EMPTY||error'
G='{"ship":["openai-codex/gpt-6.1-sol"],"no-mistakes:anthropic":["claude-opus-5-5"]}'
run rec "$NEW" "$D/home" "$PR3" "$HEAD_SHA" PASS gpt-5.1-codex "$G"
run rec "$NEW" "$D/home" "$PR3" "$HEAD_SHA" PASS claude-opus-5-5 "$G"
run verify_new "$D/home" "$D/nm" "$PR3" "$HEAD_SHA" "$BASE"

say "S5 cancelled claude invocation with empty model counts as anthropic; an OpenAI PASS covers it"
PR4=https://github.com/example/firstmate/pull/200
make_world cancelled sha1 openai-codex/gpt-6.1-sol 1
make_db "$D" "$PR4" "$BASE" "$HEAD_SHA" 'claude|EMPTY||cancelled'
run rec "$NEW" "$D/home" "$PR4" "$HEAD_SHA" PASS claude-opus-5-5 '{"ship":["openai-codex/gpt-6.1-sol"]}' --covered-groups '["ship"]'
run verify_new "$D/home" "$D/nm" "$PR4" "$HEAD_SHA" "$BASE"
run rec "$NEW" "$D/home" "$PR4" "$HEAD_SHA" PASS gpt-5.1-codex '{"ship":["openai-codex/gpt-6.1-sol"],"no-mistakes:anthropic":["claude"]}' --covered-groups '["no-mistakes:anthropic"]'
run verify_new "$D/home" "$D/nm" "$PR4" "$HEAD_SHA" "$BASE"

say "S6 missing pipeline DB: verify never creates one and the pipeline commits stay unknown"
PR5=https://github.com/example/firstmate/pull/201
make_world nodb sha1 openai-codex/gpt-6.1-sol 1
run rec "$NEW" "$D/home" "$PR5" "$HEAD_SHA" PASS claude-opus-5-5 '{"all":["openai-codex/gpt-6.1-sol","claude-opus-5-5"]}'
run rec "$NEW" "$D/home" "$PR5" "$HEAD_SHA" PASS gpt-5.1-codex '{"all":["openai-codex/gpt-6.1-sol","claude-opus-5-5"]}'
run verify_new "$D/home" "$D/nm" "$PR5" "$HEAD_SHA" "$BASE"
echo "files under NM_HOME after verify: [$(ls -A "$D/nm")]"

say "S8 ship relaunch history: OpenAI then Claude launches; only a Claude PASS"
PR6=https://github.com/example/firstmate/pull/202
make_world relaunch sha1 anthropic/claude-opus-5-5 0
printf 'g0\t\topenai-codex/gpt-6.1-sol\ng1\tg0\topenai-codex/gpt-6.1-sol\ng1\tg0\tanthropic/claude-opus-5-5\n' > "$D/home/state/task-x1.launch-models"
run rec "$NEW" "$D/home" "$PR6" "$HEAD_SHA" PASS claude-opus-5-5 '{"ship":["anthropic/claude-opus-5-5","openai-codex/gpt-6.1-sol"]}'
run verify_new "$D/home" "$D/nm" "$PR6" "$HEAD_SHA" "$BASE"
run rec "$NEW" "$D/home" "$PR6" "$HEAD_SHA" PASS gpt-5.1-codex '{"ship":["anthropic/claude-opus-5-5","openai-codex/gpt-6.1-sol"]}'
run verify_new "$D/home" "$D/nm" "$PR6" "$HEAD_SHA" "$BASE"

say "S9 ship-only PR (no pipeline commits), OpenAI worker, Claude PASS: routine merge still allowed"
PR7=https://github.com/example/firstmate/pull/203
make_world shiponly sha1 openai-codex/gpt-6.1-sol 0
run rec "$NEW" "$D/home" "$PR7" "$HEAD_SHA" PASS claude-opus-5-5 '{"all":["openai-codex/gpt-6.1-sol"]}'
run verify_new "$D/home" "$D/nm" "$PR7" "$HEAD_SHA" "$BASE"

say "S10 base SHA forms: SHA-256 repo with 64-hex base merges; short/branch bases refused"
PR8=https://github.com/example/firstmate/pull/204
make_world sha256 sha256 openai-codex/gpt-6.1-sol 1
make_db "$D" "$PR8" "$BASE" "$HEAD_SHA" 'claude|claude-opus-5-5|anthropic|completed'
echo "base=$BASE (${#BASE} hex)"; echo "head=$HEAD_SHA"
G='{"ship":["openai-codex/gpt-6.1-sol"],"no-mistakes:anthropic":["claude-opus-5-5"]}'
run rec "$NEW" "$D/home" "$PR8" "$HEAD_SHA" PASS claude-opus-5-5 "$G"
run rec "$NEW" "$D/home" "$PR8" "$HEAD_SHA" PASS gpt-5.1-codex "$G"
run verify_new "$D/home" "$D/nm" "$PR8" "$HEAD_SHA" "$BASE"
run verify_new "$D/home" "$D/nm" "$PR8" "$HEAD_SHA" "${BASE:0:12}"
run verify_new "$D/home" "$D/nm" "$PR8" "$HEAD_SHA" main
