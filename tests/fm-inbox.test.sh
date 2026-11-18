#!/usr/bin/env bash
# tests/fm-inbox.test.sh - captain inbox capture, receipts, replies, readiness.
#
# Covers the durable order contract: request-id idempotency, the crash window
# between save and announce, saved-but-unannounced repair, the unknown
# announced state of notes that predate the marker, bounded receipts JSON with
# omission disclosure, the reply cursor's strict order, and the readiness
# projection's model-aware verdict and unknown path. Human note/list/drain
# behaviour stays unchanged when the new flags are omitted.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-inbox)
INBOX_BIN="$ROOT/bin/fm-inbox.sh"
LOCK_BIN="$ROOT/bin/fm-lock.sh"

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

run_inbox() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$INBOX_BIN" "$@"
}

run_lock() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$LOCK_BIN" "$@"
}

json_get() {
  python3 -c 'import json,sys
v=json.load(sys.stdin)
for k in sys.argv[1:]:
    if isinstance(v, list) and k.lstrip("-").isdigit():
        v=v[int(k)]
    else:
        v=v[k]
print(v)' "$@"
}

count_notes() {
  find "$1/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' '
}

count_wakes() {
  if [ -f "$1/state/.wake-queue" ]; then
    grep -c 'inbox:' "$1/state/.wake-queue" || true
  else
    printf '0\n'
  fi
}

# --- human note path is unchanged without the new flags ---------------------

home=$(make_home human)
out=$(run_inbox "$home" note "hello from the terminal") \
  || fail "plain note should succeed"
assert_contains "$out" "queued " "plain note should print queued <id>"
assert_contains "$out" "firstmate will pick this up at its next check." \
  "plain note should keep its human announcement line"
assert_equals "1" "$(count_notes "$home")" "plain note should write one record"
assert_equals "1" "$(count_wakes "$home")" "plain note should append one wake"
list_out=$(run_inbox "$home" list) || fail "list should succeed"
assert_contains "$list_out" "hello from the terminal" "list should show the body"
pass "plain note, list, and wake stay on the historical human path"

# A saved note whose wake fails still exits 1 for callers that omit the new flags.
isolated="$TMP_ROOT/isolated"
mkdir -p "$isolated/bin"
cp "$INBOX_BIN" "$isolated/bin/fm-inbox.sh"
chmod +x "$isolated/bin/fm-inbox.sh"
home=$(make_home human-wake-fail)
set +e
fail_out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note "saved but not announced" 2>&1)
fail_code=$?
set -e
expect_code 1 "$fail_code" "plain note still exits 1 when announcement fails"
assert_equals "1" "$(count_notes "$home")" \
  "plain note is saved even when announcement fails"
assert_contains "$fail_out" "queued " "plain note still prints queued before the failure"
assert_contains "$fail_out" "NOT woken" "plain note still reports the wake failure"
pass "plain note keeps exit 1 for a saved-but-unannounced failure"

# --- duplicate request id returns the original identity ---------------------

home=$(make_home idempotent)
body=$'line one\nline two\n'
first=$(printf '%s' "$body" | run_inbox "$home" note --request-id req-1 --json -) \
  || fail "first request-id note should succeed"
first_id=$(printf '%s' "$first" | json_get id)
assert_equals "created" "$(printf '%s' "$first" | json_get outcome)" \
  "first submission is created"
assert_equals "True" "$(printf '%s' "$first" | json_get saved)" \
  "first submission is saved"
assert_equals "True" "$(printf '%s' "$first" | json_get announced)" \
  "first submission is announced"
assert_equals "req-1" "$(printf '%s' "$first" | json_get request_id)" \
  "receipt carries the request id"

second=$(printf '%s' "$body" | run_inbox "$home" note --request-id req-1 --json -) \
  || fail "replay of the same request id should succeed"
assert_equals "replay" "$(printf '%s' "$second" | json_get outcome)" \
  "repeat request id is a replay, not a second create"
assert_equals "$first_id" "$(printf '%s' "$second" | json_get id)" \
  "replay returns the original note id"
assert_equals "1" "$(count_notes "$home")" \
  "the same request id must not create a second note"
assert_equals "1" "$(count_wakes "$home")" \
  "replay of an already-announced note must not append a second wake"
replay_human=$(run_inbox "$home" note --request-id req-1 "line one") \
  || fail "human replay should succeed"
assert_contains "$replay_human" "replay $first_id" \
  "human replay is distinguishable from queued"
assert_equals "1" "$(count_notes "$home")" "human replay still does not duplicate"
pass "the same request id returns the original note as a distinguishable replay"

# --- crash window: reservation exists, note not yet published ---------------

home=$(make_home crash-reserve)
mkdir -p "$home/state/inbox/.requests"
crash_id="1700000000-crashwin"
printf '%s\n' "$crash_id" > "$home/state/inbox/.requests/crash-rid"
assert_absent "$home/state/inbox/$crash_id.note" \
  "fixture starts with a reservation and no published note"
