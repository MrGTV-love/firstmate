#!/usr/bin/env bash
# Slack decision plane regressions DOD-01..DOD-17, S1..S3, X1..X22.
# Every Slack call is a checked-in replay transcript; no socket is opened.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v tasks-axi >/dev/null || { printf 'skip: tasks-axi not found\n'; exit 0; }
TMP=$(fm_test_tmproot fm-slack-watch)
FIX="$ROOT/tests/fixtures/slack"
CAPTAIN="$ROOT/bin/fm-captain-hold.sh"

assert_eq() { [ "$1" = "$2" ] || fail "$3: expected [$2], got [$1]"; }
assert_contains() { printf '%s' "$1" | grep -q -- "$2" || fail "$3: missing [$2]"; }
assert_not_contains() { ! printf '%s' "$1" | grep -q -- "$2" || fail "$3: unexpected [$2]"; }
assert_open() {
  set +e; "$CAPTAIN" open "$1" >/dev/null; rc=$?; set -e
  [ "$rc" = "${2:-0}" ] || fail "$3: open $1 rc=$rc"
}
assert_closed() {
  set +e; "$CAPTAIN" open "$1" >/dev/null; rc=$?; set -e
  [ "$rc" = "${2:-1}" ] || fail "$3: open $1 rc=$rc"
}

new_home() {  # <scenario>
  HOME_DIR=$(mktemp -d "$TMP/home.XXXXXX")
  bash "$FIX/make-home.sh" "$1" "$HOME_DIR" >/dev/null
  export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config"
}

bind() { "$CAPTAIN" bind slack-dm >/dev/null; }
mirror() { "$ROOT/bin/fm-slack-mirror.sh" --replay "$FIX/$1/transcript.json"; }
poll() { "$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/$1/transcript.json"; }
closed_count() { printf '%s\n' "$1" | grep -c '^closed: ' || true; }
check_count() { printf '%s\n' "$1" | grep -c '^check: ' || true; }
state_file() { printf '%s/slack-watch/state.json' "$FM_STATE_OVERRIDE"; }
HELPER="$ROOT/tests/fm_slack_watch_test.py"
replay_file() { python3 "$HELPER" replay-file "$FM_STATE_OVERRIDE/slack-watch"; }
thread_count() { python3 "$HELPER" thread-count "$(state_file)" "${1:-}"; }
outbound_count() { python3 "$HELPER" outbound-count "$FM_STATE_OVERRIDE/slack-watch/outbound.jsonl" "$1" "${2:-}"; }
resolution_count() {  # <task-id>
  "$ROOT/bin/fm-tasks-axi.sh" show "$1" --full \
    | grep -o 'Resolution recorded by fm-captain-hold\.' | wc -l | tr -d ' '
}
answer_line() {  # <task-id>
  "$ROOT/bin/fm-tasks-axi.sh" show "$1" --full \
    | grep -o 'Answer: [^"]*' | sed 's/^Answer: //' | sed 's/\\n.*//' | tr -d '\n'
}
label_line() {  # <task-id>
  "$ROOT/bin/fm-tasks-axi.sh" show "$1" --full \
    | grep -o 'Answer as shown to the captain: [^"]*' | sed 's/^Answer as shown to the captain: //' | sed 's/\\n.*//' | tr -d '\n'
}
task_state() {  # <task-id>
  "$ROOT/bin/fm-tasks-axi.sh" show "$1" | sed -n 's/^  state: //p'
}
write_board() {  # <generated> <captains-call-json-array>
  mkdir -p "$FM_HOME/.lavish"
  printf '<html><script id="bearings-data" type="application/json">{"schema":"fm-bearings-board.v1","generated":"%s","captains_call":%s}</script></html>\n' \
    "$1" "$2" > "$FM_HOME/.lavish/bearings-board.html"
}
thread_field() { python3 "$HELPER" thread-field "$(state_file)" "$1" "$2"; }
thread_texts() { python3 "$HELPER" thread-texts "$(replay_file)" "$1"; }
reply_to() {  # <thread-ts> <ts> <text>
  python3 "$HELPER" reply "$(replay_file)" "$1" "$2" U0TESTOWNER "$3"
}
close_terminal() {  # <task-id>
  printf 'terminal fixture answer\n' > "$FM_HOME/decision.txt"
  "$CAPTAIN" answer "$1" --decision-file "$FM_HOME/decision.txt" >/dev/null
}

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
FM_CAPTAIN_HOLD_NOW=2026-10-01T00:00:00Z "$CAPTAIN" hold oversized-card --reason "Select the release approach $(python3 -c 'print("q" * 45000)')" >/dev/null
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
assert_contains "$card" 'If you both tap and type: a disagreement surfaces to the captain and neither signal is recorded as the answer.' "DOD-02 oversized card lost precedence"
assert_not_contains "$card" 'PRIVATE_TASK_BODY' "T1 task body leaked into the card"
[ "${#card}" -le 38000 ] || fail "DOD-02 oversized fields exceeded the card budget"
assert_contains "$card" 'or reply in this thread with the option number.' "DOD-02 oversized card lost the reply instruction"
assert_contains "$card" 'Messages typed in the main DM window are not read.' "DOD-02 oversized card lost the main-window note"
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
FM_CAPTAIN_HOLD_NOW=2026-10-01T00:00:00Z "$CAPTAIN" hold long-question --reason "$question" >/dev/null
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
assert_contains "$(python3 "$HELPER" cards "$(replay_file)")" 'Affordance: reaction' "DOD-04 reaction affordance"
out=$(poll reaction-answer)
assert_eq "$(closed_count "$out")" 1 "DOD-04 reaction close count"
assert_eq "$(answer_line reaction-call)" "wait" "DOD-04 option 2 value is the keyed answer"
assert_eq "$(label_line reaction-call)" "Wait" "DOD-04 option 2 label is the label"
new_home single-char-answer
bind
mirror single-char-answer >/dev/null
assert_contains "$(python3 "$HELPER" cards "$(replay_file)")" 'Affordance: single-character' "DOD-04 single-character affordance"
assert_contains "$(python3 "$HELPER" cards "$(replay_file)")" 'Reply in this thread with the option number.' "DOD-04 single-character reply place"
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

