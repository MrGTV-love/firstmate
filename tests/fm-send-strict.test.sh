#!/usr/bin/env bash
# fm-send strict target resolution and key delivery reporting.
#
# A send that cannot be tied to a recorded task/lane or to an explicit
# well-formed backend target must fail loudly. These tests pin the historical
# silent-fallback failures: missing FM_HOME, unresolved selectors, prefixless
# herdr pane ids, dead explicit endpoints, and the healthy exact/fm-id paths.
# They also verify that a key send reports whether delivery actually succeeded.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-strict)

make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "${1:-}" >> "$FM_TMUX_LOG"
    # FM_FAKE_TMUX_SEND_KEY_FAIL names one key whose delivery fails, so the
    # --key exit contract can be driven both ways from the same stub.
    if [ "$literal" = 0 ] && [ -n "${FM_FAKE_TMUX_SEND_KEY_FAIL:-}" ] \
      && [ "${1:-}" = "$FM_FAKE_TMUX_SEND_KEY_FAIL" ]; then
      exit 1
    fi
    exit 0 ;;
  display-message)
    target=
    cursor=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        *cursor_y*) cursor=1; shift ;;
        *) shift ;;
      esac
    done
    if [ -n "${FM_FAKE_TMUX_DEAD_TARGET:-}" ] && [ "$target" = "$FM_FAKE_TMUX_DEAD_TARGET" ]; then
      exit 1
    fi
    [ "$cursor" = 1 ] && { printf '1\n'; exit 0; }
    printf '%%1\n'
    exit 0 ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
  list-windows)
    printf 'foreign:%s\nfm-mpf-lane-m8\nfm-lane-key\nfm-lane-ok\n' \
      "${FM_FAKE_TMUX_WINDOW:-fm-lost}"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_HERDR_LOG"
case "${1:-} ${2:-}" in
  "status --json") printf '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true}}\n' ;;
  "pane get") printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;;
  "pane send-keys") : ;;
esac
SH
  chmod +x "$fb/herdr"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_home() {  # <name> -> echoes home dir
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

test_exact_lane_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/exact"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home exact); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/mpf-lane-m8.meta" "window=sess:fm-mpf-lane-m8" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" mpf-lane-m8 "lost dispatch" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "exact task id send should succeed when metadata exists"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=1 arg=: Firstmate instruction waiting" \
    "exact id should ring the doorbell at the meta target"
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=0 arg=Enter" "exact id should submit the doorbell with Enter"
  grep -qF 'lost dispatch' "$home/state/mpf-lane-m8.inbox/001.msg" \
    || fail "exact id should record the steer in the task inbox"
  pass "fm-send strict: exact task/lane ids resolve through home metadata"
}

test_unset_fm_home_fails() {
  local dir fb err log rc
  dir="$TMP_ROOT/nohome"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  : > "$dir/guard-events.jsonl"
  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    FM_GUARD_EVENT_LOG="$dir/guard-events.jsonl" \
    "$SEND" sess:win "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unset FM_HOME should fail"
  assert_contains "$(cat "$err")" "FM_HOME is not set" "unset FM_HOME diagnostic should be explicit"
  assert_contains "$(cat "$err")" "FM_HOME=<home> bin/fm-send.sh" \
    "unset FM_HOME diagnostic should show the working invocation"
  [ "$(grep -c '"guard":"send-home-fail-closed".*"decision":"deny"' "$dir/guard-events.jsonl")" -eq 1 ] \
    || fail "unset FM_HOME refusal should append exactly one deny event"
  [ ! -s "$log" ] || fail "unset FM_HOME still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unset FM_HOME fails before target resolution"
}

