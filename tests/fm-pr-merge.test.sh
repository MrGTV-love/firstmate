#!/usr/bin/env bash
# bin/fm-pr-merge.sh: the record, the authority, and the GitHub merge outcome.
#
# Review and captain-word authority, pr= recording, the GitHub merge outcome
# read, queue rules, and the first argument and URL refusals.
# The three groups are contiguous slices of the former suite's registration
# order, not exact themes, so a few cases sit with their neighbors.
# The other forges, reporting, and the remaining argument/URL and multi-PR
# edges live in tests/fm-pr-merge-forges.test.sh; the check-run, rollup,
# waiver, and away-authority cases live in tests/fm-pr-merge-checks.test.sh.
# Shared fixtures: tests/fm-pr-merge-helpers.sh.

# shellcheck source=tests/fm-pr-merge-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-pr-merge-helpers.sh"

test_derived_author_coverage() {
  local scenario case_dir head base url rc before after groups unknown_groups expected command rewritten
  url=https://github.com/example/repo/pull/9
  groups='{"ship":["gpt-5.1-codex"],"no-mistakes:anthropic":["claude-sonnet-5-5"]}'
  unknown_groups='{"ship":["gpt-5.1-codex"],"no-mistakes:unknown":["unknown"]}'
  for scenario in claude-only two-readers ship-only omitted-pipeline unreadable named-ship-only exact-head-fail config-fallback changed-config head-mismatch ship-history ship-prior ship-multi-read ship-default ship-reused ship-all-extra typed-unknown alias-command relative-nm-home unknown-captain-word ship-unknown-reader mixed-unknown cancelled-claude errored-omp rebased-openai rebase-claude rebase-deepseek rebase-two-readers rebase-unreadable all-prefixed fail-partial review-only-run rebase-then-clean unopenable-ship query-fails missing-db-nm missing-db-direct denied-parent fail-typed-group unknown-two-families unknown-fail-clears; do
    if [ "$scenario" = denied-parent ] && [ "$(id -u)" = 0 ]; then
      printf 'skip: denied-parent (chmod 0 does not deny root)\n'
      continue
    fi
    case_dir=$(make_case "derived-$scenario")
    rm "$case_dir/fakebin/git"
    : > "$case_dir/explicit-review"
    base=$(git -C "$case_dir/wt" rev-parse refs/remotes/origin/main)
    rewritten=
    # Main decision 029: every matching run with any invocation is author
    # evidence for the whole PR, whatever its range, steps or commit subjects.
    if [ "$scenario" = rebased-openai ] || [ "$scenario" = rebase-then-clean ]; then
      # Run A's commit; a later run's rebase rewrites it to the current SHA.
      git -C "$case_dir/wt" commit -q --allow-empty -m 'no-mistakes(review): OpenAI run draft'
      rewritten=$(git -C "$case_dir/wt" rev-parse HEAD)
      git -C "$case_dir/wt" reset -q --hard HEAD~1
    fi
    if [ "$scenario" = all-prefixed ]; then
      git -C "$case_dir/wt" commit -q --amend --allow-empty -m 'no-mistakes(review): worker-amended implementation'
    fi
    case "$scenario" in
      ship-*|rebase-*|review-only-run|unopenable-ship|query-fails|missing-db-*|denied-parent|fail-typed-group) ;;
      *) git -C "$case_dir/wt" commit -q --allow-empty -m 'no-mistakes(review): repair consumer behavior' ;;
    esac
    head=$(git -C "$case_dir/wt" rev-parse HEAD)
    rm -f "$case_dir/user-home/.no-mistakes/state.sqlite"
    python3 - "$case_dir/user-home/.no-mistakes/state.sqlite" "$case_dir/wt" "$base" "$head" "$url" "$scenario" "$rewritten" <<'PY'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as db:
    db.executescript('''CREATE TABLE repos (id TEXT, working_path TEXT);
CREATE TABLE runs (id TEXT, repo_id TEXT, branch TEXT, base_sha TEXT, head_sha TEXT, last_pushed_sha TEXT, pr_url TEXT);
CREATE TABLE agent_invocations (run_id TEXT, step_name TEXT, agent TEXT, model TEXT, model_provider TEXT, status TEXT);''')
    db.execute('INSERT INTO repos VALUES (?, ?)', ('repo', sys.argv[2]))
    db.execute('INSERT INTO runs VALUES (?, ?, ?, ?, ?, ?, ?)', ('run', 'repo', 'fm/fixture', sys.argv[3], sys.argv[4], sys.argv[4], sys.argv[5]))
    if sys.argv[6] == 'rebased-openai':
        db.execute('INSERT INTO runs VALUES (?, ?, ?, ?, ?, ?, ?)', ('run-a', 'repo', 'fm/fixture', sys.argv[3], sys.argv[7], sys.argv[7], sys.argv[5]))
        db.execute('INSERT INTO agent_invocations VALUES (?, ?, ?, ?, ?, ?)', ('run-a', 'review', 'acp:omp', 'gpt-5.1-codex', 'openai', 'completed'))
    if sys.argv[6] == 'rebase-then-clean':
        # Run A's agent resolved a conflict; the current run replayed cleanly with no agent.
        db.execute('INSERT INTO runs VALUES (?, ?, ?, ?, ?, ?, ?)', ('run-a', 'repo', 'fm/fixture', sys.argv[3], sys.argv[7], sys.argv[7], sys.argv[5]))
        db.execute('INSERT INTO agent_invocations VALUES (?, ?, ?, ?, ?, ?)', ('run-a', 'rebase', 'claude', 'claude-sonnet-5-5', 'anthropic', 'completed'))
    step = 'rebase' if sys.argv[6].startswith('rebase-') else 'review'
    if not sys.argv[6].startswith('ship-') and sys.argv[6] not in ('missing-db-direct', 'fail-typed-group', 'rebase-then-clean', 'unknown-two-families', 'unknown-fail-clears'):
        db.execute('INSERT INTO agent_invocations VALUES (?, ?, ?, ?, ?, ?)', ('run', step, 'claude', 'mystery-9' if sys.argv[6] in ('typed-unknown', 'alias-command') else 'claude-sonnet-5-5', 'anthropic', 'completed'))
    if sys.argv[6] == 'mixed-unknown':
        db.execute('INSERT INTO agent_invocations VALUES (?, ?, ?, ?, ?, ?)', ('run', 'review', 'acp:omp', None, None, 'completed'))
    if sys.argv[6] == 'cancelled-claude':
        db.execute('INSERT INTO agent_invocations VALUES (?, ?, ?, ?, ?, ?)', ('run', 'review', 'claude', '', None, 'cancelled'))
    if sys.argv[6] == 'errored-omp':
        db.execute('INSERT INTO agent_invocations VALUES (?, ?, ?, ?, ?, ?)', ('run', 'review', 'acp:omp', '', None, 'error'))
    if sys.argv[6] in ('unknown-two-families', 'unknown-fail-clears'):
        db.execute('INSERT INTO agent_invocations VALUES (?, ?, ?, ?, ?, ?)', ('run', 'review', 'acp:omp', '', None, 'completed'))
    if sys.argv[6] == 'rebase-unreadable':
        db.execute('DROP TABLE agent_invocations')
    if sys.argv[6] == 'query-fails':
        db.execute('DROP TABLE runs')
PY
    case "$scenario" in
      unreadable|config-fallback|changed-config|unknown-captain-word|unopenable-ship)
        printf 'unreadable sqlite record\n' > "$case_dir/user-home/.no-mistakes/state.sqlite" ;;
      missing-db-*) rm "$case_dir/user-home/.no-mistakes/state.sqlite" ;;
    esac
    case "$scenario" in
      missing-db-direct|denied-parent) printf 'mode=direct-pr\n' >> "$case_dir/state/task-x1.meta" ;;
    esac
    case "$scenario" in
      ship-history|ship-multi-read|ship-default|ship-reused)
        printf 'spawn_gen=gen-current\n' >> "$case_dir/state/task-x1.meta" ;;
    esac
    case "$scenario" in
      config-fallback) printf 'agent: claude\n' > "$case_dir/user-home/.no-mistakes/config.yaml" ;;
      changed-config) printf 'agent: codex\n' > "$case_dir/user-home/.no-mistakes/config.yaml" ;;
      ship-history|ship-multi-read)
        printf 'gen-first\t\tclaude-opus-5-5\ngen-current\tgen-first\tclaude-opus-5-5\ngen-current\tgen-first\tgpt-5.1-codex\n' \
          > "$case_dir/state/task-x1.launch-models" ;;
      ship-prior)
        printf 'model=claude-opus-5-5\n' > "$case_dir/state/task-x1.control-relaunch.meta-prior" ;;
      ship-default) printf 'gen-current\t\tdefault\n' > "$case_dir/state/task-x1.launch-models" ;;
      relative-nm-home)
        # A worker-planted database under a relative NM_HOME is never evidence.
        mkdir -p "$case_dir/wt/.no-mistakes"
        cp "$case_dir/user-home/.no-mistakes/state.sqlite" "$case_dir/wt/.no-mistakes/state.sqlite" ;;
      ship-reused)
        # The same task id's earlier incarnation was Claude; its lines remain.
        printf 'gen-old\t\tclaude-opus-5-5\ngen-current\t\tgpt-5.1-codex\n' > "$case_dir/state/task-x1.launch-models" ;;
    esac
    before=$(shasum -a 256 "$case_dir/user-home/.no-mistakes/state.sqlite" 2>/dev/null || true)
    add_gh_mocks "$case_dir" "$head"
    case "$scenario" in
      ship-only|omitted-pipeline|ship-prior|ship-default|ship-reused|missing-db-direct)
        record_review "$case_dir" "$url" "$head" >/dev/null || fail "record $scenario" ;;
      denied-parent)
        record_review "$case_dir" "$url" "$head" --author-groups '{"ship":["gpt-5.1-codex"]}' >/dev/null || fail 'record ship-only Claude read' ;;
      ship-history)
        # Main instruction 006: a Claude read covers the OpenAI author and an
        # OpenAI read covers the Claude author of one Claude-then-OpenAI ship group.
        record_review "$case_dir" "$url" "$head" --author-groups '{"ship":["gpt-5.1-codex","claude-opus-5-5"]}' >/dev/null || fail 'record Claude read of both ship families'
        record_review "$case_dir" "$url" "$head" --author-groups '{"ship":["gpt-5.1-codex","claude-opus-5-5"]}' --reader-model gpt-5.1-codex >/dev/null || fail 'record OpenAI read of both ship families' ;;
      alias-command)
        record_review "$case_dir" "$url" "$head" --author-groups '{"ship":["gpt-5.1-codex"]}' >/dev/null || fail 'record Claude read of ship' ;;
      ship-all-extra)
        # Main instruction 007: declared:all alone owns typed all extras, so a
        # Gemini read still covers the derived OpenAI ship group.
        record_review "$case_dir" "$url" "$head" --author-groups '{"all":["gpt-5.1-codex","gemini-x"]}' --reader-model gemini-3-pro >/dev/null || fail 'record Gemini read with a typed Google extra'
        record_review "$case_dir" "$url" "$head" --author-groups '{"declared:all":["gemini-x"]}' >/dev/null || fail 'record Claude read of the typed Google extra' ;;
      ship-multi-read)
        record_review "$case_dir" "$url" "$head" --author-groups '{"ship":["gpt-5.1-codex","claude-opus-5-5"]}' --reader-model gemini-3-pro >/dev/null || fail 'record independent read of both ship families' ;;
      typed-unknown)
        record_review "$case_dir" "$url" "$head" --author-groups '{"all":["gpt-5.1-codex","mystery-9"]}' --reader-model gemini-3-pro >/dev/null || fail 'record unknown typed constraint' ;;
      named-ship-only)
        record_review "$case_dir" "$url" "$head" --author-groups "$groups" --covered-groups '["ship"]' >/dev/null || fail 'record named Claude read'
        record_review "$case_dir" "$url" "$head" --author-groups "$groups" --covered-groups '["ship"]' --reader-model gpt-5.1-codex >/dev/null || fail 'record named OpenAI read' ;;
      rebase-claude|review-only-run|rebase-then-clean)
        # A Claude pipeline agent ran on the OpenAI worker's PR; a ship-only read is not enough.
        record_review "$case_dir" "$url" "$head" --author-groups '{"ship":["gpt-5.1-codex"]}' >/dev/null || fail 'record Claude-only read' ;;
      rebase-deepseek)
        record_review "$case_dir" "$url" "$head" --author-groups "$groups" --reader-model deepseek-v4 >/dev/null || fail 'record DeepSeek read' ;;
      all-prefixed)
        record_review "$case_dir" "$url" "$head" --author-groups '{"no-mistakes:anthropic":["claude-sonnet-5-5"]}' --reader-model gpt-5.1-codex >/dev/null || fail 'record OpenAI-only read' ;;
      fail-partial)
        # Earlier reads cover every group, but after the FAIL only ship is reread.
        record_review "$case_dir" "$url" "$head" --author-groups "$groups" >/dev/null || fail 'record Claude read'
        record_review "$case_dir" "$url" "$head" --author-groups "$groups" --reader-model gpt-5.1-codex >/dev/null || fail 'record OpenAI read'
        record_review "$case_dir" "$url" "$head" --verdict FAIL --author-groups "$groups" --reader-model gemini-3-pro >/dev/null || fail 'record FAIL of both groups'
        record_review "$case_dir" "$url" "$head" --author-groups "$groups" --covered-groups '["ship"]' >/dev/null || fail 'record later ship-only read' ;;
      rebased-openai)
        # The OpenAI-only PASS covers the Claude pipeline family, never run A's OpenAI one.
        record_review "$case_dir" "$url" "$head" --author-groups "$groups" --covered-groups '["ship"]' >/dev/null || fail 'record Claude read of ship'
        record_review "$case_dir" "$url" "$head" --author-groups "$groups" --reader-model gpt-5.1-codex >/dev/null || fail 'record OpenAI-only read' ;;
      fail-typed-group)
        record_review "$case_dir" "$url" "$head" >/dev/null || fail 'record covering Claude read'
        record_review "$case_dir" "$url" "$head" --verdict FAIL --author-groups '{"commit-group":["gpt-5.1-codex"]}' --reader-model gemini-3-pro >/dev/null || fail 'record FAIL of a typed group' ;;
      ship-unknown-reader)
        record_review "$case_dir" "$url" "$head" >/dev/null || fail 'record covering Claude read'
        record_review "$case_dir" "$url" "$head" --reader-model mistral-large >/dev/null || fail 'record newest unknown-family read' ;;
      unreadable|unknown-captain-word)
        record_review "$case_dir" "$url" "$head" --author-groups '{"all":["gpt-5.1-codex","unknown"]}' --reader-model gemini-3-pro >/dev/null || fail 'record unknown pipeline read' ;;
      unknown-two-families)
        record_review "$case_dir" "$url" "$head" --author-groups "$unknown_groups" >/dev/null || fail 'record first-family read of the unknown group' ;;
      unknown-fail-clears)
        # The OpenAI PASS predates the FAIL, so only the later Claude PASS counts.
        record_review "$case_dir" "$url" "$head" --author-groups "$unknown_groups" --reader-model gpt-5.1-codex >/dev/null || fail 'record pre-FAIL OpenAI read'
        record_review "$case_dir" "$url" "$head" --verdict FAIL --author-groups "$unknown_groups" --reader-model gemini-3-pro >/dev/null || fail 'record FAIL of the unknown group'
        record_review "$case_dir" "$url" "$head" --author-groups "$unknown_groups" >/dev/null || fail 'record later Claude read' ;;
      *)
        record_review "$case_dir" "$url" "$head" --author-groups "$groups" >/dev/null || fail "record Claude read for $scenario"
        if [ "$scenario" != claude-only ] && [ "$scenario" != mixed-unknown ]; then
          record_review "$case_dir" "$url" "$head" --author-groups "$groups" --reader-model gpt-5.1-codex >/dev/null || fail "record OpenAI read for $scenario"
        fi ;;
    esac
    if [ "$scenario" = exact-head-fail ]; then
      record_review "$case_dir" "$url" "$head" --verdict FAIL --author-groups "$groups" --reader-model gemini-3-pro >/dev/null || fail 'record blocking reader'
      record_review "$case_dir" "$url" "$head" --author-groups "$groups" --reader-model gemini-3-pro >/dev/null || fail 'record later PASS'
    fi
    if [ "$scenario" = head-mismatch ]; then
      head=9999999999999999999999999999999999999999
      add_gh_mocks "$case_dir" "$head"
      # Existing report evidence cannot authorize a different, unavailable head.
    fi
    rc=0
    if [ "$scenario" = relative-nm-home ]; then
      (cd "$case_dir/wt" && NM_HOME=.no-mistakes run_pr_merge "$case_dir" task-x1 "$url") > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    elif [ "$scenario" = denied-parent ]; then
      mkdir -p "$case_dir/denied/nm"
      cp "$case_dir/user-home/.no-mistakes/state.sqlite" "$case_dir/denied/nm/state.sqlite"
      (
        trap 'chmod 700 "$case_dir/denied"' EXIT
        chmod 0 "$case_dir/denied"
        NM_HOME="$case_dir/denied/nm" review_record_command "$case_dir" verify \
          --pr "$url" --head "$head" --task task-x1 --base "$base"
      ) > "$case_dir/stderr" 2>&1 || rc=$?
    else
      run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    fi
    if [ "$scenario" = alias-command ]; then
      expect_code 1 "$rc" "alias pipeline group must refuse before its read: $(cat "$case_dir/stderr")"
      assert_grep 'uncovered commit group no-mistakes:anthropic, family anthropic' "$case_dir/stderr" 'alias group takes the recorded provider family'
      command=$(sed -n 's/.*record it with: //p' "$case_dir/stderr")
      command=${command%; inspect review-records.jsonl in the PR task home before retrying}
      [ -n "$command" ] || fail "alias refusal printed no recording command: $(cat "$case_dir/stderr")"
      printf 'VERDICT: PASS head=%s\nOpenAI read of the Claude pipeline commits.\n' "$head" > "$case_dir/alias-report.md"
      command=${command//OUTSIDE_FAMILY_MODEL/gpt-5.1-codex}
      command=${command//LOCAL_READER_REPORT/$case_dir/alias-report.md}
      eval "$command" > "$case_dir/alias-record.out" 2>&1 || fail "the printed recording command failed: $(cat "$case_dir/alias-record.out")"
      rc=0
      run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    fi
    if [ "$scenario" = mixed-unknown ]; then
      expect_code 1 "$rc" "a mixed known and unknown pipeline must refuse: $(cat "$case_dir/stderr")"
      assert_grep 'uncovered commit group no-mistakes:unknown, family unknown; model family unknown needs exact-head PASS reads of this group from two different known reader families' "$case_dir/stderr" 'the unknown group is reported first'
      assert_grep 'captain-word --pr' "$case_dir/stderr" 'the unknown group names the captain-word route'
      assert_no_grep 'OUTSIDE_FAMILY_MODEL' "$case_dir/stderr" 'no known-family read is requested ahead of the unknown group'
    fi
    if [ "$scenario" = unknown-captain-word ]; then
      expect_code 1 "$rc" "an unknown pipeline family must refuse a one-family PASS: $(cat "$case_dir/stderr")"
      assert_grep 'uncovered commit group no-mistakes:unknown, family unknown; model family unknown needs exact-head PASS reads of this group from two different known reader families' "$case_dir/stderr" 'unknown group is named accurately'
      assert_grep 'SECOND_KNOWN_FAMILY_MODEL' "$case_dir/stderr" 'the unknown group names the second-family review route'
      command=$(sed -n 's/.* in place of FRESH_CAPTAIN_WORDS with: //p' "$case_dir/stderr")
      command=${command%; inspect review-records.jsonl in the PR task home before retrying}
      [ -n "$command" ] || fail "unknown-family refusal printed no captain-word command: $(cat "$case_dir/stderr")"
      command=${command//FRESH_CAPTAIN_WORDS/\'Merge PR 9 at this exact head.\'}
      eval "$command" > "$case_dir/captain.out" 2>&1 || fail "the printed captain-word command failed: $(cat "$case_dir/captain.out")"
      rc=0
      run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    fi
    if [ "$scenario" = unknown-two-families ] || [ "$scenario" = unknown-fail-clears ]; then
      expect_code 1 "$rc" "$scenario must refuse before the second family reads: $(cat "$case_dir/stderr")"
      if [ "$scenario" = unknown-two-families ]; then
        assert_grep 'uncovered commit group no-mistakes:unknown, family unknown; model family unknown needs exact-head PASS reads of this group from two different known reader families' "$case_dir/stderr" 'the real unknown group is refused on one family'
      else
        assert_grep 'no later exact-head PASS covers group no-mistakes:unknown, family unknown, that this FAIL read' "$case_dir/stderr" 'a PASS from before the FAIL does not count toward two families'
      fi
      assert_grep "set each read's actual trigger answers and local report" "$case_dir/stderr" 'the refusal asks for the real trigger answers'
      command=$(sed -n 's/.*then record each with: //p' "$case_dir/stderr")
      command=${command%%; or *}
      [ -n "$command" ] || fail "$scenario refusal printed no recording command: $(cat "$case_dir/stderr")"
      printf 'VERDICT: PASS head=%s\nOpenAI read of the unknown-family commits.\n' "$head" > "$case_dir/second-family.md"
      command=${command//SECOND_KNOWN_FAMILY_MODEL/gpt-5.1-codex}
      command=${command//LOCAL_READER_REPORT/$case_dir/second-family.md}
      eval "$command" > "$case_dir/second-family.out" 2>&1 || fail "the printed second-family command failed: $(cat "$case_dir/second-family.out")"
      rc=0
      run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      "$JQ_BIN" -s -e 'all(.kind != "captain-word")' "$case_dir/state/review-records.jsonl" >/dev/null \
        || fail "$scenario must merge without a captain-word record"
    fi
    if [ "$scenario" = fail-typed-group ]; then
      expect_code 1 "$rc" "a FAIL of a typed group must refuse: $(cat "$case_dir/stderr")"
      assert_grep 'no later exact-head PASS covers group commit-group, family openai, that this FAIL read' "$case_dir/stderr" 'the FAIL-typed group is named'
      command=$(sed -n 's/.*from readers outside each of its families with: //p' "$case_dir/stderr")
      command=${command%%; or obtain a fresh explicit captain merge instruction*}
      [ -n "$command" ] || fail "FAIL refusal printed no recording command: $(cat "$case_dir/stderr")"
      printf 'VERDICT: PASS head=%s\nClaude read of the FAIL-typed group.\n' "$head" > "$case_dir/typed-report.md"
      command=${command//OUTSIDE_FAMILY_MODEL/claude-opus-5-5}
      command=${command//LOCAL_READER_REPORT/$case_dir/typed-report.md}
      eval "$command" > "$case_dir/typed-record.out" 2>&1 || fail "the printed FAIL recording command failed: $(cat "$case_dir/typed-record.out")"
      rc=0
      run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    fi
    if [ "$scenario" = ship-unknown-reader ]; then
      expect_code 1 "$rc" "an unknown newest reader must refuse: $(cat "$case_dir/stderr")"
      assert_grep 'model family unknown for newest reader mistral-large; every group is covered' "$case_dir/stderr" 'the unknown reader is the named problem'
      assert_no_grep 'uncovered commit group' "$case_dir/stderr" 'a covered group is not reported as uncovered'
      command=$(sed -n 's/.*record it with: //p' "$case_dir/stderr")
      command=${command%; inspect review-records.jsonl in the PR task home before retrying}
      [ -n "$command" ] || fail "unknown-reader refusal printed no reread command: $(cat "$case_dir/stderr")"
      printf 'VERDICT: PASS head=%s\nKnown-family reread.\n' "$head" > "$case_dir/reread.md"
      command=${command//KNOWN_FAMILY_MODEL/claude-opus-5-5}
      command=${command//LOCAL_READER_REPORT/$case_dir/reread.md}
      eval "$command" > "$case_dir/reread.out" 2>&1 || fail "the printed reread command failed: $(cat "$case_dir/reread.out")"
      rc=0
      run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    fi
    case "$scenario" in
      two-readers|ship-only|ship-multi-read|ship-history|ship-reused|ship-all-extra|alias-command|unknown-captain-word|ship-unknown-reader|cancelled-claude|exact-head-fail|rebase-deepseek|rebase-two-readers|missing-db-direct|fail-typed-group|unknown-two-families|unknown-fail-clears)
        expect_code 0 "$rc" "$scenario must merge: $(cat "$case_dir/stderr")"
        assert_logged_gh_merge "$case_dir" 9 example/repo --squash ;;
      *)
        expect_code 1 "$rc" "$scenario must refuse: $(cat "$case_dir/stderr")"
        assert_no_grep '^pr merge ' "$case_dir/gh.log" "$scenario must not reach forge mutation"
        case "$scenario" in
          fail-partial) expected='no later exact-head PASS covers group no-mistakes:anthropic, family anthropic, that this FAIL read' ;;
          all-prefixed) expected='uncovered commit group ship, family openai' ;;
          head-mismatch) expected='head mismatch' ;;
          unreadable|config-fallback|changed-config|relative-nm-home|mixed-unknown|errored-omp|rebase-unreadable|unopenable-ship|query-fails|missing-db-nm|denied-parent) expected='uncovered commit group no-mistakes:unknown, family unknown' ;;
          ship-prior) expected='uncovered commit group ship, family anthropic,openai' ;;
          ship-default) expected='uncovered commit group ship, family openai,unknown' ;;
          typed-unknown) expected='family unknown' ;;
          rebased-openai) expected='uncovered commit group no-mistakes:openai, family openai' ;;
          *) expected='uncovered commit group no-mistakes:anthropic, family anthropic' ;;
        esac
        assert_grep "$expected" "$case_dir/stderr" "$scenario identifies missing independent read"
        assert_grep 'fm-review-record.py' "$case_dir/stderr" "$scenario names recording command"
        ;;
    esac
    after=$(shasum -a 256 "$case_dir/user-home/.no-mistakes/state.sqlite" 2>/dev/null || true)
    [ "$before" = "$after" ] || fail "$scenario mutated the pipeline database"
    pass "derived author coverage: $scenario"
  done
}