# DOD-06
assert_contains "$(bash "$ROOT/tests/fm-slack-intake-unchanged.test.sh")" 'ok - intake refusals hold' "DOD-06"
printf 'ok - DOD-06\n'

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
assert_contains "$(thread_texts 900.000001)" 'Remove the :two: reaction, or type 2.' "DOD-08 tap-versus-typed remedy"
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
cards=$(python3 "$HELPER" cards "$(replay_file)")
assert_contains "$cards" 'Affordance: single-character' "DOD-14 affordance"
assert_contains "$cards" 'Reply in this thread with the option number.' "DOD-14 reply place"
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

# DOD-16 (separate scan)
assert_contains "$(bash "$ROOT/tests/fm-slack-secret-scan.test.sh")" 'ok - scan redacted' "DOD-16"
printf 'ok - DOD-16\n'

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
set +e
out=$(SLACK_BOT_TOKEN='' "$FM_STATE_OVERRIDE/slack.check.sh" 2>&1); rc=$?
set -e
assert_eq "$rc" 0 "DOD-17 the armed shim exits cleanly when Slack is off"
assert_eq "$out" "" "DOD-17 the armed shim is silent when Slack is off"
set +e
out=$(FM_SLACK_ALLOWED_AUTHORS='' "$FM_STATE_OVERRIDE/slack.check.sh" 2>&1); rc=$?
set -e
assert_eq "$rc" 0 "DOD-17 the armed shim exits cleanly with an empty allowlist"
assert_eq "$out" "" "DOD-17 the armed shim is silent with an empty allowlist"
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
[ "$(printf '%s' "$line" | wc -m | tr -d ' ')" -le 512 ] || fail "S1 answer exceeded intake limit"
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

# A copy of the Slack entry points whose intake wrapper can fail on demand, so
# transient intake and call-state failures are exercised without touching the
# real intake. FM_SHIM_* name flag files; FM_SHIM_LOG records every intake call.
make_shim() {
  local dir="$TMP/shim"
  mkdir -p "$dir"
  cp "$ROOT/bin/fm-slack-lib.sh" "$ROOT/bin/fm-slack-poll.sh" "$ROOT/bin/fm-slack-mirror.sh" \
    "$ROOT/bin/fm-env-lib.sh" "$ROOT/bin/fm_slack.py" "$ROOT/bin/fm_slack_replay.py" \
    "$ROOT/bin/fm_slack_watch.py" "$dir/"
  cat > "$dir/fm-fleet-snapshot.sh" <<SH
#!/usr/bin/env bash
[ -z "\${FM_SHIM_ENVLOG:-}" ] || printf '%s\\n' "\${SLACK_BOT_TOKEN:-unset}" >> "\$FM_SHIM_ENVLOG"
exec bash "$ROOT/bin/fm-fleet-snapshot.sh" "\$@"
SH
  cat > "$dir/fm-captain-hold.sh" <<SH
#!/usr/bin/env bash
[ -z "\${FM_SHIM_LOG:-}" ] || printf '%s\\n' "\$*" >> "\$FM_SHIM_LOG"
[ -z "\${FM_SHIM_ENVLOG:-}" ] || printf '%s\\n' "\${SLACK_BOT_TOKEN:-unset}" >> "\$FM_SHIM_ENVLOG"
if [ "\${1:-}" = open ] && [ -f "\${FM_SHIM_OPEN_FAIL:-/nonexistent}" ]; then exit 2; fi
if [ "\${1:-}" = answers ] && [ -f "\${FM_SHIM_ANSWERS_FAIL:-/nonexistent}" ]; then
  echo 'fm-captain-hold: simulated backlog read bound' >&2
  exit 1
fi
if [ "\${1:-}" = answers ] && [ -f "\${FM_SHIM_ANSWERS_NOTE:-/nonexistent}" ]; then
  out=\$(bash "$ROOT/bin/fm-captain-hold.sh" "\$@"); rc=\$?
  printf '%s\\n' "\$out"
  echo 'simulated parent delivery problem' >&2
  exit "\$rc"
fi
exec bash "$ROOT/bin/fm-captain-hold.sh" "\$@"
SH
  chmod +x "$dir/fm-fleet-snapshot.sh" "$dir/fm-captain-hold.sh"
  printf '%s' "$dir"
}
SHIM=$(make_shim)
shim_poll() { env "$@" "$SHIM/fm-slack-poll.sh" --replay "$FIX/$SHIM_FIXTURE/transcript.json"; }

