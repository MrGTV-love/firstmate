#!/usr/bin/env bash
# tests/fm-watch-takeover.test.sh - the supervision host's take-over of a watcher cycle
# (bin/fm-watch-arm.sh --take-over) must neither kill a watcher inside a prelude step nor
# open a recovery episode over work main already acknowledged.
#
# The cases run the real Claude Stop hook, supervision host, arm and watcher in a fixture
# home (tests/fm-supervision-host-helpers.sh). Two things are observed from outside, the
# scripts under test are never edited:
#   - kill(): an exported function that shadows the builtin in every child bash and logs
#     "<pid> <signal> <target>" before running it (the scripts call the builtin).
#   - stubs: a copy of bin/ whose bin/fm-inactive-reconcile.sh (prelude step 9, run inside a
#     command substitution) or a registered check (prelude step 10) blocks while a trigger
#     file exists and writes an in-flight marker for as long as it blocks; a PATH md5 shim
#     does the same inside the stale-pane loop, which runs outside the prelude.
# Bash defers a stop signal while a command substitution child runs, so a TERM sent into
# any of those spans lands late: the arm used to give up after 5 s, attach, and leave the
# stopped watcher's close publishing a fresh pending downtime that the next watcher
# announced as an empty `check: rearm-resurface`, about every 100 s.
# shellcheck disable=SC2016 # fixture scripts expand in their own shells
set -u

# shellcheck source=tests/fm-supervision-host-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-supervision-host-helpers.sh"

LOOP_CYCLES=${FM_TEST_LOOP_CYCLES:-2}
# The block must outlast the arm's old 5 s wait however slowly a loaded or confined host runs its
# liveness probes (a probe through a stand-in ps took the base's 50 polls to about 10 s).
BLOCK_SECS=${FM_TEST_BLOCK_SECS:-25}

# --- instrumentation -----------------------------------------------------------
kill() {
  local o
  case "${1:-}" in
    -l|-L)
      # bash 3.2 prints SIGTERM for `kill -l 15` once kill is a function; the arm's
      # cycle ledger needs the builtin's TERM.
      o=$(builtin kill "$@") || return $?
      printf '%s\n' "${o#SIG}"
      return 0 ;;
  esac
  printf '%s %s\n' "${BASHPID:-$$}" "$*" >> "${FM_TEST_KILL_LOG:-/dev/null}"
  [ -z "${FM_TEST_KILL_SRC_LOG:-}" ] || printf '%s:%s\n' "${BASH_SOURCE[1]##*/}" "${BASH_LINENO[0]}" >> "$FM_TEST_KILL_SRC_LOG"
  builtin kill "$@"
}
export -f kill

test_kill_shim_logs_a_known_kill_and_keeps_signal_names() {
  local log p
  log="$TMP_ROOT/kill-selftest.log"
  : > "$log"
  FM_TEST_KILL_LOG=$log sleep 30 &
  p=$!
  FM_TEST_KILL_LOG=$log kill -TERM "$p"
  wait "$p" 2>/dev/null
  FM_TEST_KILL_LOG=$log bash -c 'kill -0 $$'
  grep -q -- " -TERM $p\$" "$log" || fail "the kill shim did not log a known TERM: $(cat "$log")"
  grep -q -- ' -0 ' "$log" || fail "the kill shim did not log a liveness probe"
  [ "$(bash -c 'kill -l 15')" = TERM ] || fail "the kill shim changed the name kill -l prints"
  pass "take-over fixture: the kill shim logs a known kill and keeps kill -l TERM"
}

# --- fixtures ------------------------------------------------------------------
# A primary home whose bin/ is a farm of links, so a case can replace one helper script.
make_stub_home() {  # <name>
  local home
  home=$(make_home "$1" attended)
  git init -q "$home"
  : > "$home/AGENTS.md"
  # A farm of links to the real bin/, so node resolves its modules through the real
  # files and only the stubbed helpers differ; scripts keep their logical $home/bin dir.
  mkdir "$home/bin"
  local f
  for f in "$ROOT"/bin/*; do ln -s "$f" "$home/bin/${f##*/}"; done
  rm -f "$home/bin/fm-inactive-reconcile.sh"
  ln -s "$ROOT/.agents" "$home/.agents" 2>/dev/null || true
  # Prelude step 9 runs this inside a command substitution (bin/fm-watch.sh prelude_phase).
  cat > "$home/bin/fm-inactive-reconcile.sh" <<'SH'
