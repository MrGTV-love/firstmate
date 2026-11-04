#!/usr/bin/env bash
# Real bin/fm-watch.sh + real bin/fm-github-accounting.py + real ps in disposable homes.
# A fake gh-axi keeps the watcher's owner away from the account. Usage: live_watcher.sh <worktree>
set -u
WT=$1; WATCH=$WT/bin/fm-watch.sh; OWNER=$WT/bin/fm-github-accounting.py
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-watch-live.XXXXXX"); fails=0
ok() { echo "PASS: $*"; }; bad() { echo "FAIL: $*"; fails=$((fails+1)); }
mk() { d=$ROOT/$1; mkdir -p "$d/state" "$d/fakebin" "$d/config" "$d/data"
  printf '#!/bin/sh\nprintf "api_response:\\n  body: used=1 reset=1794000000 limit=5000 remaining=4999\\n"\n' > "$d/fakebin/gh-axi"; chmod +x "$d/fakebin/gh-axi"; printf '%s' "$d"; }
watch() { d=$1; shift; PATH="$d/fakebin:$PATH" FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 FM_HOME_SUMMARY_INTERVAL=99999999 FM_OPEN_LOOPS_INTERVAL=99999999 \
  FM_SECONDMATE_LIVENESS_SECS=99999999 FM_IDLE_REAP_INTERVAL=0 FM_TYPESAFE_HEALTH_INTERVAL=0 FM_LAVISH_AUTO_RETIRE_INTERVAL=0 \
  FM_MEMORY_GUARD_BIN=/usr/bin/true FM_REVIEW_AGENT_SELECT_BIN=/usr/bin/true FM_MODEL_FRESHNESS=0 FM_DURATION_FILE=off \
  FM_MERGE_PRUNE=0 FM_CREW_STATE_NM_CACHE=off FM_OPEN_LOOPS_BIN=/usr/bin/true FM_ROOT_OVERRIDE="$d" env "$@" "$WATCH" > "$d/watch.out" 2> "$d/watch.err" & WP=$!; }
own() { PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" python3 "$OWNER" "$2"; }
field() { own "$1" status | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1],""))' "$2"; }
published() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["run_id"])' "$1/state/github-accounting/owner.lock" 2>/dev/null; }
waitfor() { n=$1; shift; i=0; while [ "$i" -lt "$n" ]; do "$@" && return 0; sleep 0.5; i=$((i+1)); done; return 1; }
runs() { id=$(published "$1") && [ -n "$id" ] && [ "$id" != "${2:-}" ]; }
gone() { ! kill -0 "$1" 2>/dev/null; }
stopw() { kill "$1" 2>/dev/null; waitfor 40 gone "$1"; wait "$1" 2>/dev/null; }
set +m; exec 2>/dev/null

echo "--- primary home: start, leave alone, recover from SIGKILL"
d=$(mk primary); watch "$d" FM_GITHUB_ACCOUNTING=1; w=$WP
waitfor 60 runs "$d" "" && ok "watcher cycle started an absent owner: run_id=$(published "$d")" || bad "watcher never started the owner: $(cat "$d/watch.err" | tail -3)"
first=$(published "$d"); opid=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pid"])' "$d/state/github-accounting/owner.lock")
sleep 6; [ "$(published "$d")" = "$first" ] && ok "after more cycles the same owner runs" || bad "owner replaced while running"
[ ! -s "$d/state/.wake-queue" ] && ok "healthy owner raised no wake" || bad "unexpected wake: $(cat "$d/state/.wake-queue")"
kill -9 "$opid"; echo "SIGKILL sent to owner $opid"
waitfor 60 runs "$d" "$first" && ok "next cycle recovered: new run_id=$(published "$d")" || bad "no recovery after SIGKILL"
second=$(published "$d"); stopw "$w"
[ "$(field "$d" run_id)" = "$second" ] && ok "detached owner outlives its watcher" || bad "owner died with its watcher"
own "$d" stop; [ "$(field "$d" state)" = stopped ] && ok "owner stop works after watcher exit" || bad "owner not stopped"
PATH="$d/fakebin:$PATH" FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" python3 "$OWNER" records --kind owner | python3 -c 'import json,sys; print("owner rows:", [ (r["action"], r["run_id"][:8]) for r in map(json.loads, sys.stdin)])'

