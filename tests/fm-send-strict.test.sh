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
    printf 'foreign:%s\nfm-mpf-lane-m8\nfm-lane-key\nfm-lane-ok\nfm-fm-slack-main-window-intake\nfm-task-one\nfm-other\nfm-unmatched\nfm-fm-mini\n' \
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
  local dir fb home log err rc target owner text
  text='Start the fix round for fm-slack-main-window-intake'
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
      "$text" > "$dir/send.out" 2> "$err"; rc=$?
    [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ] || fail "wrong-owner steer reported delivered or unconfirmed: $rc"
    owner=$(sed -n "s/.*Send to '\([^']*\)'.*/\1/p" "$err")
    [ "$owner" = fm-slack-main-window-intake ] || fail "refusal must designate the usable owner, not merely echo a task id"
    [ ! -s "$log" ] || fail "wrong-owner refusal typed into the target"
    [ ! -e "$home/state/$target.inbox" ] || fail "wrong-owner refusal enqueued a steer"
    [ ! -d "$home/state/pending-replies" ] || fail "wrong-owner refusal armed a reply expectation"
    cmp -s "$dir/status-before" "$home/state/$target.status" || fail "refusal answered the dependency"
    printf 'owner-mismatch target=%s exit=%s diagnostic=%s\n' "$target" "$rc" "$(cat "$err")"
    PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
      "$SEND" "$owner" "$text" >/dev/null 2> "$err"; rc=$?
    expect_code 0 "$rc" "the designated owner must accept the same instruction"
    [ "$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$home/state/$owner.inbox/001.msg")" = "$text" ] \
      || fail "loop-back did not reach the designated owner's inbox unchanged"
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
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    "$SEND" other "$text" >/dev/null 2> "$err"; rc=$?
  [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ] || fail "the same deliberate mention without relay must be refused"
  assert_contains "$(cat "$err")" "Send to 'fm-slack-main-window-intake'" "relay negative must designate the actual owner"
  [ ! -e "$home/state/other.inbox" ] && [ ! -s "$log" ] || fail "relay negative delivered"
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
  local dir fb home log err rc text body sequence=0 record
  dir="$TMP_ROOT/owner-tokens"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home tokens); log="$dir/send.log"; err="$dir/send.err"
  fm_write_meta "$home/state/task-one.meta" "window=sess:fm-task-one" "kind=ship"
  fm_write_meta "$home/state/other.meta" "window=sess:fm-other" "kind=ship"
  fm_write_meta "$home/state/team_task.meta" "window=sess:fm-team_task" "kind=ship"
  fm_write_meta "$home/state/rel.v2.meta" "window=sess:fm-rel.v2" "kind=scout"
  fm_write_meta "$home/state/task7.meta" "window=sess:fm-task7" "kind=secondmate"
  for text in 'task-one-longer' 'prefix-task-one' 'task-one.extension' 'task-not-owned-here' 'fm-task-one-longer' 'fm-other' 'review data/task-one/review.md' 'prefix_team_task' 'rel.v2.extension' 'task71' 'C:\data\task-one\x.md'; do
    : > "$log"
    PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
      "$SEND" other "$text" >/dev/null 2> "$err"; rc=$?
    expect_code 0 "$rc" "a longer or unrecorded task id is not a local owner mismatch"
    sequence=$((sequence + 1)); printf -v record '%s/state/other.inbox/%03d.msg' "$home" "$sequence"
    body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$record")
    [ "$body" = "$text" ] || fail "successful whole-token control changed its body"
  done
  for text in '(task-one)' 'task-one,' $'next action:\ntask-one' 'mention task-one --relay in the body' 'fm-task-one' 'Resume fm-task-one.' 'The output path is "/tmp/generated task-one"; the example is "/tmp/example"; another host has "/remote/report".'; do
    : > "$log"
    PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
      "$SEND" other "$text" >/dev/null 2> "$err"; rc=$?
    [ "$rc" -ne 0 ] || fail "whole task token escaped ownership guard: $text"
    [ ! -s "$log" ] || fail "whole-token refusal sent input"
    assert_contains "$(cat "$err")" "Send to 'task-one'" "refusal must name the owner selector: $text"
  done
  for text in team_task rel.v2 task7; do
    : > "$log"
    PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
      "$SEND" other "Continue $text." >/dev/null 2> "$err"; rc=$?
    [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ] || fail "recorded id alphabet escaped guard: $text"
    assert_contains "$(cat "$err")" "Send to '$text'" "refusal must designate the whole recorded id"
    [ ! -s "$log" ] || fail "recorded id refusal typed text"
  done
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    "$SEND" other 'team_task then task-one' >/dev/null 2> "$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "multiple-owner steer escaped guard"
  assert_contains "$(cat "$err")" "Send to 'team_task'" "first mismatching mention must win"
  pass "fm-send: whole task tokens and legacy labels reject; longer, unknown and path-embedded ids do not"
}