test_author_evidence_accepts_path_safe_legacy_task_ids() {
  local case_dir id head url rc
  head=1111111111111111111111111111111111111111
  url=https://github.com/example/repo/pull/9
  for id in _noncanonical aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa Task_A.1; do
    case_dir=$(make_case "review-task-id-$id")
    mv "$case_dir/state/task-x1.meta" "$case_dir/state/$id.meta"
    record_review "$case_dir" "$url" "$head" >/dev/null || fail 'path-safe task review must record'
    rc=0
    review_record_command "$case_dir" verify --pr "$url" --head "$head" --task "$id" --base "$(cat "$case_dir/github-base")" > "$case_dir/out" 2>&1 || rc=$?
    expect_code 0 "$rc" "supported task id $id must verify author coverage: $(cat "$case_dir/out")"
    assert_grep 'review: PASS' "$case_dir/out" 'known independent coverage must verify for the supported id'
    pass "author evidence accepts path-safe task id: $id"
  done
}

test_author_verification_names_fetch_for_missing_objects() {
  local case_dir head base url rc
  case_dir=$(make_case missing-author-objects)
  rm "$case_dir/fakebin/git"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  base=abababababababababababababababababababab
  url=https://github.com/example/repo/pull/9
  record_review "$case_dir" "$url" "$head" >/dev/null || fail 'record review before stale-base verification'
  rc=0
  PATH="$case_dir/fakebin:$PATH" HOME="$case_dir/user-home" \
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-review-record.py" verify --pr "$url" --head "$head" --task task-x1 --base "$base" > "$case_dir/out" 2>&1 || rc=$?
  expect_code 1 "$rc" "an unfetched forge base must refuse: $(cat "$case_dir/out")"
  assert_grep "fetch the exact forge base and head with: git -C $case_dir/wt fetch origin $base $head" "$case_dir/out" \
    'missing-object refusal names the exact recovery fetch'
  pass 'author verification names the exact fetch for an unfetched base'
}

test_author_verification_accepts_sha256_base() {
  local case_dir wt base head url rc
  case_dir=$(make_case sha256-author-base)
  rm "$case_dir/fakebin/git"
  wt="$case_dir/wt"
  rm -rf "$wt"
  mkdir -p "$wt"
  git -C "$wt" init -q --object-format=sha256 -b main
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q --allow-empty -m initial
  base=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q --allow-empty -m 'ship implementation'
  head=$(git -C "$wt" rev-parse HEAD)
  [ "${#base}" -eq 64 ] || fail "fixture base is not a SHA-256 object id: $base"
  url=https://github.com/example/repo/pull/9
  record_review "$case_dir" "$url" "$head" >/dev/null || fail 'record review at a SHA-256 head'
  rc=0
  PATH="$case_dir/fakebin:$PATH" HOME="$case_dir/user-home" \
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-review-record.py" verify --pr "$url" --head "$head" --task task-x1 --base "$base" > "$case_dir/out" 2>&1 || rc=$?
  expect_code 0 "$rc" "a 64-hex forge base must verify author coverage: $(cat "$case_dir/out")"
  assert_grep 'review: PASS' "$case_dir/out" 'SHA-256 base derives the ship authors'
  pass 'author verification accepts a 64-hex SHA-256 base'
}

test_github_unreadable_base_names_the_refusal() {
  local case_dir head url rc
  case_dir=$(make_case github-unreadable-base)
  head=1111111111111111111111111111111111111111
  url=https://github.com/example/repo/pull/9
  add_gh_mocks "$case_dir" "$head"
  "$JQ_BIN" -c 'del(.baseRefOid)' "$case_dir/github-view.json" > "$case_dir/view.json"
  mv "$case_dir/view.json" "$case_dir/github-view.json"
  rc=0
  run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "an unreadable GitHub base must refuse: $(cat "$case_dir/stderr")"
  assert_grep 'could not read the GitHub PR base commit for author evidence' "$case_dir/stderr" 'base read refusal names its reason'
  assert_no_grep '^pr merge ' "$case_dir/gh.log" 'unreadable base must not reach forge mutation'
  pass 'an unreadable GitHub base commit refuses with its reason'
}

test_author_verification_requires_exact_identity() {
  local case_dir scenario rc
  case_dir=$(make_case exact-evidence-identity)
  for scenario in missing-task missing-base branch-base; do
    local -a args=(--pr https://github.com/example/repo/pull/9 --head 1111111111111111111111111111111111111111)
    case "$scenario" in
      missing-task) args+=(--base "$(cat "$case_dir/github-base")") ;;
      missing-base) args+=(--task task-x1) ;;
      branch-base) args+=(--task task-x1 --base main) ;;
    esac
    rc=0
    FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
      "$ROOT/bin/fm-review-record.py" verify "${args[@]}" > "$case_dir/out" 2>&1 || rc=$?
    expect_code 2 "$rc" "$scenario must refuse without deriving from mutable refs or guessing a task"
    case "$scenario" in
      missing-task) assert_grep 'arguments are required: --task' "$case_dir/out" 'missing task diagnosis' ;;
      missing-base) assert_grep 'arguments are required: --base' "$case_dir/out" 'missing base diagnosis' ;;
      branch-base) assert_grep 'exact full base commit SHA' "$case_dir/out" 'branch name is not base evidence' ;;
    esac
  done
  pass 'author verification requires explicit task and exact base commit'
}

test_identical_captain_words_follow_append_order() {
  local case_dir head url
  case_dir=$(make_case repeated-captain-word)
  head=1111111111111111111111111111111111111111
  url=https://github.com/example/repo/pull/9
  review_record_command "$case_dir" captain-word --pr "$url" --head "$head" --words 'Merge this exact PR.' >/dev/null || fail 'record first word'
  record_review "$case_dir" "$url" "$head" --verdict FAIL >/dev/null || fail 'record intervening FAIL'
  review_record_command "$case_dir" captain-word --pr "$url" --head "$head" --words 'Merge this exact PR.' >/dev/null || fail 'record renewed word'
  # Same-second records are legal; append position must distinguish identical words.
  "$JQ_BIN" -c '.at = 1' "$case_dir/state/review-records.jsonl" > "$case_dir/same-second.jsonl"
  mv "$case_dir/same-second.jsonl" "$case_dir/state/review-records.jsonl"
  review_record_command "$case_dir" verify --pr "$url" --head "$head" > "$case_dir/out" || fail 'newest identical words did not override preceding FAIL'
  assert_grep 'review: captain-word' "$case_dir/out" 'append order must select the renewed approval'
  pass 'identical captain words at one timestamp retain append-order authority'
}

test_triggered_review_verifies_only_when_independent() {
  local case_dir head url scenario rc expected
  head=1111111111111111111111111111111111111111
  url=https://github.com/example/repo/pull/9
  for scenario in independent same-family unknown-reader unknown-author wrong-head fail; do
    case_dir=$(make_case "triggered-verify-$scenario")
    if [ "$scenario" = independent ]; then
      record_review "$case_dir" "$url" "$head" --loosens-deny-allow-list yes \
        --widens-guard yes --customer-data-billing-spend yes >/dev/null || fail "record yes-trigger PASS"
    fi
    expected=
    local review_head=$head
    local -a args=(--verdict PASS)
    case "$scenario" in
      same-family) args=(--reader-model gpt-5.1-codex); expected=reader_family ;;
      unknown-reader) args=(--reader-model mistral-large); expected='model family unknown' ;;
      unknown-author) args=(--author-groups '{"all":["mistral-large"]}'); expected='model family unknown' ;;
      wrong-head) review_head=2222222222222222222222222222222222222222; expected='head mismatch' ;;
      fail) args=(--verdict FAIL); expected='verdict is FAIL' ;;
    esac
    if [ "$scenario" != independent ]; then
      record_review "$case_dir" "$url" "$review_head" --loosens-deny-allow-list yes \
        --widens-guard yes --customer-data-billing-spend yes "${args[@]}" >/dev/null \
        || fail "record newest $scenario review"
    fi
    rc=0
    review_record_command "$case_dir" verify --pr "$url" --head "$head" > "$case_dir/out" 2>&1 || rc=$?
    if [ "$scenario" = independent ]; then
      expect_code 0 "$rc" "yes-trigger independent PASS must verify: $(cat "$case_dir/out")"
      assert_grep 'review: PASS' "$case_dir/out" "independent evidence is accepted without captain words"
      review_record_command "$case_dir" latest --pr "$url" > "$case_dir/latest" || fail "read yes-trigger evidence"
      "$JQ_BIN" -e '.review.loosens_deny_allow_list == "yes" and .review.widens_guard == "yes"
        and .review.customer_data_billing_spend == "yes" and .["captain-word"] == null' \
        "$case_dir/latest" >/dev/null || fail "latest must print all yes triggers without captain words"
    else
      expect_code 1 "$rc" "newest $scenario review must still refuse"
      assert_grep "$expected" "$case_dir/out" "$scenario refusal must name its cause"
    fi
    pass "yes-trigger review verification: $scenario"
  done
}

test_captain_fail_triggered_independent_pass_merges() {
  local case_dir head url trigger rc
  head=1111111111111111111111111111111111111111
  url=https://github.com/example/repo/pull/9
  for trigger in loosens-deny-allow-list widens-guard customer-data-billing-spend; do
    case_dir=$(make_case "captain-fail-pass-$trigger")
    : > "$case_dir/explicit-review"
    add_gh_mocks "$case_dir" "$head"
    review_record_command "$case_dir" captain-word --pr "$url" --head "$head" --words 'Merge this PR.' >/dev/null \
      || fail "could not record the original captain-word"
    record_review "$case_dir" "$url" "$head" --verdict FAIL >/dev/null || fail "could not record FAIL"
    record_review "$case_dir" "$url" "$head" "--$trigger" yes >/dev/null || fail "could not record triggered PASS"
    rc=0
    run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "captain-word, FAIL, independent PASS covering the FAIL's groups with $trigger=yes must merge: $(cat "$case_dir/stderr")"
    assert_logged_gh_merge "$case_dir" 9 example/repo --squash
    pass "an independent $trigger PASS covering every FAIL group clears it without renewed captain words"
  done
}

test_review_record_requires_matching_local_report() {
  local case_dir head url bad rc digest
  head=1111111111111111111111111111111111111111
  url=https://github.com/example/repo/pull/9
  for bad in missing symlink verdict head directory unreadable trailing-space; do
    case_dir=$(make_case "review-report-$bad")
    record_review "$case_dir" "$url" "$head" >/dev/null || fail "could not seed report validation history"
    cp "$case_dir/state/review-records.jsonl" "$case_dir/before"
    printf 'VERDICT: PASS head=%s\nReader evidence.\n' "$head" > "$case_dir/report.md"
    case "$bad" in
      missing) rm "$case_dir/report.md" ;;
      symlink) mv "$case_dir/report.md" "$case_dir/target.md"; ln -s "$case_dir/target.md" "$case_dir/report.md" ;;
      verdict) printf 'VERDICT: FAIL head=%s\n' "$head" > "$case_dir/report.md" ;;
      head) printf 'VERDICT: PASS head=%s\n' 2222222222222222222222222222222222222222 > "$case_dir/report.md" ;;
      directory) rm "$case_dir/report.md"; mkdir "$case_dir/report.md" ;;
      unreadable) chmod 000 "$case_dir/report.md" ;;
      trailing-space) printf 'VERDICT: PASS head=%s \n' "$head" > "$case_dir/report.md" ;;
    esac
    rc=0
    record_review "$case_dir" "$url" "$head" --report "$case_dir/report.md" > "$case_dir/out" 2>&1 || rc=$?
    [ "$bad" != unreadable ] || chmod 600 "$case_dir/report.md"
    expect_code 2 "$rc" "$bad report must refuse"
    assert_grep report "$case_dir/out" "$bad report refusal must identify report"
    cmp -s "$case_dir/before" "$case_dir/state/review-records.jsonl" || fail "$bad report changed history"
    pass "review recording refuses $bad report with exit 2 and appends nothing"
  done
  case_dir=$(make_case review-report-digest)
  printf 'VERDICT: PASS head=%s\nIndependent reader evidence.\n' "$head" > "$case_dir/report.md"
  digest=$(shasum -a 256 "$case_dir/report.md")
  digest=${digest%% *}
  record_review "$case_dir" "$url" "$head" --report "$case_dir/report.md" >/dev/null || fail "matching report must record"
  review_record_command "$case_dir" latest --pr "$url" > "$case_dir/latest" || fail "could not read report provenance"
  "$JQ_BIN" -e --arg digest "$digest" --arg report "$case_dir/report.md" \
    ".review | .report == \$report and .report_sha256 == \$digest" "$case_dir/latest" >/dev/null \
    || fail "record must retain report path and exact whole-file sha256"
  printf 'VERDICT: FAIL head=%s\nNew reader finding.\n' "$head" > "$case_dir/report.md"
  record_review "$case_dir" "$url" "$head" --verdict FAIL --report "$case_dir/report.md" >/dev/null \
    || fail "matching FAIL report must record"
  rc=0
  review_record_command "$case_dir" verify --pr "$url" --head "$head" > "$case_dir/out" 2>&1 || rc=$?
  expect_code 1 "$rc" "recorded FAIL must refuse verification"
  assert_grep 'verdict is FAIL' "$case_dir/out" "FAIL report must affect merge evidence"
  pass "matching local reports record whole-file sha256 and a matching FAIL blocks verification"
}

test_late_fail_before_away_hold_refuses() {
  local case_dir forge head url rc
  for forge in github gitlab forgejo; do
    case "$forge" in
      github)
        case_dir=$(make_case late-fail-github)
        head=1111111111111111111111111111111111111111
        url=https://github.com/example/repo/pull/9
        add_gh_mocks "$case_dir" "$head" ;;
      gitlab) case_dir=$(make_gitlab_case late-fail-gitlab); head=$MR_HEAD; url=$MR_URL ;;
      forgejo) case_dir=$(make_forgejo_case late-fail-forgejo); head=$FJ_HEAD; url=$FJ_URL ;;
    esac
    : > "$case_dir/explicit-review"
    record_review "$case_dir" "$url" "$head" >/dev/null || fail "$forge could not record initial PASS"
    review_record_command "$case_dir" verify --pr "$url" --head "$head" > "$case_dir/earlier-verify" \
      || fail "$forge initial PASS must verify"
    assert_grep 'review: PASS' "$case_dir/earlier-verify" "$forge must have earlier accepted evidence"
    printf 'VERDICT: FAIL head=%s\nLate independent finding.\n' "$head" > "$case_dir/late-fail.md"
    : > "$case_dir/late-fail-pending"
    # Publish a real FAIL exactly when the merge enters the away-record hold,
    # after any review verification outside that hold, without a timing sleep.
    cat > "$case_dir/fakebin/ln" <<'SH'
#!/usr/bin/env bash
for target in "$@"; do
  if [ "$target" = "$FM_STATE_OVERRIDE/.afk-contract.lock" ] && [ -e "$FM_TEST_REVIEW_RACE_DIR/late-fail-pending" ]; then
    rm "$FM_TEST_REVIEW_RACE_DIR/late-fail-pending" || exit 10
    "$FM_TEST_ROOT/bin/fm-review-record.py" review --pr "$FM_TEST_REVIEW_RACE_URL" --head "$FM_TEST_REVIEW_RACE_HEAD" \
      --verdict FAIL --reader-model claude-opus-5-5 --author-groups '{"all":["gpt-5.1-codex"]}' \
      --loosens-deny-allow-list no --widens-guard no --customer-data-billing-spend no \
      --report "$FM_TEST_REVIEW_RACE_DIR/late-fail.md" > "$FM_TEST_REVIEW_RACE_DIR/late-fail-out" || exit 11
  fi
done
exec "$FM_TEST_REAL_LN" "$@"
SH
    chmod +x "$case_dir/fakebin/ln"
    rc=0
    FM_TEST_REVIEW_RACE_DIR="$case_dir" FM_TEST_REVIEW_RACE_URL="$url" FM_TEST_REVIEW_RACE_HEAD="$head" \
      FM_TEST_REAL_LN="$(command -v ln)" run_pr_merge "$case_dir" task-x1 "$url" \
      > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    [ ! -e "$case_dir/late-fail-pending" ] || fail "$forge did not reach the injection boundary"
    assert_grep 'recorded: review' "$case_dir/late-fail-out" "$forge must append the late FAIL"
    expect_code 1 "$rc" "$forge must refuse FAIL appended after earlier verification"
    assert_grep 'verdict is FAIL' "$case_dir/stderr" "$forge must recheck late review evidence"
    assert_no_grep '^pr merge ' "$case_dir/gh.log" "$forge must not call GitHub merge"
    case "$forge" in
      gitlab) [ -z "$(glab_merge_line "$case_dir/glab.log")" ] || fail "late FAIL reached GitLab merge" ;;
      forgejo) [ -z "$(tea_merge_line "$case_dir/tea.log")" ] || fail "late FAIL reached Forgejo merge" ;;
    esac
    pass "$forge refuses a FAIL appended after earlier verify and before the merge hold"
  done
}

test_attended_override_without_review_refuses() {
  local case_dir forge url rc
  for forge in github gitlab forgejo; do
    case "$forge" in
      github)
        case_dir=$(make_case override-no-review-github)
        url=https://github.com/example/repo/pull/9
        add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111 ;;
      gitlab) case_dir=$(make_gitlab_case override-no-review-gitlab); url=$MR_URL ;;
      forgejo) case_dir=$(make_forgejo_case override-no-review-forgejo); url=$FJ_URL ;;
    esac
    : > "$case_dir/explicit-review"
    rc=0
    run_pr_merge "$case_dir" task-x1 "$url" --attended-override \
      > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "$forge attended override must not bypass missing review evidence"
    assert_grep 'review record is missing' "$case_dir/stderr" "$forge attended override must reach the review gate"
    [ ! -e "$case_dir/state/review-records.jsonl" ] || fail "$forge override unexpectedly recorded evidence"
    assert_no_grep '^pr merge ' "$case_dir/gh.log" "$forge override must not call GitHub merge"
    case "$forge" in
      gitlab) [ -z "$(glab_merge_line "$case_dir/glab.log")" ] || fail "attended override reached GitLab merge" ;;
      forgejo) [ -z "$(tea_merge_line "$case_dir/tea.log")" ] || fail "attended override reached Forgejo merge" ;;
    esac
    pass "$forge attended override cannot merge without recorded review evidence"
  done
}

test_missing_review_record_refuses() {
  local case_dir rc
  case_dir=$(make_case missing-review-record)
  : > "$case_dir/explicit-review"
  add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111
  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "missing review record must refuse"
  assert_grep 'review record' "$case_dir/stderr" "missing review refusal names the field"
  assert_no_grep '^pr merge ' "$case_dir/gh.log" "missing review must not reach forge merge"
  pass "missing review record refuses before forge merge"
}

test_gitlab_and_forgejo_missing_review_record_refuse() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-missing-review-record)
  : > "$case_dir/explicit-review"
  rc=0
  run_pr_merge "$case_dir" task-x1 "$MR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "gitlab missing review record must refuse"
  assert_grep 'review record is missing' "$case_dir/stderr" "gitlab missing review refusal names the field"
  assert_grep 'fm-review-record.py' "$case_dir/stderr" "gitlab missing review refusal names completing step"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] || fail "gitlab missing review must not reach glab mr merge"
  case_dir=$(make_forgejo_case forgejo-missing-review-record)
  : > "$case_dir/explicit-review"
  rc=0
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "forgejo missing review record must refuse"
  assert_grep 'review record is missing' "$case_dir/stderr" "forgejo missing review refusal names the field"
  assert_grep 'fm-review-record.py' "$case_dir/stderr" "forgejo missing review refusal names completing step"
  [ -z "$(tea_merge_line "$case_dir/tea.log")" ] || fail "forgejo missing review must not POST the merge"
  pass "gitlab and forgejo refuse a missing review record before their forge merge"
}

test_captain_word_refused_while_away() {
  local case_dir head url rc posture
  head=1111111111111111111111111111111111111111
  url=https://github.com/example/repo/pull/9
  for posture in away quiet none; do
    case_dir=$(make_case "captain-word-$posture")
    case "$posture" in
      away) write_away_record "$case_dir" --words 'merge PR 9 when green' ;;
      quiet) FM_AFK_MODE=quiet write_away_record "$case_dir" ;;
    esac
    rc=0
    review_record_command "$case_dir" captain-word --pr "$url" --head "$head" --words 'merge PR 9 when green' \
      > "$case_dir/out" 2>&1 || rc=$?
    if [ "$posture" = away ]; then
      expect_code 2 "$rc" "captain-word must refuse under an away record"
      assert_grep "away-posture record $case_dir/state/.afk-contract exists" "$case_dir/out" "away refusal names the record"
      assert_grep 'the captain must give the merge word after return' "$case_dir/out" "away refusal names the return"
      [ ! -e "$case_dir/state/review-records.jsonl" ] || fail "an away refusal must not append a captain-word"
    else
      expect_code 0 "$rc" "captain-word must record under posture $posture: $(cat "$case_dir/out")"
      review_record_command "$case_dir" verify --pr "$url" --head "$head" > "$case_dir/verify" \
        || fail "captain-word recorded under posture $posture must verify: $(cat "$case_dir/verify")"
      assert_grep 'review: captain-word' "$case_dir/verify" "posture $posture captain-word verifies"
    fi
  done
  case_dir=$(make_case captain-word-before-away)
  : > "$case_dir/explicit-review"
  add_gh_mocks "$case_dir" "$head"
  printf '\nyolo=on\n' >> "$case_dir/state/task-x1.meta"
  review_record_command "$case_dir" captain-word --pr "$url" --head "$head" --words 'Merge PR 9.' >/dev/null \
    || fail "captain-word before /afk must record"
  write_away_record "$case_dir" --words 'merge PR 9 when green'
  rc=0
  run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "a captain-word recorded before /afk must still verify while away: $(cat "$case_dir/stderr")"
  assert_grep 'review: captain-word' "$case_dir/stderr" "pre-away captain-word is the verified evidence"
  assert_logged_gh_merge "$case_dir" 9 example/repo --squash
  pass "captain-word refuses under an away record, records under quiet or no record, and pre-away words stay valid"
}

test_review_record_validation_and_latest() {
  local case_dir head url rc bad
  case_dir=$(make_case review-record-fields)
  head=1111111111111111111111111111111111111111
  url=https://github.com/example/repo/pull/9
  for bad in missing-report invalid-verdict invalid-url empty-words empty-groups blank-reader blank-author captain-head; do
    rc=0
    case "$bad" in
      missing-report) record_review "$case_dir" "$url" "$head" --report '' > "$case_dir/out" 2>&1 || rc=$? ;;
      invalid-verdict) record_review "$case_dir" "$url" "$head" --verdict MAYBE > "$case_dir/out" 2>&1 || rc=$? ;;
      invalid-url) record_review "$case_dir" nonsense "$head" > "$case_dir/out" 2>&1 || rc=$? ;;
      empty-words) review_record_command "$case_dir" captain-word --pr "$url" --head "$head" --words '' > "$case_dir/out" 2>&1 || rc=$? ;;
      empty-groups) record_review "$case_dir" "$url" "$head" --author-groups '{}' > "$case_dir/out" 2>&1 || rc=$? ;;
      blank-reader) record_review "$case_dir" "$url" "$head" --reader-model '' > "$case_dir/out" 2>&1 || rc=$? ;;
      blank-author) record_review "$case_dir" "$url" "$head" --author-groups '{"all":["gpt 5"]}' > "$case_dir/out" 2>&1 || rc=$? ;;
      captain-head) review_record_command "$case_dir" captain-word --pr "$url" --head main --words 'Merge it.' > "$case_dir/out" 2>&1 || rc=$? ;;
    esac
    expect_code 2 "$rc" "$bad must refuse invalid field"
    case "$bad" in
      missing-report) assert_grep report "$case_dir/out" "invalid report named" ;;
      invalid-verdict) assert_grep verdict "$case_dir/out" "invalid verdict named" ;;
      invalid-url) assert_grep pr "$case_dir/out" "invalid PR named" ;;
      empty-words) assert_grep words "$case_dir/out" "empty words named" ;;
      empty-groups) assert_grep author_groups "$case_dir/out" "empty authors named" ;;
      blank-reader) assert_grep 'reader_model must be an exact model id' "$case_dir/out" "blank reader model named" ;;
      blank-author) assert_grep 'author_groups model must be an exact model id' "$case_dir/out" "invalid author model named" ;;
      captain-head) assert_grep head "$case_dir/out" "captain-word head named" ;;
    esac
  done
  [ ! -e "$case_dir/state/review-records.jsonl" ] || fail "refused input must not append a record"
  rc=0
  FM_HOME="$case_dir/no-such-home" "$ROOT/bin/fm-review-record.py" captain-word --pr "$url" --head "$head" \
    --words 'Merge it.' > "$case_dir/out" 2>&1 || rc=$?
  expect_code 2 "$rc" "a missing home must refuse the write"
  assert_grep 'does not exist' "$case_dir/out" "missing home named"
  [ ! -e "$case_dir/no-such-home" ] || fail "a missing home must not be created"
  record_review "$case_dir" "$url" "$head" --verdict FAIL > /dev/null || fail "record FAIL"
  cp "$case_dir/state/review-records.jsonl" "$case_dir/first-record"
  record_review "$case_dir" "$url" "$head" --reader-model Claude-Sonnet-5-5 \
    --author-groups '{"initial":["openai-codex/gpt-5.1-codex"],"fixes":["Gemini-3-Pro","o3"]}' > /dev/null || fail "record grouped PASS"
  review_record_command "$case_dir" latest --pr "$url" > "$case_dir/latest" || fail "read newest record"
  # shellcheck disable=SC2016  # jq program; single quotes are intended.
  "$JQ_BIN" -e --arg pr "$url" --arg head "$head" --arg report "$case_dir/review.md" '
    .review | .pr == $pr and .head == $head and .verdict == "PASS"
    and .reader_model == "Claude-Sonnet-5-5" and .reader_family == "anthropic"
    and .author_groups == {initial:[{model:"openai-codex/gpt-5.1-codex",family:"openai"}],
      fixes:[{model:"Gemini-3-Pro",family:"google"},{model:"o3",family:"openai"}]}
    and .loosens_deny_allow_list == "no" and .widens_guard == "no"
    and .customer_data_billing_spend == "no" and .report == $report' "$case_dir/latest" >/dev/null \
    || fail "latest must preserve all review fields and groups"
  "$JQ_BIN" -sce 'length == 2 and .[0].verdict == "FAIL" and .[1].verdict == "PASS"' \
    "$case_dir/state/review-records.jsonl" >/dev/null || fail "review history must remain append-only"
  IFS= read -r bad < "$case_dir/state/review-records.jsonl"
  printf '%s\n' "$bad" > "$case_dir/retained-first"
  cmp -s "$case_dir/first-record" "$case_dir/retained-first" || fail "append changed existing bytes"
  pass "review helper validates fields, retains history, and returns newest canonical grouped evidence"
}

