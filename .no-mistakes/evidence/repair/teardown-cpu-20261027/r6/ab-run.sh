#!/bin/bash
# Usage: ab-run.sh <label> <tree-dir> <evidence-dir>
# Runs the two phase-selected cleanup cases from <tree-dir> with the scratch Bash 5.2 first on PATH,
# in a fresh owned TMPDIR, then records exit, owned-root cleanup receipts and late-writer check.
set -u
label=$1 tree=$2 ev=$3
B5=/Users/charlesabrooker/.no-mistakes/worktrees/e2f2c2589455/01M60X7EHPFP3WC1T7VVP0W6VM/.nm-test-scratch/bash-build/inst/bin
out=$ev/$label; mkdir -p "$out"
run_tmp=$(mktemp -d /Users/charlesabrooker/tmp/nm-ab-r6-$label.XXXXXX)
run_tmp=$(cd -P "$run_tmp" && pwd -P)
{
  echo "label=$label tree=$tree run_tmp=$run_tmp"
  echo "date_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  PATH="$B5:$PATH" command -v bash
  PATH="$B5:$PATH" bash --version | head -1
  shasum -a 256 "$B5/bash"
  shasum -a 256 "$tree/bin/fm-teardown.sh" "$tree/bin/fm-backend.sh" "$tree/tests/fm-teardown-cleanup.test.sh" "$tree/tests/fm-teardown-helpers.sh" "$tree/tests/fm-teardown-cpu-probe.py" "$tree/bin/fm-duration.py" "$tree/tests/lib.sh" "$tree/bin/fm-home-summary-refresh.sh"
  sed -n '1697p;1701p' "$tree/bin/fm-teardown.sh"
  uname -a; python3 --version
} > "$out/inputs.txt" 2>&1
cd "$tree" || exit 99
start_ns=$(python3 -c 'import time;print(time.monotonic_ns())')
TMPDIR="$run_tmp" PATH="$B5:$PATH" bash tests/fm-teardown-cleanup.test.sh \
  test_local_only_force_overrides_unpushed test_docker_all_failure_channels_retain_forced_tasks_until_retry \
  > "$out/stdout.log" 2> "$out/stderr.log"
rc=$?
end_ns=$(python3 -c 'import time;print(time.monotonic_ns())')
{
  echo "suite_exit=$rc"
  echo "outer_wall_ms=$(( (end_ns - start_ns) / 1000000 ))"
  echo "date_end=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "--- receipt immediately after exit: find $run_tmp"
  find "$run_tmp" -maxdepth 3 | sort
} > "$out/receipt.txt" 2>&1
sleep 15
{
  echo "--- receipt after 15s settle: find $run_tmp"
  find "$run_tmp" -maxdepth 3 | sort
  if [ "$(find "$run_tmp" -mindepth 1 | wc -l | tr -d ' ')" = 0 ]; then
    rmdir "$run_tmp" && echo "owned_tmp_removed=empty_rmdir_ok"
  else
    echo "owned_tmp_residue=retained (cleanup failure; stop)"
  fi
} >> "$out/receipt.txt" 2>&1
echo "$rc"
