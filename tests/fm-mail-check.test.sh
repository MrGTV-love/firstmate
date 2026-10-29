#!/usr/bin/env bash
# Behavior tests for bin/fm-mail-check.sh, the standing received-mail check.
#
# Two surfaces are exercised through their executable interfaces:
#
#   * arming/disarming state/mail.check.sh with its trust binding, including
#     the refusal paths (symlink at the shim path, missing mail plane);
#
#   * the `check` action itself, which runs the real fm-mail.sh poll against a
#     scratch home whose .env and fake python3 decide the outcome. The cases
#     that matter are the reporting contract: a successful poll that surfaces
#     new mail emits one wake line (the poll still also surfaces new mail as
#     durable wakes), a failing poll reports one line, a proven no-op stays
#     silent, and fail-closed-after-queue still doorbells.
#
# No case ever contacts a real IMAP or SMTP server.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-mail-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-mail-check)

# Clear ambient mail configuration so the poll's
# readiness decision comes from the fixture .env alone. The check binary is an
# explicit argument so the missing-mail-plane case runs a copy without fm-mail.sh.
run_check() {
  local home=$1 out=$2 check=$3
  shift 3
  local status=0
  env -u FM_MAIL_USER -u FM_MAIL_PASS -u FM_IMAP_HOST -u FM_SMTP_HOST \
    FM_CHECK_TIMEOUT=30 \
    "$@" FM_HOME="$home" PATH="$FAKEBIN:$PATH" \
    "$check" check >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "check exit"
}

# make_home <name>: a scratch home without a mail plane yet.
make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# write_env <home>: the four FM_MAIL_* values the poll requires.
write_env() {
  local home=$1
  printf '%s\n' \
    'FM_MAIL_USER=test@example.invalid' \
    'FM_MAIL_PASS=test-pass' \
    'FM_IMAP_HOST=imap.test.invalid' \
    'FM_SMTP_HOST=smtp.test.invalid' > "$home/.env"
}

# enter_mailbox <home> <mailbox-generator-command...>: wires the scratch home's
# bin to the real wake library and FAKEBIN to a python3 running <cmd> so a poll
# against this home can surface and durably record a wake.
enter_mailbox() {
  local home=$1 generator=$2
  mkdir -p "$home/bin" "$FAKEBIN"
  [ -e "$home/bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$home/bin/fm-wake-lib.sh"
  [ -e "$home/bin/fm-path-lib.sh" ] || ln -s "$ROOT/bin/fm-path-lib.sh" "$home/bin/fm-path-lib.sh"
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016 # Positional parameters belong to the generated shim.
    printf 'case "$1" in -c|*/fm-duration.py) exec %q "$@" ;; esac\n' "$REAL_PYTHON"
    printf '%s\n' "$generator"
  } > "$FAKEBIN/python3"
  chmod +x "$FAKEBIN/python3"
}

REAL_PYTHON=$(command -v python3)
FAKEBIN="$TMP_ROOT/fakebin"

# mail_check_copy <dir> <fake-poll-body...>: a copy of the check beside a fake
# fm-mail.sh whose body is the given lines.
mail_check_copy() {
  local dir=$1 lib
  shift
  mkdir -p "$dir"
  cp "$ROOT/bin/fm-mail-check.sh" "$dir/"
  for lib in fm-timeout-lib.sh fm-duration-lib.sh fm-duration.py fm-pr-lib.sh fm-file-identity-lib.sh fm-line-cap-lib.sh fm-check-lib.sh; do
    [ -e "$dir/$lib" ] || ln -s "$ROOT/bin/$lib" "$dir/$lib"
  done
  printf '%s\n' '#!/usr/bin/env bash' "$@" > "$dir/fm-mail.sh"
  chmod +x "$dir/fm-mail.sh"
}

