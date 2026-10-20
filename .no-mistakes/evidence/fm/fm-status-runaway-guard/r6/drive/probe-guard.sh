#!/usr/bin/env bash
# probe-guard.sh <trial-count> <loop-kind: date|random> <repo-root> <lab>
# Drives the real fm-status-cap-guard.sh against an omp-named raw-append loop of the incident's shape.
set -u
N=$1; KIND=$2; ROOT=$3; LAB=$4
CAP=32768
stopped=0; missed=0; other=0
for t in $(seq 1 "$N"); do
  D="$LAB/probe-$KIND-$t"; mkdir -p "$D/state" "$D/bin"; ln -s "$(command -v bash)" "$D/bin/omp"
  F="$D/state/loop.status"; : > "$F"
  (
    ulimit -f 2048
    if [ "$KIND" = date ]; then
      "$D/bin/omp" -c 'i=0; while [ "$i" -lt 400000 ]; do i=$((i+1)); printf "text\n" "$(date +%s)" >> "$1"; done' _ "$F" &
    else
      "$D/bin/omp" -c 'i=0; while [ "$i" -lt 3000000 ]; do i=$((i+1)); printf "text\n" "$RANDOM" >> "$1"; done' _ "$F" &
    fi
    echo $! > "$D/pid"; wait $! 2>/dev/null
  ) &
  while [ ! -s "$D/pid" ]; do sleep 0.1; done
  W=$(cat "$D/pid")
  w=0; while [ "$(stat -f %z "$F")" -le "$CAP" ] && [ "$w" -lt 3000 ]; do sleep 0.1; w=$((w+1)); done
  sz=$(stat -f %z "$F")
  out=$(FM_STATE_OVERRIDE="$D/state" FM_STATUS_CAP_BYTES=$CAP "$ROOT/bin/fm-status-cap-guard.sh" scan 2>&1)
  st=$(ps -p "$W" -o state= 2>/dev/null | tr -d ' ' | cut -c1)
  fin=$(stat -f %z "$F")
  case "$out" in *"stopped pid $W (omp) with SIGSTOP"*) r=STOPPED ;; *"none found"*) r=MISSED ;; *) r=OTHER ;; esac
  case $r in STOPPED) stopped=$((stopped+1));; MISSED) missed=$((missed+1));; *) other=$((other+1));; esac
  echo "trial=$t kind=$KIND size_at_scan_start=$sz result=$r ps_state=${st:-gone} final_size=$fin writer=$W"
  echo "   wake: ${out//$LAB/<lab>}" | cut -c1-420
  kill -CONT "$W" 2>/dev/null; kill -9 "$W" 2>/dev/null
  wait 2>/dev/null
done
echo "SUMMARY kind=$KIND trials=$N stopped=$stopped missed=$missed other=$other"
