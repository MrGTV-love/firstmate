#!/usr/bin/env bash
# Live driver: the REAL bin/fm-idle-session-reap.sh sweep over a throwaway ship
# task, calling the REAL bin/fm-teardown.sh (its default path, no stand-in).
# The task's no-mistakes run-record database is held locked by a real SQLite
# writer, so teardown's read runs out of SQLite's real 30 s busy wait.
# Expected: teardown exits 75 (unknown), the sweep reports lock-skipped, writes
# no .refused memo, and the next sweep (lock released) offers the task again.
# Usage: live-reap.sh <worktree-root> <out-dir>
set -u
WT_ROOT=$1 OUT=$2
mkdir -p "$OUT"
# shellcheck disable=SC1091
. "$WT_ROOT/tests/fm-teardown-helpers.sh"
REAP="$WT_ROOT/bin/fm-idle-session-reap.sh"
NOW=$(date +%s) OLD=$(( $(date +%s) - 7200 ))

pr_head=$(pipeline_input_case live-reap rewritten-input)
c="$TMP_ROOT/live-reap"
write_nm_run_record "$c" 01RUNREAP "https://github.com/example/repo/pull/7" "$pr_head" "$pr_head"
# Make the ship reap-ready for the sweep: done, idle, merge marker, all aged.
printf '%s\n' "harness=claude" "backend=tmux" >> "$c/state/task-x1.meta"
printf 'done [at=%s]: shipped\n' "$OLD" > "$c/state/task-x1.status"
printf 'g1.1.1\n' > "$c/state/task-x1.busy-gen"
printf 'v1 gen=g1.1.1 seq=1 state=idle source=claude-hook event=Stop ts=%s\n' "$NOW" > "$c/state/task-x1.busy-state"
printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nexample/repo\n7\n' > "$c/state/task-x1.pr-poll-merge-notified"
chmod 0600 "$c/state/task-x1.pr-poll-merge-notified"
fm_touch_epoch "$OLD" "$c/state/task-x1.pr-poll-merge-notified" "$c/state/task-x1.status"
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$c/primary-home/.tasks.toml"

reap() {
  FM_HOME="$c/primary-home" FM_ROOT_OVERRIDE="$c/code-root" FM_STATE_OVERRIDE="$c/state" \
  FM_DATA_OVERRIDE="$c/data" FM_CONFIG_OVERRIDE="$c/config" NM_HOME="$c/nm" \
  FM_GUARD_EVENT_LOG="$c/guard-events.jsonl" PATH="$c/fakebin:$PATH" \
    "$REAP" "$@"
}

{
  echo "### scan (before any teardown)"
  reap scan 2>&1 | grep -F task-x1
} | tee "$OUT/transcript.txt"

python3 -I -c 'import sqlite3, sys, time
db = sqlite3.connect(sys.argv[1], isolation_level=None)
db.execute("BEGIN EXCLUSIVE")
open(sys.argv[2], "w").close()
time.sleep(90)' "$c/nm/state.sqlite" "$c/locked" &
holder=$!
while [ ! -e "$c/locked" ]; do sleep 0.2; done
t0=$SECONDS
{
  echo
  echo "### reap pass 1: run-record DB held locked by a real SQLite writer"
  reap reap 2>&1 | grep -F task-x1
  echo "wall=$((SECONDS - t0))s"
  echo "refusal memo state/.idle-reap/task-x1.refused: $([ -e "$c/state/.idle-reap/task-x1.refused" ] && echo PRESENT || echo absent)"
  echo "task record kept: $([ -e "$c/state/task-x1.meta" ] && echo yes || echo no)"
  echo "teardown-unlanded guard events: $(grep -c teardown-unlanded "$c/guard-events.jsonl" 2>/dev/null || echo 0)"
  echo "published report row: $(grep -F task-x1 "$c/state/idle-sessions.report" 2>/dev/null)"
} | tee -a "$OUT/transcript.txt"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
{
  echo
  echo "### reap pass 2: lock released, record answers 'not this copy'"
  reap reap 2>&1 | grep -F task-x1
  echo "refusal memo: $([ -e "$c/state/.idle-reap/task-x1.refused" ] && echo PRESENT || echo absent)"
  echo "teardown-unlanded guard events: $(grep -c teardown-unlanded "$c/guard-events.jsonl" 2>/dev/null || echo 0)"
} | tee -a "$OUT/transcript.txt"