# A durable mail wake row, as fm-mail.sh's wake_for appends it.
# shellcheck disable=SC2016 # The fake poll expands its own home and clock.
QUEUE_MAIL_ROW='printf "%s\t1\tcheck\tmail:42\tcheck: mail 42\n" "$(date +%s)" >> "$FM_HOME/state/.wake-queue"'

test_help_and_usage() {
  local out rc=0
  out=$("$CHECK" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "check" "--help lists the check action"
  assert_contains "$out" "arm" "--help lists the arm action"
  assert_contains "$out" "disarm" "--help lists the disarm action"
  rc=0
  out=$("$CHECK" bogus 2>&1) || rc=$?
  expect_code 2 "$rc" "unknown action must exit 2"
  assert_contains "$out" "unknown action" "unknown action is refused loudly"
  pass "fm-mail-check: help and usage plumbing"
}

test_arm_writes_and_binds_the_check_and_disarm_removes_it() {
  local home out
  home=$(make_home arm)
  write_env "$home"
  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || fail "arm must succeed: $out"
  assert_contains "$out" "armed: state/mail.check.sh" "arm names the shim it wrote"
  assert_present "$home/state/mail.check.sh" "arm writes the check shim"
  assert_present "$home/state/mail.check-trust" "arm binds the shim for the watcher"
  assert_contains "$(cat "$home/state/mail.check.sh")" "fm-mail-check.sh check" "shim dispatches the check action"
  assert_contains "$(cat "$home/state/mail.check.sh")" "FM_HOME=$home" "shim pins the absolute home"

  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || fail "re-arm must succeed: $out"
  assert_contains "$out" "armed" "re-arm stays armed"

  out=$(FM_HOME="$home" "$CHECK" disarm 2>&1) || fail "disarm must succeed: $out"
  assert_absent "$home/state/mail.check.sh" "disarm removes the check shim"
  assert_absent "$home/state/mail.check-trust" "disarm removes the trust binding"
  assert_absent "$home/state/.mail-check" "disarm removes the report record"
  pass "fm-mail-check: arm writes and binds, re-arm is idempotent, disarm removes"
}

test_arm_resolves_a_relative_home_into_the_shim() {
  local home rel out
  home=$(make_home relative)
  write_env "$home"
  rel="$(basename "$home")"
  out=$(cd "$TMP_ROOT" && env FM_HOME="$rel" "$CHECK" arm 2>&1) || fail "arm with a relative FM_HOME must succeed: $out"
  assert_contains "$(cat "$home/state/mail.check.sh")" "export FM_HOME=$home" "the shim pins the resolved absolute home, not the relative spelling"
  pass "fm-mail-check: arm resolves a relative home into the shim"
}

test_arm_refuses_a_symlink_at_the_shim_path() {
  local home target out rc=0
  home=$(make_home symlink)
  write_env "$home"
  target="$TMP_ROOT/outside"
  mkdir -p "$target"
  printf '#!/usr/bin/env bash\n' > "$target/mail.check.sh"
  ln -s "$target/mail.check.sh" "$home/state/mail.check.sh"
  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm must refuse a symlink at the shim path"
  assert_contains "$out" "could not write" "arm reports the shim write failure"
  assert_absent "$home/state/mail.check-trust" "no trust binding is left behind by a refused arm"
  pass "fm-mail-check: arm refuses a symlink at the shim path"
}

test_arm_refuses_without_the_mail_plane() {
  local tmpbin home out rc=0
  # A copy of the check tool with no fm-mail.sh beside it is a home whose mail
  # plane has not landed yet: arming must refuse instead of delegating silence.
  tmpbin="$TMP_ROOT/plane/bin"
  home="$TMP_ROOT/plane/home"
  mkdir -p "$tmpbin" "$home/state"
  cp "$ROOT/bin/fm-mail-check.sh" "$tmpbin/"
  for lib in fm-timeout-lib.sh fm-duration-lib.sh fm-duration.py fm-pr-lib.sh fm-file-identity-lib.sh fm-line-cap-lib.sh fm-check-lib.sh; do
    [ -e "$tmpbin/$lib" ] || ln -s "$ROOT/bin/$lib" "$tmpbin/$lib"
  done
  out=$(FM_HOME="$home" "$tmpbin/fm-mail-check.sh" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm must refuse when the mail plane is missing"
  assert_contains "$out" "mail plane is missing" "arm names the missing plane"
  assert_absent "$home/state/mail.check.sh" "a refused arm writes no shim"
  pass "fm-mail-check: arm refuses without the mail plane"
}

test_successful_poll_with_new_mail_emits_one_wake_line() {
  local home out wakeq
  home=$(make_home success)
  write_env "$home"
  enter_mailbox "$home" \
    'printf "uidvalidity\\t20002\\n"
printf "42\\t2026-09-05T00:00:00Z\\talice@example.com\\tHello\\n"'
  out="$home/out.txt"
  run_check "$home" "$out" "$CHECK"
  assert_contains "$(cat "$out")" "mail: new mail: woke for 42" "a successful poll that surfaces new mail emits one wake line"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "a successful new-mail poll reports exactly one line: $(cat "$out")"
  assert_present "$home/state/.mail-check" "a successful poll records its outcome"
  assert_contains "$(cat "$home/state/.mail-check")" "fm-mail-check-v1" "the record carries its schema"
  assert_contains "$(cat "$home/state/.mail-check")" "reported=new mail: woke for 42" "the record carries the reported new-mail finding"
  wakeq="$home/state/.wake-queue"
  assert_contains "$(cat "$wakeq" 2>/dev/null)" "mail from alice@example.com" "the check-run poll still surfaces new mail as a durable wake"
  assert_contains "$(cat "$home/state/.mail-seen" 2>/dev/null)" "42" "the check-run poll still advances the inbox cursor"
  pass "fm-mail-check: a successful poll that surfaces new mail emits one wake line"
}

test_failure_is_reported_once_until_it_changes() {
  local home out
  home=$(make_home failure)
  write_env "$home"
  enter_mailbox "$home" \
    'printf "fm-mail poll error: connection refused\\n" >&2
exit 1'

  out="$home/out.txt"
  run_check "$home" "$out" "$CHECK"
  assert_contains "$(cat "$out")" "mail: fm-mail poll error: connection refused" "a failing poll reports its cause in one line"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "a failing poll reports exactly one line: $(cat "$out")"

  out="$home/out2.txt"
  run_check "$home" "$out" "$CHECK"
  [ ! -s "$out" ] || fail "the same failure must not be reported again: $(cat "$out")"
  assert_contains "$(cat "$home/state/.mail-check")" "reported=fm-mail poll error: connection refused" "the record carries the reported finding"

  # A healthy poll clears the record, so the next failure is news again.
  enter_mailbox "$home" \
    'printf "uidvalidity\\t20003\\n"'
  out="$home/out3.txt"
  run_check "$home" "$out" "$CHECK"
  [ ! -s "$out" ] || fail "a recovered poll must stay silent: $(cat "$out")"

  enter_mailbox "$home" \
    'printf "fm-mail poll error: connection refused\\n" >&2
exit 1'
  out="$home/out4.txt"
  run_check "$home" "$out" "$CHECK"
  assert_contains "$(cat "$out")" "mail: fm-mail poll error: connection refused" "a failure after a healthy poll is news again"
  pass "fm-mail-check: a poll failure is reported once and re-reported after recovery"
}

test_unconfigured_home_is_reported_once() {
  local home out
  home=$(make_home unconfigured)
  # No .env: the poll names the missing value, and the check turns that into
  # its one line instead of leaving an armed channel quiet.
  out="$home/out.txt"
  run_check "$home" "$out" "$CHECK"
  assert_contains "$(cat "$out")" "mail: missing required" "an unconfigured home reports the missing setup"
  assert_contains "$(cat "$out")" "FM_MAIL_USER" "the report names the missing variable"
  out="$home/out2.txt"
  run_check "$home" "$out" "$CHECK"
  [ ! -s "$out" ] || fail "the unconfigured state must not repeat: $(cat "$out")"
  pass "fm-mail-check: an unconfigured home is reported once, not every poll"
}

test_silent_poll_is_unknown_and_retried() {
  local home out attempt child previous=
  home=$(make_home silent)
  write_env "$home"
  # shellcheck disable=SC2016 # PID and home are resolved by the generated poll process.
  enter_mailbox "$home" 'printf "%s\n" "$$" > "$FM_HOME/poll-pid"; sleep 30'
  for attempt in 1 2; do
    out="$home/out-$attempt.txt"
    rm -f "$home/poll-pid"
    run_check "$home" "$out" "$CHECK"
    [ -s "$home/poll-pid" ] || fail "attempt $attempt did not retry the poll"
    IFS= read -r child < "$home/poll-pid"
    [ "$child" != "$previous" ] || fail 'the second attempt did not start a new poll'
    previous=$child
    ! kill -0 "$child" 2>/dev/null || fail 'silent mail child survived cleanup'
  done
  assert_contains "$(cat "$home/out-1.txt")" 'mail: poll stopped making progress; result unknown, retry next pass' \
    'silent poll must be unknown, not clean or failed'
  [ "$(wc -l < "$home/out-1.txt" | tr -d '[:space:]')" = 1 ] || fail 'unknown poll must report one line'
  [ ! -s "$home/out-2.txt" ] || fail "a repeated unknown with nothing queued woke again: $(cat "$home/out-2.txt")"
  pass 'a silent mail poll is stopped at its read bound, cleaned up, reported once and retried'
}

test_repeated_timeout_still_wakes() {
  # A stopped poll can already have queued mail. Every pass prints while that
  # row is waiting in the wake queue, and goes quiet once it is drained.
  local dir home out
  dir="$TMP_ROOT/repeat-timeout/bin"
  home="$TMP_ROOT/repeat-timeout/home"
  mkdir -p "$home/state"
  mail_check_copy "$dir" "$QUEUE_MAIL_ROW" 'exit 124'
  out="$home/out1.txt"
  run_check "$home" "$out" "$dir/fm-mail-check.sh"
  assert_contains "$(cat "$out")" "mail: poll stopped making progress" "the first stopped poll reports"
  out="$home/out2.txt"
  run_check "$home" "$out" "$dir/fm-mail-check.sh"
  assert_contains "$(cat "$out")" "mail: poll stopped making progress" "a repeated stop must still print while its mail is queued"
  : > "$home/state/.wake-queue"
  mail_check_copy "$dir" 'exit 124'
  out="$home/out3.txt"
  run_check "$home" "$out" "$dir/fm-mail-check.sh"
  [ ! -s "$out" ] || fail "a repeated stop with nothing queued still woke: $(cat "$out")"
  pass "fm-mail-check: a repeated stop still wakes while its mail is queued"
}

test_watcher_stopped_poll_rings_queued_mail_next_pass() {
  local dir home pass_status
  dir="$TMP_ROOT/watcher-stop/bin"
  home="$TMP_ROOT/watcher-stop/home"
  mkdir -p "$home/state"
  # shellcheck disable=SC2016 # The fake poll expands its own home.
  mail_check_copy "$dir" '[ -e "$FM_HOME/hang" ] || exit 0' "$QUEUE_MAIL_ROW" 'while :; do :; done'
  : > "$home/hang"
  for pass_status in stopped rings; do
    # FM_DURATION_ABSOLUTE_SECS is fm-duration.py's own seam for its absolute extreme.
    # shellcheck disable=SC2016 # The child watcher shell expands its own arguments.
    env FM_HOME="$home" FM_DURATION_ABSOLUTE_SECS="$([ "$pass_status" = stopped ] && echo 2 || echo 21600)" bash -c '
        . "$1"
        WATCHER_PID=$$
        trap "fm_active_check_stop; fm_check_output_cleanup" EXIT
        watcher_beat force
        run_check_capture mail "$2" check || exit 21
        if [ "$3" = stopped ]; then
          [ "$FM_CHECK_STATUS" = 124 ] && [ -z "$FM_CHECK_RESULT" ] || exit 22
        else
          [ "$FM_CHECK_STATUS" = 0 ] || exit 23
          [ "$FM_CHECK_RESULT" = "mail: queued mail is waiting to be drained" ] || exit 24
        fi
      ' _ "$ROOT/bin/fm-watch.sh" "$dir/fm-mail-check.sh" "$pass_status" \
      > "$home/watch-$pass_status.out" 2> "$home/watch-$pass_status.err" \
      || fail "$pass_status pass failed: $(cat "$home/watch-$pass_status.err")"
    rm -f "$home/hang"
  done
  pass 'mail queued by a poll the watcher stopped still rings on the next pass'
}

test_idle_poll_within_its_measured_bound_succeeds() {
  local home out _
  home=$(make_home idle-eighteen)
  write_env "$home"
  for _ in 1 2 3 4 5; do
    FM_DURATION_FILE="$home/durations.jsonl" python3 "$ROOT/bin/fm-duration.py" record mail-check.poll 8000 0 \
      || fail 'could not write the duration fixture'
  done
  enter_mailbox "$home" \
    'sleep 18
printf "uidvalidity\\t20002\\n"
printf "42\\t2026-09-05T00:00:00Z\\talice@example.com\\tHello\\n"'
  out="$home/out.txt"
  run_check "$home" "$out" "$CHECK" FM_DURATION_FILE="$home/durations.jsonl"
  assert_contains "$(cat "$out")" "mail: new mail: woke for 42" "an 18 s idle poll inside its measured bound was stopped"
  pass 'an idle-CPU poll that answers in 18 s delivers its mail once its measured bound allows it'
}

test_progressing_poll_survives_fivefold_slowdown() {
  local tmpbin home factor out
  tmpbin="$TMP_ROOT/progress/bin"
  mkdir -p "$tmpbin"
  cp "$CHECK" "$tmpbin/"
  for lib in fm-timeout-lib.sh fm-duration-lib.sh fm-duration.py fm-pr-lib.sh fm-file-identity-lib.sh fm-line-cap-lib.sh fm-check-lib.sh; do
    ln -s "$ROOT/bin/$lib" "$tmpbin/$lib"
  done
  cat > "$tmpbin/fm-mail.sh" <<'SH'
#!/usr/bin/env bash
for ((step=0; step<10; step++)); do printf 'progress\n' >&2; sleep "$FM_TEST_DELAY"; done
printf 'fm-mail: woke for 42\n'
SH
  chmod +x "$tmpbin/fm-mail.sh"
  for factor in 1 5; do
    home=$(make_home "progress-$factor")
    out="$home/out.txt"
    run_check "$home" "$out" "$tmpbin/fm-mail-check.sh" FM_TEST_DELAY="0.$factor"
    assert_contains "$(cat "$out")" 'mail: new mail: woke for 42' "${factor}x poll lost its new mail"
  done
  pass 'mail polls deliver new mail at 1x and 5x while making progress'
}

test_repeated_failure_that_queued_new_mail_still_wakes() {
  # A poll can append durable mail wakes and then fail with the same cause as
  # the last check. Difference-record silence would leave those wakes queued
  # and unacted; the check must print again so the watcher wakes firstmate.
  local tmpbin home out check_bin
  tmpbin="$TMP_ROOT/repeat-wake/bin"
  home="$TMP_ROOT/repeat-wake/home"
  mkdir -p "$tmpbin" "$home/state"
  check_bin="$tmpbin/fm-mail-check.sh"
  cp "$ROOT/bin/fm-mail-check.sh" "$tmpbin/"
  for lib in fm-timeout-lib.sh fm-duration-lib.sh fm-duration.py fm-pr-lib.sh fm-file-identity-lib.sh fm-line-cap-lib.sh fm-check-lib.sh; do
    [ -e "$tmpbin/$lib" ] || ln -s "$ROOT/bin/$lib" "$tmpbin/$lib"
  done
  printf '%s\n' '#!/usr/bin/env bash' 'echo "fm-mail: woke for 42"' 'echo "fm-mail: connection refused" >&2' 'exit 1' > "$tmpbin/fm-mail.sh"
  chmod +x "$tmpbin/fm-mail.sh"

  out="$home/out1.txt"
  run_check "$home" "$out" "$check_bin"
  assert_contains "$(cat "$out")" "mail: connection refused" "the first failed poll that queued new mail reports the failure"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "the first report is exactly one line: $(cat "$out")"

  out="$home/out2.txt"
  run_check "$home" "$out" "$check_bin"
  assert_contains "$(cat "$out")" "mail: connection refused" "the same failure must still print when that poll queued new mail"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "the repeat report is exactly one line: $(cat "$out")"
  pass "fm-mail-check: a repeated failure that queued new mail still wakes"
}

test_large_poll_output_is_drained() {
  # A pipe reader that exits at the first match closes before the producer has
  # written this poll's output. Ignored SIGPIPE makes that race observable as
  # stderr noise instead of silently terminating a pipeline subprocess.
  # Exercise both summary selectors and both wake predicates via the real check.
  local tmpbin home shape attempt out expected
  tmpbin="$TMP_ROOT/large-poll/bin"
  mkdir -p "$tmpbin"
  cp "$CHECK" "$tmpbin/"
  for lib in fm-timeout-lib.sh fm-duration-lib.sh fm-duration.py fm-pr-lib.sh fm-file-identity-lib.sh fm-line-cap-lib.sh fm-check-lib.sh; do
    ln -s "$ROOT/bin/$lib" "$tmpbin/$lib"
  done
  cat > "$tmpbin/fm-mail.sh" <<'SH'
#!/usr/bin/env bash
printf 'fm-mail: woke for 42\n'
case "$FM_TEST_POLL_SHAPE" in
  success)
    awk 'BEGIN { for (i=0; i<20000; i++) print "poll diagnostic padding padding padding" }'
    printf 'fm-mail: woke for 43\n'
    ;;
  preferred)
    printf 'fm-mail: connection refused\n' >&2
    awk 'BEGIN { for (i=0; i<20000; i++) print "fm-mail: later diagnostic padding padding" }' >&2
    exit 1
    ;;
  fallback)
    printf 'raw connection failure\n' >&2
    awk 'BEGIN { for (i=0; i<20000; i++) print "raw later diagnostic padding padding" }' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$tmpbin/fm-mail.sh"
  for shape in success preferred fallback; do
    home=$(make_home "large-$shape")
    case "$shape" in
      success) expected='mail: new mail: woke for 43' ;;
      preferred) expected='mail: connection refused' ;;
      fallback) expected='mail: raw connection failure' ;;
    esac
    for attempt in 1 2; do
      out="$home/out-$attempt.txt"
      (trap '' PIPE; run_check "$home" "$out" "$tmpbin/fm-mail-check.sh" FM_TEST_POLL_SHAPE="$shape")
      [ "$(cat "$out")" = "$expected" ] || fail "large $shape poll $attempt must emit only its summary: $(cat "$out")"
      [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "large $shape poll must be exactly one line"
    done
  done
  pass "fm-mail-check: large repeated polls drain every reader without output noise"
}