crash_out=$(run_inbox "$home" note --request-id crash-rid --json "recover me") \
  || fail "retry after a reservation-only crash should complete the original note"
assert_equals "replay" "$(printf '%s' "$crash_out" | json_get outcome)" \
  "completing a reserved request id is a replay of that request"
assert_equals "$crash_id" "$(printf '%s' "$crash_out" | json_get id)" \
  "the reserved note id is reused"
assert_present "$home/state/inbox/$crash_id.note" \
  "the retry publishes the reserved note rather than minting a new id"
assert_equals "1" "$(count_notes "$home")" \
  "crash-window retry leaves exactly one note"
assert_grep "recover me" "$home/state/inbox/$crash_id.note" \
  "the completed note carries the caller's body"
pass "a crash between recording the request id and publishing the note reuses the original id"

# --- saved-but-unannounced, then repair without a second note ---------------

home=$(make_home announce-fail)
set +e
saved_out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note --request-id repair-1 --json "please announce" 2>/dev/null)
saved_code=$?
set -e
expect_code 3 "$saved_code" "request-id note exits 3 when saved but not announced"
assert_equals "created" "$(printf '%s' "$saved_out" | json_get outcome)" \
  "first isolated submit is created"
assert_equals "True" "$(printf '%s' "$saved_out" | json_get saved)" \
  "isolated submit saved the note"
assert_equals "False" "$(printf '%s' "$saved_out" | json_get announced)" \
  "isolated submit could not announce"
saved_id=$(printf '%s' "$saved_out" | json_get id)
assert_equals "1" "$(count_notes "$home")" "isolated submit wrote one note"
assert_equals "0" "$(count_wakes "$home")" "isolated submit wrote no wake"

set +e
replay_fail=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note --request-id repair-1 --json "please announce" 2>/dev/null)
replay_fail_code=$?
set -e
expect_code 3 "$replay_fail_code" "replay while still unannounced also exits 3"
assert_equals "replay" "$(printf '%s' "$replay_fail" | json_get outcome)" \
  "retry with the same request id is a replay"
assert_equals "$saved_id" "$(printf '%s' "$replay_fail" | json_get id)" \
  "unannounced retry keeps the original id"
assert_equals "1" "$(count_notes "$home")" \
  "unannounced retry must not create a second note"

repair=$(run_inbox "$home" note --request-id repair-1 --json "please announce") \
  || fail "replay with a working announcer should repair the wake"
assert_equals "replay" "$(printf '%s' "$repair" | json_get outcome)" \
  "repair is still a replay"
assert_equals "True" "$(printf '%s' "$repair" | json_get announced)" \
  "repair announces the existing note"
assert_equals "$saved_id" "$(printf '%s' "$repair" | json_get id)" \
  "repair keeps the original id"
assert_equals "1" "$(count_notes "$home")" "repair does not create a second note"
assert_equals "1" "$(count_wakes "$home")" "repair appends exactly one wake"

already=$(run_inbox "$home" announce --json "$saved_id") \
  || fail "announce of an already-announced note should succeed"
assert_equals "replay" "$(printf '%s' "$already" | json_get outcome)" \
  "second announce is already-announced"
assert_equals "1" "$(count_wakes "$home")" \
  "already-announced must not append another wake"
home=$(make_home announce-repair)
set +e
unannounced=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note --request-id repair-2 --json "announce me" 2>/dev/null)
set -e
unannounced_id=$(printf '%s' "$unannounced" | json_get id)
assert_equals "0" "$(count_wakes "$home")" "the isolated submit wrote no wake"
repaired=$(run_inbox "$home" announce "$unannounced_id") \
  || fail "announce should repair a note this version saved but could not announce"
assert_contains "$repaired" "announced $unannounced_id" "the repair reports the announcement"
assert_equals "1" "$(count_wakes "$home")" "repairing appends exactly one wake"
pass "saved-but-unannounced notes are repairable without creating a second note"

# A note firstmate already acknowledged needs no wake, so neither the repair
# path nor a request-id replay appends one.
home=$(make_home announce-acked)
set +e
acked=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note --request-id acked-1 --json "drained before repair" 2>/dev/null)
set -e
acked_id=$(printf '%s' "$acked" | json_get id)
run_inbox "$home" drain --ack "$acked_id" >/dev/null || fail "drain --ack failed"
acked_repair=$(run_inbox "$home" announce --json "$acked_id") \
  || fail "announce of an acknowledged note should succeed without waking"
assert_equals "True" "$(printf '%s' "$acked_repair" | json_get acknowledged)" \
  "announce reports the note as already acknowledged"
assert_equals "False" "$(printf '%s' "$acked_repair" | json_get announced)" \
  "announce does not claim a wake it never appended"
acked_human=$(run_inbox "$home" announce "$acked_id") \
  || fail "human announce of an acknowledged note should succeed"
