#!/usr/bin/env bash
# fm-send answerer-closes (--resolve-key) behavior.
#
# A captain decision opened by a keyed needs-decision:/blocked: status line
# historically stayed open forever when the answer kicked off work: the worker's
# next line is working [key=<workstream>], never resolved [key=<decision>].
# fm-send's --resolve-key removes that writer-dependency at its source: the
# ANSWERING firstmate closes the decision in this home's own ledger at answer
# time - for a local target that is ENQUEUE time, because the durable inbox
# write is delivery to the task's record. These tests drive the real fm-send
# executable over stubbed transports and assert closure through the real
# consumer (fm-wake-drain.sh's OPEN DECISIONS section), never through source
# text:
#   1. An answer send closes the open decision, including the answer-starts-work
#      scenario where the worker never writes a matching resolved line.
#   2. A routine steer without the flag never closes anything, and a working:
#      line still cannot clear a captain decision.
#   3. A key that is not open refuses BEFORE anything is sent (mistype safety).
#   4. The close happens at enqueue: a failed doorbell ring still closes the
#      answered key (the record is durably sent), while a failed ENQUEUE - the
#      real local failure - closes nothing and leaves the decision open.
#   5. A local secondmate answer is marked+corr'd in its record yet closes the
#      same way, and the closing line carries the plain answer, not marker or
#      corr bytes.
#   6. A remote secondmate answer differs only at the transport layer: the
#      message crosses the stubbed ssh transport while the close is the same
#      local ledger append; a failed transport closes nothing.
#   7. Flag misuse (--key, empty message, explicit backend target) refuses.
#   8. A reserved pending-reply-* decision actually closes through --resolve-key
#      (the operator path the OPEN DECISIONS hint names), while an unrelated
#      writer's answered: note still cannot hijack or clear that key. A reserved
#      key this send cannot close refuses before anything is sent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-marker-lib.sh"

SEND="$ROOT/bin/fm-send.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-resolve-key)

# Stub tmux: logs literal typed text to FM_SEND_LOG and lets the submit path
# reach a clean "empty" verdict (numeric cursor_y, empty bordered composer).
# FM_FAKE_TMUX_SEND_FAIL=1 makes send-keys fail so the delivery-failure leg can
# assert that a failed send closes nothing.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    [ "${FM_FAKE_TMUX_SEND_FAIL:-0}" = 1 ] && exit 1
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows)
    printf '%s\n' fm-t1 fm-t2 fm-t3 fm-t4 fm-t5 fm-t6 fm-t7 fm-t8 fm-t9 fm-mate elsewhere
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  # Stub ssh transport for the remote-secondmate legs, selected via FM_SSH_BIN.
  # Records the full remote invocation and exits FM_FAKE_SSH_RC (default 0).
  cat > "$fb/fake-ssh" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' "$*" >> "$FM_SSH_LOG"
exit "${FM_FAKE_SSH_RC:-0}"
SH
  chmod +x "$fb/fake-ssh"
  printf '%s\n' "$fb"
}

# run_send <fakebin> <home> <send-log> <fm-send args...>: run the real fm-send
# with the stubs on PATH against the given home. Guard noise goes to stderr,
# captured per test when the diagnostic matters.
run_send() {
  local fb=$1 home=$2 log=$3; shift 3
  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" "$@" 2>/dev/null
}

setup_home() {  # <name> -> echoes a fresh home dir with an empty state/
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

drain_out() {  # <home>
  FM_STATE_OVERRIDE="$1/state" "$DRAIN" 2>/dev/null
}

test_answer_send_closes_open_decision() {
  local dir fb log home rc out
  dir="$TMP_ROOT/closes"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home closes)
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$home/state/t1.status"
  printf 'working: kept busy on an unrelated stream\n' >> "$home/state/t1.status"

  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=api-shape]' >/dev/null \
    || fail "precondition: the buried decision should list as open before the answer"

  run_send "$fb" "$home" "$log" t1 --resolve-key api-shape "go with REST"; rc=$?
  expect_code 0 "$rc" "an answer send with --resolve-key should succeed"
  grep -qF "go with REST" "$home/state/t1.inbox/001.msg" \
    || fail "the answer text should reach the worker's durable inbox record"
  assert_contains "$(cat "$log")" "Firstmate instruction waiting" "the doorbell should be rung for the answer"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/t1.status" | grep -qF 'resolved [key=api-shape]: answered: go with REST' \
    || fail "fm-send did not append the closing resolved line:"$'\n'"$(cat "$home/state/t1.status")"
  # The drain folded the worker's `working:` line but never listed it, so the
  # close must leave the file for the watcher instead of marking it seen.
  if FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/t1.status"; then
    fail "the answerer's close hid a worker line the drain never listed"
  fi

  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered decision still lists as open: $out"
  fi
  pass "fm-send --resolve-key: the answer send itself closes the open decision"
}

# The answerer's close is this home's own bookkeeping: it must not re-wake the
# session that wrote it, while any other writer's later line on the same task
# still must. Both directions are read through the production seen-signature
# gate the watcher's signal scan consumes (bin/fm-wake-lib.sh).
test_answer_close_is_self_announced() {
  local dir fb log home rc
  dir="$TMP_ROOT/self-announced"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home self-announced)
  fm_write_meta "$home/state/t9.meta" "window=sess:fm-t9" "kind=ship"
  printf 'needs-decision [key=port-choice]: 8080 or 9090\n' > "$home/state/t9.status"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/t9.status" \
    || fail "could not prime the announced baseline"

  run_send "$fb" "$home" "$log" t9 --resolve-key port-choice "use 9090"; rc=$?
  expect_code 0 "$rc" "the answer send should succeed"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/t9.status" | grep -qF 'resolved [key=port-choice]: answered: use 9090' \
    || fail "the closing resolved line is missing"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/t9.status" \
    || fail "the answerer's own close was left to re-wake this same home"

  printf 'done: worker finished after the answer\n' >> "$home/state/t9.status"
  if FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/t9.status"; then
    fail "a later worker line after the self-announced close was swallowed"
  fi
  pass "fm-send --resolve-key: the close never re-wakes its own home, later lines still do"
}

# Two distinct --resolve-key answers must each stay quiet even when the seen
# marker does NOT cover them. An in-flight watcher classification that lands
# after the first answer regresses the classified offset behind that answer's
# bytes, so the marker no longer vouches for them; only the home-appends ledger
# does. Without the ledger the second scan re-wakes this home over its own
# close. A later worker line on the same task still wakes.
test_separate_resolve_key_answers_do_not_rewake() {
  local dir fb log home rc status pre_answer ident
  dir="$TMP_ROOT/separate-answers"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home separate-answers)
  status="$home/state/t7.status"
  fm_write_meta "$home/state/t7.meta" "window=sess:fm-t7" "kind=ship"
  {
    printf 'needs-decision [key=budget]: approve spend?\n'
    printf 'needs-decision [key=vendor]: pick a vendor\n'
  } > "$status"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$status" \
    || fail "could not prime the announced baseline"
  pre_answer=$(wc -c < "$status" | tr -d '[:space:]')

  run_send "$fb" "$home" "$log" t7 --resolve-key budget "approved"; rc=$?
  expect_code 0 "$rc" "the first answer should succeed"

  # A watcher classification captured before the answer commits afterwards and
  # rewinds the classified offset behind the answer's bytes.
  ident=$(FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; _fm_open_decisions_file_ident "$2"
  ' _ "$ROOT/bin/fm-classify-lib.sh" "$status") \
    || fail "could not read the status identity"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_status_seen_commit "$2" "$3" "$4" "$5"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$status" "$pre_answer" "$ident" \
    || fail "could not replay the stale watcher classification"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$status" \
    || fail "the first --resolve-key answer was left to re-wake this home"

  run_send "$fb" "$home" "$log" t7 --resolve-key vendor "acme"; rc=$?
  expect_code 0 "$rc" "the second answer should succeed"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$status" \
    || fail "the second --resolve-key answer was left to re-wake this home"

  printf 'blocked: need staging credentials\n' >> "$status"
  if FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$status"; then
    fail "a later worker line after two answers was swallowed"
  fi
  pass "fm-send --resolve-key: separate answers do not each re-wake; later lines still do"
}

