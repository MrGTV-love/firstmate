#!/usr/bin/env bash
# fm-model-picker-daily.sh - the daily model-picker collection and its freshness check.
# bin/fm-model-picker-daily-install.sh schedules it; docs/configuration.md "Daily collection"
# owns the operator contract and this header owns the run order and the wake contract.
#
# Usage: fm-model-picker-daily.sh [run]    collect once
#        fm-model-picker-daily.sh check    check freshness only
#
# run:
#   1. Takes state/.model-picker-daily.lock. A run already under way ends this one (exit 75).
#   2. Settles a promotion an earlier runner left unfinished (bin/fm_model_picker/daily.py recover),
#      then copies the live data root to a sibling staging directory it owns. The collector rewrites
#      aa.sqlite, verdict.json and projection/ in place and sets the verdict to UNTRUSTED first,
#      so it never runs against the live root.
#   3. Runs `bin/fm-model-picker.sh --sweep --stale-after-hours 24 --chartdiff --db` against the
#      staged copy through bin/fm-proc-budget.sh, with FM_MODEL_PICKER_DATA pointing at it.
#      Its output is kept in state/.model-picker-daily.last.stdout and .last.stderr.
#   4. Exit 0: the staged outputs become the live ones (daily.py promote, whose docstring owns the order).
#      Any other exit, including a budget stop (98, 99, 125): nothing under the live root changes,
#      so the last good aa.sqlite, verdict.json and projection/ stay byte-identical. The staged
#      verdict.json and reconcile.md are kept as state/.model-picker-daily.last.verdict.json and
#      .last.reconcile.md, the newest observed_at in the staged aa.sqlite as .last.observed_at
#      (never written into the live aa.sqlite), and one `check:` wake names the exit code, the
#      first stderr line (the chart-diff line when stderr is empty, as for an UNTRUSTED verdict)
#      and that newest observed_at.
# The runner exits with the collector's status, 1 when promotion failed or an earlier one could not
# be settled, 75 when locked. A promotion has one commit point (the database commit), so its outcome
# is one of two whole generations: `completed` (exit 0, also when recovery had to finish it),
# `restored` (exit 1, the previous aa.sqlite, verdict.json and projection/ are back byte for byte),
# `cleanup-incomplete` (exit 0, one wake naming the leftover; the next run settles it before it stages
# or collects, and if that still fails raises one wake and collects nothing), or one of the two cases
# that need a disk fault to occur, each named in its wake: `restore-incomplete`
# (exit 1, the live verdict stays UNTRUSTED) and `completion-incomplete` (exit 0, the committed new
# snapshot's verdict stays UNTRUSTED, one wake, and the next run finishes it).
#
# check: reads the newest observed_at in aa.sqlite, read only, and takes no run lock, so it also
# works while a collection hangs. At 36 hours or less nothing is raised. Older raises one `check:`
# wake naming the age in hours; a missing, empty or unreadable snapshot raises one wake that says
# so. It is a separate verb because a check made only after a collection would see ages near 24,
# 48 and 72 hours and a hung collection would never reach it: bin/fm-model-picker-daily-install.sh
# schedules it on its own, hourly.
#
# Wakes use the existing queue owner, fm_wake_append in bin/fm-wake-lib.sh with kind `check`,
# the same call bin/fm-mem-guard.sh and bin/fm-merge-prune.sh make from outside a session.
# A key names its UTC day (run failures also name the exit), and state/.model-picker-daily.raised
# remembers the keys already raised, so a repeat in one day raises nothing and the next day's
# failure or staleness raises one more. A key is recorded only after its wake is queued.
#
# The data root is the collector's own (FM_MODEL_PICKER_DATA, else <data dir>/model-picker).
# A failed run leaves it as it was. A promotion that stops for any reason, a killed promote
# step included, is settled from its journal: before the commit the old generation returns, after
# it the new one is completed, and the live verdict returns only when every step worked. The wake
# names the outcome first, the whole first stderr line (the wake queue sets no length limit) and
# the verdict a reader actually sees, read back from the file, never an assumed one. A signal that
# ends the whole runner during a promotion leaves the verdict UNTRUSTED with no wake until the
# next daily run settles it at its start.
#
# Staging is a sibling <root>.daily.<pid> holding an owner record. A run removes only its own
# stage, and removes a stale one only when the record names a pid that is gone; it never touches
# a same-prefix directory it cannot prove it owns.
#
# Test seams, honored only when FM_TEST_SEAM=1: FM_MODEL_PICKER_DAILY_COLLECTOR replaces
# bin/fm-model-picker.sh, FM_MODEL_PICKER_DAILY_BUDGET replaces bin/fm-proc-budget.sh, and
# FM_MODEL_PICKER_DAILY_NOW replaces the clock (epoch seconds). The same gate enables
# FM_MODEL_PICKER_DAILY_FAULT, whose entries (failed renames, a kill or a hold at the database
# commit) bin/fm_model_picker/daily.py _faults documents.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_HOME
COLLECTOR="$SCRIPT_DIR/fm-model-picker.sh"
BUDGET="$SCRIPT_DIR/fm-proc-budget.sh"
NOW_OVERRIDE=
if [ "${FM_TEST_SEAM:-}" = 1 ]; then
  COLLECTOR=${FM_MODEL_PICKER_DAILY_COLLECTOR:-$COLLECTOR}
  BUDGET=${FM_MODEL_PICKER_DAILY_BUDGET:-$BUDGET}
  NOW_OVERRIDE=${FM_MODEL_PICKER_DAILY_NOW:-}