test_review_record_derives_model_families() {
  local case_dir head url
  case_dir=$(make_case review-model-families)
  head=1111111111111111111111111111111111111111
  url=https://github.com/example/repo/pull/9
  record_review "$case_dir" "$url" "$head" --reader-model openrouter/x-ai/grok-4 --author-groups '{
    "a":["claude-opus-5-5[1m]","anthropic/claude-haiku-5-5"],"o":["gpt-5.1-codex","chatgpt-4o","o4-mini","codex-mini"],
    "g":["gemini-3-pro","gemma-3"],"d":["deepseek-v4"],"m":["kimi-k2","moonshot-v1"],"l":["llama-4-maverick"],
    "u":["mistral-large","mystery-9"]}' > /dev/null || fail "record every family"
  review_record_command "$case_dir" latest --pr "$url" > "$case_dir/latest" || fail "read derived families"
  "$JQ_BIN" -e '.review | .reader_family == "xai" and (.author_groups | map_values(map(.family))) ==
    {a:["anthropic","anthropic"],o:["openai","openai","openai","openai"],g:["google","google"],
     d:["deepseek"],m:["moonshot","moonshot"],l:["meta"],u:["unknown","unknown"]}' "$case_dir/latest" >/dev/null \
    || fail "model ids must derive their closed-set family, with unknown otherwise: $(cat "$case_dir/latest")"
  pass "review helper derives each family from the exact model id and records unknown otherwise"
}

test_review_record_survives_a_later_family_change() {
  local case_dir head url rc
  case_dir=$(make_case review-family-added-later)
  : > "$case_dir/explicit-review"
  head=1111111111111111111111111111111111111111
  url=https://github.com/example/repo/pull/9
  add_gh_mocks "$case_dir" "$head"
  printf '\nmodel=kimi-k2\n' >> "$case_dir/state/task-x1.meta"
  record_review "$case_dir" "$url" "$head" --author-groups '{"all":["kimi-k2"]}' >/dev/null || fail "record kimi-authored PASS"
  record_review "$case_dir" https://github.com/example/repo/pull/10 "$head" >/dev/null || fail "record another PR's PASS"
  # Rows written before moonshot joined the closed set stored kimi as unknown.
  "$JQ_BIN" -c 'if .pr | endswith("/pull/9") then .author_groups.all[0].family = "unknown" else . end' \
    "$case_dir/state/review-records.jsonl" > "$case_dir/older-ledger" || fail "could not write the older ledger"
  mv "$case_dir/older-ledger" "$case_dir/state/review-records.jsonl"
  review_record_command "$case_dir" latest --pr https://github.com/example/repo/pull/10 > "$case_dir/latest" \
    || fail "a row stored under an older family set must stay valid: $(cat "$case_dir/latest")"
  rc=0
  run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "a family added after the row was stored must let the merge proceed: $(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 9 example/repo --squash
  "$JQ_BIN" -se '.[0].author_groups.all[0].family == "unknown"' "$case_dir/state/review-records.jsonl" >/dev/null \
    || fail "verify must not rewrite stored history"
  pass "a family added after a row was stored leaves the row valid and verify derives the current family"
}

test_recorded_review_merge_conditions() {
  local case_dir head url scenario rc expected
  head=1111111111111111111111111111111111111111
  url=https://github.com/example/repo/pull/9
  for scenario in stale same-family same-family-model cross-family-model unknown-reader unknown-author-captain fail trigger-list trigger-guard trigger-data other-pr stale-captain-word captain-word captain-only stale-captain-only valid newest-fail captain-then-fail captain-fail-stale-pass captain-fail-stale-fail captain-fail-unknown-pass captain-fail-same-family-pass fail-then-captain captain-fail-pass; do
    case_dir=$(make_case "review-$scenario")
    : > "$case_dir/explicit-review"
    add_gh_mocks "$case_dir" "$head"
    case "$scenario" in
      stale) record_review "$case_dir" "$url" 2222222222222222222222222222222222222222 >/dev/null; expected='head mismatch' ;;
      same-family) record_review "$case_dir" "$url" "$head" --author-groups '{"initial":["gpt-5.1-codex"],"fixes":["claude-opus-5-5"]}' >/dev/null; expected=reader_family ;;
      same-family-model) record_review "$case_dir" "$url" "$head" --reader-model claude-sonnet-5-5 --author-groups '{"all":["claude-bridge/claude-opus-5-5"]}' >/dev/null; expected='uncovered commit group' ;;
      cross-family-model)
        printf '\nmodel=kimi-k2\n' >> "$case_dir/state/task-x1.meta"
        record_review "$case_dir" "$url" "$head" --author-groups '{"all":["kimi-k2"]}' >/dev/null ;;
      unknown-reader) record_review "$case_dir" "$url" "$head" --reader-model mistral-large >/dev/null; expected='model family unknown for newest reader mistral-large' ;;
      unknown-author-captain)
        record_review "$case_dir" "$url" "$head" --author-groups '{"all":["mistral-large"]}' >/dev/null
        review_record_command "$case_dir" captain-word --pr "$url" --head "$head" --words 'Merge PR 9 despite the unknown author family.' >/dev/null ;;
      fail) record_review "$case_dir" "$url" "$head" --verdict FAIL >/dev/null; expected=verdict ;;
      newest-fail)
        record_review "$case_dir" "$url" "$head" >/dev/null
        record_review "$case_dir" "$url" "$head" --verdict FAIL >/dev/null; expected=verdict ;;
      trigger-list) record_review "$case_dir" "$url" "$head" --loosens-deny-allow-list yes >/dev/null ;;
      trigger-guard) record_review "$case_dir" "$url" "$head" --widens-guard yes >/dev/null ;;
      trigger-data) record_review "$case_dir" "$url" "$head" --customer-data-billing-spend yes >/dev/null ;;
      other-pr|stale-captain-word|captain-word)
        record_review "$case_dir" "$url" "$head" --customer-data-billing-spend yes \
          --reader-model gpt-5.1-codex >/dev/null
        expected=reader_family
        if [ "$scenario" = other-pr ]; then
          review_record_command "$case_dir" captain-word --pr https://github.com/example/repo/pull/10 --head "$head" --words 'Merge this PR.' >/dev/null
        elif [ "$scenario" = stale-captain-word ]; then
          review_record_command "$case_dir" captain-word --pr "$url" --head 2222222222222222222222222222222222222222 --words 'Merge this PR.' >/dev/null
        elif [ "$scenario" = captain-word ]; then
          review_record_command "$case_dir" captain-word --pr "$url" --head "$head" --words 'Merge this PR despite the spend trigger.' >/dev/null
          review_record_command "$case_dir" latest --pr "$url" > "$case_dir/latest"
          "$JQ_BIN" -e '.["captain-word"].words == "Merge this PR despite the spend trigger."' "$case_dir/latest" >/dev/null \
            || fail "captain exact words not preserved"
        fi ;;
      captain-only) review_record_command "$case_dir" captain-word --pr "$url" --head "$head" --words 'Merge the approved pull request.' >/dev/null ;;
      stale-captain-only)
        review_record_command "$case_dir" captain-word --pr "$url" --head 2222222222222222222222222222222222222222 --words 'Merge the approved pull request.' >/dev/null
        expected='review record is missing' ;;
      valid) record_review "$case_dir" "$url" "$head" >/dev/null ;;
      captain-then-fail|captain-fail-stale-pass|captain-fail-stale-fail|captain-fail-unknown-pass|captain-fail-same-family-pass)
        review_record_command "$case_dir" captain-word --pr "$url" --head "$head" --words 'Merge PR 9.' >/dev/null
        record_review "$case_dir" "$url" "$head" --verdict FAIL >/dev/null
        expected='verdict is FAIL at live head' ;;
      fail-then-captain)
        record_review "$case_dir" "$url" "$head" --verdict FAIL >/dev/null
        review_record_command "$case_dir" captain-word --pr "$url" --head "$head" --words 'Merge PR 9 despite the FAIL.' >/dev/null ;;
      captain-fail-pass)
        review_record_command "$case_dir" captain-word --pr "$url" --head "$head" --words 'Merge PR 9.' >/dev/null
        record_review "$case_dir" "$url" "$head" --verdict FAIL >/dev/null
        record_review "$case_dir" "$url" "$head" >/dev/null ;;
    esac
    case "$scenario" in
      captain-fail-stale-pass) record_review "$case_dir" "$url" 2222222222222222222222222222222222222222 >/dev/null ;;
      captain-fail-stale-fail) record_review "$case_dir" "$url" 2222222222222222222222222222222222222222 --verdict FAIL >/dev/null ;;
      captain-fail-unknown-pass) record_review "$case_dir" "$url" "$head" --reader-model mistral-large >/dev/null ;;
      captain-fail-same-family-pass) record_review "$case_dir" "$url" "$head" --reader-model claude-sonnet-5-5 --author-groups '{"all":["claude-opus-5-5"]}' >/dev/null ;;
    esac
    rc=0
    run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    case "$scenario" in
      valid|trigger-list|trigger-guard|trigger-data|captain-word|captain-only|cross-family-model|unknown-author-captain|fail-then-captain|captain-fail-pass)
        expect_code 0 "$rc" "$scenario must merge"
        assert_logged_gh_merge "$case_dir" 9 example/repo --squash ;;
      *)
        expect_code 1 "$rc" "$scenario must refuse"
        assert_grep "$expected" "$case_dir/stderr" "$scenario refusal names field"
        assert_grep 'fm-review-record.py' "$case_dir/stderr" "$scenario refusal names completing step"
        assert_no_grep '^pr merge ' "$case_dir/gh.log" "$scenario must never call merge" ;;
    esac
    pass "recorded review merge condition: $scenario"
  done
}

test_github_zero_exit_queue_required_refuses_with_exact_retry() {
  local case_dir rc
  case_dir=$(make_case github-zero-exit-queue-required)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2121212121212121212121212121212121212121
  write_github_outcome "$case_dir" OPEN false false 'release/2026'
  printf 'merge_method=REBASE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/56 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "github-zero-exit-queue-required: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not name the concrete observed state"
  assert_grep 'base branch release/2026 requires the merge queue' "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not name the queue requirement"
  assert_grep '--attended-override -- --auto --rebase' "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not name the exact compatible flags"
  assert_grep 'api --paginate repos/example/repo/rules/branches/release%2F2026' "$case_dir/gh.log" \
    "github-zero-exit-queue-required: queue rules were not read with pagination and encoded branch path"
  assert_logged_gh_merge "$case_dir" 56 example/repo --squash
  [ "$(grep -c '^pr merge ' "$case_dir/gh.log")" -eq 1 ] \
    || fail "github-zero-exit-queue-required: the wrapper attempted more than one merge"
  assert_no_grep --auto "$case_dir/gh.log" \
    "github-zero-exit-queue-required: queue flags were auto-applied to the attempted merge"
  assert_grep 'pr=https://github.com/example/repo/pull/56' "$case_dir/state/task-x1.meta" \
    "github-zero-exit-queue-required: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-zero-exit-queue-required: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge reports exact queue retry flags after a zero-exit false success"
}

test_github_closed_unqueued_outcome_omits_retry_flags() {
  local case_dir rc
  case_dir=$(make_case github-closed-unqueued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2323232323232323232323232323232323232323
  write_github_outcome "$case_dir" CLOSED false false master
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/57 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "github-closed-unqueued: an unproved merge must fail"
  assert_grep 'state=CLOSED, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-closed-unqueued: refusal did not name the concrete observed state"
  assert_no_grep 'requires the merge queue' "$case_dir/stderr" \
    "github-closed-unqueued: closed PR received unusable queue guidance"
  assert_no_grep '--attended-override -- --auto --merge' "$case_dir/stderr" \
    "github-closed-unqueued: closed PR received retry flags"
  assert_grep 'pr=https://github.com/example/repo/pull/57' "$case_dir/state/task-x1.meta" \
    "github-closed-unqueued: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-closed-unqueued: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge omits merge-queue retry guidance for a closed GitHub PR"
}

test_github_agreeing_queue_rules_keep_retry_guidance() {
  local case_dir rc
  case_dir=$(make_case github-agreeing-queue-rules)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2424242424242424242424242424242424242424
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=REBASE\nmerge_method=REBASE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/58 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "github-agreeing-queue-rules: an unproved merge must fail"
  assert_grep 'base branch main requires the merge queue' "$case_dir/stderr" \
    "github-agreeing-queue-rules: refusal did not name the queue requirement"
  assert_grep '--attended-override -- --auto --rebase' "$case_dir/stderr" \
    "github-agreeing-queue-rules: agreeing rules omitted exact retry flags"
  assert_no_grep 'exact retry flags are ambiguous' "$case_dir/stderr" \
    "github-agreeing-queue-rules: agreeing rules were reported as ambiguous"
  pass "fm-pr-merge aggregates agreeing merge-queue rules"
}

test_github_conflicting_queue_rules_report_ambiguity() {
  local case_dir rc
  case_dir=$(make_case github-conflicting-queue-rules)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2525252525252525252525252525252525252525
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=MERGE\nmerge_method=SQUASH\nmerge_method=SQUASH\n' \
    > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/59 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "github-conflicting-queue-rules: an unproved merge must fail"
  assert_grep 'base branch main has conflicting merge queue methods (MERGE, SQUASH)' \
    "$case_dir/stderr" \
    "github-conflicting-queue-rules: conflicting methods were not named"
  assert_no_grep '--attended-override -- --auto --merge' "$case_dir/stderr" \
    "github-conflicting-queue-rules: an exact retry method was guessed"
  assert_no_grep '--attended-override -- --auto --squash' "$case_dir/stderr" \
    "github-conflicting-queue-rules: an exact retry method was guessed"
  assert_no_grep 'SQUASH, SQUASH' "$case_dir/stderr" \
    "github-conflicting-queue-rules: a repeated queue method was named twice"
  pass "fm-pr-merge reports ambiguity for conflicting merge-queue rules"
}

test_verified_merge_records_pr_and_head() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  assert_logged_gh_merge "$case_dir" 9 example/repo --squash
  pass "fm-pr-merge records pr= and pr_head= for a verified GitHub merge"
}

