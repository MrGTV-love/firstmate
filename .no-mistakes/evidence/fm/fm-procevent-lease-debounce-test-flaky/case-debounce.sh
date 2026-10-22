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

# The runner writes its marker twice at startup, each time truncating before it
# writes the same PID, so a file that is merely nonempty can be empty again by
# the time it is read. Validate the value actually read: only a complete numeric
# line is a PID, and anything else keeps polling and ends in a nonzero status
# with nothing printed, never an empty PID for the caller to use.
runner_pid() {  # <runner-marker> [tries]
  local f=$1 n=${2:-100} pid
  for _ in $(seq 1 "$n"); do
    if IFS= read -r pid 2>/dev/null < "$f"; then
      case $pid in
        ''|*[!0-9]*) ;;
        *) printf '%s\n' "$pid"; return 0 ;;
      esac
    fi
    sleep 0.1
  done
  return 1
}

# the churning stub by the owner-loss reaping above, which asserts the tick log
# stops, so this home only needs a reparented listener holding a real
# descendant in its group.
QUIET_STUB="$TMP_ROOT/quiet-stub.sh"
cat > "$QUIET_STUB" <<'SH'
#!/usr/bin/env bash
marker=$1
( sleep "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ) &
printf '%s\n' "$!" > "$marker.descendant"
while [ ! -e "$marker.trigger" ]; do
  [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ] || exit 75
  sleep 0.1
done
printf 'orphan payload\n'
SH
chmod +x "$QUIET_STUB"

# Short enough to observe, and driven through the same environment a real home
# uses, so the bound under test is the shipped one rather than a test-only path.
# One source of truth for the shortened lease and check these fixtures run under,
# so a case that derives a deadline from the guard's documented bound cannot
# silently diverge from the settings the guard is actually given.
PROOF_LEASE_SECONDS=2
PROOF_CHECK_SECONDS=1

# The documented bound, derived here rather than restated as a flat number.
#
# The whole-second lease comparison is part of the bound, not slack: a lease of
# N is honoured until its age reads N+1, so the lease term is N+1.
PROOF_LEASE_BOUND=$((PROOF_LEASE_SECONDS + 1))
# Detection is the lease plus ONE check interval. The guard still takes two
# consecutive failing reads before it acts - one unreadable read must not end a
# live runner - but they are spaced half an interval apart, so the pair fits
# inside the single interval this term budgets.
PROOF_DETECT_BOUND=$((PROOF_LEASE_BOUND + PROOF_CHECK_SECONDS))
# The stop's own ceiling: two seconds for the ordinary signal, then two for the
# forced one. Only a group that outlives the ordinary signal spends it, so a
# case whose stub exits on that signal uses PROOF_PROMPT_STOP instead.
PROOF_STOP_CEILING=4
PROOF_PROMPT_STOP=1
# Additive scheduling slack shared by cleanup and timing cases. The strict
# timing case below owns and enforces its relation to BOUND_CHECK_SECONDS.
PROOF_LOAD_SLACK=2

orphan_pe() {  # <home> <command...>
  local home=$1
  shift
  FM_PROCEVENT_OWNER_LEASE_SECONDS="$PROOF_LEASE_SECONDS" \
    FM_PROCEVENT_OWNER_CHECK_SECONDS="$PROOF_CHECK_SECONDS" \
    FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" "$@"
}

wait_gone() {  # <pid-or-group-spec> [tries]
  local spec=$1 n=${2:-160}
  for _ in $(seq 1 "$n"); do
    kill -0 "$spec" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}
# --- one unreadable read still does not end a live runner --------------------
#
# The bound above was tightened by moving the guard's two reads closer together,
# NOT by dropping the second one. This is what that second read is for, asserted
# separately so the two cannot be traded for each other by accident: against a
# home that is still alive, an isolated failed read must not stop the runner.
#
# Inject at the lease-age command boundary: ONE read fails after startup and
# every other age is zero. A real lease refreshed only during reconcile can
# expire while a loaded host schedules startup or the observation, making the
# supposed isolated failure into consecutive misses. Expiry and detection bounds
# have their own real-clock cases above; this case isolates read recovery.

DEBOUNCE_HOME="$TMP_ROOT/lease-debounce"; new_home "$DEBOUNCE_HOME"
fm_test_track_procevent_home "$DEBOUNCE_HOME"
DEBOUNCE_STATE="$TMP_ROOT/lease-debounce-state"; mkdir -p "$DEBOUNCE_STATE"
DEBOUNCE_BIN=$(fm_fakebin "$TMP_ROOT/lease-debounce-bin")
REAL_PERL=$(command -v perl) || fail "this host has no perl to build the debounce fixture on"
cat > "$DEBOUNCE_BIN/perl" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case \$arg in
    *'int(\$now - \$value)'*)
      if [ -s "\$LEASE_DEBOUNCE_STATE/armed" ]; then
        if [ ! -s "\$LEASE_DEBOUNCE_STATE/spent" ]; then
          printf 'spent\n' > "\$LEASE_DEBOUNCE_STATE/spent"
          exit 1
        elif [ ! -s "\$LEASE_DEBOUNCE_STATE/recovered" ]; then
          printf 'recovered\n' > "\$LEASE_DEBOUNCE_STATE/recovered"
        else
          printf 'observed\n' > "\$LEASE_DEBOUNCE_STATE/observed"
        fi
      fi
      printf '0\n'
      exit 0
      ;;
  esac
