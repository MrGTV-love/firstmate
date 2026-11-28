#!/usr/bin/env bash
# Slack decision plane regressions (core DOD-01..DOD-17 and S1..S3 + Python renderer unit tests).
set -euo pipefail
# shellcheck source=tests/fm-slack-watch-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-slack-watch-helpers.sh"

python3 "$HELPER"

# HELPERS: the assertion helpers give the same verdict however fast their pipe is read. A value larger than the pipe buffer that holds
# the pattern on its first line makes a grep that exits at its first match leave the writer with a broken pipe; under pipefail that must
# neither fail assert_contains nor pass assert_not_contains.
big=$(python3 -c 'print("MATCH-AT-THE-START"); print("\n".join(["x" * 49] * 20000))')
assert_contains "$big" 'MATCH-AT-THE-START' "HELPERS assert_contains on a large value that holds the pattern at its start"
set +e; ( assert_not_contains "$big" 'MATCH-AT-THE-START' "HELPERS" ) >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -ne 0 ] || fail "HELPERS assert_not_contains passed on a large value that holds the pattern"
printf 'ok - HELPERS\n'

# DOD-01
new_home mirror
bind
mirror mirror
assert_eq "$(thread_count)" 4 "DOD-01 first mirror threads"
assert_eq "$(thread_count between)" 1 "DOD-01 between thread"
assert_eq "$(thread_count already-closed)" 0 "DOD-01 closed call thread"
assert_eq "$(thread_count "bad\$id")" 1 "DOD-01 uncertain call thread"
close_terminal between
mirror mirror
assert_eq "$(thread_count)" 4 "DOD-01 second mirror threads"
assert_eq "$(thread_count between)" 1 "DOD-01 no second thread"
printf 'ok - DOD-01\n'

# DOD-02
new_home card-payload
bind
mirror card-payload
python3 "$HELPER" card-payload "$(replay_file)"
python3 -c 'print("PRIVATE_TASK_BODY " + "x" * 45000); print("Option 1: Ship it (ship) - Deploy now\nOption 2: Wait (wait) - Hold current\nRecommendation: wait\nEvidence: /tmp/oversized-evidence.md")' > "$FM_HOME/oversized.body"
(cd "$FM_HOME" && tasks-axi add oversized-card "Oversized decision" --kind captain --repo sample --body-file "$FM_HOME/oversized.body" >/dev/null)
FM_CAPTAIN_HOLD_NOW=2026-10-01T00:00:00Z "$CAPTAIN" hold oversized-card --boundary owner-rule-change --if-no 'Keep the existing release rule' --reason "Select the release approach $(python3 -c 'print("q" * 45000)')" >/dev/null
mirror card-payload >/dev/null
card=$(python3 "$HELPER" card-text "$(replay_file)" oversized-card)
assert_contains "$card" 'Task: oversized-card' "DOD-02 oversized card lost its task id"
assert_contains "$card" 'Decision: Oversized decision' "DOD-02 oversized card lost its decision"
assert_contains "$card" 'Select the release approach' "DOD-02 oversized card lost the held question"
assert_contains "$card" 'Options:' "DOD-02 oversized card lost its option block"
assert_contains "$card" '1. Ship it (ship) - Deploy now' "DOD-02 oversized card lost option 1"
assert_contains "$card" '2. Wait (wait) - Hold current' "DOD-02 oversized card lost option 2"
assert_contains "$card" 'Recommendation: wait' "DOD-02 oversized card lost its recommendation"
assert_contains "$card" 'Evidence: /tmp/oversized-evidence.md' "DOD-02 oversized card lost its evidence"
assert_not_contains "$card" 'PRIVATE_TASK_BODY' "T1 task body leaked into the card"
[ "${#card}" -le 38000 ] || fail "DOD-02 oversized fields exceeded the card budget"
ts=$(thread_field oversized-card ts)
reply_to "$ts" 900.000099 go
out=$(poll card-payload)
assert_eq "$(closed_count "$out")" 1 "DOD-02 oversized call closed"
assert_not_contains "$out" 'transport failure' "DOD-02 the resolution post of an oversized call failed"
assert_contains "$(thread_texts "$ts")" 'Resolved: oversized-card' "DOD-02 oversized call has no resolution notice"
assert_not_contains "$(thread_texts "$ts")" 'PRIVATE_TASK_BODY' "T1 task body leaked into the resolution notice"
assert_eq "$(thread_field oversized-card retired)" True "DOD-02 oversized thread was not retired"
question="Pick the rollout $(python3 -c 'print("r" * 5000)')"
(cd "$FM_HOME" && tasks-axi add long-question "Long question" --kind captain --repo sample --body-file "$FM_HOME/oversized.body" >/dev/null)
FM_CAPTAIN_HOLD_NOW=2026-10-01T00:00:00Z "$CAPTAIN" hold long-question --boundary owner-rule-change --if-no 'Keep the existing release rule' --reason "$question" >/dev/null
mirror card-payload >/dev/null
card=$(python3 "$HELPER" card-text "$(replay_file)" long-question)
assert_contains "$card" "Question: $question" "DOD-02 an under-budget card cut its question"
assert_not_contains "$card" '\.\.\.' "DOD-02 an under-budget card was cut"
python3 "$HELPER" stage-notice "$(state_file)" "$ts" oversized-card 45000
out=$(poll card-payload)
assert_not_contains "$out" 'transport failure' "DOD-02 an oversized post was refused"
assert_contains "$out" "check: slack $ts - oversized notice" "DOD-02 the oversized notice was not published"
assert_contains "$(thread_texts "$ts")" 'Full text remains in the local backlog.' "DOD-02 an oversized post was not cut"
printf 'ok - DOD-02\n'