test_fail_closed_poll_after_wake_reports_the_failure() {
  # A poll can publish a wake and then fail closed (stale retry still on disk
  # and unwritable). The standing check must report that failure, not the
  # earlier success-wake line, or the news key hides the real condition.
  local home out
  home=$(make_home fail-closed-after-wake)
  write_env "$home"
  enter_mailbox "$home" \
    'printf "uidvalidity\\t90009\\n"
printf "77\\t2026-09-05T00:00:00Z\\tfrom@x\\tHello\\tok\\n"'
  printf 'uidvalidity=90009\n' > "$home/state/.mail-seen"
  printf '77\n' > "$home/state/.mail-retry"
  chmod 0000 "$home/state/.mail-retry"
  out="$home/out.txt"
  run_check "$home" "$out" "$CHECK"
  chmod 0600 "$home/state/.mail-retry"
  assert_contains "$(cat "$out")" "mail: could not clear retry for recovered 77 after publish" "a fail-closed poll after a wake reports the failure"
  assert_not_contains "$(cat "$out")" "woke for 77" "the standing check must not treat the success-wake line as the failure"
  assert_contains "$(cat "$home/state/.mail-check")" "reported=could not clear retry for recovered 77 after publish" "the news key is the failure, not the wake"
  pass "fm-mail-check: a fail-closed poll after a wake reports the failure, not the wake"
}