# Help is a read: it prints usage and sends nothing, so it must not need a home.
# The FM_HOME refusal exists to stop a send that resolves a target against the
# wrong home; a leading --help or -h resolves nothing. Only that leading word is
# help: the same word after a target is message text and meets every refusal.
test_leading_help_prints_usage_without_a_home() {
  local dir fb err out log events rc flag label
  dir="$TMP_ROOT/help-nohome"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/send.err"; log="$dir/tmux.log"; events="$dir/guard-events.jsonl"

  for flag in --help -h; do
    for label in unset empty; do
      : > "$log"; : > "$events"
      if [ "$label" = unset ]; then
        out=$(env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" FM_GUARD_EVENT_LOG="$events" \
          "$SEND" "$flag" 2>"$err"); rc=$?
      else
        out=$(PATH="$fb:$PATH" FM_HOME='' FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" FM_GUARD_EVENT_LOG="$events" \
          "$SEND" "$flag" 2>"$err"); rc=$?
      fi
      expect_code 0 "$rc" "$flag with FM_HOME $label should exit 0"
      assert_contains "$out" "Usage: fm-send.sh <target>" "$flag with FM_HOME $label should print the usage"
      [ ! -s "$err" ] || fail "$flag with FM_HOME $label should print nothing on stderr"$'\n'"$(cat "$err")"
      [ ! -s "$log" ] || fail "$flag with FM_HOME $label touched the terminal"$'\n'"$(cat "$log")"
      [ "$(grep -c '"guard":"send-home-fail-closed"' "$events")" -eq 0 ] \
        || fail "$flag with FM_HOME $label should record no FM_HOME refusal"$'\n'"$(cat "$events")"
    done
  done
  pass "fm-send help: a leading --help or -h prints usage and exits 0 without FM_HOME"
}

test_help_is_refused_for_a_gate_agent_like_a_send() {
  local dir fb err out log rc flag
  dir="$TMP_ROOT/help-gate"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  for flag in --help -h; do
    out=$(env -u FM_HOME -u FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE=1 PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" \
      "$SEND" "$flag" 2>"$err"); rc=$?
    expect_code 3 "$rc" "$flag from a gate agent should keep the gate refusal"
    assert_contains "$(cat "$err")" "no-mistakes gate agent must not drive the fleet (NO_MISTAKES_GATE set)" \
      "$flag from a gate agent should keep the gate refusal message"
    [ -z "$out" ] || fail "$flag from a gate agent must print no usage"
  done

  env -u FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE=1 FM_HOME="$dir" PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" \
    "$SEND" sess:win "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a send from a gate agent must stay refused"
  assert_contains "$(cat "$err")" "no-mistakes gate agent must not drive the fleet" "the gate refusal should be unchanged"
  [ ! -s "$log" ] || fail "a refused gate send still touched the terminal"
  pass "fm-send help: a gate agent's --help and -h stay refused as on base"
}

test_help_word_after_a_target_is_text_and_keeps_the_home_check() {
  local dir fb err log events rc args
  dir="$TMP_ROOT/help-after"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/send.err"; log="$dir/tmux.log"; events="$dir/guard-events.jsonl"

  for args in "sess:win --help" "sess:win -h" "sess:win hello --help" "sess:win -- --help"; do
    : > "$log"; : > "$events"
    # shellcheck disable=SC2086 # the case strings are word lists on purpose
    env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 FM_GUARD_EVENT_LOG="$events" \
      "$SEND" $args >"$dir/send.out" 2>"$err"; rc=$?
    [ "$rc" -eq 1 ] || fail "'$args' without FM_HOME should fail closed with 1, got $rc"
    assert_contains "$(cat "$err")" "error: FM_HOME is not set; fm-send refuses to resolve targets without an explicit firstmate home" \
      "'$args' should keep the FM_HOME refusal message"
    [ ! -s "$dir/send.out" ] || fail "'$args' without FM_HOME must print no usage on stdout"
    [ "$(grep -c '"guard":"send-home-fail-closed".*"decision":"deny"' "$events")" -eq 1 ] \
      || fail "'$args' without FM_HOME should append exactly one deny event"
    [ ! -s "$log" ] || fail "'$args' without FM_HOME attempted a send"$'\n'"$(cat "$log")"
  done
  pass "fm-send help: --help after a target is not help and keeps the FM_HOME refusal"
}

# The explicit-home guard records its allow for every send it admits, also one whose
# target then does not resolve, as on base (where the allow was written right after the
# FM_HOME check). So deny, allow, deny reads as a cleared refusal and one recurrence in
# bin/fm-guard-metrics.sh, not as two denies in a row.
test_home_guard_allow_is_recorded_for_an_unresolvable_target() {
  local dir fb home err log events rc decisions out
  dir="$TMP_ROOT/home-guard-seq"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home home-guard-seq); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  events="$dir/guard-events.jsonl"; : > "$events"
  env -u FM_HOME -u FM_TASK_ID PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    FM_GUARD_EVENT_LOG="$events" "$SEND" lost-target "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unset FM_HOME should fail"
  env -u FM_TASK_ID PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_WINDOW=lost-target \
    FM_SEND_SETTLE=0 FM_GUARD_EVENT_LOG="$events" "$SEND" lost-target "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an unresolvable target should fail"
  assert_contains "$(cat "$err")" "not resolvable" "the second send fails at target resolution"
  env -u FM_HOME -u FM_TASK_ID PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    FM_GUARD_EVENT_LOG="$events" "$SEND" lost-target "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unset FM_HOME should fail again"
  decisions=$(grep '"guard":"send-home-fail-closed"' "$events" | grep -o '"decision":"[a-z]*"' | tr '\n' ' ')
  assert_equals '"decision":"deny" "decision":"allow" "decision":"deny" ' "$decisions" "the recorded sequence is deny, allow, deny"
  out=$("$ROOT/bin/fm-guard-metrics.sh" --log "$events" --registry "$ROOT/docs/guards/registry.json" \
    --guards send-home-fail-closed --min-opportunities 1 2>&1)
  assert_contains "$out" "recurrences=1" "the metrics reader sees the allow clear the first deny: $out"
  [ ! -s "$log" ] || fail "no send reached the transport"$'\n'"$(cat "$log")"

  # The same sequence with no arguments at all: base recorded the allow before it
  # read the target, so deny / no-argument send / deny is one recurrence too. With
  # no task the event identity is the home plus the harness session
  # (bin/fm-guard-event.sh): the denied sends name the same home through FM_ROOT,
  # as a home whose firstmate checkout is the home itself does, and one session id
  # is pinned for all three.
  events="$dir/guard-events-noarg.jsonl"; : > "$events"
  env -u FM_HOME -u FM_TASK_ID PATH="$fb:$PATH" FM_ROOT="$home" FM_ROOT_OVERRIDE="$home" FM_SESSION_ID=noarg-seq \
    FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 FM_GUARD_EVENT_LOG="$events" "$SEND" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unset FM_HOME with no arguments should fail"
  env -u FM_TASK_ID PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SESSION_ID=noarg-seq FM_TMUX_LOG="$log" \
    FM_SEND_SETTLE=0 FM_GUARD_EVENT_LOG="$events" "$SEND" >/dev/null 2>"$err"; rc=$?
  expect_code 1 "$rc" "a send with no arguments exits 1, as on base"
  assert_contains "$(cat "$err")" "usage: FM_HOME=<home> bin/fm-send.sh <task> <message>" "the no-argument send prints the usage"
  env -u FM_HOME -u FM_TASK_ID PATH="$fb:$PATH" FM_ROOT="$home" FM_ROOT_OVERRIDE="$home" FM_SESSION_ID=noarg-seq \
    FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 FM_GUARD_EVENT_LOG="$events" "$SEND" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unset FM_HOME with no arguments should fail again"
  decisions=$(grep '"guard":"send-home-fail-closed"' "$events" | grep -o '"decision":"[a-z]*"' | tr '\n' ' ')
  assert_equals '"decision":"deny" "decision":"allow" "decision":"deny" ' "$decisions" "the no-argument sequence is deny, allow, deny"
  out=$("$ROOT/bin/fm-guard-metrics.sh" --log "$events" --registry "$ROOT/docs/guards/registry.json" \
    --guards send-home-fail-closed --min-opportunities 1 2>&1)
  assert_contains "$out" "recurrences=1" "the metrics reader sees the no-argument allow clear the first deny: $out"
  [ ! -s "$log" ] || fail "no no-argument send reached the transport"$'\n'"$(cat "$log")"
  pass "fm-send strict: the explicit-home allow is recorded for an unresolvable target and for a send with no arguments, so deny/allow/deny reads as one recurrence"
}

test_unresolvable_target_does_not_tmux_fallback() {
  local dir fb home err log rc
  dir="$TMP_ROOT/unresolved"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home unresolved); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_WINDOW=lost-target FM_SEND_SETTLE=0 \
    "$SEND" lost-target "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unresolvable target should fail"
  assert_contains "$(cat "$err")" "not resolvable" "unresolvable diagnostic should be loud"
  assert_contains "$(cat "$err")" "metadata window/terminal lookup" "unresolvable diagnostic should name the attempted lookup"
  assert_contains "$(cat "$err")" "backend=none" "unresolvable diagnostic should name that no backend was assumed"
  [ ! -s "$log" ] || fail "unresolvable target fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unresolvable selectors do not fall back to tmux"
}

test_prefixless_herdr_pane_id_fails() {
  local dir fb home err log rc
  dir="$TMP_ROOT/herdr-pane"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home herdr); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/nudge.meta" \
    "window=default:wB:p2" "backend=herdr" "herdr_session=default" "herdr_pane_id=wB:p2" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" wB:p2 "nudge" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "prefixless herdr pane id should fail"
  assert_contains "$(cat "$err")" "matches herdr_pane_id" "herdr pane diagnostic should name the meta match"
  assert_contains "$(cat "$err")" "expected <herdr-session>:<pane-id>" "herdr pane diagnostic should show expected shape"
  assert_contains "$(cat "$err")" "default:wB:p2" "herdr pane diagnostic should show the canonical target"
  [ ! -s "$log" ] || fail "prefixless herdr pane id fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: prefixless herdr pane ids are rejected before tmux fallback"
}