# The reported failure behind issue #2109: a worker that put the colon first
# (needs-decision: [key=X] ...) had its key silently folded to "default", so
# the answer's --resolve-key X refused with "no open decision or blocker with
# that key". The stated key must be honored in that position too, end to end
# through the real send.
test_colon_first_key_position_is_answerable() {
  local dir fb log home rc out
  dir="$TMP_ROOT/colon-first"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home colon-first)
  fm_write_meta "$home/state/t8.meta" "window=sess:fm-t8" "kind=ship"
  printf 'needs-decision: [key=seam-max-bound] cap the seam at 4 or 8\n' > "$home/state/t8.status"

  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=seam-max-bound]' >/dev/null \
    || fail "precondition: the colon-first decision should list as open under its stated key: $out"

  run_send "$fb" "$home" "$log" t8 --resolve-key seam-max-bound "cap it at 4"; rc=$?
  expect_code 0 "$rc" "answering a colon-first stated key should succeed, not refuse as unknown"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/t8.status" | grep -qF 'resolved [key=seam-max-bound]: answered: cap it at 4' \
    || fail "the closing resolved line is missing:"$'\n'"$(cat "$home/state/t8.status")"

  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered colon-first decision still lists as open: $out"
  fi
  pass "fm-send --resolve-key: a colon-first stated key is open under that key and answerable"
}

test_answer_starts_work_never_orphans() {
  local dir fb log home rc out
  dir="$TMP_ROOT/starts-work"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home starts-work)
  fm_write_meta "$home/state/t2.meta" "window=sess:fm-t2" "kind=ship"
  printf 'needs-decision [key=rollout]: big-bang or phased\n' > "$home/state/t2.status"

  run_send "$fb" "$home" "$log" t2 --resolve-key rollout "phased, gate each region"; rc=$?
  expect_code 0 "$rc" "the rollout answer send should succeed"
  # The forensic scenario: the answer starts a workstream, so the worker's next
  # events use a DIFFERENT key namespace and it never writes
  # resolved [key=rollout] itself.
  printf 'working [key=phased-impl]: building region gates\n' >> "$home/state/t2.status"
  printf 'done [key=phased-impl]: PR up\n' >> "$home/state/t2.status"

  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered decision orphaned after the answer started work: $out"
  fi
  pass "fm-send --resolve-key: an answer that starts a workstream leaves no orphaned decision"
}

test_routine_steer_never_closes() {
  local dir fb log home rc out
  dir="$TMP_ROOT/routine"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home routine)
  fm_write_meta "$home/state/t3.meta" "window=sess:fm-t3" "kind=ship"
  printf 'needs-decision [key=schema]: split or embed\n' > "$home/state/t3.status"

  run_send "$fb" "$home" "$log" t3 --answers-none "unrelated nudge, keep going"; rc=$?
  expect_code 0 "$rc" "a routine steer should still succeed"
  printf 'working: resumed\n' >> "$home/state/t3.status"

  if grep -F 'resolved' "$home/state/t3.status" >/dev/null; then
    fail "a routine steer wrote a resolved line: $(cat "$home/state/t3.status")"
  fi
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=schema]' >/dev/null \
    || fail "a routine steer or later working line cleared an unanswered captain decision: $out"
  printf 'done: task complete\nnote: cleanup complete\n' >> "$home/state/t3.status"
  run_send "$fb" "$home" "$log" t3 --resolve-key schema "answer to a stale decision" > "$dir/terminal.out" 2> "$dir/terminal.err"; rc=$?
  expect_code 1 "$rc" "an answer to a terminally superseded decision must refuse"
  [ ! -e "$home/state/t3.inbox/002.msg" ] || fail "a stale decision answer was delivered"
  pass "fm-send preserves decisions through routine work and refuses superseded terminal decisions"
}

test_not_open_key_refuses_before_send() {
  local dir fb log home err rc out
  dir="$TMP_ROOT/not-open"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home not-open)
  fm_write_meta "$home/state/t4.meta" "window=sess:fm-t4" "kind=ship"
  printf 'needs-decision [key=real-key]: choose\n' > "$home/state/t4.status"

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t4 --resolve-key mistyped "the answer" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a not-open key should refuse"
  assert_contains "$(cat "$err")" "--resolve-key 'mistyped'" "the refusal should name the bad key"
  assert_contains "$(cat "$err")" "nothing was sent" "the refusal should state nothing was sent"
  [ ! -s "$log" ] || fail "a refused answer still typed text: $(cat "$log")"
  [ ! -d "$home/state/t4.inbox" ] || fail "a refused answer still enqueued an inbox record"
  if grep -F 'resolved' "$home/state/t4.status" >/dev/null; then
    fail "a refused answer still closed something: $(cat "$home/state/t4.status")"
  fi
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=real-key]' >/dev/null \
    || fail "the real decision disappeared after a refused answer: $out"
  pass "fm-send --resolve-key: a key that is not open refuses loudly before anything is sent"
}

# A status log the read limits refuse (bin/fm-status-cap-lib.sh) is not a log with no
# open decision: --resolve-key must say it cannot tell, not that the key is already
# closed or mistyped, and must send nothing.
test_log_past_the_read_limits_is_unknown_not_already_closed() {
  local dir fb log home err rc
  dir="$TMP_ROOT/refused-log"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home refused-log)
  fm_write_meta "$home/state/t5.meta" "window=sess:fm-t5" "kind=ship"
  { printf 'needs-decision [key=real-key]: choose\n'; perl -e 'print "text\n" x 40000'; } > "$home/state/t5.status"

  : > "$log"
  env PATH="$fb:$PATH" FM_STATUS_CAP_BYTES=4000 FM_STATUS_CAP_RESERVE_BYTES=1000 \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t5 --resolve-key real-key "the answer" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a send whose decision ledger cannot be read should refuse"
  assert_contains "$(cat "$err")" "cannot tell which decisions are open" "the refusal should say the open set is unknown"
  assert_not_contains "$(cat "$err")" "already closed" "an unreadable log was reported as a closed decision"
  assert_contains "$(cat "$err")" "nothing was sent" "the refusal should state nothing was sent"
  [ ! -s "$log" ] || fail "a refused answer still typed text: $(cat "$log")"
  [ ! -d "$home/state/t5.inbox" ] || fail "a refused answer still enqueued an inbox record"
  pass "fm-send --resolve-key: a log past the read limits is unknown, never already closed, and nothing is sent"
}

# The close is an enqueue-time fact: the durable record IS the delivery, so a
# failed doorbell keystroke must not reopen the split-brain where the close
# waited on an unconfirmable submit.
test_failed_ring_still_closes_at_enqueue() {
  local dir fb log home rc out
  dir="$TMP_ROOT/ring-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home ring-fail)
  fm_write_meta "$home/state/t5.meta" "window=sess:fm-t5" "kind=ship"
  printf 'blocked [key=creds]: need the deploy token\n' > "$home/state/t5.status"

  : > "$log"
  env PATH="$fb:$PATH" FM_FAKE_TMUX_SEND_FAIL=1 \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t5 --resolve-key creds "token is in the vault now" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "a failed doorbell must not fail the durably enqueued answer"
  grep -qF 'token is in the vault now' "$home/state/t5.inbox/001.msg" \
    || fail "the answer must be durably recorded despite the failed ring"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/t5.status" | grep -qF 'resolved [key=creds]: answered: token is in the vault now' \
    || fail "the enqueued answer must close the decision at answer time: $(cat "$home/state/t5.status")"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F '[key=creds]' >/dev/null; then
    fail "the answered blocker still lists as open after an enqueue-time close: $out"
  fi
  pass "fm-send --resolve-key: the close happens at enqueue, surviving a failed doorbell"
}

# The real local failure - an unwritable record - is the case that must never
# close anything: nothing durable was sent.
test_failed_enqueue_does_not_close() {
  local dir fb log home rc out
  dir="$TMP_ROOT/enqueue-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home enqueue-fail)
  fm_write_meta "$home/state/t5.meta" "window=sess:fm-t5" "kind=ship"
  printf 'blocked [key=creds]: need the deploy token\n' > "$home/state/t5.status"
  : > "$home/state/t5.inbox"   # a FILE where the inbox dir must go

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t5 --resolve-key creds "token is in the vault now" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "a failed enqueue should exit nonzero"
  if grep -F 'resolved' "$home/state/t5.status" >/dev/null; then
    fail "a failed enqueue still closed the decision: $(cat "$home/state/t5.status")"
  fi
  [ ! -s "$log" ] || fail "a failed enqueue still typed something: $(cat "$log")"
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=creds]' >/dev/null \
    || fail "the blocker vanished after a failed enqueue: $out"
  pass "fm-send --resolve-key: a failed enqueue never closes the decision"
}

test_multiple_keys_close_together() {
  local dir fb log home rc out
  dir="$TMP_ROOT/multi"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home multi)
  fm_write_meta "$home/state/t6.meta" "window=sess:fm-t6" "kind=ship"
  {
    printf 'needs-decision [key=k1]: first\n'
    printf 'blocked [key=k2]: second\n'
    printf 'needs-decision [key=k3]: third, unanswered\n'
  } > "$home/state/t6.status"

  run_send "$fb" "$home" "$log" t6 --resolve-key k1 --resolve-key k2 \
    "one answer covering both"; rc=$?
  expect_code 0 "$rc" "an answer resolving two keys should succeed"
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=k3]' >/dev/null \
    || fail "the unanswered third decision must stay open: $out"
  if printf '%s' "$out" | grep -E '\[key=k1\]|\[key=k2\]' >/dev/null; then
    fail "an answered key is still open after a multi-key answer: $out"
  fi
  pass "fm-send --resolve-key: one answer closes each named key and only those"
}