assert_contains "$acked_human" "already-acknowledged $acked_id" \
  "human announce names the acknowledgement"
acked_replay=$(run_inbox "$home" note --request-id acked-1 --json "drained before repair") \
  || fail "replay of an acknowledged note should exit 0"
assert_equals "replay" "$(printf '%s' "$acked_replay" | json_get outcome)" \
  "retry of an acknowledged note is a replay"
assert_equals "True" "$(printf '%s' "$acked_replay" | json_get acknowledged)" \
  "replay reports the note as already acknowledged"
assert_equals "0" "$(count_wakes "$home")" \
  "an acknowledged note never gets a repair wake"
pass "repair and replay do not wake firstmate for an already-acknowledged note"

# --- bounded receipts JSON, omission disclosure, reply cursor ---------------

json_len() {  # <key>
  python3 -c 'import json,sys; print(len(json.load(sys.stdin)[sys.argv[1]]))' "$1"
}

home=$(make_home receipts)
ids=""
i=0
while [ "$i" -lt 21 ]; do
  ids="$ids $(run_inbox "$home" note --request-id "bulk-$i" "bulk body $i" \
    | sed -n 's/^queued //p')"
  i=$((i + 1))
done

receipts=$(run_inbox "$home" receipts) || fail "receipts should succeed"
assert_equals "fm-inbox-receipts.v1" "$(printf '%s' "$receipts" | json_get schema)" \
  "receipts use the receipts schema"
assert_equals "20" "$(printf '%s' "$receipts" | json_len pending)" \
  "pending list is bounded without a reveal flag"
assert_contains "$receipts" "pending notes omitted by bound: 1" \
  "receipts disclose how many pending notes they omitted"
assert_contains "$receipts" "pass --all-pending" \
  "omission names the flag that reveals pending notes"
assert_contains "$receipts" '"acknowledged":false' "pending notes are not acknowledged"

all_receipts=$(run_inbox "$home" receipts --all-pending) \
  || fail "unbounded receipts should succeed"
assert_equals "21" "$(printf '%s' "$all_receipts" | json_len pending)" \
  "--all-pending reveals every pending note"
assert_equals "[]" "$(printf '%s' "$all_receipts" | python3 -c 'import json,sys; print(json.load(sys.stdin)["omitted"])')" \
  "revealing every row leaves omitted empty"

# shellcheck disable=SC2086 # deliberate word splitting: one id per --ack arg.
run_inbox "$home" drain --ack $ids >/dev/null || fail "drain --ack of the bulk notes failed"
handled_receipts=$(run_inbox "$home" receipts) || fail "receipts after drain should succeed"
assert_equals "20" "$(printf '%s' "$handled_receipts" | json_len handled)" \
  "handled list is bounded without a reveal flag"
assert_contains "$handled_receipts" "handled notes omitted by bound: 1" \
  "receipts disclose how many handled notes they omitted"
assert_contains "$handled_receipts" "pass --all-handled" \
  "omission names the flag that reveals handled notes"
assert_equals "21" "$(run_inbox "$home" receipts --all-handled | json_len handled)" \
  "--all-handled reveals every handled note"
assert_contains "$handled_receipts" '"acknowledged":true' "handled notes are acknowledged"
pass "receipts JSON is bounded by fixed bounds and discloses what it omitted"

# A note written before this home tracked announcement markers already appended
# its own wake, and nothing proves that, so receipts say unknown rather than
# false and the repair path refuses it instead of appending a second wake.
home=$(make_home preexisting)
run_inbox "$home" note "establish the inbox" >/dev/null || fail "seed note failed"
legacy="1700000000-legacy"
printf 'id=%s\nat=2026-01-01T00:00:00Z\nsource=text\n--\nfrom before the marker\n' \
  "$legacy" > "$home/state/inbox/$legacy.note"