echo "--- primary home: foreign database refused, one wake, silent hold, recovery"
d=$(mk foreign); mkdir -m 700 "$d/state/github-accounting"; printf 'operator data\n' > "$d/state/github-accounting/observations.sqlite"; sum=$(shasum "$d/state/github-accounting/observations.sqlite" | cut -d' ' -f1)
watch "$d" FM_GITHUB_ACCOUNTING=1; w=$WP
waitfor 60 gone "$w"; wait "$w" 2>/dev/null
grep '^check: github-accounting owner failed to start' "$d/watch.out" && ok "failed start wakes with the named reason" || bad "no wake: $(cat "$d/watch.out")"
[ "$(grep -c github-accounting-start-failed "$d/state/.wake-queue")" = 1 ] && ok "one durable wake queued" || bad "wake count wrong"
[ -e "$d/state/.github-accounting-start-failed" ] && ok "failed-start marker written" || bad "no marker"
[ "$(shasum "$d/state/github-accounting/observations.sqlite" | cut -d' ' -f1)" = "$sum" ] && ok "foreign file bytes unchanged" || bad "foreign file changed"
FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" "$WT/bin/fm-wake-drain.sh" > "$d/drain.out" 2> "$d/drain.err"; grep 'github-accounting owner failed' "$d/drain.out" && ok "real drain presents the failed start" || bad "drain lacks the wake"
seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$d/drain.err"); gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$d/drain.err")
FM_STATE_OVERRIDE="$d/state" "$WT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1 && ok "wake acknowledged" || bad "ack failed"
rm -rf "$d/state/.prelude-progress" "$d/state/.prelude-deferred" "$d/state/.watcher-down"
mt=$(stat -f %m "$d/state/.github-accounting-start-failed"); rows=$(grep -c . "$d/state/github-accounting/owner.log")
watch "$d" FM_GITHUB_ACCOUNTING=1; w=$WP; sleep 6
kill -0 "$w" 2>/dev/null && ok "restarted watcher keeps polling inside the hold" || bad "restarted watcher exited: $(cat "$d/watch.out")"
[ "$(grep -c github-accounting-start-failed "$d/state/.wake-queue" 2>/dev/null || true)" = 0 ] && ok "no second wake inside the hold" || bad "second wake"
[ "$(grep -c . "$d/state/github-accounting/owner.log")" = "$rows" ] && [ "$(stat -f %m "$d/state/.github-accounting-start-failed")" = "$mt" ] && ok "no new start attempt inside the hold" || bad "start retried inside the hold"
stopw "$w"
mv "$d/state/github-accounting/observations.sqlite" "$ROOT/moved-foreign"; touch -t 202601010000 "$d/state/.github-accounting-start-failed"
# Adversarial: this watcher follows a TERMed one, so it closes its first cycle on a rearm-resurface wake
# before it can read its start helper's status. The marker must not strand the next watcher.
watch "$d" FM_GITHUB_ACCOUNTING=1; w=$WP
waitfor 60 runs "$d" "" && ok "after the operator moved the file, the retry started an owner" || bad "no retry start"
waitfor 60 gone "$w"; wait "$w" 2>/dev/null; echo "watcher closed its cycle with: $(tail -1 "$d/watch.out")"
[ -e "$d/state/.github-accounting-start-failed" ] && echo "marker still present after that exit (status never read)"
rm -rf "$d/state/.prelude-progress" "$d/state/.prelude-deferred" "$d/state/.watcher-down"
FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" "$WT/bin/fm-wake-drain.sh" > "$d/drain.out" 2> "$d/drain.err"
seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$d/drain.err"); gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$d/drain.err")
[ -z "$seq" ] || FM_STATE_OVERRIDE="$d/state" "$WT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
held=$(published "$d")
watch "$d" FM_GITHUB_ACCOUNTING=1; w=$WP
t0=$SECONDS; if waitfor 120 test ! -e "$d/state/.github-accounting-start-failed"; then ok "marker removed by the success after $((SECONDS-t0)) s"; else bad "marker stayed for 60 s: $(ls -la "$d/state/.github-accounting-start-failed") watcher alive=$(kill -0 "$w" 2>/dev/null && echo yes || echo no) out=$(tail -2 "$d/watch.out") err=$(tail -3 "$d/watch.err") prelude=$(ls -a "$d/state" | tr '\n' ' ')"; fi
[ "$(published "$d")" = "$held" ] && ok "the next watcher's idempotent start left the running owner alone" || bad "owner replaced"
stopw "$w"; own "$d" stop >/dev/null

for label in lab secondmate disabled; do
  echo "--- $label home: never starts the owner"
  d=$(mk "$label"); extra=FM_GITHUB_ACCOUNTING=1
  case $label in
    lab) printf 'fm-lab-home v1\n' > "$d/.fm-lab-home" ;;
    secondmate) printf 'mate\n' > "$d/.fm-secondmate-home" ;;
    disabled) extra=FM_GITHUB_ACCOUNTING=0 ;;
  esac
  watch "$d" "$extra"; w=$WP; sleep 6
  kill -0 "$w" 2>/dev/null && ok "$label watcher kept polling" || bad "$label watcher exited: $(tail -3 "$d/watch.err")"
  [ ! -e "$d/state/github-accounting/observations.sqlite" ] && [ -z "$(published "$d")" ] && ok "$label home started no owner" || bad "$label home started an owner"
  stopw "$w"
done
left=$(pgrep -f "$ROOT" || true); echo "leftover processes naming the scratch root: [${left}]"
rm -rf "$ROOT"; echo "scratch removed: $([ ! -e "$ROOT" ] && echo yes)"
echo "RESULT failures=$fails"; exit "$fails"