# X1: a reply in a replaced hold's thread never answers the newer hold
rehold() {  # <task-id>
  printf 'released for rework\n' > "$FM_HOME/decision.txt"
  "$CAPTAIN" answer "$1" --decision-file "$FM_HOME/decision.txt" --release >/dev/null
  FM_CAPTAIN_HOLD_NOW=2026-10-02T00:00:00Z "$CAPTAIN" hold "$1" --reason "Second round" >/dev/null
}
new_home reaction-answer
bind
mirror reaction-answer >/dev/null
rehold reaction-call
out=$(poll reaction-answer)
assert_eq "$(closed_count "$out")" 0 "X1 a stale reaction answered the newer hold"
assert_open reaction-call 0 "X1 newer hold stays open"
assert_eq "$(thread_count reaction-call)" 2 "X1 newer hold has its own thread"
assert_eq "$(thread_field reaction-call retired)" True "X1 superseded thread retired"
new_home reaction-answer
bind
mirror reaction-answer >/dev/null
: > "$TMP/answers-fail"
SHIM_FIXTURE=reaction-answer shim_poll FM_SHIM_ANSWERS_FAIL="$TMP/answers-fail" >/dev/null 2>&1 || true
rm -f "$TMP/answers-fail"
assert_eq "$(python3 "$HELPER" pending-count "$(state_file)")" 1 "X1 the tap is staged before the re-hold"
rehold reaction-call
out=$(poll reaction-answer)
assert_eq "$(closed_count "$out")" 0 "X1 a staged answer reached the newer hold"
assert_contains "$out" 'replaced hold' "X1 staged answer surfaces for firstmate"
assert_open reaction-call 0 "X1 staged answer left the newer hold open"
assert_contains "$(thread_texts 900.000001)" 'Answer not applied' "X1 staged answer is told it was not applied"
new_home typed-reply
bind
out=$(poll typed-reply)
assert_contains "$out" 'closed: typed-call' "X1 a live hold still takes its own thread's answer"
printf 'ok - X1\n'

# X2: an unbound source feeds nothing, from either entry point
new_home typed-reply
"$ROOT/bin/fm-slack-check.sh" arm --replay "$FIX/typed-reply/transcript.json" >/dev/null
"$CAPTAIN" unbind slack-dm >/dev/null
assert_eq "$("$ROOT/bin/fm-slack-check.sh" check --replay "$FIX/typed-reply/transcript.json")" "" "X2 unbound check output"
assert_eq "$(poll typed-reply)" "" "X2 unbound poll output"
assert_open typed-call 0 "X2 unbound source answered a call"
bind
out=$("$ROOT/bin/fm-slack-check.sh" check --replay "$FIX/typed-reply/transcript.json")
assert_contains "$out" 'closed: typed-call' "X2 rebound check answers"
printf 'ok - X2\n'

# X3: disarm is the hard off switch whatever the configuration
new_home arming
bind
armed() { [ -e "$FM_STATE_OVERRIDE/slack.check.sh" ] || [ -e "$FM_STATE_OVERRIDE/slack.check-trust" ]; }
for broken in 'SLACK_BOT_TOKEN=' 'FM_SLACK_ALLOWED_AUTHORS=oops'; do
  "$ROOT/bin/fm-slack-check.sh" arm --replay "$FIX/arming/arm.json" >/dev/null
  armed || fail "X3 arm did not register"
  out=$(env "$broken" "$ROOT/bin/fm-slack-check.sh" disarm)
  assert_contains "$out" 'disarmed:' "X3 disarm under [$broken]"
  ! armed || fail "X3 disarm under [$broken] left the check registered"
