#!/usr/bin/env bash
# r8 one-case driver. Usage: r8-wake-case-driver.sh <worktree> <evdir> <case> <original|seeded> <label>
# Runs the EXISTING case via the suite's FM_TEST_ONLY hook. Observation only:
# - wait_for_exit keeps its exact poll/TERM/KILL logic; `time` (bash builtin, no fork)
#   records its wall time; at the timeout boundary the existing liveness predicate is
#   rechecked once and the case dir is copied BEFORE the unchanged TERM path.
# - seeded mode writes ONLY a current valid empty open-loops ledger right after make_case.
# - on EXIT the case dir is copied to evidence before the suite's normal cleanup.
WT=$1 EV=$2 R8_CASE=$3 R8_MODE=$4 R8_LABEL=$5
export R8_EV="$EV/r8-$R8_LABEL"
mkdir -p "$R8_EV"
cd "$WT" || exit 2
r8_entry() {
  eval "__r8_orig_make_case() $(declare -f make_case | sed 1d)"
  make_case() {
    local d
    d=$(__r8_orig_make_case "$@") || return $?
    R8_CASE_DIRS="${R8_CASE_DIRS:+$R8_CASE_DIRS }$d"
    if [ "$R8_MODE" = seeded ]; then
      printf '{"schema":"fm-open-loops.v1","generated_epoch":%s,"home":"%s","complete":true,"rows":[%s]}\n' \
        "$(date +%s)" "${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}" "" > "$d/state/open-loops.json"
      cp -p "$d/state/open-loops.json" "$R8_EV/seeded-open-loops.json"
    fi
    printf '%s\n' "$d"
  }
  __r8_wfe_body() {
    local pid=$1 limit=${2:-50} i=0
    while [ "$i" -lt "$limit" ]; do
      if ! is_live_non_zombie "$pid"; then
        wait "$pid"
        return "$?"
      fi
      sleep 0.1
      i=$((i + 1))
    done
    if is_live_non_zombie "$pid"; then echo "post-final-sleep recheck: live" >> "$R8_EV/timeout-boundary.txt"
    else echo "post-final-sleep recheck: NOT live (final-sleep gap)" >> "$R8_EV/timeout-boundary.txt"; fi
    local n=0 d
    for d in $(ls -d "$TMP_ROOT"/*/ 2>/dev/null); do
      n=$((n + 1)); cp -Rp "$d" "$R8_EV/timeout-snapshot-$n-$(basename "$d")" 2>/dev/null || true
    done
    printf 'wait_for_exit: owned pid %s exceeded %s polls; sending TERM\n' "$pid" "$limit" >&2
    ps -p "$pid" -o pid= -o ppid= -o stat= -o command= >&2 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
    i=0
    while [ "$i" -lt 20 ] && is_live_non_zombie "$pid"; do
      sleep 0.1
      i=$((i + 1))
    done
    if is_live_non_zombie "$pid"; then
      printf 'wait_for_exit: owned pid %s survived TERM; sending KILL\n' "$pid" >&2
      kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
    return 124
  }
  wait_for_exit() {
    local rc TIMEFORMAT="wait_for_exit pid=$1 limit=${2:-50} real_s=%3R"
    { time __r8_wfe_body "$@" 2>&3; } 3>&2 2>>"$R8_EV/wait-timing.txt"
    rc=$?
    echo "  rc=$rc" >> "$R8_EV/wait-timing.txt"
    return "$rc"
  }
  trap 'r8rc=$?; cp -Rp "$TMP_ROOT" "$R8_EV/final-tmproot" 2>/dev/null; echo "exit=$r8rc" > "$R8_EV/exit.txt"; fm_test_cleanup' EXIT
  "$R8_CASE"
}
export FM_TEST_ONLY=r8_entry
. tests/fm-wake-queue.test.sh
