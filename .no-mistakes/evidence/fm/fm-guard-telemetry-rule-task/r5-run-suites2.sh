#!/usr/bin/env bash
cd "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6A1M5XYTCJS89BZNWQEAKMJ" || exit 1; PB=/Users/charlesabrooker/firstmate/bin/fm-proc-budget.sh; EV=/Users/charlesabrooker/.no-mistakes/evidence/01M6A1M5XYTCJS89BZNWQEAKMJ
run() { local name=$1; shift; local t0=$SECONDS rc=0; "$PB" --own-procs 128 -- "$@" >"$EV/r5-suite-$name.log" 2>&1 || rc=$?; printf '%s rc=%s secs=%s\n' "$name" "$rc" $((SECONDS-t0)) >>"$EV/r5-suites-summary.txt"; }
b=$(wc -l < state/guard-events.jsonl)
run teardown-landed-allow bash tests/fm-teardown-pool.test.sh test_completed_teardown_records_one_landed_work_allow
run pr-merge-guard-events bash tests/fm-pr-merge-checks.test.sh test_guard_events_record_the_merge_decisions_without_changing_them
run secondmate-T10 bash tests/fm-secondmate-sync.test.sh test_spawn_fast_forwards_before_launch
run watch-stderr bash tests/fm-watch-triage.test.sh test_guard_workaround_detector_releases_watcher_stderr
run git-secrets bash tests/fm-git-secrets.test.sh
run spawn-batch bash tests/fm-spawn-batch.test.sh
echo "code-root rows $b -> $(wc -l < state/guard-events.jsonl)" >>"$EV/r5-suites-summary.txt"; echo DONE2 >>"$EV/r5-suites-summary.txt"