legacy_announced=$(run_inbox "$home" receipts --all-pending | python3 -c 'import json,sys
rows={r["id"]: r["announced"] for r in json.load(sys.stdin)["pending"]}
print(json.dumps(rows[sys.argv[1]]))' "$legacy")
assert_equals "null" "$legacy_announced" \
  "a note that predates the marker reports announced as unknown, not false"
fresh_announced=$(run_inbox "$home" receipts --all-pending | python3 -c 'import json,sys
print(json.dumps([r["announced"] for r in json.load(sys.stdin)["pending"] if r["id"] != sys.argv[1]]))' "$legacy")
assert_equals "[true]" "$fresh_announced" \
  "a note this version wrote still reports a definite announced state"
before_wakes=$(count_wakes "$home")
set +e
legacy_out=$(run_inbox "$home" announce "$legacy" 2>&1)
legacy_code=$?
set -e
expect_code 1 "$legacy_code" "announcing a note with an unknown announced state is refused"
assert_contains "$legacy_out" "UNKNOWN" "the refusal says the announced state is unknown"
assert_equals "$before_wakes" "$(count_wakes "$home")" \
  "the refused repair must not append a second wake"
pass "notes that predate the announcement marker are unknown, not re-announced"

# Reply cursor: replies recorded within the same second are both readable, in
# recording order, even when the later note id sorts below the earlier one.
home=$(make_home cursor)
mkdir -p "$home/state/inbox"
later="1700000000-aaaaaa"
earlier="1700000000-zzzzzz"
for nid in "$earlier" "$later"; do
  printf 'id=%s\nat=2026-01-01T00:00:00Z\nsource=text\nannounce_marker=1\n--\norder %s\n' \
    "$nid" "$nid" > "$home/state/inbox/$nid.note"
done
run_inbox "$home" reply "$earlier" "answer one" >/dev/null || fail "first reply failed"
run_inbox "$home" reply "$later" "answer two" >/dev/null || fail "second reply failed"
replies=$(run_inbox "$home" receipts --all-replies) || fail "receipts with replies should succeed"
assert_equals "2" "$(printf '%s' "$replies" | json_len replies)" \
  "both replies appear without a cursor"
order=$(printf '%s' "$replies" | python3 -c 'import json,sys
print(" ".join(r["id"] for r in json.load(sys.stdin)["replies"]))')
assert_equals "$earlier $later" "$order" "replies are ordered by when they were recorded"
first_cursor=$(printf '%s' "$replies" | python3 -c 'import json,sys
print(json.load(sys.stdin)["replies"][0]["cursor"])')
after=$(run_inbox "$home" receipts --all-replies --after "$first_cursor") \
  || fail "receipts --after should succeed"
assert_equals "1" "$(printf '%s' "$after" | json_len replies)" \
  "--after returns only replies recorded later"
after_id=$(printf '%s' "$after" | python3 -c 'import json,sys; print(json.load(sys.stdin)["replies"][0]["id"])')
assert_equals "$later" "$after_id" \
  "a same-second reply recorded after the cursor is still delivered"

set +e
conflict=$(run_inbox "$home" reply "$earlier" "answer one" 2>&1)
conflict_code=$?
set -e
expect_code 1 "$conflict_code" "a second reply for the same note is refused"
assert_contains "$conflict" "already recorded" "the refusal names the existing record"
pass "the reply channel is durable and its cursor is a strict order"

# A lost sequence counter must not move the cursor backwards: the next reply
# still sorts after every reply a client has already read.
lost_cursor=$(printf '%s' "$replies" | python3 -c 'import json,sys
print(json.load(sys.stdin)["reply_cursor"])')
rm -f "$home/state/inbox/.replies/.seq"
third="1700000000-mmmmmm"
printf 'id=%s\nat=2026-01-01T00:00:00Z\nsource=text\nannounce_marker=1\n--\norder three\n' \
  "$third" > "$home/state/inbox/$third.note"
run_inbox "$home" reply "$third" "answer three" >/dev/null || fail "third reply failed"
after_lost=$(run_inbox "$home" receipts --after "$lost_cursor") \
  || fail "receipts after a lost counter should succeed"
assert_equals "$third" "$(printf '%s' "$after_lost" | json_get replies 0 id)" \
  "a reply recorded after the counter was lost is still after the client cursor"
pass "the reply cursor never goes backwards when the sequence counter is lost"

# A reply without a valid sequence is malformed: it gets no invented position
# and receipts say so instead of silently ordering it.
home=$(make_home malformed-reply)
mkdir -p "$home/state/inbox/.replies"
bad="1700000000-badseq"
printf 'id=%s\nat=2026-01-01T00:00:00Z\nsource=text\nannounce_marker=1\n--\norder\n' \
  "$bad" > "$home/state/inbox/$bad.note"
printf 'id=%s\nat=2026-01-01T00:00:00Z\n--\nno sequence here\n' \
  "$bad" >"$home/state/inbox/.replies/$bad"
malformed=$(run_inbox "$home" receipts) || fail "receipts with a malformed reply should succeed"
assert_equals "0" "$(printf '%s' "$malformed" | json_len replies)" \
  "a reply without a sequence is not placed in the reply stream"
assert_contains "$malformed" "malformed replies without a valid sequence: 1 ($bad)" \
  "receipts name the malformed reply"
pass "a reply without a valid sequence is reported as malformed"

# One undecodable note must not fail the whole receipts view.
home=$(make_home non-utf8)
run_inbox "$home" note "readable note" >/dev/null || fail "seed note failed"
printf 'id=1700000000-binary\nat=2026-01-01T00:00:00Z\nsource=text\n--\n\377\376 bytes\n' \
  > "$home/state/inbox/1700000000-binary.note"
binary=$(run_inbox "$home" receipts) || fail "receipts must survive a non-UTF-8 note"
assert_equals "2" "$(printf '%s' "$binary" | json_len pending)" \
  "the undecodable note and the readable note are both listed"
pass "a non-UTF-8 note does not break the receipts view"

# --- the wake drain refuses to acknowledge an unacked presented note ----------
# A drain presents "check: captain inbox note <id>" rows; acknowledging them
# while the note itself is unread would retire the only reminder. These cases
# run the real fm-wake-drain.sh and fm-inbox.sh in a scratch home only.

DRAIN_BIN="$ROOT/bin/fm-wake-drain.sh"
DRAIN_ROOT=$(fm_test_tmproot fm-inbox-drain-root)

make_drain_home() {
  local home
  home=$(make_home "$1")
  : > "$home/config/supervision-host-off"
  printf '%s\n' "$home"
}

run_drain() {  # <home> <drain arguments...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_ROOT_OVERRIDE="$DRAIN_ROOT" \
    "$DRAIN_BIN" "$@"
}

# present <home>: drain once and print the exact arguments of its WAKE_ACK_REQUIRED command.
present() {
  local home=$1 err
  err=$(run_drain "$home" 2>&1 >/dev/null) || fail "presentation drain failed: $err"
  printf '%s\n' "$err" | sed -n 's|^WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh ||p'
}

queue_note() {  # <home> <text> -> note id
  local out
  out=$(run_inbox "$1" note "$2") || fail "note failed"
  out=${out#queued }
  printf '%s\n' "${out%%$'\n'*}"
}

queue_rows() {  # <home>
  awk 'END { print NR + 0 }' "$1/state/.wake-queue" 2>/dev/null || printf '0\n'
}

# Unacked note in range: refused, id named, queue untouched; acked: passes.
home=$(make_drain_home ack-gate-one)
note_id=$(queue_note "$home" "advisor note")
ack_args=$(present "$home")
[ -n "$ack_args" ] || fail "the presentation drain printed no WAKE_ACK_REQUIRED command"
rows_before=$(queue_rows "$home")
set +e
# shellcheck disable=SC2086
refusal=$(run_drain "$home" $ack_args 2>&1)
refusal_rc=$?
set -e
assert_not_equals "0" "$refusal_rc" "ack of an unacked presented note is refused"
assert_contains "$refusal" "$note_id" "the refusal names the unacked note id"
assert_equals "$rows_before" "$(queue_rows "$home")" "a refused ack consumes no wake row"
assert_present "$home/state/inbox/$note_id.note" "a refused ack leaves the note pending"
run_inbox "$home" drain --ack "$note_id" >/dev/null || fail "drain --ack failed"
# shellcheck disable=SC2086
run_drain "$home" $ack_args >/dev/null 2>&1 || fail "ack after the note was acked should pass"
assert_equals "0" "$(queue_rows "$home")" "the passing ack consumes the wake row"
# A repeat of the already processed acknowledgement keeps its earlier outcome.
set +e
# shellcheck disable=SC2086
run_drain "$home" $ack_args >/dev/null 2>&1
repeat_rc=$?
set -e
assert_equals "0" "$repeat_rc" "a repeated ack of an already processed sequence still succeeds"
pass "the drain refuses to ack an unacked presented note and passes once it is acked"

# Two unacked notes: both ids named; acking only one still refuses and names the other.
home=$(make_drain_home ack-gate-two)
note_a=$(queue_note "$home" "first advisor note")
note_b=$(queue_note "$home" "second advisor note")
ack_args=$(present "$home")
set +e
# shellcheck disable=SC2086
refusal=$(run_drain "$home" $ack_args 2>&1)
refusal_rc=$?
set -e
assert_not_equals "0" "$refusal_rc" "ack with two unacked notes is refused"
assert_contains "$refusal" "$note_a" "the refusal names the first unacked note"
assert_contains "$refusal" "$note_b" "the refusal names the second unacked note"
run_inbox "$home" drain --ack "$note_a" >/dev/null || fail "drain --ack failed"
set +e
# shellcheck disable=SC2086
refusal=$(run_drain "$home" $ack_args 2>&1)
refusal_rc=$?
set -e
assert_not_equals "0" "$refusal_rc" "ack with one note still unacked is refused"
assert_contains "$refusal" "$note_b" "the refusal names the note still unacked"
assert_not_contains "$refusal" "$note_a" "the refusal does not name the acked note"
pass "every unacked note in the range is named, and an acked note is not"

# An unacked note whose wake row is above the cutoff does not block.
home=$(make_drain_home ack-gate-outside)
note_a=$(queue_note "$home" "presented note")
ack_args=$(present "$home")
run_inbox "$home" drain --ack "$note_a" >/dev/null || fail "drain --ack failed"
note_late=$(queue_note "$home" "note that arrived after presentation")
# shellcheck disable=SC2086
run_drain "$home" $ack_args >/dev/null 2>&1 || fail "an unacked note above the cutoff must not block the ack"
assert_present "$home/state/inbox/$note_late.note" "the later note stays pending"
assert_equals "1" "$(queue_rows "$home")" "only the later note's wake row remains"
pass "an unacked note outside the acknowledged range does not block"

# A range with no inbox note rows acks as before, even with an unacked note elsewhere.
home=$(make_drain_home ack-gate-none)
append_signal_row() {
  FM_STATE_OVERRIDE="$1/state" bash -c '. "$1"; fm_wake_append signal task1 "signal: task1 done"' _ "$ROOT/bin/fm-wake-lib.sh"
}
append_signal_row "$home"
ack_args=$(present "$home")
queue_note "$home" "unrelated pending note" >/dev/null
# shellcheck disable=SC2086
run_drain "$home" $ack_args >/dev/null 2>&1 || fail "a range with no inbox note rows must ack"
pass "a range with no inbox note rows acks exactly as before"

# An inbox the drain cannot read is not an acked note: the ack must keep its rows.
# Handled-note control: a note moved to handled/ is plainly not pending.
home=$(make_drain_home ack-gate-unreadable)
note_id=$(queue_note "$home" "note in an unreadable inbox")
ack_args=$(present "$home")
handled_id=$(queue_note "$home" "note acked before the check")
run_inbox "$home" drain --ack "$handled_id" >/dev/null || fail "drain --ack failed"
rows_before=$(queue_rows "$home")
assert_equals "" "$(run_inbox "$home" pending "$handled_id")" "an acked note is not pending"
assert_equals "$note_id" "$(run_inbox "$home" pending "$note_id" "$handled_id")" "only the unacked note is pending"
if [ "$(id -u)" -eq 0 ]; then
  pass "an unreadable inbox cannot be simulated as root; handled and pending controls hold"
else
  chmod 000 "$home/state/inbox"
  set +e
  pending_out=$(run_inbox "$home" pending "$note_id" 2>&1)
  pending_rc=$?
  # shellcheck disable=SC2086
  refusal=$(run_drain "$home" $ack_args 2>&1)
  refusal_rc=$?
  set -e
  chmod 700 "$home/state/inbox"
  assert_not_equals "0" "$pending_rc" "pending fails closed when the inbox cannot be read"
  assert_not_contains "$pending_out" "$note_id" "an unreadable inbox is not reported as a pending id"
  assert_not_equals "0" "$refusal_rc" "the wake ack is refused when the inbox cannot be read"
  assert_equals "$rows_before" "$(queue_rows "$home")" "a refused ack keeps every wake row"
  assert_present "$home/state/inbox/$note_id.note" "the note is still pending after the refused ack"
  pass "an unreadable inbox fails closed and the wake rows stay"
fi

# The rows the guard checks are the rows the ack consumes. A row claimed while the
# queue lock is released for receipts is neither checked nor consumed, and the
# receipt of the checked row is still recorded. The barrier holds the ack inside
# that window after its real receipt call.
home=$(make_drain_home ack-gate-claim-grows)
race_pid=
fifo="$home/barrier.fifo"
reached="$home/barrier.reached"
mkdir -p "$home/state/terminal-outcomes"
fp=$(printf 'ab%.0s' $(seq 1 32))
printf 'phase=presentation\n' > "$home/state/terminal-outcomes/$fp.pending"
note_id=$(queue_note "$home" "note held by a branch grant")
FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_wake_append check "inactive-reconcile:$2" "check: inactive outcome $2"' _ "$ROOT/bin/fm-wake-lib.sh" "$fp"
sleep 300 &
grant_pid=$!
trap 'kill "$grant_pid" 2>/dev/null || true; [ -z "$race_pid" ] || kill "$race_pid" 2>/dev/null || true; fm_test_cleanup' EXIT
grant() { FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-wake-grant.sh" "$@"; }
grant activate "$grant_pid" g1 || fail "branch grant activation failed"
grant publish g1 1 || fail "branch grant publish failed"
ack_args=$(present "$home")
case "$ack_args" in "--ack-through 2 "*) ;; *) fail "main did not present exactly the receipt row: $ack_args" ;; esac
cp -R "$ROOT/bin" "$home/bin"
cat > "$home/bin/fm-inactive-reconcile.sh" <<SHIM
#!/usr/bin/env bash
"$ROOT/bin/fm-inactive-reconcile.sh" "\$@" || exit \$?
if [ "\${1:-}" = acknowledge-notice ]; then
  : > "$reached"
  read -r _ < "$fifo"
fi
SHIM
chmod +x "$home/bin/fm-inactive-reconcile.sh"
mkfifo "$fifo"
# shellcheck disable=SC2086
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_CONFIG_OVERRIDE="$home/config" FM_ROOT_OVERRIDE="$DRAIN_ROOT" \
  "$home/bin/fm-wake-drain.sh" $ack_args > "$home/race-ack.out" 2>&1 &
race_pid=$!
waited=0
while [ ! -e "$reached" ] && [ "$waited" -lt 200 ]; do sleep 0.1; waited=$((waited + 1)); done
assert_present "$reached" "the ack never reached the receipt window"
grant release g1 || fail "branch grant release failed"
second=$(run_drain "$home" 2>&1) || fail "the second main drain failed"
assert_contains "$second" "$note_id" "the second main drain presented the note released from the grant"
printf 'go\n' > "$fifo"
race_rc=0
wait "$race_pid" || race_rc=$?
race_pid=
assert_equals "0" "$race_rc" "the ack with the claim grown in its window completes: $(cat "$home/race-ack.out")"
assert_present "$home/state/inbox/$note_id.note" "the note is still pending"
assert_contains "$(cat "$home/state/.wake-queue")" "inbox:$note_id" "the note's wake row survives an ack that never checked it"
assert_contains "$(cat "$home/state/terminal-outcomes/$fp.pending")" "notice_emitted=1" "the checked row's real receipt was recorded"
set +e
refusal=$(run_drain "$home" --ack-through 1 --recovery-generation "$(printf '%s' "$ack_args" | sed 's/.*--recovery-generation //')" 2>&1)
refusal_rc=$?
set -e
assert_not_equals "0" "$refusal_rc" "the later ack through the note's row is refused"
assert_contains "$refusal" "$note_id" "the later refusal names the note"
kill "$grant_pid" 2>/dev/null || true
trap 'fm_test_cleanup' EXIT
pass "a row claimed while the lock is released is not consumed unchecked, and the receipt stays consistent"

# --- readiness projection, including unknown -------------------------------

home=$(make_home ready-free)
ready=$(run_inbox "$home" ready) || fail "ready should succeed with no lock"
assert_equals "fm-primary-ready.v1" "$(printf '%s' "$ready" | json_get schema)" \
  "ready uses the readiness schema"
assert_equals "free" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["state"])')" \
  "no lock file is free, not live"
assert_equals "False" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["can_receive"])')" \
  "a free lock cannot receive work"
assert_equals "present" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["posture"]["state"])')" \
  "no away flag is present posture"

# A live non-harness pid in the lock file must not be treated as a live primary.
home=$(make_home ready-unknown)
printf '%s\n' "$$" > "$home/state/.lock"
ready=$(run_inbox "$home" ready) || fail "ready should succeed for an unclassified pid"
lock_state=$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["state"])')
assert_equals "unknown" "$lock_state" \
  "a live process that is not a verified harness is unknown, not held"
live=$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["live_harness"])')
assert_equals "False" "$live" "a bash test pid is not a live harness"
can=$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["can_receive"])')
[ "$can" = "False" ] || [ "$can" = "unknown" ] \
  || fail "unknown lock must not claim can_receive true (got $can)"

