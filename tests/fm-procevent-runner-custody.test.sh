#!/usr/bin/env bash
# Public Lavish/runner shutdown regressions: a TERM sent only to the owned
# runner must drain its blocking native poll and descendants before custody is
# released. A replacement must collect the answer; a crashed leader's surviving
# group remains refused. The native CLI fixture implements an exclusive listener
# and destructive answer handoff, without starting a live Lavish server.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-procevent-runner-custody)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export LAVISH_AXI_STATE_DIR="$TMP_ROOT/lavish-state"
# Keep adapter response stages inside the self-cleaning fixture too.
export TMPDIR="$TMP_ROOT"
mkdir -p "$LAVISH_AXI_STATE_DIR"
NATIVE_BIN=$(fm_fakebin "$TMP_ROOT/native")
export PATH="$NATIVE_BIN:$PATH"
OWNED_PID=''
OWNED_MEMBERS=()
OWNED_IDENTITIES=()
own_group() {
  local pid=$1 member identity
  [ -z "$OWNED_PID" ] || fail "previous owned generation was not released"
  for member in "$@"; do
    identity=$(fm_test_pid_identity "$member") || fail "could not identify owned member $member"
    [ -n "$identity" ] || fail "owned member $member has no identity"
    assert_equals "$pid" "$(ps -o pgid= -p "$member" | tr -d '[:space:]')" \
      "owned member belongs to its current runner group"
    OWNED_PID=$pid
    OWNED_MEMBERS+=("$member")
    OWNED_IDENTITIES+=("$identity")
  done
}
forget_group() {
  assert_equals "$OWNED_PID" "$1" "released group is the current owned generation"
  OWNED_PID=''
  OWNED_MEMBERS=()
  OWNED_IDENTITIES=()
}
signal_owned_group() {
  local i identity pgid
  [ -n "$OWNED_PID" ] || return 1
  for ((i = 0; i < ${#OWNED_MEMBERS[@]}; i++)); do
    identity=$(fm_test_pid_identity "${OWNED_MEMBERS[$i]}" 2>/dev/null) || identity=''
    pgid=$(ps -o pgid= -p "${OWNED_MEMBERS[$i]}" 2>/dev/null | tr -d '[:space:]')
    if [ "$identity" = "${OWNED_IDENTITIES[$i]}" ] && [ "$pgid" = "$OWNED_PID" ]; then
      kill -KILL -"$OWNED_PID" 2>/dev/null
      return
    fi
  done
  return 1
}
cleanup() {
  signal_owned_group || true
  fm_test_cleanup
}
trap cleanup EXIT

cat > "$NATIVE_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1-}" = poll ] || exit 2
artifact=$2
listener="$artifact.listener"
if ! mkdir "$listener" 2>/dev/null; then
  owner=$(cat "$listener/pid" 2>/dev/null || true)
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
    printf 'error: Lavish Editor already has an active poll listener\ncode: LISTENER_ACTIVE\n'
    exit 1
  fi
  rm -rf -- "$listener"
  mkdir "$listener" || exit 2
fi
printf '%s\n' "$$" > "$listener/pid"
trap 'rm -rf -- "$listener"' EXIT
trap 'printf "TERM\n" >> "$artifact.signals"; exit 143' TERM
trap 'exit 129' HUP
trap 'exit 130' INT
printf '%s\n' "$$" >> "$artifact.native-pids"
perl -MTime::HiRes=sleep -e '
  my ($artifact, $limit, $resist) = @ARGV;
  $SIG{TERM} = "IGNORE" if $resist;
  open my $marker, ">>", "$artifact.descendant-pids" or die $!;
  print $marker "$$\n";
  close $marker or die $!;
  my $deadline = time + $limit;
  while (!-f "$artifact.answer") {
    exit 75 if time >= $deadline;
    sleep 0.1;
  }
  open my $answer, "<", "$artifact.answer" or die $!;
  local $/;
  my $bytes = <$answer>;
  close $answer or die $!;
  unlink "$artifact.answer" or die $!;
  print $bytes;
' "$artifact" "$FM_TEST_STUB_MAX_BLOCK_SECONDS" "${FM_TEST_NATIVE_TERM_RESISTANT:-0}" &
wait "$!"
SH
chmod +x "$NATIVE_BIN/lavish-axi"

wait_for() {  # <condition command...>
  local i
  for i in $(seq 1 150); do
    "$@" && return 0
    sleep 0.1
  done
  return 1
}
nonempty() { [ -s "$1" ]; }
group_gone() { ! kill -0 -"$1" 2>/dev/null; }
two_pids() {
  [ -f "$1" ] && [ "$(wc -l < "$1" | tr -d ' ')" -ge 2 ]
}
claim_gone() { [ ! -e "$FM_PROCEVENT_CLAIM_ROOT/$1.claim" ]; }
pe() { FM_HOME="$HOME_FIXTURE" "$ROOT/bin/fm-procevent.sh" "$@"; }

new_board() {
  local name=$1
  HOME_FIXTURE="$TMP_ROOT/$name-home"
  ARTIFACT="$TMP_ROOT/$name.html"
  mkdir -p "$HOME_FIXTURE/state"
  printf '<h1>%s</h1>\n' "$name" > "$ARTIFACT"
  perl -MJSON::PP -MCwd=realpath -MDigest::SHA=sha256_hex -e '
    my ($path, $artifact) = @ARGV;
    my $real = realpath($artifact) // die "missing fixture artifact";
    my $key = substr(sha256_hex($real), 0, 16);
    open my $out, ">", $path or die $!;
    print $out encode_json({ sessions => { $key => {
      key => $key, file => $real, status => "open",
      url => "http://127.0.0.1:14387/session/0123456789abcdef",
    } } });
  ' "$LAVISH_AXI_STATE_DIR/state.json" "$ARTIFACT"
  SOURCE_ID=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$ARTIFACT")
  fm_test_track_procevent_home "$HOME_FIXTURE" "$FM_PROCEVENT_CLAIM_ROOT"
  FM_HOME="$HOME_FIXTURE" "$ROOT/bin/fm-procevent-lavish.sh" arm "$ARTIFACT" >/dev/null \
    || fail "$name public arm refused"
  wait_for nonempty "$ARTIFACT.descendant-pids" || fail "$name native descendant did not block"
  IFS= read -r NATIVE_PID < "$ARTIFACT.native-pids"
  IFS= read -r DESCENDANT_PID < "$ARTIFACT.descendant-pids"
  {
    IFS= read -r _
    IFS= read -r RUNNER_PID
  } < "$FM_PROCEVENT_CLAIM_ROOT/$SOURCE_ID.claim"
  own_group "$RUNNER_PID" "$NATIVE_PID" "$DESCENDANT_PID"
}

answer_and_capture() {  # <token>
  local token=$1 result="$HOME_FIXTURE/state/procevent-inbox/$SOURCE_ID.1.result"
  printf 'session:\n  status: feedback\n  session_ended: true\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","%s","","message",""\n' "$token" \
    > "$ARTIFACT.expected"
  if ! { cp "$ARTIFACT.expected" "$ARTIFACT.answer.tmp" \
    && mv -f -- "$ARTIFACT.answer.tmp" "$ARTIFACT.answer"; }; then
    fail "$token answer publication failed"
  fi
  wait_for nonempty "$result" || fail "$token was not captured by the replacement listener"
  cmp -s "$ARTIFACT.expected" "$result" || fail "$token capture changed the native answer bytes"
  wait_for nonempty "$HOME_FIXTURE/state/.wake-queue" || fail "$token produced no durable wake"
  assert_grep "procevent lavish $SOURCE_ID 1" "$HOME_FIXTURE/state/.wake-queue" \
    "$token capture is announced to the consumer wake queue"
  assert_contains "$(FM_HOME="$HOME_FIXTURE" "$ROOT/bin/fm-procevent-lavish.sh" read "$result")" \
    "$token" "$token reaches the public result consumer"
  wait_for claim_gone "$SOURCE_ID" || fail "$token terminal capture did not release custody"
  wait_for group_gone "$RUNNER_PID" || fail "$token terminal capture left its group alive"
  forget_group "$RUNNER_PID"
}

for resist in 0 1; do
  export FM_TEST_NATIVE_TERM_RESISTANT=$resist
  new_board "term-$resist"
  old_runner=$RUNNER_PID
  kill -TERM "$old_runner" || fail "TERM could not reach the owned runner"
  # Never observe a free claim while any nonleader from this generation is
  # still alive. On the old implementation this was the exact custody break.
  custody_broken=0
  for _ in $(seq 1 150); do
    if claim_gone "$SOURCE_ID" \
      && { kill -0 "$NATIVE_PID" 2>/dev/null || kill -0 "$DESCENDANT_PID" 2>/dev/null; }; then
      custody_broken=1
      break
    fi
    group_gone "$old_runner" && break
    sleep 0.1
  done
  if [ "$custody_broken" -eq 1 ]; then
    out=$(pe reconcile)
    printf 'custody evidence: claim=absent old_group=alive native=%s descendant=%s reconcile=%s\n' \
      "$NATIVE_PID" "$DESCENDANT_PID" "$out" >&2
    wait_for nonempty "$HOME_FIXTURE/state/procevent-inbox/$SOURCE_ID.1.result" || true
    if [ -f "$HOME_FIXTURE/state/procevent-inbox/$SOURCE_ID.1.result" ]; then
      cat "$HOME_FIXTURE/state/procevent-inbox/$SOURCE_ID.1.result" >&2
    fi
    fail "TERM-only runner exit released custody while its native poll and descendants survived"
  fi
  group_gone "$old_runner" || fail "TERM-only runner exit left its native poll group alive"
  kill -0 "$NATIVE_PID" 2>/dev/null && fail "old native listener survived TERM-only shutdown"
  kill -0 "$DESCENDANT_PID" 2>/dev/null && fail "old descendant survived TERM-only shutdown"
  forget_group "$old_runner"
  out=$(pe reconcile)
  assert_contains "$out" "started=1" "TERM-only shutdown lets reconcile confirm one replacement"
  wait_for nonempty "$ARTIFACT.listener/pid" || fail "replacement native listener did not start"
  {
    IFS= read -r _
    IFS= read -r replacement_runner
  } < "$FM_PROCEVENT_CLAIM_ROOT/$SOURCE_ID.claim"
  RUNNER_PID=$replacement_runner
  wait_for two_pids "$ARTIFACT.native-pids" || fail "replacement native listener did not publish its pid"
  wait_for two_pids "$ARTIFACT.descendant-pids" || fail "replacement descendant did not block"
  while IFS= read -r member_pid; do NATIVE_PID=$member_pid; done < "$ARTIFACT.native-pids"
  while IFS= read -r member_pid; do DESCENDANT_PID=$member_pid; done < "$ARTIFACT.descendant-pids"
  own_group "$RUNNER_PID" "$NATIVE_PID" "$DESCENDANT_PID"
  answer_and_capture "term-only-answer-$resist"
  pass "TERM-only runner shutdown preserves custody and replacement answer (resistant=$resist)"
done

export FM_TEST_NATIVE_TERM_RESISTANT=0
new_board crash
crashed_runner=$RUNNER_PID
kill -KILL "$crashed_runner" || fail "could not crash the leader without signalling its children"
wait_for nonempty "$ARTIFACT.listener/pid" || fail "crash fixture lost its native poll"
out=$(pe reconcile)
assert_contains "$out" "started=0" "crashed leader does not start a second listener"
assert_contains "$out" "uncertain=1" "crashed leader keeps its ambiguous group refused"
assert_present "$FM_PROCEVENT_CLAIM_ROOT/$SOURCE_ID.claim" "crashed leader keeps its claim"
out=$(pe start "$SOURCE_ID")
assert_contains "$out" "already owned:" "public start also refuses the crashed leader's surviving group"
kill -0 "$NATIVE_PID" 2>/dev/null || fail "crashed-leader refusal signalled the native listener"
kill -0 "$DESCENDANT_PID" 2>/dev/null || fail "crashed-leader refusal signalled the descendant"
assert_absent "$ARTIFACT.signals" "crashed-leader refusal never sends TERM"
signal_owned_group || fail "fixture-only crash cleanup could not verify a surviving owned member"
wait_for group_gone "$crashed_runner" || fail "fixture-only crash cleanup left a group alive"
forget_group "$crashed_runner"
pe retire "$SOURCE_ID" >/dev/null || fail "empty crashed group could not be retired"
pass "crashed-leader group remains claimed and un-signalled by reconcile and public start"

new_board normal
answer_and_capture normal-answer
assert_absent "$ARTIFACT.signals" "normal successful poll exit does not signal its native listener"
pass "normal terminal capture preserves exact native bytes without a false shutdown signal"

new_board killed-child
listening_runner=$RUNNER_PID
kill -TERM "$NATIVE_PID" || fail "could not signal the native poll child alone"
kill -TERM "$DESCENDANT_PID" || fail "could not close the killed poll child's inherited stdout"
wait_for two_pids "$ARTIFACT.native-pids" || fail "an outputless killed native poll did not relisten"
{
  IFS= read -r _
  IFS= read -r relistening_runner
} < "$FM_PROCEVENT_CLAIM_ROOT/$SOURCE_ID.claim"
assert_equals "$listening_runner" "$relistening_runner" "killed native poll relistens under the same claim"
assert_absent "$HOME_FIXTURE/state/procevent-inbox/$SOURCE_ID.1.result" \
  "outputless killed native poll is not captured as an error"
answer_and_capture killed-child-answer
pass "an outputless killed native poll relistens under the same runner and captures its answer"

new_board unknown-error
printf 'error: Lavish Editor session store is unavailable\ncode: SERVER_ERROR\n' > "$ARTIFACT.expected"
if ! { cp "$ARTIFACT.expected" "$ARTIFACT.answer.tmp" \
  && mv -f -- "$ARTIFACT.answer.tmp" "$ARTIFACT.answer"; }; then
  fail "unknown native error publication failed"
fi
unknown_result="$HOME_FIXTURE/state/procevent-inbox/$SOURCE_ID.1.result"
wait_for nonempty "$unknown_result" || fail "unknown native error was not captured"
cmp -s "$ARTIFACT.expected" "$unknown_result" || fail "unknown native error bytes changed"
wait_for nonempty "$HOME_FIXTURE/state/.wake-queue" || fail "unknown native error was suppressed"
assert_grep "procevent lavish $SOURCE_ID 1" "$HOME_FIXTURE/state/.wake-queue" \
  "unknown native error capture reaches the consumer wake queue"
wait_for claim_gone "$SOURCE_ID" || fail "unknown native error incorrectly relistened indefinitely"
wait_for group_gone "$RUNNER_PID" || fail "unknown native error capture left its group alive"
forget_group "$RUNNER_PID"
assert_present "$HOME_FIXTURE/state/procevent/$SOURCE_ID.source" "unknown native error remains registered"
pass "unknown native error remains exact, announced, and available for reconciliation"

printf 'all runner custody regressions passed\n'
