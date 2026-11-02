WT=/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M6BS0VSGYCH01N7E7CZ2GY8H
cd "$WT"
. tests/wake-helpers.sh
WATCH="$ROOT/bin/fm-watch.sh"; OWNER="$ROOT/bin/fm-github-accounting.py"
TMP_ROOT=$(fm_test_tmproot fm-acct-e8)
count_watch_polls
printf '### head %s host %s %s\n' "$(git rev-parse HEAD)" "$(hostname)" "$(date -u +%FT%TZ)"
echo "### re-drive of E8: the first driver stopped the watcher before its next cycle could read the start's exit"
dir=$(make_case foreign); G="$dir/state/github-accounting"; mkdir -p "$G"
python3 -c 'import sqlite3,sys;d=sqlite3.connect(sys.argv[1]);d.execute("create table customer(v)");d.commit()' "$G/observations.sqlite"
printf '#!/bin/sh\nprintf "api_response:\\n  body: used=1 reset=1794000000 limit=5000 remaining=4999\\n"\n' > "$dir/fakebin/gh-axi"; chmod +x "$dir/fakebin/gh-axi"
watcher() { PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 FM_HOME_SUMMARY_INTERVAL=99999999 FM_OPEN_LOOPS_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_IDLE_REAP_INTERVAL=0 FM_TYPESAFE_HEALTH_INTERVAL=0 FM_LAVISH_AUTO_RETIRE_INTERVAL=0 FM_GITHUB_ACCOUNTING=1 "$WATCH" > "$dir/watch.out" 2> "$dir/watch.err" & }
own() { PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" python3 "$OWNER" "$1"; }
m="$dir/state/.github-accounting-start-failed"
watcher; W=$!; wait_for_exit $W 100; echo "  first watcher closed on wake: $(grep -c '^check: github-accounting' "$dir/watch.out"); marker: $([ -e "$m" ] && echo present || echo none)"
FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$ROOT/bin/fm-wake-drain.sh" > "$dir/drain.out" 2> "$dir/drain.err"; ack_drain_err "$dir/state" "$dir/drain.err" >/dev/null; clear_watcher_cycle "$dir/state"
mv "$G/observations.sqlite" "$dir/moved.sqlite"; touch -t 200001010000 "$m"
watcher; W=$!
i=0; while [ -e "$m" ] && [ $i -lt 100 ]; do sleep 0.2; i=$((i+1)); done
echo "  after $((i/5))s marker: $([ -e "$m" ] && echo present || echo none)"; echo "  owner: $(own status)"; echo "  wake rows: $(grep -c github-accounting "$dir/state/.wake-queue" 2>/dev/null; true)"
kill $W; wait $W 2>/dev/null; own stop
