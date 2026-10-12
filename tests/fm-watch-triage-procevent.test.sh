#!/usr/bin/env bash
# tests/fm-watch-triage-procevent.test.sh - Process-event delivery, recovery acknowledgement, marker identity, and crash replay.
set -u

# shellcheck source=tests/fm-watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-watch-triage-helpers.sh"


test_procevent_captured_result_surfaces_proactively() {
  local dir state out drain_out pid beacon_age
  dir=$(make_case procevent-delivery); state="$dir/state"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  seed_captured_procevent_result "$dir" || fail "the fixture captured no process-event result"
  grep -F "procevent lavish delivery-src 1" "$state/.wake-queue" >/dev/null \
    || fail "the captured result was never published to the durable queue"

  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 \
    || fail "a healthy watcher never surfaced a durably captured process-event result: $(cat "$out")"
  grep -F "check:" "$out" >/dev/null \
    || fail "the process-event wake was not reported as an actionable check: $(cat "$out")"
  grep -F "procevent:delivery-src:1" "$out" >/dev/null \
    || fail "the actionable reason did not name the queued result: $(cat "$out")"
  beacon_age=$(FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; fm_path_age "$2"' _ "$ROOT" "$state/.last-watcher-beat")
  [ "$beacon_age" -lt 60 ] || fail "the surfacing watcher was not a healthy one (beacon age ${beacon_age}s)"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the process-event wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "procevent lavish delivery-src 1" >/dev/null \
    || fail "the process-event result was not queued for the drain that follows the wake"
  pass "a captured process-event result wakes a healthy watcher proactively, with no manual drain"
}


test_procevent_unacknowledged_result_redrains_until_handled() {
  local dir state out replay_out replay_err pid before after sequence generation
  dir=$(make_case procevent-redrain); state="$dir/state"
  out="$dir/watch.out"; replay_out="$dir/replay.out"; replay_err="$dir/replay.err"
  seed_captured_procevent_result "$dir" || fail "the fixture captured no process-event result"

  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "the first proactive wake never happened: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "drain after the first process-event wake failed"

  # An interrupted handler leaves the captured result durable. The successor
  # must re-surface it through recovery, then its drain must print the same row.
  : > "$out"
  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 \
    || fail "an unacknowledged process-event result was not re-surfaced on re-arm: $(cat "$out")"
  grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || fail "the successor did not report recovery for the unacknowledged result: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$replay_out" 2> "$replay_err" \
    || fail "the successor could not re-drain the unacknowledged process-event result"
  grep "$(printf '\tcheck\t')" "$replay_out" | grep -F 'procevent lavish delivery-src 1' >/dev/null \
    || fail "the successor drain did not re-print the durable process-event row"

  pe_case "$dir" handled delivery-src 1 >/dev/null || fail "could not acknowledge the captured result"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$replay_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$replay_err")
  [ -n "$sequence" ] && [ -n "$generation" ] \
    || fail "the replay drain omitted its post-handling acknowledgement boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "completed process-event handling could not acknowledge the replay"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledged process-event replay remained durable"

  before=$(awk 'END { print NR + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  : > "$out"
  procevent_watch_bg "$dir" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    fail "a handled process-event result woke the watcher: $(cat "$out")"
  fi
  reap "$pid"
  after=$(awk 'END { print NR + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  [ "$after" = "$before" ] || fail "a handled result was announced again ($before -> $after queued records)"
  pass "an unacknowledged process-event result re-drains until handling is acknowledged"
}


# Recovery first noticed during a poll must use the same close transition as
# startup recovery. Hold the real delivery recorder after its reason was printed
# but before EXIT cleanup, so the drain's acknowledgement wins that race.
test_recovery_discovered_during_poll_preserves_acknowledgement() {
  local dir state out drain_out drain_err ready release pid sequence generation token
  local FM_TEST_RECOVERY_REAL_CUT
  dir=$(make_case recovery-poll-ack); state="$dir/state"; out="$dir/watch.out"
  drain_out="$dir/drain.out"; drain_err="$dir/drain.err"
  ready="$dir/output-ready"; release="$dir/output-release"
  FM_TEST_RECOVERY_REAL_CUT=$(command -v cut)
  export FM_TEST_RECOVERY_REAL_CUT
  cat > "$dir/fakebin/cut" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -c1-4096 ] && [ -n "${FM_TEST_RECOVERY_OUTPUT_READY:-}" ]; then
  printf '1\n' > "$FM_TEST_RECOVERY_OUTPUT_READY" || exit 1
  i=0
  while [ ! -e "$FM_TEST_RECOVERY_OUTPUT_RELEASE" ]; do
    [ "$i" -lt 1500 ] || exit 1
    sleep 0.02
    i=$((i + 1))
  done
fi
exec "$FM_TEST_RECOVERY_REAL_CUT" "$@"
SH
  chmod +x "$dir/fakebin/cut"
  (
    pid=
    trap 'touch "$release"; if [ -n "$pid" ]; then reap "$pid"; fi' EXIT
    FM_TEST_RECOVERY_OUTPUT_READY="$ready" FM_TEST_RECOVERY_OUTPUT_RELEASE="$release" \
      procevent_watch_bg "$dir" "$out"
    pid=$!
    if ! wait_poll_cycle "$state" "$pid"; then
      fail "the empty-queue watcher did not reach its ordinary poll loop: $(cat "$out")"
    fi
    [ ! -s "$out" ] || fail "the empty-queue watcher printed a wake before late publication: $(cat "$out")"
    append_wake "$state" check late-recovery "check: late recovery fixture" \
      || fail "could not publish the late recovery fixture"
    wait_numeric_file "$ready" 100 \
      || fail "the polling watcher never reached the post-output delivery boundary: $(cat "$out")"
    grep -Fx 'check: rearm-resurface' "$out" >/dev/null \
      || fail "the late durable row was not surfaced through recovery: $(cat "$out")"
    FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2> "$drain_err" \
      || fail "the late recovery row could not be presented before cleanup"
    grep -F "check: late recovery fixture" "$drain_out" >/dev/null \
      || fail "the recovery drain lost the late durable row"
    sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$drain_err")
    generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$drain_err")
    [ -n "$sequence" ] && [ -n "$generation" ] \
      || fail "late recovery presentation omitted its acknowledgement boundary"
    FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
      || fail "late recovery could not be acknowledged before watcher cleanup"
    token=$(cat "$state/.watcher-down")
    [ "$token" = "acked:handling:$generation" ] \
      || fail "the paused watcher did not hold an acknowledged recovery episode: $token"
    [ ! -s "$state/.wake-queue" ] || fail "late recovery acknowledgement left a durable row"
    touch "$release"
    if ! wait_for_exit "$pid" 100; then
      pid=
      fail "the acknowledged recovery watcher did not finish cleanup"
    fi
    pid=
    [ "$(cat "$state/.watcher-down")" = "$token" ] \
      || fail "poll-discovered recovery cleanup republished an acknowledged episode"
    : > "$out"
    procevent_watch_bg "$dir" "$out"
    pid=$!
    if ! wait_poll_cycle "$state" "$pid"; then
      fail "the successor woke after poll-discovered recovery was acknowledged: $(cat "$out")"
    fi
    [ ! -s "$out" ] || fail "the acknowledged recovery successor printed a wake: $(cat "$out")"
    [ ! -s "$state/.wake-queue" ] || fail "the acknowledged recovery successor queued a duplicate wake"
    reap "$pid"
    pid=
    pass "poll-discovered recovery preserves acknowledgement completed before cleanup and leaves its successor quiet"
  ) || fail "poll-discovered recovery acknowledgement regression failed"
}


test_procevent_marker_keys_are_injective() {
  local dir state out pid marker_count
  dir=$(make_case procevent-marker-identity); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:a.b:1" "check: procevent fixture a.b 1"
  append_wake "$state" check "procevent:a_b:1" "check: procevent fixture a_b 1"
  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "colliding-looking process-event keys were not surfaced"
  grep -F "procevent:a.b:1" "$out" >/dev/null || fail "the dotted queue key was suppressed"
  grep -F "procevent:a_b:1" "$out" >/dev/null || fail "the underscored queue key was suppressed"
  marker_count=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | awk 'END { print NR + 0 }')
  [ "$marker_count" = 2 ] || fail "distinct queue keys produced $marker_count seen markers"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "marker identity fixture drain failed"
  pass "complete process-event queue keys map to distinct seen markers"
}


test_procevent_headlines_classify_queue_keys() {
  local dir state out
  dir=$(make_case procevent-headline-captured); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:cap-src:1" "check: procevent lavish cap-src 1"
  surface_once "$dir" "$out" || fail "a captured-result key was not surfaced: $(cat "$out")"
  grep -F "check: process-event result captured: procevent:cap-src:1" "$out" >/dev/null \
    || fail "a captured result did not surface under its own headline: $(cat "$out")"
  ! grep -F "source stranded" "$out" >/dev/null \
    || fail "a captured result was headlined as a strand: $(cat "$out")"
  ! grep -F "failed to start" "$out" >/dev/null \
    || fail "a captured result was headlined as a failed start: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "captured headline fixture drain failed"

  dir=$(make_case procevent-headline-stranded); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:str-src:stranded:tok-1" "check: process-event source str-src is registered but nothing can arm it"
  surface_once "$dir" "$out" || fail "a stranded key was not surfaced: $(cat "$out")"
  grep -F "check: process-event source stranded: procevent:str-src:stranded:tok-1" "$out" >/dev/null \
    || fail "a stranded source did not surface under its own headline: $(cat "$out")"
  ! grep -F "result captured" "$out" >/dev/null \
    || fail "a stranded source was headlined as a captured result: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "stranded headline fixture drain failed"

  dir=$(make_case procevent-headline-joined); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:cap2-src:1" "check: procevent lavish cap2-src 1"
  append_wake "$state" check "procevent:str2-src:stranded:tok-2" "check: process-event source str2-src is registered but nothing can arm it"
  surface_once "$dir" "$out" || fail "a mixed cycle was not surfaced: $(cat "$out")"
  grep -F "check: process-event result captured: procevent:cap2-src:1; process-event source stranded: procevent:str2-src:stranded:tok-2" "$out" >/dev/null \
    || fail "a cycle with a capture and a strand did not carry both headlines joined: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "joined headline fixture drain failed"
  pass "process-event queue keys surface under their own headlines"
}


# Delivery, not queue rows, is what proves a launch-failure episode reaches
# firstmate. The watcher remembers every procevent key it has surfaced for
# good, so reconcile keys each episode with a fresh suffix beyond the
# registration identity: this test would fail if a second episode reused the
# first one's key, because the watcher would keep polling and never wake.
test_procevent_launch_failed_episodes_are_each_delivered() {
  local dir state out status
  dir=$(make_case procevent-launch-failed-episodes); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:lf-src:launch-failed:1-2-100-7" \
    "check: process-event source lf-src is registered but its launch did not prove it took the claim"
  surface_once "$dir" "$out" || fail "a launch-failed key was not surfaced: $(cat "$out")"
  grep -F "check: process-event source failed to start: procevent:lf-src:launch-failed:1-2-100-7" "$out" >/dev/null \
    || fail "a failed launch did not surface under its own headline: $(cat "$out")"
  ! grep -F "result captured" "$out" >/dev/null \
    || fail "a failed launch was headlined as a captured result: $(cat "$out")"
  ack_stopped_cycle "$state" >/dev/null || fail "launch-failed fixture could not be handled and acknowledged"

  # The same key again is what a registration-identity-only key would produce
  # for the next episode: already surfaced, so the process-event surface never
  # delivers it under its headline again. A fresh watcher still recovers the
  # unacknowledged queue row through the generic `check: rearm-resurface`
  # path (the contract test_procevent_unacknowledged_result_redrains_until_handled
  # proves), so what this asserts is the headline, not silence.
  append_wake "$state" check "procevent:lf-src:launch-failed:1-2-100-7" \
    "check: process-event source lf-src is registered but its launch did not prove it took the claim"
  : > "$out"
  status=0
  surface_once "$dir" "$out" 30 || status=$?
  case "$status" in
    124) ;;
    0)
      # The one wake this tolerates is the recovery path named above, by its
      # exact reason line. A wake for any other reason would mean either that
      # the ordinary surface delivered the repeated key after all, or that
      # something unrelated fired inside the window - and both are failures of
      # exactly what this test guards, so neither may pass as "recovery".
      grep -F 'check: rearm-resurface' "$out" >/dev/null \
        || fail "an already-surfaced launch-failed key woke the watcher, and the reason was not the one tolerated recovery path (expected the exact line 'check: rearm-resurface'; if that path was reworded, update this expectation, do not restore the strict silence check): $(cat "$out")"
      ;;
    *) fail "the watcher failed on an already-surfaced launch-failed key (status $status): $(cat "$out")" ;;
  esac
  ! grep -F "failed to start: procevent:lf-src:launch-failed:1-2-100-7" "$out" >/dev/null \
    || fail "an already-surfaced launch-failed key was delivered again under its headline: $(cat "$out")"
  ack_stopped_cycle "$state" >/dev/null || fail "repeated-key fixture could not be handled and acknowledged"

  # A later episode of the same registration carries the same identity under a
  # fresh suffix, and that one must be delivered.
  append_wake "$state" check "procevent:lf-src:launch-failed:1-2-160-9" \
    "check: process-event source lf-src is registered but its launch did not prove it took the claim"
  : > "$out"
  surface_once "$dir" "$out" || fail "a second launch-failure episode was not surfaced: $(cat "$out")"
  grep -F "check: process-event source failed to start: procevent:lf-src:launch-failed:1-2-160-9" "$out" >/dev/null \
    || fail "a second launch-failure episode did not surface under its own headline: $(cat "$out")"
  ack_stopped_cycle "$state" >/dev/null || fail "second episode fixture could not be handled and acknowledged"
  pass "every launch-failure episode is delivered under the failed-to-start headline"
}