#!/usr/bin/env bash
# Stub: block while $FM_HOME/block-step9 exists, marking that it is blocking.
if [ -e "$FM_HOME/block-step9" ]; then
  : > "$FM_HOME/inflight-step9"
  i=0
  while [ -e "$FM_HOME/block-step9" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
  rm -f "$FM_HOME/inflight-step9"
  : > "$FM_HOME/done-step9"
fi
exit 0
SH
  chmod +x "$home/bin/fm-inactive-reconcile.sh"
  # Prelude step 10 (the custom-check sweep): an authenticated check that blocks.
  cat > "$home/state/slow.check.sh" <<'SH'
#!/usr/bin/env bash
if [ -e "$FM_HOME/block-step10" ]; then
  : > "$FM_HOME/inflight-step10"
  i=0
  while [ -e "$FM_HOME/block-step10" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
  rm -f "$FM_HOME/inflight-step10"
  : > "$FM_HOME/done-step10"
fi
exit 0
SH
  chmod 700 "$home/state/slow.check.sh"
  register_check "$home" slow
  # The stale-pane loop (outside the prelude) hashes each pane in a command substitution.
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) exit 0 ;;
  capture-pane) printf 'pane %s %s\n' "$RANDOM" "$(date +%s)"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$home/fakebin/tmux"
  cat > "$home/fakebin/md5" <<'SH'
#!/usr/bin/env bash
# Shim for `md5 -q`: block while $FM_HOME/block-hash exists, marking that it is blocking.
if [ -e "$FM_HOME/block-hash" ]; then
  : > "$FM_HOME/inflight-hash"
  i=0
  while [ -e "$FM_HOME/block-hash" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
  rm -f "$FM_HOME/inflight-hash"
fi
cat | cksum | cut -d' ' -f1
SH
  chmod +x "$home/fakebin/md5"
  printf '%s\n' "$home"
}

register_check() {  # <home> <id>: trust record the watcher's sweep authenticates
  local home=$1 id=$2 hash
  hash=$(shasum -a 256 "$home/state/$id.check.sh" | awk '{print $1}')
  printf 'fm-custom-check-v1\n%s\n' "$hash" > "$home/state/$id.check-trust"
  chmod 600 "$home/state/$id.check-trust"
}

fixture_diagnostics() {  # <home>
  printf -- '--- host log ---\n%s\n--- cycle ledger ---\n%s\n--- hook.err ---\n%s\n--- claude.err ---\n%s\n--- marker ---\n%s\n--- ack.log ---\n%s\n' \
    "$(cat "$1/state/.supervision-host.log" 2>/dev/null)" \
    "$(cut -c1-220 "$1/state/.watch-cycle-exits.log" 2>/dev/null)" \
    "$(cat "$1/hook.err" 2>/dev/null)" "$(cat "$1/claude.err" 2>/dev/null)" \
    "$(cat "$1/state/.watcher-down" 2>/dev/null)" "$(cat "$1/ack.log" 2>/dev/null)"
}

# Everything up to the moment a take-over would run: a session whose first watcher closed
# on a main-only wake, leaving a successor for main, and main having acknowledged it.
# Sets W_LEFT (the left watcher) and A_LEFT (the left arm).
prepare_acknowledged_session() {  # <home>
  local home=$1
  # Exported here, in the case's own shell: make_stub_home runs in a command substitution.
  export FM_TEST_KILL_LOG="$home/kill.log" FM_TEST_KILL_SRC_LOG="$home/kill-src.log"
  : > "$FM_TEST_KILL_LOG"
  : > "$FM_TEST_KILL_SRC_LOG"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 300 watcher_live "$home" || fail "the Stop hook never started a watcher: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'first wake' needs-decision
  wait_until 600 hook_exited "$home" || fail "the first wake never closed the hook: $(cat "$home/state/.supervision-host.log")"
  expect_code 2 "$(cat "$home/hook.rc")" "the first main-only wake must rewake main"
  main_drain "$home" > "$home/drain.out"
  [ -z "$MAIN_ACK" ] || (cd "$home" && FM_HOME="$home" "$FAKE_CLAUDE" -c "\"$home/bin/fm-wake-drain.sh\" ${MAIN_ACK#bin/fm-wake-drain.sh }" >> "$home/ack.log" 2>&1)
  case "$(cat "$home/state/.watcher-down" 2>/dev/null)" in acked:*) ;; *) fail "fixture: main's acknowledgement did not retire the episode: $(cat "$home/state/.watcher-down")" ;; esac
  W_LEFT=$(cat "$home/state/.watch.lock/pid")
  A_LEFT=$(ps -o ppid= -p "$W_LEFT" | tr -d ' ')
  watcher_live "$home" || fail "fixture: no successor was left for main"$'\n'"$(fixture_diagnostics "$home")"
}