# The forge call is the point of no return: once gh-axi has merged, nothing this
# script does afterwards can un-merge it. Proving pr= is already in the task's
# meta at that moment is what makes a later failure unable to lose the merge.
test_pr_metadata_is_recorded_before_the_forge_call() {
  local case_dir rc
  case_dir=$(make_case records-ahead-of-forge-call)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5151515151515151515151515151515151515151
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/meta-at-merge"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/62 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "records-ahead-of-forge-call: fm-pr-merge should succeed"
  assert_logged_gh_merge "$case_dir" 62 example/repo --squash
  assert_grep 'pr=https://github.com/example/repo/pull/62' "$case_dir/meta-at-merge" \
    "records-ahead-of-forge-call: the merge ran before pr= was recorded"
  pass "fm-pr-merge records pr= before the forge call can land the merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_github_open_unqueued_outcome_refuses() {
  local case_dir rc
  case_dir=$(make_case github-open-unqueued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2020202020202020202020202020202020202020
  write_github_outcome "$case_dir" OPEN false false master
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/52 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "github-open-unqueued: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-open-unqueued: refusal did not name the concrete observed state"
  assert_grep 'pr=https://github.com/example/repo/pull/52' "$case_dir/state/task-x1.meta" \
    "github-open-unqueued: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-open-unqueued: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge refuses a GitHub merge call that leaves the PR open and unqueued"
}

# GitHub reports mergeable=UNKNOWN for a short while after a push or a base
# branch change while it recomputes mergeability. When that is the only
# failing condition, the gate re-reads and re-checks every live condition on
# a bounded retry instead of refusing a pull request that is simply pending.
test_github_mergeable_unknown_retries_then_succeeds() {
  local case_dir rc head
  head=4242424242424242424242424242424242424242
  case_dir=$(make_case github-mergeable-unknown-then-mergeable)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  printf '%s\n' UNKNOWN MERGEABLE > "$case_dir/mergeable-sequence"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  rc=0
  FM_TEST_GH_MERGEABLE_SEQUENCE="$case_dir/mergeable-sequence" \
  FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=0 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/83 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "github-mergeable-unknown-then-mergeable: a merge should succeed once mergeable resolves"
  [ "$(grep -c '^pr view .*mergeStateStatus' "$case_dir/gh.log")" -eq 2 ] \
    || fail "github-mergeable-unknown-then-mergeable: expected exactly 2 mergeable reads, got $(grep -c '^pr view .*mergeStateStatus' "$case_dir/gh.log")"
  assert_logged_gh_merge "$case_dir" 83 example/repo --squash
  [ "$(grep -c '^pr merge ' "$case_dir/gh.log")" -eq 1 ] \
    || fail "github-mergeable-unknown-then-mergeable: the wrapper attempted more than one merge"
  assert_grep 'pr=https://github.com/example/repo/pull/83' "$case_dir/state/task-x1.meta" \
    "github-mergeable-unknown-then-mergeable: pr= was not recorded"
  pass "fm-pr-merge retries a bounded number of times when mergeable is UNKNOWN and merges once it resolves"
}

# Every attempt still reads mergeable=UNKNOWN: the bound is spent and the gate
# reports mergeability as still pending rather than calling the pull request
# unmergeable, never attempting a merge on an unresolved read.
test_github_mergeable_unknown_exhausts_bound_and_reports_pending() {
  local case_dir rc head
  head=4343434343434343434343434343434343434343
  case_dir=$(make_case github-mergeable-unknown-exhausted)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  printf '%s\n' UNKNOWN > "$case_dir/mergeable-sequence"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  rc=0
  FM_TEST_GH_MERGEABLE_SEQUENCE="$case_dir/mergeable-sequence" \
  FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=0 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/84 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "github-mergeable-unknown-exhausted: a mergeable read that never resolves must still fail"
  [ "$(grep -c '^pr view .*mergeStateStatus' "$case_dir/gh.log")" -eq 5 ] \
    || fail "github-mergeable-unknown-exhausted: expected exactly 5 bounded mergeable reads, got $(grep -c '^pr view .*mergeStateStatus' "$case_dir/gh.log")"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-mergeable-unknown-exhausted: a merge was attempted while mergeable never resolved"
  assert_grep "mergeability for https://github.com/example/repo/pull/84 is still being computed by GitHub; retry shortly" \
    "$case_dir/stderr" \
    "github-mergeable-unknown-exhausted: the exhausted retry did not report mergeability as still pending"
  pass "fm-pr-merge reports mergeability still pending after its bounded UNKNOWN retry is spent"
}

# A check that turns red between two UNKNOWN reads must refuse on the re-check:
# the retry re-reads every live condition, not only mergeable.
test_github_mergeable_unknown_retry_rechecks_checks() {
  local case_dir rc head
  head=4545454545454545454545454545454545454545
  case_dir=$(make_case github-mergeable-unknown-check-turns-red)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  printf '%s\n' UNKNOWN 'UNKNOWN FAILURE' > "$case_dir/mergeable-sequence"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  rc=0
  FM_TEST_GH_MERGEABLE_SEQUENCE="$case_dir/mergeable-sequence" \
  FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=0 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/86 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "github-mergeable-unknown-check-turns-red: a check that turned red must refuse"
  [ "$(grep -c '^pr view .*mergeStateStatus' "$case_dir/gh.log")" -eq 2 ] \
    || fail "github-mergeable-unknown-check-turns-red: expected exactly 2 reads, got $(grep -c '^pr view .*mergeStateStatus' "$case_dir/gh.log")"
  assert_grep "check 'ci' is not green" "$case_dir/stderr" \
    "github-mergeable-unknown-check-turns-red: the re-check did not refuse the red check"
  assert_no_grep 'still being computed' "$case_dir/stderr" \
    "github-mergeable-unknown-check-turns-red: a red check was reported as mergeability pending"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-mergeable-unknown-check-turns-red: gh pr merge ran after a check turned red"
  pass "fm-pr-merge refuses on the UNKNOWN re-check when a check turned red between reads"
}

# A real conflict (mergeable=CONFLICTING) is a different condition from GitHub
# still computing mergeability, and must refuse immediately like every other
# refusal, never retried.
test_github_mergeable_conflicting_is_not_retried() {
  local case_dir rc head
  head=4444444444444444444444444444444444444444
  case_dir=$(make_case github-mergeable-conflicting)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  jq -c '.mergeable = "CONFLICTING"' "$case_dir/github-view.json" > "$case_dir/github-view.tmp"
  mv "$case_dir/github-view.tmp" "$case_dir/github-view.json"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/85 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "github-mergeable-conflicting: a genuine conflict must refuse"
  [ "$(grep -c '^pr view .*mergeStateStatus' "$case_dir/gh.log")" -eq 1 ] \
    || fail "github-mergeable-conflicting: a genuine conflict was retried instead of refused immediately"
  assert_grep 'mergeable is "CONFLICTING", not MERGEABLE' "$case_dir/stderr" \
    "github-mergeable-conflicting: the conflict was not named"
  assert_no_grep 'still being computed' "$case_dir/stderr" \
    "github-mergeable-conflicting: a genuine conflict was reported as still being computed"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-mergeable-conflicting: gh pr merge ran on a conflicting PR"
  pass "fm-pr-merge refuses a genuine mergeable conflict immediately, without retrying"
}

test_github_unreadable_outcome_keeps_pr_bookkeeping() {
  local case_dir rc
  case_dir=$(make_case github-outcome-read-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3131313131313131313131313131313131313131
  add_gh_mock_outcome_read_fails "$case_dir" 3131313131313131313131313131313131313131
  add_gh_axi_mock_view_fails "$case_dir"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/57 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "github-outcome-read-fails: an unreadable outcome must fail"
  assert_grep 'could not read the GitHub pull request outcome after the merge attempt' \
    "$case_dir/stderr" "github-outcome-read-fails: the unreadable outcome was not reported"
  assert_grep 'the gh read failed and the gh-axi view could not prove the outcome either' \
    "$case_dir/stderr" "github-outcome-read-fails: the refusal did not name both failed reads"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-outcome-read-fails: an unproved merge was reported as verified"
  # The merge call itself returned success, so the pull request may well have
  # landed. Losing the reference here would leave teardown with nothing to
  # verify against and no merge poll to catch up.
  assert_grep 'pr=https://github.com/example/repo/pull/57' "$case_dir/state/task-x1.meta" \
    "github-outcome-read-fails: a successful merge call lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-outcome-read-fails: no merge poll was armed for a merge that may have landed"
  pass "fm-pr-merge keeps PR bookkeeping when it cannot read a successful merge call's outcome"
}

test_github_refusal_quotes_the_forge_output() {
  local case_dir rc
  case_dir=$(make_case github-refusal-quotes-forge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6161616161616161616161616161616161616161
  printf '%s\n' 'will be added to the merge queue when all requirements are met' \
    > "$case_dir/github-merge-output"
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/65 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "github-refusal-quotes-forge: an unproved merge must fail"
  assert_grep 'error: > will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    "github-refusal-quotes-forge: the forge's own explanation was discarded on the refusal"
  assert_grep "not this script's verdict" "$case_dir/stderr" \
    "github-refusal-quotes-forge: the forge's text was not marked as the forge's own"
  assert_grep 'error: GitHub merge outcome was not successful: state=OPEN, merged=false, isInMergeQueue=false' \
    "$case_dir/stderr" "github-refusal-quotes-forge: the wrapper's own verdict was lost"
  # A forge sentence about the merge queue must never stand on its own line, or
  # it reads as this script's verdict rather than as quoted forge output.
  ! grep -qxF 'will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    || fail "github-refusal-quotes-forge: forge text was emitted as the wrapper's own line"
  assert_no_grep 'will be added to the merge queue' "$case_dir/stdout" \
    "github-refusal-quotes-forge: the forge's unverified report leaked to stdout"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-refusal-quotes-forge: an unproved merge was reported as verified"
  pass "fm-pr-merge refuses with the forge's own output quoted apart from its verdict"
}

test_github_unreadable_outcome_refusal_quotes_the_forge_output() {
  local case_dir rc
  case_dir=$(make_case github-unreadable-outcome-quotes-forge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8787878787878787878787878787878787878787
  printf '%s\n' 'will be added to the merge queue when all requirements are met' \
    > "$case_dir/github-merge-output"
  add_gh_axi_mock_view_fails "$case_dir"
  add_gh_mock_outcome_read_fails "$case_dir" 8787878787878787878787878787878787878787
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "github-unreadable-outcome-quotes-forge: an unreadable outcome must fail"
  assert_grep 'could not read the GitHub pull request outcome after the merge attempt' \
    "$case_dir/stderr" \
    "github-unreadable-outcome-quotes-forge: the unreadable outcome was not reported"
  assert_grep 'error: > will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    "github-unreadable-outcome-quotes-forge: the forge's only evidence was discarded"
  ! grep -qxF 'will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    || fail "github-unreadable-outcome-quotes-forge: forge text was emitted as the wrapper's own line"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-unreadable-outcome-quotes-forge: an unproved merge was reported as verified"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-unreadable-outcome-quotes-forge: the attempted merge lost its merge poll"
  pass "fm-pr-merge quotes the forge output when it cannot read the outcome either"
}

test_github_accepted_queue_flags_do_not_echo_back_the_same_command() {
  local case_dir rc
  case_dir=$(make_case github-accepted-queue-flags)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8181818181818181818181818181818181818181
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/68 --attended-override -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "github-accepted-queue-flags: an unproved merge must still fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-accepted-queue-flags: refusal did not name the concrete observed state"
  assert_grep 'this run refuses even though the request for https://github.com/example/repo/pull/68 was accepted with the exact flags base branch main requires (--auto --merge)' \
    "$case_dir/stderr" \
    "github-accepted-queue-flags: the refusal did not explain that the right flags were already used"
  assert_grep "re-check the pull request's merge queue state" "$case_dir/stderr" \
    "github-accepted-queue-flags: the refusal named no concrete next step"
  assert_no_grep 'retry with:' "$case_dir/stderr" \
    "github-accepted-queue-flags: the refusal echoed back the command that just refused"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-accepted-queue-flags: an unproved merge was reported as verified"
  pass "fm-pr-merge does not echo back queue flags the caller already used"
}

test_github_mismatched_queue_flags_still_name_the_retry() {
  local case_dir rc
  case_dir=$(make_case github-mismatched-queue-flags)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8282828282828282828282828282828282828282
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=REBASE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/69 --attended-override -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "github-mismatched-queue-flags: an unproved merge must still fail"
  assert_grep 'base branch main requires the merge queue; retry with:' "$case_dir/stderr" \
    "github-mismatched-queue-flags: a caller method the queue does not use lost its retry guidance"
  assert_grep '--attended-override -- --auto --rebase' "$case_dir/stderr" \
    "github-mismatched-queue-flags: the exact compatible flags were not named"
  pass "fm-pr-merge still names retry flags when the caller used a different method"
}

test_github_unrecognised_queue_method_still_names_the_queue() {
  local case_dir rc
  case_dir=$(make_case github-unrecognised-queue-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8383838383838383838383838383838383838383
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=FASTFORWARD\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/70 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "github-unrecognised-queue-method: an unproved merge must fail"
  assert_grep 'base branch main requires the merge queue, but its configured merge method (FASTFORWARD) is not one this script recognises' \
    "$case_dir/stderr" \
    "github-unrecognised-queue-method: a readable queue rule produced no queue mention: $(cat "$case_dir/stderr")"
  assert_no_grep 'retry with:' "$case_dir/stderr" \
    "github-unrecognised-queue-method: retry flags were named for a method nothing recognises"
  assert_no_grep '--auto --' "$case_dir/stderr" \
    "github-unrecognised-queue-method: a merge method was guessed for the caller"
  pass "fm-pr-merge names the queue requirement even when its method is unrecognised"
}

test_github_unreadable_queue_rules_are_not_reported_as_no_queue() {
  local case_dir rc
  case_dir=$(make_case github-unreadable-queue-rules)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8484848484848484848484848484848484848484
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/github-rules-fail"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/71 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "github-unreadable-queue-rules: an unproved merge must fail"
  assert_grep 'the branch rules for base branch main could not be read' "$case_dir/stderr" \
    "github-unreadable-queue-rules: an unreadable rules response read like a queue-less base"
  assert_no_grep 'retry with:' "$case_dir/stderr" \
    "github-unreadable-queue-rules: retry flags were named from rules nothing could read"
  pass "fm-pr-merge distinguishes unreadable branch rules from a base with no merge queue"
}

# A repository whose plan does not expose branch rules answers the rules
# endpoint with a 403 whose body is GitHub's own plan-upgrade message, not a
# generic auth or rate-limit failure. That repository cannot have a
# merge_queue rule either, so it must read as no queue rather than unreadable
# - an attended read still fails the merge here only because the queue-aware
# outcome read (api graphql) was never set up for this case, exactly like the
# no-queue-rule case below; the queue read itself is proven by the absence of
# 'merge-queue' wording in the refusal.
test_github_plan_gated_403_reads_as_no_queue() {
  local case_dir rc
  case_dir=$(make_case github-plan-gated-403)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8989898989898989898989898989898989898989
  write_github_outcome "$case_dir" OPEN false false main
  printf 'gh: Upgrade to GitHub Pro or make this repository public to enable this feature (HTTP 403)\n' \
    > "$case_dir/github-rules-fail-body"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/75 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "github-plan-gated-403: an unproved merge must fail"
  assert_no_grep 'merge queue' "$case_dir/stderr" \
    "github-plan-gated-403: a plan-gated 403 was read as an unreadable or present queue rule"
  assert_no_grep 'could not be read' "$case_dir/stderr" \
    "github-plan-gated-403: a plan-gated 403 was reported as an unreadable rules response"
  pass "fm-pr-merge reads a plan-gated 403 on branch rules as no merge queue, not unreadable"
}

test_github_no_queue_rule_says_nothing_about_a_queue() {
  local case_dir rc
  case_dir=$(make_case github-no-queue-rule)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8585858585858585858585858585858585858585
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/72 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "github-no-queue-rule: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-no-queue-rule: refusal did not name the concrete observed state"
  assert_no_grep 'merge queue' "$case_dir/stderr" \
    "github-no-queue-rule: a base with no queue rule was told it requires the merge queue"
  pass "fm-pr-merge says nothing about a merge queue when the base branch has no queue rule"
}

test_github_unmerged_fallback_cannot_replace_queue_aware_read() {
  local case_dir rc
  case_dir=$(make_case github-unmerged-fallback)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8686868686868686868686868686868686868686
  add_gh_mock_outcome_read_fails "$case_dir"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view") printf 'pull_request:\n  number: %s\n  state: open\n' "$3" ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  : > "$case_dir/gh-axi.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/73 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "github-unmerged-fallback: an unproved merge must fail"
  assert_grep 'pr view 73 --repo example/repo' "$case_dir/gh-axi.log" \
    "github-unmerged-fallback: the fallback view was not consulted"
  assert_grep 'the gh read failed and the gh-axi view could not prove the outcome either' \
    "$case_dir/stderr" \
    "github-unmerged-fallback: an unmerged fallback was treated as a readable outcome"
  assert_no_grep 'GitHub merge outcome was not successful' "$case_dir/stderr" \
    "github-unmerged-fallback: an unmerged fallback reached detailed outcome handling"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-unmerged-fallback: an unproved merge was reported as verified"
  pass "fm-pr-merge accepts only a proved merge from the gh-axi fallback"
}

test_github_auto_merge_without_queue_refuses_legibly() {
  local case_dir rc spelling
  for spelling in --auto --auto=true; do
    case_dir=$(make_case "github-auto-no-queue${spelling#--auto}")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" 7171717171717171717171717171717171717171
    write_github_outcome "$case_dir" OPEN false false main
    : > "$case_dir/github-rules"
    : > "$case_dir/gh-axi.log"
    : > "$case_dir/gh.log"

    rc=0
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/66 \
      --attended-override -- "$spelling" --merge \
      > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

    expect_code 1 "$rc" "github-auto-no-queue: an armed but unlanded auto-merge must still fail"
    assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
      "github-auto-no-queue: refusal did not name the concrete observed state"
    assert_grep 'auto-merge was requested and armed for https://github.com/example/repo/pull/66' \
      "$case_dir/stderr" "github-auto-no-queue: the refusal never explained the armed auto-merge"
    assert_grep 'nothing is merged or in the merge queue yet' "$case_dir/stderr" \
      "github-auto-no-queue: the refusal left the operator to infer the pending state"
    assert_logged_gh_merge "$case_dir" 66 example/repo "$spelling" --merge
    [ "$(grep '^pr merge ' "$case_dir/gh.log" | grep -vc -- '--disable-auto')" -eq 1 ] \
      || fail "github-auto-no-queue: the wrapper attempted more than one merge"
    assert_grep 'pr=https://github.com/example/repo/pull/66' "$case_dir/state/task-x1.meta" \
      "github-auto-no-queue: the attempted merge lost its PR reference"
    assert_present "$case_dir/state/task-x1.check.sh" \
      "github-auto-no-queue: the attempted merge did not leave its poll armed"
  done
  pass "fm-pr-merge explains an armed auto-merge that landed nothing on a queue-less base"
}

test_github_failed_merge_never_claims_armed_auto_merge() {
  local case_dir rc
  case_dir=$(make_case github-auto-merge-command-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/67 --attended-override -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "github-auto-merge-command-fails: the forge failure must still fail the wrapper"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-auto-merge-command-fails: the original forge error was masked"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-auto-merge-command-fails: refusal did not name the concrete observed state"
  assert_no_grep 'armed' "$case_dir/stderr" \
    "github-auto-merge-command-fails: a failed merge command was reported as an armed auto-merge"
  assert_grep 'auto-merge was requested for https://github.com/example/repo/pull/67' \
    "$case_dir/stderr" \
    "github-auto-merge-command-fails: the refusal never said auto-merge had only been requested"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-auto-merge-command-fails: a failed merge command was reported as verified"
  pass "fm-pr-merge never reports auto-merge as armed when the merge command failed"
}

test_github_failed_merge_with_queue_flags_never_claims_acceptance() {
  local case_dir rc
  case_dir=$(make_case github-failed-merge-queue-flags)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 --attended-override -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "github-failed-merge-queue-flags: the forge failure must still fail the wrapper"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: the original forge error was masked"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: refusal did not name the concrete observed state"
  assert_no_grep 'was accepted with the exact flags' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: a failed merge command was reported as an accepted request"
  assert_no_grep 'armed' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: a failed merge command was reported as an armed auto-merge"
  assert_grep 'base branch main requires the merge queue; retry with:' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: the failed merge command lost its concrete retry guidance"
  assert_grep 'task-x1 https://github.com/example/repo/pull/74 --attended-override -- --auto --merge' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: the retry guidance named no queue flags"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-failed-merge-queue-flags: a failed merge command was reported as verified"
  pass "fm-pr-merge claims no acceptance for a failed merge command carrying queue flags"
}

test_github_failed_gh_read_falls_back_to_gh_axi() {
  local case_dir rc
  case_dir=$(make_case github-gh-read-falls-back)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5151515151515151515151515151515151515151
  add_gh_mock_outcome_read_fails "$case_dir" 5151515151515151515151515151515151515151
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/63 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "github-gh-read-falls-back: a merge the gh-axi view proves must succeed"
  assert_grep 'pr view 63 --repo example/repo' "$case_dir/gh-axi.log" \
    "github-gh-read-falls-back: the gh-axi view was never consulted after gh's read failed"
  assert_grep 'verified: https://github.com/example/repo/pull/63 is merged' \
    "$case_dir/stdout" "github-gh-read-falls-back: the proven merge was not reported"
  assert_grep 'pr=https://github.com/example/repo/pull/63' "$case_dir/state/task-x1.meta" \
    "github-gh-read-falls-back: the merged PR was not recorded for teardown"
  pass "fm-pr-merge falls back to the gh-axi view when gh's read fails"
}

test_github_failed_merge_names_an_observed_landed_state() {
  local case_dir rc
  case_dir=$(make_case github-failed-merge-actually-landed)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" MERGED true false main
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/64 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "github-failed-merge-actually-landed: the forge failure must still fail the wrapper"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-failed-merge-actually-landed: the original forge error was masked"
  assert_grep 'state=MERGED, merged=true, isInMergeQueue=false' "$case_dir/stderr" \
    "github-failed-merge-actually-landed: the observed landed state was never named"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-failed-merge-actually-landed: a failed merge command was reported as verified"
  assert_grep 'pr=https://github.com/example/repo/pull/64' "$case_dir/state/task-x1.meta" \
    "github-failed-merge-actually-landed: the landed PR lost its reference"
  pass "fm-pr-merge names a landed state hiding behind a failed GitHub merge command"
}

test_github_without_gh_still_uses_gh_axi_merge() {
  local case_dir ghless_path rc
  case_dir=$(make_case github-without-gh)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4141414141414141414141414141414141414141
  rm "$case_dir/fakebin/gh"
  ghless_path="$case_dir/path-without-gh"
  mirror_path_without "$ghless_path" gh "$case_dir/fakebin"
  : > "$case_dir/gh-axi.log"

  rc=0
  PATH="$ghless_path" run_pr_merge "$case_dir" task-x1 \
    https://github.com/example/repo/pull/60 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "github-without-gh: missing gh must refuse before recording"
  assert_grep 'merging a GitHub pull request requires gh on PATH' "$case_dir/stderr" \
    "github-without-gh: missing gh was not named"
  assert_no_grep 'pr=' "$case_dir/state/task-x1.meta" \
    "github-without-gh: pr= was recorded without gh"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "github-without-gh: a merge poll was armed without gh"
  pass "fm-pr-merge refuses a GitHub merge when gh is missing, before recording"
}

test_github_without_gh_failed_read_keeps_bookkeeping() {
  local case_dir ghless_path rc
  case_dir=$(make_case github-without-gh-read-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4141414141414141414141414141414141414141
  rm "$case_dir/fakebin/gh"
  ghless_path="$case_dir/path-without-gh"
  mirror_path_without "$ghless_path" gh "$case_dir/fakebin"
  : > "$case_dir/gh-axi.log"

  rc=0
  PATH="$ghless_path" run_pr_merge "$case_dir" task-x1 \
    https://github.com/example/repo/pull/61 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "github-without-gh-read-fails: missing gh must refuse before recording"
  assert_grep 'merging a GitHub pull request requires gh on PATH' "$case_dir/stderr" \
    "github-without-gh-read-fails: missing gh was not named"
  assert_no_grep 'pr=' "$case_dir/state/task-x1.meta" \
    "github-without-gh-read-fails: pr= was recorded without gh"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "github-without-gh-read-fails: a merge poll was armed without gh"
  pass "fm-pr-merge refuses a GitHub merge when gh is missing rather than merging blind"
}

test_github_merged_outcome_is_verified() {
  local case_dir rc
  case_dir=$(make_case github-verified-merged)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1010101010101010101010101010101010101010
  : > "$case_dir/gh-axi.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/51 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "github-verified-merged: a merged PR should succeed"
  assert_grep 'verified: https://github.com/example/repo/pull/51 is merged' \
    "$case_dir/stdout" "github-verified-merged: success was not reported as verified"
  assert_grep 'api graphql' "$case_dir/gh.log" \
    "github-verified-merged: the PR outcome was not read back after merging"
  pass "fm-pr-merge verifies a genuinely merged GitHub pull request"
}

# A verified merge arms the pool-copy prune and starts one detached attempt
# (bin/fm-merge-prune.sh owns the contract; tests/fm-merge-prune.test.sh covers
# its behavior). Teardown is a recording stand-in here.
test_verified_merge_arms_the_pool_copy_prune() {
  local case_dir rc stub
  case_dir=$(make_case github-merge-prunes-the-copy)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1212121212121212121212121212121212121212
  : > "$case_dir/gh-axi.log"
  stub="$case_dir/teardown-stub"
  # shellcheck disable=SC2016 # The stub's own text is single-quoted on purpose: it expands when the stub runs.
  printf '#!/usr/bin/env bash\nprintf "%%s|admission=%%s\\n" "$*" "${FM_IDLE_REAP_ADMISSION:-}" >> "%s"\nexit 0\n' "$case_dir/teardown-calls" > "$stub"
  chmod +x "$stub"

  rc=0
  FM_MERGE_PRUNE=1 FM_MERGE_PRUNE_TEARDOWN_BIN="$stub" run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/51 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "github-merge-prune: the merge itself must still succeed"
  fm_test_wait_until --progress-file "$case_dir/home/data/task-x1/merge-prune.log" --progress-file "$case_dir/teardown-calls" -- test -s "$case_dir/teardown-calls" \
    || fail "github-merge-prune: the verified merge never started a teardown attempt: $(cat "$case_dir/stderr")"
  [ "$(cat "$case_dir/teardown-calls")" = "task-x1|admission=1" ] \
    || fail "github-merge-prune: teardown was not asked plainly for the task: $(cat "$case_dir/teardown-calls")"
  fm_test_wait_until --progress-file "$case_dir/home/data/task-x1/merge-prune.log" --progress-file "$case_dir/teardown-calls" -- grep -q reaped "$case_dir/home/data/task-x1/merge-prune.log" \
    || fail "github-merge-prune: the prune log does not say reaped"
  pass "fm-pr-merge arms the pool-copy prune after a verified merge and the detached attempt reaps it, unforced"
}

test_unverified_merge_never_arms_the_pool_copy_prune() {
  local case_dir rc
  case_dir=$(make_case github-unverified-merge-no-prune)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1313131313131313131313131313131313131313
  printf '%s\n' 'state=OPEN' 'merged=false' 'queued=false' 'base=main' > "$case_dir/github-outcome"
  : > "$case_dir/gh-axi.log"

  rc=0
  FM_MERGE_PRUNE=1 run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/52 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  [ "$rc" -ne 0 ] || fail "github-unverified-no-prune: an open PR should not read as merged"
  assert_absent "$case_dir/state/task-x1.merge-prune" "github-unverified-no-prune: a merge that was not verified armed a prune"
  pass "fm-pr-merge never arms the prune for a merge it could not verify"
}

test_github_verified_merge_requires_poll_recording() {
  local case_dir rc
  case_dir=$(make_case github-poll-recording-fails)
  add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111
  add_failing_poll_publish_mv "$case_dir"
  : > "$case_dir/gh-axi.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/55 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "github-poll-recording-fails: poll setup failure should fail the merge wrapper"
  assert_grep 'error: could not publish PR poll' "$case_dir/stderr" \
    "github-poll-recording-fails: poll setup failure was not reported"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-poll-recording-fails: failed poll setup was reported as a verified merge"
  assert_grep 'pr=https://github.com/example/repo/pull/55' "$case_dir/state/task-x1.meta" \
    "github-poll-recording-fails: metadata was not retained for the attempted merge"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "github-poll-recording-fails: the failed poll setup left a runnable poll"
  pass "fm-pr-merge refuses to claim a merge when poll recording fails"
}

test_github_queued_outcome_is_verified() {
  local case_dir rc
  case_dir=$(make_case github-verified-queued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3030303030303030303030303030303030303030
  write_github_outcome "$case_dir" OPEN false true master
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/53 --attended-override -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "github-verified-queued: a queued PR should succeed"
  assert_grep 'verified: https://github.com/example/repo/pull/53 is queued' \
    "$case_dir/stdout" "github-verified-queued: success was not reported as queued"
  assert_no_grep 'merged:' "$case_dir/stdout" \
    "github-verified-queued: the forge CLI's unverified merged report leaked through"
  assert_grep 'pr=https://github.com/example/repo/pull/53' "$case_dir/state/task-x1.meta" \
    "github-verified-queued: the queued PR was not recorded for teardown"
  pass "fm-pr-merge accepts and accurately reports a GitHub merge-queue entry"
}

test_github_queue_required_refusal_names_retry_flags() {
  local case_dir rc
  case_dir=$(make_case github-queue-required)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" OPEN false false master
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/54 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "github-queue-required: an incompatible direct merge must fail"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-queue-required: the original forge failure was not preserved"
  assert_grep 'base branch master requires the merge queue' "$case_dir/stderr" \
    "github-queue-required: refusal did not name the queue requirement"
  grep -F -- '--attended-override -- --auto --merge' "$case_dir/stderr" >/dev/null \
    || fail "github-queue-required: refusal did not name the exact compatible flags"
  assert_logged_gh_merge "$case_dir" 54 example/repo --squash
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-queue-required: the failed forge call did not leave the merge poll armed"
  pass "fm-pr-merge explains how to retry with the required GitHub merge queue method"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "extra-args: branch deletion must be refused without --attended-override"
  assert_grep 'pass --attended-override only for an explicit captain instruction' "$case_dir/stderr" \
    "extra-args: refusal did not name --attended-override"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "extra-args: gh pr merge ran despite the denylist"

  case_dir=$(make_case extra-args-attended)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 \
    --attended-override -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args-attended: attended override should merge"
  assert_logged_gh_merge "$case_dir" 15 example/repo --squash --delete-branch
  pass "fm-pr-merge refuses branch deletion unless --attended-override is passed"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  printf '%s\n' 2222222222222222222222222222222222222222 > "$case_dir/github-base"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  rc=0
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh.log" ] || fail "missing-meta: gh pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  rc=0
  # A near-miss GitLab URL: one namespace segment where a project needs at
  # least two. A well-formed merge request URL is merged now, so the refusal
  # has to be proven on a URL that genuinely does not parse.
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a malformed merge request URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  rc=0
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

# Main's own home configuration, not a task record.
landing_home_config() {
  mkdir -p "$1/data" "$1/state" "$1/config"
  fm_test_tasks_toml "$1/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$1/data/backlog.md"
  if [ -n "${2:-}" ]; then
    printf 'maintainer %s\n' "$2" > "$1/config/firstmate-role"
  fi
}

# Main's own landing-record task for a PR. Args: main id
main_landing_task() {
  fm_write_meta "$1/state/$2.meta" "window=fm-$2" "worktree=$1" "project=$1" 'kind=ship' \
    'model=gpt-5.1-codex' 'branch=fm/fixture' 'mode=no-mistakes'
}

test_firstmate_landings_belong_to_main_home() {
  local case_dir head rc url main
  case_dir=$(make_case firstmate-landing-home)
  main="$case_dir/wt"
  url=https://github.com/example/repo/pull/9
  git -C "$main" remote add origin https://github.com/Example/Repo.git
  head=$(git -C "$main" rev-parse HEAD)
  add_gh_mocks "$case_dir" "$head"
  landing_home_config "$main" github.com/example/repo

  # Two independent home/state records share the installation's repository.
  # The second home's formerly normal merge must not advance Main's train tip.
  rc=0
  FM_GUARD_EVENT_LOG="$case_dir/guard-events.jsonl" FM_TEST_CODE_ROOT="$main" run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "another home must hand its firstmate landing to Main"
  assert_guard_rule "$case_dir/guard-events.jsonl" merge-single-owner deny single-owner task-x1
  assert_no_grep 'pr merge ' "$case_dir/gh.log" 'the second home never hands the PR to the forge'
  assert_absent "$case_dir/state/task-x1.check.sh" 'routing happens before PR bookkeeping'
  assert_grep "outside its Main home, $main;" "$case_dir/stderr" 'routing names the Main home its role record proves'
  assert_grep 'spawn a landing-record task' "$case_dir/stderr" 'routing names the supported Main route'
  assert_grep "fm-pr-merge.sh <landing-task> $url" "$case_dir/stderr" 'routing names the merge in Main'

  main_landing_task "$main" task-x1
  rc=0
  FM_TEST_CODE_ROOT="$main" FM_TEST_HOME="$main" FM_TEST_STATE="$main/state" run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "Main's single ready PR lands normally: $(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 9 example/repo --squash
  assert_grep "pr=$url" "$main/state/task-x1.meta" 'Main owns its landed PR record'
  assert_no_grep '^pr=' "$case_dir/state/task-x1.meta" 'the source task record was not changed by its refused merge'
  pass 'firstmate landings route to Main, and one Main PR lands normally'
}

test_repair_clone_routes_to_main() {
  local case_dir head rc url main repair
  case_dir=$(make_case repair-clone-landing)
  main="$case_dir/wt"
  repair="$case_dir/fm-repair"
  url=https://github.com/MrGTV-love/firstmate/pull/303
  git -C "$main" remote add origin https://github.com/MrGTV-love/firstmate
  git clone -q "$main" "$repair"
  git -C "$repair" remote set-url origin https://github.com/MrGTV-love/firstmate
  git -C "$repair" remote add upstream https://github.com/kunchenguid/firstmate
  head=$(git -C "$main" rev-parse HEAD)
  add_gh_mocks "$case_dir" "$head"
  landing_home_config "$repair"
  fm_write_meta "$repair/state/task-x1.meta" "worktree=$repair" "project=$repair" "kind=ship" \
    "model=gpt-5.1-codex" "branch=fm/fixture" "mode=no-mistakes"

  # The repair clone is its own primary worktree and publishes to upstream by
  # default, yet its PR targets Main's repository.
  rc=0
  FM_TEST_CODE_ROOT="$repair" FM_TEST_HOME="$repair" FM_TEST_STATE="$repair/state" \
    run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "a standalone repair clone must not land Main's repository: $(cat "$case_dir/stderr")"
  assert_no_grep 'pr merge ' "$case_dir/gh.log" 'the repair clone never hands the PR to the forge'
  assert_absent "$repair/state/task-x1.check.sh" 'the repair clone arms no merge poll'
  assert_grep 'config/firstmate-role grants maintainer github.com/mrgtv-love/firstmate' "$case_dir/stderr" \
    'the refusal names Main by its recorded publication target, not repair remotes'
  assert_no_grep "$case_dir/" "$case_dir/stderr" 'the refusal names no path it cannot prove'

  landing_home_config "$main" github.com/mrgtv-love/firstmate
  main_landing_task "$main" task-x1
  rc=0
  FM_TEST_CODE_ROOT="$main" FM_TEST_HOME="$main" FM_TEST_STATE="$main/state" \
    run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "Main lands the repair PR: $(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 303 MrGTV-love/firstmate --squash
  pass 'a standalone repair clone hands its PR to Main, which lands it'
}

test_main_scope_routes_standalone_clones() {
  local case_dir main repair head rc shape url
  case_dir=$(make_case recorded-main-target)
  main="$case_dir/wt"
  repair="$case_dir/repair"
  url=https://github.com/example/repo/pull/9
  landing_home_config "$main" github.com/example/repo
  git clone -q "$main" "$repair"
  landing_home_config "$repair"
  fm_write_meta "$repair/state/task-x1.meta" "worktree=$repair" "project=$repair" \
    'kind=ship' 'model=gpt-5.1-codex' 'branch=fm/fixture' 'mode=no-mistakes'
  head=$(git -C "$main" rev-parse HEAD)
  add_gh_mocks "$case_dir" "$head"
  for shape in origin-only with-upstream no-matching-remote; do
    case "$shape" in
      origin-only) git -C "$repair" remote set-url origin https://github.com/example/repo ;;
      with-upstream) git -C "$repair" remote add upstream https://github.com/other/firstmate ;;
      no-matching-remote)
        git -C "$repair" remote remove origin
        git -C "$repair" remote remove upstream ;;
    esac
    rc=0
    FM_TEST_CODE_ROOT="$repair" FM_TEST_HOME="$repair" FM_TEST_STATE="$repair/state" \
      run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "$shape clone must hand its landing to the recorded Main"
    assert_no_grep 'pr merge ' "$case_dir/gh.log" "$shape clone never reaches forge merge"
    assert_absent "$repair/state/task-x1.check.sh" "$shape clone never registers a poll"
    assert_grep 'grants maintainer github.com/example/repo' "$case_dir/stderr" "$shape clone names the required grant"
    assert_no_grep "$case_dir/" "$case_dir/stderr" "$shape clone names no path it cannot prove"
  done
  # Neither Main's remotes nor the source home's remotes match the PR. The
  # explicit Main grant, not gh's default-remote order, owns this target.
  git -C "$main" remote add origin https://github.com/other/fork
  git -C "$main" remote add upstream https://github.com/other/firstmate
  main_landing_task "$main" task-x1
  rc=0
  FM_TEST_CODE_ROOT="$main" FM_TEST_HOME="$main" FM_TEST_STATE="$main/state" \
    run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "Main's recorded target lands despite unrelated remotes: $(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 9 example/repo --squash
  pass 'origin-only and remote-less clones route to the recorded Main target'
}

test_linked_home_refusal_names_only_a_proved_home() {
  local case_dir repair linked head rc url
  case_dir=$(make_case linked-home-refusal)
  repair="$case_dir/repair"
  linked="$case_dir/linked"
  url=https://github.com/example/repo/pull/9
  git clone -q "$case_dir/wt" "$repair"
  git -C "$repair" remote set-url origin https://github.com/example/repo
  git -C "$repair" worktree add -q --detach "$linked"
  landing_home_config "$linked"
  fm_write_meta "$linked/state/task-x1.meta" "worktree=$linked" "project=$linked" \
    'kind=ship' 'model=gpt-5.1-codex' 'branch=fm/fixture' 'mode=no-mistakes'
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_mocks "$case_dir" "$head"

  rc=0
  FM_TEST_CODE_ROOT="$linked" FM_TEST_HOME="$linked" FM_TEST_STATE="$linked/state" \
    run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" 'a linked worktree of an ungranted clone must not land'
  assert_no_grep 'pr merge ' "$case_dir/gh.log" 'the linked home never calls forge merge'
  assert_grep 'grants maintainer github.com/example/repo' "$case_dir/stderr" 'an unproved owner is named by its grant'
  assert_no_grep "$case_dir/" "$case_dir/stderr" 'the refusal names no path that fails on the next step'

  landing_home_config "$repair" github.com/example/repo
  rc=0
  FM_TEST_CODE_ROOT="$linked" FM_TEST_HOME="$linked" FM_TEST_STATE="$linked/state" \
    run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" 'a linked worktree of the granted home must not land'
  assert_grep "outside its Main home, $repair;" "$case_dir/stderr" 'a proved owner is named by its path'
  assert_no_grep 'grants maintainer' "$case_dir/stderr" 'a proved owner needs no search'
  pass 'a linked home refusal names a home only when its role record proves the grant'
}

test_task_consent_does_not_authorize_a_landing() {
  local case_dir head rc
  case_dir=$(make_case consent-landing)
  git -C "$case_dir/wt" remote add origin https://github.com/example/repo
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_mocks "$case_dir" "$head"
  landing_home_config "$case_dir/wt"
  printf 'upstream_consent=github.com/example/repo\n' >> "$case_dir/state/task-x1.meta"
  # The primary home merges its own consent task with no maintainer grant, so
  # a matching consent is the only authority on offer.
  rc=0
  FM_TEST_CODE_ROOT="$case_dir/wt" FM_TEST_HOME="$case_dir/wt" run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" 'one-task consent must not land the PR'
  assert_no_grep 'pr merge ' "$case_dir/gh.log" 'one-task consent never reaches forge merge'
  assert_absent "$case_dir/state/task-x1.check.sh" 'one-task consent arms no merge poll'
  assert_grep 'outside its Main home, the home whose config/firstmate-role grants maintainer github.com/example/repo;' \
    "$case_dir/stderr" 'the primary home with consent but no grant is refused for the missing maintainer grant'
  assert_no_grep "$case_dir/" "$case_dir/stderr" 'the consent refusal names no path it cannot prove'
  pass 'one-task consent authorizes a contribution, not a landing'
}

test_shallow_task_lineage_routing() {
  local case_dir root task head base url rc
  case_dir=$(make_case shallow-task-landing)
  root="$case_dir/wt"
  task="$case_dir/shallow-task"
  url=https://github.com/example/repo/pull/9
  rm "$case_dir/fakebin/git"
  base=$(git -C "$root" rev-parse HEAD)
  printf '%s\n' "$base" > "$case_dir/github-base"
  git -C "$root" commit -q --allow-empty -m 'ship shallow fixture implementation'
  git clone -q --depth 2 "file://$root" "$task" || fail 'create shallow task copy'
  head=$(git -C "$task" rev-parse HEAD)
  git -C "$task" update-ref refs/remotes/origin/fm/fixture "$head"
  fm_write_meta "$case_dir/state/task-x1.meta" "worktree=$task" "project=$task" \
    'kind=ship' 'model=gpt-5.1-codex' 'branch=fm/fixture' 'mode=no-mistakes'
  add_gh_mocks "$case_dir" "$head"

  rc=0
  FM_GUARD_EVENT_LOG="$case_dir/guard-events.jsonl" FM_TEST_CODE_ROOT="$root" run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" 'unknown task lineage must not take the unrelated-project merge path'
  assert_guard_rule "$case_dir/guard-events.jsonl" merge-single-owner deny single-owner task-x1
  assert_grep 'lineage cannot be determined' "$case_dir/stderr" 'unknown lineage is the named refusal reason'
  assert_grep "git -C $task fetch --unshallow" "$case_dir/stderr" 'the remedy names the shallow task copy'
  assert_no_grep 'pr merge ' "$case_dir/gh.log" 'unknown lineage never reaches forge merge'
  assert_absent "$case_dir/state/task-x1.check.sh" 'unknown lineage never registers a merge poll'
  assert_no_grep '^pr=' "$case_dir/state/task-x1.meta" 'unknown lineage changes no landed PR record'

  # The same shallow copy is a candidate when the code-root remote identifies
  # the PR repository; it must hand off to Main, not require a history fetch.
  # This code root records no grant, so the refusal names the grant and no path.
  git -C "$root" remote add origin https://github.com/example/repo
  rc=0
  FM_TEST_CODE_ROOT="$root" run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" 'the matching remote must route the shallow task to Main'
  assert_grep 'grants maintainer github.com/example/repo' "$case_dir/stderr" \
    'the matching remote preserves the Main handoff'
  assert_no_grep 'lineage cannot be determined' "$case_dir/stderr" 'a matching remote settles candidate detection'
  assert_no_grep 'pr merge ' "$case_dir/gh.log" 'the source home cannot merge through either route'
  assert_absent "$case_dir/state/task-x1.check.sh" 'the source home arms no merge poll'
  pass 'unknown shallow lineage refuses unless a matching remote establishes the Main route'
}

test_unrelated_project_keeps_home_local_merge() {
  local case_dir head rc root
  case_dir=$(make_case vernant-landing)
  root="$case_dir/firstmate"
  fm_git_init_commit "$root"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_mocks "$case_dir" "$head"
  cat > "$case_dir/record-lock" <<SH
#!/usr/bin/env bash
if [ -e "$case_dir/state/.firstmate-landing.lock" ]; then echo held; else echo free; fi > "$case_dir/lock-at-merge"
SH
  chmod +x "$case_dir/record-lock"
  # The Firstmate root has no readable publication target; a Vernant PR has
  # no relation to a Firstmate train and keeps its existing merge path.
  rc=0
  FM_TEST_AWAY_MUTATE_AT_MERGE="$case_dir/record-lock" FM_TEST_CODE_ROOT="$root" run_pr_merge "$case_dir" task-x1 https://github.com/acme/vernant/pull/11 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "an unrelated project lands from its own home: $(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 11 acme/vernant --squash
  [ "$(cat "$case_dir/lock-at-merge" 2>/dev/null)" = free ] \
    || fail "an unrelated project holds no landing lock during its forge call: $(cat "$case_dir/lock-at-merge" 2>/dev/null)"
  pass 'an unrelated project keeps its home-local merge path'
}

test_unreadable_landing_routing_refuses() {
  local scenario case_dir head rc wt url
  url=https://github.com/example/repo/pull/9
  for scenario in absent malformed mismatched; do
    case_dir=$(make_case "unreadable-landing-$scenario")
    wt="$case_dir/wt"
    head=$(git -C "$wt" rev-parse HEAD)
    add_gh_mocks "$case_dir" "$head"
    landing_home_config "$wt"
    # Matching remotes never substitute for a valid recorded Main target.
    git -C "$wt" remote add origin https://github.com/example/repo
    case "$scenario" in
      malformed) printf 'maintainer\n' > "$wt/config/firstmate-role" ;;
      mismatched) printf 'maintainer github.com/other/repo\n' > "$wt/config/firstmate-role" ;;
    esac
    rc=0
    FM_TEST_CODE_ROOT="$wt" FM_TEST_HOME="$wt" run_pr_merge "$case_dir" task-x1 "$url" \
      > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "a $scenario recorded target must not silently create a landing owner"
    assert_no_grep 'pr merge ' "$case_dir/gh.log" 'unproved Main authority never calls the forge'
    assert_absent "$case_dir/state/task-x1.check.sh" 'unproved Main authority never arms a merge poll'
    assert_grep 'grants maintainer github.com/example/repo' "$case_dir/stderr" \
      'an unproved home hands the PR to the recorded Main rather than changing remotes'
    assert_no_grep "$case_dir/" "$case_dir/stderr" 'an unproved home names no path'
  done
  pass 'absent, malformed and mismatched Main grants fail closed despite matching remotes'
}

test_seeded_homes_cannot_create_a_second_landing_owner() {
  local scenario case_dir head rc
  for scenario in local local-ungranted remote corrupt; do
    case_dir=$(make_case "seeded-landing-$scenario")
    git -C "$case_dir/wt" remote add origin https://github.com/example/repo.git
    head=$(git -C "$case_dir/wt" rev-parse HEAD)
    add_gh_mocks "$case_dir" "$head"
    fm_git_init_commit "$case_dir/main-home"
    printf 'mate-x\n' > "$case_dir/wt/.fm-secondmate-home"
    case "$scenario" in
      local | local-ungranted)
        printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$case_dir/main-home" \
          > "$case_dir/wt/.fm-secondmate-parent" ;;
      remote)
        printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=fixture\n' \
          > "$case_dir/wt/.fm-secondmate-parent" ;;
      corrupt)
        printf 'unreadable-parent\n' > "$case_dir/wt/.fm-secondmate-parent" ;;
    esac
    [ "$scenario" != local ] || landing_home_config "$case_dir/main-home" github.com/example/repo
    rc=0
    (cd "$case_dir/wt" && FM_TEST_CODE_ROOT="$case_dir/wt" FM_TEST_HOME="$case_dir/wt" \
      run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9) \
        > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "a $scenario secondmate binding must not create another landing owner"
    assert_no_grep 'pr merge ' "$case_dir/gh.log" "the $scenario home never calls forge merge"
    case "$scenario" in
      local)
        assert_grep "outside its Main home, $case_dir/main-home;" "$case_dir/stderr" 'a separate clone still routes to its granted Main home' ;;
      local-ungranted)
        assert_grep 'grants maintainer github.com/example/repo' "$case_dir/stderr" 'an ungranted parent is named by the grant'
        assert_no_grep "$case_dir/" "$case_dir/stderr" 'an ungranted parent is not named by path' ;;
      *)
        assert_grep 'existing secondmate parent channel' "$case_dir/stderr" "an unreachable Main uses the existing parent handoff: $(cat "$case_dir/stderr")" ;;
    esac
  done
  pass 'local clones, remote homes, and corrupt bindings cannot become another landing owner'
}

