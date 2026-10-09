#!/usr/bin/env bash
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-orphan-safety)
BIN=${FM_ORPHAN_SAFETY_BIN:-$ROOT/bin}
REAL_PS=$(command -v ps)

test_reaper_identity() {
  local mode=$1 dir out wanted
  dir="$TMP_ROOT/$mode"
  mkdir -p "$dir/fm-fixture"
  printf '999999\nended-owner\n' > "$dir/fm-fixture/.fm-test-fixture"
  if [ "$mode" = owner-unknown ]; then
    printf '%s\n%s\n' "$$" "$FM_TEST_OWNER_IDENTITY" > "$dir/fm-fixture/.fm-test-fixture"
  fi
  cat > "$dir/processes.sh" <<'SH'
ps() {
  if [ "$1" = -U ]; then
    printf '424241 1 Thu Oct  8 12:00:00 2026 bash %s/fm-fixture/stub.sh\n' "$FM_SAFETY_DIR"
    if [ "$FM_SAFETY_MODE" = snapshot-descendant ]; then
      printf '424242 424241 Thu Oct  8 12:00:00 2026 sleep 120\n'
    fi
    return 0
  fi
  if [ "$1" = -p ]; then
    local pid=$2 year=2026 cmd
    [ "$pid" != "$FM_SAFETY_OWNER" ] || return 1
    [ ! -e "$FM_SAFETY_DIR/ended.$pid" ] || return 1
    case "$pid" in
      424241) cmd="bash $FM_SAFETY_DIR/fm-fixture/stub.sh" ;;
      424242) cmd='sleep 120' ;;
      *) command "$FM_SAFETY_PS" "$@"; return $? ;;
    esac
    if { [ "$FM_SAFETY_MODE" = snapshot-direct ] && [ "$pid" = 424241 ]; } ||
       { [ "$FM_SAFETY_MODE" = snapshot-descendant ] && [ "$pid" = 424242 ]; } ||
       [ -e "$FM_SAFETY_DIR/replaced.$pid" ]; then
      year=2027
    fi
    printf 'Thu Oct  8 12:00:00 %s %s\n' "$year" "$cmd"
    return 0
  fi
  command "$FM_SAFETY_PS" "$@"
}
kill() {
  case "${2:-}" in
    999999) return 1 ;;
    424241|424242)
      printf '%s %s\n' "$1" "$2" >> "$FM_SAFETY_DIR/signals"
      if [ "$1" = -CONT ] && [ "$FM_SAFETY_MODE" = after-cont ]; then
        : > "$FM_SAFETY_DIR/replaced.$2"
      fi
      if [ "$1" = -KILL ] || { [ "$1" = -TERM ] && [ "$FM_SAFETY_MODE" != before-kill ] && [ "$FM_SAFETY_MODE" != survivor-kill ]; }; then
        : > "$FM_SAFETY_DIR/ended.$2"
      fi
      return 0 ;;
  esac
  builtin kill "$@"
}
sleep() {
  if [ "$FM_SAFETY_MODE" = before-kill ]; then
    local ticks
    ticks=$(cat "$FM_SAFETY_DIR/ticks" 2>/dev/null || echo 0)
    ticks=$((ticks + 1))
    printf '%s\n' "$ticks" > "$FM_SAFETY_DIR/ticks"
    [ "$ticks" -lt 20 ] || : > "$FM_SAFETY_DIR/replaced.424241"
  fi
  return 0
}
SH
  : > "$dir/signals"
  out=$(env BASH_ENV="$dir/processes.sh" FM_SAFETY_DIR="$dir" FM_SAFETY_MODE="$mode" \
    FM_SAFETY_OWNER="$$" FM_SAFETY_PS="$REAL_PS" FM_PROC_ROOT_OVERRIDE="$dir/no-proc" \
    "$BIN/fm-test-reap-orphans.sh" --tmpdir "$dir" 2>&1) || fail "$mode sweep failed: $out"
  case "$mode" in
    snapshot-direct|owner-unknown)
      [ ! -s "$dir/signals" ] || fail "$mode authorized signals without ownership: $(cat "$dir/signals")" ;;
    snapshot-descendant)
      assert_not_contains "$(cat "$dir/signals")" '424242' 'a reused descendant PID was signalled'
      assert_contains "$(cat "$dir/signals")" '-TERM 424241' 'the unchanged owned parent was not terminated' ;;
    after-cont)
      wanted='-CONT 424241'
      [ "$(cat "$dir/signals")" = "$wanted" ] || fail "identity was not rechecked after CONT: $(cat "$dir/signals")" ;;
    before-kill)
      wanted=$(printf '%s\n' '-CONT 424241' '-TERM 424241')
      [ "$(cat "$dir/signals")" = "$wanted" ] || fail "a reused PID was signalled after the grace: $(cat "$dir/signals")" ;;
    survivor-kill)
      wanted=$(printf '%s\n' '-CONT 424241' '-TERM 424241' '-KILL 424241')
      [ "$(cat "$dir/signals")" = "$wanted" ] || fail "the unchanged survivor was not killed: $(cat "$dir/signals")" ;;
  esac
  pass "$mode preserves the process ownership boundary"
}

