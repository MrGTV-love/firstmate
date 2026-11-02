#!/usr/bin/env bash
# Evidence driver. Runs the real bin/fm-pr-merge.sh and bin/fm-review-record.py
# against a disposable task home, git worktree and no-mistakes state.sqlite whose
# only pipeline invocation is an acp:omp agent with an empty model id.
# Only the forge CLI (gh, gh-axi) is a local stand-in, so no real PR is touched.
# Usage: drive-unknown-family.sh <repo-worktree>
set -u
WT=$1
. "$WT/tests/fm-pr-merge-helpers.sh"
URL=https://github.com/example/repo/pull/9
UNKNOWN='{"ship":["gpt-5.1-codex"],"no-mistakes:unknown":["unknown"]}'
RESULTS=0

setup() {  # <name>; sets CASE and HEAD_SHA
  CASE=$(make_case "$1")
  rm -f "$CASE/fakebin/git"
  : > "$CASE/explicit-review"
  local base
  base=$(git -C "$CASE/wt" rev-parse refs/remotes/origin/main)
  git -C "$CASE/wt" commit -q --allow-empty -m 'no-mistakes(review): pipeline repair by acp:omp'
  HEAD_SHA=$(git -C "$CASE/wt" rev-parse HEAD)
  rm -f "$CASE/user-home/.no-mistakes/state.sqlite"
  python3 - "$CASE/user-home/.no-mistakes/state.sqlite" "$CASE/wt" "$base" "$HEAD_SHA" "$URL" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.executescript('''CREATE TABLE repos (id TEXT, working_path TEXT);
CREATE TABLE runs (id TEXT, repo_id TEXT, branch TEXT, base_sha TEXT, head_sha TEXT, last_pushed_sha TEXT, pr_url TEXT);
CREATE TABLE agent_invocations (run_id TEXT, step_name TEXT, agent TEXT, model TEXT, model_provider TEXT, status TEXT);''')
db.execute('INSERT INTO repos VALUES (?, ?)', ('repo', sys.argv[2]))
db.execute('INSERT INTO runs VALUES (?, ?, ?, ?, ?, ?, ?)', ('run', 'repo', 'fm/fixture', sys.argv[3], sys.argv[4], sys.argv[4], sys.argv[5]))
db.execute('INSERT INTO agent_invocations VALUES (?, ?, ?, ?, ?, ?)', ('run', 'review', 'acp:omp', '', None, 'completed'))
db.commit()
PY
  add_gh_mocks "$CASE" "$HEAD_SHA"
}

add_pipeline_author() {  # <model> <provider>
  python3 - "$CASE/user-home/.no-mistakes/state.sqlite" "$1" "$2" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute('INSERT INTO agent_invocations VALUES (?, ?, ?, ?, ?, ?)', ('run', 'review', 'claude', sys.argv[2], sys.argv[3], 'completed'))
db.commit()
PY
}

rr() {  # <reader> [extra review flags...]; records a PASS of the unknown groups
  local reader=$1
  shift
  record_review "$CASE" "$URL" "$HEAD_SHA" --author-groups "$UNKNOWN" --reader-model "$reader" "$@" >/dev/null \
    || { echo "  SETUP-ERROR: could not record $reader"; RESULTS=$((RESULTS + 1)); }
}

merge() {
  RC=0
  run_pr_merge "$CASE" task-x1 "$URL" > "$CASE/stdout" 2> "$CASE/stderr" || RC=$?
}

verify_json() {  # [extra]
  RC=0
  HOME="$CASE/user-home" PATH="$CASE/fakebin:$PATH" FM_HOME="$CASE/home" FM_STATE_OVERRIDE="$CASE/state" \
    "$WT/bin/fm-review-record.py" verify --pr "$URL" --head "$HEAD_SHA" --task task-x1 \
    --base "$(cat "$CASE/github-base")" --json "$@" > "$CASE/verify.json" 2> "$CASE/verify.err" || RC=$?
}

merged() { grep -q "^pr merge 9 --repo example/repo --match-head-commit $HEAD_SHA" "$CASE/gh.log"; }
words() { jq -s '[.[] | select(.kind == "captain-word")] | length' "$CASE/state/review-records.jsonl"; }

first_error() { grep -A2 -m1 -E '^error' "$CASE/stderr" | cut -c1-260 | tr '\n' ' '; }

