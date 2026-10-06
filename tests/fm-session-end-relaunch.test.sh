#!/usr/bin/env bash
# Session-end auto-relaunch and the opt-in Claude debug flag.
#
# The decision runs through bin/fm-session-end-relaunch-lib.sh against a fake
# endpoint. The debug flag runs through the real fm-spawn launch command.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-end-relaunch)
mkdir -p "$TMP_ROOT"
export FM_HOME="$TMP_ROOT"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-session-end-relaunch-lib.sh"

make_tmux() {  # <dir>
  local fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
cmd=${FM_FAKE_TMUX_CURRENT_COMMAND:-zsh}
[ -z "${FM_FAKE_TMUX_LOG:-}" ] || printf '%s\n' "${1:-}" >> "$FM_FAKE_TMUX_LOG"
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*)
          [ "${FM_FAKE_TMUX_READ_FAIL:-0}" != 1 ] || exit 1
          printf '%s\n' "$cmd"; exit 0 ;;
        *cursor_y*) printf '0\n'; exit 0 ;;
      esac
    done
    exit 0 ;;
  list-windows)
    if [ "${FM_FAKE_WINDOW_GONE:-0}" = 1 ]; then
      printf 'main\n'
    else
      printf 'main\nfm-lane\n'
    fi
    exit 0 ;;
  capture-pane)
    [ -z "${FM_FAKE_TMUX_CAPTURE:-}" ] || cat "$FM_FAKE_TMUX_CAPTURE"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

make_recorder() {  # <dir>
  local bin="$1/recorder"
  mkdir -p "$bin"
  cat > "$bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_HOME:-}" ] || { echo "error: FM_HOME is not set" >&2; exit 1; }
printf '%s\n' "$*" >> "${FM_SESSION_END_CONTROL_LOG:?}"
[ -z "${FM_SESSION_END_CONTROL_ENV_LOG:-}" ] \
  || printf 'FM_HOME=%s\nFM_STATE_OVERRIDE=%s\nFM_CONTROL_LAUNCH_WAIT=%s\nFM_CONTROL_QUOTA_GEN=%s\nFM_CONTROL_QUOTA_SEQ=%s\n' \
    "$FM_HOME" "${FM_STATE_OVERRIDE:-}" "${FM_CONTROL_LAUNCH_WAIT:-}" \
    "${FM_CONTROL_QUOTA_GEN:-}" "${FM_CONTROL_QUOTA_SEQ:-}" > "$FM_SESSION_END_CONTROL_ENV_LOG"
if [ -n "${FM_SESSION_END_BEACON_REF:-}" ]; then
  date +%s > "$FM_SESSION_END_BEACON_REF.start"
  if [ "${FM_STATE_OVERRIDE:-}/.last-watcher-beat" -nt "$FM_SESSION_END_BEACON_REF" ]; then
    printf 'fresh\n' > "$FM_SESSION_END_BEACON_REF.seen"
  else
    printf 'stale\n' > "$FM_SESSION_END_BEACON_REF.seen"
  fi
fi
[ -z "${FM_SESSION_END_CONTROL_SLEEP:-}" ] || sleep "$FM_SESSION_END_CONTROL_SLEEP"
if [ "${1:-}" = "${FM_SESSION_END_CONTROL_FAIL_ID:-}" ]; then
  [ -z "${FM_SESSION_END_CONTROL_FAIL_CLOCK:-}" ] \
    || printf '%s\n' "${FM_SESSION_END_CONTROL_FAIL_TIME:?}" > "$FM_SESSION_END_CONTROL_FAIL_CLOCK"
  printf 'no supported equal route for %s\n' "$1" >&2
  exit 1
fi
exit "${FM_SESSION_END_CONTROL_RC:-0}"
SH
  chmod +x "$bin/fm-control.sh"
  printf '%s\n' "$bin/fm-control.sh"
}

# <dir> <id>. One ship in <dir>/state, session-end recorded, worktree present.
add_lane() {
  local dir=$1 id=$2 harness=${3:-claude} state wt gen
  state="$dir/state"
  wt="$dir/wt-$id"
  mkdir -p "$state" "$wt" "$dir/data"
  printf 'window=firstmate:fm-lane\nkind=ship\nharness=%s\nbackend=tmux\nworktree=%s\n' "$harness" "$wt" > "$state/$id.meta"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" --state idle --source claude-hook --event launch-brief >/dev/null
  gen=$(cat "$state/$id.busy-gen")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" --source claude-hook --event session-end >/dev/null
}

# <name> -> dir. One ship named lane.
make_lane() {
  local dir="$TMP_ROOT/$1"
  add_lane "$dir" lane "${2:-claude}"
  printf '%s\n' "$dir"
}

scan_lane() {  # <dir> [<watcher-grace-secs>]
  local dir=$1 fakebin recorder
  fakebin=$(make_tmux "$dir")
  recorder=$(make_recorder "$dir")
  : > "$dir/control.log"
  : > "$dir/tmux.log"
  PATH="$fakebin:$PATH" \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_WAKE_QUEUE="$dir/state/.wake-queue" \
    FM_TEST_SEAM=1 FM_SESSION_END_CONTROL="$recorder" \
    FM_SESSION_END_CONTROL_LOG="$dir/control.log" \
    FM_FAKE_TMUX_CAPTURE="${FM_FAKE_TMUX_CAPTURE:-}" \
    FM_FAKE_TMUX_CURRENT_COMMAND="${FM_FAKE_TMUX_CURRENT_COMMAND:-zsh}" \
    FM_FAKE_WINDOW_GONE="${FM_FAKE_WINDOW_GONE:-0}" \
    FM_FAKE_TMUX_LOG="$dir/tmux.log" \
    fm_session_end_relaunch_scan "$dir/state" "${2:-}"
}