test_lock_failure() {
  local action=$1 dir state rc out file generation fail_at=1
  dir="$TMP_ROOT/lock-$action"
  state="$dir/state"
  mkdir -p "$state" "$dir/before"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_append signal existing payload' _ \
    "$BIN/fm-wake-lib.sh" || fail 'could not seed the queue'
  FM_STATE_OVERRIDE="$state" "$BIN/fm-wake-grant.sh" activate "$$" original || fail 'could not seed the owner'
  FM_STATE_OVERRIDE="$state" "$BIN/fm-wake-grant.sh" publish original 1 || fail 'could not seed the grant'
  generation=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_recovery_marker_read "$STATE/.watcher-down"; printf "%s\n" "${FM_RECOVERY_MARKER_TOKEN##*:}"' _ "$BIN/fm-wake-lib.sh") || fail 'could not read recovery generation'
  [ "$action" != drain-second ] || fail_at=2
  for file in .wake-queue .wake-queue.seq .watcher-down .branch-eligible-owner .branch-eligible-rows; do
    cp "$state/$file" "$dir/before/$file"
  done
  if [ "$fail_at" -eq 1 ]; then
    mkdir "$state/.wake-queue.lock"
    printf '%s\n' "$$" > "$state/.wake-queue.lock/pid"
  fi
  cat > "$dir/fail-lock.sh" <<'SH'
set -T
lock_calls=0
trap '
  if [ "${FM_SAFETY_FAIL_AT:-1}" = 2 ] && [ "$BASH_COMMAND" = '\''fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"'\'' ]; then
    lock_calls=$((lock_calls + 1))
    if [ "$lock_calls" -eq 2 ]; then
      mkdir "$FM_WAKE_QUEUE_LOCK"
      printf "%s\n" "$FM_SAFETY_LOCK_OWNER" > "$FM_WAKE_QUEUE_LOCK/pid"
    fi
  fi
  if [ "$BASH_COMMAND" = "return 1" ] && [ "${FUNCNAME[0]:-}" = fm_lock_acquire_wait ] && [ -d "$STATE.gone" ]; then
    command mv "$STATE.gone" "$STATE"
  fi
' DEBUG
sleep() {
  if [ -d "$STATE" ]; then command mv "$STATE" "$STATE.gone"; fi
  SECONDS=$((SECONDS + 2))
}
SH
  rc=0
  case "$action" in
    activate) set -- activate "$$" replacement ;;
    publish) set -- publish original 1 ;;
    release) set -- release original ;;
    deactivate) set -- deactivate "$$" original ;;
    append|keys|drain-first|drain-second) set -- ;;
  esac
  if [ "$action" = append ] || [ "$action" = keys ]; then
    out=$(env BASH_ENV="$dir/fail-lock.sh" FM_STATE_OVERRIDE="$state" \
      bash -c '. "$1"; if [ "$2" = append ]; then fm_wake_append signal new payload; else fm_wake_queued_keys signal; fi' \
      _ "$BIN/fm-wake-lib.sh" "$action" 2>&1) || rc=$?
  elif [ "$action" = drain-first ] || [ "$action" = drain-second ]; then
    out=$(env BASH_ENV="$dir/fail-lock.sh" FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch \
      FM_SAFETY_FAIL_AT="$fail_at" FM_SAFETY_LOCK_OWNER="$$" \
      "$BIN/fm-wake-drain.sh" --ack-through 1 --recovery-generation "$generation" 2>&1) || rc=$?
  else
    out=$(env BASH_ENV="$dir/fail-lock.sh" FM_STATE_OVERRIDE="$state" \
      "$BIN/fm-wake-grant.sh" "$@" 2>&1) || rc=$?
  fi
  [ -d "$state" ] && [ ! -e "$state.gone" ] || fail "$action did not exercise the returning-state failure: $out"
  [ "$rc" -eq 1 ] || fail "$action did not propagate lock failure (rc=$rc): $out"
  [ -z "$out" ] || fail "$action emitted protected queue contents after lock failure: $out"
  for file in .wake-queue .wake-queue.seq .watcher-down .branch-eligible-owner .branch-eligible-rows; do
    cmp -s "$state/$file" "$dir/before/$file" || fail "$action changed $file without owning the lock"
  done
  [ "$(cat "$state/.wake-queue.lock/pid")" = "$$" ] || fail "$action changed the foreign lock"
  rm -rf "$state/.wake-queue.lock"
  case "$action" in
    activate) FM_STATE_OVERRIDE="$state" "$BIN/fm-wake-grant.sh" activate "$$" replacement || fail 'ordinary activate failed'
      [ ! -e "$state/.branch-eligible-rows" ] || fail 'ordinary activate retained the old rows' ;;
    publish) rm "$state/.branch-eligible-rows"
      FM_STATE_OVERRIDE="$state" "$BIN/fm-wake-grant.sh" publish original 1 || fail 'ordinary publish failed'
      [ "$(cat "$state/.branch-eligible-rows")" = 1 ] || fail 'ordinary publish lost its row' ;;
    release) FM_STATE_OVERRIDE="$state" "$BIN/fm-wake-grant.sh" release original || fail 'ordinary release failed'
      [ ! -e "$state/.branch-eligible-rows" ] && [ -e "$state/.branch-eligible-owner" ] || fail 'ordinary release changed owner lifetime' ;;
    deactivate) FM_STATE_OVERRIDE="$state" "$BIN/fm-wake-grant.sh" deactivate "$$" original || fail 'ordinary deactivate failed'
      [ ! -e "$state/.branch-eligible-rows" ] && [ ! -e "$state/.branch-eligible-owner" ] || fail 'ordinary deactivate retained its records' ;;
    append) FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_append signal new payload' _ "$BIN/fm-wake-lib.sh" || fail 'ordinary append failed'
      [ "$(cat "$state/.wake-queue.seq")" = 2 ] || fail 'ordinary append lost sequence ordering' ;;
    keys) out=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_queued_keys signal' _ "$BIN/fm-wake-lib.sh") || fail 'ordinary keys failed'
      [ "$out" = existing ] || fail 'ordinary keys lost the queued key' ;;
    drain-first|drain-second)
      FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$BIN/fm-wake-drain.sh" \
        --ack-through 1 --recovery-generation "$generation" >/dev/null || fail 'ordinary acknowledgement failed'
      [ ! -s "$state/.wake-queue" ] && [ ! -e "$state/.branch-eligible-rows" ] \
        || fail 'ordinary acknowledgement retained its granted row' ;;
  esac
  pass "$action propagates acquisition failure without touching protected state"
}