test_unmatched_single_colon_target_must_exist() {
  local dir fb home err log rc
  dir="$TMP_ROOT/dead-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home deadexplicit); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_DEAD_TARGET=sess:missing FM_SEND_SETTLE=0 \
    "$SEND" sess:missing "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "dead explicit tmux-shaped target should fail"
  assert_contains "$(cat "$err")" "not a live tmux endpoint" "dead explicit target diagnostic should name the assumed backend"
  assert_contains "$(cat "$err")" "backend=tmux" "dead explicit target diagnostic should name the tried backend"
  [ ! -s "$log" ] || fail "dead explicit target still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unmatched single-colon explicit targets must verify live before sending"
}

test_fm_prefixed_herdr_session_is_an_explicit_target() {
  local dir fb home err log herdr_log rc
  dir="$TMP_ROOT/fm-remote-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home fmremote); err="$dir/send.err"; log="$dir/tmux.log"; herdr_log="$dir/herdr.log"
  : > "$log"
  : > "$herdr_log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_HERDR_LOG="$herdr_log" FM_SEND_SETTLE=0 \
    "$SEND" fm-remote:w1:p2 --key Enter >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "an fm-prefixed Herdr session target should be accepted as explicit"
  assert_grep 'pane get w1:p2 --session fm-remote' "$herdr_log" "fm-prefixed Herdr target was not verified in its session"
  assert_grep 'pane send-keys w1:p2 enter --session fm-remote' "$herdr_log" "fm-prefixed Herdr target was not sent its key in its session"
  assert_no_grep '--session default' "$herdr_log" "fm-prefixed Herdr target fell back to the default session"
  pass "fm-send strict: fm-prefixed Herdr sessions remain explicit backend targets"
}

