#!/usr/bin/env bash
# stress-run.sh <fix-root> <base-root> <outdir> : 8 task-owned `yes` CPU workers + both loops in parallel.
set -u
FIX=$1 BASE=$2 OUT=$3 D=$(dirname "$0"); mkdir -p "$OUT"
workers=; for n in 1 2 3 4 5 6 7 8; do yes > /dev/null & workers="$workers $!"; done
trap 'kill $workers 2>/dev/null' EXIT
echo "start $(date -u +%FT%TZ) host=$(uname -sm) ncpu=$(sysctl -n hw.ncpu) bash=$(bash --version|head -1) workers=8 load=$(uptime | sed 's/.*averages: //')" > "$OUT/meta.txt"
"$D/stress.sh" fix "$FIX" 40 "$OUT" & a=$!
"$D/stress.sh" base "$BASE" 20 "$OUT" & b=$!
wait $a $b
echo "end $(date -u +%FT%TZ) load=$(uptime | sed 's/.*averages: //')" >> "$OUT/meta.txt"
for l in fix base; do echo "$l: runs=$(wc -l < "$OUT/$l/results.txt") failures=$(grep -vc ' rc=0 ' "$OUT/$l/results.txt")"; done | tee -a "$OUT/meta.txt"