# DOD-03
new_home typed-reply
bind
out=$(poll typed-reply)
assert_eq "$(closed_count "$out")" 1 "DOD-03 close count"
assert_contains "$out" "closed: typed-call" "DOD-03 task id"
assert_contains "$(answer_line typed-call)" "line one line with tab" "DOD-03 flattened answer"
assert_closed typed-call 1 "DOD-03 open predicate"
printf 'ok - DOD-03\n'

# DOD-04
new_home reaction-answer
bind
mirror reaction-answer >/dev/null
out=$(poll reaction-answer)
assert_eq "$(closed_count "$out")" 1 "DOD-04 reaction close count"
assert_eq "$(answer_line reaction-call)" "wait" "DOD-04 option 2 value is the keyed answer"
assert_eq "$(label_line reaction-call)" "Wait" "DOD-04 option 2 label is the label"
new_home single-char-answer
bind
mirror single-char-answer >/dev/null
out=$(poll single-char-answer)
assert_eq "$(closed_count "$out")" 1 "DOD-04 single-char close count"
assert_eq "$(answer_line single-call)" "wait" "DOD-04 single-char option value"
assert_eq "$(label_line single-call)" "Wait" "DOD-04 single-char option label"
new_home free-nine
bind
mirror free-nine >/dev/null
out=$(poll free-nine)
assert_eq "$(closed_count "$out")" 1 "DOD-04 nine is free text"
assert_eq "$(answer_line free-nine-call)" "9" "DOD-04 nine answer"
printf 'ok - DOD-04\n'

# DOD-05
new_home allowlist
bind
out=$(poll allowlist)
assert_eq "$(closed_count "$out")" 1 "DOD-05 one allowed answer"
assert_closed allow-a 1 "DOD-05 owner answer closed"
for key in allow-b allow-c allow-d; do
  set +e; "$CAPTAIN" open "$key" >/dev/null; rc=$?; set -e
  [ "$rc" = 0 ] || fail "DOD-05 refused reply touched $key"
done
out=$(SLACK_BOT_TOKEN=fixture FM_SLACK_DM_USER=U0TESTOWNER FM_SLACK_ALLOWED_AUTHORS='' \
  "$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/allowlist/transcript.json")
assert_eq "$out" "" "DOD-05 an empty allowlist is off and emits nothing"
out=$(SLACK_BOT_TOKEN=fixture FM_SLACK_DM_USER=U0TESTOWNER FM_SLACK_ALLOWED_AUTHORS=oops \
  "$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/allowlist/transcript.json")