done
"$ROOT/bin/fm-slack-check.sh" arm --replay "$FIX/arming/arm.json" >/dev/null
rm -f "$FM_STATE_OVERRIDE/slack.check.sh"
ln -s "$FM_HOME/data" "$FM_STATE_OVERRIDE/slack.check.sh"
set +e
out=$("$ROOT/bin/fm-slack-check.sh" disarm 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "X3 disarm reported success for an unsafe check"
assert_not_contains "$out" 'disarmed:' "X3 disarm claimed an unsafe removal"
assert_contains "$out" 'slack: refused' "X3 disarm names the refusal"
rm -f "$FM_STATE_OVERRIDE/slack.check.sh"
printf 'ok - X3\n'

# X4: a board card steers a thread only when the board is newer than the hold
board_cards='[{"key":"with-options","close":"release","options":[{"value":"board-a","label":"Board A"},{"value":"board-b","label":"Board B"}],"recommend_value":"board-a"}]'
text_only_case() {  # <generated>
  new_home card-payload
  bind
  write_board "$1" "$board_cards"
  mirror card-payload >/dev/null
  card=$(python3 "$HELPER" card-text "$(replay_file)" with-options)
  assert_not_contains "$card" 'Board A' "X4 [$1] a board card that is not newer steered the thread"
  assert_not_contains "$card" 'Options:' "X4 [$1] text-only card offered options"
  assert_not_contains "$card" 'React with' "X4 [$1] text-only card advertised taps"
  assert_contains "$card" 'Affordance: text' "X4 [$1] text-only affordance"
  assert_contains "$card" 'Reply in this thread with your answer.' "X4 [$1] text-only reply place"
  ts=$(thread_field with-options ts)
  assert_eq "$(python3 "$HELPER" reaction-count "$FM_STATE_OVERRIDE/slack-watch/outbound.jsonl" "$ts")" 0 "X4 [$1] seeded reactions"
  reply_to "$ts" 900.000099 1
  out=$(poll card-payload)
  assert_eq "$(closed_count "$out")" 1 "X4 [$1] free text answers"
  assert_eq "$(answer_line with-options)" "1" "X4 [$1] free text recorded verbatim"
  assert_eq "$(task_state with-options)" "done" "X4 [$1] stale card chose the close mode"
}
text_only_case 2026-09-30T00:00Z
text_only_case 2026-10-01T00:00Z
new_home card-payload
bind
write_board 2026-10-02T00:00Z "$board_cards"
mirror card-payload >/dev/null
card=$(python3 "$HELPER" card-text "$(replay_file)" with-options)
assert_contains "$card" '1. Board A (board-a)' "X4 newer board options reach the card"
assert_contains "$card" 'Recommendation: board-a' "X4 newer board recommendation reaches the card"
assert_contains "$card" 'Affordance: reaction' "X4 newer board affordance"
ts=$(thread_field with-options ts)
assert_eq "$(python3 "$HELPER" reaction-count "$FM_STATE_OVERRIDE/slack-watch/outbound.jsonl" "$ts")" 2 "X4 seeded reactions"
assert_eq "$(thread_field with-options mode)" release "X4 card close mode reaches the thread"
reply_to "$ts" 900.000099 2
out=$(poll card-payload)
assert_eq "$(closed_count "$out")" 1 "X4 board option answers"
assert_eq "$(answer_line with-options)" "board-b" "X4 board option value recorded"
assert_eq "$(label_line with-options)" "Board B" "X4 board option label recorded"
[ "$(task_state with-options)" != "done" ] || fail "X4 a release card closed the task instead of lifting the hold"
assert_closed with-options 1 "X4 released call is no longer open"
printf 'ok - X4\n'

# X5: a changed owner id is refused, not silently ignored
new_home mirror
bind
mirror mirror >/dev/null
sent=$(wc -l < "$FM_STATE_OVERRIDE/slack-watch/outbound.jsonl")
set +e
out=$(FM_SLACK_DM_USER=U0OTHEROWNER1 "$ROOT/bin/fm-slack-mirror.sh" --replay "$FIX/mirror/transcript.json" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "X5 a changed owner id was accepted"
assert_contains "$out" 'dm_user_changed' "X5 named refusal"
assert_eq "$(wc -l < "$FM_STATE_OVERRIDE/slack-watch/outbound.jsonl")" "$sent" "X5 nothing was sent to either owner"
printf 'ok - X5\n'

# X6: a lost thread commit does not post the card twice
new_home mirror
bind
mirror mirror >/dev/null
python3 "$HELPER" drop-threads "$(state_file)"
mirror mirror >/dev/null
assert_eq "$(python3 "$HELPER" root-count "$(replay_file)" open-a)" 1 "X6 card posted twice"
assert_eq "$(thread_count open-a)" 1 "X6 thread restored from the existing card"
printf 'ok - X6\n'

# X7: Slack and the board leave the same keyed record for the same option
new_home single-char-answer
bind
mirror single-char-answer >/dev/null
poll single-char-answer >/dev/null
(cd "$FM_HOME" && tasks-axi add board-call "Board call" --kind captain --repo sample --body-file "$FM_HOME/options.body" >/dev/null)
FM_CAPTAIN_HOLD_NOW=2026-10-01T00:00:00Z "$CAPTAIN" hold board-call --reason "Select the release approach" >/dev/null
cat > "$FM_HOME/board.result" <<'RESULT'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[1]{uid,prompt,selector,tag,text}:
  "1","Wait\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"board-call\",\n  \"selection\": \"wait\",\n  \"note\": \"\"\n}","section#call > form:nth-of-type(1)",choice,"Wait"
next_step: done
RESULT
bash "$ROOT/bin/fm-procevent-lavish.sh" answers "$FM_HOME/board.result" \
  | "$CAPTAIN" answers --any-origin --source board-lavish >/dev/null
assert_eq "$(answer_line board-call)" "$(answer_line single-call)" "X7 answer differs across surfaces"
assert_eq "$(label_line board-call)" "$(label_line single-call)" "X7 label differs across surfaces"
assert_eq "$(answer_line single-call)" wait "X7 recorded value"
printf 'ok - X7\n'

# X8: crash injection comes from the process environment, never from .env
new_home typed-reply
printf 'FM_SLACK_FAULT=after-delivery\n' >> "$FM_HOME/.env"
set +e
out=$(poll typed-reply); rc=$?
set -e
assert_eq "$rc" 0 "X8 a stray .env fault crashed the poll"
assert_contains "$out" 'closed: typed-call' "X8 poll ran normally"
printf 'ok - X8\n'

# X9: every pending wake condition reaches the one check line
new_home unmatched-two
"$ROOT/bin/fm-slack-check.sh" arm --replay "$FIX/unmatched-two/transcript.json" >/dev/null
out=$("$ROOT/bin/fm-slack-check.sh" check --replay "$FIX/unmatched-two/transcript.json")
assert_eq "$(printf '%s\n' "$out" | grep -c .)" 1 "X9 one wake line"
assert_contains "$out" 'unmatched reply 900.000002' "X9 first condition"
assert_contains "$out" 'unmatched reply 900.000003' "X9 second condition"
[ "${#out}" -le 480 ] || fail "X9 wake line is unbounded"
new_home typed-reply
bind
set +e
out=$("$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/partial-failure/transcript.json"); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "X9 the failed read reported success"
assert_contains "$out" 'unmatched reply 900.000002' "X9 a failure erased an earlier line"
assert_contains "$out" 'transport failure' "X9 failure line"
new_home unmatched
bind
set +e
first=$("$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/unmatched-retry/transcript.json"); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "X9 the failed post reported success"
assert_not_contains "$first" 'unmatched reply' "X9 a line was said before its post succeeded"
second=$("$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/unmatched-retry/transcript.json")
assert_eq "$(check_count "$second")" 1 "X9 the retried notice says its line"
printf 'ok - X9\n'

# X10: a failed intake run is retried, never consumed or reported as a refusal
new_home typed-reply
bind
: > "$TMP/answers-fail"
SHIM_FIXTURE=typed-reply
set +e
out=$(shim_poll FM_SHIM_ANSWERS_FAIL="$TMP/answers-fail" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "X10 a failed intake run reported success"
assert_contains "$out" 'answer_intake_failed' "X10 failure named"
assert_contains "$out" 'simulated backlog read bound' "X10 intake diagnostic surfaced"
assert_open typed-call 0 "X10 failed intake closed the call"
assert_eq "$(outbound_count chat.postMessage 900.000001)" 0 "X10 a failed intake was acknowledged"
assert_eq "$(python3 "$HELPER" pending-count "$(state_file)")" 1 "X10 the reply stays staged"
set +e
out=$(shim_poll FM_SHIM_ANSWERS_FAIL="$TMP/answers-fail" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "X10 the retry reported success while the intake still failed"
assert_eq "$(printf '%s\n' "$out" | grep -c 'answer_intake_failed' || true)" 0 "X10 failure episode is quiet"
rm -f "$TMP/answers-fail"
out=$(poll typed-reply)
assert_contains "$out" 'closed: typed-call' "X10 the retried reply is delivered"
assert_eq "$(resolution_count typed-call)" 1 "X10 one record"
assert_contains "$(thread_texts 900.000001)" 'Answer recorded.' "X10 acknowledged as applied"
assert_not_contains "$(thread_texts 900.000001)" 'not applied' "X10 not reported as refused"
new_home typed-reply
bind
: > "$TMP/answers-note"
out=$(shim_poll FM_SHIM_ANSWERS_NOTE="$TMP/answers-note" 2>&1)
assert_contains "$out" 'closed: typed-call' "X10 close still reported"
assert_contains "$out" 'intake note: simulated parent delivery problem' "X10 intake stderr surfaced after a close"
new_home resolution
bind
poll resolution >/dev/null
reply_to 900.000001 900.000009 $'\x01'
out=$(poll resolution)
assert_contains "$out" 'answer not applied: resolve-call' "X10 a row the intake skipped silently still reaches firstmate"
assert_open resolve-call 0 "X10 a skipped row closed the call"
printf 'ok - X10\n'

# X11: an unreadable call state defers the reply instead of guessing
new_home typed-reply
bind
: > "$TMP/open-fail"
SHIM_FIXTURE=typed-reply
set +e
out=$(shim_poll FM_SHIM_OPEN_FAIL="$TMP/open-fail" 2>&1); rc=$?
set -e
assert_eq "$rc" 0 "X11 a deferred poll is not a failure"
assert_eq "$out" "" "X11 a deferred poll is silent"
assert_open typed-call 0 "X11 a deferred reply closed the call"
assert_eq "$(outbound_count chat.postMessage 900.000001)" 0 "X11 a deferred reply was acknowledged"
rm -f "$TMP/open-fail"
out=$(poll typed-reply)
assert_contains "$out" 'closed: typed-call' "X11 the deferred reply is delivered once the state is readable"
printf 'ok - X11\n'

# X12: a thread mirrored while the call state was unreadable never answers a verified hold
new_home reaction-answer
bind
: > "$TMP/open-fail"
env FM_SHIM_OPEN_FAIL="$TMP/open-fail" "$SHIM/fm-slack-mirror.sh" --replay "$FIX/reaction-answer/transcript.json" >/dev/null
assert_eq "$(thread_field reaction-call identity)" uncertain "X12 an unreadable state mirrors an uncertain thread"
rm -f "$TMP/open-fail"
out=$(poll reaction-answer)
assert_eq "$(closed_count "$out")" 0 "X12 an uncertain thread answered a verified hold"
assert_open reaction-call 0 "X12 the hold stays open"
assert_eq "$(thread_count reaction-call)" 2 "X12 the verified hold has its own thread"
assert_eq "$(thread_field reaction-call retired)" True "X12 the uncertain thread is retired"
assert_contains "$(thread_texts 900.000001)" 'Superseded' "X12 the uncertain thread says it was superseded"
printf 'ok - X12\n'

# X13: per-poll work follows open holds, not every hold ever mirrored
new_home resolution
bind
poll resolution >/dev/null
python3 "$HELPER" add-retired "$(state_file)" 25
SHIM_FIXTURE=resolution
rm -f "$TMP/open.log"
shim_poll FM_SHIM_LOG="$TMP/open.log" >/dev/null
assert_eq "$(grep -c '^open ' "$TMP/open.log" || true)" 1 "X13 retired threads were probed"
close_terminal resolve-call
shim_poll FM_SHIM_LOG="$TMP/open.log" >/dev/null
rm -f "$TMP/open.log"
shim_poll FM_SHIM_LOG="$TMP/open.log" >/dev/null
assert_eq "$(grep -c '^open ' "$TMP/open.log" || true)" 0 "X13 a poll with nothing open probed a call"
new_home mirror
bind
mirror mirror >/dev/null
python3 "$HELPER" pad-history "$(replay_file)" 300
(cd "$FM_HOME" && tasks-axi add late-call "Late call" --kind captain --repo sample >/dev/null)
FM_CAPTAIN_HOLD_NOW=2026-10-01T00:00:00Z "$CAPTAIN" hold late-call --reason "Late" >/dev/null
before=$(outbound_count conversations.history)
mirror mirror >/dev/null
assert_eq "$(thread_count late-call)" 1 "X13 late card mirrored"
assert_eq "$(( $(outbound_count conversations.history) - before ))" 1 "X13 a new card read more than the newest history page"
printf 'ok - X13\n'

# X14: only explicit "Option N:" lines are options, and the answer is never the hint
new_home parse-options
bind
mirror parse-options >/dev/null
facts=$(python3 "$HELPER" card-text "$(replay_file)" facts-only)
forms=$(python3 "$HELPER" card-text "$(replay_file)" option-forms)
assert_not_contains "$facts" '1. CI is green' "T1 numbered task-body facts leaked into the card"
assert_not_contains "$facts" 'Options:' "X14 numbered facts became options"
assert_contains "$facts" 'Affordance: text' "X14 numbered facts offered taps"
assert_not_contains "$forms" '2) Reviewer approved' "T1 a task-body fact beside options leaked into the card"
assert_contains "$forms" '1. Ship it (Ship it) - Deploy now' "X14 option without a slug"
assert_contains "$forms" '2. Wait (wait) - Hold current' "X14 option with a slug"
assert_not_contains "$forms" 'Ship it - Deploy now)' "X14 hint leaked into the option value"
ts=$(thread_field option-forms ts)
reply_to "$ts" 900.000099 1
out=$(poll parse-options)
assert_eq "$(closed_count "$out")" 1 "X14 option answered"
assert_eq "$(answer_line option-forms)" "Ship it" "X14 recorded answer carries the hint"
printf 'ok - X14\n'

# X15: a tap is attributed to the member who made it
new_home reaction-answer
bind
mirror reaction-answer >/dev/null
python3 "$HELPER" unreact "$(replay_file)" 900.000001 two U0TESTOWNER
: > "$TMP/answers-fail"
SHIM_FIXTURE=reaction-answer
shim_poll FM_SLACK_ALLOWED_AUTHORS='U0TESTOWNER U0123456789' FM_SHIM_ANSWERS_FAIL="$TMP/answers-fail" >/dev/null 2>&1 || true
rm -f "$TMP/answers-fail"
assert_eq "$(python3 "$HELPER" pending-field "$(state_file)" author)" U0123456789 "X15 tap attributed to another member"
out=$(env FM_SLACK_ALLOWED_AUTHORS=U0TESTOWNER "$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/reaction-answer/transcript.json")
assert_eq "$(closed_count "$out")" 0 "X15 a tap by a removed member was delivered"
assert_eq "$(python3 "$HELPER" pending-count "$(state_file)")" 0 "X15 the removed member's tap stayed staged"
assert_open reaction-call 0 "X15 the removed member's tap closed the call"
printf 'ok - X15\n'

# X16: the DM is only prepared through arm, mirror, and poll
set +e
out=$(python3 "$ROOT/bin/fm_slack_watch.py" prepare 2>&1); rc=$?
set -e
assert_eq "$rc" 2 "X16 prepare is no longer a command"
assert_contains "$out" 'unknown command' "X16 prepare refusal"
printf 'ok - X16\n'

# X17: no local child process inherits the bot token
new_home typed-reply
bind
SHIM_FIXTURE=typed-reply
rm -f "$TMP/env.log"
shim_poll FM_SHIM_ENVLOG="$TMP/env.log" >/dev/null
[ -s "$TMP/env.log" ] || fail "X17 no local child ran"
assert_eq "$(sort -u "$TMP/env.log")" unset "X17 a local child inherited the bot token"
new_home mirror
bind
rm -f "$TMP/env.log"
env FM_SHIM_ENVLOG="$TMP/env.log" "$SHIM/fm-slack-mirror.sh" --replay "$FIX/mirror/transcript.json" >/dev/null
[ -s "$TMP/env.log" ] || fail "X17 no child ran during the mirror"
assert_eq "$(sort -u "$TMP/env.log")" unset "X17 a mirror child inherited the bot token"
printf 'ok - X17\n'

# X18: Slack's message escaping is undone before a typed reply is recorded
new_home card-payload
bind
mirror card-payload >/dev/null
ts=$(thread_field no-options ts)
reply_to "$ts" 900.000099 'merge 12 &amp; 13, skip CI &lt; 5 min &gt; see <https://example.com/b> and <https://example.com/a|the doc>'
out=$(poll card-payload)
assert_eq "$(closed_count "$out")" 1 "X18 escaped reply close"
expected='merge 12 & 13, skip CI < 5 min > see https://example.com/b and the doc'
assert_eq "$(answer_line no-options)" "$expected" "X18 the recorded answer is what the owner typed"
assert_eq "$(label_line no-options)" "$expected" "X18 the recorded label is what the owner typed"
printf 'ok - X18\n'

# X19: notices surface in order, as many as the wake line holds, the rest queue unchanged
new_home mirror
bind
mirror mirror >/dev/null
"$ROOT/bin/fm-slack-check.sh" arm --replay "$FIX/mirror/transcript.json" >/dev/null
ts_a=$(thread_field open-a ts)
ts_b=$(thread_field open-b ts)
ts_c=$(thread_field between ts)
wide() { python3 -I -c 'import sys; print(sys.argv[1] * 200)' "$1"; }
reply_to "$ts_a" 900.000101 "$(wide a)"
reply_to "$ts_a" 900.000102 "$(wide b)"
reply_to "$ts_b" 900.000201 "$(wide c)"
reply_to "$ts_b" 900.000202 "$(wide d)"
close_terminal between
reply_to "$ts_c" 900.000301 hello
wake() { "$ROOT/bin/fm-slack-check.sh" check --replay "$FIX/mirror/transcript.json"; }
out=$(wake)
[ "${#out}" -le 480 ] || fail "X19 the wake line is unbounded"
assert_contains "$out" 'conflicting signals' "X19 first conflict surfaces first"
assert_contains "$out" 'aaaa' "X19 first conflict names its answer"
assert_not_contains "$out" 'cccc' "X19 second conflict jumped the queue"
assert_not_contains "$out" 'unmatched reply' "X19 the later reply jumped the queue"
assert_contains "$out" '; +2 queued$' "X19 the queue marker"
assert_eq "$(python3 "$HELPER" seen-count "$(state_file)" "$ts_a")" 2 "X19 first conflict marked seen"
assert_eq "$(python3 "$HELPER" seen-count "$(state_file)" "$ts_b")" 0 "X19 a queued conflict was marked seen without its line"
assert_eq "$(python3 "$HELPER" seen-count "$(state_file)" "$ts_c")" 0 "X19 a queued reply was marked seen without its line"
assert_eq "$(python3 "$HELPER" pending-count "$(state_file)")" 2 "X19 queued rows were not carried"
assert_contains "$(thread_texts "$ts_a")" 'Conflicting signals' "X19 first notice post"
assert_not_contains "$(thread_texts "$ts_b")" 'Conflicting signals' "X19 a queued notice was posted before its line"
out=$(wake)
[ "${#out}" -le 480 ] || fail "X19 the second wake line is unbounded"
assert_contains "$out" 'cccc' "X19 second conflict surfaces next"
assert_not_contains "$out" 'aaaa' "X19 first conflict repeated"
assert_not_contains "$out" 'unmatched reply' "X19 the later reply surfaced early"
assert_contains "$out" '; +1 queued$' "X19 the queue marker shrinks"
assert_eq "$(python3 "$HELPER" seen-count "$(state_file)" "$ts_b")" 2 "X19 second conflict marked seen"
assert_eq "$(python3 "$HELPER" seen-count "$(state_file)" "$ts_c")" 0 "X19 the later reply was marked seen without its line"
assert_contains "$(thread_texts "$ts_b")" 'Conflicting signals' "X19 second notice post"
out=$(wake)
assert_contains "$out" "unmatched reply 900.000301" "X19 the later reply's line was lost"
assert_not_contains "$out" 'queued' "X19 an empty queue left a marker"
assert_eq "$(python3 "$HELPER" seen-count "$(state_file)" "$ts_c")" 1 "X19 the later reply marked seen"
assert_eq "$(python3 "$HELPER" pending-count "$(state_file)")" 0 "X19 rows left after every line surfaced"
assert_eq "$(wake)" "" "X19 a surfaced notice repeated"
assert_open open-a 0 "X19 a conflict recorded an answer"
assert_open open-b 0 "X19 a conflict recorded an answer"
printf 'ok - X19\n'

# X20: a Slack subtype alone never refuses the owner; a bot marker always does
new_home card-payload
bind
mirror card-payload >/dev/null
ts=$(thread_field no-options ts)
python3 "$HELPER" reply "$(replay_file)" "$ts" 900.000096 U0TESTOWNER 'bot id' '{"bot_id":"BBOTLOOKALIKE"}'
python3 "$HELPER" reply "$(replay_file)" "$ts" 900.000097 U0TESTOWNER 'app id' '{"app_id":"AAPPLOOKALIKE"}'
python3 "$HELPER" reply "$(replay_file)" "$ts" 900.000098 U0TESTOWNER 'bot profile' '{"bot_profile":{"id":"BPROFILE"}}'
out=$(poll card-payload)
assert_eq "$(closed_count "$out")" 0 "X20 a bot-marked message answered"
assert_open no-options 0 "X20 a bot-marked message closed the call"
python3 "$HELPER" reply "$(replay_file)" "$ts" 900.000099 U0TESTOWNER 'ship the release' '{"subtype":"thread_broadcast"}'
out=$(poll card-payload)
assert_eq "$(closed_count "$out")" 1 "X20 a thread_broadcast reply from the owner"
assert_eq "$(answer_line no-options)" "ship the release" "X20 the broadcast reply's words are the answer"
printf 'ok - X20\n'

# X21: an explicit arm names every failure on stderr each time; only the standing check reports once
arm_fails() {  # <label> <expected-text> [env assignments...]; runs arm with streams captured apart
  local label=$1 expected=$2
  shift 2
  set +e
  out=$(env "$@" "$ROOT/bin/fm-slack-check.sh" arm --replay "${ARM_TRANSCRIPT:-$FIX/arming/arm.json}" 2>"$TMP/arm.err"); rc=$?
  set -e
  assert_eq "$out" "" "X21 [$label] a failed arm wrote to stdout"
  assert_contains "$(cat "$TMP/arm.err")" "$expected" "X21 [$label] the failure was not named on stderr"
  [ "$rc" -ne 0 ] || fail "X21 [$label] a failed arm exited zero"
}
new_home typed-reply
"$ROOT/bin/fm-slack-check.sh" arm --replay "$FIX/arming/arm.json" >/dev/null
set +e
out=$("$ROOT/bin/fm-slack-check.sh" check --replay "$FIX/arming/arm.json" 2>"$TMP/check.err"); rc=$?
set -e
assert_eq "$out" "" "X21 the healthy standing check wrote to stdout"
assert_eq "$(cat "$TMP/check.err")" "" "X21 the healthy standing check wrote to stderr"
assert_eq "$rc" 0 "X21 the healthy standing check exited nonzero"
arm_fails "dm user changed" dm_user_changed FM_SLACK_DM_USER=U0OTHEROWNER
arm_fails "dm user changed again" dm_user_changed FM_SLACK_DM_USER=U0OTHEROWNER
set +e
out=$(env FM_SLACK_DM_USER=U0OTHEROWNER "$ROOT/bin/fm-slack-check.sh" check --replay "$FIX/arming/arm.json" 2>"$TMP/check.err"); rc=$?
set -e
assert_contains "$out" 'transport failure: dm_user_changed' "X21 the standing check did not report the change"
assert_eq "$(cat "$TMP/check.err")" "" "X21 the standing check wrote its report to stderr"
assert_eq "$rc" 1 "X21 the failing standing check exit"
set +e
out=$(env FM_SLACK_DM_USER=U0OTHEROWNER "$ROOT/bin/fm-slack-check.sh" check --replay "$FIX/arming/arm.json" 2>"$TMP/check.err"); rc=$?
set -e
assert_eq "$out" "" "X21 the standing check repeated its report"
assert_eq "$(cat "$TMP/check.err")" "" "X21 the repeated standing check wrote to stderr"
arm_fails "dm user changed after the standing check recorded it" dm_user_changed FM_SLACK_DM_USER=U0OTHEROWNER
new_home typed-reply
mkdir -p "$FM_STATE_OVERRIDE/slack-watch"
printf '{"schema":"not-this-one"}' > "$FM_STATE_OVERRIDE/slack-watch/state.json"
arm_fails "invalid state schema" invalid_state_schema
arm_fails "invalid state schema again" invalid_state_schema
new_home typed-reply
mkdir -p "$TMP/elsewhere"
ln -s "$TMP/elsewhere" "$FM_STATE_OVERRIDE/slack-watch"
arm_fails "unsafe state path" unsafe_state_path
rm -f "$FM_STATE_OVERRIDE/slack-watch"
new_home typed-reply
ARM_TRANSCRIPT="$TMP/no-such-transcript.json" arm_fails "missing transcript" replay_transcript_unreadable
printf 'ok - X21\n'

# X22: a spent answer cap never retires a thread whose replies were not read
new_home mirror
bind
mirror mirror >/dev/null
ts_a=$(thread_field open-a ts)
ts_b=$(thread_field open-b ts)
reply_to "$ts_a" 900.000101 go
close_terminal open-b
reply_to "$ts_b" 900.000201 late
out=$(env FM_SLACK_POLL_MAX_ANSWERS=1 "$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/mirror/transcript.json")
assert_eq "$(closed_count "$out")" 1 "X22 the live thread was answered"
assert_closed open-a 1 "X22 the live call closed"
assert_eq "$(thread_field open-a retired)" True "X22 the answered thread was retired"
assert_eq "$(thread_field open-b retired)" False "X22 an unread thread was retired"
assert_not_contains "$(thread_texts "$ts_b")" 'Resolved:' "X22 an unread thread was resolved"
assert_not_contains "$out" 'unmatched reply' "X22 the unread reply surfaced early"
out=$(env FM_SLACK_POLL_MAX_ANSWERS=1 "$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/mirror/transcript.json")
assert_contains "$out" "unmatched reply 900.000201" "X22 the late reply on the closed call was never surfaced"
assert_eq "$(thread_field open-b retired)" False "X22 the thread was retired with its notice"
out=$(env FM_SLACK_POLL_MAX_ANSWERS=1 "$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/mirror/transcript.json")
assert_eq "$(thread_field open-b retired)" True "X22 the read thread was not retired"
assert_contains "$(thread_texts "$ts_b")" 'Resolved: open-b' "X22 the retired thread was not resolved"
assert_not_contains "$out" 'unmatched reply' "X22 the late reply surfaced twice"
printf 'ok - X22\n'

printf 'ok - all Slack watch checks\n'