test_link_lock_failure() {
  local action=$1 dir state meta lock out rc
  dir="$TMP_ROOT/link-$action"
  state="$dir/state"
  meta="$state/task.meta"
  mkdir -p "$state"
  printf 'kind=worker\nx_request=original\nx_request_ts=1\nx_followups=2\n' > "$meta"
  cp "$meta" "$dir/before"
  lock=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_meta_lock_path "$2"' _ \
    "$BIN/fm-wake-lib.sh" "$meta") || fail 'could not resolve metadata lock'
  mkdir "$lock"
  printf '%s\n' "$$" > "$lock/pid"
  cat > "$dir/fail-lock.sh" <<'SH'
set -T
trap 'if [ "$BASH_COMMAND" = "return 1" ] && [ "${FUNCNAME[0]:-}" = fm_lock_acquire_wait ] && [ -d "$STATE.gone" ]; then command mv "$STATE.gone" "$STATE"; fi' DEBUG
sleep() {
  if [ -d "$STATE" ]; then command mv "$STATE" "$STATE.gone"; fi
  SECONDS=$((SECONDS + 2))
}
SH
  rc=0
  out=$(env BASH_ENV="$dir/fail-lock.sh" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-x-lib.sh"
    case "$2" in
      link) fmx_meta_link_set "$3" replacement 10 ;;
      followups) fmx_meta_followups_set "$3" 3 ;;
      clear) fmx_meta_link_clear "$3" ;;
    esac
  ' _ "$BIN" "$action" "$meta" 2>&1) || rc=$?
  [ -d "$state" ] && [ ! -e "$state.gone" ] || fail "$action did not exercise returning state: $out"
  [ "$rc" -eq 1 ] || fail "$action did not propagate metadata lock failure: $out"
  cmp -s "$meta" "$dir/before" || fail "$action changed metadata without owning its lock"
  [ "$(cat "$lock/pid")" = "$$" ] || fail "$action changed the foreign metadata lock"
  rm -rf "$lock"
  out=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-x-lib.sh"
    case "$2" in
      link) fmx_meta_link_set "$3" replacement 10 || exit 1; fmx_meta_get "$3" x_request ;;
      followups) fmx_meta_followups_set "$3" 3 || exit 1; fmx_meta_get "$3" x_followups ;;
      clear) fmx_meta_link_clear "$3" || exit 1; fmx_meta_get "$3" x_request ;;
    esac
  ' _ "$BIN" "$action" "$meta") || fail "ordinary $action failed"
  case "$action" in
    link) [ "$out" = replacement ] || fail 'ordinary link lost its request' ;;
    followups) [ "$out" = 3 ] || fail 'ordinary followups lost its count' ;;
    clear) [ -z "$out" ] || fail 'ordinary clear retained its request' ;;
  esac
  pass "$action leaves metadata unchanged after acquisition failure"
}

case "${1:-all}" in
  all)
    for mode in snapshot-direct snapshot-descendant after-cont before-kill survivor-kill owner-unknown; do test_reaper_identity "$mode"; done
    for action in activate publish release deactivate append keys drain-first drain-second; do test_lock_failure "$action"; done
    for action in link followups clear; do test_link_lock_failure "$action"; done ;;
  snapshot-direct|snapshot-descendant|after-cont|before-kill|survivor-kill|owner-unknown) test_reaper_identity "$1" ;;
  activate|publish|release|deactivate|append|keys|drain-first|drain-second) test_lock_failure "$1" ;;
  link|followups|clear) test_link_lock_failure "$1" ;;
  *) exit 2 ;;
esac