assert_contains "$out" 'slack: refused: allowlist_unparseable' "DOD-05 malformed allowlist reason"
for key in allow-b allow-c allow-d; do
  set +e; "$CAPTAIN" open "$key" >/dev/null; rc=$?; set -e
  [ "$rc" = 0 ] || fail "DOD-05 malformed allowlist touched $key"
done
printf 'ok - DOD-05\n'

# DOD-06 is covered directly by standalone tests/fm-slack-intake-unchanged.test.sh in CI.

# DOD-07
new_home unmatched
bind
out=$(poll unmatched)
assert_eq "$(check_count "$out")" 1 "DOD-07 one check line"
assert_eq "$(closed_count "$out")" 0 "DOD-07 no answer"
assert_eq "$(outbound_count chat.postMessage 900.000001)" 1 "DOD-07 one thread acknowledgement"
new_home unmatched-two
bind
out=$(poll unmatched-two)
assert_eq "$(check_count "$out")" 2 "DOD-07 two distinct wake lines"
printf 'ok - DOD-07\n'

# DOD-08
new_home contradiction
bind
out=$(poll contradiction)
assert_eq "$(check_count "$out")" 1 "DOD-08 one conflict line"
assert_eq "$(closed_count "$out")" 0 "DOD-08 no answer"
assert_contains "$out" 'Wait' "DOD-08 names option 2"
assert_contains "$out" 'Abort' "DOD-08 names option 3"
assert_open conflict-call 0 "DOD-08 call stays open"
assert_contains "$(thread_texts 900.000001)" 'Remove the :two: reaction and reply again, or type 2.' "DOD-08 tap-versus-typed remedy"
sent=$(outbound_count chat.postMessage 900.000001)
out=$(poll contradiction)
assert_eq "$(closed_count "$out")" 0 "DOD-08 (b) a later poll records neither signal"
assert_eq "$(check_count "$out")" 0 "DOD-08 (b) the conflict surfaces once"
assert_eq "$(outbound_count chat.postMessage 900.000001)" "$sent" "DOD-08 (b) no second notice"
assert_open conflict-call 0 "DOD-08 (b) call still open"
reply_to 900.000001 900.000009 2
out=$(poll contradiction)
assert_eq "$(closed_count "$out")" 1 "DOD-08 (b) a fresh typed reply clears the block"
assert_eq "$(answer_line conflict-call)" "wait" "DOD-08 (b) fresh reply recorded"
new_home contradiction
bind
poll contradiction >/dev/null
python3 "$HELPER" unreact "$(replay_file)" 900.000001 two U0TESTOWNER
sent=$(outbound_count chat.postMessage 900.000001)
out=$(poll contradiction)
assert_eq "$(closed_count "$out")" 0 "DOD-08 (b) removing the reaction alone records nothing"
assert_eq "$(check_count "$out")" 0 "DOD-08 (b) removing the reaction alone is quiet"
assert_eq "$(outbound_count chat.postMessage 900.000001)" "$sent" "DOD-08 (b) removing the reaction alone posts nothing"
assert_open conflict-call 0 "DOD-08 (b) call open after the reaction is removed"
reply_to 900.000001 900.000009 3
out=$(poll contradiction)
assert_eq "$(closed_count "$out")" 1 "DOD-08 (b) a reply after removing the reaction answers"
assert_eq "$(answer_line conflict-call)" "abort" "DOD-08 (b) reply after removal recorded"
assert_eq "$(resolution_count conflict-call)" 1 "DOD-08 (b) reply after removal recorded once"
out=$(poll contradiction)
assert_eq "$(closed_count "$out")" 0 "DOD-08 (b) reply after removal is not recorded again"
new_home contradiction-typed
bind
out=$(poll contradiction-typed)
assert_eq "$(check_count "$out")" 1 "DOD-08 typed contradiction line"
assert_eq "$(closed_count "$out")" 0 "DOD-08 typed contradiction no answer"
assert_contains "$(thread_texts 900.000001)" 'Please reply once.' "DOD-08 typed-versus-typed remedy"
out=$(poll contradiction-typed)
assert_eq "$(closed_count "$out")" 0 "DOD-08 (a) a later poll records neither typed reply"
assert_eq "$(check_count "$out")" 0 "DOD-08 (a) the typed conflict surfaces once"
assert_open conflict-call 0 "DOD-08 (a) call still open"
reply_to 900.000001 900.000009 3
out=$(poll contradiction-typed)
assert_eq "$(closed_count "$out")" 1 "DOD-08 (a) a fresh typed reply answers"
assert_eq "$(answer_line conflict-call)" "abort" "DOD-08 (a) fresh reply recorded"
new_home resolution
bind
mirror resolution >/dev/null
reply_to 900.000001 900.000011 "$(python3 -c 'print("a" * 45000)')"
reply_to 900.000001 900.000012 "$(python3 -c 'print("b" * 45000)')"
out=$(poll resolution)
assert_not_contains "$out" 'transport failure' "DOD-08 a long conflict notice failed to post"
assert_eq "$(check_count "$out")" 1 "DOD-08 long conflict surfaces once"
notice=$(python3 "$HELPER" thread-posts "$FM_STATE_OVERRIDE/slack-watch/outbound.jsonl" 900.000001)
assert_contains "$notice" 'aaaaaaaa' "DOD-08 long conflict notice lost the first candidate"
assert_contains "$notice" 'bbbbbbbb' "DOD-08 long conflict notice lost the second candidate"
assert_contains "$notice" 'No answer was recorded. Please reply once.' "DOD-08 long conflict notice lost the remedy"
[ "${#notice}" -lt 1200 ] || fail "DOD-08 long conflict notice is unreadable"
assert_contains "$out" 'aaaaaaaa' "DOD-08 long conflict wake lost the first candidate"
assert_contains "$out" 'bbbbbbbb' "DOD-08 long conflict wake lost the second candidate"
assert_contains "$out" 'Please reply once.' "DOD-08 long conflict wake lost the remedy"
[ "${#out}" -le 480 ] || fail "DOD-08 long conflict wake is unbounded"
assert_open resolve-call 0 "DOD-08 long conflict records nothing"
new_home contradiction
bind
python3 -I - "$FIX/contradiction/transcript.json" "$TMP/wide-conflict.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
card, other = '1792735945.123456', '1792735946.123456'
data['messages'] = [{'ts': card, 'text': 'Seeded decision card', 'user': 'UBOT0123456', 'bot_id': 'BBOT0123456'},
                    {'ts': other, 'text': 'Older decision card', 'user': 'UBOT0123456', 'bot_id': 'BBOT0123456'},
                    {'ts': '1792735947.000001', 'thread_ts': other, 'user': 'U0TESTOWNER', 'text': 'late'}]