signals_to() {  # <home> <pid>: kill-log lines sending a real signal to the pid or its group
  awk -v p="$2" '$2 != "-0" && ($NF == p || $NF == "-" p)' "$1/kill.log" 2>/dev/null || true
}

# The absence of a signal only counts when the shim demonstrably logs from inside the
# scripts under test, so every "no TERM" claim first shows the arm's own probes in the log.
assert_kill_shim_reaches_the_arm() {  # <home> <label>
  grep -q '^fm-watch-arm.sh:\|^fm-wake-lib.sh:' "$1/kill-src.log" 2>/dev/null \
    || fail "$2: the kill shim logged nothing from the scripts under test, so a missing signal proves nothing"$'\n'"$(cat "$1/kill-src.log" 2>/dev/null | sort | uniq -c | head)"
}

ledger_rows() { grep -E "$2" "$1/state/.watch-cycle-exits.log" 2>/dev/null || true; }

# --- LOOP-NOKILL: a take-over never signals a watcher inside a prelude step -----------
# The stub blocks inside the step and marks it; the take-over is sent only while the
# marker exists. The watcher that was in the step must still be the one holding the lock
# when the step ends, no TERM or KILL may have been sent to it or its group, and a wake
# raised during the step is delivered once, by the taking arm.
assert_take_over_attaches_to_a_watcher_inside_a_prelude_step() {  # <step9|step10>
  local step=$1 home pids sampled i held
  home=$(make_stub_home "takeover-busy-$step")
  [ "$step" != step10 ] || export FM_CHECK_INTERVAL=1
  prepare_acknowledged_session "$home"
  : > "$home/block-$step"
  wait_until 300 test -e "$home/inflight-$step" || fail "$step: the watcher never reached the blocking stub"
  turn_end "$home"
  wait_until 300 grep -q '	take-over	arm=' "$home/state/.supervision-host.log" || fail "$step: the host never took over: $(cat "$home/state/.supervision-host.log")"
  # Raise a wake while the step is in flight, then sample the lock for a while.
  append_status "$home" 'wake during the step' needs-decision
  sampled=0
  held=
  i=0
  while [ "$i" -lt 25 ]; do
    [ -e "$home/inflight-$step" ] || fail "$step: the stub stopped blocking before the samples ended"
    held=$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)
    [ "$held" = "$W_LEFT" ] || fail "$step: the lock moved from the busy watcher $W_LEFT to '$held' while its step was in flight"
    sampled=$((sampled + 1))
    sleep 0.2
    i=$((i + 1))
  done
  [ "$sampled" -ge 20 ] || fail "$step: too few lock samples ($sampled)"
  assert_kill_shim_reaches_the_arm "$home" "$step"
  pids=$(signals_to "$home" "$W_LEFT")
  [ -z "$pids" ] || fail "$step: the take-over signalled the watcher inside its step: $pids"
  rm -f "$home/block-$step"
  wait_until 300 test -e "$home/done-$step" || fail "$step: the stub never finished"
  wait_until 600 hook_exited "$home" || fail "$step: the wake raised during the step was never delivered: $(cat "$home/state/.supervision-host.log")"
  expect_code 2 "$(cat "$home/hook.rc")" "$step: the wake must reach main"
  [ "$(grep -c 'wake during the step\|demo.status' "$home/hook.err")" -ge 1 ] || fail "$step: the wake text is missing from the hook output: $(cat "$home/hook.err")"
  [ "$(grep -c '^signal:' "$home/hook.err")" -eq 1 ] || fail "$step: the wake was not delivered exactly once: $(cat "$home/hook.err")"
  [ "$(awk -v p="$W_LEFT" -F '\t' '$1 == p' "$home/state/.watch-deliveries.log" | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "$step: the busy watcher's wake was recorded as delivered other than once: $(cat "$home/state/.watch-deliveries.log")"
  ledger_rows "$home" "arm_pid=$A_LEFT	watcher_pid=$W_LEFT.*exit_code=0	signal=none	reason=actionable-signal" | grep -q . \
    || fail "$step: the left arm's row does not show the watcher ending itself on its wake: $(cat "$home/state/.watch-cycle-exits.log")"
  ledger_rows "$home" "watcher_pid=$W_LEFT	origin=attached.*reason=attached-delivered-wake" | grep -q . \
    || fail "$step: the taking arm's row does not show an attach that delivered the wake: $(cat "$home/state/.watch-cycle-exits.log")"
  ! ledger_rows "$home" "watcher_pid=$W_LEFT.*signal=TERM" | grep -q . || fail "$step: the busy watcher ended on TERM"
  export FM_CHECK_INTERVAL=999999
  pass "take-over: a watcher inside prelude $step is attached to, never signalled, and its wake is delivered once"
}
test_take_over_attaches_to_a_watcher_inside_prelude_step9() { assert_take_over_attaches_to_a_watcher_inside_a_prelude_step step9; }
test_take_over_attaches_to_a_watcher_inside_prelude_step10() { assert_take_over_attaches_to_a_watcher_inside_a_prelude_step step10; }