test_healthy_fm_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/healthy"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home healthy); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-ok.meta" "window=sess:fm-lane-ok" "kind=ship" "harness=codex"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" fm-lane-ok "hello captain" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "healthy fm-id send should succeed"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-lane-ok literal=1 arg=: Firstmate instruction waiting" \
    "healthy send should ring the doorbell at the meta target"
  assert_contains "$got" "target=sess:fm-lane-ok literal=0 arg=Enter" "healthy send should submit the doorbell with Enter"
  grep -qF 'hello captain' "$home/state/lane-ok.inbox/001.msg" \
    || fail "healthy send should record the steer in the task inbox"
  assert_contains "$(cat "$err")" "requested message WILL still be sent" "fm-send guard banner should keep send-specific continuation wording"
  pass "fm-send strict: healthy fm-<id> sends record the steer and ring once"
}

# A --key send is how firstmate interrupts a worker, so its exit status is the
# only signal that the interrupt actually landed.
# Reporting success for a key that was never delivered would leave supervision
# believing a runaway worker had been stopped, so the failing case must exit
# nonzero and name the key.
# Both directions are asserted from one stub so the failing case cannot go
# quietly vacuous if the key ever stops being delivered at all.
test_key_send_exit_status_follows_delivery() {
  local dir fb home err log rc
  dir="$TMP_ROOT/key-exit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home keyexit); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-key.meta" "window=sess:fm-lane-key" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" lane-key --key Escape >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "a delivered --key interrupt should report success"
  assert_contains "$(cat "$log")" "target=sess:fm-lane-key literal=0 arg=Escape" "the delivered case should send the named key"

  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    FM_FAKE_TMUX_SEND_KEY_FAIL=Escape \
    "$SEND" lane-key --key Escape >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an undelivered --key interrupt reported success"
  assert_contains "$(cat "$err")" "key 'Escape' not sent" "the undelivered case should name the key that failed"
  assert_contains "$(cat "$log")" "target=sess:fm-lane-key literal=0 arg=Escape" "the undelivered case should still have attempted the send"
  pass "fm-send --key: exit status follows delivery, and an undelivered key never reports success"
}

test_exact_lane_id_send_still_works
test_key_send_exit_status_follows_delivery
test_unset_fm_home_fails
test_leading_help_prints_usage_without_a_home
test_help_is_refused_for_a_gate_agent_like_a_send
test_help_word_after_a_target_is_text_and_keeps_the_home_check
test_unresolvable_target_does_not_tmux_fallback
test_home_guard_allow_is_recorded_for_an_unresolvable_target
test_prefixless_herdr_pane_id_fails
test_unmatched_single_colon_target_must_exist
test_fm_prefixed_herdr_session_is_an_explicit_target
test_healthy_fm_id_send_still_works
