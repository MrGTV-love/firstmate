#!/usr/bin/env bash
# hit-rate.sh <lab> <kind> <looks>: how often one lsof look (the guard's own invocation) lists an omp-named raw-append loop
set -u
LAB=$1; KIND=$2; N=$3
D="$LAB/hit-$KIND"; mkdir -p "$D/bin"; ln -s "$(command -v bash)" "$D/bin/omp"; F="$D/loop.status"; : > "$F"
( ulimit -f 2048
  case "$KIND" in
    date) "$D/bin/omp" -c 'i=0; while [ "$i" -lt 400000 ]; do i=$((i+1)); printf "text\n" "$(date +%s)" >> "$1"; done' _ "$F" & ;;
    random) "$D/bin/omp" -c 'i=0; while [ "$i" -lt 3000000 ]; do i=$((i+1)); printf "text\n" "$RANDOM" >> "$1"; done' _ "$F" & ;;
  esac
  echo $! > "$D/pid"; wait $! 2>/dev/null ) &
while [ ! -s "$D/pid" ]; do sleep 0.1; done; W=$(cat "$D/pid")
hits=0; looks=0; start=$SECONDS
while [ "$looks" -lt "$N" ]; do
  out=$(/usr/sbin/lsof -nP -F pcfa -- "$F" 2>/dev/null)
  looks=$((looks+1)); case "$out" in *"p$W"*) hits=$((hits+1));; esac
done
echo "kind=$KIND looks=$looks hits=$hits secs=$((SECONDS-start)) size=$(stat -f %z "$F") load=$(uptime | sed 's/.*averages: //')"
kill -9 "$W" 2>/dev/null; wait 2>/dev/null
