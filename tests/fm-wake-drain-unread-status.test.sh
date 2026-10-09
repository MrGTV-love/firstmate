#!/usr/bin/env bash
# tests/fm-wake-drain-unread-status.test.sh - drain must surface every still-
# unread informational status line since the last presentation, not only the
# newest line. This is a portable tests/ regression: the drain decides WHICH
# status lines to surface, so the real drain/classify functions over crafted
# status logs are sufficient (no harness). The incident this pins: a `note:`
# answer immediately followed by a routine `note:` was buried because the
# annotation kept only the newest line and `note:` never folds into OPEN
# DECISIONS.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-unread-status-tests)

# These regressions exercise status presentation on a home that does not run
# the supervision host, so its BRANCH OUTCOMES section stays out of the drain;
# the explicit off file pins that posture on every primary instead of reading
# the code root's config (bin/fm-supervision-engine-lib.sh owns the gate).
mkdir -p "$TMP_ROOT/config"
: > "$TMP_ROOT/config/supervision-host-off"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"

# Establish the durable last-presentation cursor by draining once over a
# bootstrap line so later appends are "new since last drain".
prime_cursor() {  # <state> <status-file>
  local state=$1 status=$2
  printf 'note: bootstrap cursor line\n' > "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>/dev/null \
    || fail "bootstrap drain failed while priming the unread cursor"
}

test_incident_note_answer_buried_under_routine_note_surfaces_both() {
  local dir state out status
  dir=$(make_case incident-buried-note)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task1.status"
  prime_cursor "$state" "$status"

  printf 'note: captain said use REST not RPC\n' >> "$status"
  printf 'note: re-read acknowledgement\n' >> "$status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on the incident shape"

  grep -F 'UNREAD STATUS' "$out" >/dev/null \
    || fail "the incident shape produced no UNREAD STATUS section: $(cat "$out")"
  grep -F 'task1 note: captain said use REST not RPC' "$out" >/dev/null \
    || fail "the buried answer note was not surfaced: $(cat "$out")"
  grep -F 'task1 note: re-read acknowledgement' "$out" >/dev/null \
    || fail "the newest routine note was dropped while surfacing the answer: $(cat "$out")"
  pass "a note: answer buried under a later routine note: is surfaced with both lines"
}

test_already_presented_notes_are_not_replayed() {
  local dir state out status
  dir=$(make_case no-replay)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task2.status"
  prime_cursor "$state" "$status"

  printf 'note: captain said use REST not RPC\n' >> "$status"
  printf 'note: re-read acknowledgement\n' >> "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "first drain of unread notes failed"
  grep -F 'captain said use REST not RPC' "$out" >/dev/null \
    || fail "setup error: first drain did not surface the answer note"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second drain after presentation failed"
  if grep -F 'captain said use REST not RPC' "$out" >/dev/null; then
    fail "an already-presented answer note was replayed as new: $(cat "$out")"
  fi
  if grep -F 're-read acknowledgement' "$out" >/dev/null; then
    fail "an already-presented routine note was replayed as new: $(cat "$out")"
  fi
  if grep -F 'UNREAD STATUS' "$out" >/dev/null; then
    fail "the second drain reprinted an UNREAD STATUS section with no new lines: $(cat "$out")"
  fi
  pass "already-presented note: lines are not re-surfaced on the next drain"
}

test_brand_new_note_after_presentation_is_surfaced() {
  local dir state out status
  dir=$(make_case brand-new-note)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task3.status"
  prime_cursor "$state" "$status"

  printf 'note: first answer\n' >> "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain of the first note failed"
  grep -F 'task3 note: first answer' "$out" >/dev/null \
    || fail "setup error: first note was not presented"

  printf 'note: follow-up after ack\n' >> "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain of the brand-new note failed"
  grep -F 'task3 note: follow-up after ack' "$out" >/dev/null \
    || fail "a brand-new note after presentation was not surfaced: $(cat "$out")"
  if grep -F 'task3 note: first answer' "$out" >/dev/null; then
    fail "the already-presented first note was replayed next to the new one: $(cat "$out")"
  fi
  pass "a brand-new note: after presentation is surfaced without replaying handled lines"
}

test_signal_annotation_surfaces_every_unread_note_not_only_the_newest() {
  local dir state out err status
  dir=$(make_case signal-annotation)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"
  status="$state/task4.status"
  prime_cursor "$state" "$status"

  printf 'note: captain said use REST not RPC\n' >> "$status"
  printf 'note: re-read acknowledgement\n' >> "$status"
  append_wake "$state" signal task4.status "signal: task4.status" \
    || fail "queueing the incident-shape status signal failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" \
    || fail "signal drain failed on the incident shape"

  grep -F 'unread wake-EVENT since last drain, not current state: task4.status: note: captain said use REST not RPC' "$out" >/dev/null \
    || fail "the signal annotation dropped the buried answer note: $(cat "$out")"
  grep -F 'latest wake-EVENT observed at drain, not current state: task4.status: note: re-read acknowledgement' "$out" >/dev/null \
    || fail "the signal annotation dropped the newest routine note: $(cat "$out")"
  grep "$(printf '\tsignal\ttask4.status\t')" "$out" >/dev/null \
    || fail "surfacing unread notes hid the authoritative raw wake row"
  pass "a queued status signal annotates every unread note, not only the newest"
}