human_lock=$(run_lock "$home" status) || fail "lock status should succeed"
assert_contains "$human_lock" "stale (pid $$ dead or not a harness)" \
  "human lock status keeps its historical stale wording"

# Dead pid is stale, not held.
home=$(make_home ready-stale)
printf '%s\n' "999999" > "$home/state/.lock"
ready=$(run_inbox "$home" ready) || fail "ready should succeed for a dead pid"
assert_equals "stale" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["state"])')" \
  "a dead recorded pid is stale"
assert_equals "False" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["can_receive"])')" \
  "a stale lock cannot receive work"

# Existence of a pane-like leftover must not become liveness: unreadable lock.
home=$(make_home ready-unreadable)
mkdir -p "$home/state/.lock"
ready=$(run_inbox "$home" ready) || fail "ready should succeed for a directory lock"
assert_equals "unreadable" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["state"])')" \
  "a non-file lock is unreadable rather than held"
# A Claude primary mid-turn runs no watcher process - its watcher is armed at
# turn end - so the model-aware supervision verdict, not the pid-strict watcher
# check, owns whether the wake will be drained.
home=$(make_home ready-midturn)
touch "$home/state/.last-watcher-beat"
midturn=$(FM_SUPERVISION_MODEL=autoarm run_inbox "$home" ready) \
  || fail "ready should succeed for a mid-turn autoarm primary"