# Issue 4767: the session-start drain listed both decisions (folding them
# without a watcher seen marker), and one answer closes both. The closes are
# this home's own bookkeeping, so the watcher must not wake it to reread them.
test_multiple_keys_close_after_fold_is_self_announced() {
  local dir fb log home rc out
  dir="$TMP_ROOT/multi-fold"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home multi-fold)
  fm_write_meta "$home/state/t7.meta" "window=sess:fm-t7" "kind=ship"
  {
    printf 'needs-decision [key=budget]: approve spend?\n'
    printf 'needs-decision [key=vendor]: pick a vendor\n'
  } > "$home/state/t7.status"
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=vendor]' >/dev/null \
    || fail "precondition: the drain should list both decisions: $out"

  run_send "$fb" "$home" "$log" t7 --resolve-key budget --resolve-key vendor \
    "approve spend, pick acme"; rc=$?
  expect_code 0 "$rc" "an answer resolving two folded keys should succeed"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/t7.status" \
    || fail "one answer's two closes after an OPEN DECISIONS drain were left to re-wake this home"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "an answered folded key is still open: $out"
  fi
  pass "fm-send --resolve-key: one answer's closes after a drain fold never wake this home"
}

test_local_secondmate_answer_marked_and_closed() {
  local dir fb log home rc got out closing
  dir="$TMP_ROOT/sm"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home sm)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  printf 'needs-decision [key=fleet-split]: shard by team or by repo\n' > "$home/state/domain.status"

  run_send "$fb" "$home" "$log" fm-domain --resolve-key fleet-split "shard by team"; rc=$?
  expect_code 0 "$rc" "a secondmate answer send should succeed"
  got=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" \
    "$home/state/domain.inbox/001.msg")
  case "$got" in
    "$FM_FROMFIRST_MARK"corr=*) : ;;
    *) fail "the secondmate answer's record lost its from-firstmate marker/corr framing: $got" ;;
  esac
  closing=$(grep -F 'resolved [key=fleet-split]' "$home/state/domain.status" || true)
  [ -n "$closing" ] || fail "the secondmate decision was not closed: $(cat "$home/state/domain.status")"
  case "$closing" in
    *corr=*) fail "the closing line leaked the corr token: $closing" ;;
  esac
  case "$closing" in
    *"$FM_FROMFIRST_SEPARATOR"*) fail "the closing line leaked marker bytes" ;;
  esac
  assert_contains "$closing" "shard by team" "the closing line should carry the plain answer"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered secondmate decision still lists as open: $out"
  fi
  pass "fm-send --resolve-key: a marked local-secondmate answer closes with the plain answer text"
}

# Remote secondmate: the answer crosses the (stubbed) ssh transport through the
# real fm-on.sh + registry route, while the close is the SAME local ledger
# append as every other target kind - the transport is the only difference.
setup_remote_home() {  # <name> -> echoes home dir with remote meta + registry
  local home
  home=$(setup_home "$1")
  mkdir -p "$home/data"
  fm_write_meta "$home/state/rsm.meta" \
    "window=fm-remote:w1:p1" \
    "endpoint_task_id=rsm" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "remote_host=remote-mac" \
    "remote_root=/remote/root" \
    "remote_backend=herdr" \
    "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:w1:p1"
  cat > "$home/data/secondmates.md" <<EOF
- rsm - remote test domain (host: remote-mac; root: /remote/root; home: /remote/home; scope: remote testing; projects: alpha; added 2026-08-02)
EOF
  printf '%s\n' "$home"
}

test_remote_secondmate_answer_closes_locally() {
  local dir fb log home ssh_log rc out
  dir="$TMP_ROOT/remote-ok"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; ssh_log="$dir/ssh.log"; : > "$ssh_log"
  home=$(setup_remote_home remote-ok)
  printf 'needs-decision [key=upgrade-window]: tonight or the weekend\n' > "$home/state/rsm.status"

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SSH_BIN="$fb/fake-ssh" FM_SSH_LOG="$ssh_log" FM_FAKE_SSH_RC=0 \
    "$SEND" rsm --resolve-key upgrade-window "the weekend, freeze Friday" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "a remote secondmate answer send should succeed"
  assert_grep 'fm-remote-entrypoint.sh' "$ssh_log" \
    "the answer message should cross the remote transport"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/rsm.status" | grep -qF 'resolved [key=upgrade-window]: answered: the weekend, freeze Friday' \
    || fail "the remote answer did not close the local ledger: $(cat "$home/state/rsm.status")"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered remote-secondmate decision still lists as open: $out"
  fi
  pass "fm-send --resolve-key: a remote-secondmate answer closes the same local ledger, transport-only difference"
}

# The reported failure: a remote secondmate reply line prepends a
# "[corr=<hex>]" correlation tag ahead of "[key=...]"
# (needs-decision [corr=d448ea86afa4bf67] [key=x]: ...). The verb parser used
# to strip only a leading "[key=...]" token, so the corr tag stayed glued onto
# the returned verb and the fold never recognized the line as a decision at
# all - "--resolve-key x" refused with "no open decision with that key" even
# though the key was right there on the line. This drives the real fm-send
# over that exact line shape and asserts the answer now succeeds and closes it.
test_remote_reply_corr_tag_does_not_block_resolve_key() {
  local dir fb log home ssh_log rc out
  dir="$TMP_ROOT/remote-corr-tag"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; ssh_log="$dir/ssh.log"; : > "$ssh_log"
  home=$(setup_remote_home remote-corr-tag)
  printf 'needs-decision [corr=d448ea86afa4bf67] [key=loan-installment-cadence-amount]: pick the cadence\n' \
    > "$home/state/rsm.status"

  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=loan-installment-cadence-amount]' >/dev/null \
    || fail "precondition: the corr-tagged remote decision should list as open under its stated key: $out"

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SSH_BIN="$fb/fake-ssh" FM_SSH_LOG="$ssh_log" FM_FAKE_SSH_RC=0 \
    "$SEND" rsm --resolve-key loan-installment-cadence-amount "monthly" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "answering a corr-tagged remote decision should succeed, not refuse as unknown"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/rsm.status" | grep -qF 'resolved [key=loan-installment-cadence-amount]: answered: monthly' \
    || fail "the closing resolved line is missing:"$'\n'"$(cat "$home/state/rsm.status")"

  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered corr-tagged remote decision still lists as open: $out"
  fi
  pass "fm-send --resolve-key: a remote reply's leading [corr=...] tag no longer blocks closing its stated key"
}

test_remote_transport_failure_does_not_close() {
  local dir fb log home ssh_log rc out
  dir="$TMP_ROOT/remote-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; ssh_log="$dir/ssh.log"; : > "$ssh_log"
  home=$(setup_remote_home remote-fail)
  printf 'blocked [key=quota]: remote host is out of runway\n' > "$home/state/rsm.status"

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SSH_BIN="$fb/fake-ssh" FM_SSH_LOG="$ssh_log" FM_FAKE_SSH_RC=1 \
    "$SEND" rsm --resolve-key quota "quota refreshed, resume" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "a failed remote transport should exit nonzero"
  if grep -F 'resolved' "$home/state/rsm.status" >/dev/null; then
    fail "a failed remote send still closed the decision: $(cat "$home/state/rsm.status")"
  fi
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=quota]' >/dev/null \
    || fail "the remote blocker vanished after a failed transport: $out"
  pass "fm-send --resolve-key: a failed remote transport never closes the decision"
}