test_pending_reply_resolution_surfaces_once() {
  local dir state out status
  dir=$(make_case pending-reply-resolution)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task5.status"
  prime_cursor "$state" "$status"

  printf 'blocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=task5 pending-reply-id=abcdef0123456789 request=ship it\n' >> "$status"
  append_wake "$state" signal task5.status "signal: task5.status" \
    || fail "queueing the pending-reply request signal failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null \
    || fail "drain failed while acknowledging the pending-reply request"
  {
    printf 'resolved [key=pending-reply-abcdef0123456789]: pending-reply-resolved: task=task5 pending-reply-id=abcdef0123456789 via=status\n'
    printf 'note: re-read acknowledgement\n'
  } >> "$status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a pending-reply resolution"

  grep -F 'pending-reply-resolved: task=task5 pending-reply-id=abcdef0123456789 via=status' "$out" >/dev/null \
    || fail "the pending-reply resolution was buried under the later note: $(cat "$out")"
  grep -F 'task5 note: re-read acknowledgement' "$out" >/dev/null \
    || fail "the trailing note was not surfaced with the pending-reply resolution: $(cat "$out")"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the pending-reply resolution did not close its open decision: $(cat "$out")"
  fi

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second drain after pending-reply presentation failed"
  if grep -F 'pending-reply-resolved:' "$out" >/dev/null; then
    fail "an already-presented pending-reply resolution was replayed: $(cat "$out")"
  fi
  pass "a pending-reply resolution buried under a later note surfaces once and closes OPEN DECISIONS"
}

# The watcher's pending-reply close goes through the self-announced append, so
# it records its bytes as this home's own and never wakes. The drain must still
# present that reserved-key resolution in UNREAD STATUS, its only guaranteed
# presentation.
test_self_announced_pending_reply_close_still_surfaces() {
  local dir state out status corr
  dir=$(make_case self-announced-pending-reply)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task6.status"

  run_pending_reply() {
    FM_STATE_OVERRIDE="$state" FM_PENDING_REPLY_NOW=5000 bash -c '
      . "$1"; . "$2"; shift 2; "$@"
    ' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$ROOT/bin/fm-wake-lib.sh" "$@"
  }

  corr=$(run_pending_reply fm_pending_reply_create "$dir" "$state" task6 "ship it") \
    || fail "could not create the pending-reply record"
  run_pending_reply fm_pending_reply_mark_delivered "$state" "$corr" \
    || fail "could not mark the pending-reply request delivered"
  FM_STATE_OVERRIDE="$state" FM_PENDING_REPLY_NOW=5000 bash -c '
    . "$1"; rec=$(fm_pending_reply_path "$2" "$3")
    fm_pending_reply_set "$rec" phase escalated && fm_pending_reply_set "$rec" escalated_epoch 4950
  ' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$state" "$corr" \
    || fail "could not mark the pending-reply request escalated"

  printf 'blocked [key=pending-reply-%s]: pending-reply-missed: task=task6 pending-reply-id=%s request=ship it\n' \
    "$corr" "$corr" > "$status"
  prime_status_seen "$state" "$status" || fail "could not mark the status file surfaced"
  append_wake "$state" signal task6.status "signal: task6.status" \
    || fail "queueing the pending-reply escalation signal failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null || fail "drain of the escalation failed"
  printf 'done [corr=%s]: shipped after all\n' "$corr" >> "$status"
  prime_status_seen "$state" "$status" || fail "could not mark the status file surfaced"
  append_wake "$state" signal task6.status "signal: task6.status" \
    || fail "queueing the delayed reply signal failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null || fail "drain of the delayed reply failed"

  run_pending_reply fm_pending_reply_try_resolve "$state" "$corr" \
    || fail "the delayed reply did not resolve the pending-reply record"
  sed -E 's/ \[at=[0-9]+\]//' "$status" \
    | grep -F "resolved [key=pending-reply-$corr]: pending-reply-resolved:" >/dev/null \
    || fail "the resolve did not append the escalation close: $(cat "$status")"
  [ -s "$state/.task6.home-appends" ] \
    || fail "the escalation close did not go through the self-announced append"
  run_pending_reply fm_wake_signal_seen_current "$state" "$status" \
    || fail "the self-announced escalation close was left to re-wake this home"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain after the escalation close failed"
  sed -E 's/ \[at=[0-9]+\]//' "$out" \
    | grep -F "task6 resolved [key=pending-reply-$corr]: pending-reply-resolved: task=task6 pending-reply-id=$corr" >/dev/null \
    || fail "the self-announced pending-reply resolution was hidden from UNREAD STATUS: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second drain after the escalation close failed"
  if grep -F 'pending-reply-resolved:' "$out" >/dev/null; then
    fail "an already-presented self-announced resolution was replayed: $(cat "$out")"
  fi
  pass "a self-announced pending-reply close does not wake yet still surfaces once in UNREAD STATUS"
}

