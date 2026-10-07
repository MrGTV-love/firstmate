#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

run_owned_checkpoint() {
  local home=$1 command=${2:-$CHECKPOINT} seconds=${3:-5} repeat=${4:-once}
  mkdir -p "$home/primary-bin"
  [ -e "$home/primary-bin/codex" ] || ln -s /bin/bash "$home/primary-bin/codex"
  STATUS=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 \
    "$home/primary-bin/codex" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      "$0" --seconds "$1"
      first_status=$?
      if [ -f "$FM_HOME/state/.last-watcher-beat" ]; then
        cp "$FM_HOME/state/.last-watcher-beat" "$FM_HOME/first-watcher-beat"
      fi
      if [ "$2" = repeat ]; then
        "$3" > "$FM_HOME/drained.txt" 2> "$FM_HOME/drained.err" || exit 1
        generation=
        while IFS= read -r line; do
          case "$line" in
            WAKE_ACK_REQUIRED:*)
              read -r -a fields <<< "$line"
              count=${#fields[@]}
              cutoff=${fields[$((count - 3))]}
              generation=${fields[$((count - 1))]}
              ;;
          esac
        done < "$FM_HOME/drained.err"
        [ -n "$generation" ] || exit 1
        "$3" --ack-through "$cutoff" --recovery-generation "$generation" \
          > "$FM_HOME/ack.txt" 2> "$FM_HOME/ack.err" || exit 1
        "$0" --seconds "$1" > "$FM_HOME/second.out" 2> "$FM_HOME/second.err"
        printf "%s\n" "$?" > "$FM_HOME/second.code"
      fi
      exit "$first_status"
    ' "$command" "$seconds" "$repeat" "$ROOT/bin/fm-wake-drain.sh" >"$home/out.txt" 2>"$home/err.txt" || STATUS=$?
}

register_monitor_check() {
  local home=$1
  cat > "$home/state/ordinary-monitor.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'ordinary-monitor-ran\n' >> "$FM_HOME/monitor-effects"
printf 'ordinary-monitor-active\n'
SH
  chmod 0700 "$home/state/ordinary-monitor.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" ordinary-monitor >/dev/null \
    || fail "could not register ordinary checkpoint monitor"
}

test_denied_host_preflight_runs_real_ordinary_monitor() {
  local policy home drained
  for policy in omp-or-tc malformed; do
    home=$(make_home "denied-$policy")
    printf 'claude\n' > "$home/config/supervision-host"
    printf '%s\n' "$policy" > "$home/config/session-launch-policy"
    register_monitor_check "$home"
    run_owned_checkpoint "$home" "$CHECKPOINT" 5 repeat
    expect_code 0 "$STATUS" "denied host ordinary check wake: $(cat "$home/out.txt" "$home/err.txt")"
    assert_contains "$(cat "$home/out.txt")" "supervision-host: launch policy refused:" "preflight denial lost its diagnostic"
    assert_contains "$(cat "$home/out.txt")" "check: rearm-resurface" "preflight denial did not deliver the real watcher's recovery wake"
    expect_code 0 "$(cat "$home/second.code")" "second denied checkpoint ordinary check wake"
    assert_contains "$(cat "$home/second.out")" "ordinary-monitor-active" "unchanged denial did not continue ordinary monitoring"
    assert_not_contains "$(cat "$home/second.out" "$home/second.err")" "launch policy refused:" "unchanged denial redelivered its diagnostic"
    assert_contains "$(cat "$home/monitor-effects")" "ordinary-monitor-ran" "denied host did not run ordinary monitoring"
    assert_present "$home/first-watcher-beat" "first denied checkpoint did not start ordinary monitoring"
    assert_present "$home/state/.last-watcher-beat" "denied host did not publish a real watcher beacon"
    assert_absent "$home/state/.supervision-host.log" "denied preflight launched the host"
    assert_absent "$home/state/.watch.lock/pid" "ordinary monitoring left its foreground watcher alive"
    assert_contains "$(cat "$home/drained.txt")" "launch policy refused:" "owned preflight denial did not retain its refusal wake"
    drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
    assert_not_contains "$drained" "launch policy refused:" "unchanged denial requeued its refusal"
  done
  pass "denied and malformed host policies restore real ordinary foreground monitoring"
}

