#!/usr/bin/env bash
# S3: conflict, outage/rate-limit/bad-token, crash recovery, missing scope, unmatched late reply, duplicate polls.
set -uo pipefail
. "$(dirname "$0")/lab.sh"
FAILED=0
lab_start || exit 1
trap lab_stop EXIT

step "S3.1 tap :two: AND type 3 -> conflict surfaces once, nothing recorded, call stays open"
new_home reaction-answer
mirror >/dev/null; T=$(thread_ts reaction-call)
react "$T" two "user=$OWNER"; reply "$T" "3" "user=$OWNER"
out=$(poll); echo "poll1: [$out]"
expect_has "$out" 'conflicting signals' "wake line names conflict"
expect_not "$out" 'closed:' "no close"
expect_eq "$(is_open reaction-call)" open "call open"
expect_has "$(thread_texts "$T")" 'No answer was recorded.' "thread notice says nothing recorded"
out=$(poll); echo "poll2: [$out]"; expect_eq "$out" "" "second poll silent (surfaces once)"
reply "$T" "2" "user=$OWNER"
out=$(poll); echo "poll3: [$out]"
expect_has "$out" 'closed: reaction-call' "fresh typed reply resolves it"
expect_eq "$(answer_line reaction-call)" wait "recorded option 2"

step "S3.2 outage: Slack 503 on thread reads -> named once, then quiet; terminal path and recovery intact"
new_home rate-limited
mirror >/dev/null; T=$(thread_ts failure-call)
reply "$T" "2" "user=$OWNER"
admin fail "method=conversations.replies" "status=503" "times=-1" >/dev/null
out=$(poll); echo "poll1: [$out]"
expect_has "$out" 'slack: transport failure:' "failure named"
expect_eq "$(printf '%s\n' "$out" | grep -c 'transport failure')" 1 "exactly one failure line"
out2=$(poll); echo "poll2: [$out2]"; expect_eq "$out2" "" "same episode stays quiet"
expect_eq "$(is_open failure-call)" open "call still open (reply not lost, not applied)"
admin clearfail >/dev/null
out=$(poll); echo "poll after recovery: [$out]"
expect_has "$out" 'closed: failure-call' "queued owner reply delivered after recovery"
expect_eq "$(answer_line failure-call)" wait "recorded"

step "S3.2b rate limit (HTTP 429) is named; bad token is named without echoing the token"
new_home rate-limited
mirror >/dev/null
admin fail "method=conversations.replies" "status=429" "times=-1" >/dev/null
out=$(poll); echo "429 poll: [$out]"; expect_has "$out" 'rate_limited' "rate limit named"
admin clearfail >/dev/null
new_home rate-limited "SLACK_BOT_TOKEN=xoxb-lab-WRONG-token-9999"
out=$(poll 2>&1); echo "bad token poll: [$out]"
expect_has "$out" 'invalid_auth' "invalid_auth named"
expect_not "$out" 'xoxb-lab-WRONG-token-9999' "bad token never echoed"
expect_eq "$(grep -rl -- 'xoxb-lab-WRONG-token-9999' "$FM_STATE_OVERRIDE" "$FM_DATA_OVERRIDE" 2>/dev/null | wc -l | tr -d ' ')" 0 "bad token not in state"

step "S3.3 crash after intake applied, before ack journaled: rerun records ONCE and acks 'Answer recorded.'"
for FAULT in after-delivery after-answer; do
  new_home crash-a
  mirror >/dev/null; T=$(thread_ts crash-a-call)
  reply "$T" "1" "user=$OWNER"
  FM_SLACK_FAULT=$FAULT poll >/dev/null 2>&1; rc=$?
  echo "$FAULT first run rc=$rc"; expect_eq "$rc" 75 "$FAULT crashed the poll"
  out=$(poll); echo "$FAULT rerun: [$out]"
  expect_eq "$(is_open crash-a-call)" closed "$FAULT: call closed after rerun"
  expect_eq "$("$REPO/bin/fm-tasks-axi.sh" show crash-a-call --full | grep -o 'Resolution recorded by fm-captain-hold\.' | wc -l | tr -d ' ')" 1 "$FAULT: exactly one resolution record"
  expect_has "$(thread_texts "$T")" 'Answer recorded.' "$FAULT: ack says recorded"
  expect_not "$(thread_texts "$T")" 'not applied' "$FAULT: no false 'not applied'"
  out=$(poll); expect_eq "$out" "" "$FAULT: later poll silent"