test_flag_misuse_refuses() {
  local dir fb log home err rc
  dir="$TMP_ROOT/misuse"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home misuse)
  fm_write_meta "$home/state/t7.meta" "window=sess:fm-t7" "kind=ship"
  printf 'needs-decision [key=k]: choose\n' > "$home/state/t7.status"

  # --resolve-key with --key (both orders) is refused: an answer is text.
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t7 --resolve-key k --key Enter >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "--resolve-key before --key should refuse"
  assert_contains "$(cat "$err")" "cannot accompany --key" "the --key refusal should be explicit"
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t7 --key Enter --resolve-key k >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "--resolve-key after --key should refuse instead of being silently dropped"
  assert_contains "$(cat "$err")" "cannot accompany --key" "the trailing --resolve-key refusal should be explicit"

  # An empty answer message is refused.
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t7 --resolve-key k >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an empty answer message should refuse"
  assert_contains "$(cat "$err")" "nonempty answer message" "the empty-message refusal should be explicit"

  # An explicit backend target has no task ledger in this home.
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:elsewhere --resolve-key k "answer" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an explicit backend target should refuse --resolve-key"
  assert_contains "$(cat "$err")" "no decision ledger" "the explicit-target refusal should be explicit"

  # A malformed key is refused before anything else.
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t7 --resolve-key 'bad key!' "answer" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a malformed key should refuse"
  assert_contains "$(cat "$err")" "not a valid decision key" "the malformed-key refusal should be explicit"

  [ ! -s "$log" ] || fail "a refused misuse still typed text: $(cat "$log")"
  if grep -F 'resolved' "$home/state/t7.status" >/dev/null; then
    fail "a refused misuse still closed something: $(cat "$home/state/t7.status")"
  fi
  pass "fm-send --resolve-key: --key, empty message, explicit targets, and malformed keys refuse loudly"
}

# The reported silent no-op: fm-send --resolve-key on a reserved pending-reply-*
# key used to write "answered: ..." and exit 0 while the classify fold left the
# decision open. The operator path must actually close it, using the owning
# library's vocabulary, without weakening the guard against an unrelated writer.
test_reserved_pending_reply_key_closes_through_resolve_key() {
  local dir fb log home rc out key corr
  dir="$TMP_ROOT/reserved-close"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home reserved-close)
  corr=abcdef0123456789
  key="pending-reply-$corr"
  fm_write_meta "$home/state/mate.meta" "window=sess:fm-mate" "kind=ship"
  printf 'blocked [key=%s]: pending-reply-missed: task=mate pending-reply-id=%s request=ship it\n' \
    "$key" "$corr" > "$home/state/mate.status"

  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F "[key=$key]" >/dev/null \
    || fail "precondition: the reserved pending-reply decision should list as open: $out"

  run_send "$fb" "$home" "$log" mate --resolve-key "$key" "ack, false escalation"; rc=$?
  expect_code 0 "$rc" "closing a reserved pending-reply key via --resolve-key should succeed"
  grep -F "pending-reply-resolved: task=mate pending-reply-id=$corr via=operator-resolve-key" \
    "$home/state/mate.status" >/dev/null \
    || fail "the operator close did not write the owning library's close note:"$'\n'"$(cat "$home/state/mate.status")"
  if grep -E "resolved \[key=$key\]( \[at=[0-9]+\])?: answered:" "$home/state/mate.status" >/dev/null; then
    fail "the operator close still wrote a bare answered: note that the fold ignores:"$'\n'"$(cat "$home/state/mate.status")"
  fi

  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the reserved pending-reply decision still lists as open after --resolve-key: $out"
  fi
  pass "fm-send --resolve-key: a reserved pending-reply key actually closes through the operator path"
}

test_unrelated_writer_cannot_close_or_hijack_reserved_key() {
  local dir fb log home rc out key corr
  dir="$TMP_ROOT/reserved-guard"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home reserved-guard)
  corr=abcdef0123456789
  key="pending-reply-$corr"
  fm_write_meta "$home/state/mate.meta" "window=sess:fm-mate" "kind=ship"
  {
    printf 'blocked [key=%s]: pending-reply-missed: task=mate pending-reply-id=%s request=ship it\n' \
      "$key" "$corr"
    printf 'blocked [key=%s]: shipping is blocked on infra\n' "$key"
    printf 'resolved [key=%s]: answered: operator thought this would close it\n' "$key"
    printf 'resolved [key=%s]: all good now\n' "$key"
  } > "$home/state/mate.status"

  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F "pending-reply-id=$corr" >/dev/null \
    || fail "an unrelated answered: resolution cleared a reserved decision: $out"
  if printf '%s' "$out" | grep -F 'shipping is blocked on infra' >/dev/null; then
    fail "an unrelated writer took over a reserved decision key: $out"
  fi

  run_send "$fb" "$home" "$log" mate --resolve-key "$key" "dismiss the missed-reply hold"; rc=$?
  expect_code 0 "$rc" "the operator close should still succeed after foreign no-op lines"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the reserved key stayed open after the operator close: $out"
  fi
  pass "fm-send --resolve-key: an unrelated writer cannot close or hijack a reserved key, and the operator close still can"
}

test_unclosable_reserved_key_refuses_before_send() {
  local dir fb log home err rc out
  dir="$TMP_ROOT/reserved-refuse"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home reserved-refuse)
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship"
  printf 'blocked [key=secret-abc]: secret-held: keep this\n' > "$home/state/t1.status"

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_CLASSIFY_RESERVED_KEY_PREFIXES='pending-reply- secret-' \
    "$SEND" t1 --resolve-key secret-abc "this must not silently no-op" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a reserved key this send cannot close should refuse"
  assert_contains "$(cat "$err")" "--resolve-key 'secret-abc'" "the refusal should name the reserved key"
  assert_contains "$(cat "$err")" "cannot take effect" "the refusal should say the close cannot take effect"
  assert_contains "$(cat "$err")" "nothing was sent" "the refusal should state nothing was sent"
  [ ! -s "$log" ] || fail "a refused reserved-key close still typed text: $(cat "$log")"
  [ ! -d "$home/state/t1.inbox" ] || fail "a refused reserved-key close still enqueued an inbox record"
  if grep -F 'resolved' "$home/state/t1.status" >/dev/null; then
    fail "a refused reserved-key close still wrote a resolved line: $(cat "$home/state/t1.status")"
  fi
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=secret-abc]' >/dev/null \
    || fail "the reserved decision disappeared after a refused close: $out"
  pass "fm-send --resolve-key: a reserved key this send cannot close refuses loudly before anything is sent"
}

test_long_decision_key_refuses_before_send() {
  local dir fb log home err key rc out
  dir="$TMP_ROOT/long-key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home long-key)
  key=$(printf 'k%.0s' {1..230})
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship"
  printf 'needs-decision [key=%s]: choose safely\n' "$key" > "$home/state/t1.status"

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t1 --resolve-key "$key" "answer the long-key decision" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a key whose close prefix cannot fit should refuse before sending"
  assert_contains "$(cat "$err")" "decision key of length 230" "the refusal should report the key-length cause"
  assert_contains "$(cat "$err")" "220-character status-line cap" "the refusal should report the truncation limit"
  assert_contains "$(cat "$err")" "nothing was sent" "the refusal should state nothing was sent"
  [ ! -s "$log" ] || fail "a refused long-key close still typed text: $(cat "$log")"
  [ ! -d "$home/state/t1.inbox" ] || fail "a refused long-key close still enqueued an inbox record"
  if grep -F 'resolved' "$home/state/t1.status" >/dev/null; then
    fail "a refused long-key close still wrote a malformed resolution: $(cat "$home/state/t1.status")"
  fi
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null \
    || fail "the long-key decision disappeared after a refused close: $out"
  pass "fm-send --resolve-key: an overlong decision key refuses before sending"
}

# The cap bounds the line that is actually APPENDED. The self-announced append
# stamps each close with its emission time, so a cap measured before the stamp
# lets the stored line overrun it and every 220-capped rendering downstream
# silently loses that much real note text.
test_stamped_close_line_stays_within_the_status_line_cap() {
  local dir fb log home rc answer line
  dir="$TMP_ROOT/cap-with-stamp"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home cap-with-stamp)
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship"
  printf 'needs-decision [key=api-shape]: REST or gRPC\n' > "$home/state/t1.status"
  answer=$(printf 'x%.0s' {1..400})

  run_send "$fb" "$home" "$log" t1 --resolve-key api-shape "$answer"; rc=$?
  expect_code 0 "$rc" "answering with an over-long note should succeed, not refuse"
  line=$(grep -F 'resolved [key=api-shape]' "$home/state/t1.status") \
    || fail "the closing resolved line is missing:"$'\n'"$(cat "$home/state/t1.status")"
  case "$line" in
    *' [at='*']: '*) : ;;
    *) fail "the appended close carries no emission stamp: $line" ;;
  esac
  [ "${#line}" -le 220 ] \
    || fail "the appended close is ${#line} characters, past the 220-character cap: $line"
  pass "fm-send --resolve-key: a stamped close line stays inside the status-line cap"
}