data['messages'] += [{'ts': '1792735947.%06d' % (n + 2), 'thread_ts': card, 'user': 'U0TESTOWNER',
                      'text': '0' + letter * 199} for n, letter in enumerate('abcdefghijk')]
data['reactions'] = {card: [{'name': 'three', 'users': ['U0TESTOWNER']}]}
row = data['seed_state']['threads']['conflict-call:2026-10-01T00:00:00Z#0']
row['ts'] = card
data['seed_state']['threads']['conflict-call:2026-09-01T00:00:00Z#0'] = dict(
    row, identity='2026-09-01T00:00:00Z#0', ts=other)
json.dump(data, open(sys.argv[2], 'w'))
PY
"$ROOT/bin/fm-slack-check.sh" arm --replay "$TMP/wide-conflict.json" >/dev/null
out=$("$ROOT/bin/fm-slack-check.sh" check --replay "$TMP/wide-conflict.json")
[ "${#out}" -le 480 ] || fail "DOD-08 wide tap conflict wake is unbounded"
assert_contains "$out" '0aaaaaaaa' "DOD-08 wide tap conflict wake lost the first candidate"
assert_contains "$out" '0bbbbbbbb' "DOD-08 wide tap conflict wake lost the second candidate"
assert_contains "$out" '(+10 more)' "DOD-08 wide tap conflict wake lost the candidate count"
assert_contains "$out" 'Remove the :three: reaction and reply again, or type 3.; +1 queued$' "DOD-08 wide tap conflict wake lost the remedy"
assert_open conflict-call 0 "DOD-08 wide tap conflict records nothing"
new_home reaction-answer
bind
mirror reaction-answer >/dev/null
python3 "$HELPER" react "$(replay_file)" 900.000001 three U0TESTOWNER
out=$(poll reaction-answer)
assert_eq "$(check_count "$out")" 1 "DOD-08 (c) two taps surface once"
assert_eq "$(closed_count "$out")" 0 "DOD-08 (c) two taps record neither"
assert_contains "$(thread_texts 900.000001)" 'Remove all but one reaction.' "DOD-08 tap-versus-tap remedy"
sent=$(outbound_count chat.postMessage 900.000001)
out=$(poll reaction-answer)
assert_eq "$(check_count "$out")" 0 "DOD-08 (c) a later poll is quiet"
assert_eq "$(outbound_count chat.postMessage 900.000001)" "$sent" "DOD-08 (c) no repeated notice"
assert_open reaction-call 0 "DOD-08 (c) call still open"
python3 "$HELPER" unreact "$(replay_file)" 900.000001 three U0TESTOWNER
out=$(poll reaction-answer)
assert_eq "$(closed_count "$out")" 1 "DOD-08 (c) a changed reaction set clears the block"
assert_eq "$(answer_line reaction-call)" "wait" "DOD-08 (c) remaining reaction recorded"
new_home typed-reply
bind
out=$(poll reaction-skipped)
assert_contains "$out" 'refused: typed-call' "DOD-08 (d) the intake skipped the reaction"
assert_open typed-call 0 "DOD-08 (d) call stays open"
sent=$(outbound_count chat.postMessage 900.000001)
out=$(poll reaction-skipped)
assert_not_contains "$out" 'refused:' "DOD-08 (d) a skipped reaction is not re-staged"
assert_eq "$(outbound_count chat.postMessage 900.000001)" "$sent" "DOD-08 (d) no second acknowledgement"
printf 'ok - DOD-08\n'