test_repeated_status4_fail_closed_still_wakes() {
  # Status 4: wake_for published the row, then retry-clear failed, so the poll
  # returns 1 without printing woke-for. A second identical poll must still
  # print so the watcher drains the queued check: mail <uid> row.
  local home out wakeq
  home=$(make_home repeat-status4)
  write_env "$home"
  enter_mailbox "$home" \
    'printf "uidvalidity\\t90009\\n"
printf "77\\t2026-09-05T00:00:00Z\\tfrom@x\\tHello\\tretry\\n"'
  printf 'uidvalidity=90009\n77\n' > "$home/state/.mail-seen"
  printf '77\n' > "$home/state/.mail-retry"
  chmod 0000 "$home/state/.mail-retry"

  out="$home/out1.txt"
  run_check "$home" "$out" "$CHECK"
  assert_contains "$(cat "$out")" "mail: could not clear retry for recovered 77 after publish" "the first status-4 poll reports the failure"
  assert_not_contains "$(cat "$out")" "woke for 77" "status 4 does not print woke-for"
  wakeq="$home/state/.wake-queue"
  assert_contains "$(cat "$wakeq" 2>/dev/null)" "check: mail 77" "status 4 leaves the recovery wake queued"

  out="$home/out2.txt"
  run_check "$home" "$out" "$CHECK"
  assert_contains "$(cat "$out")" "mail: could not clear retry for recovered 77 after publish" "a repeated status-4 poll still prints so the queued mail is not stranded"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "the repeat report is exactly one line: $(cat "$out")"
  assert_contains "$(cat "$wakeq" 2>/dev/null)" "check: mail 77" "the queued recovery wake is still present"
  chmod 0600 "$home/state/.mail-retry"
  pass "fm-mail-check: a repeated status-4 fail-closed poll still wakes"
}