test_failed_close_recovery_command_is_shell_safe() {
  local dir fb log home err marker answer rc diagnostic manual out
  dir="$TMP_ROOT/manual-close"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home "manual close")
  marker="$dir/injected"
  answer="ok'; touch $marker; echo '"
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship"
  printf 'needs-decision [key=quote-safety]: choose safely\n' > "$home/state/t1.status"
  chmod 0400 "$home/state/t1.status"

  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t1 --resolve-key quote-safety "$answer" >/dev/null 2>"$err"; rc=$?
  chmod 0600 "$home/state/t1.status"
  [ "$rc" -ne 0 ] || fail "a delivered answer with a failed close append should fail loudly"
  diagnostic=$(cat "$err")
  assert_contains "$diagnostic" "Close it manually with:" "the close failure should provide recovery guidance"
  manual=${diagnostic#*Close it manually with: }
  manual=${manual% - do not resend the answer.}
  bash -c "$manual" || fail "the generated manual close command should execute successfully"
  [ ! -e "$marker" ] || fail "the generated manual close command executed answer text as shell code"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the generated manual close command did not close the decision: $out"
  fi
  pass "fm-send --resolve-key: failed-close recovery commands safely quote operator text and paths"
}

test_remote_reserved_pending_reply_key_closes_locally() {
  local dir fb log home ssh_log rc out key corr
  dir="$TMP_ROOT/remote-reserved"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; ssh_log="$dir/ssh.log"; : > "$ssh_log"
  home=$(setup_remote_home remote-reserved)
  corr=d448ea86afa4bf67
  key="pending-reply-$corr"
  printf 'blocked [key=%s]: pending-reply-missed: task=rsm pending-reply-id=%s request=ship it\n' \
    "$key" "$corr" > "$home/state/rsm.status"

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SSH_BIN="$fb/fake-ssh" FM_SSH_LOG="$ssh_log" FM_FAKE_SSH_RC=0 \
    "$SEND" rsm --resolve-key "$key" "ack the missed-reply hold" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "a remote reserved-key --resolve-key should succeed"
  grep -F "pending-reply-resolved: task=rsm pending-reply-id=$corr via=operator-resolve-key" \
    "$home/state/rsm.status" >/dev/null \
    || fail "the remote operator close did not write the owning library's close note: $(cat "$home/state/rsm.status")"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the remote reserved pending-reply decision still lists as open: $out"
  fi
  pass "fm-send --resolve-key: a remote secondmate reserved-key close is the same local ledger append"
}

# The decision-answer partition (bin/fm-send.sh header "Answering a decision"):
# a --resolve-key naming an open needs-decision or a captain-held task is a
# decision answer, main-owned while attended and refused for the supervision
# branch before anything is sent; a blocked: key is ordinary steering for
# either actor; and while the away-posture record exists the same branch
# answer is sent and closes the key, because main is parked. Main itself never
# meets the partition.
test_decision_answer_partition_relocates_under_the_record() {
  local dir fb log home rc out
  dir="$TMP_ROOT/partition"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home partition)
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$home/state/t1.status"
  printf 'blocked [key=token]: firstmate can refresh the token\n' >> "$home/state/t1.status"

  # Attended branch: the decision is refused at the partition, nothing sent.
  : > "$log"
  out=$(env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SUPERVISION_ACTOR=branch "$SEND" t1 --resolve-key api-shape "go with REST" 2>&1); rc=$?
  expect_code 6 "$rc" "an attended branch answering a decision must be refused at the partition"
  assert_contains "$out" "decision answer (fm-send --resolve-key) refused" "the partition refusal lost its action label"
  [ ! -e "$home/state/t1.inbox" ] || fail "a refused decision answer still reached the worker's inbox"
  [ ! -s "$log" ] || fail "a refused decision answer still rang the doorbell"
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=api-shape]' >/dev/null \
    || fail "the refused answer closed the decision anyway: $out"

  # Attended branch: a blocked: key is steering, sent and closed under the
  # ordinary lease guard alone.
  FM_SUPERVISION_ACTOR=branch run_send "$fb" "$home" "$log" t1 --resolve-key token "refreshed the token; resume"; rc=$?
  expect_code 0 "$rc" "an attended branch resolving a blocker is ordinary steering"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/t1.status" | grep -qF 'resolved [key=token]: answered: refreshed the token; resume' \
    || fail "the branch's blocker answer did not close the key:"$'\n'"$(cat "$home/state/t1.status")"
  grep -qF "refreshed the token; resume" "$home/state/t1.inbox/001.msg" \
    || fail "the branch's blocker answer did not reach the worker's inbox"

  # Under the record: the same decision answer is sent and closes the key.
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" enter >/dev/null || fail "away entry failed"
  out=$(env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SUPERVISION_ACTOR=branch "$SEND" t1 --resolve-key api-shape "go with REST" 2>&1); rc=$?
  expect_code 0 "$rc" "under the away-posture record the branch's decision answer must be sent: $out"
  assert_contains "$out" "main is parked" "the relocation did not announce itself"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/t1.status" | grep -qF 'resolved [key=api-shape]: answered: go with REST' \
    || fail "the relocated answer did not close the decision:"$'\n'"$(cat "$home/state/t1.status")"
  grep -qF "go with REST" "$home/state/t1.inbox/002.msg" \
    || fail "the relocated answer did not reach the worker's inbox"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F '[key=api-shape]' >/dev/null; then
    fail "the relocated answer left the decision open: $out"
  fi

  # Main never meets the partition, attended or not.
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null || fail "away archive failed"
  printf 'needs-decision [key=db]: postgres or sqlite\n' >> "$home/state/t1.status"
  run_send "$fb" "$home" "$log" t1 --resolve-key db "postgres"; rc=$?
  expect_code 0 "$rc" "main answering a decision attended is unaffected by the partition"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/t1.status" | grep -qF 'resolved [key=db]: answered: postgres' \
    || fail "main's attended decision answer did not close the key"
  pass "fm-send --resolve-key: a decision answer refuses the attended branch before sending, a blocked: key stays steering, and the away-posture record relocates the answer"
}

# Opt-in fleet ledger: the close appends one task.answered per key, with
# answered_by derived from this home's role; nothing about the send changes.
test_resolve_key_records_task_answered() {
  local dir fb log home rc rows
  dir="$TMP_ROOT/ledger-answered"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home ledger-answered)
  mkdir -p "$home/config"
  : > "$home/config/fleet-ledger"
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$home/state/t1.status"
  printf 'needs-decision [key=db-choice]: pick a database\n' >> "$home/state/t1.status"
  printf 'needs-decision [key=port-choice]: pick a port\n' >> "$home/state/t1.status"

  run_send "$fb" "$home" "$log" t1 --resolve-key api-shape "go with REST"; rc=$?
  expect_code 0 "$rc" "an answer send should succeed with the ledger on"
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" enter >/dev/null || fail "away entry failed"
  run_send "$fb" "$home" "$log" t1 --resolve-key db-choice "postgres"; rc=$?
  expect_code 0 "$rc" "an answer send under the away record should succeed"
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null || fail "away archive failed"
  printf 'needs-decision [key=cache-choice]: pick a cache\n' >> "$home/state/t1.status"
  FM_HOME="$home" FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter >/dev/null || fail "quiet entry failed"
  : > "$home/state/.afk"
  run_send "$fb" "$home" "$log" t1 --resolve-key cache-choice "redis"; rc=$?
  expect_code 0 "$rc" "an answer send under a quiet record should succeed"
  rm -f "$home/state/.afk"
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null || fail "quiet archive failed"
  printf 'mate-1\n' > "$home/.fm-secondmate-home"
  run_send "$fb" "$home" "$log" t1 --resolve-key port-choice "9090" >/dev/null 2>&1; rc=$?
  rm -f "$home/.fm-secondmate-home"
  rows=$(jq -c 'select(.event == "task.answered") | [.task, .via, .key, .answered_by, (.at | test("Z$"))]' "$home/state/fleet-ledger.jsonl")
  assert_equals "$(printf '%s\n' '["t1","send","api-shape","main",true]' '["t1","send","db-choice","main-afk",true]' \
    '["t1","send","cache-choice","main",true]')" \
    "$(printf '%s\n' "$rows" | head -3)" "task.answered records for main, away, and quiet (present captain) answers"
  assert_equals 4 "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')" "task.answered records after four answers"
  assert_contains "$(printf '%s\n' "$rows" | tail -1)" '"port-choice","secondmate"' "a secondmate home's answer was not recorded as such"

  # A key that is not open is refused before anything is sent or recorded.
  run_send "$fb" "$home" "$log" t1 --resolve-key not-open "nope"; rc=$?
  expect_code 1 "$rc" "a mistyped key must still refuse"
  assert_equals 4 "$(jq -c 'select(.event == "task.answered")' "$home/state/fleet-ledger.jsonl" | wc -l | tr -d ' ')" \
    "a refused send must record nothing"
  pass "fm-send --resolve-key: one task.answered per closed key, answered_by derived from the home's role, nothing on a refusal"
}