test_unread_output_over_cap_remains_recoverable() {
  local dir state out status i payload
  dir=$(make_case unread-over-cap)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task-cap.status"
  prime_cursor "$state" "$status"
  payload=$(printf '%0180d' 0)
  i=1
  while [ "$i" -le 30 ]; do
    printf 'note: overflow-%02d %s\n' "$i" "$payload" >> "$status"
    i=$((i + 1))
  done

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed for unread output over the former cap"
  grep -F 'task-cap note: overflow-01' "$out" >/dev/null \
    || fail "the first over-cap note was not surfaced"
  grep -F 'task-cap note: overflow-30' "$out" >/dev/null \
    || fail "a later note vanished behind the unread byte cap: $(cat "$out")"
  if grep -F 'more omitted' "$out" >/dev/null; then
    fail "the unread section still omitted complete lines: $(cat "$out")"
  fi
  pass "unread status over the former byte cap preserves every line"
}

test_snapshot_does_not_ack_a_later_append() {
  local dir state status first second
  dir=$(make_case snapshot-append)
  state="$dir/state"
  status="$state/task-race.status"
  prime_cursor "$state" "$status"
  printf 'note: included in presentation snapshot\n' >> "$status"

  FM_STATE_OVERRIDE="$state" bash -c '
    set -u
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-classify-lib.sh"
    snapshot=$(status_presentation_snapshot "$STATE")
    scan_unread_surface_snapshot "$STATE" "$snapshot" > "$2"
    printf "note: appended after presentation snapshot\n" >> "$STATE/task-race.status"
    scan_open_decisions_snapshot "$STATE" "$snapshot" >/dev/null
    status_commit_presentation_snapshot "$STATE" "$snapshot"
    scan_unread_surface_lines "$STATE" > "$3"
  ' _ "$ROOT" "$dir/first" "$dir/second" || fail "snapshot race exercise failed"
  first=$(cat "$dir/first")
  second=$(cat "$dir/second")
  case "$first" in *'included in presentation snapshot'*) ;; *) fail "snapshot omitted the line it captured: $first" ;; esac
  case "$first" in *'appended after presentation snapshot'*) fail "snapshot read beyond its endpoint: $first" ;; esac
  case "$second" in *'appended after presentation snapshot'*) ;; *) fail "fold advancement swallowed a post-snapshot append: $second" ;; esac
  case "$second" in *'included in presentation snapshot'*) fail "the next scan replayed a presented line: $second" ;; esac
  pass "presentation cursor advances only through its captured endpoint"
}