done
exec "$REAL_PERL" "\$@"
SH
chmod +x "$DEBOUNCE_BIN/perl"

# Keep the ordinary lease/check settings; freshness is supplied independently
# above, so scheduling delay cannot manufacture another failed lease check.
DEBOUNCE_LEASE_SECONDS=30
DEBOUNCE_CHECK_SECONDS=1
debounce_pe() {
  PATH="$DEBOUNCE_BIN:$PATH" LEASE_DEBOUNCE_STATE="$DEBOUNCE_STATE" \
    FM_PROCEVENT_OWNER_LEASE_SECONDS="$DEBOUNCE_LEASE_SECONDS" \
    FM_PROCEVENT_OWNER_CHECK_SECONDS="$DEBOUNCE_CHECK_SECONDS" \
    FM_HOME="$DEBOUNCE_HOME" "$ROOT/bin/fm-procevent.sh" "$@"
}
debounce_pe register lavish debounce-src -- "$QUIET_STUB" "$TMP_ROOT/lease-debounce-marker" >/dev/null \
  || fail "fixture step failed: register debounce-src"
debounce_pe reconcile >/dev/null \
  || fail "fixture step failed: reconcile debounce_pe"
wait_for "$TMP_ROOT/lease-debounce-marker.descendant" \
  || fail "the debounce fixture's source never started"
DEBOUNCE_PID=$(runner_pid "$DEBOUNCE_HOME/state/procevent/debounce-src.runner") \
  || fail "the debounce fixture's listener never recorded its runner"
# Armed only now. The guard proves the lease once before it reports ready, and
# failing THAT read would refuse the runner outright instead of exercising the
# debounce this case is about.
printf 'armed\n' > "$DEBOUNCE_STATE/armed"
wait_for "$DEBOUNCE_STATE/spent" \
  || fail "the single failed lease read this case injects never happened"
# The next read can begin only after the guard consumed the recovery result.
# Waiting for that causal boundary proves the guard advanced past the miss;
# a fixed observation sleep neither proves recovery nor keeps a lease fresh.
wait_for "$DEBOUNCE_STATE/observed" \
  || fail "one unreadable lease read ended a runner whose home was still alive"
kill -0 -"$DEBOUNCE_PID" 2>/dev/null \
  || fail "one unreadable lease read ended a runner whose home was still alive"
debounce_pe retire debounce-src >/dev/null \
  || fail "retiring the debounce fixture's source reported failure"
wait_gone "-$DEBOUNCE_PID" \
  || fail "retiring the debounce fixture left its process group running"
pass "one unreadable read does not end a live runner"
