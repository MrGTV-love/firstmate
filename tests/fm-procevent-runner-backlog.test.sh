#!/usr/bin/env bash
# A held unrelated source mutex must not delay a public listener's next answer.
set -u
BOOTSTRAP=$(mktemp -d "${TMPDIR:-/tmp}/fm-backlog-test.XXXXXX") || exit 1
export TMPDIR="$BOOTSTRAP"
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-procevent-runner-backlog)
export FM_HOME="$TMP_ROOT/home" FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export TMPDIR="$TMP_ROOT" LAVISH_AXI_STATE_DIR="$TMP_ROOT/lavish-state"
mkdir -p "$FM_HOME/state" "$LAVISH_AXI_STATE_DIR"
fm_test_track_procevent_home "$FM_HOME" "$FM_PROCEVENT_CLAIM_ROOT"
HOLDER_PID=''
CAPTURE_BARRIERS=()
cleanup() {
  : > "$TMP_ROOT/release-lock"
  local barrier
  for barrier in "${CAPTURE_BARRIERS[@]:-}"; do
    [ -n "$barrier" ] && : > "$barrier/release"
  done
  [ -z "$HOLDER_PID" ] || wait "$HOLDER_PID" 2>/dev/null || true
  fm_test_cleanup
  rm -rf -- "$BOOTSTRAP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'exit 131' QUIT
wait_for() {
  local _
  for _ in $(seq 1 100); do "$@" && return 0; sleep 0.1; done
  return 1
}
nonempty() { [ -s "$1" ]; }
pe() { "$ROOT/bin/fm-procevent.sh" "$@"; }
# Make a real unhandled durable capture, including its metadata and initial wake.
pe register lavish unrelated-pending -- /usr/bin/printf 'session:\n  status: feedback\n  session_ended: true\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","unrelated pending answer","","message",""\n' >/dev/null \
  || fail 'could not register unrelated source'
pe start unrelated-pending >/dev/null 2>&1 || fail 'could not capture unrelated result'
assert_present "$FM_HOME/state/procevent-inbox/unrelated-pending.1.result" 'unrelated capture exists'
assert_absent "$FM_HOME/state/procevent-inbox/unrelated-pending.1.handled" 'unrelated capture is unhandled'
NATIVE_BIN=$(fm_fakebin "$TMP_ROOT/native")
export PATH="$NATIVE_BIN:$PATH"
cat > "$NATIVE_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1-}" = poll ] || exit 2
artifact=$2
n=$(cat "$artifact.count" 2>/dev/null || printf 0)
n=$((n + 1))
printf '%s\n' "$n" > "$artifact.count"
printf 'ready\n' > "$artifact.poll$n"
while [ ! -f "$artifact.answer$n" ]; do
  [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ] || exit 1
  sleep 0.05
done
cat "$artifact.answer$n"
rm -f -- "$artifact.answer$n"
SH
chmod +x "$NATIVE_BIN/lavish-axi"
ARTIFACT="$TMP_ROOT/board.html"
printf '<h1>backlog isolation</h1>\n' > "$ARTIFACT"
perl -MJSON::PP -MCwd=realpath -MDigest::SHA=sha256_hex -e '
  my ($path, $artifact) = @ARGV;
  my $real = realpath($artifact) // die "missing artifact";
  my $key = substr(sha256_hex($real), 0, 16);
  open my $out, ">", $path or die $!;
  print $out encode_json({sessions => {$key => {key => $key, file => $real,
    status => "open", url => "http://127.0.0.1:14387/session/0123456789abcdef"}}});
' "$LAVISH_AXI_STATE_DIR/state.json" "$ARTIFACT"
SOURCE_ID=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$ARTIFACT")
pe register lavish "$SOURCE_ID" -- "$ROOT/bin/fm-procevent-lavish.sh" poll "$ARTIFACT" >/dev/null \
  || fail 'public registration failed'