test_mentions_match_the_recorded_id_spelling() {
  local dir fb home log err rc text body sequence=0 record dots
  dir="$TMP_ROOT/owner-case"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home ownercase); log="$dir/send.log"; err="$dir/send.err"
  fm_write_meta "$home/state/other.meta" "window=sess:fm-other" "kind=ship"
  fm_write_meta "$home/state/mini.meta" "window=sess:fm-mini" "kind=ship"
  dots=$(head -c 12 /dev/zero | tr '\0' '.')
  for text in 'Other tasks wait; continue.' 'OTHER.' "Other$dots" 'Mini, take the next step.' 'Fm-mini, take the next step.' "MINI$dots"; do
    : > "$log"
    PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
      "$SEND" other "$text" >/dev/null 2> "$err"; rc=$?
    expect_code 0 "$rc" "a token spelled unlike every recorded id is not a mention: $text ($(cat "$err"))"
    sequence=$((sequence + 1)); printf -v record '%s/state/other.inbox/%03d.msg' "$home" "$sequence"
    body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$record")
    [ "$body" = "$text" ] || fail "a differently spelled token changed the delivered body"
  done
  for text in 'mini, take the next step.' "mini$dots" 'fm-mini.'; do
    : > "$log"
    PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
      "$SEND" other "$text" >/dev/null 2> "$err"; rc=$?
    [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ] || fail "the exact recorded spelling escaped the ownership guard: $text"
    assert_contains "$(cat "$err")" "refused task 'mini'" "the refusal must name the recorded id: $text"
    [ ! -s "$log" ] || fail "an exact-spelling refusal typed text"
  done
  pass "fm-send: only the recorded id spelling is a task mention, in short and long dotted forms"
}

test_miscased_selector_keeps_its_own_mentions() {
  local dir fb home log err rc text record
  dir="$TMP_ROOT/owner-selector-case"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home selectorcase); log="$dir/send.log"; err="$dir/send.err"
  fm_write_meta "$home/state/other.meta" "window=sess:fm-other" "kind=ship"
  fm_write_meta "$home/state/mini.meta" "window=sess:fm-mini" "kind=ship"
  if [ ! -f "$home/state/OTHER.meta" ]; then
    : > "$log"
    PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
      "$SEND" Other 'Continue other. Report back.' >/dev/null 2> "$err"; rc=$?
    [ "$rc" -ne 0 ] || fail "a miscased selector resolved on a case-sensitive state directory"
    assert_contains "$(cat "$err")" "not resolvable" "a miscased selector must be refused as unresolved"
    [ ! -s "$log" ] || fail "an unresolved miscased selector typed text"
    for record in "$home/state/"*.inbox; do
      [ ! -e "$record" ] || fail "an unresolved miscased selector left a durable inbox: $record"
    done
    pass "fm-send: a miscased selector is refused as unresolved, with no effect, on a case-sensitive state directory"
    return 0
  fi
  text='Continue other. Report back.'
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" Other "$text" >/dev/null 2> "$err"; rc=$?
  expect_code 0 "$rc" "a selector that resolves to the task's own meta keeps its own mentions ($(cat "$err"))"
  for record in "$home/state/"*.inbox/001.msg; do
    [ "$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$record")" = "$text" ] \
      || fail "the miscased selector changed the delivered body"
  done
  assert_contains "$(cat "$log")" 'Firstmate instruction waiting' "the miscased selector must ring its durable record"
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" Other 'Continue mini.' >/dev/null 2> "$err"; rc=$?
  [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ] || fail "a miscased selector escaped the ownership guard for another task"
  assert_contains "$(cat "$err")" "Send to 'mini'" "the refusal must designate the recorded owner"
  [ ! -s "$log" ] || fail "a miscased-selector refusal typed text"
  pass "fm-send: a selector that names a task's own meta in another case keeps its mentions and its refusals"
}

