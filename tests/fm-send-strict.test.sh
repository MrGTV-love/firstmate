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
    printf 'foreign:%s\nfm-mpf-lane-m8\nfm-lane-key\nfm-lane-ok\nfm-fm-slack-main-window-intake\nfm-other\nfm-fm-mini\n' \
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

test_task_owner_mismatch_is_refused() {
  local dir fb home log err rc target
  for target in fm-mini another-worker; do
    dir="$TMP_ROOT/owner-mismatch-$target"; mkdir -p "$dir"
    fb=$(make_stubs "$dir"); home=$(setup_home "$target"); log="$dir/send.log"; err="$dir/send.err"
    : > "$log"
    fm_write_meta "$home/state/fm-slack-main-window-intake.meta" \
      "window=sess:fm-fm-slack-main-window-intake" "kind=ship" "harness=claude"
    if [ "$target" = fm-mini ]; then
      fm_write_secondmate_meta "$home/state/$target.meta" "$home" "sess:fm-$target"
    else
      fm_write_meta "$home/state/$target.meta" "window=sess:fm-$target" "kind=ship"
    fi
    printf 'needs-decision [key=dependency]: waiting for approved input\n' > "$home/state/$target.status"
    cp "$home/state/$target.status" "$dir/status-before"
    PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
      "$SEND" "$target" --resolve-key dependency \
      'Start the fix round for fm-slack-main-window-intake' > "$dir/send.out" 2> "$err"; rc=$?
    [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ] || fail "wrong-owner steer reported delivered or unconfirmed: $rc"
    assert_contains "$(cat "$err")" 'fm-slack-main-window-intake' "refusal must name the real owner"
    [ ! -s "$log" ] || fail "wrong-owner refusal typed into the target"
    [ ! -e "$home/state/$target.inbox" ] || fail "wrong-owner refusal enqueued a steer"
    [ ! -d "$home/state/pending-replies" ] || fail "wrong-owner refusal armed a reply expectation"
    cmp -s "$dir/status-before" "$home/state/$target.status" || fail "refusal answered the dependency"
    printf 'owner-mismatch target=%s exit=%s diagnostic=%s\n' "$target" "$rc" "$(cat "$err")"
  done
  pass "fm-send: a wrong worker or secondmate is refused before delivery or decision closure"
}

test_owner_relay_and_correct_owner() {
  local dir fb home log err rc text target body record
  dir="$TMP_ROOT/owner-allowed"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home allowed); log="$dir/send.log"; err="$dir/send.err"
  fm_write_meta "$home/state/fm-slack-main-window-intake.meta" \
    "window=sess:fm-fm-slack-main-window-intake" "kind=ship" "harness=claude"
  fm_write_meta "$home/state/other.meta" "window=sess:fm-other" "kind=ship"
  text=$'Start the fix round for\nfm-slack-main-window-intake'
  for target in fm-slack-main-window-intake fm-fm-slack-main-window-intake other; do
    : > "$log"
    set --
    [ "$target" != other ] || set -- --relay
    PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
      "$SEND" "$target" "$@" "$text" >/dev/null 2> "$err"; rc=$?
    expect_code 0 "$rc" "correct-owner and explicit-relay steers must send"
    case "$target" in fm-fm-*) target=${target#fm-} ;; esac
    for record in "$home/state/$target.inbox/"*.msg; do
      body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$record")
      [ "$body" = "$text" ] || fail "owner/relay send changed message bytes"
    done
    assert_contains "$(cat "$log")" 'Firstmate instruction waiting' "allowed steer must ring its durable record"
  done
  pass "fm-send: correct-owner selectors and explicit cross-task relays retain the message"
}

test_task_mentions_match_whole_tokens() {
  local dir fb home log err rc text
  dir="$TMP_ROOT/owner-tokens"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home tokens); log="$dir/send.log"; err="$dir/send.err"
  fm_write_meta "$home/state/task-one.meta" "window=sess:fm-task-one" "kind=ship"
  fm_write_meta "$home/state/other.meta" "window=sess:fm-other" "kind=ship"
  for text in 'task-one-longer' 'prefix-task-one' 'task-one.extension' 'task-not-owned-here' 'fm-task-one-longer' 'fm-other' 'review data/task-one/review.md'; do
    : > "$log"
    PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
      "$SEND" other "$text" >/dev/null 2> "$err"; rc=$?
    expect_code 0 "$rc" "a longer or unrecorded task id is not a local owner mismatch"
  done
  for text in '(task-one)' 'task-one,' $'next action:\ntask-one' 'mention task-one --relay in the body' 'fm-task-one' 'Resume fm-task-one.'; do
    : > "$log"
    PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
      "$SEND" other "$text" >/dev/null 2> "$err"; rc=$?
    [ "$rc" -ne 0 ] || fail "whole task token escaped ownership guard: $text"
    [ ! -s "$log" ] || fail "whole-token refusal sent input"
    assert_contains "$(cat "$err")" "Send to 'task-one'" "refusal must name the owner selector: $text"
  done
  pass "fm-send: whole task tokens and legacy labels reject; longer, unknown and path-embedded ids do not"
}

