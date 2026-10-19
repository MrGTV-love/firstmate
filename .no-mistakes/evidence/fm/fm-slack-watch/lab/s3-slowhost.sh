#!/usr/bin/env bash
# S3.8: slow host. The keyed-answer intake takes 25s (> the client's 20s per-process budget).
# Expectation: nothing is lost or duplicated; the answer lands once and the Slack ack/resolution catch up on later polls.
set -uo pipefail
. "$(dirname "$0")/lab.sh"
FAILED=0
lab_start || exit 1
trap lab_stop EXIT
new_home duplicate
mirror >/dev/null; T=$(thread_ts dup-a)
reply "$T" "1" "user=$OWNER"
for p in 1 2 3 4; do
  s=$SECONDS
  if [ "$p" = 1 ]; then o=$(LAB_SLOW_ANSWERS=25 poll 2>&1); rc=$?; else o=$(poll 2>&1); rc=$?; fi
  echo "poll$p rc=$rc elapsed=$((SECONDS-s))s out=[$o] bot-msgs=$(bot_count "$T") open=$(is_open dup-a) pending=$(python3 -c 'import json,sys; print([ (p["kind"],p["stage"]) for p in json.load(open(sys.argv[1]))["pending"]])' "$FM_STATE_OVERRIDE/slack-watch/state.json")"
done
thread_texts "$T" | grep -A1 '^--- BOT' | grep -v '^--$' | tail -8
expect_eq "$(is_open dup-a)" closed "call closed"
expect_eq "$("$REPO/bin/fm-tasks-axi.sh" show dup-a --full | grep -o 'Resolution recorded by fm-captain-hold\.' | wc -l | tr -d ' ')" 1 "exactly one resolution record"
expect_eq "$(bot_count "$T")" 3 "card + one ack + one resolution (caught up)"
[ "$FAILED" = 0 ] && echo "S3.8 RESULT: ALL PASS" || echo "S3.8 RESULT: FAILURES"
exit $FAILED