pe start "$SOURCE_ID" > "$TMP_ROOT/runner.log" 2>&1 &
wait_for nonempty "$ARTIFACT.poll1" || fail 'first native poll did not start'
cp "$FM_PROCEVENT_CLAIM_ROOT/$SOURCE_ID.claim" "$TMP_ROOT/original.claim"
bash -c '
  . "$1/bin/fm-pr-lib.sh"
  . "$1/bin/fm-wake-lib.sh"
  . "$1/bin/fm-procevent-lib.sh"
  fm_procevent_source_lock_acquire unrelated-pending || exit 1
  trap "fm_procevent_source_lock_release unrelated-pending" EXIT
  printf "ready\n" > "$2/lock-ready"
  while [ ! -e "$2/release-lock" ]; do
    kill -0 "$3" 2>/dev/null || exit 0
    sleep 0.1
  done
' _ "$ROOT" "$TMP_ROOT" "$$" &
HOLDER_PID=$!
wait_for nonempty "$TMP_ROOT/lock-ready" || fail 'could not hold unrelated exact source lock'
for round in 1 2; do
  printf 'session:\n  status: feedback\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","backlog round %s","","message",""\n' "$round" > "$ARTIFACT.expected$round"
  if ! { cp "$ARTIFACT.expected$round" "$ARTIFACT.answer$round.tmp" \
    && mv -f -- "$ARTIFACT.answer$round.tmp" "$ARTIFACT.answer$round"; }; then
    fail "round $round answer publication failed"
  fi
  result="$FM_HOME/state/procevent-inbox/$SOURCE_ID.$round.result"
  wait_for nonempty "$result" || fail "round $round was not captured while unrelated source stayed locked"
  cmp -s "$ARTIFACT.expected$round" "$result" || fail "round $round native bytes changed"
  wake_has_round() { [ -f "$FM_HOME/state/.wake-queue" ] && grep -q "procevent lavish $SOURCE_ID $round" "$FM_HOME/state/.wake-queue"; }
  wait_for wake_has_round || fail "round $round had no durable wake"
  wait_for nonempty "$ARTIFACT.poll$((round + 1))" \
    || fail "round $round capture failed to relisten while unrelated source stayed locked"
  cmp -s "$TMP_ROOT/original.claim" "$FM_PROCEVENT_CLAIM_ROOT/$SOURCE_ID.claim" \
    || fail "round $round replaced the full runner claim instead of relistening"
  assert_absent "$FM_HOME/state/procevent-inbox/$SOURCE_ID.$round.handled" 'feedback stays unacknowledged'
done
# No reconciliation occurred above. Global durable replay remains its job:
# remove wake delivery, release the unrelated mutex, then ask reconcile to replay.
: > "$TMP_ROOT/release-lock"
wait "$HOLDER_PID" || fail 'lock holder failed'
HOLDER_PID=''
rm -f -- "$FM_HOME/state/.wake-queue"
pe reconcile >/dev/null || fail 'reconcile replay failed'
assert_grep 'procevent lavish unrelated-pending 1' "$FM_HOME/state/.wake-queue" 'reconcile reannounces unrelated durable capture'
for round in 1 2; do
  assert_grep "procevent lavish $SOURCE_ID $round" "$FM_HOME/state/.wake-queue" 'reconcile reannounces unhandled feedback'
done
pass 'same full-claim public runner captures and wakes repeated feedback despite unrelated locked backlog; reconcile retains global replay'