test_session_end_relaunches_a_dead_lane_once() {
  local dir state
  dir=$(make_lane relaunch-once)
  state="$dir/state"
  scan_lane "$dir" || fail "scan failed on an eligible dead lane"
  [ "$FM_SESSION_END_WAKE" = "check: lane auto-relaunched after session-end" ] \
    || fail "eligible session-end did not wake a relaunch: ${FM_SESSION_END_WAKE:-<empty>}"
  [ "$(wc -l < "$dir/control.log" | tr -d ' ')" = 1 ] \
    || fail "relaunch was not invoked exactly once: $(cat "$dir/control.log")"
  grep -F 'lane relaunch --note' "$dir/control.log" >/dev/null \
    || fail "relaunch was not the control verb: $(cat "$dir/control.log")"
  grep -F 'left as the previous worker left them' "$dir/control.log" >/dev/null \
    || fail "the relaunch note did not say the local copy was preserved: $(cat "$dir/control.log")"
  [ "$(awk -F '\t' '$2 == "attempt"' "$state/.session-end-relaunch-lane" | wc -l | tr -d ' ')" = 1 ] \
    || fail "the attempt was not ledgered"
  scan_lane "$dir" || fail "second scan failed"
  [ -z "$FM_SESSION_END_WAKE" ] || fail "a second scan woke again: $FM_SESSION_END_WAKE"
  [ ! -s "$dir/control.log" ] || fail "a second scan relaunched again: $(cat "$dir/control.log")"
  [ ! -s "$dir/tmux.log" ] || fail "an already-handled lane still probed its endpoint: $(cat "$dir/tmux.log")"
  pass "a dead session-end lane is relaunched once and then left alone"
}

# The watcher assigns FM_HOME and STATE without exporting them, and the
# default home has nothing else that exports FM_HOME.
test_relaunch_hands_control_the_watcher_home() {
  local dir fakebin recorder wait
  dir=$(make_lane unexported-home)
  fakebin=$(make_tmux "$dir")
  recorder=$(make_recorder "$dir")
  : > "$dir/control.log"
  (
    export -n FM_HOME
    unset FM_STATE_OVERRIDE FM_WAKE_QUEUE
    FM_HOME="$dir"
    export PATH="$fakebin:$PATH" FM_TEST_SEAM=1 FM_SESSION_END_CONTROL="$recorder" \
      FM_SESSION_END_CONTROL_LOG="$dir/control.log" \
      FM_SESSION_END_CONTROL_ENV_LOG="$dir/control-env.log" \
      FM_CONTROL_LAUNCH_WAIT=600
    fm_session_end_relaunch_scan "$dir/state" || exit 1
    printf '%s\n' "$FM_SESSION_END_WAKE" > "$dir/wake"
    printf '%s\n' "$FM_SESSION_END_TIMEOUT" > "$dir/bound"
  ) || fail "scan failed with an unexported FM_HOME"
  [ "$(cat "$dir/wake")" = "check: lane auto-relaunched after session-end" ] \
    || fail "an unexported FM_HOME did not relaunch: $(cat "$dir/wake")"
  grep -Fx "FM_HOME=$dir" "$dir/control-env.log" >/dev/null \
    || fail "control did not get the watcher's home: $(cat "$dir/control-env.log")"
  grep -Fx "FM_STATE_OVERRIDE=$dir/state" "$dir/control-env.log" >/dev/null \
    || fail "control did not get the scanned state dir: $(cat "$dir/control-env.log")"
  wait=$(sed -n 's/^FM_CONTROL_LAUNCH_WAIT=//p' "$dir/control-env.log")
  case "$wait" in
    ''|*[!0-9]*) fail "control did not get a launch wait: $(cat "$dir/control-env.log")" ;;
  esac
  [ "$wait" -lt "$(cat "$dir/bound")" ] \
    || fail "control's launch wait ${wait}s is not inside the $(cat "$dir/bound")s bound"
  pass "the relaunch hands control the watcher's home, state, and a launch wait inside its bound"
}

test_missing_endpoint_is_not_relaunched() {
  local dir
  dir=$(make_lane missing-endpoint)
  FM_FAKE_WINDOW_GONE=1 scan_lane "$dir" || fail "scan failed on a missing endpoint"
  unset FM_FAKE_WINDOW_GONE
  [ ! -s "$dir/control.log" ] || fail "a missing endpoint was relaunched: $(cat "$dir/control.log")"
  [ -z "$FM_SESSION_END_WAKE" ] || fail "a missing endpoint woke: $FM_SESSION_END_WAKE"
  [ ! -e "$dir/state/.session-end-relaunch-lane" ] \
    || fail "a missing endpoint ledgered an attempt: $(cat "$dir/state/.session-end-relaunch-lane")"
  pass "a missing endpoint with session-end is not relaunched"
}

# The watcher touches its beacon once per cycle, and the relaunch blocks
# inside that cycle, so the bound must leave the beacon short of the grace.
test_relaunch_bound_stays_inside_the_watcher_grace() {
  local dir grace start elapsed called
  for grace in '' 300 900; do
    dir=$(make_lane "bound-${grace:-default}")
    FM_POLL=15 scan_lane "$dir" "$grace" || fail "scan failed with grace '${grace:-default}'"
    [ -n "$grace" ] || grace=300
    [ $((grace - FM_SESSION_END_TIMEOUT)) -ge 60 ] \
      || fail "the ${FM_SESSION_END_TIMEOUT}s bound leaves less than 60s of the ${grace}s watcher grace"
    [ "$FM_SESSION_END_LAUNCH_WAIT" -lt "$FM_SESSION_END_TIMEOUT" ] \
      || fail "the ${FM_SESSION_END_LAUNCH_WAIT}s launch wait is not inside the ${FM_SESSION_END_TIMEOUT}s bound"
  done

  dir=$(make_lane bound-kill)
  touch -t 200001010000 "$dir/state/.last-watcher-beat"
  touch -t 200101010000 "$dir/beacon-ref"
  start=$SECONDS
  FM_SESSION_END_CONTROL_SLEEP=60 FM_SESSION_END_BEACON_REF="$dir/beacon-ref" \
    scan_lane "$dir" 66 || fail "scan failed with a short watcher grace"
  elapsed=$((SECONDS - start))
  [ "$elapsed" -lt 60 ] || fail "a relaunch that outlived the bound blocked the scan for ${elapsed}s"
  called=$(( $(date +%s) - $(cat "$dir/beacon-ref.start") ))
  [ "$called" -le $((66 - 60 + 5)) ] \
    || fail "the relaunch call blocked for ${called}s, past the 66s grace less its 60s margin"
  [ "$(cat "$dir/beacon-ref.seen" 2>/dev/null)" = fresh ] \
    || fail "the watcher beacon was not touched before the blocking relaunch call"
  grep -F 'check: lane auto-relaunch failed after session-end' <<<"$FM_SESSION_END_WAKE" >/dev/null \
    || fail "a relaunch cut off by the bound did not wake as failed: ${FM_SESSION_END_WAKE:-<empty>}"

  dir=$(make_lane bound-too-short)
  scan_lane "$dir" 61 || fail "scan failed with a grace too short for the margin"
  [ ! -s "$dir/control.log" ] \
    || fail "a grace with no room for the margin still relaunched: $(cat "$dir/control.log")"
  pass "the relaunch bound stays at least 60s inside the watcher grace and refreshes the beacon first"
}

