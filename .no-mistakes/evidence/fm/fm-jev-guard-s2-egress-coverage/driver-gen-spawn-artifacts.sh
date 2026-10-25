#!/usr/bin/env bash
# Generate real fm-spawn worker artifacts (omp extension, Claude hook settings) in a disposable home.
set -u
ROOTDIR=$1; LAB=$2
. "$ROOTDIR/tests/fixtures.sh"
for h in omp claude; do
  d="$LAB/spawn-$h"
  fm_test_spawn_home "$d/home" "$h"
  fm_git_worktree "$d/project" "$d/wt" "wt-$h-t4" >/dev/null
  fm_test_spawn_brief "$d/home" "t4$h"
  fb=$(make_spawn_fakebin "$d/fake" "$h")
  FM_FAKE_OMP_VERSION=18.12.6 fm_test_run_spawn "$d/home" "$d/wt" "$fb" "t4$h" "$d/project" --mode no-mistakes --yolo off > "$d/spawn.out" 2>&1
  echo "$h spawn exit $?"
done
