#!/usr/bin/env bash
# A held unrelated source mutex must not delay a public listener's next answer.
set -u
BOOTSTRAP=$(mktemp -d "$(dirname "${BASH_SOURCE[0]}")/../.fm-backlog-test.XXXXXX") || exit 1
export TMPDIR="$BOOTSTRAP"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-procevent-runner-backlog)
export FM_HOME="$TMP_ROOT/home" FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export TMPDIR="$TMP_ROOT" LAVISH_AXI_STATE_DIR="$TMP_ROOT/lavish-state"
mkdir -p "$FM_HOME/state" "$LAVISH_AXI_STATE_DIR"
fm_test_track_procevent_home "$FM_HOME" "$FM_PROCEVENT_CLAIM_ROOT"
HOLDER_PID=''
cleanup() {
  : > "$TMP_ROOT/release-lock"
  [ -z "$HOLDER_PID" ] || wait "$HOLDER_PID" 2>/dev/null || true
  fm_test_cleanup
  rm -rf -- "$BOOTSTRAP"
}
trap cleanup EXIT
wait_for() {
  local i
  for i in $(seq 1 100); do "$@" && return 0; sleep 0.1; done
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
while [ ! -f "$artifact.answer$n" ]; do sleep 0.05; done
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
  cp "$ARTIFACT.expected$round" "$ARTIFACT.answer$round.tmp" \
    && mv -f -- "$ARTIFACT.answer$round.tmp" "$ARTIFACT.answer$round" \
    || fail "round $round answer publication failed"
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