test_cap_holds_and_wakes_once() {
  local dir state now
  dir=$(make_lane cap-min)
  state="$dir/state"
  now=$(date +%s)
  printf '%s\tattempt\n' "$now" > "$state/.session-end-relaunch-lane"
  scan_lane "$dir" || fail "capped scan failed"
  [ -s "$dir/control.log" ] && fail "a capped lane was relaunched: $(cat "$dir/control.log")"
  grep -F 'auto-relaunch paused after 1 attempt in 1800s' <<<"$FM_SESSION_END_WAKE" >/dev/null \
    || fail "the 30-minute cap did not wake: ${FM_SESSION_END_WAKE:-<empty>}"
  scan_lane "$dir" || fail "second capped scan failed"
  [ -z "$FM_SESSION_END_WAKE" ] || fail "the cap woke again for the same session-end: $FM_SESSION_END_WAKE"
  pass "the 30-minute cap holds and wakes once"

  dir=$(make_lane cap-day)
  state="$dir/state"
  now=$(date +%s)
  printf '%s\tattempt\n%s\tattempt\n%s\tattempt\n' $((now - 1900)) $((now - 4000)) $((now - 8000)) \
    > "$state/.session-end-relaunch-lane"
  scan_lane "$dir" || fail "daily-cap scan failed"
  [ -s "$dir/control.log" ] && fail "a daily-capped lane was relaunched: $(cat "$dir/control.log")"
  grep -F 'auto-relaunch paused after 3 attempts in 86400s' <<<"$FM_SESSION_END_WAKE" >/dev/null \
    || fail "the daily cap did not wake: ${FM_SESSION_END_WAKE:-<empty>}"
  pass "the daily cap holds and wakes once"
}