test_secondmate_own_task_and_relay_safety() {
  local dir fb home log err rc body corr
  dir="$TMP_ROOT/owner-secondmate"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home secondmate); log="$dir/send.log"; err="$dir/send.err"
  mkdir -p "$dir/child/state"
  fm_write_secondmate_meta "$home/state/fm-mini.meta" "$dir/child" "sess:fm-fm-mini"
  fm_write_meta "$dir/child/state/child-task.meta" "window=child:fm-child-task" "kind=ship"
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    "$SEND" fm-mini 'Continue child-task' >/dev/null 2> "$err"; rc=$?
  expect_code 0 "$rc" "a secondmate child absent from parent direct reports is not a mismatch"
  body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$home/state/fm-mini.inbox/001.msg")
  corr=$(bash -c '. "$1"; fm_pending_reply_extract_corr "$2"' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$body")
  [ -n "$corr" ] || fail "secondmate request lost its correlation"
  [ "${body#*"corr=$corr "}" = 'Continue child-task' ] || fail "secondmate child instruction changed"
  assert_contains "$(cat "$log")" 'Firstmate instruction waiting' "secondmate child instruction must have its doorbell"
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
    FM_GUARD_EVENT_LOG="$home/state/guard-events.jsonl" \
    "$SEND" other --relay --require-input "$worktree/required.md" --resolve-key dependency \
    'Use the declared report' >/dev/null 2> "$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a missing declared input was silently delegated"
  assert_contains "$(cat "$err")" "$worktree/required.md" "missing input report must name its artifact"
  assert_contains "$(cat "$err")" "receiver 'other'" "missing input report must name its receiver"
  jq -es 'map(select(.guard == "send-task-prerequisites")) | length == 1 and .[0].decision == "deny" and .[0].rule == "required-input" and .[0].task == "other"' "$home/state/guard-events.jsonl" >/dev/null \
    || fail "missing local input must emit one receiver-attributed denial"
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

test_explicit_endpoint_ownership_and_guard_events() {
  local dir fb home log err events rc text body target mode
  dir="$TMP_ROOT/explicit-owner"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home explicit-owner)
  log="$dir/send.log"; err="$dir/send.err"; events="$dir/events.jsonl"
  fm_write_meta "$home/state/task-one.meta" "window=sess:fm-task-one" "kind=ship" "harness=claude"
  fm_write_meta "$home/state/other.meta" "window=sess:fm-other" "kind=ship" "harness=claude"
  printf 'needs-decision [key=dependency]: waiting for approved input\n' > "$home/state/other.status"
  cp "$home/state/other.status" "$dir/status-before"
  for mode in explicit typed fire-and-forget; do
    target=other; text='Continue task-one and task-one'; set --
    case "$mode" in
      explicit) target=sess:fm-unmatched ;;
      typed) text='/review task-one and task-one' ;;
      fire-and-forget)
        fm_write_secondmate_meta "$home/state/other.meta" "$home" "sess:fm-other"
        set -- --fire-and-forget 0123456789abcdef ;;

    esac
    : > "$log"; : > "$events"
    PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
      FM_GUARD_EVENT_LOG="$events" "$SEND" "$target" "$@" "$text" > /dev/null 2> "$err"; rc=$?
    expect_code 1 "$rc" "$mode wrong-owner refusal must not report delivered-unconfirmed"
    [ ! -s "$log" ] || fail "$mode wrong-owner refusal reached backend"
    [ ! -d "$home/state/other.inbox" ] || fail "$mode refusal wrote an inbox"
    [ ! -d "$home/state/pending-replies" ] || fail "$mode refusal armed a pending reply"
    cmp -s "$dir/status-before" "$home/state/other.status" || fail "$mode refusal changed status"
    jq -es 'map(select(.guard == "send-task-prerequisites")) | length == 1 and .[0].decision == "deny" and .[0].task == "task-one" and .[0].override == false' "$events" >/dev/null \
      || fail "$mode refusal must emit exactly one attributed deny"
    : > "$log"; : > "$events"
    PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
      FM_GUARD_EVENT_LOG="$events" "$SEND" "$target" --relay "$@" "$text" > /dev/null 2> "$err"; rc=$?
    expect_code 0 "$rc" "$mode deliberate relay should send"
    jq -es 'map(select(.guard == "send-task-prerequisites")) | length == 1 and .[0].decision == "bypass" and .[0].task == "task-one" and .[0].override == true' "$events" >/dev/null \
      || fail "$mode relay must emit exactly one attributed bypass despite repeated mentions"
    if [ "$mode" = fire-and-forget ]; then
      body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$home/state/other.inbox/001.msg")
      case "$body" in
        *" $text") : ;;
        *) fail "fire-and-forget relay changed message" ;;
      esac
    else
      [ "$(sed -n 's/^send-keys target=[^ ]* literal=1 arg=//p' "$log")" = "$text" ] \
        || fail "$mode relay changed typed text"
    fi
  done
  : > "$log"; : > "$events"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    FM_GUARD_EVENT_LOG="$events" "$SEND" sess:fm-task-one 'Continue task-one' >/dev/null 2> "$err"; rc=$?
  expect_code 0 "$rc" "the owner's recorded endpoint must send unchanged"
  [ "$(sed -n 's/^send-keys target=[^ ]* literal=1 arg=//p' "$log")" = 'Continue task-one' ] \
    || fail "owner endpoint changed message"
  [ ! -d "$home/state/task-one.inbox" ] || fail "owner endpoint changed the typed plane"
  jq -es 'map(select(.guard == "send-task-prerequisites")) | length == 0' "$events" >/dev/null \
    || fail "correct owner emitted an ownership decision"
  : > "$events"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    FM_GUARD_EVENT_LOG="$events" "$SEND" other --relay 'no recorded task mention' >/dev/null 2> "$err"; rc=$?
  expect_code 0 "$rc" "unneeded relay must still send"
  jq -es 'map(select(.guard == "send-task-prerequisites")) | length == 0' "$events" >/dev/null \
    || fail "unneeded relay emitted bypass"
  : > "$events"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    FM_GUARD_EVENT_LOG="$events" "$SEND" other --relay --resolve-key nonexistent 'Continue task-one' >/dev/null 2> "$err"; rc=$?
  expect_code 1 "$rc" "relay must not escape the earlier decision guard"
  jq -es 'map(select(.guard == "send-task-prerequisites")) | length == 0' "$events" >/dev/null \
    || fail "an earlier refusal emitted an ownership escape"
  pass "fm-send: explicit, typed and fire-and-forget mismatches emit one deny or effective escape; owner and earlier guards stay intact"
}