test_retired_task_id_starts_new_status_unread() {
  local dir state out offset event old_ident
  dir=$(make_case retired-task-reuse)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'note: old reused-task history\n' > "$state/reused.status"
  printf 'note: stable neighboring history\n' > "$state/neighbor.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null \
    || fail "drain failed while acknowledging pre-retirement histories"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-classify-lib.sh"
    _fm_open_decisions_file_ident "$STATE/reused.status" > "$2"
    printf "40@$(cat "$2")" > "$(status_signal_seen_marker_path "$STATE" reused)"
    printf "40@$(cat "$2")" > "$(status_heartbeat_seen_marker_path "$STATE" reused)"
    printf "40@$(cat "$2")" > "$(status_daemon_seen_marker_path "$STATE" reused)"
    ledger=$(status_home_appends_path "$STATE/reused.status")
    status_home_appends_record "$STATE/reused.status" 0 12 || exit 1
    [ -f "$ledger" ] || exit 1
    mkdir -p "$ledger.lock" || exit 1
    printf "%s\n" 2147483646 > "$ledger.lock/pid" || exit 1
    status_retire_presentation_task "$STATE" reused || exit 1
    for marker in \
      "$(status_signal_seen_marker_path "$STATE" reused)" \
      "$(status_heartbeat_seen_marker_path "$STATE" reused)" \
      "$(status_daemon_seen_marker_path "$STATE" reused)" \
      "$ledger" "$ledger.lock"; do
      [ ! -e "$marker" ] && [ ! -L "$marker" ] || exit 1
    done
  ' _ "$ROOT" "$dir/old-ident" || fail "retiring the reused task presentation state failed"
  printf 'blocked: release host unavailable\nworking: routine padding after the reused task started again\nnote: first event from reused task id\n' \
    > "$state/reused.status"
  old_ident=$(cat "$dir/old-ident")
  printf '40@%s' "$old_ident" > "$state/.seen-reused_status"
  offset=$(bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-classify-lib.sh"
    fm_wake_signal_seen_size "$2" "$2/reused.status"
  ' _ "$ROOT" "$state")
  [ "$offset" = 0 ] || fail "a retired file identity restored a stale offset after task reuse"
  event=$(bash -c '
    . "$1/bin/fm-classify-lib.sh"
    status_span_first_actionable "$2/reused.status" "$3"
  ' _ "$ROOT" "$state" "$offset")
  [ "$event" = 'blocked: release host unavailable' ] \
    || fail "retired supervision offsets hid the replacement task blocker: $event"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain failed after reusing a retired task id"
  grep -F 'reused note: first event from reused task id' "$out" >/dev/null \
    || fail "the retired manifest row skipped the new task prefix: $(cat "$out")"
  if grep -F 'stable neighboring history' "$out" >/dev/null; then
    fail "retiring one task replayed a neighboring task's handled history: $(cat "$out")"
  fi
  pass "a reused task id starts its replacement status log unread at byte zero"
}

test_weak_identity_still_presents_and_advances() {
  local dir state out second reader
  dir=$(make_case weak-identity); state="$dir/state"
  out="$dir/first.out"; second="$dir/second.out"; reader="$dir/identity-reader"
  printf '#!/usr/bin/env bash\nprintf "weak:7:8"\n' > "$reader"; chmod +x "$reader"
  printf 'needs-decision [key=release]: choose target\nnote: release context attached\n' > "$state/weak.status"
  FM_STATUS_IDENTITY_READER="$reader" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain failed with the platform-strength fallback identity"
  grep -F 'weak [key=release] needs-decision: choose target' "$out" >/dev/null \
    || fail "weak identity omitted OPEN DECISIONS: $(cat "$out")"
  grep -F 'weak note: release context attached' "$out" >/dev/null \
    || fail "weak identity omitted unread status: $(cat "$out")"
  FM_STATUS_IDENTITY_READER="$reader" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$second" \
    || fail "second drain failed with the platform-strength fallback identity"
  grep -F 'release context attached' "$second" >/dev/null \
    && fail "weak identity did not advance the presented-status cursor"
  pass "fallback identity still presents and advances status state"
}

test_snapshot_failure_is_visible() {
  local dir state out reader
  dir=$(make_case snapshot-failure); state="$dir/state"; out="$dir/drain.out"; reader="$dir/identity-reader"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$reader"; chmod +x "$reader"
  printf 'needs-decision: choose target\n' > "$state/fail.status"
  FM_STATUS_IDENTITY_READER="$reader" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain aborted instead of reporting its incomplete status surface"
  grep -F 'STATUS PRESENTATION INCOMPLETE:' "$out" >/dev/null \
    || fail "snapshot failure produced a silently incomplete drain: $(cat "$out")"
  pass "snapshot failures are reported visibly"
}

test_manifest_read_failure_does_not_replay_or_replace_receipts() {
  local dir state out err owner mode prefix
  dir=$(make_case manifest-read-failure); state="$dir/state"
  out="$dir/drain.out"; err="$dir/drain.err"
  printf 'note: handled neighboring note\n' > "$state/a-neighbor.status"
  printf 'note: handled answer note\n' > "$state/b-answer.status"
  printf 'done: handled completion\n' > "$state/c-done.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>/dev/null \
    || fail "could not establish handled note and completion receipts"
  cp "$state/.status-presentation-cursor" "$dir/original.cursor"
  IFS= read -r prefix < "$dir/original.cursor"
  prefix+=$'\n'
  printf 'note: new answer after the receipt\n' >> "$state/b-answer.status"
  for owner in status_acknowledge_presented_snapshot print_status_outcome_backstop_section status_commit_presentation_snapshot fm_wake_print_annotations; do
    if [ "$owner" = fm_wake_print_annotations ]; then
      append_wake "$state" signal b-answer.status 'signal: b-answer.status' \
        || fail "could not queue the manifest-failure signal annotation"
    fi
    for mode in empty prefix; do
      FM_STATE_OVERRIDE="$state" FM_MANIFEST_FAULT_OWNER="$owner" FM_MANIFEST_FAULT_MODE="$mode" \
        FM_MANIFEST_FAULT_PREFIX="$prefix" FM_MANIFEST_FAULT_LOG="$dir/fault.log" bash -c '
        read() {
          local __test_frame
          if [ "${FUNCNAME[1]:-}" = _fm_read_file_into ]; then
            for __test_frame in "${FUNCNAME[@]}"; do
              if [ "$__test_frame" = "$FM_MANIFEST_FAULT_OWNER" ]; then
                printf "read failure\n" >> "$FM_MANIFEST_FAULT_LOG"
                case "$FM_MANIFEST_FAULT_MODE" in
                  empty) printf -v "${!#}" "%s" "" ;;
                  prefix) printf -v "${!#}" "%s" "$FM_MANIFEST_FAULT_PREFIX" ;;
                esac
                return 1
              fi
            done
          fi
          builtin read "$@"
        }
        drain=$1; shift
        . "$drain"
      ' _ "$DRAIN" > "$out" 2> "$err" \
        || fail "drain exited instead of reporting incomplete presentation"
      [ -s "$dir/fault.log" ] || fail "manifest failure was not exercised for $owner/$mode"
      rm -f "$dir/fault.log"
      if [ "$owner" = fm_wake_print_annotations ]; then
        if grep -F 'wake annotation:' "$out" >/dev/null; then fail "failed manifest read published a signal annotation"; fi
      elif [ "$owner" != status_commit_presentation_snapshot ] && [ -s "$out" ]; then
        fail "manifest read failure published an incomplete presentation for $owner/$mode: $(cat "$out")"
      fi
      cmp -s "$dir/original.cursor" "$state/.status-presentation-cursor" \
        || fail "manifest read failure replaced a handled receipt for $owner/$mode"
      if grep -E 'handled neighboring note|handled answer note|handled completion' "$out" >/dev/null; then
        fail "manifest read failure replayed handled status for $owner/$mode: $(cat "$out")"
      fi
    done
  done
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" \
    || fail "drain did not recover after the manifest read failure"
  grep -F 'b-answer note: new answer after the receipt' "$out" >/dev/null \
    || fail "the failed presentation swallowed the new note"
  if grep -E 'handled neighboring note|handled answer note|handled completion' "$out" >/dev/null; then
    fail "recovery replayed previously handled status: $(cat "$out")"
  fi
  pass "failed or partial manifest reads abort all receipt consumers without replay or replacement"
}

