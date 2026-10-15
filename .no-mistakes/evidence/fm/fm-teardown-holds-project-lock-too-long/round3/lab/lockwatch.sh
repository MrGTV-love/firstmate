#!/usr/bin/env bash
# lockwatch.sh <lockdir> <outfile> : sample lock-dir presence every 50ms until killed
lock=$1 out=$2
prev=
while :; do
  if [ -d "$lock" ]; then cur="held $(cat "$lock"/pid "$lock"/owner 2>/dev/null | head -1)"; else cur=free; fi
  if [ "$cur" != "$prev" ]; then printf '%s %s\n' "$(perl -MTime::HiRes=time -e 'printf "%.3f", time')" "$cur" >> "$out"; prev=$cur; fi
  sleep 0.05
done