test_relay_survives_unavailable_event_writer() {
  local dir fb home log err rc writer body bells baseline_body='' baseline_bells='' baseline_owner='' baseline_input='' baseline_owner_rc=0 line events
  dir="$TMP_ROOT/writer-failure"; mkdir -p "$dir/copy"
  events="$dir/events.jsonl"
  cp -R "$ROOT/bin" "$dir/copy/bin"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  for writer in executable unavailable failed; do
    home=$(setup_home "writer-$writer")
    fm_write_meta "$home/state/task-one.meta" "window=sess:fm-task-one" "kind=ship"
    fm_write_meta "$home/state/other.meta" "window=sess:fm-other" "kind=ship"
    printf 'done: previous instruction completed\n' > "$home/state/task-one.status"
    printf 'done: previous instruction completed\n' > "$home/state/other.status"
    [ "$writer" != unavailable ] || chmod -x "$dir/copy/bin/fm-guard-event.sh"
    if [ "$writer" = failed ]; then
      printf '#!/usr/bin/env bash\nexit 7\n' > "$dir/copy/bin/fm-guard-event.sh"
      chmod +x "$dir/copy/bin/fm-guard-event.sh"
    fi
    : > "$log"; : > "$events"
    PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 FM_GUARD_EVENT_LOG="$events" \
      "$dir/copy/bin/fm-send.sh" other --relay 'Continue task-one' >/dev/null 2> "$err"; rc=$?
    expect_code 0 "$rc" "writer availability must not change relay exit"
    body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$home/state/other.inbox/001.msg")
    bells=$(cat "$log"); bells=${bells//"$home"/HOME}
    if [ "$writer" = executable ]; then
      baseline_body=$body; baseline_bells=$bells
      assert_contains "$bells" 'Firstmate instruction waiting' "baseline must actually ring"
    else
      [ "$body" = "$baseline_body" ] || fail "unavailable writer changed durable record"
      [ "$bells" = "$baseline_bells" ] || fail "unavailable writer changed doorbell"
    fi
    : > "$log"
    PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_GUARD_EVENT_LOG="$events" \
      "$dir/copy/bin/fm-send.sh" other 'Continue task-one' >/dev/null 2> "$err"; rc=$?
    [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ] || fail "writer outage bypassed ownership refusal"
    line=$(sed -n '/^error: refused task /p' "$err")
    if [ "$writer" = executable ]; then baseline_owner=$line; baseline_owner_rc=$rc; else
      expect_code "$baseline_owner_rc" "$rc" "writer outage must preserve ownership exit"
      [ "$line" = "$baseline_owner" ] || fail "writer outage changed ownership refusal"
    fi
    [ ! -s "$log" ] && [ ! -f "$home/state/other.inbox/002.msg" ] || fail "writer outage bypassed owner guard"
    PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_GUARD_EVENT_LOG="$events" \
      "$dir/copy/bin/fm-send.sh" other --require-input missing.md 'Use input' >/dev/null 2> "$err"; rc=$?
    expect_code 4 "$rc" "writer outage must preserve declared-input refusal"
    line=$(sed -n '/^error: refused required input /p' "$err")
    if [ "$writer" = executable ]; then baseline_input=$line; else
      [ "$line" = "$baseline_input" ] || fail "writer outage changed input refusal"
      [ ! -s "$events" ] || fail "unavailable or failing writer unexpectedly wrote an event"
    fi
    [ ! -s "$log" ] && [ ! -f "$home/state/other.inbox/002.msg" ] || fail "writer outage bypassed input guard"
  done
  pass "fm-send: unavailable and failing telemetry writers preserve relay delivery and ownership/input refusals"
}

test_shared_endpoint_accepts_each_recorded_owner() {
  local dir fb home log err events rc text
  dir="$TMP_ROOT/shared-owner"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home shared)
  log="$dir/send.log"; err="$dir/send.err"; events="$dir/events.jsonl"
  fm_write_meta "$home/state/task-one.meta" "window=sess:fm-task-one" "kind=ship"
  fm_write_meta "$home/state/task-two.meta" "window=sess:fm-task-one" "kind=scout"
  fm_write_meta "$home/state/other.meta" "window=sess:fm-other" "kind=ship"
  for text in 'Continue task-one' 'Continue task-two'; do
    : > "$log"; : > "$events"
    PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
      FM_GUARD_EVENT_LOG="$events" "$SEND" sess:fm-task-one "$text" >/dev/null 2> "$err"; rc=$?
    expect_code 0 "$rc" "shared explicit endpoint owns either recorded task: $text"
    [ "$(sed -n 's/^send-keys target=[^ ]* literal=1 arg=//p' "$log")" = "$text" ] \
      || fail "shared endpoint changed typed text"
    jq -es 'map(select(.guard == "send-task-prerequisites")) | length == 0' "$events" >/dev/null \
      || fail "shared owner emitted an ownership event"
  done
  : > "$log"; : > "$events"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    FM_GUARD_EVENT_LOG="$events" "$SEND" sess:fm-task-one 'Continue other' >/dev/null 2> "$err"; rc=$?
  expect_code 1 "$rc" "shared endpoint does not own a task recorded elsewhere"
  assert_contains "$(cat "$err")" "Send to 'other'" "shared endpoint refusal designates the different owner"
  [ ! -s "$log" ] || fail "shared endpoint mismatch typed text"
  pass "fm-send: a shared explicit endpoint accepts either owner but refuses a different endpoint's task"
}