# DOD-09
new_home duplicate
bind
first=$(poll duplicate)
assert_eq "$(printf '%s\n' "$first" | grep -c '^closed: dup-a$' || true)" 1 "DOD-09 dup-a once"
assert_eq "$(printf '%s\n' "$first" | grep -c '^closed: dup-b$' || true)" 1 "DOD-09 dup-b once"
second=$(poll duplicate)
assert_eq "$(printf '%s\n' "$second" | grep -c '^skipped:' || true)" 0 "DOD-09 a repeat poll invents no skipped line"
assert_eq "$(closed_count "$second")" 0 "DOD-09 a repeat poll closes nothing"
assert_eq "$(resolution_count dup-a)" 1 "DOD-09 one resolution record"
assert_eq "$(resolution_count dup-b)" 1 "DOD-09 one resolution record"
close_terminal dup-c
third=$(poll duplicate)
assert_eq "$(closed_count "$third")" 0 "DOD-09 terminal close not replayed"
assert_eq "$(resolution_count dup-a)" 1 "DOD-09 still one record"
printf 'ok - DOD-09\n'

# DOD-10
new_home resolution
bind
close_terminal resolve-call
poll resolution >/dev/null
assert_eq "$(outbound_count chat.postMessage 900.000001)" 1 "DOD-10 one resolution"
poll resolution >/dev/null
assert_eq "$(outbound_count chat.postMessage 900.000001)" 1 "DOD-10 no second resolution"
new_home reaction-answer
bind
mirror reaction-answer >/dev/null
poll reaction-answer >/dev/null
assert_eq "$(outbound_count chat.postMessage 900.000001)" 2 "DOD-10 Slack answer ack and resolution"
printf 'ok - DOD-10\n'

# DOD-12
new_home no-token
unset SLACK_BOT_TOKEN FM_SLACK_DM_USER FM_SLACK_ALLOWED_AUTHORS
out=$(poll no-token)
assert_eq "$out" "" "DOD-12 silent output"
[ ! -d "$FM_STATE_OVERRIDE/slack-watch" ] || fail "DOD-12 created state"
printf 'ok - DOD-12\n'