test_repeated_status2_stays_queued_still_wakes() {
  # Status 2: the wake stays queued with no durable record and no woke-for line.
  # A second identical diagnostic must still print.
  local tmpbin home out check_bin
  tmpbin="$TMP_ROOT/repeat-status2/bin"
  home="$TMP_ROOT/repeat-status2/home"
  mkdir -p "$tmpbin" "$home/state"
  check_bin="$tmpbin/fm-mail-check.sh"
  cp "$ROOT/bin/fm-mail-check.sh" "$tmpbin/"
  for lib in fm-timeout-lib.sh fm-duration-lib.sh fm-duration.py fm-pr-lib.sh fm-file-identity-lib.sh fm-line-cap-lib.sh fm-check-lib.sh; do
    [ -e "$tmpbin/$lib" ] || ln -s "$ROOT/bin/$lib" "$tmpbin/$lib"
  done
  cat > "$tmpbin/fm-mail.sh" <<EOF
#!/usr/bin/env bash
printf '1\t1\tcheck\tmail:9\tcheck: mail 9 - stays queued\\n' >> "\$FM_HOME/state/.wake-queue"
echo "fm-mail: wake for 9 could not be rolled back or durably recorded; the wake stays queued and the next poll heals it - a possible duplicate, never a lost mail" >&2
exit 1
EOF
  chmod +x "$tmpbin/fm-mail.sh"

  out="$home/out1.txt"
  run_check "$home" "$out" "$check_bin"
  assert_contains "$(cat "$out")" "the wake stays queued" "the first status-2 poll reports that the wake stays queued"

  out="$home/out2.txt"
  run_check "$home" "$out" "$check_bin"
  assert_contains "$(cat "$out")" "the wake stays queued" "a repeated status-2 poll still prints so the queued mail is not stranded"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "the repeat report is exactly one line: $(cat "$out")"
  pass "fm-mail-check: a repeated status-2 stays-queued poll still wakes"
}