expect_merge() {  # <label> [want captain words count]
  local label=$1 want=${2:-0} ok=PASS
  merge
  [ "$RC" -eq 0 ] && merged && [ "$(words)" = "$want" ] || { ok=FAIL; RESULTS=$((RESULTS + 1)); }
  printf '%s  %s\n  exit=%s  forge merge=%s  captain-word records=%s\n  stdout: %s\n' \
    "$ok" "$label" "$RC" "$(merged && grep -m1 '^pr merge ' "$CASE/gh.log" || echo none)" "$(words)" "$(tail -1 "$CASE/stdout" | cut -c1-200)"
  [ "$ok" = PASS ] || sed 's/^/  stderr: /' "$CASE/stderr"
}

expect_refuse() {  # <label> <needle>...
  local label=$1 ok=PASS needle
  shift
  merge
  if [ "$RC" -eq 0 ] || merged; then ok=FAIL; fi
  for needle in "$@"; do
    grep -qF -- "$needle" "$CASE/stderr" || { ok=FAIL; echo "  MISSING TEXT: $needle"; }
  done
  [ "$ok" = PASS ] || RESULTS=$((RESULTS + 1))
  printf '%s  %s\n  exit=%s  forge merge=%s\n  refusal: %s\n' "$ok" "$label" "$RC" "$(merged && echo RAN || echo none)" "$(first_error)"
}

heading() { printf '\n=== %s\n' "$*"; }

heading 'A. reported failure: acp:omp empty model, PASS from two known families, no owner words'
setup a1; rr claude-opus-5-5; rr gpt-5.1-codex
jq -r '"  read: head=\(.head[0:12]) reader=\(.reader_model) verdict=\(.verdict)"' "$CASE/state/review-records.jsonl"
sqlite3 "$CASE/user-home/.no-mistakes/state.sqlite" "SELECT '  author evidence: agent=' || agent || ' model=[' || model || ']' FROM agent_invocations"
verify_json --review-only
printf '  verify --review-only --json: exit=%s %s\n' "$RC" "$(jq -c '{ok,basis,reader_model}' "$CASE/verify.json")"
expect_merge 'two families merge without owner words'

setup a2; rr gpt-5.1-codex; rr gemini-3-pro
expect_merge 'reverse-order and non-Claude pair also merge (the ship group has an outside reader in gemini)'

heading 'B. old rule on the same fixture: fm-pr-merge.sh and fm-review-record.py from base f77b7973'
SCRATCH=$(mktemp -d "$TMP_ROOT/old.XXXXXX")
git -C "$WT" archive f77b7973ce14d0eb8813476cf380f8cb022ab9fb bin | tar -x -C "$SCRATCH"
git -C "$SCRATCH" init -q && git -C "$SCRATCH" add -A && git -C "$SCRATCH" commit -q -m 'base f77b7973 bin only'
setup b1; rr claude-opus-5-5; rr gpt-5.1-codex
OLD_PR_MERGE=$PR_MERGE
PR_MERGE="$SCRATCH/bin/fm-pr-merge.sh" FM_TEST_CODE_ROOT="$SCRATCH"
export FM_TEST_CODE_ROOT
expect_refuse 'old rule refuses the same two reads and demands owner words' 'model family unknown is never covered by a PASS'
PR_MERGE=$OLD_PR_MERGE
unset FM_TEST_CODE_ROOT

