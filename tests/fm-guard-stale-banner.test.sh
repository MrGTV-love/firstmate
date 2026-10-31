#!/usr/bin/env bash
# Regression tests for fm-guard's watcher-down banner deduplication.
#
# The first stale command in one FM_HOME must print the full actionable watcher
# banner.
# Repeated commands in that same stale episode should print only a concise
# reminder, while unrelated alarms such as queued wakes stay independent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-guard-stale-banner)

make_guard_case() {
  local name=$1 dir home root
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  root="$dir/root"
  mkdir -p "$home/state" "$home/config" "$root"
  fm_write_meta "$home/state/task.meta" "window=firstmate:fm-task" "kind=ship"
  printf '%s\n' "$dir"
}

case_home() {
  printf '%s/home\n' "$1"
}

case_root() {
  printf '%s/root\n' "$1"
}

record_live_watcher() {
  local dir=$1 pid=$2 home identity
  home=$(case_home "$dir")
  identity=$(FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid") || return 1
  mkdir -p "$home/state/.watch.lock"
  printf '%s\n' "$pid" > "$home/state/.watch.lock/pid"
  printf '%s\n' "$home" > "$home/state/.watch.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$home/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$home/state/.watch.lock/pid-identity"
}

# These cases exercise the persistent-watcher model (a live pid is the real
# liveness signal), so pin the model rather than letting the host test runner's
# ambient harness ancestry pick it.
run_guard_case() {
  local dir=$1
  FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE=999 \
    FM_SUPERVISION_MODEL=persistent \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

run_guard_case_read_only() {
  local dir=$1
  FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE=999 \
    FM_SUPERVISION_MODEL=persistent \
    FM_GUARD_READ_ONLY=1 \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

# Pin the Claude auto-arm model to prove it cannot change guard liveness.
run_guard_case_autoarm() {
  local dir=$1
  FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE=999 \
    FM_SUPERVISION_MODEL=autoarm \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

# Age the rewake ledger into the past so a passing long-turn case cannot rest on
# epoch freshness: a handling turn that has already outrun grace still has this
# shape, which is the false alarm this suite now pins.
record_aged_rewake_epoch() {
  local home=$1 session_pid=$2 recovery=${3:-guard-test-generation}
  printf 'epoch=7 owner_pid=1 outcome=rewake updated_at=1 session_pid=%s recovery_generation=%s\n' \
    "$session_pid" "$recovery" > "$home/state/.claude-autoarm-epoch"
  printf 'acked:handling:%s\n' "$recovery" > "$home/state/.watcher-down"
  touch -t 201901010000 "$home/state/.last-watcher-beat"
  touch -t 202001010000 "$home/state/.claude-autoarm-epoch"
}

record_session_lock_pid() {
  local home=$1 pid=$2
  printf '%s\n' "$pid" > "$home/state/.lock"
}

# Pin the extension model to prove hand-offs still use strict guard liveness.
run_guard_case_extension() {
  local dir=$1
  FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE=999 \
    FM_SUPERVISION_MODEL=extension \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

# The same extension-model call from the supervision branch actor
# (FM_SUPERVISION_ACTOR=branch, as the Pi branch extension injects it).
run_guard_case_extension_as_branch() {
  local dir=$1
  FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE=999 \
    FM_SUPERVISION_MODEL=extension \
    FM_SUPERVISION_ACTOR=branch \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

# Stand up the durable evidence a live Pi session leaves behind: both primary
# extensions present under the case root, and a marker per extension recording
# that extension's current build plus the session pid in state/.lock.
# Each named part can be broken independently so a test can prove which one the
# verdict actually depends on.
#   session_pid  the pid state/.lock names (a live one unless the test wants a dead
#                session); "" writes no session lock at all
#   omit         "" | watch | turnend - skip that extension's marker
#   drift        "" | watch | turnend - write a marker whose version is not the
#                current build, i.e. the session loaded an older extension
record_pi_extension_session() {
  local dir=$1 session_pid=${2:-} omit=${3:-} drift=${4:-} home root pair source marker version
  home=$(case_home "$dir")
  root=$(case_root "$dir")
  mkdir -p "$root/.pi/extensions"
  for pair in \
    "fm-primary-pi-watch.ts:.pi-watch-extension-loaded:watch" \
    "fm-primary-turnend-guard.ts:.pi-turnend-extension-loaded:turnend"; do
    source=${pair%%:*}
    marker=${pair#*:}; marker=${marker%%:*}
    printf '// %s for %s\n' "${pair##*:}" "$(basename "$dir")" > "$root/.pi/extensions/$source"
    [ "$omit" = "${pair##*:}" ] && continue
    if [ "$drift" = "${pair##*:}" ]; then
      version="sha256:0000000000000000000000000000000000000000000000000000000000000000"
    else
      version=$(FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_pi_extension_version "$2"' \
        _ "$ROOT/bin/fm-wake-lib.sh" "$root/.pi/extensions/$source") || return 1
    fi
    if [ "${pair##*:}" = watch ]; then
      printf '%s\n%s\ngeneration=1 phase=active\n' "$version" "$session_pid" > "$home/state/$marker"
    else
      printf '%s\n%s\n' "$version" "$session_pid" > "$home/state/$marker"
    fi
  done
  [ -n "$session_pid" ] && printf '%s\n' "$session_pid" > "$home/state/.lock"
  return 0
}

count_text() {
  local haystack=$1 needle=$2
  awk -v needle="$needle" 'index($0, needle) { c++ } END { print c + 0 }' <<EOF
$haystack
EOF
}

# The same persistent-model call from the supervision branch actor, as the
# supervision host's engine turn runs every guarded command.
run_guard_case_as_branch() {
  local dir=$1
  FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE=999 \
    FM_SUPERVISION_MODEL=persistent \
    FM_SUPERVISION_ACTOR=branch \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

# The branch actor never owns watcher continuity, so a down watcher is never an
# instruction to it, and its calls neither open nor end main's down-episode.
test_branch_actor_is_never_told_to_repair_the_watcher() {
  local dir out
  dir=$(make_guard_case branch-watcher-down)
  out=$(run_guard_case_as_branch "$dir")
  assert_not_contains "$out" "WATCHER DOWN" "the branch actor was shown the watcher-down banner: $out"
  assert_not_contains "$out" "watcher still down" "the branch actor was shown the watcher-down reminder: $out"
  assert_not_contains "$out" "repair" "the branch actor was given a watcher repair instruction: $out"
  out=$(run_guard_case "$dir")
  [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "a branch call must not consume main's full banner for the episode: $out"
  out=$(run_guard_case_as_branch "$dir")
  [ -z "$out" ] || fail "the branch actor must stay silent inside main's episode: $out"
  out=$(run_guard_case "$dir")
  assert_contains "$out" "full banner already printed this episode" \
    "a branch call must not end main's down-episode"
  pass "fm-guard stale banner: the branch actor is never told to repair the watcher and leaves main's episode alone"
}

test_first_stale_call_prints_full_banner() {
  local dir out
  dir=$(make_guard_case first-stale)
  out=$(run_guard_case "$dir")
  [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "first stale guard call did not print exactly one full banner: $out"
  assert_contains "$out" "Trust the emitted supervision protocol" \
    "full banner must keep the actionable watcher-repair instruction"
  assert_contains "$out" "WILL still run" \
    "full banner must keep the guarded-operation continuation line"
  pass "fm-guard stale banner: first stale call prints the full actionable banner"
}

test_full_banner_names_quiet_mode_when_active() {
  # kunchenguid/firstmate#2356: the banner's repair line must not misdirect a
  # captain in quiet mode to /afk - fm-guard.sh threads the flag's declared
  # mode through to fm-supervision-instructions.sh's --afk-mode.
  local dir home out
  dir=$(make_guard_case quiet-mode-banner)
  home=$(case_home "$dir")
  printf 'quiet\n%s\n' "$(date '+%s')" > "$home/state/.afk"
  out=$(run_guard_case "$dir")
  assert_contains "$out" "Quiet mode owns watcher supervision; load /quiet" \
    "full banner did not name /quiet for an active quiet-mode flag"
  assert_not_contains "$out" "Away mode owns watcher supervision" \
    "full banner misdirected a quiet-mode captain to /afk"
  pass "fm-guard stale banner: repair line is quiet-mode-aware, not hardcoded to away mode"
}

test_repeated_same_episode_prints_reminder_only() {
  local dir out1 out2 marker lines
  dir=$(make_guard_case repeated-stale)
  out1=$(run_guard_case "$dir")
  out2=$(run_guard_case "$dir")
  [ "$(count_text "$out1" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "first stale call did not print the full banner: $out1"
  [ "$(count_text "$out2" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 0 ] \
    || fail "second stale call repeated the full banner: $out2"
  assert_contains "$out2" "full banner already printed this episode" \
    "second stale call did not print the concise reminder"
  marker="$(case_home "$dir")/state/.guard-watcher-stale-banner"
  assert_present "$marker" "stale banner marker was not written under the owning home"
  lines=$(awk 'END { print NR + 0 }' "$marker")
  [ "$lines" -le 1 ] || fail "stale banner marker must stay bounded to one line, got $lines"
  pass "fm-guard stale banner: repeated same-episode calls print a concise reminder only"
}

test_fresh_beacon_without_live_watcher_stays_alarm() {
  local dir out
  dir=$(make_guard_case fresh-no-live)
  touch "$(case_home "$dir")/state/.last-watcher-beat"
  out=$(run_guard_case "$dir")
  [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "a fresh leftover beacon without a live watcher must still alarm: $out"
  pass "fm-guard stale banner: a fresh beacon without a live watcher remains unhealthy"
}

test_x_mode_without_live_watcher_stays_alarm() {
  local dir home out
  dir=$(make_guard_case x-mode-no-live)
  home=$(case_home "$dir")
  rm -f "$home/state/task.meta"
  : > "$home/state/x-watch.check.sh"
  out=$(run_guard_case "$dir")
  assert_contains "$out" "X-mode relay polling needs supervision" "X-mode-only need must remain guarded"
  pass "fm-guard stale banner: X-mode polling without a live watcher remains unhealthy"
}

test_healthy_recovery_rearms_next_stale_episode() {
  local dir home out1 healthy out2 pid
  dir=$(make_guard_case healthy-recovery)
  home=$(case_home "$dir")
  out1=$(run_guard_case "$dir")
  [ "$(count_text "$out1" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "first stale episode did not print the full banner: $out1"

  sleep 60 &
  pid=$!
  record_live_watcher "$dir" "$pid" || fail "could not record the live watcher for recovery"
  touch "$home/state/.last-watcher-beat"
  healthy=$(run_guard_case "$dir")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ -z "$healthy" ] || fail "guard should be silent after watcher recovery, got: $healthy"
  assert_absent "$home/state/.guard-watcher-stale-banner" \
    "healthy recovery must clear the stale-banner marker"

  rm -f "$home/state/.last-watcher-beat"
  rm -rf "$home/state/.watch.lock"
  out2=$(run_guard_case "$dir")
  [ "$(count_text "$out2" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "second stale episode did not re-print the full banner: $out2"
  pass "fm-guard stale banner: healthy recovery rearms the next stale episode"
}

test_concurrent_same_episode_prints_one_full_banner() {
  local dir out_dir i pids pid all full reminders
  dir=$(make_guard_case concurrent-stale)
  out_dir="$dir/outs"
  mkdir -p "$out_dir"
  pids=
  i=1
  while [ "$i" -le 30 ]; do
    (
      run_guard_case "$dir" > "$out_dir/$i.out" 2>&1
    ) &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || fail "concurrent guard subprocess failed"
  done
  all=$(cat "$out_dir"/*.out)
  full=$(count_text "$all" "WATCHER DOWN - SUPERVISION IS OFF")
  reminders=$(count_text "$all" "full banner already printed this episode")
  [ "$full" -eq 1 ] || fail "concurrent same-episode calls printed $full full banners"$'\n'"$all"
  [ "$reminders" -eq 29 ] || fail "concurrent same-episode calls printed $reminders reminders, expected 29"$'\n'"$all"
  pass "fm-guard stale banner: concurrent same-episode calls claim exactly one full banner"
}

test_home_isolation() {
  local dir_a dir_b out_a1 out_a2 out_b1
  dir_a=$(make_guard_case home-a)
  dir_b=$(make_guard_case home-b)
  out_a1=$(run_guard_case "$dir_a")
  out_b1=$(run_guard_case "$dir_b")
  out_a2=$(run_guard_case "$dir_a")
  [ "$(count_text "$out_a1" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "home A first stale call did not print a full banner: $out_a1"
  [ "$(count_text "$out_b1" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "home B first stale call was suppressed by home A: $out_b1"
  assert_contains "$out_a2" "full banner already printed this episode" \
    "home A repeated stale call did not remember its own episode"
  pass "fm-guard stale banner: deduplication is isolated per FM_HOME"
}

test_queued_wake_warning_stays_independent() {
  local dir home out1 out2
  dir=$(make_guard_case queued-wake)
  home=$(case_home "$dir")
  out1=$(run_guard_case "$dir")
  [ "$(count_text "$out1" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "first stale call did not print the full banner before queued wake case: $out1"
  printf 'signal: %s/state/task.status\n' "$home" > "$home/state/.wake-queue"
  out2=$(run_guard_case "$dir")
  assert_contains "$out2" "full banner already printed this episode" \
    "same-episode stale call should still print its concise reminder"
  assert_contains "$out2" "queued wakes pending" \
    "queued wake warning must not be suppressed by stale-banner deduplication"
  pass "fm-guard stale banner: queued-wake warning remains independent"
}

test_read_only_before_writable_does_not_consume_full_banner() {
  local dir home marker lock out_ro out_rw
  dir=$(make_guard_case read-only-before-writable)
  home=$(case_home "$dir")
  marker="$home/state/.guard-watcher-stale-banner"
  lock="$home/state/.guard-watcher-stale-banner.lock"

  out_ro=$(run_guard_case_read_only "$dir")
  [ "$(count_text "$out_ro" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "read-only stale call should print the advisory full banner: $out_ro"
  assert_absent "$marker" "read-only stale call must not create the stale-banner marker"
  assert_absent "$lock" "read-only stale call must not create the stale-banner lock"

  out_rw=$(run_guard_case "$dir")
  [ "$(count_text "$out_rw" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "writable stale call should still receive the full banner after read-only: $out_rw"
  assert_present "$marker" "writable stale call should claim the stale-banner marker"
  pass "fm-guard stale banner: read-only before writable does not consume full banner"
}

test_read_only_during_episode_observes_without_mutating_marker() {
  local dir home marker before after out_ro
  dir=$(make_guard_case read-only-during-episode)
  home=$(case_home "$dir")
  marker="$home/state/.guard-watcher-stale-banner"

  run_guard_case "$dir" >/dev/null
  before=$(cat "$marker")
  out_ro=$(run_guard_case_read_only "$dir")
  after=$(cat "$marker")
  assert_contains "$out_ro" "full banner already printed this episode" \
    "read-only stale call during a claimed episode should print the concise reminder"
  [ "$after" = "$before" ] || fail "read-only stale call must not update an existing marker"
  pass "fm-guard stale banner: read-only during episode observes without mutating marker"
}

test_healthy_read_only_does_not_clear_marker() {
  local dir home marker before after healthy pid
  dir=$(make_guard_case healthy-read-only)
  home=$(case_home "$dir")
  marker="$home/state/.guard-watcher-stale-banner"

  run_guard_case "$dir" >/dev/null
  before=$(cat "$marker")
  sleep 60 &
  pid=$!
  record_live_watcher "$dir" "$pid" || fail "could not record the live watcher for read-only recovery"
  touch "$home/state/.last-watcher-beat"
  healthy=$(run_guard_case_read_only "$dir")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ -z "$healthy" ] || fail "healthy read-only guard should stay silent, got: $healthy"
  assert_present "$marker" "healthy read-only guard must not clear the stale-banner marker"
  after=$(cat "$marker")
  [ "$after" = "$before" ] || fail "healthy read-only guard must not update the marker"
  pass "fm-guard stale banner: healthy read-only does not clear marker"
}

test_read_only_never_mutates_stale_banner_state_files() {
  local dir home marker lock before after no_work
  dir=$(make_guard_case read-only-state-nonmutation)
  home=$(case_home "$dir")
  marker="$home/state/.guard-watcher-stale-banner"
  lock="$home/state/.guard-watcher-stale-banner.lock"
  printf '%s\n' "sentinel-marker" > "$marker"

  before=$(find "$home/state" -maxdepth 1 -mindepth 1 -name '.guard-watcher-stale-banner*' -print | sort)
  run_guard_case_read_only "$dir" >/dev/null
  after=$(find "$home/state" -maxdepth 1 -mindepth 1 -name '.guard-watcher-stale-banner*' -print | sort)
  [ "$after" = "$before" ] || fail "stale read-only guard changed stale-banner state files"$'\n'"before: $before"$'\n'"after: $after"
  [ "$(cat "$marker")" = "sentinel-marker" ] || fail "stale read-only guard updated the marker content"
  assert_absent "$lock" "stale read-only guard must not create the stale-banner lock"

  rm -f "$home/state/task.meta"
  no_work=$(run_guard_case_read_only "$dir")
  [ -z "$no_work" ] || fail "read-only guard with no in-flight work should stay silent, got: $no_work"
  after=$(find "$home/state" -maxdepth 1 -mindepth 1 -name '.guard-watcher-stale-banner*' -print | sort)
  [ "$after" = "$before" ] || fail "no-work read-only guard changed stale-banner state files"$'\n'"before: $before"$'\n'"after: $after"
  [ "$(cat "$marker")" = "sentinel-marker" ] || fail "no-work read-only guard updated the marker content"
  pass "fm-guard stale banner: read-only never mutates stale-banner state files"
}

test_autoarm_fresh_beacon_without_watcher_warns() {
  local dir out
  dir=$(make_guard_case autoarm-fresh)
  # A fresh beacon without a live watcher cannot satisfy the shared predicate.
  touch "$(case_home "$dir")/state/.last-watcher-beat"
  out=$(run_guard_case_autoarm "$dir")
  assert_contains "$out" "WATCHER DOWN - SUPERVISION IS OFF" "a leftover auto-arm beacon must not prove liveness"
  pass "fm-guard stale banner: auto-arm leftover beacons do not prove liveness"
}

test_autoarm_stale_beacon_alarms_with_correct_reason() {
  local dir out
  dir=$(make_guard_case autoarm-stale)
  # No beacon at all -> a genuine supervision lapse even under the auto-arm model.
  out=$(run_guard_case_autoarm "$dir")
  [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "auto-arm model with an absent/stale beacon must alarm: $out"
  assert_contains "$out" "no watcher has a fresh beacon" \
    "auto-arm stale-beacon banner must name the stale-beacon reason"
  pass "fm-guard stale banner: auto-arm stale beacon alarms with the true reason"
}

test_autoarm_stale_episode_is_stable() {
  local dir out1 out2
  dir=$(make_guard_case autoarm-stable-episode)
  out1=$(run_guard_case_autoarm "$dir")
  out2=$(run_guard_case_autoarm "$dir")
  [ "$(count_text "$out1" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "first auto-arm stale call did not print the full banner: $out1"
  [ "$(count_text "$out2" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 0 ] \
    || fail "auto-arm stale episode re-printed the full banner instead of deduping: $out2"
  assert_contains "$out2" "full banner already printed this episode" \
    "second auto-arm stale call did not print the concise reminder"
  pass "fm-guard stale banner: auto-arm stale episode stays one episode across calls"
}

# A long Claude handling turn still needs a live supervisor: a rewake ledger
# and live session lock alone cannot silence the shared guard predicate.
test_autoarm_rewake_without_watcher_warns() {
  local dir home out pid
  dir=$(make_guard_case autoarm-long-turn)
  home=$(case_home "$dir")
  sleep 60 &
  pid=$!
  record_aged_rewake_epoch "$home" "$pid"
  record_session_lock_pid "$home" "$pid"
  out=$(run_guard_case_autoarm "$dir")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_contains "$out" "WATCHER DOWN - SUPERVISION IS OFF" "a rewake ledger must not replace a live supervisor"
  assert_present "$home/state/.guard-watcher-stale-banner" "a stale unsupervised turn must open a down-episode"
  pass "fm-guard stale banner: a rewake ledger without a live watcher still warns"
}

# Legacy generation metadata, complete or incomplete, cannot replace a live
# watcher under the shared strict predicate.
test_autoarm_legacy_signals_never_replace_a_live_watcher() {
  local dir home out pid replacement_pid='' case_name
  for case_name in no-epoch failed-outcome failure-notified failure-alarmed dead-lock missing-lock changed-lock moved-recovery later-beacon; do
    dir=$(make_guard_case "autoarm-long-turn-$case_name")
    home=$(case_home "$dir")
    sleep 60 &
    pid=$!
    record_aged_rewake_epoch "$home" "$pid"
    record_session_lock_pid "$home" "$pid"
    case "$case_name" in
      no-epoch)
        rm -f "$home/state/.claude-autoarm-epoch"
        ;;
      failed-outcome)
        printf 'epoch=7 owner_pid=1 outcome=failed updated_at=1\n' > "$home/state/.claude-autoarm-epoch"
        touch -t 202001010000 "$home/state/.claude-autoarm-epoch"
        ;;
      failure-notified)
        : > "$home/state/.claude-autoarm-failure-notified"
        ;;
      failure-alarmed)
        : > "$home/state/.claude-autoarm-failure-alarmed"
        ;;
      dead-lock)
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        pid=
        ;;
      missing-lock)
        rm -f "$home/state/.lock"
        ;;
      changed-lock)
        sleep 60 &
        replacement_pid=$!
        record_session_lock_pid "$home" "$replacement_pid"
        ;;
      moved-recovery)
        printf 'pending:handling:later-turn-generation\n' > "$home/state/.watcher-down"
        ;;
      later-beacon)
        touch -t 202101010000 "$home/state/.last-watcher-beat"
        ;;
    esac
    out=$(run_guard_case_autoarm "$dir")
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
    [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
    [ -z "$replacement_pid" ] || kill "$replacement_pid" 2>/dev/null || true
    [ -z "$replacement_pid" ] || wait "$replacement_pid" 2>/dev/null || true
    replacement_pid=
    [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
      || fail "auto-arm long-turn health must not survive $case_name; guard output: $out"
    assert_contains "$out" "no watcher has a fresh beacon" \
      "a genuine auto-arm lapse with $case_name must still name the stale beacon"
  done
  pass "fm-guard stale banner: legacy auto-arm signals never replace a live watcher"
}

# An open arming claim is between-turn startup, not evidence that the current
# handling turn came from a healthy rewake.
test_autoarm_open_claim_does_not_explain_stale_beacon() {
  local dir home out pid identity
  dir=$(make_guard_case autoarm-open-claim)
  home=$(case_home "$dir")
  sleep 60 &
  pid=$!
  identity=$(fm_test_pid_identity "$pid") \
    || fail "could not compute the open-claim owner identity"
  [ -n "$identity" ] || fail "open-claim owner identity was empty"
  printf 'epoch=3 owner_pid=%s outcome=arming updated_at=%s\n%s\n' \
    "$pid" "$(date +%s)" "$identity" > "$home/state/.claude-autoarm-epoch"
  out=$(run_guard_case_autoarm "$dir")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "an open auto-arm claim must not suppress a stale-beacon alarm: $out"
  pass "fm-guard stale banner: an open auto-arm claim does not explain a stale beacon"
}

# The long-turn tolerance is a Claude auto-arm carve-out. The same leftover
# rewake ledger must not silence Pi/extension or persistent primaries.
test_autoarm_long_turn_does_not_silence_other_models() {
  local dir home out pid model
  for model in persistent extension; do
    dir=$(make_guard_case "autoarm-carveout-$model")
    home=$(case_home "$dir")
    sleep 60 &
    pid=$!
    record_aged_rewake_epoch "$home" "$pid"
    record_session_lock_pid "$home" "$pid"
    if [ "$model" = extension ]; then
      out=$(run_guard_case_extension "$dir")
    else
      out=$(run_guard_case "$dir")
    fi
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
      || fail "a $model primary must still alarm on a stale beacon despite a leftover rewake epoch: $out"
  done
  pass "fm-guard stale banner: auto-arm long-turn health does not leak to other models"
}

test_persistent_no_watcher_banner_names_missing_process() {
  local dir out
  dir=$(make_guard_case persistent-no-watcher-reason)
  # A fresh beacon with no live watcher under the persistent model: the real
  # failing condition is the missing process, not a stale beacon.
  touch "$(case_home "$dir")/state/.last-watcher-beat"
  out=$(run_guard_case "$dir")
  assert_contains "$out" "no live watcher process holds this home lock" \
    "persistent no-watcher banner must name the missing watcher process"
  assert_not_contains "$out" "no watcher has a fresh beacon" \
    "persistent no-watcher banner must not blame the fresh beacon"
  pass "fm-guard stale banner: persistent no-watcher banner names the true reason"
}

test_persistent_no_watcher_episode_survives_beacon_touch() {
  local dir home out1 out2
  dir=$(make_guard_case persistent-no-watcher-episode)
  home=$(case_home "$dir")
  touch "$home/state/.last-watcher-beat"
  out1=$(run_guard_case "$dir")
  [ "$(count_text "$out1" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "first persistent no-watcher call did not print the full banner: $out1"
  # The beacon mtime advancing with NO live watcher must not split the continuous
  # down-episode. The old beacon-mtime episode key re-printed the full banner
  # here; the reason-based key keeps it a single episode. Separate the touches by
  # a second so the mtime genuinely changes at whole-second stat granularity.
  sleep 1
  touch "$home/state/.last-watcher-beat"
  out2=$(run_guard_case "$dir")
  [ "$(count_text "$out2" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 0 ] \
    || fail "advancing the beacon mtime with no live watcher re-printed the banner: $out2"
  assert_contains "$out2" "full banner already printed this episode" \
    "same no-watcher episode did not print the concise reminder after a beacon touch"
  pass "fm-guard stale banner: a no-watcher episode survives a beacon mtime change"
}

# A Pi extension hand-off with no watcher has the same liveness verdict as
# the turn-end guard, regardless of loaded extension ownership markers.
test_extension_handoff_without_watcher_warns() {
  local dir home out pid
  dir=$(make_guard_case extension-handoff)
  home=$(case_home "$dir")
  sleep 60 &
  pid=$!
  record_pi_extension_session "$dir" "$pid" || fail "could not record the Pi extension session"
  touch "$home/state/.last-watcher-beat"
  out=$(run_guard_case_extension "$dir")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_contains "$out" "WATCHER DOWN - SUPERVISION IS OFF" "extension markers must not replace a live supervisor"
  assert_present "$home/state/.guard-watcher-stale-banner" "an unheld extension handoff must open a down-episode"
  pass "fm-guard stale banner: extension ownership does not replace a live supervisor"
}

# An empty watcher lock proves no owner even with loaded extension markers.
test_extension_handoff_with_empty_lock_warns() {
  local dir home out pid
  dir=$(make_guard_case extension-empty-lock)
  home=$(case_home "$dir")
  sleep 60 &
  pid=$!
  record_pi_extension_session "$dir" "$pid" || fail "could not record the Pi extension session"
  mkdir -p "$home/state/.watch.lock"
  touch "$home/state/.last-watcher-beat"
  out=$(run_guard_case_extension "$dir")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_contains "$out" "WATCHER DOWN - SUPERVISION IS OFF" "an empty watcher lock must not prove liveness"
  assert_present "$home/state/.guard-watcher-stale-banner" "an empty lock must open a down-episode"
  pass "fm-guard stale banner: an empty extension handoff lock still warns"
}

# Extension ownership tolerates only a released lock. Every non-empty recorded
# pid means the lock is held, so any strict watcher-health failure stays loud.
test_extension_held_unhealthy_locks_stay_alarm() {
  local dir home out session_pid holder_pid case_name
  for case_name in dead-pid malformed-pid wrong-home wrong-path identity-mismatch; do
    dir=$(make_guard_case "extension-held-$case_name")
    home=$(case_home "$dir")
    sleep 60 &
    session_pid=$!
    record_pi_extension_session "$dir" "$session_pid" \
      || fail "could not record the Pi extension session for $case_name"
    holder_pid=
    case "$case_name" in
      malformed-pid)
        mkdir -p "$home/state/.watch.lock"
        printf '%s\n' not-a-pid > "$home/state/.watch.lock/pid"
        ;;
      *)
        sleep 60 &
        holder_pid=$!
        record_live_watcher "$dir" "$holder_pid" \
          || fail "could not record the watcher lock for $case_name"
        case "$case_name" in
          dead-pid)
            kill "$holder_pid" 2>/dev/null || true
            wait "$holder_pid" 2>/dev/null || true
            holder_pid=
            ;;
          wrong-home)
            printf '%s\n' "$home/other" > "$home/state/.watch.lock/fm-home"
            ;;
          wrong-path)
            printf '%s\n' "$home/bin/not-fm-watch.sh" > "$home/state/.watch.lock/watcher-path"
            ;;
          identity-mismatch)
            printf '%s\n' mismatched-identity > "$home/state/.watch.lock/pid-identity"
            ;;
        esac
        ;;
    esac
    touch "$home/state/.last-watcher-beat"
    out=$(run_guard_case_extension "$dir")
    [ -z "$holder_pid" ] || kill "$holder_pid" 2>/dev/null || true
    [ -z "$holder_pid" ] || wait "$holder_pid" 2>/dev/null || true
    kill "$session_pid" 2>/dev/null || true
    wait "$session_pid" 2>/dev/null || true
    [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
      || fail "an extension-owned held lock with $case_name must alarm: $out"
    assert_contains "$out" "no live watcher process holds this home lock" \
      "a held unhealthy lock with $case_name must report no-watcher"
  done
  pass "fm-guard stale banner: held unhealthy extension locks stay loud"
}

# The same unheld lock and fresh beacon, with NO extension ownership to prove, is
# the genuinely-down cycle and must stay exactly as loud as before.
test_extension_without_ownership_evidence_stays_alarm() {
  local dir home out
  dir=$(make_guard_case extension-no-evidence)
  home=$(case_home "$dir")
  touch "$home/state/.last-watcher-beat"
  out=$(run_guard_case_extension "$dir")
  [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "an unheld lock with no extension ownership evidence must alarm: $out"
  assert_contains "$out" "no live watcher process holds this home lock" \
    "the unowned extension-model banner must name the missing watcher process"
  pass "fm-guard stale banner: extension model without ownership evidence stays loud"
}

# Complete or incomplete extension markers do not establish a live watcher.
test_extension_legacy_signals_never_replace_a_live_watcher() {
  local dir home out pid case_name spec
  for spec in \
    "dead-session:dead::" \
    "missing-watch-marker:live:watch:" \
    "missing-turnend-marker:live:turnend:" \
    "drifted-watch-build:live::watch" \
    "drifted-turnend-build:live::turnend" \
    "handoff-watch-generation:live::" \
    "legacy-watch-marker:live::"; do
    case_name=${spec%%:*}
    dir=$(make_guard_case "extension-$case_name")
    home=$(case_home "$dir")
    sleep 60 &
    pid=$!
    if [ "$(printf '%s' "$spec" | cut -d: -f2)" = dead ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
    record_pi_extension_session "$dir" "$pid" \
      "$(printf '%s' "$spec" | cut -d: -f3)" \
      "$(printf '%s' "$spec" | cut -d: -f4)" \
      || fail "could not record the Pi extension session for $case_name"
    case "$case_name" in
      handoff-watch-generation)
        head -n 2 "$home/state/.pi-watch-extension-loaded" \
          > "$home/state/.pi-watch-extension-loaded.tmp"
        printf 'generation=1 phase=handoff\n' \
          >> "$home/state/.pi-watch-extension-loaded.tmp"
        mv "$home/state/.pi-watch-extension-loaded.tmp" "$home/state/.pi-watch-extension-loaded"
        ;;
      legacy-watch-marker)
        head -n 2 "$home/state/.pi-watch-extension-loaded" \
          > "$home/state/.pi-watch-extension-loaded.tmp"
        mv "$home/state/.pi-watch-extension-loaded.tmp" "$home/state/.pi-watch-extension-loaded"
        ;;
    esac
    touch "$home/state/.last-watcher-beat"
    out=$(run_guard_case_extension "$dir")
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
      || fail "extension ownership must not survive $case_name; guard output: $out"
  done
  pass "fm-guard stale banner: legacy extension signals never replace a live watcher"
}

# Ownership tolerates the hand-off, never a supervision lapse: once the beacon
# passes the grace window the extension has not restored the cycle and the banner
# must fire even with a fully live, correctly loaded Pi session.
test_extension_stale_beacon_alarms_despite_live_session() {
  local dir home out pid
  dir=$(make_guard_case extension-stale-beacon)
  home=$(case_home "$dir")
  sleep 60 &
  pid=$!
  record_pi_extension_session "$dir" "$pid" || fail "could not record the Pi extension session"
  out=$(FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$home" \
    FM_GUARD_GRACE=1 \
    FM_SUPERVISION_MODEL=extension \
    "$ROOT/bin/fm-guard.sh" 2>&1)
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "a beacon past grace must alarm even under a live Pi session: $out"
  assert_contains "$out" "no watcher has a fresh beacon" \
    "the extension-model stale-beacon banner must name the stale beacon"
  pass "fm-guard stale banner: extension model still alarms on a genuinely stale beacon"
}

# The queued-wake hazard is independent of the watcher verdict and must survive the
# hand-off tolerance: a silenced banner must never take this warning down with it.
test_extension_handoff_keeps_queued_wake_warning() {
  local dir home out pid
  dir=$(make_guard_case extension-queued-wake)
  home=$(case_home "$dir")
  sleep 60 &
  pid=$!
  record_pi_extension_session "$dir" "$pid" || fail "could not record the Pi extension session"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "1700000000	1	signal	task	signal: crewmate needs a decision" > "$home/state/.wake-queue"
  out=$(run_guard_case_extension "$dir")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_contains "$out" "queued wakes pending" \
    "the queued-wake warning must still fire during an extension-owned hand-off"
  assert_contains "$out" "WATCHER DOWN - SUPERVISION IS OFF" "handoff must retain the same missing-supervisor warning"
  pass "fm-guard stale banner: queued-wake warning remains independent during handoff"
}

# The tolerance is scoped to the extension model alone. Every persistent-watcher
# primary (codex, opencode, grok, kimi, tmux, unknown) must keep alarming on the
# same state, even when Pi extension markers happen to be present on disk.
# The supervision branch runs guarded commands (fm-peek, fm-crew-state) while
# handling the very rows that are queued. For that actor the drain warning is
# not advice, it is the misreading that re-ran a previous acknowledgement in a
# loop, so the guard stays silent about queued rows for that actor.
test_branch_actor_is_not_told_to_drain_queued_wakes() {
  local dir home out pid
  dir=$(make_guard_case branch-actor-queued-wake)
  home=$(case_home "$dir")
  sleep 60 &
  pid=$!
  record_pi_extension_session "$dir" "$pid" || fail "could not record the Pi extension session"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' \
    "1700000000	7	stale	firstmate:fm-task	stale: firstmate:fm-task (idle 378s, possible wedge)" \
    "1700000001	8	check	merge-poll	check: merge-poll: merged" > "$home/state/.wake-queue"
  printf '7\n' > "$home/state/.branch-eligible-rows"
  out=$(run_guard_case_extension_as_branch "$dir")
  assert_not_contains "$out" "queued wakes pending" \
    "the branch actor must not be told to drain the rows it is already handling"
  assert_not_contains "$out" "wake row" \
    "the branch actor gets no replacement note about queued rows"
  rm -f "$home/state/.branch-eligible-rows"
  out=$(run_guard_case_extension_as_branch "$dir")
  assert_not_contains "$out" "queued wakes pending" \
    "a branch actor with no grant can drain nothing, so the warning must stay silent"
  out=$(run_guard_case_extension "$dir")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_contains "$out" "queued wakes pending" \
    "main must still be warned about the queued rows"
  pass "fm-guard: the branch actor is never told to drain queued wakes while main still is"
}

test_persistent_model_ignores_pi_extension_evidence() {
  local dir home out pid
  dir=$(make_guard_case persistent-ignores-pi-evidence)
  home=$(case_home "$dir")
  sleep 60 &
  pid=$!
  record_pi_extension_session "$dir" "$pid" || fail "could not record the Pi extension session"
  touch "$home/state/.last-watcher-beat"
  out=$(run_guard_case "$dir")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "a persistent-watcher primary must still alarm with Pi markers present: $out"
  assert_contains "$out" "no live watcher process holds this home lock" \
    "the persistent-model banner must still name the missing watcher process"
  pass "fm-guard stale banner: persistent primaries ignore Pi extension evidence"
}

# An extension-owned home with a genuinely live watcher is the ordinary steady
# state and must stay silent through the strict path, not through the tolerance.
test_extension_live_watcher_is_healthy_without_ownership_evidence() {
  local dir home out pid
  dir=$(make_guard_case extension-live-watcher)
  home=$(case_home "$dir")
  sleep 60 &
  pid=$!
  record_live_watcher "$dir" "$pid" || fail "could not record the live watcher"
  touch "$home/state/.last-watcher-beat"
  out=$(run_guard_case_extension "$dir")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ -z "$out" ] \
    || fail "a live identity-matched watcher must be healthy under the extension model, got: $out"
  pass "fm-guard stale banner: extension model stays silent for a live watcher"
}

# The cases above pin the model. This one takes the end-user path instead: no
# FM_SUPERVISION_MODEL at all, so bin/fm-harness.sh must route a Pi primary to the
# extension model on its own. Without that routing the tolerance would never reach
# a real Pi home. Pinning Pi takes both halves of the evidence: the foreign markers
# are cleared because the host running this suite may carry one, and the ancestry
# walk is blinded because a structural ancestor of a different harness outranks the
# Pi marker, so the harness this suite was launched from would otherwise answer.
test_pi_harness_uses_shared_strict_liveness() {
  local dir home out pid harness blind
  local -a pi_env
  blind=$(fm_fakebin "$TMP_ROOT/pi-routing-blind")
  fm_fake_blind_ancestry "$blind"
  for harness in pi pi-signed; do
    pi_env=(PI_CODING_AGENT=true)
    [ "$harness" = pi ] || pi_env+=(FM_PI_HARNESS=pi-signed)
    dir=$(make_guard_case "harness-routing-$harness")
    home=$(case_home "$dir")
    sleep 60 &
    pid=$!
    record_pi_extension_session "$dir" "$pid" || fail "could not record the Pi extension session"
    touch "$home/state/.last-watcher-beat"
    out=$(env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GROK_AGENT -u FM_SUPERVISION_MODEL \
      "${pi_env[@]}" \
      PATH="$blind:$PATH" \
      FM_ROOT_OVERRIDE="$(case_root "$dir")" \
      FM_HOME="$home" \
      FM_GUARD_GRACE=999 \
      "$ROOT/bin/fm-guard.sh" 2>&1)
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    assert_contains "$out" "WATCHER DOWN - SUPERVISION IS OFF" "a $harness primary must use strict liveness despite extension markers"
  done
  pass "fm-guard stale banner: Pi and pi-signed primaries use the same strict liveness"
}

test_warning_and_turnend_share_liveness() {
  local dir home root model scenario pid out status expected identity
  sleep 60 &
  pid=$!
  for model in persistent autoarm extension; do
    for scenario in healthy handoff missing-lock stale-beacon wrong-identity away-daemon; do
      dir=$(make_guard_case "shared-$model-$scenario")
      home=$(case_home "$dir")
      root=$(case_root "$dir")
      git init -q "$root"
      : > "$root/AGENTS.md"
      mkdir -p "$root/bin"
      touch "$home/state/.last-watcher-beat"
      expected=2
      case "$scenario" in
        healthy|stale-beacon|wrong-identity)
          record_live_watcher "$dir" "$pid" || fail "could not record shared watcher"
          case "$scenario" in
            healthy) expected=0 ;;
            stale-beacon) touch -t 202001010000 "$home/state/.last-watcher-beat" ;;
            wrong-identity) printf 'wrong\n' > "$home/state/.watch.lock/pid-identity" ;;
          esac ;;
        handoff) record_pi_extension_session "$dir" "$pid" || fail "could not record extension handoff" ;;
        away-daemon)
          : > "$home/state/.afk"
          mkdir "$home/state/.supervise-daemon.lock"
          identity=$(fm_test_pid_identity "$pid") || fail "could not identify away owner"
          printf '%s\n' "$pid" > "$home/state/.supervise-daemon.lock/pid"
          printf '%s\n' "$identity" > "$home/state/.supervise-daemon.lock/pid-identity"
          expected=0 ;;
      esac
      out=$(FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_SUPERVISION_MODEL="$model" bash "$ROOT/bin/fm-guard.sh" 2>&1)
      if [ "$expected" -eq 0 ]; then
        [ -z "$out" ] || fail "$model/$scenario warning rejected live supervision: $out"
      else
        assert_contains "$out" "WATCHER DOWN - SUPERVISION IS OFF" "$model/$scenario warning accepted missing supervision"
      fi
      out=$(printf '{"stop_hook_active":false}' | FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_SUPERVISION_MODEL="$model" bash "$ROOT/bin/fm-turnend-guard.sh" 2>&1); status=$?
      expect_code "$expected" "$status" "$model/$scenario turn-end and warning must agree"
    done
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "fm-guard and turn-end: identical liveness for watcher, handoff, missing lock, stale beacon, identity mismatch and away owner"
}

test_warning_and_turnend_share_liveness
test_first_stale_call_prints_full_banner
test_full_banner_names_quiet_mode_when_active
test_repeated_same_episode_prints_reminder_only
test_pi_harness_uses_shared_strict_liveness
test_extension_handoff_without_watcher_warns
test_extension_handoff_with_empty_lock_warns
test_extension_held_unhealthy_locks_stay_alarm
test_extension_without_ownership_evidence_stays_alarm
test_extension_legacy_signals_never_replace_a_live_watcher
test_extension_stale_beacon_alarms_despite_live_session
test_extension_handoff_keeps_queued_wake_warning
test_branch_actor_is_not_told_to_drain_queued_wakes
test_branch_actor_is_never_told_to_repair_the_watcher
test_persistent_model_ignores_pi_extension_evidence
test_extension_live_watcher_is_healthy_without_ownership_evidence
test_autoarm_fresh_beacon_without_watcher_warns
test_autoarm_stale_beacon_alarms_with_correct_reason
test_autoarm_stale_episode_is_stable
test_autoarm_rewake_without_watcher_warns
test_autoarm_legacy_signals_never_replace_a_live_watcher
test_autoarm_open_claim_does_not_explain_stale_beacon
test_autoarm_long_turn_does_not_silence_other_models
test_persistent_no_watcher_banner_names_missing_process
test_persistent_no_watcher_episode_survives_beacon_touch
test_fresh_beacon_without_live_watcher_stays_alarm
test_x_mode_without_live_watcher_stays_alarm
test_healthy_recovery_rearms_next_stale_episode
test_concurrent_same_episode_prints_one_full_banner
test_home_isolation
test_queued_wake_warning_stays_independent
test_read_only_before_writable_does_not_consume_full_banner
test_read_only_during_episode_observes_without_mutating_marker
test_healthy_read_only_does_not_clear_marker
test_read_only_never_mutates_stale_banner_state_files
