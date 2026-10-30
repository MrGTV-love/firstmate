#!/usr/bin/env bash
# Slack decision plane regressions DOD-01..DOD-17, S1..S3, X1..X40.
# Every Slack call is a checked-in replay transcript; no socket is opened.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$FM_WT/tests/lib.sh"
ROOT=$FM_WT
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

# X33: a thread whose reactions cannot be read is never retired with its late reply unread
new_home reaction-answer
bind
mirror reaction-answer >/dev/null
ts=$(thread_field reaction-call ts)
close_terminal reaction-call
reply_to "$ts" 900.000201 late
python3 "$HELPER" fail-call "$(replay_file)" "reactions.get:$ts" 400
set +e
out=$(poll reaction-answer); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "X33 the unreadable thread reported success"
assert_contains "$out" 'transport failure: api_error' "X33 the unreadable thread was not reported"
assert_eq "$(thread_field reaction-call retired)" False "X33 a thread whose taps were not read was retired"
assert_not_contains "$(thread_texts "$ts")" 'Resolved:' "X33 a thread whose taps were not read was resolved"
python3 "$HELPER" clear-fail "$(replay_file)" "reactions.get:$ts"
out=$(poll reaction-answer)
assert_contains "$out" "unmatched reply 900.000201" "X33 the late reply was never surfaced"
assert_eq "$(thread_field reaction-call retired)" False "X33 the thread was retired with its notice"
poll reaction-answer >/dev/null
assert_eq "$(thread_field reaction-call retired)" True "X33 the read thread was not retired"
assert_contains "$(thread_texts "$ts")" 'Resolved: reaction-call' "X33 the retired thread was not resolved"
printf 'ok - X33\n'

# X34: a failed acknowledgement never lets one poll deliver more answers than the cap
new_home duplicate
bind
python3 "$HELPER" add-failure "$FIX/duplicate/transcript.json" "$TMP/ack-fail.json" chat.postMessage 400
set +e
out=$(env FM_SLACK_POLL_MAX_ANSWERS=1 "$ROOT/bin/fm-slack-poll.sh" --replay "$TMP/ack-fail.json"); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "X34 the failed acknowledgement reported success"
assert_eq "$(closed_count "$out")" 1 "X34 one poll delivered more answers than the cap"
assert_contains "$out" 'transport failure: api_error' "X34 the failed acknowledgement was not reported"
assert_open dup-b 0 "X34 the call past the cap was answered"
printf 'ok - X34\n'

# X35: an unreadable card never uses up the answer cap of the threads after it
new_home duplicate
bind
python3 "$HELPER" add-failure "$FIX/duplicate/transcript.json" "$TMP/cap-read-fail.json" conversations.replies:900.000001 400
set +e
out=$(env FM_SLACK_POLL_MAX_ANSWERS=1 "$ROOT/bin/fm-slack-poll.sh" --replay "$TMP/cap-read-fail.json"); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "X35 the unreadable card reported success"
assert_contains "$out" 'closed: dup-b' "X35 an unreadable card used up the answer cap"
assert_open dup-a 0 "X35 the unreadable card's call was answered"
printf 'ok - X35\n'

# X36: a journaled row whose thread is gone never keeps the other threads unread on later polls
new_home duplicate
bind
python3 "$HELPER" add-failure "$FIX/duplicate/transcript.json" "$TMP/resume-fail.json" chat.postMessage 400
python3 "$HELPER" add-failure "$TMP/resume-fail.json" "$TMP/resume-fail.json" conversations.replies:900.000101 400
set +e
out=$("$ROOT/bin/fm-slack-poll.sh" --replay "$TMP/resume-fail.json"); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "X36 the failed acknowledgement reported success"
assert_contains "$out" 'closed: dup-a' "X36 the first thread was not answered"
assert_open dup-b 0 "X36 the unreadable thread was answered"
assert_eq "$(python3 "$HELPER" pending-count "$(state_file)")" 1 "X36 the unacknowledged answer left the journal"
python3 "$HELPER" clear-fail "$(replay_file)" chat.postMessage
python3 "$HELPER" clear-fail "$(replay_file)" conversations.replies:900.000101
python3 "$HELPER" fail-call "$(replay_file)" conversations.replies:900.000001 400
set +e
out=$("$ROOT/bin/fm-slack-poll.sh" --replay "$TMP/resume-fail.json"); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "X36 the gone thread reported success"
assert_contains "$out" 'closed: dup-b' "X36 a journaled row whose thread is gone kept another thread's reply unread"
assert_eq "$(python3 "$HELPER" pending-count "$(state_file)")" 1 "X36 the row for the gone thread left the journal"
printf 'ok - X36\n'

# X37: more than 100 unprinted wake lines all survive a run that dies before printing
new_home typed-reply
"$ROOT/bin/fm-slack-check.sh" arm --replay "$FIX/typed-reply/transcript.json" >/dev/null
for n in $(seq 101 205); do python3 "$HELPER" journal-line "$(state_file)" "check: slack held-$n"; done
set +e
FM_SLACK_FAULT=before-emit "$ROOT/bin/fm-slack-check.sh" check --replay "$FIX/typed-reply/transcript.json" >/dev/null 2>&1; rc=$?
set -e
assert_eq "$rc" 75 "X37 the check fault did not fire"
printed=''
for _ in $(seq 1 20); do
  out=$("$ROOT/bin/fm-slack-check.sh" check --replay "$FIX/typed-reply/transcript.json")
  [ -n "$out" ] || break
  printed="$printed; $out"