test_repeated_heal_failure_stays_silent() {
  # Heal failure happens before wake_for: no queued mail and no .mail-woken
  # growth. The first standing check reports it; a repeated identical
  # pre-wake failure must stay silent.
  local home out
  home=$(make_home heal-fail)
  write_env "$home"
  enter_mailbox "$home" \
    'printf "uidvalidity\\t90009\\n"'
  printf 'uidvalidity=90009\n' > "$home/state/.mail-seen"
  printf '%s\t%s\n' '90009' '55' > "$home/state/.mail-woken"
  chmod 0400 "$home/state/.mail-seen"

  out="$home/out1.txt"
  run_check "$home" "$out" "$CHECK"
  assert_contains "$(cat "$out")" "mail: heal could not record a uid" "the first heal failure reports"

  out="$home/out2.txt"
  run_check "$home" "$out" "$CHECK"
  [ ! -s "$out" ] || fail "a repeated pre-wake heal failure must stay silent: $(cat "$out")"
  chmod 0600 "$home/state/.mail-seen"
  pass "fm-mail-check: a repeated pre-wake heal failure stays silent"
}

test_missing_mail_plane_is_reported() {
  local tmpbin home out check_bin
  tmpbin="$TMP_ROOT/plane2/bin"
  home="$TMP_ROOT/plane2/home"
  mkdir -p "$tmpbin" "$home/state"
  check_bin="$tmpbin/fm-mail-check.sh"
  cp "$ROOT/bin/fm-mail-check.sh" "$tmpbin/"
  for lib in fm-timeout-lib.sh fm-duration-lib.sh fm-duration.py fm-pr-lib.sh fm-file-identity-lib.sh fm-line-cap-lib.sh fm-check-lib.sh; do
    [ -e "$tmpbin/$lib" ] || ln -s "$ROOT/bin/$lib" "$tmpbin/$lib"
  done
  out="$home/out.txt"
  run_check "$home" "$out" "$check_bin"
  assert_contains "$(cat "$out")" "mail: fm-mail.sh is missing next to this check" "a home lacking the mail plane reports it"
  pass "fm-mail-check: a missing mail plane is reported, not assumed"
}

test_help_and_usage
test_arm_writes_and_binds_the_check_and_disarm_removes_it
test_arm_resolves_a_relative_home_into_the_shim
test_arm_refuses_a_symlink_at_the_shim_path
test_arm_refuses_without_the_mail_plane
test_successful_poll_with_new_mail_emits_one_wake_line
test_failure_is_reported_once_until_it_changes
test_unconfigured_home_is_reported_once
test_silent_poll_is_unknown_and_retried
test_repeated_timeout_still_wakes
test_watcher_stopped_poll_rings_queued_mail_next_pass
test_idle_poll_within_its_measured_bound_succeeds
test_progressing_poll_survives_fivefold_slowdown
test_fail_closed_poll_after_wake_reports_the_failure
test_repeated_status4_fail_closed_still_wakes
test_repeated_status2_stays_queued_still_wakes
test_repeated_failure_that_queued_new_mail_still_wakes
test_large_poll_output_is_drained
test_repeated_heal_failure_stays_silent
test_missing_mail_plane_is_reported