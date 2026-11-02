WT=/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M6BS0VSGYCH01N7E7CZ2GY8H
cd "$WT"
. tests/wake-helpers.sh
WATCH="$ROOT/bin/fm-watch.sh"; OWNER="$ROOT/bin/fm-github-accounting.py"
TMP_ROOT=$(fm_test_tmproot fm-acct-e2e)
count_watch_polls
printf '### head %s host %s %s\n' "$(git rev-parse HEAD)" "$(hostname)" "$(date -u +%FT%TZ)"
echo "### real bin/fm-watch.sh, real owner, disposable homes; gh-axi is a labelled fake here so the watcher fixtures stay off the account"
fake_gh() { printf '#!/bin/sh\nprintf "api_response:\\n  body: used=1 reset=1794000000 limit=5000 remaining=4999\\n"\n' > "$1/fakebin/gh-axi"; chmod +x "$1/fakebin/gh-axi"; }
watcher() { local dir=$1; shift; fake_gh "$dir"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 FM_HOME_SUMMARY_INTERVAL=99999999 FM_OPEN_LOOPS_INTERVAL=99999999 \
  FM_SECONDMATE_LIVENESS_SECS=99999999 FM_IDLE_REAP_INTERVAL=0 FM_TYPESAFE_HEALTH_INTERVAL=0 FM_LAVISH_AUTO_RETIRE_INTERVAL=0 \
  FM_GITHUB_ACCOUNTING=1 env "$@" "$WATCH" > "$dir/watch.out" 2> "$dir/watch.err" & }
own() { PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" python3 "$OWNER" "$2"; }
rid() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["run_id"])' "$1/state/github-accounting/owner.lock" 2>/dev/null; }
field() { own "$1" status | python3 -c 'import json,sys;print(json.load(sys.stdin).get(sys.argv[1],""))' "$2"; }
waitfor() { local i=0 limit=$1; shift; while [ $i -lt $((limit*5)) ]; do "$@" && { echo "  after $((i/5))s"; return 0; }; sleep 0.2; i=$((i+1)); done; echo "  NOT within ${limit}s"; return 1; }
running() { [ "$(field "$1" state)" = running ] && { [ -z "${2:-}" ] || [ "$(field "$1" run_id)" != "$2" ]; }; }
stopw() { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; clear_watcher_cycle "$2/state"; }
alive() { kill -0 "$1" 2>/dev/null && echo "  watcher alive" || echo "  watcher EXITED: $(cat "$2/watch.out")"; }
wakes() { printf '  wake rows %s; marker %s\n' "$( [ -f "$1/state/.wake-queue" ] && grep -c github-accounting "$1/state/.wake-queue" || echo 0)" "$( [ -e "$1/state/.github-accounting-start-failed" ] && echo present || echo none)"; }

dir=$(make_case primary)
echo "=== E1 primary home: absent owner starts on a cycle"; watcher "$dir"; W=$!; waitfor 20 running "$dir"; first=$(field "$dir" run_id); own "$dir" status
echo "=== E2 running owner left alone across cycles"; sleep 5; [ "$(field "$dir" run_id)" = "$first" ] && echo "  same run_id: yes" || echo "  same run_id: NO"; alive $W "$dir"; wakes "$dir"
echo "=== E3 SIGKILL of owner recovers at the next cycle"; kill -9 "$(field "$dir" pid)"; waitfor 20 running "$dir" "$first"; second=$(field "$dir" run_id)
echo "=== E4 plain stop lasts until the next cycle"; own "$dir" stop; waitfor 20 running "$dir" "$second"; third=$(field "$dir" run_id)
echo "=== E5 watcher exit leaves the detached owner; a new watcher does not double it"; stopw $W "$dir"; echo "  owner: $(own "$dir" status)"; watcher "$dir"; W=$!; sleep 4; [ "$(field "$dir" run_id)" = "$third" ] && echo "  same run_id: yes" || echo "  same run_id: NO"
echo "=== E6 FM_GITHUB_ACCOUNTING=0 with a stopped owner keeps it off"; stopw $W "$dir"; own "$dir" stop; watcher "$dir" FM_GITHUB_ACCOUNTING=0; W=$!; sleep 4; own "$dir" status; alive $W "$dir"; stopw $W "$dir"; wakes "$dir"
PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" python3 "$OWNER" records --kind owner | python3 -c 'import json,sys
print("  owner events",[(json.loads(l).get("action"),json.loads(l)["run_id"][:8]) for l in sys.stdin])'