done
assert_eq "$(printf '%s' "$printed" | tr ';' '\n' | grep -c '^ check: slack held-' || true)" 105 "X37 an unprinted wake line was lost"
assert_contains "$printed" 'check: slack held-101; ' "X37 the oldest unprinted wake line was lost"
assert_contains "$printed" 'closed: typed-call' "X37 the line the dying run earned was lost"
assert_closed typed-call 1 "X37 the answer was not delivered"
printf 'ok - X37\n'

# X38: a journaled row stuck before its acknowledgement never uses up the answer cap of a later poll
new_home duplicate
bind
python3 "$HELPER" add-failure "$FIX/duplicate/transcript.json" "$TMP/stuck-cap.json" chat.postMessage 400
set +e
out=$(env FM_SLACK_POLL_MAX_ANSWERS=1 "$ROOT/bin/fm-slack-poll.sh" --replay "$TMP/stuck-cap.json"); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "X38 the failed acknowledgement reported success"
assert_contains "$out" 'closed: dup-a' "X38 the first thread was not answered"
assert_open dup-b 0 "X38 one poll delivered more answers than the cap"
python3 "$HELPER" clear-fail "$(replay_file)" chat.postMessage
python3 "$HELPER" fail-call "$(replay_file)" conversations.replies:900.000001 400
set +e
out=$(env FM_SLACK_POLL_MAX_ANSWERS=1 "$ROOT/bin/fm-slack-poll.sh" --replay "$TMP/stuck-cap.json"); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "X38 the gone thread reported success"
assert_contains "$out" 'closed: dup-b' "X38 a row stuck before its acknowledgement used up the answer cap"
assert_eq "$(python3 "$HELPER" pending-count "$(state_file)")" 1 "X38 the row for the gone thread left the journal"
printf 'ok - X38\n'

# X39: an older journaled answer acknowledged on a re-read never uses up the answer cap
new_home duplicate
bind
python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); next(m for m in d["messages"] if m["ts"] == "900.000002")["text"] = "reconcile"; json.dump(d, open(sys.argv[2], "w"))' \
  "$FIX/duplicate/transcript.json" "$TMP/reread-cap.json"
python3 "$HELPER" add-failure "$TMP/reread-cap.json" "$TMP/reread-cap.json" chat.postMessage 400
set +e
out=$(env FM_SLACK_POLL_MAX_ANSWERS=1 "$ROOT/bin/fm-slack-poll.sh" --replay "$TMP/reread-cap.json"); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "X39 the failed acknowledgement reported success"
assert_contains "$out" 'refused: dup-a' "X39 the reserved answer was not refused"
assert_open dup-a 0 "X39 a refused answer closed the call"
assert_open dup-b 0 "X39 one poll delivered more answers than the cap"
python3 "$HELPER" fail-call "$(replay_file)" chat.postMessage 400 1
set +e
out=$(env FM_SLACK_POLL_MAX_ANSWERS=1 "$ROOT/bin/fm-slack-poll.sh" --replay "$TMP/reread-cap.json"); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "X39 the transient acknowledgement failure was not reported"
assert_contains "$out" 'closed: dup-b' "X39 an older answer acknowledged on a re-read used up the answer cap"
assert_not_contains "$out" 'refused: dup-a' "X39 the older answer was delivered twice"
assert_eq "$(python3 "$HELPER" pending-count "$(state_file)")" 0 "X39 the acknowledged answers stayed journaled"
printf 'ok - X39\n'

# X40: an older journaled answer acknowledged on a closed call's re-read never uses up the answer cap
new_home duplicate
bind
python3 "$HELPER" add-failure "$FIX/duplicate/transcript.json" "$TMP/closed-reread-cap.json" chat.postMessage 400
set +e
out=$(env FM_SLACK_POLL_MAX_ANSWERS=1 "$ROOT/bin/fm-slack-poll.sh" --replay "$TMP/closed-reread-cap.json"); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "X40 the failed acknowledgement reported success"
assert_contains "$out" 'closed: dup-a' "X40 the first thread was not answered"
assert_closed dup-a 1 "X40 the accepted answer left the call open"
assert_open dup-b 0 "X40 one poll delivered more answers than the cap"
python3 "$HELPER" fail-call "$(replay_file)" chat.postMessage 400 1
set +e
out=$(env FM_SLACK_POLL_MAX_ANSWERS=1 "$ROOT/bin/fm-slack-poll.sh" --replay "$TMP/closed-reread-cap.json"); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "X40 the transient acknowledgement failure was not reported"
assert_contains "$out" 'closed: dup-b' "X40 an older answer acknowledged on a closed call's re-read used up the answer cap"
assert_not_contains "$out" 'unmatched reply' "X40 the acknowledged answer was surfaced as unmatched"
assert_eq "$(python3 "$HELPER" pending-count "$(state_file)")" 0 "X40 the acknowledged answers stayed journaled"
printf 'ok - X40\n'

printf 'ok - all Slack watch checks\n'