test_missing_inputs_report_all_without_inbox_trace() {
  local dir fb home log err rc existing input
  dir="$TMP_ROOT/input-refusal"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home input-refusal)
  log="$dir/send.log"; err="$dir/send.err"
  fm_write_meta "$home/state/other.meta" "window=sess:fm-other" "kind=ship"
  for existing in no yes; do
    if [ "$existing" = yes ]; then
      mkdir -p "$home/state/other.inbox"
      printf 'schema=fm-task-inbox.v1\nat=2020-01-01T00:00:00Z\n--\nprevious' > "$home/state/other.inbox/007.msg"
      cp "$home/state/other.inbox/007.msg" "$dir/before.msg"
    fi
    : > "$log"
    PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
      "$SEND" other --require-input first.md --require-input middle.md --require-input last.md \
      'Use the required inputs' >/dev/null 2> "$err"; rc=$?
    expect_code 4 "$rc" "declared input refusal has a distinct documented status"
    for input in first.md middle.md last.md; do
      assert_contains "$(cat "$err")" "$input" "every missing declaration must be reported"
    done
    assert_contains "$(cat "$err")" "receiver 'other'" "input report names receiver"
    assert_not_contains "$(cat "$err")" 'inbox record could not be written' "input refusal must not claim a write failure"
    [ ! -s "$log" ] || fail "missing inputs reached backend"
    if [ "$existing" = no ]; then
      [ ! -e "$home/state/other.inbox" ] || fail "refusal created target inbox"
    else
      cmp -s "$dir/before.msg" "$home/state/other.inbox/007.msg" || fail "refusal changed earlier record"
      [ ! -e "$home/state/other.inbox/handled" ] || fail "refusal created handled directory"
      [ "$(find "$home/state/other.inbox" -mindepth 1 | wc -l | tr -d ' ')" = 1 ] || fail "refusal left extra inbox entries"
    fi
  done
  for input in first.md middle.md last.md; do printf 'input\n' > "$home/$input"; done
  existing=8
  for input in first.md middle.md last.md; do
    rm "$home/$input"; : > "$log"
    PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
      "$SEND" other --require-input "$home/first.md" --require-input "$home/middle.md" --require-input "$home/last.md" \
      'Use all three inputs' >/dev/null 2> "$err"; rc=$?
    expect_code 4 "$rc" "a missing declaration at each position must refuse"
    assert_contains "$(cat "$err")" "$home/$input" "the missing position must be named"
    [ ! -s "$log" ] || fail "a missing later declaration reached the backend"
    [ ! -e "$home/state/other.inbox/$(printf '%03d' "$existing").msg" ] || fail "a missing later declaration published a record"
    printf 'input\n' > "$home/$input"
    PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
      "$SEND" other --require-input "$home/first.md" --require-input "$home/middle.md" --require-input "$home/last.md" \
      'Use all three inputs' >/dev/null 2> "$err"; rc=$?
    expect_code 0 "$rc" "every all-accessible twin must deliver"
    [ "$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$home/state/other.inbox/$(printf '%03d' "$existing").msg")" = 'Use all three inputs' ] \
      || fail "accessible input declarations changed the delivered body"
    existing=$((existing + 1))
  done
  pass "fm-send: all missing inputs report their own cause, status 4, and leave absent or existing inbox unchanged"
}