test_manifest_reader_preserves_complete_bytes() {
  . "$ROOT/bin/fm-status-io-lib.sh"
  local dir input actual
  dir=$(make_case manifest-reader-bytes)
  for input in '' $'row\tidentity\t42\t42\n' $'row\tidentity\t42\t42\n\n' $'row\tidentité\t42\t42'; do
    printf '%s' "$input" > "$dir/manifest"
    actual=unchanged
    _fm_read_file_into "$dir/manifest" actual || fail "complete manifest read failed"
    [ "$actual" = "$input" ] || fail "complete manifest read changed persisted bytes"
  done
  printf 'row\tidentity\t42\t42\000another\tidentity\t1\t1\n' > "$dir/manifest"
  actual=unchanged
  if _fm_read_file_into "$dir/manifest" actual; then fail "manifest reader accepted an incomplete NUL-delimited prefix"; fi
  [ "$actual" = unchanged ] || fail "failed manifest read published partial bytes"
  pass "manifest reader preserves empty, unterminated, multibyte and trailing-newline bytes"
}

test_open_decisions_fold_is_unchanged() {
  local dir state out
  dir=$(make_case open-decisions-regression)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task6.status"
  printf 'working: continuing other work\n' >> "$state/task6.status"
  printf 'note: re-read acknowledgement\n' >> "$state/task6.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a buried needs-decision plus a note"

  grep -F 'task6 [key=api-shape] needs-decision: pick REST or RPC' "$out" >/dev/null \
    || fail "OPEN DECISIONS no longer surfaces a buried needs-decision: $(cat "$out")"
  grep -F 'task6 note: re-read acknowledgement' "$out" >/dev/null \
    || fail "the unread note was not surfaced alongside the still-open decision: $(cat "$out")"
  grep -F "close one by answering it: bin/fm-send.sh <task> --resolve-key <key>" "$out" >/dev/null \
    || fail "OPEN DECISIONS lost its answerer-closes hint"

  printf 'resolved [key=api-shape]: went with REST\n' >> "$state/task6.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after resolving the keyed decision"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "an explicitly resolved decision still printed as open: $(cat "$out")"
  fi
  if grep -F 'pick REST or RPC' "$out" >/dev/null; then
    fail "a resolved decision leaked back through the unread surface: $(cat "$out")"
  fi
  pass "OPEN DECISIONS still folds needs-decision/blocked independently of unread notes"
}

test_empty_queue_does_not_swallow_later_signal_annotation() {
  local dir state out status
  dir=$(make_case delayed-signal-annotation)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task-delayed.status"
  printf 'done: shipped before watcher published signal\n' > "$status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "empty-queue drain failed before delayed signal publication"
  grep -F 'task-delayed done: shipped before watcher published signal' "$out" >/dev/null \
    || fail "the main-drain loss backstop did not surface the terminal event before its delayed signal: $(cat "$out")"

  append_wake "$state" signal task-delayed.status "signal: task-delayed.status" \
    || fail "publishing the delayed status signal failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain failed after delayed signal publication"
  grep -F 'latest wake-EVENT observed at drain, not current state: task-delayed.status: done: shipped before watcher published signal' "$out" >/dev/null \
    || fail "the empty-queue drain acknowledged an event before its signal annotation: $(cat "$out")"
  pass "an empty-queue backstop presentation still preserves the status for its later signal annotation"
}