fi

usage() { sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
case "${1:-run}" in
  run|check) MODE=${1:-run} ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }

# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

command -v python3 >/dev/null 2>&1 || { printf 'error: Python 3 is required\n' >&2; exit 1; }
daily() { PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" PYTHONDONTWRITEBYTECODE=1 python3 -m fm_model_picker.daily "$@"; }

RUN_LOCK="$STATE/.model-picker-daily.lock"
RAISED="$STATE/.model-picker-daily.raised"
LAST_OUT="$STATE/.model-picker-daily.last.stdout"
LAST_ERR="$STATE/.model-picker-daily.last.stderr"

now_epoch() {
  if [ -n "$NOW_OVERRIDE" ]; then printf '%s\n' "$NOW_OVERRIDE"; else date +%s; fi
}

# raise_once <key> <payload>: queue one check wake unless this key was raised before.
raise_once() {
  local key=$1 payload=$2 status=0
  fm_lock_acquire_wait "$RAISED.lock" || return 1
  if grep -Fxq -- "$key" "$RAISED" 2>/dev/null; then
    fm_lock_release "$RAISED.lock"
    return 0
  fi
  if fm_wake_append check "$key" "$payload"; then
    printf '%s\n' "$key" >> "$RAISED" && { tail -n 60 "$RAISED" > "$RAISED.tmp" && mv -f "$RAISED.tmp" "$RAISED"; } || status=1
  else
    status=1
  fi
  fm_lock_release "$RAISED.lock"
  return "$status"
}

# one_line: keep every byte of one line except its newline and the control characters the one-row wake queue cannot carry; each of those becomes one space.
one_line() { LC_ALL=C tr -d '\n' | LC_ALL=C tr '\000-\037\177' ' '; }
outcome() { sed -n 's/^outcome=//p' | tail -n 1; }

# first_stderr_line: the literal first line of the failed run's stderr, trailing spaces included.
first_stderr_line() {
  local line
  if [ -s "$LAST_ERR" ]; then
    line=$(LC_ALL=C head -n 1 "$LAST_ERR" | one_line)
    printf '%s\n' "${line:-(the first stderr line is empty)}"
    return 0
  fi
  line=$(LC_ALL=C grep -m1 '^chart-diff:' "$LAST_OUT" 2>/dev/null | one_line)
  [ -z "$line" ] || line="no stderr line; stdout said: $line"
  printf '%s\n' "${line:-no stderr line}"
}

check_freshness() {  # <root> <now>
  local root=$1 now=$2 state='' hours='' observed='' day='' reason='' key line
  while IFS='=' read -r key line; do
    case "$key" in
      state) state=$line ;; hours) hours=$line ;; observed_at) observed=$line ;;
      day) day=$line ;; reason) reason=$line ;;
    esac
  done < <(daily freshness "$root" --now "$now")
  case "$state" in
    fresh) return 0 ;;
    stale)
      raise_once "model-picker-daily-stale:$day" \
        "check: model-picker-daily: the model-picker snapshot is $hours hours old (newest observed_at $observed), past the 36 hour limit, so the daily collector is not producing a trusted run; read $LAST_ERR, then run bin/fm-model-picker-daily-install.sh status" ;;
    missing)
      raise_once "model-picker-daily-stale:$day" \
        "check: model-picker-daily: the model-picker snapshot is missing: $reason; run bin/fm-model-picker-daily.sh and read $LAST_ERR" ;;
    *) printf 'error: the freshness check gave no state\n' >&2; return 1 ;;
  esac
}

NOW=$(now_epoch)
case "$NOW" in ''|*[!0-9]*) printf 'error: the clock gave no epoch\n' >&2; exit 1 ;; esac
ROOT=$(daily root) || { printf 'error: cannot resolve the model-picker data root\n' >&2; exit 1; }