# DOD-13
new_home unreachable
bind
first=$( "$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/unreachable/transcript.json" || true)
assert_eq "$(printf '%s\n' "$first" | grep -c '^slack: transport failure:' || true)" 1 "DOD-13 one diagnostic"
second=$( "$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/unreachable/transcript.json" || true)
assert_eq "$(printf '%s\n' "$second" | grep -c '^slack: transport failure:' || true)" 0 "DOD-13 episode quiet"
assert_eq "$(check_count "$first")" 0 "DOD-13 no wake"
assert_eq "$(closed_count "$first")" 0 "DOD-13 no answer"
close_terminal failure-call
assert_closed failure-call 1 "DOD-13 terminal answer works"
new_home rate-limited
bind
first=$( "$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/rate-limited/transcript.json" || true)
assert_contains "$first" 'rate_limited' "DOD-13 rate limit named"
printf 'ok - DOD-13\n'

# DOD-14
new_home missing-scope
bind
out=$(mirror missing-scope)
assert_contains "$out" 'missing reaction scope: reactions:read, users:read' "DOD-14 scope diagnostic"
assert_contains "$(python3 "$HELPER" cards "$(replay_file)")" 'Missing reaction scope:' "DOD-14 card fault signal"
out=$(poll missing-scope)
assert_not_contains "$out" 'missing reaction scope' "DOD-14 diagnostic is once per state change"
assert_contains "$out" 'closed: scope-call' "DOD-14 still answerable"
new_home missing-scope
bind
out=$(poll missing-scope)
assert_eq "$(printf '%s\n' "$out" | grep -c 'missing reaction scope' || true)" 1 "DOD-14 poll diagnostic"
assert_contains "$out" 'closed: scope-call' "DOD-14 first poll still answerable"
printf 'ok - DOD-14\n'

# DOD-15
for pair in 'crash-a after-delivery crash-a-call' 'crash-b after-answer crash-b-call' \
  'crash-release after-delivery crash-release-call'; do
  # shellcheck disable=SC2086
  set -- $pair
  new_home "$1"
  bind
  FM_SLACK_FAULT="$2" "$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/$1/transcript.json" >/dev/null 2>&1 || true
  poll "$1" >/dev/null
  assert_eq "$(resolution_count "$3")" 1 "DOD-15 $1 one record"
  assert_closed "$3" 1 "DOD-15 $1 closed"
  texts=$(thread_texts 900.000001)
  assert_contains "$texts" 'Answer recorded.' "DOD-15 $1 acknowledged as applied"
  assert_not_contains "$texts" 'not applied' "DOD-15 $1 reported as refused"
done
[ "$(task_state crash-release-call)" != "done" ] || fail "DOD-15 a release-mode answer closed the task"
printf 'ok - DOD-15\n'

# DOD-16 is covered directly by standalone tests/fm-slack-secret-scan.test.sh in CI.

# DOD-17
new_home arming
set +e
out=$("$ROOT/bin/fm-slack-check.sh" arm --replay "$FIX/arming/arm.json" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "DOD-17 arm before binding succeeded"
assert_contains "$out" 'source_not_bound' "DOD-17 named refusal"
[ ! -e "$FM_STATE_OVERRIDE/slack.check.sh" ] || fail "DOD-17 refusal left a shim"
bind
"$ROOT/bin/fm-slack-check.sh" arm --replay "$FIX/arming/arm.json" >/dev/null
[ -f "$FM_STATE_OVERRIDE/slack.check.sh" ] && [ -f "$FM_STATE_OVERRIDE/slack.check-trust" ] \
  || fail "DOD-17 arm did not register"
# The two runs of the registered check file below are reserved to Main and the grader (Main 2180).
if fm_slack_registered_allowed "DOD-17 [token empty]"; then
  set +e
  out=$(SLACK_BOT_TOKEN='' "$FM_STATE_OVERRIDE/slack.check.sh" 2>&1); rc=$?
  set -e
  assert_eq "$rc" 0 "DOD-17 the armed shim exits cleanly when Slack is off"
  assert_eq "$out" "" "DOD-17 the armed shim is silent when Slack is off"
fi
if fm_slack_registered_allowed "DOD-17 [allowlist empty]"; then
  set +e
  out=$(FM_SLACK_ALLOWED_AUTHORS='' "$FM_STATE_OVERRIDE/slack.check.sh" 2>&1); rc=$?
  set -e
  assert_eq "$rc" 0 "DOD-17 the armed shim exits cleanly with an empty allowlist"
  assert_eq "$out" "" "DOD-17 the armed shim is silent with an empty allowlist"
fi
python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); d["action"] = "disarm"; json.dump(d, open(sys.argv[2], "w"))' \
  "$FIX/arming/arm.json" "$TMP/action-key.json"