test_routine_working_and_covered_done_stay_silent_on_the_empty_queue() {
  local dir state out old
  dir=$(make_case silent-working)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'working: on it\n' > "$state/task7.status"
  printf 'done: shipped clean\n' > "$state/task8.status"
  old=$(( $(date +%s) - 20 ))
  perl -e 'utime($ARGV[0], $ARGV[0], $ARGV[1]) or exit 1' "$old" "$state/task8.status" \
    || fail "could not age the covered done fixture"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task8 --verdict captain --summary 'shipped clean was handled' >/dev/null \
    || fail "could not record the newer branch outcome fixture"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with routine working and covered done lines"

  if grep -F 'UNREAD STATUS' "$out" >/dev/null; then
    fail "routine working/covered done lines printed an UNREAD STATUS section: $(cat "$out")"
  fi
  if grep -F 'STATUS OUTCOME BACKSTOP' "$out" >/dev/null; then
    fail "a covered done line printed the outcome backstop: $(cat "$out")"
  fi
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "routine working/covered done lines printed OPEN DECISIONS: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the empty-queue covered routine case was not silent: $(cat "$out")"
  pass "routine working and branch-covered done lines print nothing on an empty-queue drain"
}

# A fleet-sized drain must not fork once per status line or once per cursor row.
# The incident: a drain over 25 status logs and a 25-row presentation cursor
# created thousands of processes per run, because every cursor-row read, every
# stat, and every routine `resolved` line each paid a command substitution, and
# the cost grew with the fleet and with unread history. Production now takes
# those values without a child process, so the subshells an empty-queue drain
# enters over routine history must stay flat as history grows and must grow only
# linearly, by a small fixed amount, as tasks are added.
#
# subshell_entries <state> <count-file> prints how many subshells the drain
# entered (command substitutions, pipeline stages, and the like). The drain is
# sourced under set -T so the DEBUG trap follows into every subshell, and each
# process notes the first command it runs at a new subshell depth: a child
# inherits its parent's last-seen depth, so its first command is the entry.
subshell_entries() {
  local state=$1 count=$2
  : > "$count"
  # The drain reads its own arguments, so the script path and the count file
  # travel in the environment and the sourced script sees no arguments.
  FM_STATE_OVERRIDE="$state" SUBSHELL_ENTRY_COUNT="$count" SUBSHELL_ENTRY_DRAIN="$DRAIN" bash -c '
    set -T
    seen_depth=0
    trap '\''if [ "$BASH_SUBSHELL" != "$seen_depth" ]; then seen_depth=$BASH_SUBSHELL; printf x >> "$SUBSHELL_ENTRY_COUNT"; fi'\'' DEBUG
    . "$SUBSHELL_ENTRY_DRAIN"
  ' >/dev/null 2>&1 || fail "the instrumented drain exited non-zero"
  wc -c < "$count" | tr -d '[:space:]'
}

# <state> <tasks> <history>: each task opens with a working line, then carries
# <history> routine lines, half of them `resolved` closes under a non-reserved
# key. Routine lines stay unread (and so are rescanned by every drain) until a
# signal needs them, which makes this the steady state of a busy fleet.
# Leave checkpoints absent: priming them first hides per-line cold-fold forks.
build_routine_fleet() {
  local state=$1 tasks=$2 history=$3 t i
  for ((t = 0; t < tasks; t++)); do
    {
      printf 'working: starting task %s\n' "$t"
      for ((i = 0; i < history; i++)); do
        printf 'resolved [key=side-%s]: routine close %s\n' "$i" "$i"
        printf 'working: step %s\n' "$i"
      done
    } > "$state/fleet$t.status"
  done
}