test_procevent_surface_serializes_with_drain() {
  local dir state out drain_out ready release pid drain_pid
  dir=$(make_case procevent-drain-race); state="$dir/state"; out="$dir/watch.out"
  drain_out="$dir/drain.out"; ready="$dir/marker-ready"; release="$dir/marker-release"
  append_wake "$state" check "procevent:drain-race:1" "check: procevent fixture drain-race 1"
  install_marker_mv_fault "$dir"
  FM_MARKER_MV_MODE=pause FM_MARKER_MV_READY="$ready" FM_MARKER_MV_RELEASE="$release" \
    procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_numeric_file "$ready" 100 || fail "the watcher never reached its marker commit boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" &
  drain_pid=$!
  wait_live "$drain_pid" 10 || fail "a concurrent drain split the surfacing transition"
  [ -s "$state/.wake-queue" ] || fail "the concurrent drain consumed the record before marker commit"
  touch "$release"
  wait "$pid" || fail "the paused watcher did not finish surfacing"
  wait "$drain_pid" || fail "the concurrent drain failed after surfacing committed"
  grep -F "procevent:drain-race:1" "$drain_out" >/dev/null \
    || fail "the serialized drain lost the process-event record"
  pass "queue revalidation, proactive output, and marker commit serialize with drain"
}