assert_equals "healthy" "$(printf '%s' "$midturn" | json_get wake_consumer state)" \
  "a mid-turn autoarm primary with a fresh beacon has a healthy wake consumer"

# A home that never ran a watcher has no observation, so it reports no age
# rather than the missing-path sentinel. With no lock holder the model is
# unknown for this home, which is the honest caller path.
home=$(make_home ready-no-beacon)
nobeat=$(run_inbox "$home" ready) || fail "ready should succeed with no beacon"
assert_equals "supervision-model-unknown-for-home" \
  "$(printf '%s' "$nobeat" | json_get wake_consumer reason)" \
  "no lock holder means the home's supervision model is unknown"
assert_equals "None" "$(printf '%s' "$nobeat" | json_get wake_consumer beacon_age_seconds)" \
  "a beacon that does not exist has no age"

# The intended caller (HTTP backend, ssh host fm-inbox.sh ready) does not set
# FM_SUPERVISION_MODEL. A live non-harness lock pid must not invent a model
# from the caller's own process tree.
home=$(make_home ready-no-override)
printf '%s\n' "$$" > "$home/state/.lock"
touch "$home/state/.last-watcher-beat"
no_override=$(run_inbox "$home" ready) || fail "ready should succeed with no model override"
assert_equals "unknown" "$(printf '%s' "$no_override" | json_get wake_consumer state)" \
  "without a lock-holder harness, wake-consumer is unknown"