test_drain_subshell_entries_stay_flat_as_history_and_fleet_grow() {
  local dir small_hist large_hist few many per_task warm_few warm_many warm_per_task
  dir=$(make_case drain-subshell-entries)
  mkdir -p "$dir/h-small/state" "$dir/h-large/state" "$dir/f-few/state" "$dir/f-many/state"
  build_routine_fleet "$dir/h-small/state" 3 3
  build_routine_fleet "$dir/h-large/state" 3 60
  small_hist=$(subshell_entries "$dir/h-small/state" "$dir/h-small.count")
  large_hist=$(subshell_entries "$dir/h-large/state" "$dir/h-large.count")
  [ "$large_hist" -le "$((small_hist + 40))" ] \
    || fail "drain subshell entries grow with unread history: $small_hist for 3 routine lines per task, $large_hist for 60"

  build_routine_fleet "$dir/f-few/state" 3 3
  build_routine_fleet "$dir/f-many/state" 11 3
  few=$(subshell_entries "$dir/f-few/state" "$dir/f-few.count")
  many=$(subshell_entries "$dir/f-many/state" "$dir/f-many.count")
  per_task=$(( (many - few) / 8 ))
  [ "$per_task" -le 40 ] \
    || fail "drain subshell entries grow too fast with the fleet: $few for 3 tasks, $many for 11 ($per_task per added task, limit 40)"
  build_routine_fleet "$dir/f-many/state" 35 3
  FM_STATE_OVERRIDE="$dir/f-many/state" "$DRAIN" >/dev/null 2>/dev/null \
    || fail "the larger warm-fleet priming drain failed"
  [ "$(wc -l < "$dir/f-few/state/.status-presentation-cursor")" -eq 3 ] \
    || fail "the few-task priming drain did not populate its presentation manifest"
  [ "$(wc -l < "$dir/f-many/state/.status-presentation-cursor")" -eq 35 ] \
    || fail "the many-task priming drain did not populate its presentation manifest"
  warm_few=$(subshell_entries "$dir/f-few/state" "$dir/f-few-warm.count")
  warm_many=$(subshell_entries "$dir/f-many/state" "$dir/f-many-warm.count")
  warm_per_task=$(( (warm_many - warm_few) / 32 ))
  [ "$warm_per_task" -le 40 ] \
    || fail "drain subshell entries grow too fast with populated presentation manifests: $warm_few for 3 tasks, $warm_many for 35 ($warm_per_task per added task, limit 40)"
  pass "drain subshell entries stay flat as unread history grows and linear in cold/warm fleets ($per_task/$warm_per_task per task)"
}

# Reference the original command-substitution fold's byte contract, independently
# of the optimized fold/drop helpers. This is deliberately slow and test-only.
legacy_decision_fold_line() {
  local open=$1 line=$2 resolve=$3 held=$4 kind=$5 verb key note row kept=''
  verb=$(status_line_verb "$line")
  _fm_status_unstamped "$line" line
  case "$line" in *:*|*\[key=*\]*) ;; *) printf '%s' "$open"; return 0 ;; esac
  case "$line" in
    *:*) case "$verb:$kind" in
      done:ship|done:scout|failed:ship|failed:scout) return 0 ;;
    esac ;;
  esac
  case "$verb" in
    needs-decision|blocked|"$resolve"|"$held") ;;
    *) printf '%s' "$open"; return 0 ;;
  esac
  key=$(_fm_decision_key "$line") || { printf '%s' "$open"; return 0; }
  note=$(status_line_note "$line")
  _fm_decision_key_transition_allowed "$key" "$note" \
    || { printf '%s' "$open"; return 0; }
  while IFS= read -r row || [ -n "$row" ]; do
    [ -n "$row" ] || continue
    case "$row" in "$key"$'\t'*) ;; *) kept+="$row"$'\n' ;; esac
  done <<EOF
$open
EOF
  open=${kept%$'\n'}
  case "$verb" in
    needs-decision|blocked)
      [ -n "$open" ] && open+=$'\n'
      open+="$key"$'\t'"$verb"$'\t'"$note"
      ;;
  esac
  printf '%s' "$open"
}

test_decision_fold_preserves_stdout_and_out_var_bytes() {
  # shellcheck source=bin/fm-classify-lib.sh
  . "$ROOT/bin/fm-classify-lib.sh"
  local input=$'a\tneeds-decision\tfirst\nb\tblocked\tsecond\n\n' line kind expected actual open
  local lines=(
    'working: unchanged'
    'needs-decision bare prose [at=10:30]'
    'blocked [key=bad/key]: rejected key'
    'resolved [key=pending-reply-7]: unrelated note'
    'needs-decision [key=a] [at=2026-10-09T10:30:00Z]: reopened'
    'blocked [key=c]: third'
    $'blocked [key=c]: third\n\n'
    'done'
    'resolved [key=a]: answered'
    'captain-held [key=b]: transferred'
    'done: shipped'
    'failed: stopped'
  )
  for input in '' "$input"; do
    for kind in ship scout secondmate; do
      for line in "${lines[@]}"; do
        expected=$(legacy_decision_fold_line "$input" "$line" resolved captain-held "$kind")
        actual=$(_fm_decision_fold_line "$input" "$line" resolved captain-held "$kind") \
          || fail "stdout fold failed for $kind: $line"
        [ "$actual" = "$expected" ] || fail "stdout fold changed bytes for $kind: $line"
        open=$input
        _fm_decision_fold_line_into "$open" "$line" resolved captain-held "$kind" open
        [ "$open" = "$expected" ] || fail "out-var fold changed bytes for $kind: $line"
      done
    done
  done
  for input in '' $'a\tblocked\tfirst\nb\tneeds-decision\tsecond'; do
    for line in a missing; do
      actual=$(_fm_decision_drop "$input" "$line") || fail "stdout key removal failed"
      open=$input
      _fm_decision_drop "$open" "$line" open
      [ "$open" = "$actual" ] || fail "key removal out-var and stdout bytes differ"
      case "$line" in
        missing) [ "$open" = "$input" ] || fail "absent key removal changed the set" ;;
        a) [ "$open" = "${input#*$'\n'}" ] || fail "key removal changed surviving record" ;;
      esac
    done
  done
  pass "stdout and in-process decision folds preserve legacy bytes and early returns"
}

