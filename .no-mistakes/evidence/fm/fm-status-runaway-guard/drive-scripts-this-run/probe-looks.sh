#!/usr/bin/env bash
set -u
N=$1; ROOT=$2; LAB=$3; CAP=32768
for t in $(seq 1 "$N"); do
  D="$LAB/looks-$t"; mkdir -p "$D/state" "$D/bin"; ln -s "$(command -v bash)" "$D/bin/omp"
  F="$D/state/loop.status"; : > "$F"; : > "$D/looks.log"
  ( ulimit -f 2048
    "$D/bin/omp" -c 'i=0; while [ "$i" -lt 400000 ]; do i=$((i+1)); printf "text\n" "$(date +%s)" >> "$1"; done' _ "$F" &
    echo $! > "$D/pid"; wait $! 2>/dev/null ) &
  while [ ! -s "$D/pid" ]; do sleep 0.1; done; W=$(cat "$D/pid")
  w=0; while [ "$(stat -f %z "$F")" -le "$CAP" ] && [ "$w" -lt 3000 ]; do sleep 0.1; w=$((w+1)); done
  t0=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
  out=$(FM_LOOK_LOG="$D/looks.log" FM_STATE_OVERRIDE="$D/state" FM_STATUS_CAP_BYTES=$CAP FM_STATUS_CAP_LSOF="$LAB/drive/counting-lsof.sh" "$ROOT/bin/fm-status-cap-guard.sh" scan 2>&1)
  t1=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
  looks=$(wc -l < "$D/looks.log" | tr -d ' '); hits=$(grep -c hit "$D/looks.log")
  avg=$(awk -F'\t' '{d+=$2-$1} END {if (NR) printf "%.2f", d/NR}' "$D/looks.log")
  case "$out" in *"stopped pid $W"*) r=STOPPED;; *"none found"*) r=MISSED;; *) r=OTHER;; esac
  echo "trial=$t result=$r looks=$looks hits=$hits avg_look_secs=$avg scan_secs=$(perl -e "printf '%.1f', $t1-$t0") load=$(uptime | sed 's/.*averages: //')"
  kill -CONT "$W" 2>/dev/null; kill -9 "$W" 2>/dev/null; wait 2>/dev/null
done
echo LOOKS-DONE
