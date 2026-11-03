#!/usr/bin/env bash
# Real bin/fm-watch.sh + real owner + fake gh-axi. Part 1 marked lab home: never starts. Part 2 disposable unmarked
# (primary-shape) home outside every checkout, no gate bypass: starts, restarts, switch off keeps it off, foreign DB wakes once.
# Open-loop and memory wakes use their documented test seams, so only the accounting tick can close the cycle.
set -u
EV=$1; . "$EV/drivers/common.sh"
WATCH="$PWD/bin/fm-watch.sh"
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE
FB=$(mktemp -d "$TMPDIR/fm-s8-bin.XXXXXX"); cat > "$FB/gh-axi" <<'F'
#!/bin/sh
printf 'api_response:\n  body: used=1 reset=1794000000 limit=5000 remaining=4999\n'
F
chmod +x "$FB/gh-axi"; export PATH="$FB:$PATH"
watch() { # <home> <out> [env...]
  local h=$1 o=$2; shift 2
  FM_HOME="$h" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 FM_HOME_SUMMARY_INTERVAL=99999999 \
  FM_OPEN_LOOPS_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_IDLE_REAP_INTERVAL=0 FM_TYPESAFE_HEALTH_INTERVAL=0 FM_LAVISH_AUTO_RETIRE_INTERVAL=0 FM_OPEN_LOOPS_BIN=/usr/bin/true FM_MEMORY_GUARD_BIN=/usr/bin/true \
  env "$@" "$WATCH" > "$o" 2>&1 &
}
run_id() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["run_id"])' "$1/state/github-accounting/owner.lock" 2>/dev/null; }
wait_run() { local i; for i in $(seq 1 ${3:-60}); do r=$(run_id "$1"); [ -n "$r" ] && [ "$r" != "$2" ] && { echo "$r"; return 0; }; sleep 0.5; done; return 1; }
own() { FM_HOME="$1" python3 "$OWNER" "$2"; }
stopw() { kill "$1" 2>/dev/null; wait_gone "$1"; }

echo "=== 1. marked lab home: watcher never starts an owner"
( unset NO_MISTAKES_GATE; eval "$(bin/fm-lab-home.sh env 2>/dev/null)"; export FM_HOME
  watch "$FM_HOME" "$FM_HOME/w.out" FM_GITHUB_ACCOUNTING=1; p=$!; sleep 8; kill -0 $p && echo "watcher alive after 8 s"
  ls "$FM_HOME/state/github-accounting" 2>/dev/null || echo "no state/github-accounting dir: owner never ran"
  grep -c github-accounting "$FM_HOME/w.out"; stopw $p
  bin/fm-lab-home.sh teardown "$FM_HOME" && rm -rf "$FM_HOME"; echo "lab_teardown=$?" )

