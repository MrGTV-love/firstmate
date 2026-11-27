#!/bin/bash
# 1 s sampler of ShellCheck RSS for one lint run I started.
# Args: <lint-pid> <out-file>. Stops only that lint pid if pressure reaches 2.
lintpid=$1
out=$2
while kill -0 "$lintpid" 2>/dev/null; do
  ts=$(date +%s)
  lvl=$(sysctl -n kern.memorystatus_vm_pressure_level)
  ps -axo pid=,ppid=,rss=,comm= | awk -v ts="$ts" -v lvl="$lvl" '
    $4 ~ /shellcheck$/ { n++; s += $3; printf "%s\tproc\t%s\t%s\t%s\n", ts, $1, $2, $3 }
    END { printf "%s\ttotal\t%d\t%d\t%s\n", ts, n, s, lvl }' >> "$out"
  if [ "$lvl" -ge 2 ]; then
    echo "$ts pressure 2: stopping lint $lintpid" >> "$out"
    kill -TERM "$lintpid"
  fi
  sleep 1
done