landing_waiter_visible() {
  local file
  for file in "$1"/.lock-monitor.wait.*; do
    [ -f "$file" ] || continue
    grep -qF "$1/.firstmate-landing.lock" "$file" && return 0
  done
  return 1
}

test_main_serializes_firstmate_landings() (
  local case_dir main head first='' second='' rc
  case_dir=$(make_case serialized-firstmate-landings)
  main="$case_dir/wt"
  git -C "$main" remote add origin https://github.com/example/repo.git
  head=$(git -C "$main" rev-parse HEAD)
  add_gh_mocks "$case_dir" "$head"
  landing_home_config "$main" github.com/example/repo
  main_landing_task "$main" task-x1
  main_landing_task "$main" task-x2
  cat > "$case_dir/hold-merge" <<SH
#!/usr/bin/env bash
: > "$case_dir/merge-entered"
while [ ! -e "$case_dir/release-merge" ]; do sleep 0.1; done
SH
  chmod +x "$case_dir/hold-merge"
  # Always release the private fixture's forge callback, including on failure.
  trap ': > "$case_dir/release-merge"; [ -z "$first" ] || wait "$first" 2>/dev/null; [ -z "$second" ] || wait "$second" 2>/dev/null' EXIT
  FM_TEST_CODE_ROOT="$main" FM_TEST_HOME="$main" FM_TEST_STATE="$main/state" FM_TEST_AWAY_MUTATE_AT_MERGE="$case_dir/hold-merge" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
      > "$case_dir/first.out" 2> "$case_dir/first.err" &
  first=$!
  fm_test_wait_until --while-alive "$first" --progress-file "$case_dir/gh.log" \
    -- test -e "$case_dir/merge-entered" || fail 'first merge never entered its forge callback'
  FM_GUARD_EVENT_LOG="$main/state/guard-events.jsonl" FM_TEST_CODE_ROOT="$main" FM_TEST_HOME="$main" FM_TEST_STATE="$main/state" \
    run_pr_merge "$case_dir" task-x2 https://github.com/example/repo/pull/10 \
      > "$case_dir/second.out" 2> "$case_dir/second.err" &
  second=$!
  fm_test_wait_until --while-alive "$second" --progress-file "$main/state/guard-events.jsonl" \
    -- landing_waiter_visible "$main/state" || fail 'second landing never waited for the first'
  assert_no_grep '^pr merge 10 ' "$case_dir/gh.log" 'another task cannot merge while the first outcome is pending'
  : > "$case_dir/release-merge"
  rc=0; wait "$first" || rc=$?; first=
  expect_code 0 "$rc" "first landing failed: $(cat "$case_dir/first.err")"
  rc=0; wait "$second" || rc=$?; second=
  expect_code 0 "$rc" "second landing failed: $(cat "$case_dir/second.err")"
  assert_logged_gh_merge "$case_dir" 9 example/repo --squash
  assert_logged_gh_merge "$case_dir" 10 example/repo --squash
  assert_absent "$main/state/.firstmate-landing.lock" 'landing lock is released after the confirmed outcome'
  pass 'Main serializes different firstmate tasks through their forge outcomes'
)

# --- automatic exact-head review and merge (bin/fm-pr-auto-review.py) -------
# Real fm-pr-auto-review.py, fm-review-record.py, fm-review-diff.sh and fm-pr-merge.sh
# over the shared GitHub mocks; the review runner is a FAKE script that logs its argv
# and writes a canned report. Nothing here reads, merges or records a real PR.
AUTO_URL=https://github.com/example/repo/pull/9
AUTO_TERRA=openai-codex/gpt-6.1-terra
AUTO_SONNET='claude-sonnet-5-5[1m]'
AUTO_DEEPSEEK=deepseek/deepseek-v4-flash

auto_slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

auto_write_runner() {  # <case_dir>
  cat > "$1/fake-runner.sh" <<'SH'
#!/usr/bin/env bash
# FAKE review runner: <review-dir> <pr-url> <head> <diff-file> <repo-root> [model]
D=$1; URL=$2; H=$3; DIFF=$4; PROJECT=$5; MODEL=${6:-default}
C=$FM_AUTO_CASE
printf 'argv: %s|%s|%s|%s|%s|%s contract=%s ci=%s diff=%s\n' "$D" "$URL" "$H" "$DIFF" "$PROJECT" "$MODEL" \
  "$(wc -c < "$D/contract.md" | tr -d ' ')" "$(wc -c < "$D/ci-evidence.md" | tr -d ' ')" "$(wc -c < "$D/$DIFF" | tr -d ' ')" >> "$C/runner.calls"
slug=$(printf '%s' "$MODEL" | tr -c 'A-Za-z0-9._-' '_')
mode=$(cat "$C/runner/$slug.mode" 2>/dev/null || cat "$C/runner/default.mode" 2>/dev/null || echo pass)
named=$H
served=$MODEL
if [ "$mode" = hang ] || [ "$(cat "$C/hang-head" 2>/dev/null)" = "$H" ]; then
  printf '%s\n' "$$" > "$C/runner.pid"
  while [ ! -e "$C/runner.release" ] && [ -d "$C" ]; do sleep 0.1; done
  mode=pass
fi
case $mode in
  quota) echo usage_limit_reached >&2; echo "rc=1 report=$D/review.md"; exit 1 ;;
  crash) exit 3 ;;
  wrong-head) named=0000000000000000000000000000000000000000; mode=pass ;;
  switched) served=openai-codex/gpt-6.1-sol; mode=pass ;;
  switched-fail) served=openai-codex/gpt-6.1-sol; mode=fail ;;
  prose-only) served=; echo 'Terra quota exhausted (marker x); using openai-codex/gpt-6.1-sol' >&2; echo "switching to $MODEL now"; mode=pass ;;
  no-served) served=; mode=pass ;;
  bad-served) served="$MODEL extra"; mode=pass ;;
  rc17) exit_rc=17; mode=pass ;;
  rc17-fail) exit_rc=17; mode=fail ;;
esac
word=PASS; case $mode in fail|fail-truncated) word=FAIL ;; incomplete) word=INCOMPLETE ;; esac
loosens=no; [ "$mode" != loosens-yes ] || loosens=yes
eol='\n'; [ "$mode" != crlf ] || eol='\r\n'
{
  printf "VERDICT: %s head=%s$eol" "$word" "$named"
  printf 'Reader %s read the pack.\n' "$MODEL"
  if [ "$mode" != no-facts ]; then
    printf -- '- Loosens a deny or allow list: %s - fixture\n' "$loosens"
    printf -- '- Widens what a guard permits: no - fixture\n'
    printf -- '- Touches customer data, billing or spend: no - fixture\n'
  fi
  case $mode in
    protected-yes) printf 'Protected class: yes - security-sensitive fixture\n' ;;
    protected-missing) ;;
    protected-malformed) printf 'Protected class: maybe\n' ;;
    *) printf 'Protected class: no - fixture\n' ;;
  esac
  [ "$mode" = fail-truncated ] || printf 'VERDICT: %s\n' "$word"
} > "$D/review.md"
[ -z "$served" ] || echo "served-model: $served"
echo "rc=${exit_rc:-0} report=$D/review.md"
exit "${exit_rc:-0}"
SH
  chmod +x "$1/fake-runner.sh"
}

auto_publish_head() {  # <case_dir> <label>: the ship tip becomes the PR head on the fake forge and its origin
  git -C "$1/wt" push -q -f origin "HEAD:refs/pull/9/head"
  git -C "$1/wt" rev-parse HEAD > "$1/$2"
  write_github_live_json "$1" "$(cat "$1/$2")"
}
auto_push() {  # <case_dir>: a push makes a new head h2
  printf 'more\n' >> "$1/wt/changed.txt"
  git -C "$1/wt" commit -q -am 'ship change 2'
  auto_publish_head "$1" h2
}
auto_sha() { cat "$1/$2"; }

auto_case() {  # <name> [ship author model]; echoes the case dir
  local name=$1 author=${2:-gpt-5.1-codex} case_dir
  case_dir=$(make_case "auto-$name")
  : > "$case_dir/explicit-review"
  # fm-review-diff.sh needs a project clone and a ship branch that differs from main.
  fm_git_init_commit "$case_dir/project"
  git -C "$case_dir/project" branch -M main
  git -C "$case_dir/wt" checkout -q -B fm/fixture
  printf 'change\n' > "$case_dir/wt/changed.txt"
  git -C "$case_dir/wt" add changed.txt
  git -C "$case_dir/wt" commit -q -m 'ship change'
  git -C "$case_dir/wt" branch -f main "$(cat "$case_dir/github-base")"
  # The PR head is a real commit served from refs/pull/9/head, so the diff can be bound to it.
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/wt" remote add origin "$case_dir/origin.git"
  git -C "$case_dir/wt" push -q origin main fm/fixture
  add_gh_mocks "$case_dir" "$(git -C "$case_dir/wt" rev-parse HEAD)"
  : > "$case_dir/gh-axi.log"
  auto_publish_head "$case_dir" h1
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" \
    "project=$case_dir/project" "kind=ship" "model=$author" "branch=fm/fixture" "mode=no-mistakes" "pr=$AUTO_URL"
  mkdir -p "$case_dir/home/data/task-x1" "$case_dir/runner"
  # The default layout: bin/fm-brief.sh scaffolds the Definition Of Done as an inline section of brief.md.
  auto_write_brief "$case_dir" 'G1 fixture item.'
  mkdir -p "$case_dir/state/task-x1.inbox/handled"
  printf 'schema=fm-task-inbox.v1\nat=x\n--\nMain ruling fixture.\n' > "$case_dir/state/task-x1.inbox/handled/001.msg"
  cat > "$case_dir/home/config/crew-dispatch.json" <<JSON
{"rules":[{"when":"Isolated independent quality review of a specific pull request","use":[{"harness":"omp","model":"$AUTO_TERRA"},{"harness":"claude","model":"$AUTO_SONNET"}],"fallback":[{"harness":"dsh","model":"$AUTO_DEEPSEEK"}]}]}
JSON
  auto_write_runner "$case_dir"
  printf '%s\n' "$case_dir/fake-runner.sh" > "$case_dir/home/config/review-runner"
  : > "$case_dir/runner.calls"
  printf '%s\n' "$case_dir"
}

auto_mode() { mkdir -p "$1/runner"; printf '%s\n' "$3" > "$1/runner/$(auto_slug "$2").mode"; }

