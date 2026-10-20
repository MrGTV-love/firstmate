#!/usr/bin/env bash
# real-omp-observe.sh <lab> <status-file> <secs>
# Read-only observer: every 0.25 s print the status file size and who lsof says holds it open for writing.
LAB=$1; F=$2; SECS=$3
end=$((SECONDS + SECS))
last=-1
while [ "$SECONDS" -lt "$end" ]; do
  sz=$(stat -f %z "$F" 2>/dev/null || echo none)
  w=$(lsof -nP -F pcfa -- "$F" 2>/dev/null | awk '/^p/{p=substr($0,2)} /^c/{c=substr($0,2)} /^a[wu]/{print "pid=" p " lsof_cmd=" c}' | sort -u | tr '\n' ';')
  if [ "$sz" != "$last" ] || [ -n "$w" ]; then
    echo "t=$SECONDS size=$sz writers=[${w}]"
    last=$sz
  fi
  sleep 0.25
done
