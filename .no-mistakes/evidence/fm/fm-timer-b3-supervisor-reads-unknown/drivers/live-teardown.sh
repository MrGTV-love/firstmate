#!/usr/bin/env bash
# Live driver: runs the REAL bin/fm-teardown.sh against throwaway task homes
# (a disposable git origin, project clone, task copy, state dir, and a real
# SQLite no-mistakes run record). Only the forge (gh-axi) and the no-mistakes
# daemon CLI are stand-ins; the database lock in scenario L1 is a REAL SQLite
# exclusive lock and the reader runs SQLite's own real 30 s busy wait.
#
# Usage: live-teardown.sh <worktree-root> <out-dir> [bin-root]
#   bin-root: alternate checkout whose bin/ is the teardown under test
#             (used to replay L1 against the commit before the fix).
set -u
WT_ROOT=$1 OUT=$2 BIN_ROOT=${3:-$1}
SCENARIOS=${SCENARIOS:-L1 L2 L3}
mkdir -p "$OUT"
# shellcheck disable=SC1091
. "$WT_ROOT/tests/fm-teardown-helpers.sh"
TEARDOWN="$BIN_ROOT/bin/fm-teardown.sh"

use_bin_root() {  # <case-dir>
  rm -f "$1/code-root/bin"
  ln -s "$BIN_ROOT/bin" "$1/code-root/bin"
}

show() {  # <label> <case-dir> <rc> <secs>
  local label=$1 case_dir=$2 rc=$3 secs=$4
  {
    echo "### $label"
    echo "\$ fm-teardown.sh task-x1 ${5:-}"
    echo "exit=$rc  wall=${secs}s"
    echo "--- stderr ---"
    cat "$case_dir/stderr"
    echo "--- guard events (teardown-unlanded?) ---"
    if [ -s "$case_dir/guard-events.jsonl" ]; then
      grep -o '"guard":"[^"]*"\|"decision":"[^"]*"' "$case_dir/guard-events.jsonl" | paste -sd' ' -
    else
      echo "(none)"
    fi
    echo "--- task copy kept: $([ -d "$case_dir/wt" ] && echo yes || echo no); task record kept: $([ -e "$case_dir/state/task-x1.meta" ] && echo yes || echo no)"
    if [ -e "$case_dir/data/task-x1/no-mistakes-unknown.log" ]; then
      echo "--- data/task-x1/no-mistakes-unknown.log ---"
      cat "$case_dir/data/task-x1/no-mistakes-unknown.log"
    fi
    echo
  } | tee -a "$OUT/transcript.txt"
}

run_case() {  # <label> <case-dir> [teardown args...]
  local label=$1 case_dir=$2 rc=0 t0=$SECONDS
  shift 2
  FM_GUARD_EVENT_LOG="$case_dir/guard-events.jsonl" \
    run_teardown "$case_dir" "$@" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  show "$label" "$case_dir" "$rc" "$((SECONDS - t0))" "$*"
}

# L1: a writer holds the run-record DB lock past SQLite's real 30 s busy wait.
if [[ " $SCENARIOS " == *" L1 "* ]]; then
  pr_head=$(pipeline_input_case live-locked rewritten-input)
  c="$TMP_ROOT/live-locked"; use_bin_root "$c"
  write_nm_run_record "$c" 01RUNLOCKED "https://github.com/example/repo/pull/7" "$pr_head" "$pr_head"
  python3 -I -c 'import sqlite3, sys, time
db = sqlite3.connect(sys.argv[1], isolation_level=None)
db.execute("BEGIN EXCLUSIVE")
open(sys.argv[2], "w").close()
time.sleep(90)' "$c/nm/state.sqlite" "$c/locked" &
  holder=$!
  while [ ! -e "$c/locked" ]; do sleep 0.2; done
  run_case "L1a run-record DB held locked by a writer (real 30 s SQLite busy wait, default 900 s stall)" "$c"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  run_case "L1b same task after the lock is released: the record answers 'not this copy'" "$c"
fi

# L2: the no-mistakes daemon goes silent on `axi status` for a parked run.
if [[ " $SCENARIOS " == *" L2 "* ]]; then
  c=$(make_case live-silent); use_bin_root "$c"
  write_meta "$c" no-mistakes ship
  land_shippable_commit "$c"
  head=$(git -C "$c/wt" rev-parse HEAD)
  export FM_FAKE_AXI_STATUS FM_FAKE_NM_ABORT_LOG="$c/nm-abort.log" FM_FAKE_NM_STATUS_HANG=1 \
    FM_TEARDOWN_NM_STALL_SECS=5 FM_FAKE_NM_HANG_LOG="$c/hang.log"
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")"
  run_case "L2a silent daemon, no --force (stall 5 s)" "$c"
  run_case "L2b silent daemon, captain's --force" "$c" --force --drop-file "$(fm_test_drop_file)"
  echo "silent status reads made by L2a+L2b: $(wc -l < "$c/hang.log" | tr -d ' '); abort log: $(cat "$c/nm-abort.log" 2>/dev/null || echo none)" | tee -a "$OUT/transcript.txt"
  unset FM_FAKE_AXI_STATUS FM_FAKE_NM_ABORT_LOG FM_FAKE_NM_STATUS_HANG FM_TEARDOWN_NM_STALL_SECS FM_FAKE_NM_HANG_LOG
fi

# L3: a slow but working daemon: status read burns CPU 20 s (2x the old 10 s cap,
# 4x the 5 s stall) before it answers with the parked run.
if [[ " $SCENARIOS " == *" L3 "* ]]; then
  c=$(make_case live-slow); use_bin_root "$c"
  write_meta "$c" no-mistakes ship
  land_shippable_commit "$c"
  head=$(git -C "$c/wt" rev-parse HEAD)
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$c/nm-abort.log" FM_FAKE_NM_STATUS_BURN_SECS=20 \
  FM_FAKE_NM_BURN_MARK="$c/burned" FM_TEARDOWN_NM_STALL_SECS=5 \
    run_case "L3 slow, CPU-busy daemon answers after 20 s (stall 5 s)" "$c"
  echo "abort log after L3: $(cat "$c/nm-abort.log" 2>/dev/null || echo none)" | tee -a "$OUT/transcript.txt"
fi