# <case_dir> [<section-body>]: rewrite the task brief; with a body it carries the scaffolded
# `## Definition Of Done (task)` section through `## How You're Graded`, without one it has neither.
auto_write_brief() {
  {
    printf '# Brief\n## Captain'\''s intent\nFixture intent.\n'
    [ $# -lt 2 ] || printf '\n## Definition Of Done (task)\n%s\n\n## How You'\''re Graded\nGraded by the fixture.\n' "$2"
  } > "$1/home/data/task-x1/brief.md"
}

auto_helper() {  # <case_dir> <verb> [env...]: run bin/fm-pr-auto-review.py <verb> task-x1 in the sandbox
  local case_dir=$1 verb=$2 saved=$PR_MERGE rc=0
  shift 2
  PR_MERGE=$ROOT/bin/fm-pr-auto-review.py
  FM_AUTO_CASE="$case_dir" FM_PR_AUTO_REVIEW_INTERVAL=0 FM_PR_AUTO_REVIEW_MERGE_RETRY="${AUTO_MERGE_RETRY:-600}" \
    run_pr_merge "$case_dir" "$verb" "${AUTO_TASK:-task-x1}" > "$case_dir/helper.out" 2> "$case_dir/helper.err" || rc=$?
  PR_MERGE=$saved
  return "$rc"
}
auto_state() { auto_helper "$1" state; cat "$1/helper.out"; }
# FM_AUTO_EVIDENCE=1 prints what each step and each scenario left behind (fake-reader evidence).
auto_step() {
  auto_helper "$1" step || fail "$1: the review step must exit 0: $(cat "$1/helper.err")"
  [ -z "${FM_AUTO_EVIDENCE:-}" ] || printf '  step -> state=[%s] reads=%s reviews=%s merges=%s\n' "$(auto_state "$1")" "$(auto_calls "$1")" "$(auto_reviews "$1")" "$(auto_merges "$1")" | sed "s#$TMP_ROOT#<tmp>#g"
}
auto_dump() {  # <case_dir> <label>
  [ -n "${FM_AUTO_EVIDENCE:-}" ] || return 0
  printf '## %s\n  fake runner argv:\n' "$2"
  sed -e "s#$TMP_ROOT#<tmp>#g" -e 's/^/    /' "$1/runner.calls"
  printf '  review-lane events (fm-pr-auto-review.py events task-x1):\n'
  sed -e "s#$TMP_ROOT#<tmp>#g" -e 's/^/    /' "$(auto_event_file "$1")" 2>/dev/null || true
  printf '  review records (state/review-records.jsonl):\n'
  jq -c '{verdict,head:.head[0:12],reader_model,reader_family,covered_groups,loosens:.loosens_deny_allow_list,widens:.widens_guard,data:.customer_data_billing_spend}' "$1/state/review-records.jsonl" 2>/dev/null | sed 's/^/    /' || true
  printf '  forge merge calls (fake gh log):\n'
  grep '^pr merge ' "$1/gh.log" | sed 's/^/    /' || true
  printf '  current state: %s\n' "$(auto_state "$1" | sed "s#$TMP_ROOT#<tmp>#g")"
}

auto_wait() {  # <case_dir>: until every requested read has returned
  local case_dir=$1 n req
  for n in $(seq 1 150); do
    req=0
    for dir in "$case_dir"/state/.pr-auto-review/task-x1.d/*.run; do
      [ -f "$dir/request.json" ] && [ ! -f "$dir/result.json" ] && [ ! -f "$dir/killed" ] && req=1
    done
    [ "$req" = 0 ] && return 0
    sleep 0.2
  done
  fail "$case_dir: a fake read never returned"
}

auto_count() { local n; n=$(grep -cF -- "$1" "$2" 2>/dev/null) || n=0; printf '%s' "${n:-0}"; }
auto_calls() { auto_count 'argv:' "$1/runner.calls"; }
auto_merges() { auto_count 'pr merge ' "$1/gh.log"; }
auto_reviews() { auto_count '"kind":"review"' "$1/state/review-records.jsonl"; }
auto_event_file() {  # <case_dir>: the review-lane events the helper printed, as a file path
  auto_helper "$1" events
  cp "$1/helper.out" "$1/events.txt"
  printf '%s' "$1/events.txt"
}
auto_notes() { auto_count "$2" "$(auto_event_file "$1")"; }

test_auto_review_green_uncovered_pr_is_read_recorded_and_merged() {
  local case_dir rc
  case_dir=$(auto_case green-uncovered)
  auto_step "$case_dir"
  auto_wait "$case_dir"
  expect_code 1 "$(auto_calls "$case_dir")" "green-uncovered: exactly one read is requested"
  grep -qF "|$AUTO_URL|$(auto_sha "$case_dir" h1)|pr.diff|$case_dir/project|$AUTO_SONNET " "$case_dir/runner.calls" \
    || fail "green-uncovered: runner argv wrong (the OpenAI-authored head must go to the Claude entry): $(cat "$case_dir/runner.calls")"
  grep -Eq 'contract=[1-9][0-9]* ci=[1-9][0-9]* diff=[1-9][0-9]*' "$case_dir/runner.calls" \
    || fail "green-uncovered: the request omitted the contract, the CI evidence or the diff: $(cat "$case_dir/runner.calls")"
  grep -qF 'Fixture intent' "$case_dir"/state/.pr-auto-review/task-x1.d/*/contract.md \
    || fail "green-uncovered: the brief is not in the contract text"
  grep -qF 'G1 fixture item' "$case_dir"/state/.pr-auto-review/task-x1.d/*/contract.md \
    || fail "green-uncovered: the Definition Of Done is not in the contract text"
  grep -qF 'Main ruling fixture' "$case_dir"/state/.pr-auto-review/task-x1.d/*/contract.md \
    || fail "green-uncovered: the steering message is not in the contract text"
  grep -qF 'ci: status=COMPLETED conclusion=SUCCESS' "$case_dir"/state/.pr-auto-review/task-x1.d/*/ci-evidence.md \
    || fail "green-uncovered: the check runs at the head are not in the CI evidence"
  # A repeated pass while the read is out, and again after it returned, requests nothing more.
  auto_step "$case_dir"
  expect_code 1 "$(auto_calls "$case_dir")" "green-uncovered: a repeat pass made a duplicate request"
  expect_code 1 "$(auto_reviews "$case_dir")" "green-uncovered: the verdict must be recorded exactly once"
  expect_code 1 "$(auto_merges "$case_dir")" "green-uncovered: a covering PASS must merge exactly once"
  assert_logged_gh_merge "$case_dir" 9 example/repo --squash
  auto_step "$case_dir"
  expect_code 1 "$(auto_merges "$case_dir")" "green-uncovered: a pass after the merge made a second merge"
  expect_code 1 "$(auto_calls "$case_dir")" "green-uncovered: a pass after the merge made a duplicate request"
  rc=$(auto_state "$case_dir")
  case $rc in "merged $AUTO_URL") ;; *) fail "green-uncovered: current state should read merged with the full URL, got: $rc" ;; esac
  rc=$(auto_sha "$case_dir" h1)
  assert_grep "reading ${rc:0:12} by $AUTO_SONNET" "$(auto_event_file "$case_dir")" "green-uncovered: the request is not an event"
  assert_grep "verdict recorded: PASS for ${rc:0:12} by $AUTO_SONNET" "$(auto_event_file "$case_dir")" "green-uncovered: the verdict is not an event naming the served model"
  assert_grep "merged: $AUTO_URL" "$(auto_event_file "$case_dir")" "green-uncovered: the merge is not an event with the full URL"
  auto_dump "$case_dir" "G1/G3 green uncovered PR"
  pass "a green uncovered PR gets one read with its pack, a recorded PASS and one merge through fm-pr-merge.sh"
}

test_auto_review_makes_no_request_when_the_pr_is_not_ready() {
  local scenario case_dir sha
  for scenario in draft red pending unreported conflicting unregistered local-only closed covered-by-captain-word stale-diff; do
    case_dir=$(auto_case "none-$scenario")
    case $scenario in
      draft) jq '.isDraft = true' "$case_dir/github-view.json" > "$case_dir/v" && mv "$case_dir/v" "$case_dir/github-view.json" ;;
      red) jq '.mergeStateStatus = "UNSTABLE" | .statusCheckRollup[0].conclusion = "FAILURE"' "$case_dir/github-view.json" > "$case_dir/v" && mv "$case_dir/v" "$case_dir/github-view.json" ;;
      pending) jq '.statusCheckRollup[0].status = "IN_PROGRESS"' "$case_dir/github-view.json" > "$case_dir/v" && mv "$case_dir/v" "$case_dir/github-view.json" ;;
      unreported) jq '.mergeStateStatus = "BLOCKED"' "$case_dir/github-view.json" > "$case_dir/v" && mv "$case_dir/v" "$case_dir/github-view.json" ;;
      conflicting) jq '.mergeable = "CONFLICTING" | .mergeStateStatus = "DIRTY"' "$case_dir/github-view.json" > "$case_dir/v" && mv "$case_dir/v" "$case_dir/github-view.json" ;;
      unregistered) grep -v '^pr=' "$case_dir/state/task-x1.meta" > "$case_dir/m" && mv "$case_dir/m" "$case_dir/state/task-x1.meta" ;;
      local-only) sed -i.bak 's/^mode=.*/mode=local-only/' "$case_dir/state/task-x1.meta" ;;
      closed) jq '.state = "CLOSED"' "$case_dir/github-view.json" > "$case_dir/v" && mv "$case_dir/v" "$case_dir/github-view.json" ;;
      covered-by-captain-word) review_record_command "$case_dir" captain-word --pr "$AUTO_URL" --head "$(auto_sha "$case_dir" h1)" --words 'Merge it.' >/dev/null ;;
      # The forge names a head that the PR ref fm-review-diff.sh fetches does not hold.
      stale-diff) write_github_live_json "$case_dir" 3333333333333333333333333333333333333333 ;;
    esac
    auto_step "$case_dir"
    auto_step "$case_dir"
    if [ "$scenario" = stale-diff ]; then
      assert_grep 'review pack not built for 333333333333: diff unavailable: the PR head fm-review-diff.sh fetched is' "$(auto_event_file "$case_dir")" \
        "stale-diff: a diff of another head must not be sent to a reader"
      grep -q 'pr-review:task-x1:333333333333:pack:' "$case_dir/state/.wake-queue" || fail "stale-diff: the unbuilt pack did not wake Main"
    fi
    if [ "$scenario" = covered-by-captain-word ]; then
      sha=$(auto_sha "$case_dir" h1)
      assert_grep "held: a captain merge word is recorded at ${sha:0:12}" "$(auto_event_file "$case_dir")" \
        "covered-by-captain-word: the captain-word head is not held"
      expect_code 1 "$(auto_count "pr-review:task-x1:${sha:0:12}:captain-word" "$case_dir/state/.wake-queue")" \
        "covered-by-captain-word: two passes must wake Main exactly once for the head and reason"
    fi
    expect_code 0 "$(auto_calls "$case_dir")" "none-$scenario: a read was requested for a PR that is not ready or not the machinery's"
    expect_code 0 "$(auto_merges "$case_dir")" "none-$scenario: a merge command ran"
    expect_code 0 "$(auto_reviews "$case_dir")" "none-$scenario: a review record was written"
    auto_dump "$case_dir" "G1/G4 no request: $scenario"
  done
  pass "a draft, red, pending, unreported, conflicting, unregistered, local-only, closed or captain-worded PR, or one whose fetched diff is another head's, gets no read and no merge"
}

test_auto_review_unset_or_unusable_runner_records_one_reason_per_head() {
  local case_dir
  case_dir=$(auto_case runner-unset)
  : > "$case_dir/home/config/review-runner"
  auto_step "$case_dir"; auto_step "$case_dir"; auto_step "$case_dir"
  expect_code 0 "$(auto_calls "$case_dir")" "runner-unset: a read ran with no runner"
  expect_code 1 "$(auto_notes "$case_dir" 'review runner unavailable: FM_REVIEW_RUNNER and config/review-runner are both unset')" "runner-unset: one reason line per head"
  auto_dump "$case_dir" "G1 runner unset"
  case_dir=$(auto_case runner-missing)
  printf '%s\n' "$case_dir/not-there.sh" > "$case_dir/home/config/review-runner"
  auto_step "$case_dir"; auto_step "$case_dir"
  expect_code 1 "$(auto_notes "$case_dir" "is not an executable file")" "runner-missing: one line for the unusable path"
  auto_dump "$case_dir" "G1 runner path not executable"
  expect_code 0 "$(auto_calls "$case_dir")" "runner-missing: a read ran with no runner"
  case_dir=$(auto_case runner-relative)
  printf '%s\n' 'relative/run-review.sh' > "$case_dir/home/config/review-runner"
  auto_step "$case_dir"
  expect_code 1 "$(auto_notes "$case_dir" 'is not an absolute path')" "runner-relative: a relative runner path must be refused"
  case_dir=$(auto_case runner-env)
  : > "$case_dir/home/config/review-runner"
  FM_REVIEW_RUNNER="$case_dir/fake-runner.sh" auto_step "$case_dir"
  auto_wait "$case_dir"
  expect_code 1 "$(auto_calls "$case_dir")" "runner-env: the environment setting must name the runner"
  auto_dump "$case_dir" "G1 runner from FM_REVIEW_RUNNER"
  pass "an unset, relative or non-executable runner makes no request and records one reason per head; the setting is FM_REVIEW_RUNNER or config/review-runner"
}

auto_use_models() {  # <case_dir> <use-model>... [-- <fallback-model>...]: rewrite the review rule's candidates
  local case_dir=$1 use='' fallback='' target=use model
  shift
  for model in "$@"; do
    if [ "$model" = -- ]; then target=fallback; continue; fi
    if [ "$target" = use ]; then use="${use:+$use,}{\"model\":\"$model\"}"; else fallback="${fallback:+$fallback,}{\"model\":\"$model\"}"; fi
  done
  printf '{"rules":[{"when":"Isolated independent quality review of a specific pull request","use":[%s],"fallback":[%s]}]}\n' \
    "$use" "$fallback" > "$case_dir/home/config/crew-dispatch.json"
}

auto_mixed_authors() {  # <case_dir>: one ship group authored by an OpenAI and an Anthropic model
  printf 'g2\t\tgpt-5.1-codex\ng1\t\tclaude-opus-5-5\n' > "$1/state/task-x1.launch-models"
  sed -i.bak 's/^model=.*/model=gpt-5.1-codex/' "$1/state/task-x1.meta"
  printf 'spawn_gen=g2\n' >> "$1/state/task-x1.meta"
  printf 'g2\tg1\tgpt-5.1-codex\ng1\t\tclaude-opus-5-5\n' > "$1/state/task-x1.launch-models"
}

auto_runner_models() { sed -n 's/^argv: [^|]*|[^|]*|[^|]*|[^|]*|[^|]*|\([^ ]*\) .*/\1/p' "$1/runner.calls" | paste -sd, -; }

test_auto_review_chooses_readers_by_author_family() {
  local case_dir
  # Anthropic-authored: the first rule entry (OpenAI) covers it with one read.
  case_dir=$(auto_case fam-anthropic claude-opus-5-5)
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"
  expect_code "$AUTO_TERRA" "$(auto_runner_models "$case_dir")" "fam-anthropic: an Anthropic-authored head must go to the OpenAI entry"
  expect_code 1 "$(auto_merges "$case_dir")" "fam-anthropic: the covering PASS must merge"
  auto_dump "$case_dir" "G2 anthropic-authored"
  # Mixed OpenAI and Anthropic: the complementary pair, one read at a time, in rule order.
  case_dir=$(auto_case fam-mixed)
  auto_mixed_authors "$case_dir"
  auto_step "$case_dir"; auto_wait "$case_dir"
  expect_code "$AUTO_TERRA" "$(auto_runner_models "$case_dir")" "fam-mixed: the first read covers the Anthropic family"
  auto_step "$case_dir"; auto_wait "$case_dir"
  expect_code "$AUTO_TERRA,$AUTO_SONNET" "$(auto_runner_models "$case_dir")" "fam-mixed: the second read covers the OpenAI family"
  expect_code 0 "$(auto_merges "$case_dir")" "fam-mixed: a lone same-family gap must not merge"
  auto_step "$case_dir"
  expect_code 1 "$(auto_merges "$case_dir")" "fam-mixed: both families covered must merge once"
  auto_dump "$case_dir" "G2 mixed OpenAI+Anthropic (complementary pair)"
  # Mixed with a third-family reader: one read covers both.
  case_dir=$(auto_case fam-third)
  auto_mixed_authors "$case_dir"
  auto_use_models "$case_dir" "$AUTO_DEEPSEEK"
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"
  expect_code "$AUTO_DEEPSEEK" "$(auto_runner_models "$case_dir")" "fam-third: a reader outside both families covers both in one read"
  expect_code 1 "$(auto_merges "$case_dir")" "fam-third: must merge"
  auto_dump "$case_dir" "G2 mixed, one third-family reader"
  # A reader of the family to cover is never taken: only OpenAI entries for an OpenAI head.
  case_dir=$(auto_case fam-same)
  auto_use_models "$case_dir" "$AUTO_TERRA"
  auto_step "$case_dir"; auto_step "$case_dir"
  expect_code 0 "$(auto_calls "$case_dir")" "fam-same: a reader of the author's own family was requested"
  expect_code 1 "$(auto_notes "$case_dir" 'held: no eligible reader')" "fam-same: no eligible reader is recorded once"
  auto_dump "$case_dir" "G2 lone same-family gap"
  # An unreadable review rule is not an exhaustion: once the config is repaired the head is read.
  case_dir=$(auto_case fam-config)
  cp "$case_dir/home/config/crew-dispatch.json" "$case_dir/dispatch.json"
  printf '{not json\n' > "$case_dir/home/config/crew-dispatch.json"
  auto_step "$case_dir"; auto_step "$case_dir"
  expect_code 0 "$(auto_calls "$case_dir")" "fam-config: no read with an unreadable review rule"
  expect_code 1 "$(auto_notes "$case_dir" 'held: no eligible reader: config/crew-dispatch.json is unreadable')" "fam-config: reported once"
  cp "$case_dir/dispatch.json" "$case_dir/home/config/crew-dispatch.json"
  auto_step "$case_dir"; auto_wait "$case_dir"
  expect_code 1 "$(auto_calls "$case_dir")" "fam-config: a repaired config must be read on the same head"
  # Unknown author family: nothing can cover it, so no read, and one report.
  case_dir=$(auto_case fam-unknown mystery-9)
  auto_step "$case_dir"; auto_step "$case_dir"; auto_step "$case_dir"
  expect_code 0 "$(auto_calls "$case_dir")" "fam-unknown: a read was requested for an unknown author family"
  expect_code 1 "$(auto_notes "$case_dir" 'held: author family unknown')" "fam-unknown: reported once per head"
  # Repairing the author evidence lets the same head go on without a push.
  sed -i.bak 's/^model=.*/model=gpt-5.1-codex/' "$case_dir/state/task-x1.meta"
  auto_step "$case_dir"; auto_wait "$case_dir"
  expect_code 1 "$(auto_calls "$case_dir")" "fam-unknown: a repaired author family must be read on the same head"
  auto_dump "$case_dir" "G2 unknown author family"
  pass "readers differ from the family they cover, mixed heads use the complementary pair or one third-family reader, unknown and same-family gaps request nothing"
}

test_auto_review_switches_after_a_failed_read_and_never_retries_the_failed_model() {
  local case_dir
  case_dir=$(auto_case switch)
  auto_mode "$case_dir" "$AUTO_SONNET" quota
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"; auto_wait "$case_dir"
  auto_step "$case_dir"; auto_step "$case_dir"
  expect_code "$AUTO_SONNET,$AUTO_DEEPSEEK" "$(auto_runner_models "$case_dir")" "switch: the quota-failed model must not be retried; the next eligible model is used"
  expect_code 1 "$(auto_merges "$case_dir")" "switch: the second reader's PASS must merge"
  assert_grep '(usage limit reached)' "$(auto_event_file "$case_dir")" "switch: the quota failure is not an event"
  auto_dump "$case_dir" "G2 first model quota-failed, next eligible used"
  case_dir=$(auto_case switch-none)
  auto_mode "$case_dir" "$AUTO_SONNET" quota
  auto_mode "$case_dir" "$AUTO_DEEPSEEK" crash
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"; auto_wait "$case_dir"
  auto_step "$case_dir"; auto_step "$case_dir"; auto_step "$case_dir"
  expect_code "$AUTO_SONNET,$AUTO_DEEPSEEK" "$(auto_runner_models "$case_dir")" "switch-none: no model is asked twice and no loop follows"
  expect_code 1 "$(auto_notes "$case_dir" 'held: no eligible reader')" "switch-none: no eligible reader is recorded once"
  expect_code 0 "$(auto_merges "$case_dir")" "switch-none: nothing may merge"
  auto_dump "$case_dir" "G2 every model failed"
  case_dir=$(auto_case switch-actual)
  auto_mode "$case_dir" "$AUTO_SONNET" switched
  auto_mode "$case_dir" "$AUTO_DEEPSEEK" switched
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"
  expect_code 0 "$(auto_reviews "$case_dir")" "switch-actual: a PASS served by a same-family model covers nothing and must not be recorded"
  expect_code 0 "$(auto_merges "$case_dir")" "switch-actual: nothing may merge"
  assert_grep 'covers nothing' "$(auto_event_file "$case_dir")" "switch-actual: the unusable read is not an event"
  auto_dump "$case_dir" "G2/G3 runner served a same-family model"
  # A FAIL served by a same-family model still counts: recorded, the head ends at fail, no later PASS is sought.
  case_dir=$(auto_case switch-fail)
  auto_mode "$case_dir" "$AUTO_SONNET" switched-fail
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"; auto_step "$case_dir"
  expect_code 1 "$(auto_count '"verdict":"FAIL"' "$case_dir/state/review-records.jsonl")" "switch-fail: a same-family FAIL must be recorded as FAIL"
  expect_code "$AUTO_SONNET" "$(auto_runner_models "$case_dir")" "switch-fail: no further reader may be asked after a FAIL"
  grep -q '^fail ' <<<"$(auto_state "$case_dir")" || fail "switch-fail: current state should read fail: $(auto_state "$case_dir")"
  expect_code 0 "$(auto_merges "$case_dir")" "switch-fail: nothing may merge over a FAIL"
  auto_dump "$case_dir" "G3 same-family FAIL stands"
  pass "a failed or exhausted reader is not retried, the next eligible model is used, none left records no eligible reader, and the model that actually ran is the one judged"
}

test_auto_review_records_each_verdict_and_merges_only_a_covering_pass() {
  local mode case_dir
  for mode in fail fail-truncated incomplete wrong-head no-facts crlf; do
    case_dir=$(auto_case "verdict-$mode")
    auto_mode "$case_dir" "$AUTO_SONNET" "$mode"
    auto_mode "$case_dir" "$AUTO_DEEPSEEK" "$mode"
    auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"
    expect_code 0 "$(auto_merges "$case_dir")" "verdict-$mode: nothing may merge"
    auto_dump "$case_dir" "G3 report verdict: $mode"
    case $mode in
      fail)
        expect_code 1 "$(auto_count '"verdict":"FAIL"' "$case_dir/state/review-records.jsonl")" "verdict-$mode: the FAIL is recorded as FAIL"
        grep -q '^fail ' <<<"$(auto_state "$case_dir")" || fail "verdict-$mode: current state should read fail: $(auto_state "$case_dir")"
        grep -q "pr-review:task-x1:.*fail" "$case_dir/state/.wake-queue" || fail "verdict-$mode: the owner is not told through a wake"
        ;;
      fail-truncated)
        expect_code 0 "$(auto_reviews "$case_dir")" "verdict-$mode: a FAIL without its last line is not recorded"
        grep -q '^fail ' <<<"$(auto_state "$case_dir")" || fail "verdict-$mode: an unrecordable FAIL must still end the head at fail: $(auto_state "$case_dir")"
        auto_step "$case_dir"
        expect_code "$AUTO_SONNET" "$(auto_runner_models "$case_dir")" "verdict-$mode: no further reader may be asked after a FAIL"
        grep -q "pr-review:task-x1:.*fail" "$case_dir/state/.wake-queue" || fail "verdict-$mode: the owner is not told through a wake"
        ;;
      incomplete)
        expect_code 0 "$(auto_reviews "$case_dir")" "verdict-$mode: INCOMPLETE is never recorded"
        grep -q '^held: review INCOMPLETE' <<<"$(auto_state "$case_dir")" || fail "verdict-$mode: current state should read held: review INCOMPLETE"
        grep -q "pr-review:task-x1:.*incomplete" "$case_dir/state/.wake-queue" || fail "verdict-$mode: the report path is not routed through a wake"
        ;;
      *)
        expect_code 0 "$(auto_reviews "$case_dir")" "verdict-$mode: an unusable report is never recorded"
        auto_wait "$case_dir"; auto_step "$case_dir"; auto_step "$case_dir"
        expect_code "$AUTO_SONNET,$AUTO_DEEPSEEK" "$(auto_runner_models "$case_dir")" "verdict-$mode: the unusable reader is not asked again"
        ;;
    esac
  done
  # A yes to a declaration is a recorded fact, not a reason to hold.
  case_dir=$(auto_case verdict-loosens)
  auto_mode "$case_dir" "$AUTO_SONNET" loosens-yes
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"
  grep -q '"loosens_deny_allow_list":"yes"' "$case_dir/state/review-records.jsonl" || fail "verdict-loosens: the declaration is not recorded as yes"
  expect_code 1 "$(auto_merges "$case_dir")" "verdict-loosens: a yes declaration alone must not hold a covering PASS"
  auto_dump "$case_dir" "G3 PASS with a yes declaration"
  pass "FAIL and INCOMPLETE merge nothing and reach the owner, an unusable, CRLF or wrong-head PASS is never recorded, and a yes declaration is a fact not a hold"
}

