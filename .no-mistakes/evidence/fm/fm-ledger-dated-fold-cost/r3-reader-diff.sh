#!/bin/bash
# r3-reader-diff.sh <base-bin> <target-bin> <status-file> <out-dir>: time and compare both readers, old vs new.
base=$1 target=$2 file=$3 out=$4
export LC_ALL=en_US.UTF-8
for fn in status_open_decisions_dated status_open_decisions; do
  for side in target base; do
    eval "bindir=\$$side"
    start=$(python3 -c 'import time; print(time.time())')
    /bin/bash "$(dirname "$0")/call-reader.sh" "$bindir" "$fn" "$file" > "$out/$fn.$side.out" 2> "$out/$fn.$side.err"
    rc=$?
    end=$(python3 -c 'import time; print(time.time())')
    printf '%s %s exit=%s seconds=%s bytes=%s md5=%s load=%s\n' "$fn" "$side" "$rc" \
      "$(python3 -c "print(round($end-$start,1))")" "$(wc -c < "$out/$fn.$side.out" | tr -d ' ')" \
      "$(md5 -q "$out/$fn.$side.out")" "$(sysctl -n vm.loadavg)"
  done
  if cmp -s "$out/$fn.target.out" "$out/$fn.base.out"; then echo "$fn: IDENTICAL to base"; else echo "$fn: DIFFERS from base"; fi
done
