. $S/lab.sh
E=$1
snap() { (cd "$L/nm" && ls -1 | sort | tr '\n' ' '; echo; shasum -a 256 state.sqlite* 2>/dev/null | awk '{print "  "$1" "$2}'); }

{
echo "=== Scenario 2: rebase-agent run, then later clean rebase run; no no-mistakes( subject at head ==="
mk s2 no-mistakes gpt-5.1-codex
commit "feat: worker change after clean replay"
db "add_run('run1', None, 'fm/x'); add_inv('run1','rebase','claude','claude-sonnet-5-5','anthropic'); add_run('run2', '$URL', 'fm/x')"
echo "runs: run1 (branch match, Claude rebase agent), run2 (pr_url match, no agent)"
rec PASS claude-opus-5-5 '{"ship":["gpt-5.1-codex"]}'
ver
} 2>&1 | tee $E/s2-rebase-then-clean.txt

{
echo "=== Scenario 3: pipeline DB exists but is not a SQLite file ==="
mk s3 no-mistakes gpt-5.1-codex
commit "feat: worker"; commit "no-mistakes(review): fix"
printf 'not a sqlite database\n' > $L/nm/state.sqlite
rec PASS claude-opus-5-5 '{"ship":["gpt-5.1-codex"],"no-mistakes:unknown":["unknown"]}'
rec PASS gemini-3-pro '{"ship":["gpt-5.1-codex"],"no-mistakes:unknown":["unknown"]}'
rec PASS deepseek-v4 '{"all":["gpt-5.1-codex","unknown"]}'
ver
echo "--- the printed fix: record fresh captain words at the exact head ---"
"$RR" captain-word --pr "$URL" --head "$HEAD_SHA" --words "Merge PR 197 at this head (lab captain words)"; echo "  rc=$?"
ver
} 2>&1 | tee $E/s3-unreadable-db.txt

{
echo "=== Scenario 4: pipeline DB opens but the runs query fails (no runs table) ==="
mk s4 no-mistakes gpt-5.1-codex
commit "feat: worker"
python3 -c "import sqlite3,sys; sqlite3.connect(sys.argv[1]).execute('CREATE TABLE other (x)')" $L/nm/state.sqlite
rec PASS claude-opus-5-5 '{"ship":["gpt-5.1-codex"]}'
ver
} 2>&1 | tee $E/s4-query-fails.txt

{
echo "=== Scenario 5a: no pipeline DB at NM_HOME, task mode=no-mistakes ==="
mk s5a no-mistakes gpt-5.1-codex
commit "feat: worker"
rec PASS claude-opus-5-5 '{"ship":["gpt-5.1-codex"]}'
ver
echo "=== Scenario 5b: no pipeline DB, mode not recorded (defaults to no-mistakes) ==="
mk s5b "" gpt-5.1-codex
commit "feat: worker"
rec PASS claude-opus-5-5 '{"ship":["gpt-5.1-codex"]}'
ver
echo "=== Scenario 5c: no pipeline DB, task mode=direct-PR, Claude PASS of OpenAI ship ==="
mk s5c direct-PR gpt-5.1-codex
commit "feat: worker"
rec PASS claude-opus-5-5 '{"ship":["gpt-5.1-codex"]}'
ver
echo "=== Scenario 5d: no pipeline DB, mode=direct-PR, but a no-mistakes( subject exists ==="
mk s5d direct-PR gpt-5.1-codex
commit "feat: worker"; commit "no-mistakes(review): fix"
rec PASS claude-opus-5-5 '{"ship":["gpt-5.1-codex"]}'
ver
} 2>&1 | tee $E/s5-missing-db.txt

{
echo "=== Scenario 6: same-family read; Claude ship worker, Claude PASS with typed OpenAI-only groups ==="
mk s6 direct-PR claude-opus-5-5
commit "feat: Claude worker"
python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.executescript(open(sys.argv[2]).read())" $L/nm/state.sqlite $S/schema.sql
rec PASS claude-sonnet-5-5 '{"all":["gpt-5.1-codex"]}'
echo "--- BEFORE (base verify) ---"; "$S/old/bin/fm-review-record.py" verify --pr "$URL" --head "$HEAD_SHA"; echo "  rc=$?"
echo "--- AFTER ---"; ver
echo "--- an OpenAI read of the ship group then clears it ---"
rec PASS gpt-5.1-codex '{"ship":["claude-opus-5-5"]}'
ver
} 2>&1 | tee $E/s6-same-family-refused.txt

{
echo "=== Scenario 7: verify opens the pipeline DB read-only (WAL DB, real table layout) ==="
mk s7 no-mistakes gpt-5.1-codex
commit "feat: worker"; commit "no-mistakes(review): fix"
db "add_run('run1', '$URL', 'fm/x'); add_inv('run1','review','claude','claude-opus-5-5','anthropic')"
rec PASS claude-opus-5-5 '{"ship":["gpt-5.1-codex"]}'
rec PASS gpt-5.1-codex '{"no-mistakes:anthropic":["claude-opus-5-5"]}'
echo "before:"; snap
ver
echo "after:"; snap
echo "--- same DB made read-only (chmod 444 file): verify still reads it ---"
chmod 444 $L/nm/state.sqlite; ver; chmod 644 $L/nm/state.sqlite
echo "--- planted DB under a relative NM_HOME is not evidence ---"
mkdir -p $L/wt/.nm && cp $L/nm/state.sqlite $L/wt/.nm/
(cd $L/wt && NM_HOME=.nm "$RR" verify --pr "$URL" --head "$HEAD_SHA" --task task-x1 --base "$BASE" | sed "s#$S#<lab>#g"; echo "  rc=${PIPESTATUS[0]}")
} 2>&1 | tee $E/s7-read-only-db.txt

{
echo "=== Scenario 8: FAIL typed with a group only it names; run the printed fix command ==="
mk s8 direct-PR gpt-5.1-codex
commit "feat: worker"
python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.executescript(open(sys.argv[2]).read())" $L/nm/state.sqlite $S/schema.sql
rec PASS claude-opus-5-5 '{"ship":["gpt-5.1-codex"]}'
rec FAIL claude-opus-5-5 '{"commit-group":["gpt-5.1-codex"]}'
ver | tee $S/s8.out
cmd=$(grep -o "FM_HOME=.*LOCAL_READER_REPORT" $S/s8.out | head -1 | sed "s#<lab>#$S#g")
printf 'VERDICT: PASS head=%s\nreread\n' "$HEAD_SHA" > $L/rr.md
cmd=${cmd//OUTSIDE_FAMILY_MODEL/gemini-3-pro}; cmd=${cmd//LOCAL_READER_REPORT/$L/rr.md}
echo "\$ ${cmd//$S/<lab>}"; eval "$cmd"; echo "  rc=$?"
ver
echo "--- adversarial: a later same-family (OpenAI) PASS does not clear a FAIL on an OpenAI group ---"
rec FAIL claude-opus-5-5 '{"ship":["gpt-5.1-codex"]}'
rec PASS gpt-5.2 '{"ship":["gpt-5.1-codex"]}'
ver
} 2>&1 | tee $E/s8-fail-typed-group.txt