test_auto_review_new_head_voids_the_pass_and_held_prs_are_never_merged() {
  local case_dir state
  # A push after the PASS: the old PASS no longer counts and the new head is read once.
  case_dir=$(auto_case head-moves)
  auto_step "$case_dir"; auto_wait "$case_dir"
  # A pending check holds the merge, so the pass that collects the old head's read records its PASS and stops.
  jq '.statusCheckRollup[0].status = "IN_PROGRESS"' "$case_dir/github-view.json" > "$case_dir/v" && mv "$case_dir/v" "$case_dir/github-view.json"
  auto_step "$case_dir"
  expect_code 1 "$(auto_reviews "$case_dir")" "head-moves: the PASS for the old head is recorded for the old head"
  auto_push "$case_dir"
  auto_step "$case_dir"
  expect_code 1 "$(auto_reviews "$case_dir")" "head-moves: the push records nothing more"
  expect_code 0 "$(auto_merges "$case_dir")" "head-moves: the old head's PASS must not merge the new head"
  auto_wait "$case_dir"
  expect_code 2 "$(auto_calls "$case_dir")" "head-moves: the new head is read under the same counting rule"
  auto_step "$case_dir"
  expect_code 1 "$(auto_merges "$case_dir")" "head-moves: the new head's own PASS merges"
  expect_code 0 "$(auto_count "match-head-commit $(auto_sha "$case_dir" h1)" "$case_dir/gh.log")" "head-moves: nothing may merge the old head"
  assert_logged_gh_merge "$case_dir" 9 example/repo --squash
  auto_dump "$case_dir" "G4 head moved after the PASS"
  # A refused merge (a moved base, a catch-up run) holds with its reason, backs off, then retries once.
  case_dir=$(auto_case merge-refused)
  printf '1\n' > "$case_dir/github-merge-rc"
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"
  expect_code 1 "$(auto_merges "$case_dir")" "merge-refused: one merge attempt"
  state=$(auto_state "$case_dir")
  case $state in "held: merge not landed"*) ;; *) fail "merge-refused: current state should read held: merge not landed, got: $state" ;; esac
  auto_step "$case_dir"; auto_step "$case_dir"
  expect_code 1 "$(auto_merges "$case_dir")" "merge-refused: no error loop inside the back-off"
  expect_code 1 "$(auto_count ':merge:' "$case_dir/state/.wake-queue")" "merge-refused: Main must be woken once for the refusal, not again while it is unchanged"
  rm -f "$case_dir/github-merge-rc"
  jq '.heads |= map_values(.merge.next_at = 0)' "$case_dir/state/.pr-auto-review/task-x1.json" > "$case_dir/s" && mv "$case_dir/s" "$case_dir/state/.pr-auto-review/task-x1.json"
  auto_step "$case_dir"
  expect_code 2 "$(auto_merges "$case_dir")" "merge-refused: one retry after the back-off"
  expect_code 1 "$(auto_reviews "$case_dir")" "merge-refused: the retry must not record a second verdict"
  auto_dump "$case_dir" "G4 merge refused, back-off, one retry"
  # A task or report marking a protected class is never merged and Main is told the class.
  case_dir=$(auto_case protected-task)
  printf 'protected=destructive\n' >> "$case_dir/state/task-x1.meta"
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"
  expect_code 0 "$(auto_merges "$case_dir")" "protected-task: a protected class must not merge"
  grep -q "pr-review:task-x1:.*protected" "$case_dir/state/.wake-queue" || fail "protected-task: silence about a held protected PR"
  assert_grep 'held: protected class destructive' "$(auto_event_file "$case_dir")" "protected-task: the class is not named"
  auto_dump "$case_dir" "G4 protected class from the task meta"
  # The report's protected-class answer: yes holds, and a missing or malformed line holds (fail closed).
  for mode in protected-yes protected-missing protected-malformed; do
    case_dir=$(auto_case "$mode")
    auto_mode "$case_dir" "$AUTO_SONNET" "$mode"
    auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"; auto_step "$case_dir"
    expect_code 1 "$(auto_reviews "$case_dir")" "$mode: the PASS is still recorded"
    expect_code 0 "$(auto_merges "$case_dir")" "$mode: the merge must be held"
    grep -q "pr-review:task-x1:.*protected" "$case_dir/state/.wake-queue" || fail "$mode: Main is not woken"
    case $mode in
      protected-yes) state='held: protected class yes - security-sensitive fixture' ;;
      protected-missing) state='held: protected class line missing in a report' ;;
      protected-malformed) state='held: protected class line malformed in a report' ;;
    esac
    assert_grep "$state" "$(auto_event_file "$case_dir")" "$mode: the hold does not name its reason"
    auto_dump "$case_dir" "G4 report protected-class answer: $mode"
  done
  pass "a new head voids the old PASS, a refused merge backs off and retries once, and a protected class, or a missing or malformed answer, is held and named"
}

test_auto_review_survives_slow_hung_and_killed_readers() {
  local case_dir started elapsed state
  case_dir=$(auto_case hung)
  auto_mode "$case_dir" "$AUTO_SONNET" hang
  started=$(date +%s)
  auto_step "$case_dir"
  elapsed=$(($(date +%s) - started))
  [ "$elapsed" -le 20 ] || fail "hung: the pass waited on the reader ($elapsed s)"
  for n in $(seq 1 50); do [ -s "$case_dir/runner.pid" ] && break; sleep 0.1; done
  state=$(auto_sha "$case_dir" h1)
  case $(auto_state "$case_dir") in "reading ${state:0:12} by $AUTO_SONNET") ;; *) fail "hung: current state should read reading, got: $(auto_state "$case_dir")" ;; esac
  auto_step "$case_dir"; auto_step "$case_dir"
  expect_code 1 "$(auto_calls "$case_dir")" "hung: a read still out must not be requested again"
  # Another task's pass runs while this reader hangs.
  cp "$case_dir/state/task-x1.meta" "$case_dir/state/task-x2.meta"
  sed -i.bak 's#^pr=.*#pr=https://github.com/example/repo/pull/10#' "$case_dir/state/task-x2.meta"
  started=$(date +%s)
  AUTO_TASK=task-x2 auto_helper "$case_dir" step || fail "hung: another task's pass failed"
  [ "$(($(date +%s) - started))" -le 20 ] || fail "hung: a hung reader stalled another task's pass"
  # A push while the old head's read hangs: the new head is read on the normal cadence.
  auto_push "$case_dir"
  auto_step "$case_dir"
  for n in $(seq 1 50); do [ "$(auto_calls "$case_dir")" -ge 2 ] && break; sleep 0.1; done
  expect_code 2 "$(auto_calls "$case_dir")" "hung: a new head must get its own read while the old head's read hangs"
  state=$(auto_sha "$case_dir" h2)
  case $(auto_state "$case_dir") in "reading ${state:0:12} by $AUTO_SONNET") ;; *) fail "hung: current state should read the new head, got: $(auto_state "$case_dir")" ;; esac
  : > "$case_dir/runner.release"
  auto_wait "$case_dir"; auto_step "$case_dir"
  expect_code 1 "$(auto_reviews "$case_dir")" "hung: only the live head's read is recorded; the superseded head's read is not"
  expect_code 1 "$(auto_merges "$case_dir")" "hung: only the new head merges, once"
  assert_logged_gh_merge "$case_dir" 9 example/repo --squash
  auto_dump "$case_dir" "G5 hung reader, new head read meanwhile, both released late"
  # The old head's read returns after the new head's PASS is recorded: it is never recorded and the new head still merges.
  case_dir=$(auto_case late-old)
  auto_sha "$case_dir" h1 > "$case_dir/hang-head"
  printf '1\n' > "$case_dir/github-merge-rc"
  auto_step "$case_dir"
  for n in $(seq 1 50); do [ -s "$case_dir/runner.pid" ] && break; sleep 0.1; done
  auto_push "$case_dir"
  auto_step "$case_dir"
  state=$(auto_sha "$case_dir" h2)
  for n in $(seq 1 150); do [ -f "$case_dir/state/.pr-auto-review/task-x1.d/${state:0:12}-$(auto_slug "$AUTO_SONNET").run/result.json" ] && break; sleep 0.2; done
  auto_step "$case_dir"
  expect_code 1 "$(auto_reviews "$case_dir")" "late-old: the new head's PASS is recorded"
  expect_code 1 "$(auto_merges "$case_dir")" "late-old: the first merge attempt is refused"
  : > "$case_dir/runner.release"
  auto_wait "$case_dir"
  rm -f "$case_dir/github-merge-rc"
  jq '.heads |= map_values(.merge.next_at = 0)' "$case_dir/state/.pr-auto-review/task-x1.json" > "$case_dir/s" && mv "$case_dir/s" "$case_dir/state/.pr-auto-review/task-x1.json"
  auto_step "$case_dir"
  expect_code 1 "$(auto_reviews "$case_dir")" "late-old: the superseded head's late read must not be recorded"
  expect_code 2 "$(auto_merges "$case_dir")" "late-old: the new head must still merge after the old read returns"
  expect_code "merged $AUTO_URL" "$(auto_state "$case_dir")" "late-old: the live head merges"
  state=$(auto_sha "$case_dir" h1)
  expect_code 0 "$(auto_count "pr-review:task-x1:${state:0:12}" "$case_dir/state/.wake-queue")" "late-old: the superseded head must not wake Main"
  auto_dump "$case_dir" "G5 old head's read returns after the new head's PASS"
  # A reader killed after its request: the model is not retried, the next eligible model is.
  case_dir=$(auto_case killed)
  auto_mode "$case_dir" "$AUTO_SONNET" hang
  auto_step "$case_dir"
  for n in $(seq 1 50); do [ -s "$case_dir/runner.pid" ] && break; sleep 0.1; done
  pkill -9 -f "fm-pr-auto-review.py _read $case_dir" || true
  kill -9 "$(cat "$case_dir/runner.pid")" 2>/dev/null || true
  for dir in "$case_dir"/state/.pr-auto-review/task-x1.d/*.run; do : > "$dir/killed"; done
  sleep 0.5
  auto_mode "$case_dir" "$AUTO_SONNET" pass
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"
  expect_code "$AUTO_SONNET,$AUTO_DEEPSEEK" "$(auto_runner_models "$case_dir")" "killed: the killed model must not be asked again for the head"
  expect_code 1 "$(auto_merges "$case_dir")" "killed: the next eligible reader's PASS merges once"
  auto_dump "$case_dir" "G5 reader killed after its request"
  # A kill after the record but before the sidecar saved it, then after the merge: no second record, no second merge.
  case_dir=$(auto_case replay)
  printf '1\n' > "$case_dir/github-merge-rc"
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"
  expect_code 1 "$(auto_reviews "$case_dir")" "replay: one verdict recorded"
  jq '.heads |= map_values(.attempts |= map_values(.state = "requested") | .merge.next_at = 0)' "$case_dir/state/.pr-auto-review/task-x1.json" > "$case_dir/s" \
    && mv "$case_dir/s" "$case_dir/state/.pr-auto-review/task-x1.json"
  rm -f "$case_dir/github-merge-rc"
  auto_step "$case_dir"
  expect_code 1 "$(auto_reviews "$case_dir")" "replay: a replayed collection must not record a second verdict"
  expect_code 1 "$(auto_calls "$case_dir")" "replay: a replayed collection must not request a second read"
  expect_code 2 "$(auto_merges "$case_dir")" "replay: the refused merge is retried once"
  jq '.state = "MERGED"' "$case_dir/github-view.json" > "$case_dir/v" && mv "$case_dir/v" "$case_dir/github-view.json"
  jq '.heads |= map_values(del(.outcome))' "$case_dir/state/.pr-auto-review/task-x1.json" > "$case_dir/s" && mv "$case_dir/s" "$case_dir/state/.pr-auto-review/task-x1.json"
  auto_step "$case_dir"; auto_step "$case_dir"
  expect_code 2 "$(auto_merges "$case_dir")" "replay: a merge already landed on the forge must not be merged again"
  state=$(auto_state "$case_dir")
  case $state in "merged $AUTO_URL") ;; *) fail "replay: a landed merge should read merged, got: $state" ;; esac
  auto_dump "$case_dir" "G5 replay after record, after merge"
  pass "a hung reader stalls nothing and is not duplicated, a killed reader is not retried, and a replay after a kill records and merges exactly once"
}

test_auto_review_leaves_the_away_record_to_the_merge_script() {
  local case_dir state
  case_dir=$(auto_case away)
  auto_step "$case_dir"; auto_wait "$case_dir"
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" "$ROOT/bin/fm-afk-contract.sh" enter --words 'merge task-x1 when green' >/dev/null \
    || fail "away: could not enter the away posture"
  auto_step "$case_dir"
  expect_code 1 "$(auto_reviews "$case_dir")" "away: the verdict is recorded"
  expect_code 0 "$(auto_notes "$case_dir" 'away posture')" "away: the machinery must not hold on the away record itself"
  state=$(auto_state "$case_dir")
  case $state in "merged $AUTO_URL"|"held: merge not landed: "*) ;; *) fail "away: fm-pr-merge.sh must decide under the away record, got: $state" ;; esac
  auto_dump "$case_dir" "G4 away record left to fm-pr-merge.sh"
  # Quiet mode is a present captain: nothing is held.
  case_dir=$(auto_case quiet)
  FM_AFK_MODE=quiet FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" "$ROOT/bin/fm-afk-contract.sh" enter >/dev/null || fail "quiet: could not enter quiet mode"
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"
  expect_code 1 "$(auto_merges "$case_dir")" "quiet: a present captain must not hold the merge"
  pass "an away record is left to fm-pr-merge.sh's own away handling, and quiet mode holds nothing"
}

test_auto_review_trusts_only_a_structured_served_model() {
  local mode case_dir
  for mode in no-served bad-served prose-only; do
    case_dir=$(auto_case "served-$mode")
    auto_mode "$case_dir" "$AUTO_SONNET" "$mode"
    auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"; auto_step "$case_dir"
    expect_code 0 "$(auto_reviews "$case_dir")" "served-$mode: a read with no structured served model must not be recorded"
    expect_code 0 "$(auto_merges "$case_dir")" "served-$mode: nothing may merge"
    expect_code "$AUTO_SONNET" "$(auto_runner_models "$case_dir")" "served-$mode: no further read may be requested for the head"
    case $(auto_state "$case_dir") in "held: served model unknown for the read requested from $AUTO_SONNET, report "*) ;;
      *) fail "served-$mode: current state should read held: served model unknown, got: $(auto_state "$case_dir")" ;; esac
    grep -q 'pr-review:task-x1:.*served-model-unknown' "$case_dir/state/.wake-queue" || fail "served-$mode: Main is not woken"
    auto_dump "$case_dir" "G2/G3 served model: $mode"
  done
  pass "only one exact 'served-model:' stdout line names the reader; a missing, malformed or prose-only notice holds the head for Main"
}

test_auto_review_waits_on_a_merge_queue_and_keeps_heads_it_needs() {
  local case_dir n
  # fm-pr-merge.sh reports the PR queued: not merged yet, and not called again while it stays queued.
  case_dir=$(auto_case queued)
  write_github_outcome "$case_dir" OPEN false true main
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"
  expect_code 1 "$(auto_merges "$case_dir")" "queued: one merge call"
  expect_code "queued $AUTO_URL" "$(auto_state "$case_dir")" "queued: a queued PR must not read as merged"
  auto_step "$case_dir"; auto_step "$case_dir"
  expect_code 1 "$(auto_merges "$case_dir")" "queued: no second merge call while the PR stays queued"
  jq '.state = "MERGED"' "$case_dir/github-view.json" > "$case_dir/v" && mv "$case_dir/v" "$case_dir/github-view.json"
  auto_step "$case_dir"
  expect_code "merged $AUTO_URL" "$(auto_state "$case_dir")" "queued: the forge's merged state resolves the queue"
  auto_dump "$case_dir" "G5 merge queue"
  # Six newer-looking heads in the sidecar never prune the head being read.
  case_dir=$(auto_case prune)
  auto_mode "$case_dir" "$AUTO_SONNET" hang
  auto_step "$case_dir"
  for n in $(seq 1 50); do [ -s "$case_dir/runner.pid" ] && break; sleep 0.1; done
  jq --argjson now "$(($(date +%s) + 1000))" '.heads += ([range(6)] | map({key: ("f" * 39 + (. | tostring)), value: {attempts: {}, emitted: [], outcome: null, seen: $now}}) | from_entries)' \
    "$case_dir/state/.pr-auto-review/task-x1.json" > "$case_dir/s" && mv "$case_dir/s" "$case_dir/state/.pr-auto-review/task-x1.json"
  auto_step "$case_dir"; auto_step "$case_dir"
  : > "$case_dir/runner.release"
  auto_wait "$case_dir"; auto_step "$case_dir"
  expect_code 1 "$(auto_calls "$case_dir")" "prune: pruning lost the head being read and requested it again"
  expect_code 1 "$(auto_merges "$case_dir")" "prune: the head being read merges once"
  pass "a queued PR reads queued and is not merged again until the forge resolves it, and pruning never drops the head being read"
}

test_auto_review_holds_a_head_that_leaves_the_merge_queue_still_open() {
  local case_dir
  # fm-pr-merge.sh queues the PR; someone removes it from the queue by hand, so the PR is open and out of the queue.
  case_dir=$(auto_case left-queue)
  write_github_outcome "$case_dir" OPEN false true main
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"
  expect_code 1 "$(auto_merges "$case_dir")" "left-queue: one merge call queues the PR"
  expect_code "queued $AUTO_URL" "$(auto_state "$case_dir")" "left-queue: the PR reads queued"
  expect_code 0 "$(auto_count ':left-queue' "$case_dir/state/.wake-queue")" "left-queue: no wake while the PR stays queued"
  write_github_outcome "$case_dir" OPEN false false main
  auto_step "$case_dir"; auto_step "$case_dir"; auto_step "$case_dir"
  expect_code 1 "$(auto_merges "$case_dir")" "left-queue: fm-pr-merge.sh must not be called again for a head that left the queue"
  expect_code 1 "$(auto_count ':left-queue' "$case_dir/state/.wake-queue")" "left-queue: Main is woken once"
  expect_code "held: left the merge queue and is still open" "$(auto_state "$case_dir")" "left-queue: the state reads held"
  expect_code 1 "$(auto_notes "$case_dir" 'left the merge queue')" "left-queue: one event"
  assert_grep "$AUTO_URL" "$case_dir/state/.wake-queue" "left-queue: the wake names the full PR URL"
  # A new head is judged fresh: its read is requested.
  auto_push "$case_dir"
  auto_step "$case_dir"; auto_wait "$case_dir"
  expect_code 2 "$(auto_calls "$case_dir")" "left-queue: a new head must be read on its own"
  expect_code 1 "$(auto_count ':left-queue' "$case_dir/state/.wake-queue")" "left-queue: the new head adds no left-queue wake"
  auto_dump "$case_dir" "queue exit held once"
  # A head that left the queue because it merged still ends merged, with no hold and no wake.
  case_dir=$(auto_case left-queue-merged)
  write_github_outcome "$case_dir" OPEN false true main
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"
  write_github_outcome "$case_dir" MERGED true false main
  auto_step "$case_dir"; auto_step "$case_dir"
  expect_code "queued $AUTO_URL" "$(auto_state "$case_dir")" "left-queue-merged: a PR the forge now reports merged is not held while the view still reads open"
  expect_code 0 "$(auto_count ':left-queue' "$case_dir/state/.wake-queue")" "left-queue-merged: no hold wake"
  jq '.state = "MERGED"' "$case_dir/github-view.json" > "$case_dir/v" && mv "$case_dir/v" "$case_dir/github-view.json"
  auto_step "$case_dir"
  expect_code "merged $AUTO_URL" "$(auto_state "$case_dir")" "left-queue-merged: the merged head ends merged"
  expect_code 1 "$(auto_merges "$case_dir")" "left-queue-merged: still one merge call"
  expect_code 0 "$(auto_count ':left-queue' "$case_dir/state/.wake-queue")" "left-queue-merged: no hold wake after the merge"
  pass "a head that leaves the merge queue still open is held once with one wake and never merged again; a head that merged still ends merged"
}

test_auto_review_events_reach_the_fleet_ledger() {
  local case_dir
  case_dir=$(auto_case ledger)
  : > "$case_dir/home/config/fleet-ledger"
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"
  grep -q 'merged' "$case_dir/state/fleet-ledger.jsonl" 2>/dev/null \
    || fail "ledger: the merge did not reach the fleet ledger through fm-pr-merge.sh: $(cat "$case_dir/state/fleet-ledger.jsonl" 2>&1 | head -3)"
  grep -q "$AUTO_URL" "$case_dir/state/fleet-ledger.jsonl" || fail "ledger: the merged record does not carry the full PR URL"
  # The worker's own status log is never written: a trailing note there would displace its done: line.
  [ ! -e "$case_dir/state/task-x1.status" ] || fail "status: the machinery wrote to the worker's status log: $(cat "$case_dir/state/task-x1.status")"
  auto_dump "$case_dir" "G5 merge reaches the fleet ledger, events stay in the sidecar"
  pass "the merge reaches the fleet ledger, the events stay in the sidecar, and the worker's status log is never written"
}

test_auto_review_three_prs_through_the_housekeeping_pass() {
  local p1 p2 p3 p4 n saved=$PR_MERGE
  # FAKE reader, fake forge, the real housekeeping pass, fm-pr-check.sh registration, fm-review-record.py and fm-pr-merge.sh. One home per PR.
  auto_reconcile() { PR_MERGE=$ROOT/bin/fm-pr-ready-reconcile.sh; FM_AUTO_CASE="$1" FM_PR_AUTO_REVIEW_INTERVAL=0 FM_PR_READY_RECONCILE_TIMEOUT=60 run_pr_merge "$1" > "$1/pass.out" 2>&1 || fail "$1: the housekeeping pass failed: $(cat "$1/pass.out")"; PR_MERGE=$saved; }
  # Each ship has reported its PR in a done line and has no pr= yet, so the real fm-pr-check.sh must register it.
  auto_unregistered() { sed -i.bak '/^pr=/d' "$1/state/task-x1.meta"; printf 'done [at=1792479210]: PR %s checks green at %s\n' "$AUTO_URL" "$(auto_sha "$1" h1)" > "$1/state/task-x1.status"; }
  p1=$(auto_case e2e-p1); p2=$(auto_case e2e-p2); p3=$(auto_case e2e-p3)
  auto_unregistered "$p1"; auto_unregistered "$p2"; auto_unregistered "$p3"
  auto_mode "$p2" "$AUTO_SONNET" fail
  auto_reconcile "$p1"; auto_reconcile "$p2"; auto_reconcile "$p3"
  for n in "$p1" "$p2" "$p3"; do
    grep -q "^pr=$AUTO_URL\$" "$n/state/task-x1.meta" || fail "e2e: fm-pr-check.sh did not register $AUTO_URL for $n: $(cat "$n/pass.out")"
    assert_grep 'registered' "$n/pass.out" "e2e: the housekeeping pass did not report a registration"
  done
  expect_code 0 "$(auto_calls "$p1")" "e2e: registration alone requests no read"
  # The fail case of the same path: a draft PR is not registered by fm-pr-check.sh, so it is never read.
  p4=$(auto_case e2e-p4)
  auto_unregistered "$p4"
  jq '.isDraft = true' "$p4/github-view.json" > "$p4/v" && mv "$p4/v" "$p4/github-view.json"
  auto_reconcile "$p4"
  if grep -q '^pr=' "$p4/state/task-x1.meta"; then fail "e2e P4: a draft PR was registered: $(cat "$p4/pass.out")"; fi
  grep -q 'registration refused' "$p4/pass.out" || fail "e2e P4: the refusal is not reported: $(cat "$p4/pass.out")"
  expect_code 0 "$(auto_calls "$p4")" "e2e P4: an unregistered draft is never read"
  expect_code 0 "$(auto_merges "$p4")" "e2e P4: an unregistered draft never merges"
  auto_reconcile "$p1"; auto_reconcile "$p2"; auto_reconcile "$p3"
  auto_wait "$p1"; auto_wait "$p2"; auto_wait "$p3"
  # P3's check is still running when its read returns, so the pass that collects the read records the PASS and merges nothing.
  jq '.statusCheckRollup[0].status = "IN_PROGRESS"' "$p3/github-view.json" > "$p3/v" && mv "$p3/v" "$p3/github-view.json"
  auto_reconcile "$p1"; auto_reconcile "$p2"; auto_reconcile "$p3"
  expect_code 1 "$(auto_reviews "$p3")" "e2e P3: the old head's PASS is recorded before the push"
  expect_code 0 "$(auto_merges "$p3")" "e2e P3: nothing merges while its check is pending"
  auto_push "$p3"
  auto_reconcile "$p3"
  auto_wait "$p3"
  auto_reconcile "$p3"
  printf 'g6 FAKE reader, fake forge, real housekeeping pass with fm-pr-check.sh registration, record and merge scripts\n'
  printf 'g6 P1 green+uncovered : state=%s merges=%s reviews=%s\n' "$(auto_state "$p1")" "$(auto_merges "$p1")" "$(auto_reviews "$p1")"
  printf 'g6 P2 green+FAIL      : state=%s merges=%s reviews=%s wake=%s\n' "$(auto_state "$p2")" "$(auto_merges "$p2")" "$(auto_reviews "$p2")" "$(grep -c 'pr-review:task-x1' "$p2/state/.wake-queue")"
  printf 'g6 P3 head moved      : state=%s merges=%s reviews=%s reads=%s merged-head=%s\n' "$(auto_state "$p3")" "$(auto_merges "$p3")" "$(auto_reviews "$p3")" "$(auto_calls "$p3")" "$(sed -n 's/.*--match-head-commit \([0-9a-f]*\).*/\1/p' "$p3/gh.log")"
  expect_code 1 "$(auto_merges "$p1")" "e2e P1: read, PASS, merge"
  expect_code 0 "$(auto_merges "$p2")" "e2e P2: a FAIL must not merge"
  expect_code 1 "$(auto_merges "$p3")" "e2e P3: only the new head's PASS merges"
  expect_code 2 "$(auto_reviews "$p3")" "e2e P3: the old head's PASS and the new head's PASS are both recorded"
  expect_code 2 "$(auto_calls "$p3")" "e2e P3: the old head and the new head are each read once"
  expect_code "$(auto_sha "$p3" h2)" "$(sed -n 's/.*--match-head-commit \([0-9a-f]*\).*/\1/p' "$p3/gh.log")" "e2e P3: the merge names the new head"
  pass "three registered PRs run through the housekeeping pass: P1 merged, P2 FAIL not merged and owner told, P3 old PASS voided and new head merged once"
}