test_procevent_surface_crash_boundaries() {
  local dir state out fifo pid reader marker exit_status replay_err sequence generation
  dir=$(make_case procevent-output-fail); state="$dir/state"; out="$dir/watch.out"; fifo="$dir/output.fifo"
  append_wake "$state" check "procevent:output-fail:1" "check: procevent fixture output-fail 1"
  mkfifo "$fifo"
  sh -c ': < "$1"' _ "$fifo" & reader=$!
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$fifo" &
  pid=$!
  wait "$reader" || true
  wait_for_exit "$pid" 100
  exit_status=$?
  [ "$exit_status" -ne 124 ] || fail "the watcher survived a failed actionable output write"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -z "$marker" ] || fail "failed output committed a suppression marker"
  [ -s "$state/.wake-queue" ] || fail "failed output consumed the durable queue record"
  procevent_watch_bg "$dir" "$out"; pid=$!
  wait_for_exit "$pid" 100 || fail "the record was not replayable after output failure"
  grep -F "procevent:output-fail:1" "$out" >/dev/null || fail "output failure lost proactive replay"

  dir=$(make_case procevent-before-marker); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:before-marker:1" "check: procevent fixture before-marker 1"
  install_marker_mv_fault "$dir"
  FM_MARKER_MV_MODE=kill-before procevent_watch_bg "$dir" "$out"; pid=$!
  wait_for_exit "$pid" 100
  exit_status=$?
  [ "$exit_status" -ne 124 ] || fail "the watcher survived the injected pre-marker crash"
  grep -F "procevent:before-marker:1" "$out" >/dev/null || fail "the pre-marker crash happened before output"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -z "$marker" ] || fail "a pre-marker crash committed suppression"
  procevent_watch_bg "$dir" "$out.replay"; pid=$!
  wait_for_exit "$pid" 100 || fail "a pre-marker crash was not replayable"

  dir=$(make_case procevent-after-marker); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:after-marker:1" "check: procevent fixture after-marker 1"
  install_marker_mv_fault "$dir"
  FM_MARKER_MV_MODE=kill-after procevent_watch_bg "$dir" "$out"; pid=$!
  wait_for_exit "$pid" 100
  exit_status=$?
  [ "$exit_status" -ne 124 ] || fail "the watcher survived the injected post-marker crash"
  grep -F "procevent:after-marker:1" "$out" >/dev/null || fail "the post-marker crash lost actionable output"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -n "$marker" ] || fail "the post-marker crash did not reach marker commit"
  : > "$out.replay"
  procevent_watch_bg "$dir" "$out.replay"; pid=$!
  wait_for_exit "$pid" 100 \
    || fail "an unacknowledged delivered record was not re-surfaced on re-arm: $(cat "$out.replay")"
  grep -F 'check: rearm-resurface' "$out.replay" >/dev/null \
    || fail "the successor did not recover the delivered-but-unacknowledged record: $(cat "$out.replay")"
  replay_err="$out.replay.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out.replay.drain" 2> "$replay_err" \
    || fail "post-marker successor drain failed"
  grep "$(printf '\tcheck\t')" "$out.replay.drain" | grep -F 'procevent fixture after-marker 1' >/dev/null \
    || fail "post-marker successor did not re-drain the durable record"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$replay_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$replay_err")
  [ -n "$sequence" ] && [ -n "$generation" ] \
    || fail "post-marker replay omitted its post-handling acknowledgement boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "post-marker replay acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "post-marker acknowledgement left the durable record queued"
  pass "surfacing failures replay until post-handling acknowledgement"
}


