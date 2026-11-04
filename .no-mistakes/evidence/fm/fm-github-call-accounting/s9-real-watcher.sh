#!/usr/bin/env bash
# S9: real bin/fm-watch.sh + real owner + real ps, fake tmux/gh-axi, disposable homes.
# A plain disposable home acts as a primary. A home minted by bin/fm-lab-home.sh acts as a lab.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M6HY67SMDHG0CZE4NE696MQG
cd "$WT"
. "$WT/tests/wake-helpers.sh"
WATCH="$ROOT/bin/fm-watch.sh"; OWNER="$ROOT/bin/fm-github-accounting.py"
TMP_ROOT=$(fm_test_tmproot fm-acct-s9)
count_watch_polls
fake_gh() { printf '#!/bin/sh\nprintf "api_response:\\n  body: used=1 reset=1794000000 limit=5000 remaining=4999\\n"\n' > "$1/gh-axi"; chmod +x "$1/gh-axi"; }
start_w() {  # <home> <fakebin>; plain FM_HOME, default state path
  PATH="$2:$PATH" FM_HOME="$1" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 \
    FM_HOME_SUMMARY_INTERVAL=99999999 FM_OPEN_LOOPS_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    FM_IDLE_REAP_INTERVAL=0 FM_TYPESAFE_HEALTH_INTERVAL=0 FM_LAVISH_AUTO_RETIRE_INTERVAL=0 FM_GITHUB_ACCOUNTING=1 \
    "$WATCH" > "$1/watch.out" 2> "$1/watch.err" &
}
polled() { local f; f=$(watch_polls_file "$1" "$2"); [ -e "$f" ] && [ "$(cat "$f" 2>/dev/null || echo 0)" -ge "$3" ]; }
rid() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["run_id"])' "$1/state/github-accounting/owner.lock" 2>/dev/null; }
has_rid() { local i; i=$(rid "$1") && [ -n "$i" ] && [ "$i" != "${2:-}" ]; }
ost() { PATH="$2:$PATH" FM_HOME="$1" "$OWNER" "$3"; }

echo "=== primary-like home (no marker)"
P=$(make_case primary); fake_gh "$P/fakebin"
start_w "$P" "$P/fakebin"; W=$!
fm_test_wait_until --while-alive "$W" --cycles 8 "$(watch_polls_file "$P/state" "$W")" -- has_rid "$P" "" || echo "FAIL owner never started: $(cat "$P/watch.out")"
R1=$(rid "$P"); O1=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$P/state/github-accounting/owner.lock")
echo "watcher started owner: run_id=$R1 pid=$O1 state_dir=<home>/state/github-accounting exists=$([ -d "$P/state/github-accounting" ] && echo yes)"
B=$(cat "$(watch_polls_file "$P/state" "$W")" 2>/dev/null || echo 0)
fm_test_wait_until --while-alive "$W" --cycles 8 "$(watch_polls_file "$P/state" "$W")" -- polled "$P/state" "$W" $((B+3)) || echo "FAIL polling stopped"
echo "after 3 more cycles: run_id unchanged=$([ "$(rid "$P")" = "$R1" ] && echo yes || echo NO) wake-queue bytes=$(wc -c < "$P/state/.wake-queue" 2>/dev/null || echo 0)"
kill -9 "$O1"; echo "SIGKILL owner $O1"
fm_test_wait_until --while-alive "$W" --cycles 8 "$(watch_polls_file "$P/state" "$W")" -- has_rid "$P" "$R1" || echo "FAIL no recovery"
R2=$(rid "$P"); echo "next cycle recovered: new run_id=$R2 differs=$([ "$R2" != "$R1" ] && echo yes || echo NO)"
kill "$W"; wait_for_exit "$W" 100 || true
echo "after watcher exit, owner state=$(ost "$P" "$P/fakebin" status | python3 -c 'import json,sys;print(json.load(sys.stdin)["state"])') (detached owner outlives watcher)"
ost "$P" "$P/fakebin" stop; echo "start-failed marker present: $([ -e "$P/state/.github-accounting-start-failed" ] && echo yes || echo no)"

echo "=== failed real start in primary-like home: foreign db"
F=$(make_case failed); fake_gh "$F/fakebin"; mkdir -p "$F/state/github-accounting"
python3 -c 'import sqlite3,sys; d=sqlite3.connect(sys.argv[1]); d.execute("create table theirs(x)"); d.commit()' "$F/state/github-accounting/observations.sqlite"
start_w "$F" "$F/fakebin"; W=$!
wait_for_exit "$W" 100 || { kill "$W"; echo "FAIL watcher did not close with a wake"; }
sed "s#$F#<home>#g" "$F/watch.out" | grep github-accounting
echo "queued wake rows: $(grep -c github-accounting-start-failed "$F/state/.wake-queue")  marker present: $([ -e "$F/state/.github-accounting-start-failed" ] && echo yes || echo no)"

echo "=== marked lab home from bin/fm-lab-home.sh"
L=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$L" >/dev/null || echo "FAIL lab create"
L=$(cd "$L" && pwd -P)
LB=$(make_case labbin); fake_gh "$LB/fakebin"; fm_test_track_watcher_state "$L/state"
start_w "$L" "$LB/fakebin"; W=$!
fm_test_wait_until --while-alive "$W" --cycles 8 "$(watch_polls_file "$L/state" "$W")" -- polled "$L/state" "$W" 4 || echo "FAIL lab polling: $(cat "$L/watch.out")"
echo "after 4 cycles: state/github-accounting exists=$([ -e "$L/state/github-accounting" ] && echo YES || echo no)"
kill "$W"; wait_for_exit "$W" 100 || true
rm -rf "$L"
echo done
