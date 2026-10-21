#!/usr/bin/env bash
# usage: stream.sh <worktree> <evdir> <summary-file> <fn...>
wt=$1; ev=$2; sum=$3; shift 3
cd "$wt" || exit 1
for fn in "$@"; do
  case "$fn" in
    SCRIPT:*) t=${fn#SCRIPT:}
      env -u FM_ROOT_OVERRIDE nice -n 20 timeout 600 bash bin/fm-test-run.sh "$t" > "$ev/$(basename "$t").log" 2>&1
      echo "$t exit=$?" >> "$sum" ;;
    OMP:*) f=${fn#OMP:}
      FM_TEST_ONLY=$f nice -n 20 timeout 600 bash bin/fm-test-run.sh tests/fm-omp-harness.test.sh > "$ev/omp-harness-$f.log" 2>&1
      echo "omp-harness $f exit=$?" >> "$sum" ;;
    *)
      FM_TEST_ONLY=$fn nice -n 20 timeout 600 bash bin/fm-test-run.sh tests/fm-control-relaunch.test.sh > "$ev/$fn.log" 2>&1
      echo "$fn exit=$?" >> "$sum" ;;
  esac
done
echo STREAM_DONE >> "$sum"