dir=$(make_case foreign); G="$dir/state/github-accounting"; mkdir -p "$G"
python3 -c 'import sqlite3,sys;d=sqlite3.connect(sys.argv[1]);d.execute("create table customer(v)");d.execute("insert into customer values (42)");d.commit()' "$G/observations.sqlite"; before=$(shasum -a 256 "$G/observations.sqlite" | cut -c1-16)
echo "=== E7 foreign database: real failed start wakes once, keeps the file, then holds to the retry interval"; watcher "$dir"; W=$!; wait_for_exit $W 100; grep '^check: github-accounting' "$dir/watch.out" | sed "s#$dir#<home>#g; s/^/  /"; echo "  owner.log: $(tail -1 "$G/owner.log")"; wakes "$dir"; [ "$(shasum -a 256 "$G/observations.sqlite" | cut -c1-16)" = "$before" ] && echo "  database bytes unchanged $before"
FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$ROOT/bin/fm-wake-drain.sh" > "$dir/drain.out" 2> "$dir/drain.err"; ack_drain_err "$dir/state" "$dir/drain.err" >/dev/null; echo "  drained; wake rows $(grep -c github-accounting "$dir/state/.wake-queue" 2>/dev/null || echo 0)"
clear_watcher_cycle "$dir/state"; logbefore=$(wc -l < "$G/owner.log"); watcher "$dir"; W=$!; sleep 5; echo "  next watcher, 5 s: new log lines $(( $(wc -l < "$G/owner.log") - logbefore )); $(alive $W "$dir")"; wakes "$dir"
echo "=== E8 operator moves the file; next attempt after the interval starts the owner and clears the marker"; mv "$G/observations.sqlite" "$dir/moved.sqlite"; touch -t 200001010000 "$dir/state/.github-accounting-start-failed"; waitfor 20 running "$dir"; wakes "$dir"; stopw $W "$dir"; FM_GITHUB_ACCOUNTING=1 own "$dir" stop
echo "  moved file intact: $(python3 -c 'import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute("select v from customer").fetchone()[0])' "$dir/moved.sqlite")"

dir=$(make_case zero); G="$dir/state/github-accounting"; mkdir -p "$G"; : > "$G/observations.sqlite"
echo "=== E9 zero-size database under the real watcher: starts, no wake, no marker"; watcher "$dir"; W=$!; waitfor 20 running "$dir"; alive $W "$dir"; wakes "$dir"; stopw $W "$dir"; own "$dir" stop

dir=$(make_case busy); fake_gh "$dir"; own "$dir" start >/dev/null; own "$dir" stop >/dev/null; G="$dir/state/github-accounting"
python3 -c 'import fcntl,sys,time;l=open(sys.argv[1],"r+");fcntl.flock(l,fcntl.LOCK_SH);open(sys.argv[2],"w").close();time.sleep(300)' "$G/owner.lock" "$dir/holding" & H=$!
while [ ! -e "$dir/holding" ]; do sleep 0.1; done
echo "=== E10 held lock: start is busy (75), no wake, no marker; next cycle after release starts the owner"; own "$dir" start; echo "  direct start exit=$?"; watcher "$dir"; W=$!; sleep 4; alive $W "$dir"; wakes "$dir"; echo "  state: $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["state"])' "$G/owner.lock" 2>/dev/null)"; kill $H; wait $H 2>/dev/null; waitfor 20 running "$dir"; wakes "$dir"; stopw $W "$dir"; own "$dir" stop

dir=$(make_case mate); printf 'mate\n' > "$dir/.fm-secondmate-home"
echo "=== E11 secondmate home: no owner"; watcher "$dir"; W=$!; sleep 4; own "$dir" status; alive $W "$dir"; stopw $W "$dir"
dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); dir=$(env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE "$ROOT/bin/fm-lab-home.sh" create "$dir"); mkdir -p "$dir/fakebin"
echo "=== E12 real fm-lab-home.sh home: marker means no owner"; ls -a "$dir" | grep fm-lab-home | sed 's/^/  /'; watcher "$dir"; W=$!; sleep 4; own "$dir" status; alive $W "$dir"; stopw $W "$dir"; "$ROOT/bin/fm-lab-home.sh" teardown "$dir" >/dev/null 2>&1; rm -rf "$dir"