assert_equals "supervision-model-unknown-for-home" \
  "$(printf '%s' "$no_override" | json_get wake_consumer reason)" \
  "the unknown reason names that the model could not be determined for this home"
can=$(printf '%s' "$no_override" | json_get can_receive)
assert_equals "unknown" "$can" "unknown lock plus unknown consumer is not can_receive true"

# A live lock holder whose ancestry names a known harness, plus a fresh
# beacon, is the yes path: the inspected home can receive work.
home=$(make_home ready-holder)
# A process whose ps comm is the harness name, so lock inspect and
# fm-harness.sh ancestry both classify it without PATH tricks.
perl -e '$0="claude"; sleep 60' &
holder_pid=$!
# Give ps a moment to report the renamed comm.
sleep 0.2
kill_holder() {
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
}
trap 'kill_holder; fm_test_cleanup' EXIT
printf '%s\n' "$holder_pid" > "$home/state/.lock"
touch "$home/state/.last-watcher-beat"
held=$(run_inbox "$home" ready) || fail "ready should succeed for a lock-holder harness"
assert_equals "held" "$(printf '%s' "$held" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["state"])')" \
  "a live claude-named holder is a held lock"
assert_equals "healthy" "$(printf '%s' "$held" | json_get wake_consumer state)" \
  "lock-holder ancestry plus a fresh beacon is a healthy wake consumer"