# Round 4 (Main 3137): behavior tests, each with a fail case and a pass case.

auto_report() {  # <file> <head> <PASS|FAIL> [<protected line>]: a complete exact-head report that this lane did not write
  local file=$1 head=$2 word=$3 line=${4-}
  {
    printf 'VERDICT: %s head=%s\n' "$word" "$head"
    printf 'External reader report.\n'
    printf -- '- Loosens a deny or allow list: no - fixture\n'
    printf -- '- Widens what a guard permits: no - fixture\n'
    printf -- '- Touches customer data, billing or spend: no - fixture\n'
    [ -z "$line" ] || printf '%s\n' "$line"
    printf 'VERDICT: %s\n' "$word"
  } > "$file"
}

auto_record_external() {  # <case_dir> <report> <PASS|FAIL> <reader-model> <authors-json> <covered-json>
  local case_dir=$1 report=$2 word=$3 reader=$4 groups=$5 covered=$6
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" "$ROOT/bin/fm-review-record.py" review \
    --pr "$AUTO_URL" --head "$(cat "$case_dir/github-head")" --verdict "$word" --reader-model "$reader" \
    --author-groups "$groups" --covered-groups "$covered" --loosens-deny-allow-list no --widens-guard no \
    --customer-data-billing-spend no --report "$report" > "$case_dir/external.out" 2>&1 \
    || fail "recording an external review failed: $(cat "$case_dir/external.out")"
}

auto_wakes() { auto_count 'pr-review:task-x1' "$1/state/.wake-queue"; }

test_auto_review_protected_class_counts_every_recorded_review() {
  local case_dir head authors='{"ship":["gpt-5.1-codex","claude-opus-5-5"]}'
  # F1, fail case: an earlier recorded PASS that said yes is never cleared by a later reader that said no.
  case_dir=$(auto_case prot-ext-yes)
  auto_mixed_authors "$case_dir"
  head=$(auto_sha "$case_dir" h1)
  auto_report "$case_dir/external.md" "$head" PASS 'Protected class: yes - security-sensitive fixture'
  auto_record_external "$case_dir" "$case_dir/external.md" PASS "$AUTO_TERRA" "$authors" '["ship"]'
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"; auto_step "$case_dir"
  expect_code "$AUTO_SONNET" "$(auto_runner_models "$case_dir")" "prot-ext-yes: the lane reads only the family the external PASS left uncovered"
  expect_code 2 "$(auto_reviews "$case_dir")" "prot-ext-yes: the covering PASS is recorded beside the external one"
  expect_code 0 "$(auto_merges "$case_dir")" "prot-ext-yes: a later 'no' must not merge a head an earlier review marked protected"
  case $(auto_state "$case_dir") in "held: protected class yes - security-sensitive fixture"*) ;;
    *) fail "prot-ext-yes: current state should name the earlier answer, got: $(auto_state "$case_dir")" ;; esac
  expect_code 1 "$(auto_count ':protected' "$case_dir/state/.wake-queue")" "prot-ext-yes: Main is woken once for the hold"
  auto_dump "$case_dir" "F1 earlier recorded review said yes, later lane review said no"
  # F1, pass case: when every recorded review said no, the same sequence merges.
  case_dir=$(auto_case prot-ext-no)
  auto_mixed_authors "$case_dir"
  head=$(auto_sha "$case_dir" h1)
  auto_report "$case_dir/external.md" "$head" PASS 'Protected class: no - routine'
  auto_record_external "$case_dir" "$case_dir/external.md" PASS "$AUTO_TERRA" "$authors" '["ship"]'
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"
  expect_code 2 "$(auto_reviews "$case_dir")" "prot-ext-no: both reviews are recorded"
  expect_code 1 "$(auto_merges "$case_dir")" "prot-ext-no: every recorded answer is no, so the covering PASS merges"
  auto_dump "$case_dir" "F1 every recorded review said no"
  # F1, fail case: an external FAIL or PASS with no protected-class line is insufficient evidence.
  case_dir=$(auto_case prot-ext-missing)
  auto_mixed_authors "$case_dir"
  head=$(auto_sha "$case_dir" h1)
  auto_report "$case_dir/external.md" "$head" PASS ''
  auto_record_external "$case_dir" "$case_dir/external.md" PASS "$AUTO_TERRA" "$authors" '["ship"]'
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"; auto_step "$case_dir"
  expect_code 0 "$(auto_merges "$case_dir")" "prot-ext-missing: an external review with no protected-class answer holds the merge"
  assert_grep 'protected class line missing' "$(auto_event_file "$case_dir")" "prot-ext-missing: the hold does not say what is missing"
  pass "every exact-head recorded review counts: any yes or missing protected-class answer holds, and all-no evidence merges"
}

test_auto_review_reaches_the_merge_gate_on_a_recorded_routine_pass() {
  local case_dir scenario report
  # F5, pass case: an applicable recorded routine PASS that verify accepts proceeds to the merge gate with no sidecar attempt.
  case_dir=$(auto_case prot-recorded-routine)
  auto_step "$case_dir"; auto_wait "$case_dir"
  jq '.statusCheckRollup[0].status = "IN_PROGRESS"' "$case_dir/github-view.json" > "$case_dir/v" && mv "$case_dir/v" "$case_dir/github-view.json"
  auto_step "$case_dir"
  expect_code 1 "$(auto_reviews "$case_dir")" "prot-recorded-routine: the PASS is recorded while a check is pending"
  expect_code 0 "$(auto_merges "$case_dir")" "prot-recorded-routine: nothing merges while a check is pending"
  rm -f "$case_dir/state/.pr-auto-review/task-x1.json"
  jq '.statusCheckRollup[0].status = "COMPLETED"' "$case_dir/github-view.json" > "$case_dir/v" && mv "$case_dir/v" "$case_dir/github-view.json"
  auto_step "$case_dir"
  expect_code 1 "$(auto_merges "$case_dir")" "prot-recorded-routine: a recorded routine PASS with an explicit 'no' reaches the merge gate"
  expect_code 1 "$(auto_calls "$case_dir")" "prot-recorded-routine: no second read is requested"
  auto_dump "$case_dir" "F5 recorded routine PASS, no sidecar attempt"
  # F5, fail cases: a recorded PASS whose report changed after it was recorded, or is gone, is insufficient evidence.
  for scenario in tampered gone; do
    case_dir=$(auto_case "prot-recorded-$scenario")
    auto_step "$case_dir"; auto_wait "$case_dir"
    jq '.statusCheckRollup[0].status = "IN_PROGRESS"' "$case_dir/github-view.json" > "$case_dir/v" && mv "$case_dir/v" "$case_dir/github-view.json"
    auto_step "$case_dir"
    rm -f "$case_dir/state/.pr-auto-review/task-x1.json"
    jq '.statusCheckRollup[0].status = "COMPLETED"' "$case_dir/github-view.json" > "$case_dir/v" && mv "$case_dir/v" "$case_dir/github-view.json"
    for report in "$case_dir"/state/.pr-auto-review/task-x1.d/*/review.md; do
      if [ "$scenario" = tampered ]; then sed -i.bak 's/read the pack/read another pack/' "$report"; else rm -f "$report"; fi
    done
    auto_step "$case_dir"; auto_step "$case_dir"
    expect_code 0 "$(auto_merges "$case_dir")" "prot-recorded-$scenario: unverifiable report evidence must hold the merge"
    case $(auto_state "$case_dir") in "held: "*) ;; *) fail "prot-recorded-$scenario: current state should be a hold, got: $(auto_state "$case_dir")" ;; esac
    expect_code 1 "$(auto_count ':protected' "$case_dir/state/.wake-queue")" "prot-recorded-$scenario: Main is woken once"
  done
  pass "a recorded routine PASS that verify accepts reaches the merge gate with no sidecar attempt, and unverifiable report evidence holds"
}

test_auto_review_incomplete_review_pack_is_held_and_never_dispatched() {
  local case_dir scenario n
  # F2: a contract source that is absent holds the head and surfaces it; no reader is dispatched.
  for scenario in no-brief empty-brief no-dod dod-md missing-pointer empty-pointer; do
    case_dir=$(auto_case "pack-$scenario")
    case $scenario in
      no-brief) rm "$case_dir/home/data/task-x1/brief.md" ;;
      empty-brief) : > "$case_dir/home/data/task-x1/brief.md" ;;
      no-dod) auto_write_brief "$case_dir" ;;
      dod-md) auto_write_brief "$case_dir"; printf '## Definition Of Done\nG1 fixture item.\n' > "$case_dir/home/data/task-x1/dod.md" ;;
      missing-pointer) auto_write_brief "$case_dir" "DoD file: $case_dir/home/data/missing-dod.md" ;;
      empty-pointer) auto_write_brief "$case_dir" "DoD file: $case_dir/home/data/empty-dod.md"; : > "$case_dir/home/data/empty-dod.md" ;;
    esac
    auto_step "$case_dir"; auto_step "$case_dir"
    expect_code 0 "$(auto_calls "$case_dir")" "pack-$scenario: no reader may be dispatched on an incomplete contract"
    n=$(ls -d "$case_dir"/state/.pr-auto-review/task-x1.d/*.run 2>/dev/null | wc -l | tr -d ' ')
    expect_code 0 "$n" "pack-$scenario: no request may be written"
    expect_code 0 "$(auto_merges "$case_dir")" "pack-$scenario: nothing may merge"
    case $(auto_state "$case_dir") in "held: review pack not built: "*) ;;
      *) fail "pack-$scenario: current state should read held: review pack not built, got: $(auto_state "$case_dir")" ;; esac
    expect_code 1 "$(auto_wakes "$case_dir")" "pack-$scenario: Main is woken once"
  done
  # F2, pass case: a complete contract is dispatched, and a repaired contract is read on the same head.
  case_dir=$(auto_case pack-repaired)
  mv "$case_dir/home/data/task-x1/brief.md" "$case_dir/brief.saved"
  auto_step "$case_dir"
  expect_code 0 "$(auto_calls "$case_dir")" "pack-repaired: nothing dispatched while the brief is absent"
  mv "$case_dir/brief.saved" "$case_dir/home/data/task-x1/brief.md"
  auto_step "$case_dir"; auto_wait "$case_dir"
  expect_code 1 "$(auto_calls "$case_dir")" "pack-repaired: the complete contract is read on the same head"
  pass "an incomplete review pack is held with its missing source and never dispatched; a complete or repaired one is read"
}

test_auto_review_reads_the_definition_of_done_as_fm_dod_lib_does() {
  local case_dir scenario contract
  for scenario in inline fenced-pointer pointer outside-pointer dod-file-only; do
    case_dir=$(auto_case "dod-$scenario")
    mkdir -p "$case_dir/home/data/dod"
    printf 'Outside the data directory.\n' > "$case_dir/outside-dod.md"
    case $scenario in
      inline) ;;
      fenced-pointer)
        # An example pointer in a code fence names nothing, even when its target does not exist.
        auto_write_brief "$case_dir" "$(printf 'G1 fixture item.\n\n```text\nDoD file: %s\n```' "$case_dir/home/data/missing-dod.md")" ;;
      pointer)
        printf 'Pointed criteria fixture.\n' > "$case_dir/home/data/dod/task-x1.md"
        auto_write_brief "$case_dir" "DoD file: $case_dir/home/data/dod/task-x1.md" ;;
      outside-pointer)
        printf 'Exact contract fixture.\n' > "$case_dir/home/data/dod/task-x1.md"
        auto_write_brief "$case_dir" "DoD file: $case_dir/outside-dod.md" ;;
      dod-file-only)
        printf 'Exact contract fixture.\n' > "$case_dir/home/data/dod/task-x1.md"
        auto_write_brief "$case_dir" ;;
    esac
    auto_step "$case_dir"; auto_wait "$case_dir"
    expect_code 1 "$(auto_calls "$case_dir")" "dod-$scenario: exactly one read is requested"
    case $(auto_state "$case_dir") in "held: "*) fail "dod-$scenario: the head must not be held, got: $(auto_state "$case_dir")" ;; esac
    contract=$(cat "$case_dir"/state/.pr-auto-review/task-x1.d/*/contract.md)
    case $scenario in
      inline|fenced-pointer) printf '%s' "$contract" | grep -qF 'G1 fixture item' || fail "dod-$scenario: the inline Definition Of Done is not in the contract" ;;
      pointer) printf '%s' "$contract" | grep -qF 'Pointed criteria fixture' || fail "dod-$scenario: the named DoD file is not in the contract" ;;
      outside-pointer|dod-file-only) printf '%s' "$contract" | grep -qF 'Exact contract fixture' || fail "dod-$scenario: data/dod/<task>.md is not in the contract" ;;
    esac
    ! printf '%s' "$contract" | grep -qF 'Outside the data directory' || fail "dod-$scenario: a DoD file pointer outside data/ must not be read"
    auto_dump "$case_dir" "DoD presence: $scenario"
  done
  pass "a Definition Of Done is the brief's own section, the file its unfenced in-section pointer names under data/, or data/dod/<task>.md; a fenced or outside pointer names nothing"
}

test_auto_review_judges_each_check_before_spending_a_read() {
  local case_dir head scenario
  # F3: the readiness decision looks at each check and status context; the aggregate CLEAN state is not enough.
  for scenario in red-check cancelled-check red-context error-context required-unreported required-ruleset-unreported; do
    case_dir=$(auto_case "ready-$scenario")
    head=$(auto_sha "$case_dir" h1)
    case $scenario in
      red-check) write_github_rollup_json "$case_dir" "$head" "$(check_run ci COMPLETED FAILURE)" ;;
      cancelled-check) write_github_rollup_json "$case_dir" "$head" "$(check_run ci COMPLETED SUCCESS)" "$(check_run lint COMPLETED CANCELLED)" ;;
      red-context) write_github_rollup_json "$case_dir" "$head" "$(check_run ci COMPLETED SUCCESS)" "$(status_context deploy FAILURE)" ;;
      error-context) write_github_rollup_json "$case_dir" "$head" "$(check_run ci COMPLETED SUCCESS)" "$(status_context deploy ERROR)" ;;
      required-unreported) write_github_required "$case_dir" classic:lint ;;
      required-ruleset-unreported) write_github_required "$case_dir" ruleset:lint ;;
    esac
    auto_step "$case_dir"; auto_step "$case_dir"
    expect_code 0 "$(auto_calls "$case_dir")" "ready-$scenario: no read may be requested"
    expect_code 0 "$(auto_merges "$case_dir")" "ready-$scenario: nothing may merge"
    case $(auto_state "$case_dir") in "waiting: "*) ;; *) fail "ready-$scenario: current state should read waiting, got: $(auto_state "$case_dir")" ;; esac
  done
  # F3, pass cases: a green head is read, a re-run that superseded a red run is read, and a reported required check is read.
  case_dir=$(auto_case ready-superseded)
  head=$(auto_sha "$case_dir" h1)
  write_github_rollup_json "$case_dir" "$head" "$(check_run ci COMPLETED FAILURE 2026-01-01T00:00:00Z)" "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:05:00Z)"
  auto_step "$case_dir"; auto_wait "$case_dir"
  expect_code 1 "$(auto_calls "$case_dir")" "ready-superseded: a red run superseded by a later green run of the same check is ready"
  case_dir=$(auto_case ready-required-reported)
  write_github_required "$case_dir" classic:ci
  auto_step "$case_dir"; auto_wait "$case_dir"
  expect_code 1 "$(auto_calls "$case_dir")" "ready-required-reported: a required check that reported green is ready"
  pass "a red or cancelled check, a failed status context and an unreported required check stop a read; a green, re-run or reported head is read"
}

test_auto_review_treats_a_failed_runner_exit_as_a_failed_read() {
  local case_dir
  # F4, fail case: a runner that exits nonzero after writing a PASS report is a failed read; the next model is asked.
  case_dir=$(auto_case rc-pass)
  auto_mode "$case_dir" "$AUTO_SONNET" rc17
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"
  expect_code 0 "$(auto_merges "$case_dir")" "rc-pass: a PASS from a runner that failed must not merge"
  expect_code 0 "$(auto_reviews "$case_dir")" "rc-pass: that PASS must not be recorded"
  auto_wait "$case_dir"; auto_step "$case_dir"
  expect_code "$AUTO_SONNET,$AUTO_DEEPSEEK" "$(auto_runner_models "$case_dir")" "rc-pass: the failed model is not asked again and the next one is"
  expect_code 1 "$(auto_merges "$case_dir")" "rc-pass: the next model's clean PASS merges"
  assert_grep 'exited 17' "$(auto_event_file "$case_dir")" "rc-pass: the failure is not named"
  auto_dump "$case_dir" "F4 nonzero runner exit after a PASS report"
  # F4, safe handling of a reported FAIL: the head ends at fail and no later PASS can merge over it.
  case_dir=$(auto_case rc-fail)
  auto_mode "$case_dir" "$AUTO_SONNET" rc17-fail
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"; auto_step "$case_dir"
  expect_code 0 "$(auto_merges "$case_dir")" "rc-fail: nothing merges over a reported FAIL"
  expect_code "$AUTO_SONNET" "$(auto_runner_models "$case_dir")" "rc-fail: no later reader is asked after a FAIL"
  expect_code 1 "$(auto_count '"verdict":"FAIL"' "$case_dir/state/review-records.jsonl")" "rc-fail: the reported FAIL is recorded"
  assert_grep 'runner exited 17' "$(auto_event_file "$case_dir")" "rc-fail: the exit status is not named"
  grep -q '^fail ' <<<"$(auto_state "$case_dir")" || fail "rc-fail: current state should read fail: $(auto_state "$case_dir")"
  pass "a nonzero runner exit is a failed read even with a report: a PASS is not recorded and the next model is asked, a FAIL still ends the head"
}

test_auto_review_retries_a_wake_that_failed_to_append() {
  local case_dir
  # F6: a wake that could not be appended is not delivered, so it is not marked emitted; it is delivered once the queue works.
  case_dir=$(auto_case wake-retry)
  rm -f "$case_dir/home/config/review-runner"
  mkdir "$case_dir/state/.wake-queue"
  auto_step "$case_dir"
  expect_code 0 "$(auto_wakes "$case_dir")" "wake-retry: nothing can be appended while the queue is unavailable"
  expect_code 0 "$(auto_notes "$case_dir" 'review runner unavailable')" "wake-retry: an undelivered hold is not recorded as emitted"
  rmdir "$case_dir/state/.wake-queue"
  auto_step "$case_dir"
  expect_code 1 "$(auto_wakes "$case_dir")" "wake-retry: the hold is delivered once the queue recovers"
  expect_code 1 "$(auto_notes "$case_dir" 'review runner unavailable')" "wake-retry: and recorded once"
  auto_step "$case_dir"; auto_step "$case_dir"
  expect_code 1 "$(auto_wakes "$case_dir")" "wake-retry: a repeat pass must not wake again"
  # F6: a terminal hold (the head has an outcome) still delivers its wake after the queue recovers.
  case_dir=$(auto_case wake-retry-fail)
  auto_mode "$case_dir" "$AUTO_SONNET" fail
  mkdir "$case_dir/state/.wake-queue"
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"
  expect_code 0 "$(auto_wakes "$case_dir")" "wake-retry-fail: the FAIL wake cannot be appended yet"
  rmdir "$case_dir/state/.wake-queue"
  auto_step "$case_dir"; auto_step "$case_dir"
  expect_code 1 "$(auto_wakes "$case_dir")" "wake-retry-fail: a terminal head still delivers its pending wake, once"
  expect_code 0 "$(auto_merges "$case_dir")" "wake-retry-fail: a FAIL never merges"
  pass "a failed wake append is never marked emitted: it is delivered after recovery, including for a terminal hold, and never repeated"
}

pr_merge_test_cases=(
test_auto_review_green_uncovered_pr_is_read_recorded_and_merged
test_auto_review_makes_no_request_when_the_pr_is_not_ready
test_auto_review_unset_or_unusable_runner_records_one_reason_per_head
test_auto_review_chooses_readers_by_author_family
test_auto_review_switches_after_a_failed_read_and_never_retries_the_failed_model
test_auto_review_records_each_verdict_and_merges_only_a_covering_pass
test_auto_review_new_head_voids_the_pass_and_held_prs_are_never_merged
test_auto_review_survives_slow_hung_and_killed_readers
test_auto_review_leaves_the_away_record_to_the_merge_script
test_auto_review_trusts_only_a_structured_served_model
test_auto_review_waits_on_a_merge_queue_and_keeps_heads_it_needs
test_auto_review_holds_a_head_that_leaves_the_merge_queue_still_open
test_auto_review_events_reach_the_fleet_ledger
test_auto_review_protected_class_counts_every_recorded_review
test_auto_review_reaches_the_merge_gate_on_a_recorded_routine_pass
test_auto_review_incomplete_review_pack_is_held_and_never_dispatched
test_auto_review_reads_the_definition_of_done_as_fm_dod_lib_does
test_auto_review_judges_each_check_before_spending_a_read
test_auto_review_treats_a_failed_runner_exit_as_a_failed_read
test_auto_review_retries_a_wake_that_failed_to_append
test_auto_review_three_prs_through_the_housekeeping_pass
test_seeded_homes_cannot_create_a_second_landing_owner
test_unreadable_landing_routing_refuses
test_main_serializes_firstmate_landings
test_firstmate_landings_belong_to_main_home
test_repair_clone_routes_to_main
test_main_scope_routes_standalone_clones
test_linked_home_refusal_names_only_a_proved_home
test_task_consent_does_not_authorize_a_landing
test_shallow_task_lineage_routing
test_unrelated_project_keeps_home_local_merge
test_derived_author_coverage
test_author_evidence_accepts_path_safe_legacy_task_ids
test_author_verification_requires_exact_identity
test_author_verification_names_fetch_for_missing_objects
test_author_verification_accepts_sha256_base
test_github_unreadable_base_names_the_refusal
test_identical_captain_words_follow_append_order
test_triggered_review_verifies_only_when_independent
test_captain_fail_triggered_independent_pass_merges
test_review_record_requires_matching_local_report
test_late_fail_before_away_hold_refuses
test_attended_override_without_review_refuses
test_missing_review_record_refuses
test_gitlab_and_forgejo_missing_review_record_refuse
test_captain_word_refused_while_away
test_review_record_validation_and_latest
test_review_record_derives_model_families
test_review_record_survives_a_later_family_change
test_recorded_review_merge_conditions
test_github_zero_exit_queue_required_refuses_with_exact_retry
test_github_closed_unqueued_outcome_omits_retry_flags
test_github_agreeing_queue_rules_keep_retry_guidance
test_github_conflicting_queue_rules_report_ambiguity
test_verified_merge_records_pr_and_head
test_pr_metadata_is_recorded_before_the_forge_call
test_merge_failure_propagates_after_recording
test_github_open_unqueued_outcome_refuses
test_github_mergeable_unknown_retries_then_succeeds
test_github_mergeable_unknown_exhausts_bound_and_reports_pending
test_github_mergeable_unknown_retry_rechecks_checks
test_github_mergeable_conflicting_is_not_retried
test_github_unreadable_outcome_keeps_pr_bookkeeping
test_github_refusal_quotes_the_forge_output
test_github_unreadable_outcome_refusal_quotes_the_forge_output
test_github_accepted_queue_flags_do_not_echo_back_the_same_command
test_github_mismatched_queue_flags_still_name_the_retry
test_github_unrecognised_queue_method_still_names_the_queue
test_github_unreadable_queue_rules_are_not_reported_as_no_queue
test_github_plan_gated_403_reads_as_no_queue
test_github_no_queue_rule_says_nothing_about_a_queue
test_github_unmerged_fallback_cannot_replace_queue_aware_read
test_github_auto_merge_without_queue_refuses_legibly
test_github_failed_merge_never_claims_armed_auto_merge
test_github_failed_merge_with_queue_flags_never_claims_acceptance
test_github_failed_gh_read_falls_back_to_gh_axi
test_github_failed_merge_names_an_observed_landed_state
test_github_without_gh_still_uses_gh_axi_merge
test_github_without_gh_failed_read_keeps_bookkeeping
test_github_merged_outcome_is_verified
test_verified_merge_arms_the_pool_copy_prune
test_unverified_merge_never_arms_the_pool_copy_prune
test_github_verified_merge_requires_poll_recording
test_github_queued_outcome_is_verified
test_github_queue_required_refusal_names_retry_flags
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
)
pr_merge_run "$@"