if [ "$MODE" = check ]; then
  check_freshness "$ROOT" "$NOW"
  exit $?
fi

if ! fm_lock_try_acquire "$RUN_LOCK"; then
  printf 'another model-picker daily run holds %s\n' "$RUN_LOCK" >&2
  exit 75
fi
STAGE="$ROOT.daily.$$"
# shellcheck disable=SC2329  # Registered by the EXIT trap below.
cleanup() { daily discard "$STAGE" "$$"; fm_lock_release "$RUN_LOCK"; }
trap cleanup EXIT
trap 'exit 143' HUP INT TERM
daily reap "$ROOT" || true

DAY=$(daily freshness "$ROOT" --now "$NOW" | sed -n 's/^day=//p')
WORD=$(daily recover "$ROOT" 2> "$LAST_ERR" | outcome)
case "${WORD:-none}" in
  unchanged|completed|restored) ;;
  *)
    : > "$LAST_OUT"
    raise_once "model-picker-daily-run:$DAY:recover" \
      "check: model-picker-daily: an earlier promotion into $ROOT could not be settled (${WORD:-no result}), so this run collected nothing (the runner exits 1; the live verdict now reads $(daily verdict "$ROOT" 2>/dev/null || echo UNKNOWN)): $(first_stderr_line)"
    exit 1 ;;
esac
CODE=0
if ! daily stage "$ROOT" "$STAGE" "$$"; then
  printf 'error: could not stage %s\n' "$ROOT" > "$LAST_ERR"
  : > "$LAST_OUT"
  CODE=1
else
  FM_MODEL_PICKER_DATA="$STAGE" "$BUDGET" -- "$COLLECTOR" --sweep --stale-after-hours 24 --chartdiff --db \
    > "$LAST_OUT" 2> "$LAST_ERR" || CODE=$?
fi

STATUS=$CODE
if [ "$CODE" -eq 0 ]; then
  WORD=$(daily promote "$ROOT" "$STAGE" 2> "$LAST_ERR.promote" | outcome)
  if [ -z "$WORD" ]; then
    WORD=$(daily recover "$ROOT" 2> "$LAST_ERR.recover" | outcome)
    WORD=${WORD:-none}
    { printf 'the promote step ended without a result, so recovery settled it: %s\n' "$WORD"; cat "$LAST_ERR.promote" "$LAST_ERR.recover" 2>/dev/null; } > "$LAST_ERR"
  else
    cat "$LAST_ERR.promote" > "$LAST_ERR"
  fi
  rm -f "$LAST_ERR.promote" "$LAST_ERR.recover"
  case "$WORD" in
    completed) ;;
    cleanup-incomplete)
      raise_once "model-picker-daily-run:$DAY:cleanup" \
        "check: model-picker-daily: the collector run exited 0 and its snapshot is committed, published and trusted under $ROOT, but cleanup left files behind (the runner exits 0; the next run removes them before it collects): $(first_stderr_line)" || STATUS=1 ;;
    completion-incomplete)
      raise_once "model-picker-daily-run:$DAY:complete" \
        "check: model-picker-daily: the collector run exited 0 and its snapshot is committed under $ROOT, but its verdict could not be published (the runner exits 0; the live verdict now reads $(daily verdict "$ROOT" 2>/dev/null || echo UNKNOWN); the next run finishes it): $(first_stderr_line)" || STATUS=1 ;;
    *)
      STATUS=1
      raise_once "model-picker-daily-run:$DAY:promote" \
        "check: model-picker-daily: the collector run exited 0 but installing its output into $ROOT failed (outcome $WORD; the runner exits 1; the live verdict now reads $(daily verdict "$ROOT" 2>/dev/null || echo UNKNOWN)): $(first_stderr_line)" || STATUS=1 ;;
  esac
else
  NEWEST=$(daily freshness "$STAGE" --now "$NOW" | sed -n 's/^observed_at=//p')
  printf '%s\n' "${NEWEST:-unknown}" > "$STATE/.model-picker-daily.last.observed_at"
  for kept in verdict.json reconcile.md; do
    cp -f "$STAGE/$kept" "$STATE/.model-picker-daily.last.$kept" 2>/dev/null || rm -f "$STATE/.model-picker-daily.last.$kept"
  done
  raise_once "model-picker-daily-run:$DAY:exit$CODE" \
    "check: model-picker-daily: the daily collector run exited $CODE: $(first_stderr_line); the failed run's newest observed_at was ${NEWEST:-unknown}; the last good snapshot under $ROOT is unchanged; the failed run's output and verdict are in $STATE/.model-picker-daily.last.*" || STATUS=1
fi

exit "$STATUS"