assert_equals "True" "$(printf '%s' "$held" | json_get can_receive)" \
  "a held lock with a healthy wake consumer can receive work"
kill_holder
trap fm_test_cleanup EXIT
pass "readiness says unknown (or not-receivable) instead of inferring liveness from a lock"

# --- invalid input ----------------------------------------------------------

home=$(make_home invalid)
set +e
empty_out=$(run_inbox "$home" note --request-id x --json "   " 2>&1)
empty_code=$?
bad_out=$(run_inbox "$home" note --request-id '../etc/passwd' --json "nope" 2>&1)
bad_code=$?
# An empty request id must be refused, never treated as "no request id given":
# falling through to the non-idempotent path would make a retry a second note.
blank_out=$(run_inbox "$home" note --request-id '' --json "silently duplicated" 2>&1)
blank_code=$?
set -e
expect_code 1 "$empty_code" "empty body is still refused"
expect_code 1 "$bad_code" "path-like request ids are refused"
expect_code 1 "$blank_code" "an empty request id is refused, not ignored"
assert_contains "$empty_out" "empty" "empty-body refusal says the note was empty"
assert_contains "$bad_out" "invalid request id" "unsafe request ids are rejected by name"
assert_contains "$blank_out" "invalid request id" "an empty request id is rejected by name"
assert_equals "0" "$(count_notes "$home")" "refusals must not write a note"
pass "empty bodies and unsafe request ids are refused"

# The voice handover passes a raw transcript as the first argument, so a body
# that opens with a double dash is text, not an option.
home=$(make_home dash-body)
transcript="--- handover: ship the console backend --now"
dash_out=$(run_inbox "$home" note "$transcript") \
  || fail "a note body opening with dashes should be queued"
assert_contains "$dash_out" "queued " "a dash-leading body is queued like any other"
assert_equals "1" "$(count_notes "$home")" "a dash-leading body writes one note"
dash_body=$(run_inbox "$home" receipts --all-pending | python3 -c 'import json,sys
print(json.load(sys.stdin)["pending"][0]["body"])')
assert_equals "$transcript" "$dash_body" "the transcript is stored verbatim"
escaped=$(run_inbox "$home" note -- "--request-id is body text here") \
  || fail "-- should end option parsing"
assert_contains "$escaped" "queued " "-- escapes a body that looks like a flag"
pass "a note body that opens with a double dash is queued as text"

# --- drain still acks by moving the note ------------------------------------

home=$(make_home drain)
queued=$(run_inbox "$home" note "ack me") || fail "note for drain failed"
did=${queued#queued }
did=${did%%$'\n'*}
run_inbox "$home" drain --ack "$did" >/dev/null || fail "drain --ack failed"
assert_absent "$home/state/inbox/$did.note" "acked note leaves pending"
assert_present "$home/state/inbox/handled/$did.note" "acked note is in handled"
pass "drain --ack still moves the note to handled"

