#!/usr/bin/env bash
# Behavior tests for the generic process-to-event runner and its Lavish adapter.
#
# The source under test is a fake blocking process that returns only when its
# trigger file appears, so completion is a real process event and no test here
# depends on a discovery timer. The Lavish adapter is exercised through its own
# public commands against the currently published poll shape; no live Lavish
# server is started.
#
# Delivery is deliberately NOT asserted as at-least-once or lossless: the
# published Lavish poll clears feedback destructively before returning it, so
# the only durability under test is the runner's own - output that reached the
# runner is stored before it is announced.
set -u

# shellcheck source=tests/lib.sh
. "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5G1E133H37VH68X05J0GD12/tests/lib.sh"

ROOT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5G1E133H37VH68X05J0GD12
TMP_ROOT=$(fm_test_tmproot fm-procevent-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export LAVISH_AXI_STATE_DIR="$TMP_ROOT/lavish-state"
mkdir -p "$LAVISH_AXI_STATE_DIR"

# Lavish owns this persisted session contract. The fake CLI fixtures exercise
# its published poll and synchronous reply command boundaries without starting a server.
lavish_session() {  # <artifact> [session-url]
  perl -MJSON::PP -MCwd=realpath -MDigest::SHA=sha256_hex -MEncode=decode -e '
    my ($path, $artifact, $url) = @ARGV;
    my $real = realpath($artifact) // die "missing fixture artifact";
    my $key = substr(sha256_hex($real), 0, 16);
    my $state = { sessions => {} };
    if (-f $path) { open my $in, "<", $path or die $!; local $/; $state = decode_json(<$in>); }
    $state->{sessions}{$key} = {
      key => $key, file => decode("UTF-8", $real), status => "open", url => $url,
    };
    open my $out, ">", $path or die $!;
    print $out encode_json($state);
  ' "$LAVISH_AXI_STATE_DIR/state.json" "$1" "${2:-http://127.0.0.1:14387/session/0123456789abcdef}"
}

BLOCKER="$TMP_ROOT/blocker.sh"
cat > "$BLOCKER" <<'SH'
#!/usr/bin/env bash
# Blocks until the trigger exists, then emits its payload. Completion is the
# event; nothing here polls on a schedule. The wait is bounded so a stub that
# escapes its test cannot keep spawning processes indefinitely.
trigger=$1; shift
while [ ! -e "$trigger" ]; do
  [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ] || exit 75
  sleep 0.05
done
[ -n "${BLOCKER_STDERR:-}" ] && printf 'noise on stderr\n' >&2
[ -n "${BLOCKER_EXIT:-}" ] && exit "$BLOCKER_EXIT"
printf '%s\n' "$@"
SH
chmod +x "$BLOCKER"

# Records that the wrapped command actually started, then becomes it. A claim
# only proves its runner got as far as claiming; a test that needs the runner
# already inside its source command waits for this marker instead of a settle
# window, because a runner still short of that command retires itself when its
# registration goes away.
STARTED_BLOCKER="$TMP_ROOT/started-blocker.sh"
cat > "$STARTED_BLOCKER" <<'SH'
#!/usr/bin/env bash
printf 'started\n' > "$1"
shift
exec "$@"
SH
chmod +x "$STARTED_BLOCKER"

pe() { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }

# Every home this suite registers a source in is tracked so teardown can stop
# its runners. A runner started by reconcile is detached and reparented, so a
# source that never completes outlives the suite unless its home is swept -
# removing the fixture directory does not stop an already-running child.
# tests/lib.sh owns that sweep and runs it from every cleanup path.
pe_register() {  # <home> <adapter> <source-id> -- <argv>...
  local home=$1 adapter=$2 id=$3
  shift 3
  fm_test_track_procevent_home "$home"
  pe "$home" register "$adapter" "$id" "$@"
}
new_home() { mkdir -p "$1/state"; }
# A worker-owned board can only be armed for a task whose endpoint metadata the
# runner can ring, so every fixture worker needs the same durable record a real
# spawn leaves behind.
new_task_endpoint() {  # <home> <task-id>
  mkdir -p "$1/state"
  printf 'window=fmtest:fm-%s\nworktree=%s/worktree-%s\nproject=fmtest\n' "$2" "$1" "$2" \
    > "$1/state/$2.meta"
}
wake_payloads() { awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null; }

# The wake queue is a durable tab-separated record firstmate consumes:
# <epoch> <sequence> <kind> <key> <payload>. These read the rows reconcile
# publishes for a source it stranded, keyed by that source and its claim
# generation.
stranded_wake_keys() {  # <home> <source-id>
  [ -e "$1/state/.wake-queue" ] || return 0
  awk -F '\t' -v id="$2" \
    '$3 == "check" && index($4, "procevent:" id ":stranded:") == 1 { print $4 }' \
    "$1/state/.wake-queue"
}
stranded_wake_count() {  # <home> <source-id>
  stranded_wake_keys "$1" "$2" | grep -c . || true
}
stranded_wake_payloads() {  # <home> <source-id>
  [ -e "$1/state/.wake-queue" ] || return 0
  awk -F '\t' -v id="$2" \
    '$3 == "check" && index($4, "procevent:" id ":stranded:") == 1 { print $5 }' \
    "$1/state/.wake-queue"
}
# The same rows for a launch reconcile could not confirm, keyed by that source
# and the registration identity the launch ran under.
launch_failed_wake_keys() {  # <home> <source-id>
  [ -e "$1/state/.wake-queue" ] || return 0
  awk -F '\t' -v id="$2" \
    '$3 == "check" && index($4, "procevent:" id ":launch-failed:") == 1 { print $4 }' \
    "$1/state/.wake-queue"
}
launch_failed_wake_count() {  # <home> <source-id>
  launch_failed_wake_keys "$1" "$2" | grep -c . || true
}

first_result() {  # <home> <source-id>: print the first captured result, if any
  local g
  for g in "$1/state/procevent-inbox/$2".*.result; do
    [ -e "$g" ] || continue
    printf '%s\n' "$g"
    return 0
  done
  return 1
}

count_results() {  # <home> <source-id>
  local g n=0
  for g in "$1/state/procevent-inbox/$2".*.result; do
    [ -e "$g" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

wait_for() {  # <file> [tries]
  local f=$1 n=${2:-100}
  for _ in $(seq 1 "$n"); do [ -s "$f" ] && return 0; sleep 0.1; done
  return 1
}

wait_for_lines() {
  local f=$1 want=$2 n=${3:-100} have
  for _ in $(seq 1 "$n"); do
    if [ -f "$f" ]; then
      have=$(wc -l < "$f" | tr -d ' ')
    else
      have=0
    fi
    case "$have" in ''|*[!0-9]*) have=0 ;; esac
    [ "$have" -ge "$want" ] && return 0
    sleep 0.1
  done
  return 1
}
CONT="$TMP_ROOT/continuous-lavish"
mkdir -p "$CONT/bin" "$CONT/home/state"
cat > "$CONT/bin/lavish-axi" <<'SH'
#!/usr/bin/env bash
mkdir "$CONT/current-poller" || { touch "$CONT/duplicate"; exit 1; }
trap 'rmdir "$CONT/current-poller"' EXIT
n=$(cat "$CONT/count" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$CONT/count"
printf '%s\n' "$n" >> "$CONT/started"
while [ ! -f "$CONT/round$n" ]; do
  [ "$SECONDS" -lt 120 ] || exit 75
  sleep 0.05
done
cat "$CONT/round$n"
SH
chmod +x "$CONT/bin/lavish-axi"
export CONT
cont_art="$CONT/review.html"
printf '<h1>continuous review</h1>\n' > "$cont_art"
lavish_session "$cont_art"
cont_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$cont_art")
fm_test_track_procevent_home "$CONT/home"
cont_rc=0
PATH="$CONT/bin:$PATH" FM_HOME="$CONT/home" FM_LAVISH_POLL_RETRY_DELAY=1 \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$cont_art" > "$CONT/arm.out" 2> "$CONT/arm.err" || cont_rc=$?
[ "$cont_rc" -eq 0 ] \
  || fail "the continuous listener arm failed ($cont_rc): $(cat "$CONT/arm.err")"
assert_contains "$(cat "$CONT/arm.out")" "armed: $cont_id" "the continuous listener was not reported ready"
wait_for_lines "$CONT/started" 1 || fail "continuous listener never started"
cont_claim=$(cat "$FM_PROCEVENT_CLAIM_ROOT/$cont_id.claim")
if ! { printf 'session:\n  status: browser_disconnected\n' > "$CONT/round1.tmp" \
  && mv -f -- "$CONT/round1.tmp" "$CONT/round1"; }; then
  fail "disconnect round publication failed"
fi
wait_for_lines "$CONT/started" 2 || fail "disconnect did not resume listening without reconcile"
assert_present "$CONT/home/state/procevent-inbox/$cont_id.1.handled" \
  "the disconnect remains a silent no-op"
: > "$CONT/round2"
wait_for_lines "$CONT/started" 3 || fail "empty poll return stranded the listener"
# lavish-axi 0.1.79 refuses a poll while a leftover poller holds the page.
if ! { printf '%s\n' 'error: "Lavish Editor already has an active poll listener (current listener: agent-listener; active for 11175ms)"' \
  'code: LISTENER_ACTIVE' 'help[1]: Use --takeover only when you intend to displace the current listener' > "$CONT/round3.tmp" \
  && mv -f -- "$CONT/round3.tmp" "$CONT/round3"; }; then
  fail "held-page round publication failed"
fi
wait_for_lines "$CONT/started" 4 || fail "a page held by a leftover poller stranded the listener"
if ! { printf 'session:\n  status: feedback\nprompts[1]{tag,prompt}:\n  message,first answer\n' > "$CONT/round4.tmp" \
  && mv -f -- "$CONT/round4.tmp" "$CONT/round4"; }; then
  fail "first answer publication failed"
fi
wait_for_lines "$CONT/started" 5 || fail "unhandled answer stranded the listener"
assert_absent "$CONT/home/state/procevent-inbox/$cont_id.4.handled" \
  "keeping the listener never acknowledges the answer"
if ! { printf 'session:\n  status: feedback\nprompts[1]{tag,prompt}:\n  message,second answer\n' > "$CONT/round5.tmp" \
  && mv -f -- "$CONT/round5.tmp" "$CONT/round5"; }; then
  fail "second answer publication failed"
fi
wait_for_lines "$CONT/started" 6 || fail "second answer stranded the listener"
assert_contains "$(wake_payloads "$CONT/home")" "procevent lavish $cont_id 4" \
  "first answer is announced with its own sequence"
assert_contains "$(wake_payloads "$CONT/home")" "procevent lavish $cont_id 5" \
  "second answer is announced with its own sequence"
[ "$(cat "$FM_PROCEVENT_CLAIM_ROOT/$cont_id.claim")" = "$cont_claim" ] \
  || fail "nonterminal rounds replaced the exclusive owner"
PATH="$CONT/bin:$PATH" pe "$CONT/home" start "$cont_id" >/dev/null \
  || fail "fixture step failed: start CONT"
[ "$(cat "$CONT/count")" = 6 ] || fail "a competing start opened a duplicate poll"
assert_absent "$CONT/duplicate" "each source has at most one active polling child"
assert_contains "$(pe "$CONT/home" list --age)" "$cont_id" "age report retains the open review"
age_row=$(pe "$CONT/home" list --age | awk -v id="$cont_id" '$1 == id { print $3, $5 }')
case "$age_row" in live\ [0-9]*) ;; *) fail "age report did not show live owner and numeric age: $age_row" ;; esac
if ! { printf 'session:\n  status: ended\n  ended_by: user\n' > "$CONT/round6.tmp" \
  && mv -f -- "$CONT/round6.tmp" "$CONT/round6"; }; then
  fail "ended round publication failed"
fi
for _ in $(seq 1 100); do
  [ -e "$CONT/home/state/procevent/$cont_id.source" ] || break
  sleep 0.1
done
assert_absent "$CONT/home/state/procevent/$cont_id.source" "user-ended review retires automatically"
PATH="$CONT/bin:$PATH" pe "$CONT/home" reconcile >/dev/null \
  || fail "fixture step failed: reconcile CONT"
[ "$(cat "$CONT/count")" = 6 ] || fail "ended review reopened its listener"
pass "one exclusive listener survives disconnects and multiple unhandled answers, then retires on user end"