VISIBILITY_BIN=$(fm_fakebin "$TMP_ROOT/visibility")
REAL_MV=$(command -v mv)
REAL_MKTEMP=$(command -v mktemp)
ln -s /bin/bash "$VISIBILITY_BIN/claude"
fm_fake_exit0 "$VISIBILITY_BIN" tmux
cat > "$VISIBILITY_BIN/mv" <<SH
#!/usr/bin/env bash
set -u
dest=''
for arg in "\$@"; do dest=\$arg; done
"$REAL_MV" "\$@" || exit \$?
case "\$dest" in
  "\${FM_TEST_CAPTURE_BASE:-unset}".*.result)
    printf '%s\n' "\$dest" > "\$FM_TEST_CAPTURE_BARRIER/ready" || exit 1
    while [ ! -e "\$FM_TEST_CAPTURE_BARRIER/release" ]; do
      [ "\$SECONDS" -lt "\${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ] || exit 75
      sleep 0.05
    done
    ;;
esac
SH
cat > "$VISIBILITY_BIN/mktemp" <<SH
#!/usr/bin/env bash
set -u
template=''
for arg in "\$@"; do template=\$arg; done
if [ -f "\${FM_TEST_CAPTURE_BARRIER:-unset}/fail-handled" ] \
  && [ "\$template" = "\$FM_TEST_CAPTURE_BARRIER/home/state/procevent-inbox/.handled.XXXXXX" ]; then
  exit 1
fi
exec "$REAL_MKTEMP" "\$@"
SH
chmod +x "$VISIBILITY_BIN/mv" "$VISIBILITY_BIN/mktemp"
make_capture_fixture() {
  CAPTURE_DIR="$TMP_ROOT/visibility-$1"
  CAPTURE_HOME="$CAPTURE_DIR/home"
  CAPTURE_SEQUENCE=${2:-1}
  fm_git_init_commit "$CAPTURE_HOME" || fail 'could not create primary capture checkout'
  mkdir -p "$CAPTURE_HOME/state" "$CAPTURE_HOME/config" "$CAPTURE_DIR/user-home"
  : > "$CAPTURE_HOME/AGENTS.md"
  ln -s "$ROOT/bin" "$CAPTURE_HOME/bin"
  fm_test_track_procevent_home "$CAPTURE_HOME" "$FM_PROCEVENT_CLAIM_ROOT"
  CAPTURE_BARRIERS+=("$CAPTURE_DIR")
  CAPTURE_ARTIFACT="$CAPTURE_DIR/board.html"
  printf '<h1>capture visibility</h1>\n' > "$CAPTURE_ARTIFACT"
  perl -MJSON::PP -MCwd=realpath -MDigest::SHA=sha256_hex -e '
    my ($path, $artifact) = @ARGV;
    open my $in, "<", $path or die $!;
    local $/;
    my $state = decode_json(<$in>);
    close $in;
    my $real = realpath($artifact) // die "missing artifact";
    my $key = substr(sha256_hex($real), 0, 16);
    $state->{sessions}{$key} = {key => $key, file => $real, status => "open",
      url => "http://127.0.0.1:14387/session/0123456789abcdef"};
    open my $out, ">", $path or die $!;
    print $out encode_json($state);
    close $out or die $!;
  ' "$LAVISH_AXI_STATE_DIR/state.json" "$CAPTURE_ARTIFACT" \
    || fail 'could not record fixture Lavish session'
  CAPTURE_ID=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$CAPTURE_ARTIFACT")
  CAPTURE_BASE="$CAPTURE_HOME/state/procevent-inbox/$CAPTURE_ID.$CAPTURE_SEQUENCE"
}
capture_pe() {
  FM_HOME="$CAPTURE_HOME" FM_STATE_OVERRIDE="$CAPTURE_HOME/state" \
    FM_ROOT_OVERRIDE="$CAPTURE_HOME" FM_CONFIG_OVERRIDE="$CAPTURE_HOME/config" \
    HOME="$CAPTURE_DIR/user-home" XDG_CONFIG_HOME="$CAPTURE_DIR/user-home/.config" \
    XDG_STATE_HOME="$CAPTURE_DIR/user-home/.state" \
    "$ROOT/bin/fm-procevent.sh" "$@"
}
capture_posttool() {
  # Expand variables in the child shell, not in this parent shell.
  # shellcheck disable=SC2016
  printf '{"session_id":"capture-visibility"}\n' \
    | env -u GROK_AGENT -u GROK_HOOK_EVENT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
        -u FM_PROCEVENT_IN_RUNNER \
        FM_HOME="$CAPTURE_HOME" FM_STATE_OVERRIDE="$CAPTURE_HOME/state" \
        FM_ROOT_OVERRIDE="$CAPTURE_HOME" FM_CONFIG_OVERRIDE="$CAPTURE_HOME/config" \
        HOME="$CAPTURE_DIR/user-home" XDG_CONFIG_HOME="$CAPTURE_DIR/user-home/.config" \
        XDG_STATE_HOME="$CAPTURE_DIR/user-home/.state" \
        "$VISIBILITY_BIN/claude" -c '
          printf "%s\n" "$$" > "$FM_HOME/state/.lock"
          "$1/bin/fm-procevent-posttool-check.sh"
        ' _ "$ROOT"
}
assert_capture_notice() {
  local notice=$1 context
  context=$(printf '%s\n' "$notice" | perl -MJSON::PP=decode_json -e '
    local $/;
    my $notice = decode_json(<STDIN>)->{hookSpecificOutput};
    die "not PostToolUse" unless $notice->{hookEventName} eq "PostToolUse";
    print $notice->{additionalContext};
  ') || fail 'capture notice was not native PostToolUse additional context'
  assert_contains "$context" "A captured Lavish result is waiting: $CAPTURE_ID $CAPTURE_SEQUENCE." \
    'unhandled capture notice identifies its exact source and sequence'
  assert_contains "$context" "$CAPTURE_BASE.result" 'unpublished capture notice retains direct result recovery'
  assert_contains "$context" 'fm-procevent-lavish.sh' 'capture notice provides the public reader'
  assert_contains "$context" "handled $CAPTURE_ID $CAPTURE_SEQUENCE" 'capture notice provides explicit acknowledgement'
}
start_capture() {
  if [ -n "${1-}" ]; then
    capture_pe register-task lavish "$CAPTURE_ID" "$1" -- \
      "$ROOT/bin/fm-procevent-lavish.sh" poll "$CAPTURE_ARTIFACT" >/dev/null \
      || fail 'could not register task-owned capture fixture'
  else
    capture_pe register lavish "$CAPTURE_ID" -- \
      "$ROOT/bin/fm-procevent-lavish.sh" poll "$CAPTURE_ARTIFACT" >/dev/null \
      || fail 'could not register primary capture fixture'
  fi
  PATH="$VISIBILITY_BIN:$PATH" FM_TEST_CAPTURE_BARRIER="$CAPTURE_DIR" \
    FM_TEST_CAPTURE_BASE="$CAPTURE_HOME/state/procevent-inbox/$CAPTURE_ID" \
    capture_pe start "$CAPTURE_ID" > "$CAPTURE_DIR/runner.log" 2>&1 &
  CAPTURE_RUN_PID=$!
  wait_for nonempty "$CAPTURE_ARTIFACT.poll1" || fail 'capture fixture did not enter its native poll'
  if ! { cp "$CAPTURE_DIR/payload" "$CAPTURE_ARTIFACT.answer1.tmp" \
    && mv -f -- "$CAPTURE_ARTIFACT.answer1.tmp" "$CAPTURE_ARTIFACT.answer1"; }; then
    fail 'could not supply capture fixture answer'
  fi
  wait_for nonempty "$CAPTURE_DIR/ready" || fail 'runner did not reach the result-rename barrier'
  assert_equals "$CAPTURE_BASE.result" "$(cat "$CAPTURE_DIR/ready")" \
    'capture commits at the expected fresh sequence'
  cmp -s "$CAPTURE_DIR/payload" "$CAPTURE_BASE.result" || fail 'capture changed the native result bytes'
  assert_grep lavish "$CAPTURE_BASE.adapter" 'notification-visible capture has its adapter identity'
}
finish_capture() {
  : > "$CAPTURE_DIR/release"
  wait "$CAPTURE_RUN_PID" || fail 'terminal capture runner failed after barrier release'
}

for shape in disconnected ended; do
  make_capture_fixture "$shape"
  if [ "$shape" = disconnected ]; then
    printf 'session:\n  status: browser_disconnected\n' > "$CAPTURE_DIR/payload"
  else
    printf 'session:\n  status: ended\n  ended_by: user\n' > "$CAPTURE_DIR/payload"
  fi
  start_capture
  assert_present "$CAPTURE_BASE.handled" 'silent capture is durably handled before the result rename returns'
  assert_absent "$CAPTURE_HOME/state/.wake-queue" 'paused silent capture has no primary wake'
  [ -z "$(capture_posttool)" ] || fail "paused $shape capture notified the primary"
  [ -z "$(capture_posttool)" ] || fail "repeated hook exposed paused $shape capture"
  : > "$CAPTURE_DIR/release"
  if [ "$shape" = disconnected ]; then
    wait_for nonempty "$CAPTURE_ARTIFACT.poll2" || fail 'handled disconnect failed to relisten'
    capture_pe retire "$CAPTURE_ID" >/dev/null || fail 'could not retire disconnected fixture listener'
    wait "$CAPTURE_RUN_PID" 2>/dev/null || true
  else
    wait "$CAPTURE_RUN_PID" || fail 'empty ended capture runner failed'
  fi
  assert_absent "$CAPTURE_HOME/state/procevent/$CAPTURE_ID.source" 'silent fixture leaves no registered listener'
  capture_pe reconcile >/dev/null || fail 'silent capture reconciliation failed'
  assert_absent "$CAPTURE_HOME/state/.wake-queue" 'silent capture remains unwoken after publication and replay'
  [ -z "$(capture_posttool)" ] || fail "settled $shape capture notified the primary"
done
pass 'primary disconnect and empty ended captures are already durably silent when their real result becomes visible'

for shape in feedback orphan-handled; do
  if [ "$shape" = orphan-handled ]; then
    make_capture_fixture "$shape" 2
    mkdir -p "$CAPTURE_HOME/state/procevent-inbox"
    : > "$CAPTURE_HOME/state/procevent-inbox/$CAPTURE_ID.1.handled"
    chmod 0600 "$CAPTURE_HOME/state/procevent-inbox/$CAPTURE_ID.1.handled"
    assert_absent "$CAPTURE_HOME/state/procevent-inbox/$CAPTURE_ID.1.result" 'interrupted silent capture has no committed result'
  else
    make_capture_fixture "$shape"
  fi
  printf 'session:\n  status: feedback\n  session_ended: true\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","genuine visibility answer","","message",""\n' \
    > "$CAPTURE_DIR/payload"
  mkdir "$CAPTURE_HOME/state/.wake-queue"
  start_capture
  assert_absent "$CAPTURE_BASE.handled" 'genuine feedback does not inherit silence'
  assert_capture_notice "$(capture_posttool)"
  assert_capture_notice "$(capture_posttool)"
  assert_absent "$CAPTURE_BASE.handled" 'repeated hook notices do not acknowledge genuine feedback'
  finish_capture
  [ -d "$CAPTURE_HOME/state/.wake-queue" ] || fail 'publication blocker did not remain in place'
  assert_absent "$CAPTURE_HOME/state/procevent/$CAPTURE_ID.source" 'terminal feedback source retires despite blocked publication'
  assert_capture_notice "$(capture_posttool)"
  assert_capture_notice "$(capture_posttool)"
  assert_absent "$CAPTURE_BASE.handled" 'unpublished feedback remains recoverable until explicit acknowledgement'
  capture_pe handled "$CAPTURE_ID" "$CAPTURE_SEQUENCE" >/dev/null || fail 'could not explicitly acknowledge genuine feedback'
  [ -z "$(capture_posttool)" ] || fail 'explicitly handled feedback still notified the primary'
  cmp -s "$CAPTURE_DIR/payload" "$CAPTURE_BASE.result" || fail 'acknowledgement changed the durable feedback'
  rmdir "$CAPTURE_HOME/state/.wake-queue"
  capture_pe reconcile >/dev/null || fail 'handled feedback reconciliation failed'
  assert_absent "$CAPTURE_HOME/state/.wake-queue" 'handled unpublished feedback stays silent when publication recovers'
done
pass 'unpublished genuine feedback remains repeatedly visible until explicitly handled, including after orphaned silent-marker sequence reservation'

make_capture_fixture unrecordable-silence
printf 'session:\n  status: ended\n  ended_by: user\n' > "$CAPTURE_DIR/payload"
: > "$CAPTURE_DIR/fail-handled"
start_capture
assert_absent "$CAPTURE_BASE.handled" 'unrecordable silence does not discard or acknowledge the capture'
assert_capture_notice "$(capture_posttool)"
finish_capture
assert_absent "$CAPTURE_BASE.handled" 'failed marker installation retains an unhandled durable result'
assert_grep "procevent lavish $CAPTURE_ID 1" "$CAPTURE_HOME/state/.wake-queue" \
  'unrecordable silence falls open to durable owner notification'
assert_capture_notice "$(capture_posttool)"
rm -f -- "$CAPTURE_DIR/fail-handled" "$CAPTURE_HOME/state/.wake-queue"
capture_pe reconcile >/dev/null || fail 'silence did not recover after handled markers became writable'
assert_present "$CAPTURE_BASE.handled" 'recovered silence is durably acknowledged'
assert_absent "$CAPTURE_HOME/state/.wake-queue" 'recovered silence is not reannounced'
[ -z "$(capture_posttool)" ] || fail 'recovered silence still notified the primary'
pass 'a silent capture whose handled marker cannot be installed stays durable and recoverable until acknowledgement recovers'

make_capture_fixture task-disconnected
printf 'session:\n  status: browser_disconnected\n' > "$CAPTURE_DIR/payload"
fm_write_meta "$CAPTURE_HOME/state/visibility-task.meta" \
  'window=fmtest:fm-visibility-task' "worktree=$CAPTURE_DIR/worktree" 'project=fmtest'
start_capture visibility-task
assert_present "$CAPTURE_BASE.handled" 'task-owned disconnect is durably handled before result visibility'
assert_grep visibility-task "$CAPTURE_BASE.owner-task" 'silent task-owned capture retains its owner at first visibility'
[ -z "$(capture_posttool)" ] || fail 'paused task-owned disconnect leaked to the primary'
assert_absent "$CAPTURE_HOME/state/visibility-task.inbox" 'paused task-owned disconnect does not notify its task'
assert_absent "$CAPTURE_HOME/state/.wake-queue" 'paused task-owned disconnect does not wake the primary'
: > "$CAPTURE_DIR/release"
wait_for nonempty "$CAPTURE_ARTIFACT.poll2" || fail 'handled task-owned disconnect failed to relisten'
assert_absent "$CAPTURE_HOME/state/visibility-task.inbox" 'relistened task-owned disconnect remains silent to its task'
assert_absent "$CAPTURE_HOME/state/.wake-queue" 'relistened task-owned disconnect remains silent to the primary'
[ -z "$(capture_posttool)" ] || fail 'relistened task-owned disconnect leaked to the primary'
FM_TASK_ID=visibility-task capture_pe retire "$CAPTURE_ID" >/dev/null \
  || fail 'could not retire task-owned disconnected fixture listener'
wait "$CAPTURE_RUN_PID" 2>/dev/null || true
assert_absent "$CAPTURE_HOME/state/procevent/$CAPTURE_ID.source" 'task-owned disconnect listener retires through the public identity-safe interface'
pass 'task-owned disconnect capture is durably silent at first visibility and resumes listening without notifying either owner channel'

make_capture_fixture task-terminal
printf 'session:\n  status: ended\n  ended_by: user\n' > "$CAPTURE_DIR/payload"
fm_write_meta "$CAPTURE_HOME/state/visibility-task.meta" \
  'window=fmtest:fm-visibility-task' "worktree=$CAPTURE_DIR/worktree" 'project=fmtest'
start_capture visibility-task
assert_grep visibility-task "$CAPTURE_BASE.owner-task" 'task ownership precedes result visibility'
assert_absent "$CAPTURE_BASE.handled" 'task-owned terminal capture is not automatically silenced'
[ -z "$(capture_posttool)" ] || fail 'paused task-owned terminal capture leaked to the primary'
assert_absent "$CAPTURE_HOME/state/visibility-task.inbox" 'task notification waits until the result-rename barrier releases'
finish_capture
assert_present "$CAPTURE_HOME/state/visibility-task.inbox/001.msg" 'task-owned terminal capture reaches its task inbox'
assert_grep "$CAPTURE_ID sequence 1 is terminal" "$CAPTURE_HOME/state/visibility-task.inbox/001.msg" \
  'task terminal notification identifies the captured round'
assert_grep "$CAPTURE_BASE.result" "$CAPTURE_HOME/state/visibility-task.inbox/001.msg" \
  'task terminal notification retains its durable result'
assert_absent "$CAPTURE_BASE.handled" 'task notification alone does not acknowledge its terminal round'
assert_absent "$CAPTURE_HOME/state/.wake-queue" 'task-owned terminal capture never wakes the primary'
[ -z "$(capture_posttool)" ] || fail 'notified task-owned terminal capture leaked to the primary'
FM_TASK_ID=visibility-task capture_pe handled "$CAPTURE_ID" 1 >/dev/null \
  || fail 'task could not acknowledge its terminal capture'
assert_absent "$CAPTURE_HOME/state/procevent/$CAPTURE_ID.source" 'task acknowledgement retires its terminal source'
pass 'task-owned empty terminal capture still notifies only its task and retires after its owner acknowledges'