# --- an idle watcher is still stopped, and the taking arm owns the cycle -------------
# Rejects a fix that always attaches: with no step in flight the take-over TERMs the
# watcher, the owner arm's row records the TERM, the taking arm starts the next watcher,
# main's acknowledgement survives, and a later wake is printed by the taking arm's host.
test_idle_take_over_stops_the_watcher_and_the_new_arm_prints_the_next_wake() {
  local home new
  home=$(make_stub_home takeover-idle)
  export FM_POLL=6
  count_watch_polls
  prepare_acknowledged_session "$home"
  wait_for_idle_poll "$home/state" "$W_LEFT"
  turn_end "$home"
  wait_until 300 bash -c '[ "$(cat "$1/state/.watch.lock/pid" 2>/dev/null)" != "$2" ] && [ -s "$1/state/.watch.lock/pid" ]' _ "$home" "$W_LEFT" \
    || fail "idle: the taking arm never started its own watcher"$'\n'"$(fixture_diagnostics "$home")"$'\n'"kill log: $(tail -5 "$home/kill.log")"
  new=$(cat "$home/state/.watch.lock/pid")
  ledger_rows "$home" "arm_pid=$A_LEFT	watcher_pid=$W_LEFT.*exit_code=143	signal=TERM	reason=signal-exit" | grep -q . \
    || fail "idle: no TERM exit row for the idle watcher: $(cat "$home/state/.watch-cycle-exits.log")"
  ledger_rows "$home" "watcher_pid=$W_LEFT	origin=attached.*reason=taken-over" | grep -q . \
    || fail "idle: the taking arm did not record the take-over: $(cat "$home/state/.watch-cycle-exits.log")"
  case "$(cat "$home/state/.watcher-down")" in acked:*) ;; *) fail "idle: the take-over opened an episode over acknowledged work: $(cat "$home/state/.watcher-down")" ;; esac
  sleep 3
  watcher_live "$home" || fail "idle: the taken-over cycle closed with no new work: $(cat "$home/hook.err")"
  ! grep -q 'rearm-resurface' "$home/hook.err" || fail "idle: an empty recovery wake followed the take-over"
  append_status "$home" 'after the take-over' needs-decision
  wait_until 600 hook_exited "$home" || fail "idle: the later wake never reached the taking arm's host"
  [ "$(grep -c '^signal:' "$home/hook.err")" -eq 1 ] || fail "idle: the later wake was not printed once: $(cat "$home/hook.err")"
  ledger_rows "$home" "watcher_pid=$new	origin=started.*reason=actionable-signal" | grep -q . \
    || fail "idle: the new watcher's own arm did not close on the wake: $(cat "$home/state/.watch-cycle-exits.log")"
  export FM_POLL=1
  pass "take-over: an idle watcher is TERMed, main's acknowledgement survives, and the new arm prints the next wake"
}