test_unwritable_ledger_leaves_the_send_alone() {
  local dir fb log home rc on_out off_out on_err
  dir="$TMP_ROOT/ledger-failing"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home ledger-failing)
  mkdir -p "$home/config"
  : > "$home/config/fleet-ledger"
  mkdir "$home/state/fleet-ledger.jsonl"
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$home/state/t1.status"
  : > "$log"
  rc=0
  on_out=$(env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t1 --resolve-key api-shape "go with REST" 2> "$dir/stderr") || rc=$?
  on_err=$(cat "$dir/stderr")
  expect_code 0 "$rc" "an unwritable ledger must not fail the send"
  assert_contains "$on_err" "fm-fleet-ledger: could not record answered for t1" "the failed write was not reported"
  assert_equals 1 "$(printf '%s\n' "$on_err" | grep -c 'fm-fleet-ledger')" "ledger lines on stderr"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/t1.status" | grep -qF 'resolved [key=api-shape]: answered: go with REST' \
    || fail "the close was not written when the ledger failed"

  # The flag absent: same stdout, no ledger.
  rm -f "$home/config/fleet-ledger"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$home/state/t1.status"
  rm -rf "$home/state/t1.inbox"
  off_out=$(env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t1 --resolve-key api-shape "go with REST" 2>/dev/null) || fail "flag-off send failed"
  assert_equals "$off_out" "$on_out" "send stdout with an unwritable ledger and with the flag absent"
  pass "fm-send --resolve-key: an unwritable ledger costs one stderr line and changes neither the close nor the output"
}


# --- The send must state its choice when the target has open keyed decisions ---
# (bin/fm-send.sh header, "Decision closure"). A send that states neither
# --resolve-key nor --answers-none is delivered yet leaves its decision open, so
# the drain keeps listing answered work as waiting; it now refuses before
# anything durable happens.

# tree_state <home>: every file under the home with its checksum, so a refusal can
# be shown to have changed nothing durable (inbox, expectation, ledger, status).
# The supervision-warning banner marker (fm-guard.sh runs before any argument is
# read, so every send writes it, refused or not) is not send state.
tree_state() {
  (cd "$1" && find . -type f ! -name '.guard-*' -exec cksum {} + 2>/dev/null | sort)
}

# setup_two_key_home <name> -> a home whose task t1 holds an open needs-decision
# k1 and an open blocked k2.
setup_two_key_home() {
  local home
  home=$(setup_home "$1")
  mkdir -p "$home/config"
  : > "$home/config/fleet-ledger"
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship"
  printf 'needs-decision [key=k1]: pick REST or RPC\n' > "$home/state/t1.status"
  printf 'blocked [key=k2]: need the staging token\n' >> "$home/state/t1.status"
  printf '%s\n' "$home"
}

# send_capture <fakebin> <home> <log> <err-file> <args...>: run_send that keeps stderr.
send_capture() {
  local fb=$1 home=$2 log=$3 err=$4; shift 4
  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" "$@" 2>"$err"
}

test_bare_send_with_open_keys_refuses() {
  local dir fb log home err rc before after
  dir="$TMP_ROOT/choice-bare"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_two_key_home choice-bare)
  before=$(tree_state "$home")

  send_capture "$fb" "$home" "$log" "$err" t1 "go with REST"; rc=$?
  expect_code 1 "$rc" "a send that states no choice must refuse with the same status as the --resolve-key refusals"
  after=$(tree_state "$home")
  assert_equals "$before" "$after" "a refused send must change nothing durable (inbox, expectation, ledger, status)"
  [ ! -e "$home/state/t1.inbox" ] || fail "a refused send wrote a steering record"
  [ ! -s "$log" ] || fail "a refused send rang a doorbell or typed text: $(cat "$log")"
  assert_contains "$(cat "$err")" "[key=k1] needs-decision" "the refusal must list k1 with its verb"
  assert_contains "$(cat "$err")" "[key=k2] blocked" "the refusal must list k2 with its verb"
  assert_contains "$(cat "$err")" "--resolve-key <key>" "the refusal must name the --resolve-key way to proceed"
  assert_contains "$(cat "$err")" "--answers-none" "the refusal must name the --answers-none way to proceed"
  assert_contains "$(cat "$err")" "nothing was sent" "the refusal must say nothing was sent"

  # The listing is the fold's open set: a key that closes leaves the listing.
  send_capture "$fb" "$home" "$log" "$err.close" t1 --resolve-key k1 "REST" >/dev/null; rc=$?
  expect_code 0 "$rc" "the keyed resend must deliver"
  send_capture "$fb" "$home" "$log" "$err" t1 "next"; rc=$?
  expect_code 1 "$rc" "one key still open: a bare send still refuses"
  assert_contains "$(cat "$err")" "[key=k2] blocked" "the remaining open key is listed"
  case "$(cat "$err")" in
    *"[key=k1]"*) fail "a closed key is still listed: $(cat "$err")" ;;
  esac
  pass "fm-send: a send that states no choice refuses before anything durable and lists every open key"
}

test_bare_send_refuses_before_marking_a_secondmate() {
  local dir fb log home err rc before after
  dir="$TMP_ROOT/choice-sm"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home choice-sm)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  printf 'needs-decision [key=fleet-split]: shard by team or by repo\n' > "$home/state/domain.status"
  before=$(tree_state "$home")
  send_capture "$fb" "$home" "$log" "$err" fm-domain "carry on"; rc=$?
  expect_code 1 "$rc" "a bare send to a secondmate with an open key must refuse"
  assert_equals "$before" "$(tree_state "$home")" "a refusal must leave no inbox record, no pending-reply expectation, no marker"
  [ ! -d "$home/state/pending-replies" ] || fail "a refused send created a reply expectation"
  assert_contains "$(cat "$err")" "[key=fleet-split] needs-decision" "the secondmate refusal lists the key"
  pass "fm-send: the refusal happens before a secondmate target is marked or its reply expectation is created"
}

test_bare_send_unchanged_without_open_decisions() {
  local dir fb log home rc rec_bare rec_none
  dir="$TMP_ROOT/choice-none-open"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home choice-none-open)
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship"
  printf 'needs-decision [key=old]: choose\nresolved [key=old]: answered: done\nworking: busy\n' > "$home/state/t1.status"
  run_send "$fb" "$home" "$log" t1 "plain steer"; rc=$?
  expect_code 0 "$rc" "a bare send to a task with no open decision is delivered as before"
  rec_bare=$(sed '/^at=/d' "$home/state/t1.inbox/001.msg")
  rm -rf "$home/state/t1.inbox"
  run_send "$fb" "$home" "$log" t1 --answers-none "plain steer"; rc=$?
  expect_code 0 "$rc" "--answers-none on a task with no open decision is accepted (a caller may pass it unconditionally)"
  rec_none=$(sed '/^at=/d' "$home/state/t1.inbox/001.msg")
  assert_equals "$rec_bare" "$rec_none" "the record is identical with and without the flag (timestamp line aside)"
  assert_contains "$rec_bare" "plain steer" "the steer text reached the record"

  # A reply expectation that opened no status entry is outside the rule.
  home=$(setup_home choice-pending-only)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  run_send "$fb" "$home" "$log" fm-domain "first request"; rc=$?
  expect_code 0 "$rc" "first request creates a reply expectation"
  [ -d "$home/state/pending-replies" ] || fail "precondition: the first request should leave a pending-reply expectation"
  run_send "$fb" "$home" "$log" fm-domain "second request"; rc=$?
  expect_code 0 "$rc" "an expectation with no status entry is not an open keyed decision: the send is delivered"
  pass "fm-send: sends to tasks with no open keyed decision are delivered exactly as before"
}

test_answers_none_delivers_a_routine_steer() {
  local dir fb log home err rc before drain
  dir="$TMP_ROOT/choice-none"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_two_key_home choice-none)
  before=$(cat "$home/state/t1.status")

  send_capture "$fb" "$home" "$log" "$err" t1 --answers-none "unrelated nudge"; rc=$?
  expect_code 0 "$rc" "--answers-none delivers the steer"
  grep -qF "unrelated nudge" "$home/state/t1.inbox/001.msg" || fail "the steer did not reach the record"
  assert_contains "$(cat "$log")" "Firstmate instruction waiting" "the doorbell is rung for a none-send"
  assert_equals "$before" "$(cat "$home/state/t1.status")" "a none-send appends no status line"
  drain=$(drain_out "$home")
  assert_contains "$drain" "[key=k1]" "k1 stays open after a none-send"
  assert_contains "$drain" "[key=k2]" "k2 stays open after a none-send"
  [ ! -e "$home/state/fleet-ledger.jsonl" ] || fail "a none-send recorded an answer in the ledger"

  # --resolve-key for one of two keys is a stated choice and leaves the other open.
  send_capture "$fb" "$home" "$log" "$err" t1 --resolve-key k1 "REST"; rc=$?
  expect_code 0 "$rc" "--resolve-key for one of two open keys needs no further flag"
  drain=$(drain_out "$home")
  case "$drain" in *"[key=k1]"*) fail "k1 should be closed" ;; esac
  assert_contains "$drain" "[key=k2]" "k2 stays open after answering k1"
  pass "fm-send --answers-none: delivers a routine steer, appends nothing, and leaves every key open"
}