test_quota_recovery_retries_after_recent_relaunch_and_failure() {
  local dir state gen identity seq
  dir=$(make_lane quota-retry omp)
  state="$dir/state"
  scan_lane "$dir" || fail "initial session-end relaunch failed"
  [ "$FM_SESSION_END_WAKE" = "check: lane auto-relaunched after session-end" ] \
    || fail "the quota fixture did not first relaunch after session-end"
  gen=$(cat "$state/lane.busy-gen")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" lane idle --gen "$gen" \
    --source omp-ext --event quota-exhausted >/dev/null \
    || fail "quota exhaustion was not recorded"
  FM_FAKE_TMUX_CURRENT_COMMAND=omp FM_SESSION_END_CONTROL_RC=1 scan_lane "$dir" \
    || fail "failed quota-recovery scan failed"
  [ "$FM_SESSION_END_ACTION" = failed ] \
    || fail "recent session-end history suppressed the first quota attempt: $FM_SESSION_END_ACTION"
  [ "$(wc -l < "$dir/control.log" | tr -d ' ')" = 1 ] \
    || fail "quota recovery did not invoke control after a recent relaunch"
  grep -F 'auto-relaunch failed after quota exhaustion' <<<"$FM_SESSION_END_WAKE" >/dev/null \
    || fail "the failed quota attempt did not report quota exhaustion: ${FM_SESSION_END_WAKE:-<empty>}"
  FM_FAKE_TMUX_CURRENT_COMMAND=omp scan_lane "$dir" || fail "quota retry scan failed"
  [ "$FM_SESSION_END_WAKE" = "check: lane auto-relaunched after quota exhaustion" ] \
    || fail "a previous failed quota attempt suppressed recovery: ${FM_SESSION_END_WAKE:-<empty>}"
  [ "$(wc -l < "$dir/control.log" | tr -d ' ')" = 1 ] \
    || fail "quota retry did not invoke control exactly once"
  grep -F 'permitted matrix fallback' "$dir/control.log" >/dev/null \
    || fail "quota retry did not pass the fallback recovery note"
  [ "$(awk -F '\t' '$2 == "attempt"' "$state/.session-end-relaunch-lane" | wc -l | tr -d ' ')" = 3 ] \
    || fail "the original relaunch, failed quota attempt, and successful retry were not ledgered"
  printf '%s\tattempt\n' $(( $(date +%s) - 90000 )) > "$state/.session-end-relaunch-lane"
  FM_FAKE_TMUX_CURRENT_COMMAND=omp scan_lane "$dir" || fail "handled quota scan failed"
  [ -z "$FM_SESSION_END_WAKE" ] && [ ! -s "$dir/control.log" ] && [ ! -s "$dir/tmux.log" ] \
    || fail "a successful quota recovery duplicated after its attempt history expired"
  identity=$(fm_session_end_identity "$state" lane) || fail "quota identity was lost"
  seq=${identity#* }
  "$ROOT/bin/fm-busy-event.sh" apply "$state" lane idle --gen "$gen" \
    --source omp-ext --event quota-exhausted >/dev/null \
    || fail "a later quota exhaustion was not recorded"
  [ "$(fm_session_end_identity "$state" lane)" != "$gen $seq" ] \
    || fail "a later quota event did not advance its identity"
  FM_FAKE_TMUX_CURRENT_COMMAND=omp scan_lane "$dir" || fail "later quota recovery scan failed"
  [ "$FM_SESSION_END_WAKE" = "check: lane auto-relaunched after quota exhaustion" ] \
    || fail "successful handling of an older sequence suppressed a new quota event"
  pass "quota recovery ignores recent relaunches and failed attempts but deduplicates successful identities"
}

test_quota_recovery_ignores_daily_cap_and_capped_handling() {
  local dir state now identity gen seq which
  for which in min day; do
    dir=$(make_lane "quota-capped-$which" omp)
    state="$dir/state"
    now=$(date +%s)
    if [ "$which" = min ]; then
      printf '%s\tattempt\n' "$now" > "$state/.session-end-relaunch-lane"
    else
      printf '%s\tattempt\n%s\tattempt\n%s\tattempt\n' $((now - 1900)) $((now - 4000)) $((now - 8000)) \
        > "$state/.session-end-relaunch-lane"
    fi
    gen=$(cat "$state/lane.busy-gen")
    "$ROOT/bin/fm-busy-event.sh" apply "$state" lane idle --gen "$gen" \
      --source omp-ext --event quota-exhausted >/dev/null \
      || fail "quota exhaustion was not recorded for $which cap"
    identity=$(fm_session_end_identity "$state" lane) || fail "quota identity could not be read"
    seq=${identity#* }
    printf '%s\t%s\tcapped-%s\n' "$gen" "$seq" "$which" > "$state/.session-end-handled-lane"
    FM_FAKE_TMUX_CURRENT_COMMAND=omp scan_lane "$dir" || fail "$which-capped quota scan failed"
    [ "$FM_SESSION_END_WAKE" = "check: lane auto-relaunched after quota exhaustion" ] \
      || fail "$which cap or its handled marker suppressed quota recovery: ${FM_SESSION_END_WAKE:-<empty>}"
    [ "$(wc -l < "$dir/control.log" | tr -d ' ')" = 1 ] \
      || fail "$which-capped quota recovery did not invoke control exactly once"
  done
  pass "quota recovery bypasses recent and daily caps and their same-identity handled markers"
}

test_failed_quota_recovery_does_not_starve_later_tasks() {
  local dir="$TMP_ROOT/quota-starvation" state id gen first_identity luna_identity scan
  state="$dir/state"
  for id in a-sol b-luna c-luna; do
    add_lane "$dir" "$id" omp
    if [ "$id" = a-sol ]; then
      printf 'model=openai-codex/gpt-6.1-sol\neffort=high\n' >> "$state/$id.meta"
    else
      printf 'model=openai-codex/gpt-6-luna\n' >> "$state/$id.meta"
    fi
    gen=$(cat "$state/$id.busy-gen")
    "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" \
      --source omp-ext --event quota-exhausted >/dev/null \
      || fail "quota exhaustion was not recorded for $id"
  done
  first_identity=$(fm_session_end_identity "$state" a-sol) || fail "Sol identity was lost"
  luna_identity=$(fm_session_end_identity "$state" b-luna) || fail "Luna identity was lost"
  FM_FAKE_TMUX_CURRENT_COMMAND=omp FM_SESSION_END_CONTROL_FAIL_ID=a-sol scan_lane "$dir" \
    || fail "multi-task quota scan failed"
  [ "$(cut -d' ' -f1 "$dir/control.log")" = $'a-sol\nb-luna' ] \
    || fail "a failed Sol recovery starved Luna or allowed a second success: $(cat "$dir/control.log")"
  [ "$FM_SESSION_END_WAKE" = "check: a-sol auto-relaunch failed after quota exhaustion: no supported equal route for a-sol" ] \
    || fail "the scan did not preserve the first failure wake: ${FM_SESSION_END_WAKE:-<empty>}"
  [ "$(cat "$state/.session-end-handled-a-sol")" = "$(printf '%s\t%s\tfailed' "${first_identity%% *}" "${first_identity#* }")" ] \
    || fail "failed Sol did not retain its retryable identity"
  [ "$(cat "$state/.session-end-handled-b-luna")" = "$(printf '%s\t%s\trelaunched' "${luna_identity%% *}" "${luna_identity#* }")" ] \
    || fail "successful Luna was not marked handled for its generation and sequence"
  [ ! -e "$state/.session-end-relaunch-c-luna" ] \
    || fail "the scan attempted a second successful relaunch"

  FM_FAKE_TMUX_CURRENT_COMMAND=omp FM_SESSION_END_CONTROL_FAIL_ID=a-sol scan_lane "$dir" \
    || fail "second multi-task quota scan failed"
  [ "$(cut -d' ' -f1 "$dir/control.log")" = c-luna ] \
    || fail "an unattempted task lost priority or a handled Luna duplicated: $(cat "$dir/control.log")"
  for scan in 3 4 5; do
    FM_FAKE_TMUX_CURRENT_COMMAND=omp FM_SESSION_END_CONTROL_FAIL_ID=a-sol scan_lane "$dir" \
      || fail "multi-task quota scan $scan failed"
    [ "$(cut -d' ' -f1 "$dir/control.log")" = a-sol ] \
      || fail "scan $scan capped Sol retries or duplicated a successful generation: $(cat "$dir/control.log")"
  done
  [ "$(awk -F '\t' '$2 == "attempt"' "$state/.session-end-relaunch-a-sol" | wc -l | tr -d ' ')" = 4 ] \
    || fail "the failed quota task did not remain retryable beyond the daily attempt cap"
  for id in b-luna c-luna; do
    [ "$(awk -F '\t' '$2 == "relaunched"' "$state/.session-end-relaunch-$id" | wc -l | tr -d ' ')" = 1 ] \
      || fail "$id's successful quota generation was not deduplicated"
  done
  [ "$(FM_WAKE_QUEUE="$state/.wake-queue" fm_wake_queued_keys check | wc -l | tr -d ' ')" = 3 ] \
    || fail "the durable queue lost a later success or duplicated Sol's failure wake"
  pass "failed quota recovery advances to later tasks, retries without caps, and deduplicates successful generations"
}

test_failed_recovery_shares_the_scan_time_bound() {
  local dir state id gen remaining
  for remaining in 30 1; do
    dir="$TMP_ROOT/quota-budget-$remaining"
    state="$dir/state"
    for id in a-sol b-luna; do
      add_lane "$dir" "$id" omp
      gen=$(cat "$state/$id.busy-gen")
      "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" \
        --source omp-ext --event quota-exhausted >/dev/null \
        || fail "quota exhaustion was not recorded for $id"
    done
    printf '100000\n' > "$dir/clock"
    mkdir -p "$dir/fakebin"
    cat > "$dir/fakebin/date" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = +%s ] || exit 1
cat "${FM_SESSION_END_CONTROL_FAIL_CLOCK:?}"
SH
    chmod +x "$dir/fakebin/date"
    FM_FAKE_TMUX_CURRENT_COMMAND=omp FM_SESSION_END_CONTROL_FAIL_ID=a-sol \
      FM_SESSION_END_CONTROL_FAIL_CLOCK="$dir/clock" \
      FM_SESSION_END_CONTROL_FAIL_TIME="$((100060 - remaining))" \
      FM_SESSION_END_CONTROL_ENV_LOG="$dir/control-env.log" scan_lane "$dir" 120 \
      || fail "remaining-budget scan failed"
    [ "$FM_SESSION_END_TIMEOUT" = 60 ] && [ "$FM_SESSION_END_LAUNCH_WAIT" = 30 ] \
      || fail "a scan changed its published grace-derived bounds"
    if [ "$remaining" = 30 ]; then
      [ "$(cut -d' ' -f1 "$dir/control.log")" = $'a-sol\nb-luna' ] \
        || fail "a failure with time remaining starved the next task: $(cat "$dir/control.log")"
      grep -Fx 'FM_CONTROL_LAUNCH_WAIT=15' "$dir/control-env.log" >/dev/null \
        || fail "the later relaunch did not halve the remaining shared budget: $(cat "$dir/control-env.log")"
    else
      [ "$(cut -d' ' -f1 "$dir/control.log")" = a-sol ] \
        || fail "an exhausted scan budget still attempted another task: $(cat "$dir/control.log")"
      [ ! -e "$state/.session-end-relaunch-b-luna" ] \
        || fail "an exhausted scan budget ledgered an unattempted task"
    fi
  done
  pass "failed attempts share one scan budget and leave a half-budget launch wait for later recovery"
}

test_deadline_consuming_quota_failure_advances_next_scan() {
  local dir="$TMP_ROOT/quota-slow-starvation" state id gen scan attempts
  state="$dir/state"
  for id in a-sol b-luna; do
    add_lane "$dir" "$id" omp
    gen=$(cat "$state/$id.busy-gen")
    "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" \
      --source omp-ext --event quota-exhausted >/dev/null \
      || fail "quota exhaustion was not recorded for $id"
  done
  printf '100000\n' > "$dir/clock"
  mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/date" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = +%s ] || exit 1
cat "${FM_SESSION_END_CONTROL_FAIL_CLOCK:?}"
SH
  chmod +x "$dir/fakebin/date"
  for scan in 1 2 3 4 5; do
    FM_FAKE_TMUX_CURRENT_COMMAND=omp FM_SESSION_END_CONTROL_FAIL_ID=a-sol \
      FM_SESSION_END_CONTROL_FAIL_CLOCK="$dir/clock" \
      FM_SESSION_END_CONTROL_FAIL_TIME="$(( $(cat "$dir/clock") + 6 ))" \
      FM_SESSION_END_CONTROL_ENV_LOG="$dir/control-env.log" scan_lane "$dir" 66 \
      || fail "bounded quota scan $scan failed"
    [ "$FM_SESSION_END_TIMEOUT" = 6 ] && [ "$FM_SESSION_END_LAUNCH_WAIT" = 3 ] \
      || fail "scan $scan changed the grace-derived execution bound"
    grep -Fx 'FM_CONTROL_LAUNCH_WAIT=3' "$dir/control-env.log" >/dev/null \
      || fail "scan $scan did not preserve the half-budget command wait"
    if [ "$scan" = 2 ]; then
      [ "$(cut -d' ' -f1 "$dir/control.log")" = b-luna ] \
        || fail "the slow failed task starved the usable later route: $(cat "$dir/control.log")"
      [ "$FM_SESSION_END_WAKE" = "check: b-luna auto-relaunched after quota exhaustion" ] \
        || fail "the later quota task did not recover"
    else
      [ "$(cut -d' ' -f1 "$dir/control.log")" = a-sol ] \
        || fail "scan $scan exceeded its budget, capped retries, or duplicated recovery"
      if [ "$scan" = 1 ]; then
        [ ! -e "$state/.session-end-relaunch-b-luna" ] \
          || fail "the exhausted first scan attempted a second lane"
        [ "$(cat "$dir/clock")" = 100006 ] \
          || fail "the failed attempt did not consume the shared scan deadline"
      fi
    fi
  done
  attempts=$(awk -F '\t' '$2 == "attempt" {n++} END {print n}' "$state/.session-end-relaunch-a-sol")
  [ "$attempts" = 4 ] || fail "slow quota retries were capped after $attempts attempts"
  [ "$(awk -F '\t' '$2 == "relaunched" {n++} END {print n}' "$state/.session-end-relaunch-b-luna")" = 1 ] \
    || fail "the recovered later task was not deduplicated"
  pass "deadline-consuming quota failures yield first position on the next bounded scan without retry caps"
}

test_deliberate_exit_and_waits_are_skipped() {
  local dir gen
  dir=$(make_lane deliberate)
  gen=$(cat "$dir/state/lane.busy-gen")
  printf 'gen=%s\n' "$gen" > "$dir/state/lane.control-exit"
  scan_lane "$dir" || fail "deliberate-exit scan failed"
  [ -z "$FM_SESSION_END_WAKE" ] || fail "a deliberate exit was relaunched: $FM_SESSION_END_WAKE"
  [ -s "$dir/control.log" ] && fail "a deliberate exit invoked control"

  dir=$(make_lane paused)
  printf 'paused: waiting on the upstream release\n' > "$dir/state/lane.status"
  scan_lane "$dir" || fail "paused scan failed"
  [ -s "$dir/control.log" ] && fail "a paused task was relaunched"

  dir=$(make_lane held)
  printf 'captain-held: waiting on the merge\n' > "$dir/state/lane.status"
  scan_lane "$dir" || fail "held scan failed"
  [ -s "$dir/control.log" ] && fail "a captain-held task was relaunched"

  dir=$(make_lane done-lane)
  printf 'done: the work is finished\n' > "$dir/state/lane.status"
  scan_lane "$dir" || fail "done scan failed"
  [ -s "$dir/control.log" ] && fail "a finished task was relaunched"

  dir=$(make_lane alive)
  FM_FAKE_TMUX_CURRENT_COMMAND=claude scan_lane "$dir" || fail "alive scan failed"
  unset FM_FAKE_TMUX_CURRENT_COMMAND
  [ -s "$dir/control.log" ] && fail "a live agent was relaunched"
  pass "deliberate exit, pause, hold, done, and a live agent are skipped"
}

test_stale_exit_in_scrollback_still_relaunches() {
  local dir gen
  dir=$(make_lane stale-exit)
  gen=$(cat "$dir/state/lane.busy-gen")
  printf 'gen=%s-previous\n' "$gen" > "$dir/state/lane.control-exit"
  printf '❯ /exit\nResume this session with:\n$ claude --debug\nResume this session with:\n' > "$dir/pane"
  FM_FAKE_TMUX_CAPTURE="$dir/pane" scan_lane "$dir" || fail "stale-exit scan failed"
  unset FM_FAKE_TMUX_CAPTURE
  [ "$FM_SESSION_END_WAKE" = "check: lane auto-relaunched after session-end" ] \
    || fail "an old /exit in the pane suppressed the relaunch: ${FM_SESSION_END_WAKE:-<empty>}"
  [ "$(wc -l < "$dir/control.log" | tr -d ' ')" = 1 ] \
    || fail "an old /exit in the pane did not relaunch exactly once: $(cat "$dir/control.log")"
  pass "an old /exit in the pane and an older exit marker do not suppress a later session-end relaunch"
}

test_one_relaunch_per_scan() {
  local dir="$TMP_ROOT/two-lanes" first
  add_lane "$dir" lane-a
  add_lane "$dir" lane-b
  scan_lane "$dir" || fail "two-lane scan failed"
  [ "$(wc -l < "$dir/control.log" | tr -d ' ')" = 1 ] \
    || fail "one scan relaunched more than one lane: $(cat "$dir/control.log")"
  first=$(cut -d' ' -f1 "$dir/control.log")
  scan_lane "$dir" || fail "second two-lane scan failed"
  [ "$(wc -l < "$dir/control.log" | tr -d ' ')" = 1 ] \
    || fail "the second scan did not relaunch exactly one lane: $(cat "$dir/control.log")"
  [ "$(cut -d' ' -f1 "$dir/control.log")" != "$first" ] \
    || fail "the second scan relaunched $first again instead of the other lane"
  pass "one scan runs at most one relaunch and the next scan takes the next lane"
}

test_unreadable_hold_answer_is_skipped() {
  local dir
  dir=$(make_lane hold-unreadable)
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  mkdir -p "$dir/fakebin"
  printf '#!/bin/sh\nexit 1\n' > "$dir/fakebin/tasks-axi"
  chmod +x "$dir/fakebin/tasks-axi"
  scan_lane "$dir" || fail "unreadable-hold scan failed"
  [ -s "$dir/control.log" ] && fail "a lane whose captain hold could not be read was relaunched: $(cat "$dir/control.log")"
  [ -z "$FM_SESSION_END_WAKE" ] || fail "an unreadable hold answer woke: $FM_SESSION_END_WAKE"
  pass "a lane whose captain hold cannot be read is not relaunched"
}

test_backlog_hold_is_skipped() {
  local dir
  command -v tasks-axi >/dev/null 2>&1 || { pass "backlog hold skip skipped (tasks-axi absent)"; return 0; }
  dir=$(make_lane backlog-hold)
  cp "$ROOT/.tasks.toml" "$dir/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  (cd "$dir" && tasks-axi add lane 'open lane' --file data/backlog.md) >/dev/null 2>&1 \
    || { pass "backlog hold skip skipped (could not add a backlog row)"; return 0; }
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_CONFIG_OVERRIDE="$dir/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold lane --reason 'awaiting the captain' >/dev/null 2>&1 \
    || { pass "backlog hold skip skipped (hold could not be recorded)"; return 0; }
  printf 'working: still open\n' > "$dir/state/lane.status"
  scan_lane "$dir" || fail "held-metadata scan failed"
  [ -s "$dir/control.log" ] && fail "a backlog captain hold was relaunched: $(cat "$dir/control.log")"
  pass "a backlog captain hold is not relaunched"
}

test_claude_debug_is_off_unless_asked() {
  local case_dir home proj wt fakebin id=debug-off out launch status sm form probe env_log arg debug_count
  local -a argv
  case_dir="$TMP_ROOT/debug-off"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-debug-off"
  fm_test_spawn_brief "$home" "$id"
  status=0
  FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off > "$case_dir/spawn.out" || status=$?
  out=$(cat "$case_dir/spawn.out")
  expect_code 0 "$status" "a default claude spawn should succeed: $out"
  launch=$(cat "$case_dir/launch.log")
  probe="$case_dir/claude-probe"
  env_log="$case_dir/claude.env"
  mkdir -p "$probe"
  fm_fake_claude_recording "$probe"
  (unset CLAUDE_CODE_DIAGNOSTICS_FILE
    fm_eval_launch "$launch" "$wt" "$probe" HOME="$home" \
      FM_FAKE_CLAUDE_ENV_LOG="$env_log"
  ) || fail "the default Claude launch failed to execute"
  argv=()
  while IFS= read -r -d '' arg; do argv+=("$arg"); done < "$env_log.args"
  for arg in "${argv[@]}"; do
    [ "$arg" != --debug ] || fail "claude debug was on without --claude-debug"
  done
  assert_no_grep 'CLAUDE_CODE_DIAGNOSTICS_FILE=' "$env_log" \
    "claude diagnostics were on without --claude-debug"

  # The relaunch needs the recorded window listed with a bare shell in it.
  mkdir -p "$case_dir/stopped"
  cat > "$case_dir/stopped/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *'#{pane_current_command}'*) printf 'zsh\\n'; exit 0 ;;
esac
exec '$fakebin/tmux' "\$@"
SH
  chmod +x "$case_dir/stopped/tmux"
  fakebin="$case_dir/stopped:$fakebin"
  : > "$case_dir/launch.log"
  status=0
  FM_FAKE_DUPLICATE_WINDOW="fm-$id" FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" --relaunch --claude-debug > "$case_dir/relaunch.out" || status=$?
  expect_code 0 "$status" "a --relaunch --claude-debug spawn should succeed: $(cat "$case_dir/relaunch.out")"
  launch=$(cat "$case_dir/launch.log")
  (unset CLAUDE_CODE_DIAGNOSTICS_FILE
    fm_eval_launch "$launch" "$wt" "$probe" HOME="$home" \
      FM_FAKE_CLAUDE_ENV_LOG="$env_log"
  ) || fail "the debug Claude relaunch failed to execute"
  argv=()
  while IFS= read -r -d '' arg; do argv+=("$arg"); done < "$env_log.args"
  debug_count=0
  for arg in "${argv[@]}"; do
    if [ "$arg" = --debug ]; then debug_count=$((debug_count + 1)); fi
  done
  [ "$debug_count" -eq 1 ] || fail "claude debug was not enabled exactly once when asked"
  assert_grep "CLAUDE_CODE_DIAGNOSTICS_FILE=$(cd "$home/state" && pwd -P)/$id.claude-diagnostics.jsonl" "$env_log" \
    "the claude launch did not name the diagnostics file that records the stop signal"

  cp "$home/state/$id.meta" "$case_dir/meta.before"
  status=0
  FM_FAKE_DUPLICATE_WINDOW="fm-$id" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" --relaunch --harness pi --claude-debug \
    > "$case_dir/relaunch-pi.out" || status=$?
  expect_code 1 "$status" "a non-claude --claude-debug relaunch must be refused"
  assert_contains "$(cat "$case_dir/relaunch-pi.out")" '--claude-debug applies only to a claude launch' \
    "the harness refusal did not name the flag"
  cmp -s "$case_dir/meta.before" "$home/state/$id.meta" \
    || fail "a refused --claude-debug relaunch changed the task record"

  id=debug-fresh
  fm_test_spawn_brief "$home" "$id"
  sm="$case_dir/mate-home"
  mkdir -p "$sm"
  for form in ship scout secondmate batch; do
    status=0
    case "$form" in
      ship) fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off --claude-debug ;;
      scout) fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --scout --claude-debug ;;
      secondmate) fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$sm" --secondmate --claude-debug ;;
      batch) fm_test_run_spawn "$home" "$wt" "$fakebin" "$id=$proj" "$id-b=$proj" --mode no-mistakes --yolo off --claude-debug ;;
    esac > "$case_dir/fresh-$form.out" || status=$?
    expect_code 1 "$status" "a fresh $form spawn with --claude-debug must be refused: $(cat "$case_dir/fresh-$form.out")"
    assert_contains "$(cat "$case_dir/fresh-$form.out")" '--claude-debug applies to --relaunch only' \
      "the fresh $form refusal did not name the flag"
    [ ! -e "$home/state/$id.meta" ] && [ ! -e "$home/state/$id-b.meta" ] \
      || fail "a refused fresh $form --claude-debug spawn published a task record"
  done
  pass "claude debug is off by default, on for a claude relaunch, and refused for another harness or a fresh spawn"
}

add_partial_quota_lane() {
  local dir=$1 id=$2 gen record seq
  add_lane "$dir" "$id" omp
  gen=$(cat "$dir/state/$id.busy-gen")
  "$ROOT/bin/fm-busy-event.sh" apply "$dir/state" "$id" idle --gen "$gen" \
    --source omp-ext --event quota-exhausted >/dev/null || fail "quota event fixture failed"
  record=$(cat "$dir/state/$id.busy-state")
  seq=${record#*seq=}
  seq=${seq%% *}
  printf 'busy_gen=%s\n' "$gen" >> "$dir/state/$id.meta"
  printf '%s\n' v1 "task=$id" phase=failed:launching rollback=prior-record-kept \
    backend=tmux endpoint=firstmate:fm-lane "worktree=$dir/wt-$id" kind=ship \
    from_harness=omp from_model=default from_effort=default \
    "quota_gen=$gen" "quota_seq=$seq" "from_busy_gen=$gen" from_relaunch_tx=- \
    relaunch_tx=fixture-tx > "$dir/state/$id.control-relaunch"
  "$ROOT/bin/fm-busy-event.sh" retire "$dir/state" "$id" --current-gen >/dev/null \
    || fail "quota retirement fixture failed"
}

test_partial_quota_retries_are_uncapped_and_deduplicated() {
  local dir="$TMP_ROOT/partial-quota-retries" id=a-journal gen seq scan now
  add_partial_quota_lane "$dir" "$id"
  gen=$(fm_meta_get "$dir/state/$id.control-relaunch" quota_gen)
  seq=$(fm_meta_get "$dir/state/$id.control-relaunch" quota_seq)
  add_lane "$dir" b-session-end
  now=$(date +%s)
  printf '%s\tattempt\n%s\tattempt\n%s\tattempt\n' "$now" "$((now - 2000))" "$((now - 4000))" \
    > "$dir/state/.session-end-relaunch-$id"
  for scan in 1 2 3 4; do
    FM_SESSION_END_CONTROL_FAIL_ID="$id" FM_SESSION_END_CONTROL_ENV_LOG="$dir/control-env.log" scan_lane "$dir" \
      || fail "partial quota failure scan $scan failed"
    [ "$(cut -d' ' -f1 "$dir/control.log")" = "$(if [ "$scan" = 1 ]; then printf 'b-session-end'; else printf '%s' "$id"; fi)" ] \
      || fail "a partial quota retry was capped, starved the later lane, or repeated a success"
    [ ! -e "$dir/state/$id.busy-gen" ] && [ ! -e "$dir/state/$id.busy-state" ] \
      || fail "journal eligibility resurrected busy state"
  done
  grep -Fx "FM_CONTROL_QUOTA_GEN=$gen" "$dir/control-env.log" >/dev/null \
    || fail "the stable quota generation was not passed to control"
  grep -Fx "FM_CONTROL_QUOTA_SEQ=$seq" "$dir/control-env.log" >/dev/null \
    || fail "the stable quota sequence was not passed to control"
  scan_lane "$dir" || fail "partial quota success scan failed"
  [ "$FM_SESSION_END_WAKE" = "check: $id auto-relaunched after quota exhaustion" ] \
    || fail "partial quota recovery did not remain eligible after repeated failures"
  printf '%s\tattempt\n' "$((now - 90000))" > "$dir/state/.session-end-relaunch-$id"
  scan_lane "$dir" || fail "handled partial quota scan failed"
  [ -z "$FM_SESSION_END_WAKE" ] && [ ! -s "$dir/control.log" ] \
    || fail "the successfully handled journal identity duplicated after its ledger expired"
  pass "journal-backed quota failures stay uncapped, advance to later lanes, and deduplicate their stable identity"
}

test_partial_quota_journal_guards_fail_closed() {
  local dir variant journal meta gen before_gen before_record command read_fail missing replacement_gen lock_holder lock_deadline scan_rc
  for variant in paused held done failed backlog-close deliberate lock captain-unreadable \
    alive ambiguous unreadable missing active complete confirmed pre-stop stop-alive stop-unknown \
    manual incomplete task worktree endpoint backend profile superseded-meta superseded-gen \
    superseded-tx stale-sequence published-malformed published-symlink-state published-symlink-gen \
    published-missing-record published-orphan-record published-superseded-gen; do
    dir="$TMP_ROOT/partial-quota-guard-$variant"
    add_partial_quota_lane "$dir" lane
    journal="$dir/state/lane.control-relaunch"
    meta="$dir/state/lane.meta"
    gen=$(fm_meta_get "$journal" quota_gen)
    command=zsh read_fail=0 missing=0
    case "$variant" in
      published-*)
        "$ROOT/bin/fm-busy-event.sh" arm "$dir/state" lane --state busy --source fm-spawn --event launch-brief >/dev/null
        replacement_gen=$(cat "$dir/state/lane.busy-gen")
        printf 'busy_gen=%s\ncontrol_relaunch_tx=fixture-current\n' "$replacement_gen" >> "$meta"
        printf 'phase=failed:checkpoint\nrollback=instructions-restored\nfrom_busy_gen=%s\nfrom_relaunch_tx=fixture-current\n' \
          "$replacement_gen" >> "$journal"
        ;;
    esac
    case "$variant" in
      paused) printf 'paused: waiting\n' > "$dir/state/lane.status" ;;
      held) printf 'captain-held: waiting\n' > "$dir/state/lane.status" ;;
      done) printf 'done: finished\n' > "$dir/state/lane.status" ;;
      failed) printf 'failed: finished\n' > "$dir/state/lane.status" ;;
      backlog-close) : > "$dir/state/lane.backlog-close" ;;
      deliberate) printf 'gen=%s\n' "$gen" > "$dir/state/lane.control-exit" ;;
      lock)
        (
          fm_lock_try_acquire "$dir/state/.control-lane.lock" || exit 1
          trap 'fm_lock_release "$dir/state/.control-lane.lock"' EXIT
          : > "$dir/control-lock-ready"
          lock_deadline=$((SECONDS + 30))
          while [ ! -e "$dir/control-lock-release" ] && [ "$SECONDS" -lt "$lock_deadline" ]; do
            sleep 0.05
          done
        ) &
        lock_holder=$!
        lock_deadline=$((SECONDS + 5))
        while [ ! -e "$dir/control-lock-ready" ] && [ "$SECONDS" -lt "$lock_deadline" ] && kill -0 "$lock_holder" 2>/dev/null; do
          sleep 0.05
        done
        if [ ! -e "$dir/control-lock-ready" ]; then
          : > "$dir/control-lock-release"
          wait "$lock_holder" 2>/dev/null || true
          fail "control lock fixture failed to acquire its foreign hold"
        fi
        ;;
      captain-unreadable)
        printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
        mkdir -p "$dir/fakebin"
        printf '#!/bin/sh\nexit 1\n' > "$dir/fakebin/tasks-axi"
        chmod +x "$dir/fakebin/tasks-axi"
        ;;
      alive) command=omp ;;
      ambiguous) command=python ;;
      unreadable) read_fail=1 ;;
      missing) missing=1 ;;
      active) printf 'phase=launching\n' >> "$journal" ;;
      complete) printf 'phase=complete\n' >> "$journal" ;;
      confirmed) printf 'rollback=none-new-agent-confirmed\n' >> "$journal" ;;
      pre-stop) printf 'phase=failed:noted\nrollback=instructions-restored\n' >> "$journal"; command=omp ;;
      stop-alive) printf 'phase=failed:stopping\nrollback=instructions-restored-agent-alive\n' >> "$journal" ;;
      stop-unknown) printf 'phase=failed:stopping\nrollback=instructions-restored-agent-state-unknown\n' >> "$journal" ;;
      manual) printf 'quota_gen=\nquota_seq=\n' >> "$journal" ;;
      incomplete) printf 'relaunch_tx=\nfrom_busy_gen=\n' >> "$journal" ;;
      task) printf 'task=other\n' >> "$journal" ;;
      worktree) printf 'worktree=%s\n' "$dir" >> "$journal" ;;
      endpoint) printf 'endpoint=firstmate:fm-other\n' >> "$journal" ;;
      backend) printf 'backend=herdr\n' >> "$journal" ;;
      profile) printf 'harness=claude\n' >> "$meta" ;;
      superseded-meta) printf 'busy_gen=newer-generation\n' >> "$meta" ;;
      superseded-gen)
        "$ROOT/bin/fm-busy-event.sh" arm "$dir/state" lane --state idle --source fm-spawn --event launch-brief >/dev/null
        ;;
      superseded-tx) printf 'control_relaunch_tx=unrelated\n' >> "$meta" ;;
      stale-sequence)
        "$ROOT/bin/fm-busy-event.sh" arm "$dir/state" lane --state idle --source omp-ext --event quota-exhausted >/dev/null
        replacement_gen=$(cat "$dir/state/lane.busy-gen")
        printf 'busy_gen=%s\n' "$replacement_gen" >> "$meta"
        printf 'quota_gen=%s\nfrom_busy_gen=%s\n' "$replacement_gen" "$replacement_gen" >> "$journal"
        ;;
      published-malformed) printf 'malformed\n' > "$dir/state/lane.busy-state" ;;
      published-symlink-state)
        mv "$dir/state/lane.busy-state" "$dir/state/lane.busy-state-target"
        ln -s "$dir/state/lane.busy-state-target" "$dir/state/lane.busy-state"
        ;;
      published-symlink-gen)
        mv "$dir/state/lane.busy-gen" "$dir/state/lane.busy-gen-target"
        ln -s "$dir/state/lane.busy-gen-target" "$dir/state/lane.busy-gen"
        ;;
      published-missing-record) rm "$dir/state/lane.busy-state" ;;
      published-orphan-record) rm "$dir/state/lane.busy-gen" ;;
      published-superseded-gen)
        "$ROOT/bin/fm-busy-event.sh" arm "$dir/state" lane --state busy --source fm-spawn --event launch-brief >/dev/null
        ;;
    esac
    before_gen=$(cat "$dir/state/lane.busy-gen" 2>/dev/null || true)
    before_record=$(cat "$dir/state/lane.busy-state" 2>/dev/null || true)
    scan_rc=0
    FM_FAKE_TMUX_CURRENT_COMMAND="$command" FM_FAKE_TMUX_READ_FAIL="$read_fail" \
      FM_FAKE_WINDOW_GONE="$missing" scan_lane "$dir" || scan_rc=$?
    if [ "$variant" = lock ]; then
      : > "$dir/control-lock-release"
      wait "$lock_holder" || fail "control lock fixture failed to release its foreign hold"
    fi
    [ "$scan_rc" -eq 0 ] || fail "$variant journal scan failed"
    [ -z "$FM_SESSION_END_WAKE" ] && [ ! -s "$dir/control.log" ] \
      || fail "$variant journal authorized an automatic replacement"
    [ "$before_gen" = "$(cat "$dir/state/lane.busy-gen" 2>/dev/null || true)" ] \
      && [ "$before_record" = "$(cat "$dir/state/lane.busy-state" 2>/dev/null || true)" ] \
      || fail "$variant journal eligibility changed incarnation state"
  done
  pass "partial quota journals preserve shared skips and refuse unsafe, unrelated, manual, or superseded transactions"
}

test_session_end_relaunches_a_dead_lane_once
test_relaunch_hands_control_the_watcher_home
test_missing_endpoint_is_not_relaunched
test_relaunch_bound_stays_inside_the_watcher_grace
test_cap_holds_and_wakes_once
test_quota_recovery_retries_after_recent_relaunch_and_failure
test_quota_recovery_ignores_daily_cap_and_capped_handling
test_failed_quota_recovery_does_not_starve_later_tasks
test_failed_recovery_shares_the_scan_time_bound
test_deadline_consuming_quota_failure_advances_next_scan
test_partial_quota_retries_are_uncapped_and_deduplicated
test_partial_quota_journal_guards_fail_closed
test_deliberate_exit_and_waits_are_skipped
test_stale_exit_in_scrollback_still_relaunches
test_one_relaunch_per_scan
test_unreadable_hold_answer_is_skipped
test_backlog_hold_is_skipped
test_claude_debug_is_off_unless_asked
