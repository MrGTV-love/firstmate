#!/usr/bin/env bash
# stall-monitor.sh <pool> <spans> <out>: read-only. When no root ends for 60 s, record one snapshot of the pool.
pool=$1 spans=$2 out=$3; last=-1; since=$SECONDS; n=0
while [ $n -lt 3 ] && [ $SECONDS -lt 1000 ]; do
  c=$(wc -l < "$spans" 2>/dev/null || echo 0)
  if [ "$c" != "$last" ]; then last=$c; since=$SECONDS; fi
  if [ $((SECONDS-since)) -ge 60 ]; then
    n=$((n+1)); since=$SECONDS
    { echo "== snapshot $n $(date -u +%T) roots_done=$c no_end_for=60s load=$(uptime | sed 's/.*averages: //')"
      ls "$pool" | grep -c '^queue\.0' ; ls "$pool" | grep '^queue\.0'
      for s in "$pool"/slot.[0-9]*; do printf '%s: ' "${s##*/}"; cat "$s"; [ -s "$s" ] || echo; done
      echo "-- holders of admission.lock (open, flock owner not shown)"; lsof "$pool/admission.lock" 2>/dev/null | awk 'NR>1{print $2}' | sort -u | tr '\n' ' '; echo
      echo "-- slot.0 openers"; lsof "$pool/slot.0" 2>/dev/null | awk 'NR>1{print $1,$2}' | sort -u
      echo "-- ps children of gates"; /bin/ps -axo pid=,ppid=,etime=,command= | grep -F "$pool" | grep -v grep | awk '{print $1,$2,$3}' | head -20
      /bin/ps -axo pid=,ppid=,etime=,command= | grep -E '[ /]ps -|bin/ps -o|bin/ps -ax' | grep -v grep | head -30 | cut -c1-90
    } >> "$out"
  fi
  sleep 2
done