test_keyed_cold_drain_preserves_cursor_bytes_and_flat_forks() {
  # shellcheck source=bin/fm-classify-lib.sh
  . "$ROOT/bin/fm-classify-lib.sh"
  local dir state history task i line open expected actual ident size signature small large
  dir=$(make_case keyed-cold-fold)
  for history in 3 60; do
    state="$dir/h$history/state"
    mkdir -p "$state"
    for ((task = 0; task < 3; task++)); do
      {
        printf '%s\n' 'needs-decision [key=keep]: initial' 'blocked [key=remove]: temporary'
        for ((i = 0; i < history; i++)); do
          printf 'resolved [key=side-%s]: routine close\nworking: step %s\n' "$i" "$i"
        done
        printf '%s\n' \
          'captain-held [key=remove]: transferred' \
          'needs-decision [key=pending-reply-7]: pending-reply-missed: still waiting' \
          'resolved [key=pending-reply-7]: unrelated note cannot close' \
          'blocked [key=last]: final blocker' \
          'needs-decision [key=keep] [at=2026-10-09T10:30:00Z]: reopened'
        case "$task" in 1) printf 'done: shipped\n' ;; esac
      } > "$state/fleet$task.status"
      printf 'kind=ship\n' > "$state/fleet$task.meta"
    done
    actual=$(subshell_entries "$state" "$dir/h$history.count")
    case "$history" in 3) small=$actual ;; 60) large=$actual ;; esac
    for ((task = 0; task < 3; task++)); do
      open=''
      while IFS= read -r line || [ -n "$line" ]; do
        open=$(legacy_decision_fold_line "$open" "$line" resolved captain-held ship)
      done < "$state/fleet$task.status"
      expected=$'pending-reply-7\tneeds-decision\tpending-reply-missed: still waiting\nlast\tblocked\tfinal blocker\nkeep\tneeds-decision\treopened'
      case "$task" in 1) expected='' ;; esac
      [ "$open" = "$expected" ] || fail "legacy fold did not retain the expected order and notes"
      _fm_status_stat_into "$state/fleet$task.status" ident size \
        || fail "could not read fixture identity and size"
      _fm_open_decisions_fold_signature ship signature
      {
        printf 'version=%s\noffset=%s\nident=%s\n' "$signature" "$size" "$ident"
        printf '%s' "$open"
      } > "$dir/expected.cursor"
      cmp -s "$dir/expected.cursor" "$state/.fleet$task.open-decisions-cursor" \
        || fail "drain persisted different cursor bytes, including trailing newlines"
      actual=$(status_open_decisions_incremental "$state/fleet$task.status")
      [ "$actual" = "$open" ] || fail "keyed cold drain changed the legacy open set"
    done
  done
  [ "$large" -le "$((small + 40))" ] \
    || fail "keyed cold-fold subshell entries grew with history: $small to $large"
  pass "keyed cold drains preserve exact open/cursor bytes with flat forks ($small/$large)"
}

test_incident_note_answer_buried_under_routine_note_surfaces_both
test_already_presented_notes_are_not_replayed
test_brand_new_note_after_presentation_is_surfaced
test_signal_annotation_surfaces_every_unread_note_not_only_the_newest
test_pending_reply_resolution_surfaces_once
test_self_announced_pending_reply_close_still_surfaces
test_unread_output_over_cap_remains_recoverable
test_snapshot_does_not_ack_a_later_append
test_retired_task_id_starts_new_status_unread
test_weak_identity_still_presents_and_advances
test_snapshot_failure_is_visible
test_manifest_read_failure_does_not_replay_or_replace_receipts
test_manifest_reader_preserves_complete_bytes
test_open_decisions_fold_is_unchanged
test_empty_queue_does_not_swallow_later_signal_annotation
test_routine_working_and_covered_done_stay_silent_on_the_empty_queue
test_drain_subshell_entries_stay_flat_as_history_and_fleet_grow
test_decision_fold_preserves_stdout_and_out_var_bytes
test_keyed_cold_drain_preserves_cursor_bytes_and_flat_forks