test_known_endpoint_accepts_declared_input() {
  local dir fb home log err rc text
  dir="$TMP_ROOT/endpoint-input"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home endpoint-input)
  log="$dir/send.log"; err="$dir/send.err"; text='/review the input'
  fm_write_meta "$home/state/other.meta" "window=sess:fm-other" "kind=ship"
  printf 'report\n' > "$home/input.md"
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:fm-other --require-input input.md "$text" >/dev/null 2> "$err"; rc=$?
  expect_code 0 "$rc" "known-owner explicit endpoint accepts input declaration"
  [ "$(sed -n 's/^send-keys target=[^ ]* literal=1 arg=//p' "$log")" = "$text" ] || fail "declared input changed endpoint text"
  rm "$home/input.md"; : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:fm-other --require-input input.md "$text" >/dev/null 2> "$err"; rc=$?
  expect_code 4 "$rc" "missing explicit-endpoint input refuses distinctly"
  [ ! -s "$log" ] || fail "missing endpoint input reached backend"
  pass "fm-send: known-owner explicit endpoint validates inputs without changing its typed plane"
}

test_input_boundary_is_not_reported_missing() {
  local dir fb home log err rc
  dir="$TMP_ROOT/input-boundary"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home input-boundary)
  log="$dir/send.log"; err="$dir/send.err"
  fm_write_meta "$home/state/other.meta" "window=sess:fm-other" "kind=ship"
  printf 'already readable, do not disclose\n' > "$dir/outside.md"
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    "$SEND" other --require-input "$dir/outside.md" 'Use the declared input' >/dev/null 2> "$err"; rc=$?
  expect_code 4 "$rc" "outside input refuses distinctly"
  assert_contains "$(cat "$err")" 'outside the transfer boundary' "outside input is a confinement limit, not missing"
  assert_not_contains "$(cat "$err")" 'unavailable to' "outside input must not be called inaccessible"
  assert_not_contains "$(cat "$err")" 'already readable, do not disclose' "validation returns no contents"
  [ ! -s "$log" ] && [ ! -e "$home/state/other.inbox" ] || fail "outside declaration reached receiver"
  pass "fm-send: outside-home input is reported as the transfer boundary without reading its contents"
}

test_long_dotted_forms_keep_rule_m_results() {
  local dir fb home log err rc dots text body
  dir="$TMP_ROOT/scan-dotted"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home scandotted); log="$dir/send.log"; err="$dir/send.err"
  fm_write_meta "$home/state/task-one.meta" "window=sess:fm-task-one" "kind=ship"
  fm_write_meta "$home/state/other.meta" "window=sess:fm-other" "kind=ship"
  dots=$(head -c 3000 /dev/zero | tr '\0' '.')
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" other "Continue task-one$dots" >/dev/null 2> "$err"; rc=$?
  [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ] || fail "a recorded id followed by 3000 dots escaped the ownership guard"
  assert_contains "$(cat "$err")" "Send to 'task-one'" "the long dotted form must still designate its owner"
  [ ! -s "$log" ] && [ ! -e "$home/state/other.inbox" ] || fail "the long dotted refusal had an effect"
  text="Continue task-one-longer$dots"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" other "$text" >/dev/null 2> "$err"; rc=$?
  expect_code 0 "$rc" "a longer id followed by dots is not a mention"
  body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$home/state/other.inbox/001.msg")
  [ "$body" = "$text" ] || fail "the dotted control changed its body"
  pass "fm-send: a recorded id followed by a long run of dots is refused and a longer id is delivered unchanged"
}

# The scan before the single-pass change, kept here as the reference for rule M:
# strip one trailing dot at a time and stop at the first form that resolves.
reference_mention_id() {  # <state> <token>
  local state=$1 token=$2 id=
  while :; do
    if [ -f "$state/$token.meta" ]; then id=$token; break; fi
    case "$token" in fm-?*)
      if [ -f "$state/${token#fm-}.meta" ]; then id=${token#fm-}; break; fi ;;
    esac
    [ "${token%.}" != "$token" ] || break
    token=${token%.}
  done
  printf '%s' "$id"
}