test_answers_none_with_resolve_key_is_contradictory() {
  local dir fb log home err rc before after
  dir="$TMP_ROOT/choice-contradict"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_two_key_home choice-contradict)
  before=$(tree_state "$home")
  send_capture "$fb" "$home" "$log" "$err" t1 --answers-none --resolve-key k1 "both"; rc=$?
  expect_code 1 "$rc" "the flag pair is refused"
  assert_contains "$(cat "$err")" "--answers-none" "the refusal names --answers-none"
  assert_contains "$(cat "$err")" "--resolve-key" "the refusal names --resolve-key"
  assert_equals "$before" "$(tree_state "$home")" "a contradictory pair changes nothing durable"
  send_capture "$fb" "$home" "$log" "$err" t1 --resolve-key k1 --answers-none "both"; rc=$?
  expect_code 1 "$rc" "the flag pair is refused in the other order too"
  assert_equals "$before" "$(tree_state "$home")" "refusals change nothing durable"
  send_capture "$fb" "$home" "$log" "$err" t1 --answers-none --answers-none "twice"; rc=$?
  expect_code 0 "$rc" "a repeated --answers-none states one choice and is delivered"
  grep -qF "twice" "$home/state/t1.inbox/001.msg" || fail "the repeated-flag send did not reach the record"
  assert_contains "$(drain_out "$home")" "[key=k1]" "a repeated --answers-none leaves k1 open"
  pass "fm-send: --answers-none together with --resolve-key is refused as contradictory; a repeated --answers-none is one choice"
}

test_mistyped_or_closed_key_is_not_turned_into_a_none_send() {
  local dir fb log home err rc before
  dir="$TMP_ROOT/choice-mistyped"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_two_key_home choice-mistyped)
  before=$(tree_state "$home")
  send_capture "$fb" "$home" "$log" "$err" t1 --resolve-key nope "answer"; rc=$?
  expect_code 1 "$rc" "a mistyped key is refused"
  assert_contains "$(cat "$err")" "no open decision or blocker with that key" "the existing refusal text is unchanged"
  assert_equals "$before" "$(tree_state "$home")" "a mistyped key changes nothing durable"
  send_capture "$fb" "$home" "$log" "$err" t1 --resolve-key k1 "REST" >/dev/null; rc=$?
  expect_code 0 "$rc" "precondition: k1 closes"
  before=$(tree_state "$home")
  send_capture "$fb" "$home" "$log" "$err" t1 --resolve-key k1 "REST again"; rc=$?
  expect_code 1 "$rc" "a closed key is refused as on base"
  assert_contains "$(cat "$err")" "already closed or mistyped" "the existing closed-key refusal text is unchanged"
  assert_equals "$before" "$(tree_state "$home")" "a closed key changes nothing durable"
  pass "fm-send --resolve-key: a mistyped or closed key still refuses with the existing text and is never turned into a none-send"
}

test_reserved_key_counts_as_an_open_decision() {
  local dir fb log home err rc key corr out
  dir="$TMP_ROOT/choice-reserved"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  corr=abcdef0123456789
  key="pending-reply-$corr"
  home=$(setup_home choice-reserved)
  fm_write_meta "$home/state/mate.meta" "window=sess:fm-mate" "kind=ship"
  printf 'blocked [key=%s]: pending-reply-missed: task=mate pending-reply-id=%s request=ship it\n' \
    "$key" "$corr" > "$home/state/mate.status"

  send_capture "$fb" "$home" "$log" "$err" mate "carry on"; rc=$?
  expect_code 1 "$rc" "a bare send to a task whose only open entry is a reserved key refuses"
  assert_contains "$(cat "$err")" "[key=$key] blocked" "the reserved key is listed"
  [ ! -e "$home/state/mate.inbox" ] || fail "the refused send wrote a record"

  send_capture "$fb" "$home" "$log" "$err" mate --answers-none "carry on"; rc=$?
  expect_code 0 "$rc" "the none-send is delivered"
  assert_contains "$(drain_out "$home")" "[key=$key]" "the none-send leaves the reserved key open"

  send_capture "$fb" "$home" "$log" "$err" mate --resolve-key "$key" "ack, false escalation"; rc=$?
  expect_code 0 "$rc" "the keyed answer is delivered"
  grep -F "pending-reply-resolved: task=mate pending-reply-id=$corr via=operator-resolve-key" \
    "$home/state/mate.status" >/dev/null \
    || fail "the keyed answer did not close with the owning library's vocabulary:"$'\n'"$(cat "$home/state/mate.status")"
  out=$(drain_out "$home")
  case "$out" in *"OPEN DECISIONS"*) fail "the reserved key still lists as open: $out" ;; esac
  pass "fm-send: an open reserved pending-reply key refuses a bare send; the keyed answer closes it; the none-send leaves it open"
}

test_sends_that_cannot_answer_are_not_subject() {
  local dir fb log home err rc
  dir="$TMP_ROOT/choice-exempt"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_two_key_home choice-exempt)
  send_capture "$fb" "$home" "$log" "$err" t1 --key Enter; rc=$?
  expect_code 0 "$rc" "a --key send to a task with open keys is not subject to the rule"
  send_capture "$fb" "$home" "$log" "$err" t1 --answers-none --key Enter; rc=$?
  expect_code 0 "$rc" "--answers-none is a harmless no-op beside --key"
  send_capture "$fb" "$home" "$log" "$err" sess:elsewhere "typed text"; rc=$?
  expect_code 0 "$rc" "a send to an explicit backend target has no task ledger and is not subject"
  assert_contains "$(cat "$log")" "typed text" "the explicit-target text was typed"
  assert_equals "$(printf 'needs-decision [key=k1]: pick REST or RPC\nblocked [key=k2]: need the staging token')" \
    "$(cat "$home/state/t1.status")" "none of these sends touched the status log"
  send_capture "$fb" "$home" "$log" "$err" t1 --answers-none --resolve-key k1 --key Enter; rc=$?
  [ "$rc" -ne 0 ] || fail "--resolve-key beside --key still refuses"
  pass "fm-send: --key sends and explicit backend targets are not subject to the choice rule"
}

test_log_past_the_read_limits_refuses_a_bare_send() {
  local dir fb log home err rc
  dir="$TMP_ROOT/choice-limits"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home choice-limits)
  fm_write_meta "$home/state/t5.meta" "window=sess:fm-t5" "kind=ship"
  { printf 'needs-decision [key=real-key]: choose\n'; perl -e 'print "text\n" x 40000'; } > "$home/state/t5.status"

  : > "$log"
  env PATH="$fb:$PATH" FM_STATUS_CAP_BYTES=4000 FM_STATUS_CAP_RESERVE_BYTES=1000 \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t5 "a bare steer" >/dev/null 2>"$err"; rc=$?
  expect_code 1 "$rc" "a bare send whose decision ledger cannot be read must refuse, not guess"
  assert_contains "$(cat "$err")" "cannot tell whether t5 has open decisions" "the refusal says the open set is unknown"
  assert_contains "$(cat "$err")" "nothing was sent" "the refusal states nothing was sent"
  [ ! -d "$home/state/t5.inbox" ] || fail "a refused bare send still enqueued a record"
  : > "$log"
  env PATH="$fb:$PATH" FM_STATUS_CAP_BYTES=4000 FM_STATUS_CAP_RESERVE_BYTES=1000 \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t5 --answers-none "a none steer" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "--answers-none does not depend on reading the log and is delivered"
  pass "fm-send: an unreadable (past-the-limits) status log refuses a bare send rather than guessing"
}