heading 'C. one family only, then the printed command and the printed owner-words route'
setup c1; rr claude-opus-5-5
expect_refuse 'one known family refuses' 'two different known reader families' 'SECOND_KNOWN_FAMILY_MODEL' 'captain-word --pr' "set each read's actual trigger answers and local report"
printf '  full refusal text:\n'; sed 's/^/    /' "$CASE/stderr"
cmd=$(sed -n 's/.*then record each with: //p' "$CASE/stderr"); cmd=${cmd%%; or *}
printf 'VERDICT: PASS head=%s\nOpenAI read.\n' "$HEAD_SHA" > "$CASE/second.md"
cmd=${cmd//SECOND_KNOWN_FAMILY_MODEL/gpt-5.1-codex}; cmd=${cmd//LOCAL_READER_REPORT/$CASE/second.md}
eval "$cmd" > "$CASE/second.out" 2>&1; printf '  printed review command run: exit=%s\n' "$?"
expect_merge 'printed second-family command then merge succeeds without owner words'

setup c2; rr claude-opus-5-5
merge
cmd=$(sed -n 's/.* in place of FRESH_CAPTAIN_WORDS with: //p' "$CASE/stderr"); cmd=${cmd%; inspect review-records.jsonl in the PR task home before retrying}
cmd=${cmd//FRESH_CAPTAIN_WORDS/\'merge pr 9 at this head\'}
PATH="$CASE/fakebin:$PATH" HOME="$CASE/user-home" eval "$cmd" > "$CASE/word.out" 2>&1; printf '  printed captain-word command run: exit=%s\n' "$?"
expect_merge 'owner-words route still merges' 1

heading 'D. adversarial: reads that must not count'
setup d1; rr claude-opus-5-5; rr sonnet
expect_refuse 'two readers of one family (claude-opus-5-5, sonnet)' 'uncovered commit group no-mistakes:unknown, family unknown'
setup d2; rr gpt-5.1-codex; rr o3
expect_refuse 'two OpenAI aliases (gpt-5.1-codex, o3)' 'family unknown'
setup d3; rr openrouter/anthropic/claude-sonnet-5-5; rr claude-opus-5-5
expect_refuse 'route prefix does not make a new family' 'family unknown'
setup d4; rr mistral-large; rr claude-opus-5-5
expect_refuse 'unknown-family reader plus one known reader' 'uncovered commit group no-mistakes:unknown, family unknown'

setup d5; record_review "$CASE" "$URL" 2222222222222222222222222222222222222222 --author-groups "$UNKNOWN" --reader-model gpt-5.1-codex >/dev/null; rr claude-opus-5-5
expect_refuse 'second family read names another head' 'uncovered commit group no-mistakes:unknown, family unknown'
setup d6; rr claude-opus-5-5; rr gpt-5.1-codex; record_review "$CASE" "$URL" 2222222222222222222222222222222222222222 --author-groups "$UNKNOWN" --reader-model gemini-3-pro >/dev/null
expect_refuse 'two families at head, but newest read names another head' 'head mismatch'

setup d7; rr claude-opus-5-5; rr gpt-5.1-codex --covered-groups '["ship"]'
expect_refuse 'second family read skipped the unknown group (covered-groups=ship)' 'uncovered commit group no-mistakes:unknown, family unknown'
setup d8; record_review "$CASE" "$URL" "$HEAD_SHA" --author-groups '{"all":["gpt-5.1-codex"]}' --reader-model claude-opus-5-5 >/dev/null; record_review "$CASE" "$URL" "$HEAD_SHA" --author-groups '{"all":["gpt-5.1-codex"]}' --reader-model gemini-3-pro >/dev/null
expect_refuse 'all-declaration hides the unknown family' 'uncovered commit group no-mistakes:unknown, family unknown'
setup d9; rr claude-opus-5-5; rr gpt-5.1-codex; rr mistral-large
expect_refuse 'covered, but the newest reader has an unknown family' 'model family unknown for newest reader' 'KNOWN_FAMILY_MODEL'

heading 'E. FAIL precedence stays'
setup e1; rr gpt-5.1-codex; rr gemini-3-pro --verdict FAIL; rr claude-opus-5-5
expect_refuse 'PASS from before the FAIL does not count; one later family refuses' 'no later exact-head PASS covers group no-mistakes:unknown, family unknown, that this FAIL read'
rr gpt-5.1-codex
expect_merge 'second later family clears the FAIL'
setup e2; rr claude-opus-5-5; rr gpt-5.1-codex; rr gemini-3-pro --verdict FAIL
expect_refuse 'FAIL after two family PASS reads blocks' 'verdict is FAIL at live head'

heading 'F. trigger answers and report checks stay'
setup f1; rr claude-opus-5-5; rr gpt-5.1-codex --widens-guard yes
verify_json --review-only
printf '  yes trigger: verify --review-only exit=%s kind=%s msg=%s\n' "$RC" "$(jq -r '.error.kind' "$CASE/verify.json")" "$(jq -r '.error.message' "$CASE/verify.json" | cut -c1-120)"
[ "$RC" -eq 1 ] && printf 'PASS  review-only refuses a yes trigger on the newest two-family PASS\n' || { printf 'FAIL  review-only accepted a yes trigger\n'; RESULTS=$((RESULTS + 1)); }
setup f2; rr claude-opus-5-5
printf 'VERDICT: PASS head=%s\n' 3333333333333333333333333333333333333333 > "$CASE/wrong.md"
rc=0; HOME="$CASE/user-home" FM_HOME="$CASE/home" FM_STATE_OVERRIDE="$CASE/state" "$WT/bin/fm-review-record.py" review --pr "$URL" --head "$HEAD_SHA" --verdict PASS --reader-model gpt-5.1-codex --author-groups "$UNKNOWN" --loosens-deny-allow-list no --widens-guard no --customer-data-billing-spend no --report "$CASE/wrong.md" > "$CASE/wrong.out" 2>&1 || rc=$?
printf '  report for another head: review exit=%s: %s\n' "$rc" "$(head -1 "$CASE/wrong.out" | cut -c1-160)"
[ "$rc" -ne 0 ] && printf 'PASS  report for another head is rejected at record time\n' || { printf 'FAIL  report for another head recorded\n'; RESULTS=$((RESULTS + 1)); }
expect_refuse 'the rejected second read does not count toward two families' 'family unknown'

heading 'G. away rule stays'
setup g1; rr claude-opus-5-5
write_away_record "$CASE" --words 'merge when green'
rc=0; HOME="$CASE/user-home" FM_HOME="$CASE/home" FM_STATE_OVERRIDE="$CASE/state" "$WT/bin/fm-review-record.py" captain-word --pr "$URL" --head "$HEAD_SHA" --words 'merge it' > "$CASE/away.out" 2>&1 || rc=$?
printf '  captain-word while away: exit=%s: %s\n' "$rc" "$(cut -c1-170 "$CASE/away.out" | head -1)"
[ "$rc" -eq 2 ] && printf 'PASS  captain-word still refused while away\n' || { printf 'FAIL  captain-word recorded while away\n'; RESULTS=$((RESULTS + 1)); }
expect_refuse 'away posture with one family still refuses' 'family unknown'
rr gpt-5.1-codex
expect_merge 'away posture with two families merges by the same review rule'
grep -m1 'merge landed' "$CASE/state/.wake-queue" | sed 's/^/  wake-queue: /' | cut -c1-160

heading 'H. live forge checks stay'
setup h1; rr claude-opus-5-5; rr gpt-5.1-codex; write_github_red_json "$CASE" "$HEAD_SHA" lint
FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=0 expect_refuse 'two families, red check' 'lint'
setup h2; rr claude-opus-5-5; rr gpt-5.1-codex
jq '.isDraft = true' "$CASE/github-view.json" > "$CASE/v.json" && mv "$CASE/v.json" "$CASE/github-view.json"
expect_refuse 'two families, draft PR' 'draft'
setup h3; rr claude-opus-5-5; rr gpt-5.1-codex
NEW=4444444444444444444444444444444444444444
printf '%s\n' "$NEW" > "$CASE/github-head"
jq --arg h "$NEW" '.headRefOid = $h' "$CASE/github-view.json" > "$CASE/v.json" && mv "$CASE/v.json" "$CASE/github-view.json"
merge
if [ "$RC" -ne 0 ] && ! grep -q '^pr merge ' "$CASE/gh.log"; then printf 'PASS  two families, forge head moved after the reads\n'; else printf 'FAIL  merge ran on a moved head\n'; RESULTS=$((RESULTS + 1)); fi
printf '  exit=%s refusal: %s\n' "$RC" "$(first_error)"

heading 'I. other shapes and known-family wording'
setup i1; add_pipeline_author claude-sonnet-5-5 anthropic
record_review "$CASE" "$URL" "$HEAD_SHA" --author-groups '{"ship":["gpt-5.1-codex"],"no-mistakes:unknown":["unknown"],"no-mistakes:anthropic":["claude-sonnet-5-5"]}' >/dev/null
expect_refuse 'mixed pipeline with one Claude read: the unknown group is named first' 'uncovered commit group no-mistakes:unknown, family unknown'
record_review "$CASE" "$URL" "$HEAD_SHA" --author-groups '{"ship":["gpt-5.1-codex"],"no-mistakes:unknown":["unknown"],"no-mistakes:anthropic":["claude-sonnet-5-5"]}' --reader-model gpt-5.1-codex >/dev/null
expect_merge 'mixed pipeline with Claude and OpenAI reads merges (Claude author read by OpenAI)'

setup i2; python3 - "$CASE/user-home/.no-mistakes/state.sqlite" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("UPDATE agent_invocations SET agent='claude', model='claude-sonnet-5-5', model_provider='anthropic'")
db.commit()
PY
record_review "$CASE" "$URL" "$HEAD_SHA" --author-groups '{"ship":["gpt-5.1-codex"],"no-mistakes:anthropic":["claude-sonnet-5-5"]}' >/dev/null
expect_refuse 'known-family refusal keeps the OUTSIDE_FAMILY_MODEL command' 'uncovered commit group no-mistakes:anthropic, family anthropic' 'OUTSIDE_FAMILY_MODEL'
if grep -q SECOND_KNOWN_FAMILY_MODEL "$CASE/stderr"; then printf 'FAIL  known-family refusal asked for two families\n'; RESULTS=$((RESULTS + 1)); else printf 'PASS  known-family refusal does not ask for two families\n'; fi

heading 'J. follow only the printed refusals from one partial read, each read naming only what the refusal names'
setup j1
record_review "$CASE" "$URL" "$HEAD_SHA" --author-groups "$UNKNOWN" --covered-groups '["no-mistakes:unknown"]' --reader-model claude-opus-5-5 >/dev/null
expect_refuse 'step 1: one family of the unknown group refuses' 'SECOND_KNOWN_FAMILY_MODEL'
cmd=$(sed -n 's/.*then record each with: //p' "$CASE/stderr"); cmd=${cmd%%; or *}
printf 'VERDICT: PASS head=%s\nOpenAI read.\n' "$HEAD_SHA" > "$CASE/s2.md"
cmd=${cmd//SECOND_KNOWN_FAMILY_MODEL/gpt-5.1-codex}; cmd=${cmd//LOCAL_READER_REPORT/$CASE/s2.md}
eval "$cmd" > "$CASE/s2.out" 2>&1; printf '  printed SECOND_KNOWN_FAMILY_MODEL command: exit=%s\n' "$?"
expect_refuse 'step 2: the unknown group is covered; the ship group is named next' 'uncovered commit group ship, family openai' 'OUTSIDE_FAMILY_MODEL'
cmd=$(sed -n 's/.*then record it with: //p' "$CASE/stderr"); cmd=${cmd%%; inspect *}
printf 'VERDICT: PASS head=%s\nGemini read.\n' "$HEAD_SHA" > "$CASE/s3.md"
cmd=${cmd//OUTSIDE_FAMILY_MODEL/gemini-3-pro}; cmd=${cmd//LOCAL_READER_REPORT/$CASE/s3.md}
eval "$cmd" > "$CASE/s3.out" 2>&1; printf '  printed OUTSIDE_FAMILY_MODEL command: exit=%s\n' "$?"
expect_merge 'step 3: the printed commands alone lead to a merge without owner words'

heading 'K. typed unknown author and yes-trigger merge path'
setup k1; add_pipeline_author claude-sonnet-5-5 anthropic
python3 - "$CASE/user-home/.no-mistakes/state.sqlite" <<'PY2'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("DELETE FROM agent_invocations WHERE agent='acp:omp'")
db.commit()
PY2
TYPED='{"all":["gpt-5.1-codex","claude-sonnet-5-5","mystery-9"]}'
record_review "$CASE" "$URL" "$HEAD_SHA" --author-groups "$TYPED" --reader-model gemini-3-pro >/dev/null
expect_refuse 'typed unknown author with one family refuses' 'family unknown'
record_review "$CASE" "$URL" "$HEAD_SHA" --author-groups "$TYPED" --reader-model deepseek-v3 >/dev/null
expect_merge 'typed unknown author with two families merges'

setup k2; rr claude-opus-5-5; rr gpt-5.1-codex --widens-guard yes
expect_merge 'default merge path: a yes trigger alone still does not require owner words (rule unchanged)'
setup k3; add_pipeline_author claude-sonnet-5-5 anthropic
python3 - "$CASE/user-home/.no-mistakes/state.sqlite" <<'PY2'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("DELETE FROM agent_invocations WHERE agent='acp:omp'")
db.commit()
PY2
KNOWN='{"ship":["gpt-5.1-codex"],"no-mistakes:anthropic":["claude-sonnet-5-5"]}'
record_review "$CASE" "$URL" "$HEAD_SHA" --author-groups "$KNOWN" >/dev/null
record_review "$CASE" "$URL" "$HEAD_SHA" --author-groups "$KNOWN" --reader-model gpt-5.1-codex --widens-guard yes >/dev/null
PR_MERGE="$SCRATCH/bin/fm-pr-merge.sh" FM_TEST_CODE_ROOT="$SCRATCH"
export FM_TEST_CODE_ROOT
expect_merge 'control on base f77b7973: a known-family yes trigger also merges, so the path above is old behavior'
PR_MERGE=$OLD_PR_MERGE
unset FM_TEST_CODE_ROOT

printf '\nDRIVER FAILURES: %s\n' "$RESULTS"
exit "$RESULTS"