test_mention_resolution_matches_the_reference_scan() {
  local dir state fn id base dots k token want got checked=0 set sets
  dir="$TMP_ROOT/scan-diff"; mkdir -p "$dir"
  fn=$(awk '/^fm_send_load_recorded_ids\(\) /,/^}$/; /^fm_send_resolve_mention\(\) /,/^}$/' "$SEND")
  case "$fn" in *'fm_send_load_recorded_ids() '*'fm_send_resolve_mention() '*) ;; *)
    fail "fm_send_load_recorded_ids and fm_send_resolve_mention are not defined in bin/fm-send.sh" ;;
  esac
  eval "$fn"
  sets=(
    "a"
    "fm-a"
    "a fm-a"
    "a.. fm-a. b.."
    "a.b a.b.. fm-a.b"
    "= . .. ......"
    "a.......... fm-a.......... fm-...........  ...........x"
    "a a. a.. a... a.... a..... a...... a....... a........ a......... a.......... fm-a fm-a. fm-a........... b fm-fm-a"
  )
  for set in "${sets[@]}"; do
    state="$dir/state"; rm -rf "$state"; mkdir -p "$state"
    for id in $set; do
      [ "$id" != '=' ] || id=
      : > "$state/$id.meta"
    done
    export STATE=$state
    fm_send_load_recorded_ids
    for base in '' a fm- fm-a fm-fm-a b a.b fm-a.b x; do
      for k in 0 1 2 3 4 5 6 7 8 9 10 11 12 13; do
        dots=$(printf '%*s' "$k" '' | tr ' ' '.')
        token=$base$dots
        want=$(reference_mention_id "$state" "$token")
        MENTION_ID=
        fm_send_resolve_mention "$base" "$k"
        got=$MENTION_ID
        [ "$got" = "$want" ] || fail "rule M differs for '$token' with metas [$set]: reference '$want', scan '$got'"
        checked=$((checked + 1))
      done
    done
  done
  printf 'scan-diff: %s token and meta-set pairs agree with the reference scan\n' "$checked"
  pass "fm-send: the single-pass mention scan resolves every token like the one-dot-at-a-time scan"
}

test_trailing_dot_split_matches_the_reference_split() {
  local fn token reference want got checked=0 base k dots
  fn=$(awk '/^fm_send_split_trailing_dots\(\) /,/^}$/' "$SEND")
  [ -n "$fn" ] || fail "fm_send_split_trailing_dots is not defined in bin/fm-send.sh"
  eval "$fn"
  for base in '' a ab a.b fm- zq 'a..b' '...' 'x.y.z'; do
    for k in 0 1 2 3 4 5 8 9 17 64 129; do
      dots=$(printf '%*s' "$k" '' | tr ' ' '.')
      token=$base$dots
      [ -n "$token" ] || continue
      reference=$token; want=0
      while [ "${reference%.}" != "$reference" ]; do reference=${reference%.}; want=$((want + 1)); done
      got=$(printf '%s\n' "$token" | fm_send_split_trailing_dots)
      [ "$got" = "$(printf '%d\t%s' "$want" "$reference")" ] || fail "split of '$token' is wrong: '$got'"
      checked=$((checked + 1))
    done
  done
  printf 'split-diff: %s tokens split like the one-dot-at-a-time reference\n' "$checked"
  pass "fm-send: the trailing-dot split counts the same dots as stripping them one at a time"
}

# A UTF-8 locale an operator's shell normally runs in; echoes nothing if none is installed.
utf8_test_locale() {
  local name
  for name in en_US.UTF-8 C.UTF-8; do
    if LC_ALL=$name bash -c 'exit 0' 2>/dev/null && locale -a 2>/dev/null | grep -qix "$name"; then
      printf '%s\n' "$name"; return 0
    fi
  done
}

# CPU milliseconds (user plus system, children included) that one send of a
# message of <chars> characters followed by one space and a word takes, in the
# UTF-8 locale <locale>. CPU time, not a deadline: nothing is timed out or
# killed, and the assertion compares two sizes. A message with a space is the
# case that matters: the old empty-message check was fast without one.
send_cpu_ms_for_message() {  # <home> <fakebin> <log> <chars> <locale> -> echoes ms
  local home=$1 fb=$2 log=$3 chars=$4 locale=$5 msg out
  msg="$(printf '%*s' "$chars" '' | tr ' ' x) y"
  : > "$log"
  out=$(LC_ALL=$locale PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    bash -c '"$1" other "$2" >/dev/null 2>&1; times' _ "$SEND" "$msg") || fail "long no-space message was not delivered"
  printf '%s\n' "$out" | awk 'NR == 2 { for (i = 1; i <= 2; i++) { split($i, a, /[ms]/); total += a[1] * 60000 + a[2] * 1000 } printf "%d\n", total }'
}

test_empty_message_check_cost_does_not_grow_quadratically() {
  local dir fb home log small large grown locale
  locale=$(utf8_test_locale)
  if [ -z "$locale" ]; then
    printf 'empty-check-cost: no UTF-8 locale installed here; the cost check needs one and was not run\n'
    return 0
  fi
  dir="$TMP_ROOT/empty-check-cost"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home emptycost); log="$dir/send.log"
  fm_write_meta "$home/state/other.meta" "window=sess:fm-other" "kind=ship"
  small=$(send_cpu_ms_for_message "$home" "$fb" "$log" 2000 "$locale")
  large=$(send_cpu_ms_for_message "$home" "$fb" "$log" 8000 "$locale")
  grown=$((large - small))
  printf 'empty-check-cost: locale=%s cpu ms at 2000 chars=%s, at 8000 chars=%s, growth=%s\n' "$locale" "$small" "$large" "$grown"
  [ "$grown" -le 2000 ] || fail "send CPU grows faster than the message: ${small} ms at 2000 characters, ${large} ms at 8000"
  pass "fm-send: a long message with a space costs CPU in proportion to its length"
}