test_secondmate_own_task_and_relay_safety() {
  local dir fb home log err rc
  dir="$TMP_ROOT/owner-secondmate"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home secondmate); log="$dir/send.log"; err="$dir/send.err"
  mkdir -p "$dir/child/state"
  fm_write_secondmate_meta "$home/state/fm-mini.meta" "$dir/child" "sess:fm-fm-mini"
  fm_write_meta "$dir/child/state/child-task.meta" "window=child:fm-child-task" "kind=ship"
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    "$SEND" fm-mini 'Continue child-task' >/dev/null 2> "$err"; rc=$?
  expect_code 0 "$rc" "a secondmate child absent from parent direct reports is not a mismatch"
  assert_grep 'Continue child-task' "$home/state/fm-mini.inbox/001.msg" "secondmate must receive its child task request"
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    "$SEND" fm-mini --relay --resolve-key nonexistent 'answer' >/dev/null 2> "$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "relay bypassed missing decision refusal"
  [ ! -s "$log" ] || fail "relay delivered an invalid decision answer"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    "$SEND" fm-mini --relay ' ' >/dev/null 2> "$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "relay bypassed empty-message refusal"
  pass "fm-send: a secondmate's own child routes normally and relay grants no decision authority"
}

test_arbitrary_path_mentions_are_not_inputs() {
  local dir fb home log err rc text body
  dir="$TMP_ROOT/path-mentions"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home mentions); log="$dir/send.log"; err="$dir/send.err"
  fm_write_meta "$home/state/other.meta" "window=sess:fm-other" "kind=ship"
  fm_write_meta "$home/state/task-one.meta" "window=sess:fm-task-one" "kind=ship"
  text='Write output to /not-created/task-one/output.md; example /examples/task-one/example.md; the other computer has /Users/studio/task-one/report.md and C:\reports\task-one\report.md.'
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    "$SEND" other "$text" >/dev/null 2> "$err"; rc=$?
  expect_code 0 "$rc" "undeclared output, example and other-host paths are ordinary message text"
  body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$home/state/other.inbox/001.msg")
  [ "$body" = "$text" ] || fail "path mentions changed the delivered instruction"
  pass "fm-send: output, example and other-computer paths are not input declarations or task tokens"
}

test_declared_local_input_is_checked_without_grants() {
  local dir fb home log err rc worktree before after body
  dir="$TMP_ROOT/local-input"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home input); log="$dir/send.log"; err="$dir/send.err"
  worktree="$dir/task-copy"; mkdir -p "$worktree"
  fm_write_meta "$home/state/other.meta" "window=sess:fm-other" "kind=ship" "worktree=$worktree"
  printf 'needs-decision [key=dependency]: waiting for input\n' > "$home/state/other.status"
  cp "$home/state/other.status" "$dir/status-before"
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    "$SEND" other --relay --require-input "$worktree/required.md" --resolve-key dependency \
    'Use the declared report' >/dev/null 2> "$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a missing declared input was silently delegated"
  assert_contains "$(cat "$err")" "$worktree/required.md" "missing input report must name its artifact"
  assert_contains "$(cat "$err")" "receiver 'other'" "missing input report must name its receiver"
  [ ! -s "$log" ] || fail "missing input typed a doorbell"
  [ ! -f "$home/state/other.inbox/001.msg" ] || fail "missing input published an instruction"
  cmp -s "$dir/status-before" "$home/state/other.status" || fail "missing input closed a dependency"
  printf 'required report\n' > "$worktree/required.md"
  printf 'undeclared neighbor\n' > "$worktree/neighbor.md"
  chmod 600 "$worktree/required.md" "$worktree/neighbor.md"
  before=$(LC_ALL=C ls -ld "$worktree" "$worktree/required.md" "$worktree/neighbor.md")
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    "$SEND" other --require-input "$worktree/required.md" 'Use the declared report' >/dev/null 2> "$err"; rc=$?
  expect_code 0 "$rc" "an accessible input in the recorded task copy should send"
  after=$(LC_ALL=C ls -ld "$worktree" "$worktree/required.md" "$worktree/neighbor.md")
  [ "$before" = "$after" ] || fail "input validation changed artifact or parent access"
  [ ! -e "$worktree/state" ] || fail "input validation wrote operational state into the task copy"
  body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$home/state/other.inbox/001.msg")
  [ "$body" = 'Use the declared report' ] || fail "a declared input changed the delivered message: $body"
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    "$SEND" other --require-input "$worktree/required.md" '/review the declared report' >/dev/null 2> "$err"; rc=$?
  expect_code 0 "$rc" "a typed native command with an accessible declared input should send"
  [ "$(sed -n 's/^send-keys target=[^ ]* literal=1 arg=//p' "$log")" = '/review the declared report' ] \
    || fail "a declared input changed the typed native command"$'\n'"$(cat "$log")"
  [ ! -f "$home/state/other.inbox/002.msg" ] || fail "a typed native command was enqueued as a record"
  rm "$worktree/required.md"
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    "$SEND" other --require-input "$worktree/required.md" '/review the declared report' >/dev/null 2> "$err"; rc=$?
  [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ] || fail "a typed native command sent without its declared input: $rc"
  assert_contains "$(cat "$err")" "$worktree/required.md" "typed missing-input report must name its artifact"
  [ ! -s "$log" ] || fail "a typed native command was typed without its declared input"
  pass "fm-send: declared local inputs gate inbox and typed delivery without changing the message, permissions, or transfers"
}

fm_test_only

test_arbitrary_path_mentions_are_not_inputs
test_declared_local_input_is_checked_without_grants
test_task_owner_mismatch_is_refused
test_owner_relay_and_correct_owner
test_task_mentions_match_whole_tokens
test_secondmate_own_task_and_relay_safety
test_exact_lane_id_send_still_works
test_key_send_exit_status_follows_delivery
test_unset_fm_home_fails
test_unresolvable_target_does_not_tmux_fallback
test_prefixless_herdr_pane_id_fails
test_unmatched_single_colon_target_must_exist
test_fm_prefixed_herdr_session_is_an_explicit_target
test_healthy_fm_id_send_still_works