H=$(mktemp -d "$TMPDIR/fm-s8-home.XXXXXX"); mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects"
echo "=== 2. disposable primary-shape home: watcher starts an absent owner, leaves it alone"
watch "$H" "$H/w.out" FM_GITHUB_ACCOUNTING=1; p=$!
r1=$(wait_run "$H" "") && echo "owner started by watcher" || { echo FAIL; cat "$H/w.out"; }
sleep 4; [ "$(run_id "$H")" = "$r1" ] && echo "same run after 4 more cycles"
echo "=== 3. plain stop lasts until the next cycle (documented)"
own "$H" stop; r2=$(wait_run "$H" "$r1") && echo "new owner after plain stop: differs=$([ "$r1" != "$r2" ] && echo yes)"
echo "=== 4. SIGKILL recovers at the next cycle, with no wake"
pid=$(own "$H" status | python3 -c 'import json,sys;print(json.load(sys.stdin)["pid"])'); kill -9 "$pid"
r3=$(wait_run "$H" "$r2") && echo "recovered: differs=$([ "$r2" != "$r3" ] && echo yes)"
[ ! -s "$H/state/.wake-queue" ] && echo "wake queue empty"
echo "=== 5. owner outlives the watcher"
stopw $p; own "$H" status | python3 -c 'import json,sys;print(json.load(sys.stdin)["state"])'
echo "=== 6. FM_GITHUB_ACCOUNTING=0 keeps a stopped owner off"
own "$H" stop >/dev/null; watch "$H" "$H/w2.out" FM_GITHUB_ACCOUNTING=0; p=$!; sleep 6; own "$H" status; stopw $p
echo "=== 7. foreign database: one wake, no start loop, reason in owner.log, file unchanged"
mv "$H/state/github-accounting/observations.sqlite" "$H/moved.sqlite"
/usr/bin/sqlite3 "$H/state/github-accounting/observations.sqlite" "CREATE TABLE theirs(v); INSERT INTO theirs VALUES('keep');"
b=$(shasum -a 256 "$H/state/github-accounting/observations.sqlite")
watch "$H" "$H/w3.out" FM_GITHUB_ACCOUNTING=1; p=$!
wait_gone "$p" || { sleep 10; wait_gone "$p"; }; kill -0 $p 2>/dev/null && echo "watcher still alive" || echo "watcher closed its cycle with a wake"
grep '^check: github-accounting' "$H/w3.out"
grep -c github-accounting-start-failed "$H/state/.wake-queue"
ls -la "$H/state/.github-accounting-start-failed" | awk '{print "marker present:",$NF}' | sed "s#$H#<home>#"
tail -1 "$H/state/github-accounting/owner.log"
[ "$b" = "$(shasum -a 256 "$H/state/github-accounting/observations.sqlite")" ] && echo "foreign file bytes identical"
echo "=== 8. next watcher holds the retry without another wake"
FM_HOME="$H" bin/fm-wake-drain.sh > "$H/d.out" 2> "$H/d.err"; grep -q 'github-accounting owner failed to start' "$H/d.out" && echo "drain presents the failed start"
ack=$(sed -n 's/^WAKE_ACK_REQUIRED:.*\(--ack-through [0-9]* --recovery-generation [A-Za-z0-9._-]*\)$/\1/p' "$H/d.err"); FM_HOME="$H" bin/fm-wake-drain.sh $ack >/dev/null 2>&1; echo "ack_exit=$?"
rm -rf "$H/state/.prelude-progress" "$H/state/.prelude-deferred" "$H/state/.watcher-down"
m0=$(stat -f %m "$H/state/.github-accounting-start-failed")
watch "$H" "$H/w4.out" FM_GITHUB_ACCOUNTING=1; p=$!; sleep 8; kill -0 $p && echo "watcher alive after 8 s"; echo "accounting lines in watcher output: $(grep -c 'github-accounting' "$H/w4.out")"; echo "queued accounting wakes: $(grep -c github-accounting-start-failed "$H/state/.wake-queue")"; [ "$m0" = "$(stat -f %m "$H/state/.github-accounting-start-failed")" ] && echo "marker untouched: no attempt inside the hour"; own "$H" status; stopw $p
echo "=== 9. operator remedy: move the file, age the marker, start recovers"
mv "$H/state/github-accounting/observations.sqlite" "$H/foreign.sqlite"; touch -t 200001010000 "$H/state/.github-accounting-start-failed"
rm -rf "$H/state/.prelude-progress" "$H/state/.prelude-deferred" "$H/state/.watcher-down"; watch "$H" "$H/w5.out" FM_GITHUB_ACCOUNTING=1; p=$!; for i in $(seq 1 30); do [ -e "$H/state/.github-accounting-start-failed" ] || break; sleep 0.5; done
[ -e "$H/state/.github-accounting-start-failed" ] && echo "marker STILL present" || echo "marker cleared"
own "$H" status | python3 -c 'import json,sys;print(json.load(sys.stdin)["state"])'; stopw $p; own "$H" stop
pgrep -fl "$H" | grep -v pgrep || echo "no home processes left"
rm -rf "$H" "$FB"