"$ROOT/bin/fm-slack-check.sh" --replay "$TMP/action-key.json" >/dev/null
[ -f "$FM_STATE_OVERRIDE/slack.check.sh" ] || fail "DOD-17 a transcript action key disarmed the check"
out=$("$ROOT/bin/fm-slack-check.sh" check --replay "$FIX/arming/check.json")
assert_eq "$(printf '%s\n' "$out" | grep -c .)" 1 "DOD-17 one check line"
"$ROOT/bin/fm-slack-check.sh" disarm >/dev/null
out=$("$ROOT/bin/fm-slack-check.sh" check --replay "$FIX/arming/check.json")
assert_eq "$out" "" "DOD-17 disarmed check silent"
new_home arming
bind
set +e
out=$("$ROOT/bin/fm-slack-check.sh" arm --replay "$FIX/arming/unreachable-dm.json" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "DOD-17 unreachable DM arm succeeded"
assert_contains "$out" 'unreachable' "DOD-17 DM refusal named"
[ ! -e "$FM_STATE_OVERRIDE/slack.check.sh" ] || fail "DOD-17 failed arm left a shim"
printf 'ok - DOD-17\n'

# S1
new_home long-text
bind
out=$(poll long-text)
assert_eq "$(closed_count "$out")" 1 "S1 close"
line=$(answer_line long-call)
# wc -m counts bytes without a UTF-8 locale; pin one so the count is characters.
[ "$(printf '%s' "$line" | LC_ALL=C.UTF-8 wc -m | tr -d ' ')" -le 512 ] || fail "S1 answer exceeded intake limit"
assert_contains "$line" 'Keep exact words.' "S1 the answer starts with the reply"
assert_eq "$(find "$FM_HOME/state" -name 'full-*' | wc -l | tr -d ' ')" 0 "S1 a raw-text copy of the reply was kept"
assert_not_contains "$(label_line long-call)" 'full text' "S1 the label points at a copy"
printf 'ok - S1\n'

# S2
new_home config
base_env=(SLACK_BOT_TOKEN=fixture FM_SLACK_DM_USER=U0TESTOWNER FM_SLACK_ALLOWED_AUTHORS=U0TESTOWNER)
run_unset() {  # <variable> <script> [args...]; the variable is left out of the environment
  local var=$1 script=$2 item
  local -a args=()
  shift 2
  for item in "${base_env[@]}"; do
    [ "${item%%=*}" = "$var" ] || args+=("$item")
  done
  env "${args[@]}" "$ROOT/bin/$script" "$@" 2>&1 || true
}
run_with() {  # <assignment> <script> [args...]; the assignment overrides the base environment
  local assignment=$1 script=$2
  shift 2
  env "${base_env[@]}" "$assignment" "$ROOT/bin/$script" "$@" 2>&1 || true
}
CHECK_REPLAY="$FIX/config/unset.json"
ARM_REPLAY="$FIX/arming/arm.json"
assert_eq "$(run_unset SLACK_BOT_TOKEN fm-slack-check.sh check --replay "$CHECK_REPLAY")" "" "S2 token unset is off"
assert_eq "$(run_unset SLACK_BOT_TOKEN fm-slack-poll.sh --replay "$CHECK_REPLAY")" "" "S2 token unset poll is off"
assert_eq "$(run_unset FM_SLACK_ALLOWED_AUTHORS fm-slack-check.sh check --replay "$CHECK_REPLAY")" "" "S2 empty allowlist check is off"
assert_eq "$(run_unset FM_SLACK_ALLOWED_AUTHORS fm-slack-poll.sh --replay "$CHECK_REPLAY")" "" "S2 empty allowlist poll is off"
assert_eq "$(run_unset FM_SLACK_POLL_MAX_ANSWERS fm-slack-check.sh check --replay "$CHECK_REPLAY")" "" "S2 poll cap default"
for bad in FM_SLACK_ALLOWED_AUTHORS=oops FM_SLACK_DM_USER=not-a-member FM_SLACK_POLL_MAX_ANSWERS=0 \
  FM_SLACK_POLL_MAX_ANSWERS=201 FM_SLACK_POLL_MAX_ANSWERS=many; do
  assert_eq "$(run_with "$bad" fm-slack-check.sh check --replay "$CHECK_REPLAY")" "" \
    "S2 the standing check stays silent on [$bad]"
done
assert_contains "$(run_with FM_SLACK_ALLOWED_AUTHORS=oops fm-slack-poll.sh --replay "$CHECK_REPLAY")" 'slack: refused: allowlist_unparseable' "S2 allowlist refusal by hand"
assert_contains "$(run_with FM_SLACK_DM_USER=not-a-member fm-slack-poll.sh --replay "$CHECK_REPLAY")" 'slack: refused: missing_or_invalid_FM_SLACK_DM_USER' "S2 DM refusal by hand"
assert_contains "$(run_with FM_SLACK_POLL_MAX_ANSWERS=0 fm-slack-poll.sh --replay "$CHECK_REPLAY")" 'slack: refused: invalid_FM_SLACK_POLL_MAX_ANSWERS_1_to_200' "S2 poll cap refusal by hand"
assert_contains "$(run_unset FM_SLACK_DM_USER fm-slack-check.sh arm --replay "$ARM_REPLAY")" 'slack: refused: missing_or_invalid_FM_SLACK_DM_USER' "S2 arm names an unusable DM user"
assert_contains "$(run_with FM_SLACK_ALLOWED_AUTHORS=oops fm-slack-check.sh arm --replay "$ARM_REPLAY")" 'slack: refused: allowlist_unparseable' "S2 arm names an unusable allowlist"
[ ! -e "$FM_STATE_OVERRIDE/slack.check.sh" ] || fail "S2 a refused arm left a check"
without() {  # <variable> <command> [args...]; the variable is left out of the environment
  local var=$1 item
  local -a args=()
  shift
  for item in "${base_env[@]}"; do
    [ "${item%%=*}" = "$var" ] || args+=("$item")
  done
  env "${args[@]}" "$@"
}
for var in SLACK_BOT_TOKEN FM_SLACK_ALLOWED_AUTHORS; do
  set +e
  out=$(without "$var" "$ROOT/bin/fm-slack-check.sh" arm --replay "$ARM_REPLAY" 2>"$TMP/arm.err"); rc=$?
  set -e
  assert_eq "$out" "" "S2 arm without $var wrote to stdout"
  assert_contains "$(cat "$TMP/arm.err")" 'slack: refused: unconfigured' "S2 arm names an unconfigured home without $var on stderr"
  [ "$rc" -ne 0 ] || fail "S2 arm without $var exited zero"
  [ ! -e "$FM_STATE_OVERRIDE/slack.check.sh" ] || fail "S2 arm without $var left a check"
  set +e
  out=$(without "$var" "$ROOT/bin/fm-slack-check.sh" check --replay "$CHECK_REPLAY" 2>"$TMP/check.err"); rc=$?
  set -e
  assert_eq "$out" "" "S2 the periodic check without $var wrote to stdout"
  assert_eq "$(cat "$TMP/check.err")" "" "S2 the periodic check without $var wrote to stderr"
  assert_eq "$rc" 0 "S2 the periodic check without $var exited nonzero"
done
printf 'ok - S2\n'

# S3
new_home backlog
bind
export FM_SLACK_POLL_MAX_ANSWERS=2
assert_eq "$(closed_count "$(poll backlog)")" 2 "S3 first poll"
assert_eq "$(closed_count "$(poll backlog)")" 2 "S3 second poll"
assert_eq "$(closed_count "$(poll backlog)")" 1 "S3 third poll"
assert_eq "$(closed_count "$(poll backlog)")" 0 "S3 fourth poll"
unset FM_SLACK_POLL_MAX_ANSWERS
printf 'ok - S3\n'

printf 'ok - Slack watch core checks\n'