test_unowned_denial_cannot_publish_refusal() {
  local home status
  home=$(make_home denied-unowned)
  printf 'claude\n' > "$home/config/supervision-host"
  printf 'omp-or-tc\n' > "$home/config/session-launch-policy"
  printf '%s\n' "$$" > "$home/state/.lock"
  status=0
  FM_HOME="$home" "$CHECKPOINT" --seconds 1 >"$home/out.txt" 2>"$home/err.txt" || status=$?
  expect_code 1 "$status" "unowned denied checkpoint"
  assert_contains "$(cat "$home/out.txt")" "supervision-host stood down" "host did not retain ownership validation"
  assert_absent "$home/state/.session-launch-refused-.supervision-host" "unowned checkpoint wrote a refusal receipt"
  assert_absent "$home/state/.wake-queue" "unowned checkpoint published a refusal wake"
  assert_absent "$home/state/.last-watcher-beat" "unowned checkpoint restored someone else's watcher"
  pass "checkpoint checks actual ownership before refusal publication"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

# A home opted into the supervision host whose checkpoint runs a stub host in
# a fixture code root: the stub records the bound it was given, then closes
# the way $FM_HOME/host-kind says.
make_host_home() {  # <name>
  local home
  home=$(make_home "$1")
  mkdir -p "$home/root/bin"
  cp "$CHECKPOINT" "$home/root/bin/fm-watch-checkpoint.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$ROOT/bin/fm-cursor-lib.sh" \
    "$ROOT/bin/fm-supervision-engine-lib.sh" "$ROOT/bin/fm-session-launch-policy-lib.sh" \
    "$ROOT/bin/fm-config-inherit-lib.sh" "$ROOT/bin/fm-startup-memory-budget-lib.sh" \
    "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-path-lib.sh" "$home/root/bin/"
  cat > "$home/root/bin/fm-watch.sh" <<SH
#!/usr/bin/env bash
exec "$ROOT/bin/fm-watch.sh" "\$@"
SH
  chmod +x "$home/root/bin/fm-watch.sh"
  cat > "$home/root/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'host-call\n' >> "$FM_HOME/host-calls"
printf 'args=%s\nprimary=%s\npark=%s\nlimit=%s\n' "$*" "${FM_SUPERVISION_HOST_PRIMARY:-}" \
  "${FM_SUPERVISION_HOST_PARK_SECONDS:-}" "${FM_SUPERVISION_HOST_PARK_LIMIT:-}" > "$FM_HOME/host-env"
case "$(cat "$FM_HOME/host-kind")" in
  boundary) printf 'supervision-host: cycle boundary - fixture\n' ;;
  handback)
    printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
    printf 'signal: demo.status\nsupervision-host: the away session could not take this wake: fixture; this wake is yours\n'
    ;;
  stood-down) printf 'supervision-host stood down: this session no longer owns supervision\n' ;;
  refusal|refusal-lost-owner)
    printf 'omp-or-tc\n' > "$FM_HOME/config/session-launch-policy"
    if [ "$(cat "$FM_HOME/host-kind")" = refusal-lost-owner ]; then
      printf '0\n' > "$FM_HOME/state/.lock"
    else
      . "$(dirname "$0")/fm-wake-lib.sh"
      fm_recovery_marker_publish "$FM_HOME/state/.watcher-down" downtime || exit 1
      cp "$FM_HOME/state/.watcher-down" "$FM_HOME/runtime-recovery-marker"
    fi
    printf 'supervision-host: launch policy refused: transition-fixture\n'
    exit 1
    ;;
esac
SH
  chmod +x "$home/root/bin/fm-watch-checkpoint.sh" "$home/root/bin/fm-supervision-host.sh"
  : > "$home/config/supervision-host"
  printf '%s\n' "$home"
}

run_host_checkpoint() {  # <home> <kind> [checkpoint args...]; sets STATUS
  local home=$1
  printf '%s\n' "$2" > "$home/host-kind"
  shift 2
  STATUS=0
  FM_HOME="$home" "$home/root/bin/fm-watch-checkpoint.sh" "$@" >"$home/out.txt" 2>"$home/err.txt" || STATUS=$?
}

test_host_checkpoint_bounds_the_park_by_posture() {
  local home
  home=$(make_host_home host-bound)
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 124 "$STATUS" "a host park that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 5s" "the boundary must read as the ordinary quiet line"
  assert_contains "$(cat "$home/host-env")" $'args=park\nprimary=codex\npark=5\nlimit=1235' \
    "attended, the host must park for the checkpoint's own bound with the codex pin and a turn limit past it"
  : > "$home/state/.afk-contract"
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 124 "$STATUS" "an away park that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 3600s" "away, the bound must be raised"
  assert_contains "$(cat "$home/host-env")" 'park=3600' "away, the host must park for the away bound"
  FM_CODEX_WATCH_CHECKPOINT_AWAY=900 run_host_checkpoint "$home" boundary --seconds 5
  assert_contains "$(cat "$home/host-env")" 'park=900' "the away bound must be configurable"
  FM_CODEX_WATCH_CHECKPOINT_AWAY=900 run_host_checkpoint "$home" boundary --seconds 1000
  assert_contains "$(cat "$home/host-env")" 'park=1000' "the away bound must never shorten a longer checkpoint"
  pass "checkpoint: an opted-in home runs the host for the checkpoint's bound, raised while away"
}