test_empty_message_refusal_is_unchanged_for_long_inputs() {
  local dir fb home log err rc text reference n
  dir="$TMP_ROOT/empty-check-rows"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home emptyrows); log="$dir/send.log"; err="$dir/send.err"
  fm_write_meta "$home/state/other.meta" "window=sess:fm-other" "kind=ship"
  for text in '' ' ' $'\t\n \r' "$(printf '%*s' 20000 '' | tr ' ' ' ')" "$(printf '%*s' 20000 '' | tr ' ' $'\n')" $'\v\f' ; do
    : > "$log"
    PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
      "$SEND" other "$text" >/dev/null 2> "$err"; rc=$?
    [ "$rc" -eq 1 ] || fail "an empty-looking message of ${#text} characters was not refused: exit $rc"
    assert_contains "$(cat "$err")" 'requires a nonempty message' "empty-looking message refusal text"
    [ ! -s "$log" ] && [ ! -e "$home/state/other.inbox" ] || fail "an empty-looking message had an effect"
  done
  n=0
  for text in 'x' ' x ' $'\n\nx' "$(printf '%*s' 20000 '' | tr ' ' x)" "$(printf '%*s' 20000 '' | tr ' ' .)" "$(printf '%*s' 20000 '' | tr ' ' ' ')x" "$(printf '%*s' 20000 '' | tr ' ' x) y"; do
    n=$((n + 1))
    PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
      "$SEND" other "$text" >/dev/null 2> "$err"; rc=$?
    expect_code 0 "$rc" "a non-empty message of ${#text} characters must still send"
    reference=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$(printf '%s/state/other.inbox/%03d.msg' "$home" "$n")")
    [ "$reference" = "$text" ] || fail "a non-empty message changed on delivery"
  done
  # The case pattern must call the same strings empty as the deletion it replaced.
  local locale probe empty_by_case empty_by_deletion compared=0
  for locale in C "$(utf8_test_locale)"; do
    [ -n "$locale" ] || continue
    for probe in '' ' ' $'\t\n\v\f\r ' 'x' ' x' 'x ' $' \n x \n' $'\xc2\xa0' $'\xc2\xa0x' $'\xe3\x80\x80' $'\xe2\x80\x83 ' $'\xff' $'\xff ' 'é' ' é '; do
      empty_by_deletion=$(LC_ALL=$locale bash -c 'if [ -z "${1//[[:space:]]/}" ]; then echo yes; else echo no; fi' _ "$probe")
      empty_by_case=$(LC_ALL=$locale bash -c 'case "$1" in *[![:space:]]*) echo no ;; *) echo yes ;; esac' _ "$probe")
      [ "$empty_by_case" = "$empty_by_deletion" ] || fail "locale $locale: case says empty=$empty_by_case, deletion says $empty_by_deletion"
      compared=$((compared + 1))
    done
  done
  printf 'empty-check-diff: %s string and locale pairs agree between the case and the old deletion\n' "$compared"
  pass "fm-send: empty-looking messages, short or very long, are still refused; non-empty ones still send unchanged"
}

fm_test_only

test_empty_message_check_cost_does_not_grow_quadratically
test_empty_message_refusal_is_unchanged_for_long_inputs
test_trailing_dot_split_matches_the_reference_split
test_long_dotted_forms_keep_rule_m_results
test_mention_resolution_matches_the_reference_scan
test_input_boundary_is_not_reported_missing
test_missing_inputs_report_all_without_inbox_trace
test_known_endpoint_accepts_declared_input
test_shared_endpoint_accepts_each_recorded_owner
test_explicit_endpoint_ownership_and_guard_events
test_relay_survives_unavailable_event_writer
test_arbitrary_path_mentions_are_not_inputs
test_declared_local_input_is_checked_without_grants
test_task_owner_mismatch_is_refused
test_owner_relay_and_correct_owner
test_task_mentions_match_whole_tokens
test_mentions_match_the_recorded_id_spelling
test_miscased_selector_keeps_its_own_mentions
test_secondmate_own_task_and_relay_safety
test_exact_lane_id_send_still_works
test_key_send_exit_status_follows_delivery
test_unset_fm_home_fails
test_unresolvable_target_does_not_tmux_fallback
test_prefixless_herdr_pane_id_fails
test_unmatched_single_colon_target_must_exist
test_fm_prefixed_herdr_session_is_an_explicit_target
test_healthy_fm_id_send_still_works