test_procevent_marker_failure_exits_and_replays() {
  local dir state out pid marker output_count
  dir=$(make_case procevent-marker-failure); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:marker-failure:1" "check: procevent fixture marker-failure 1"
  install_marker_mv_fault "$dir"
  FM_MARKER_MV_MODE=fail procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "marker failure did not end the actionable watcher cycle successfully"
  output_count=$(grep -Fc "procevent:marker-failure:1" "$out" || true)
  [ "$output_count" = 1 ] || fail "marker failure printed the actionable reason $output_count times"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -z "$marker" ] || fail "marker failure committed suppression"
  [ ! -e "$state/.wake-queue.lock" ] && [ ! -L "$state/.wake-queue.lock" ] \
    || fail "marker failure left the queue lock held"
  procevent_watch_bg "$dir" "$out.replay"
  pid=$!
  wait_for_exit "$pid" 100 || fail "marker failure did not leave the durable record replayable"
  grep -F "procevent:marker-failure:1" "$out.replay" >/dev/null \
    || fail "marker failure lost the later proactive replay"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "marker-failure fixture drain failed"
  pass "marker failure exits through the shared wake owner, releases its lock, and replays later"
}

# FM_TEST_ONLY runs one named case without the rest of this group.
if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
  exit 0
fi

test_procevent_captured_result_surfaces_proactively
test_procevent_unacknowledged_result_redrains_until_handled
test_recovery_discovered_during_poll_preserves_acknowledgement
test_procevent_marker_keys_are_injective
test_procevent_headlines_classify_queue_keys
test_procevent_launch_failed_episodes_are_each_delivered
test_procevent_surface_serializes_with_drain
test_procevent_surface_crash_boundaries
test_procevent_marker_failure_exits_and_replays
