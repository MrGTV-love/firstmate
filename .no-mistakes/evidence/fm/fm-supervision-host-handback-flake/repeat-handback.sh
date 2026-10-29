#!/usr/bin/env bash
# Run the named hand-back cases N times idle, then N times beside a CPU-burn
# neighbour (one busy loop per core), each run under bin/fm-proc-budget.sh.
# Usage: repeat-handback.sh <worktree> <runner> <N>
set -u
wt=$1 runner=$2 n=$3
cd "$wt" || exit 2
pass=0 failc=0
run_set() {  # <label>
  local i rc out
  for i in $(seq 1 "$n"); do
    out=$(bin/fm-proc-budget.sh --own-procs 256 -- bash "$runner" 2>&1); rc=$?
    if [ "$rc" = 0 ]; then pass=$((pass + 1)); else failc=$((failc + 1)); fi
    printf '%s run %02d exit=%s oks=%s notoks=%s\n' "$1" "$i" "$rc" \
      "$(printf '%s\n' "$out" | grep -c '^ok - ')" "$(printf '%s\n' "$out" | grep -c '^not ok')"
    [ "$rc" = 0 ] || printf '%s\n' "$out" | grep '^not ok' | sed 's/^/    /'
  done
}
printf 'bash on PATH: %s\n' "$(bash --version | head -1)"
run_set idle
cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc)
burners=()
for _ in $(seq 1 "$cores"); do
  sh -c 'while :; do :; done' &
  burners+=("$!")
done
printf 'started %s CPU burners\n' "$cores"
run_set burn
kill "${burners[@]}" 2>/dev/null
wait "${burners[@]}" 2>/dev/null
printf 'total pass=%s fail=%s\n' "$pass" "$failc"
