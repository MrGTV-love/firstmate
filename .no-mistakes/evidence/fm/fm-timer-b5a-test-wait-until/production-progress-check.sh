#!/usr/bin/env bash
# production-progress-check.sh <tmpdir>: drive fm_progress_check (production path, no --while-alive)
. bin/fm-timeout-lib.sh
T=$1
for pathset in default py39; do
  [ "$pathset" = py39 ] && PATH="$T/py39:$PATH"
  echo "== fm_progress_check via $(python3 --version)"
  sleep 60 & idle=$!
  python3 -c "while True: pass" & busy=$!
  for name in idle busy; do
    pid=${!name}; rec="$T/$name-$pathset.json"; out=""
    for _ in 1 2 3 4 5 6 7 8; do rc=0; fm_progress_check "$rec" "$pid" 3 2>>"$T/err" || rc=$?; out="$out $rc"; sleep 0.5; done
    echo "$name pid=$pid: rc sequence every 0.5s with 3s inactivity bound:$out"
  done
  kill $idle $busy; wait $idle $busy 2>/dev/null
done
echo "stderr: $(tr "\n" " " < "$T/err")"
