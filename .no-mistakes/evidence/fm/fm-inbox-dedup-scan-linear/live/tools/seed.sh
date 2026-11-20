#!/bin/bash
# seed.sh <inbox-dir> <count> [prefix]: writes <count> handled records in the real record format
set -u
d=$1; n=$2; p=${3:-acknowledged steer}
mkdir -p "$d/handled"
i=0
while [ "$i" -lt "$n" ]; do
  i=$((i+1))
  printf -v f '%s/handled/%04d.msg' "$d" "$i"
  printf 'schema=fm-task-inbox.v1\nat=2026-11-18T00:00:00Z\n--\n%s %s\nsecond line\n' "$p" "$i" > "$f"
done