done

step "S3.4 reactions scopes revoked: card falls back to typed numbers; one scope notice; typed answer works"
admin scopes "list=chat:write,im:write,im:history" >/dev/null
new_home missing-scope
out=$(mirror); echo "mirror: [$out]"
expect_has "$out" 'missing reaction scope: reactions:read, users:read' "scope diagnostic"
T=$(thread_ts scope-call)
expect_has "$(thread_texts "$T")" 'Affordance: single-character' "card does not advertise taps"
expect_has "$(thread_texts "$T")" 'Reply in this thread with the option number.' "typed fallback"
out=$(mirror); expect_eq "$out" "" "scope diagnostic reported once"
reply "$T" "3" "user=$OWNER"
out=$(poll); echo "poll: [$out]"; expect_has "$out" 'closed: scope-call' "typed answer still works"
expect_eq "$(answer_line scope-call)" abort "option 3 value"
admin scopes "list=chat:write,im:write,im:history,reactions:read,reactions:write,users:read" >/dev/null

step "S3.5 late reply on a call already closed in the terminal is surfaced, never applied"
new_home unmatched
mirror >/dev/null
# unmatched scenario has no task; use a real one instead
new_home typed-reply
mirror >/dev/null; T=$(thread_ts typed-call)
printf 'closed in terminal\n' > "$FM_HOME/decision.txt"; "$CAPTAIN" answer typed-call --decision-file "$FM_HOME/decision.txt" >/dev/null
reply "$T" "ship" "user=$OWNER"
out=$(poll); echo "poll: [$out]"
expect_has "$out" "unmatched reply" "wake line names unmatched reply"
expect_not "$out" 'closed:' "not applied"
expect_has "$(thread_texts "$T")" 'No open decision matches this reply.' "thread told"
expect_has "$("$REPO/bin/fm-tasks-axi.sh" show typed-call --full)" 'Captain decision:\nclosed in terminal' "record is still the terminal answer"
expect_not "$("$REPO/bin/fm-tasks-axi.sh" show typed-call --full)" 'through slack-dm' "late Slack reply was never recorded"

step "S3.6 repeated polls after an answer never double-record or re-post"
new_home duplicate
mirror >/dev/null; T=$(thread_ts dup-a)
reply "$T" "1" "user=$OWNER"
o1=$(poll); n1=$(bot_count "$T"); echo "poll1: [$o1] bot msgs in thread: $n1"; thread_texts "$T" | grep -c '^--- BOT' ; o2=$(poll); o3=$(poll); n2=$(bot_count "$T")
echo "poll2: [$o2] poll3: [$o3] bot msgs: $n2"
expect_eq "$n1" 3 "card + ack + resolution posted"
expect_eq "$n2" "$n1" "no extra Slack posts on repeat polls"
expect_eq "$("$REPO/bin/fm-tasks-axi.sh" show dup-a --full | grep -o 'Resolution recorded by fm-captain-hold\.' | wc -l | tr -d ' ')" 1 "one resolution record"

step "S3.7 hostile text: Slack-escaped typed reply is recorded as typed; reserved 'reconcile' never answers"
new_home free-nine
mirror >/dev/null; T=$(thread_ts free-nine-call)
reply "$T" "reconcile" "user=$OWNER"
out=$(poll); echo "reconcile poll: [$out]"
expect_not "$out" 'closed:' "reserved value does not close"
expect_eq "$(is_open free-nine-call)" open "still open"
reply "$T" 'ship &lt;now&gt; &amp; <https://example.com|docs>' "user=$OWNER"
out=$(poll); echo "poll: [$out]"
expect_has "$out" 'closed: free-nine-call' "free text closes"
expect_eq "$(answer_line free-nine-call)" 'ship <now> & docs' "unescaped as the owner typed it"

[ "$FAILED" = 0 ] && echo "S3 RESULT: ALL PASS" || echo "S3 RESULT: FAILURES"
exit $FAILED