test_host_checkpoint_passes_a_handback_and_reports_a_stand_down() {
  local home
  home=$(make_host_home host-handback)
  run_host_checkpoint "$home" handback --seconds 5
  expect_code 0 "$STATUS" "a handed-back wake is an actionable checkpoint"
  assert_contains "$(cat "$home/out.txt")" $'signal: demo.status\nsupervision-host: the away session could not take this wake' \
    "the wake and its host line must pass through"
  assert_not_contains "$(cat "$home/out.txt")" "watcher: started" "the host's cycle status is not part of the wake"
  run_host_checkpoint "$home" stood-down --seconds 5
  expect_code 1 "$STATUS" "a host that stood down is a failed checkpoint"
  assert_contains "$(cat "$home/out.txt")" "supervision-host stood down" "the stand-down must be shown"
  pass "checkpoint: a handed-back wake passes through, and a host stand-down is a failure"
}

# The real host under a fake Codex harness that holds the home's session lock.
# shellcheck disable=SC2016 # the fake harness's script expands in its own shell
test_real_host_checkpoint_ends_quietly_at_its_bound() {
  local home fakebin status
  home=$(make_home host-real)
  : > "$home/config/supervision-host"
  fakebin="$TMP_ROOT/host-real-bin"
  mkdir -p "$fakebin"
  ln -s /bin/bash "$fakebin/codex"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$fakebin/codex" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    "$0" --seconds 4
  ' "$CHECKPOINT" >"$home/out.txt" 2>"$home/err.txt" || status=$?
  expect_code 124 "$status" "a quiet host checkpoint: $(cat "$home/out.txt" "$home/err.txt")"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 4s" "the real host's boundary must read as the quiet line"
  assert_grep '	boundary	' "$home/state/.supervision-host.log" "the host must have ended its own park"
  if [ -e "$home/state/.watch.lock/pid" ] && kill -0 "$(cat "$home/state/.watch.lock/pid")" 2>/dev/null; then
    fail "a host checkpoint left its watcher running"
  fi
  pass "checkpoint: the real host ends its park at the checkpoint bound as a quiet checkpoint"
}

test_runtime_host_refusal_restores_real_monitor_only_for_owner() {
  local home drained
  home=$(make_host_home host-refusal-transition)
  register_monitor_check "$home"
  printf 'refusal\n' > "$home/host-kind"
  run_owned_checkpoint "$home" "$home/root/bin/fm-watch-checkpoint.sh" 5 repeat
  expect_code 0 "$STATUS" "runtime refused host ordinary check wake: $(cat "$home/out.txt" "$home/err.txt")"
  assert_equals "host-call" "$(cat "$home/host-calls")" "runtime refusal retried the denied host"
  assert_contains "$(cat "$home/out.txt")" "launch policy refused: transition-fixture" "runtime refusal was not retained"
  assert_contains "$(cat "$home/out.txt")" "check: rearm-resurface" "runtime refusal bypassed the real watcher's recovery wake"
  expect_code 0 "$(cat "$home/second.code")" "post-refusal checkpoint ordinary check wake"
  assert_contains "$(cat "$home/second.out")" "ordinary-monitor-active" "post-refusal checkpoint did not continue ordinary monitoring"
  assert_not_contains "$(cat "$home/second.out" "$home/second.err")" "launch policy refused:" "post-refusal checkpoint repeated the unchanged refusal"
  assert_contains "$(cat "$home/monitor-effects")" "ordinary-monitor-ran" "runtime refusal did not execute the ordinary check"
  assert_present "$home/first-watcher-beat" "runtime refusal checkpoint did not start ordinary monitoring"
  assert_present "$home/runtime-recovery-marker" "runtime host fixture did not publish its recovery episode"
  assert_present "$home/state/.last-watcher-beat" "runtime refusal did not start the ordinary watcher"
  assert_contains "$(cat "$home/drained.txt")" "launch policy refused:" "runtime refusal did not publish the owned refusal"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "launch policy refused:" "post-refusal checkpoint requeued its refusal"
  home=$(make_host_home host-refusal-lost-owner)
  register_monitor_check "$home"
  printf 'refusal-lost-owner\n' > "$home/host-kind"
  run_owned_checkpoint "$home" "$home/root/bin/fm-watch-checkpoint.sh"
  expect_code 1 "$STATUS" "runtime refusal after losing ownership"
  assert_equals "host-call" "$(cat "$home/host-calls")" "lost-owner refusal retried the host"
  assert_absent "$home/monitor-effects" "lost owner restored ordinary monitoring"
  assert_absent "$home/state/.wake-queue" "lost owner published a refusal wake"
  assert_absent "$home/state/.session-launch-refused-.supervision-host" "lost owner wrote a refusal receipt"
  assert_absent "$home/state/.watcher-down" "lost owner published a recovery marker"
  assert_absent "$home/runtime-recovery-marker" "lost owner entered the owned recovery fixture"
  pass "runtime policy refusal restores real foreground monitoring only while the primary still owns supervision"
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_host_checkpoint_bounds_the_park_by_posture
test_host_checkpoint_passes_a_handback_and_reports_a_stand_down
test_real_host_checkpoint_ends_quietly_at_its_bound
test_denied_host_preflight_runs_real_ordinary_monitor
test_unowned_denial_cannot_publish_refusal
test_runtime_host_refusal_restores_real_monitor_only_for_owner