# The CONFIG_REREAD pointer send (bin/fm-config-inherit-lib.sh) answers no
# decision, so it states --answers-none and still lands when the mate has an open
# keyed decision.
test_config_reread_pointer_is_delivered_to_a_mate_with_an_open_keyed_decision() {
  local dir fb log home instr out rc before
  dir="$TMP_ROOT/reread-open-key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home reread-open-key)
  fm_write_secondmate_meta "$home/state/sm.meta" "$home" "sess:fm-sm"
  printf 'needs-decision [key=shard-plan]: shard by team or by repo\n' > "$home/state/sm.status"
  before=$(cat "$home/state/sm.status")
  instr="$home/state/.fm-inherited-config-reread.fixture"
  printf 'These inherited config files changed. Re-read them.\n' > "$instr"
  printf '%s' "$instr" > "$instr.pending"
  : > "$log"
  # The single-quoted script is deliberate: its $1 and $2 are bash -c positional parameters.
  # shellcheck disable=SC2016
  out=$(env PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    bash -c '. "$1"; fm_config_reread_send_pointer sm "$2"' _ "$ROOT/bin/fm-config-inherit-lib.sh" "$instr" 2>&1); rc=$?
  expect_code 0 "$rc" "the CONFIG_REREAD send was refused by the open keyed decision: $out"
  assert_contains "$out" "config-reread: sent" "the CONFIG_REREAD send did not report delivery: $out"
  grep -qF "CONFIG_REREAD: $instr" "$home/state/sm.inbox/001.msg" \
    || fail "the CONFIG_REREAD pointer did not reach the mate's record"
  assert_equals "$before" "$(cat "$home/state/sm.status")" "the CONFIG_REREAD send closed or appended something in the mate's status log"
  assert_contains "$(drain_out "$home")" "[key=shard-plan]" "the open decision no longer lists as open after the CONFIG_REREAD send"
  pass "fm-send callers: the CONFIG_REREAD pointer reaches a mate that has an open keyed decision and leaves it open"
}

# The three cases of 2026-11-03 that led to the choice rule (fm-send header, "Decision
# closure"). Each status log below holds the recorded verb, key, corr and at stamps of the
# lines in the home's state/ at the moment the answer was sent; the summary text is cut after
# its first clause (the full recorded lines are in the task's evidence). The answer texts are
# stand-ins: the message bodies of Main 2874, Main 3000 and the Main 2868 follow-up are not in
# any status log. On the old behavior each answer was delivered and the key stayed open (the
# lane's own working:/done: lines cannot close it); now the bare send refuses.
recorded_case_check() {  # <case-name> <task> <key> <status-log-file> <lane-lines-file> <drain-marker>
  local name=$1 task=$2 key=$3 statusfile=$4 lanefile=$5 marker=$6 dir fb log home err rc out
  dir="$TMP_ROOT/recorded-$name"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home "recorded-$name")
  # All three recorded lanes are secondmates: a secondmate's own done: line does not clear its open set.
  fm_write_secondmate_meta "$home/state/$task.meta" "$home" "sess:fm-$task"
  cp "$statusfile" "$home/state/$task.status"
  assert_contains "$(drain_out "$home")" "$marker" "precondition: the recorded decision lists as open"

  send_capture "$fb" "$home" "$log" "$err" "$task" "stand-in answer text"; rc=$?
  expect_code 1 "$rc" "$name: the bare answer must refuse"
  assert_contains "$(cat "$err")" "[key=$key]" "$name: the refusal must list the recorded key"
  [ ! -e "$home/state/$task.inbox" ] || fail "$name: the refused answer was delivered"

  # What the old behavior led to: a none-send is the explicit way to deliver without closing, and
  # the lane's own later lines never close the key.
  send_capture "$fb" "$home" "$log" "$err" "$task" --answers-none "stand-in answer text"; rc=$?
  expect_code 0 "$rc" "$name: the none-send is delivered"
  cat "$lanefile" >> "$home/state/$task.status"
  assert_contains "$(drain_out "$home")" "$marker" "$name: the lane's working:/done: lines closed the key"

  send_capture "$fb" "$home" "$log" "$err" "$task" --resolve-key "$key" "stand-in answer text"; rc=$?
  expect_code 0 "$rc" "$name: the keyed answer is delivered"
  out=$(drain_out "$home")
  case "$out" in
    *"$marker"*) fail "$name: the key is still open after the keyed answer: $out" ;;
  esac
}

test_recorded_cases_of_2026_11_03() {
  local dir="$TMP_ROOT/recorded-lines"
  mkdir -p "$dir"
  # Case 1 - d3 b6-slice2-seam-and-admit, Main 2874 sent with a correlation only.
  cat > "$dir/case1.status" <<'EOF'
needs-decision [key=b6-slice2-seam-and-admit] [at=1793687475]: B6 slice 2 customer screens (worker alive, clean at ad8e09ee9, 1 unlanded commit) has waited about 8 h for two Main items: (1) the after-confirm seam answer, (2) the admit for its one run.
EOF
  cat > "$dir/case1.lane" <<'EOF'
working [key=b6-slice2-seam-and-admit] [corr=770ac0ee07611c04] [at=1793687979]: Main 2874 relayed to the B6 worker (seam = option A); keep holding ad8e09ee9 for the admit.
done [key=b6-slice2-seam-and-admit] [corr=770ac0ee07611c04] [at=1793688539]: B6 M6 Verify addition PASSED clean contract review.
EOF
  recorded_case_check d3-b6-slice2 b6mate b6-slice2-seam-and-admit "$dir/case1.status" "$dir/case1.lane" "[key=b6-slice2-seam-and-admit]"

  # Case 2 - vernant-mini-build train-records-close-route: the lane reopened the key after
  # Main 2999 closed it, and Main 3000 went without the key.
  cat > "$dir/case2.status" <<'EOF'
needs-decision [key=train-records-close-route] [at=1793711904]: train H5 landed (PR 3607, commit 06a18553). Three old ledger rows block my wake acks and cannot be deferred twice.
resolved [key=train-records-close-route] [at=1793712032]: answered: Main 2999 [key=train-records-close-route] Ledger rows (record each with this message's text as evidence)
needs-decision [key=train-records-close-route] [corr=6abd3f41d39e730f] [at=1793712159]: (a) three ledger rows recorded escalated with Main 2999 text (steered refused as before). (b) h5 closed already by the merge script's own prune.
EOF
  cat > "$dir/case2.lane" <<'EOF'
done [key=train-records-close-route] [corr=5aa6551388deaf07] [at=1793712531]: received Main 3000. h3 record held untouched until Main relays the captain's drop words verbatim.
EOF
  recorded_case_check vernant-mini-build minimate train-records-close-route "$dir/case2.status" "$dir/case2.lane" "[key=train-records-close-route]"

  # Case 3 - d3, the Main 2868 blocker: an unkeyed blocked: line with a correlation folds under the
  # key "default"; it stayed open until Main 3124.
  cat > "$dir/case3.status" <<'EOF'
blocked [corr=5187ee73da3d3afd] [at=1793687534]: Main 2868 not done. Drop words written verbatim to the two captain-drop-words files. The teardown command did NOT run: this session's harness permission check refused it before execution.
EOF
  cat > "$dir/case3.lane" <<'EOF'
working [at=1793687900]: retrying the two drop items after Main 2868.
EOF
  recorded_case_check d3-main2868 d3mate default "$dir/case3.status" "$dir/case3.lane" "d3mate blocked:"
  pass "fm-send: the three recorded cases of 2026-11-03 refuse a bare answer; the keyed answer leaves the drain's open set without the key"
}

test_answer_send_closes_open_decision
test_answer_close_is_self_announced
test_separate_resolve_key_answers_do_not_rewake
test_colon_first_key_position_is_answerable
test_answer_starts_work_never_orphans
test_routine_steer_never_closes
test_not_open_key_refuses_before_send
test_log_past_the_read_limits_is_unknown_not_already_closed
test_failed_ring_still_closes_at_enqueue
test_failed_enqueue_does_not_close
test_multiple_keys_close_together
test_multiple_keys_close_after_fold_is_self_announced
test_local_secondmate_answer_marked_and_closed
test_remote_secondmate_answer_closes_locally
test_remote_reply_corr_tag_does_not_block_resolve_key
test_remote_transport_failure_does_not_close
test_flag_misuse_refuses
test_reserved_pending_reply_key_closes_through_resolve_key
test_unrelated_writer_cannot_close_or_hijack_reserved_key
test_unclosable_reserved_key_refuses_before_send
test_long_decision_key_refuses_before_send
test_stamped_close_line_stays_within_the_status_line_cap
test_failed_close_recovery_command_is_shell_safe
test_remote_reserved_pending_reply_key_closes_locally
test_decision_answer_partition_relocates_under_the_record
test_resolve_key_records_task_answered
test_unwritable_ledger_leaves_the_send_alone
test_bare_send_with_open_keys_refuses
test_bare_send_refuses_before_marking_a_secondmate
test_bare_send_unchanged_without_open_decisions
test_answers_none_delivers_a_routine_steer
test_answers_none_with_resolve_key_is_contradictory
test_mistyped_or_closed_key_is_not_turned_into_a_none_send
test_reserved_key_counts_as_an_open_decision
test_sends_that_cannot_answer_are_not_subject
test_log_past_the_read_limits_refuses_a_bare_send
test_config_reread_pointer_is_delivered_to_a_mate_with_an_open_keyed_decision
test_recorded_cases_of_2026_11_03