# --- S1: the loop, with the stop deferred outside the prelude ------------------------
# The md5 shim blocks the stale-pane loop's command substitution (outside the prelude)
# for longer than the arm's old 5 s wait. On the base the arm gave up, attached, the
# watcher closed late with no restore, and the next watcher announced an empty
# `check: rearm-resurface`; every cycle repeated it.
test_a_stop_deferred_outside_the_prelude_leaves_no_empty_recovery_wake() {
  local home n w
  home=$(make_stub_home takeover-loop)
  printf 'project=demo\nwindow=fm-demo\nharness=claude\n' > "$home/state/demo.meta"
  prepare_acknowledged_session "$home"
  n=1
  while [ "$n" -le "$LOOP_CYCLES" ]; do
    w=$(cat "$home/state/.watch.lock/pid")
    : > "$home/block-hash"
    wait_until 300 test -e "$home/inflight-hash" || fail "cycle $n: the watcher never blocked in the stale-pane hash"
    turn_end "$home"
    # The block ends after BLOCK_SECS, past the arm's old 5 s wait.
    sleep "$BLOCK_SECS"
    rm -f "$home/block-hash"
    wait_until 400 bash -c '[ "$(cat "$1/state/.watch.lock/pid" 2>/dev/null)" != "$2" ] && [ -s "$1/state/.watch.lock/pid" ] && kill -0 "$(cat "$1/state/.watch.lock/pid")" 2>/dev/null' _ "$home" "$w" \
      || fail "cycle $n: no new watcher took the lock after the deferred stop: $(cat "$home/state/.watch-cycle-exits.log")"
    sleep 4
    if hook_exited "$home"; then
      ! grep -q 'rearm-resurface' "$home/hook.err" \
        || fail "cycle $n: an empty check: rearm-resurface followed the take-over of an acknowledged watcher: $(cat "$home/hook.err")"$'\n'"$(cat "$home/state/.watch-cycle-exits.log")"
    fi
    case "$(cat "$home/state/.watcher-down")" in acked:*) ;; *) fail "cycle $n: the stop opened a recovery episode over acknowledged work: $(cat "$home/state/.watcher-down")" ;; esac
    # A real wake closes the hook, then main handles and acknowledges it.
    append_status "$home" "cycle $n wake" needs-decision
    wait_until 600 hook_exited "$home" || fail "cycle $n: the real wake never reached main: $(cat "$home/state/.supervision-host.log")"
    ! grep -q 'rearm-resurface' "$home/hook.err" || fail "cycle $n: the hook output carries an empty recovery wake: $(cat "$home/hook.err")"
    main_drain "$home" > "$home/drain.out"
    [ -z "$MAIN_ACK" ] || (cd "$home" && FM_HOME="$home" "$FAKE_CLAUDE" -c "\"$home/bin/fm-wake-drain.sh\" ${MAIN_ACK#bin/fm-wake-drain.sh }" >> "$home/ack.log" 2>&1)
    n=$((n + 1))
  done
  pass "take-over: $LOOP_CYCLES consecutive stops deferred outside the prelude leave no empty rearm-resurface wake"
}

# --- the window: a step that starts between the arm's check and its signal ------------
# The test hook (FM_TEST_SEAM) holds the arm after its no-step check. A prelude that
# starts then must see the arm's claim and not start its step, so the TERM that follows
# never lands in a step.
test_a_prelude_starting_after_the_arms_check_does_not_start_its_step() {
  local home
  home=$(make_stub_home takeover-window)
  # Exported before the session starts so the arm the host runs inherits them; the pause
  # only holds a take-over, and the pause file does not exist until the take-over is due.
  export FM_TEST_SEAM=1 FM_TEST_TAKEOVER_PAUSE_FILE="$home/arm-pause" FM_TEST_TAKEOVER_PAUSED_FILE="$home/arm-paused"
  export FM_POLL=6
  count_watch_polls
  prepare_acknowledged_session "$home"
  wait_for_idle_poll "$home/state" "$W_LEFT"
  : > "$home/arm-pause"
  turn_end "$home"
  wait_until 300 test -e "$home/arm-paused" || { unset FM_TEST_SEAM; fail "window: the arm never reached its pause: $(cat "$home/state/.supervision-host.log")"; }
  : > "$home/block-step9"
  sleep 3
  [ ! -e "$home/inflight-step9" ] || { unset FM_TEST_SEAM; fail "window: a prelude step started after the arm's claim"; }
  rm -f "$home/arm-pause"
  rm -f "$home/block-step9"
  wait_until 300 bash -c '[ "$(cat "$1/state/.watch.lock/pid" 2>/dev/null)" != "$2" ] && [ -s "$1/state/.watch.lock/pid" ]' _ "$home" "$W_LEFT" \
    || { unset FM_TEST_SEAM; fail "window: the take-over never completed: $(cat "$home/state/.watch-cycle-exits.log")"; }
  unset FM_TEST_SEAM FM_TEST_TAKEOVER_PAUSE_FILE FM_TEST_TAKEOVER_PAUSED_FILE
  export FM_POLL=1
  ledger_rows "$home" "arm_pid=$A_LEFT	watcher_pid=$W_LEFT.*signal=TERM" | grep -q . || fail "window: the watcher was not stopped by the take-over's TERM"
  pass "take-over: a prelude that starts after the arm's check does not start its step"
}

fm_test_only
run_host_case test_kill_shim_logs_a_known_kill_and_keeps_signal_names
run_host_case test_take_over_attaches_to_a_watcher_inside_prelude_step9
run_host_case test_take_over_attaches_to_a_watcher_inside_prelude_step10
run_host_case test_idle_take_over_stops_the_watcher_and_the_new_arm_prints_the_next_wake
run_host_case test_a_stop_deferred_outside_the_prelude_leaves_no_empty_recovery_wake
run_host_case test_a_prelude_starting_after_the_arms_check_does_not_start_its_step
