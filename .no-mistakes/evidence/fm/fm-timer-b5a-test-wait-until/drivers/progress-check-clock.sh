#!/usr/bin/env bash
# Production progress-check path (bin/fm-timeout-lib.sh fm_progress_check and the
# bare CLI on both interpreters): genuine silence still returns 124, CPU work
# never does, and a record from another clock domain starts a fresh window.
set -u
WT=$1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-pc-driver.XXXXXX")
. "$WT/bin/fm-timeout-lib.sh"

sample_loop() {  # <label> <pid> <seconds> <runner...>
  local label=$1 pid=$2 secs=$3 rec="$TMP/$1.json" rc i out=''
  shift 3
  rm -f "$rec"
  for i in $(seq 0 $((secs * 2 + 2))); do
    rc=0; "$@" "$rec" "$pid" "$secs" || rc=$?
    out="$out $rc"
    [ "$rc" = 124 ] && break
    sleep 0.5
  done
  echo "$label: samples(rc every 0.5s, inactivity=${secs}s):$out  record_clock=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("clock"))' "$rec")"
}

sleep 1000 & silent=$!
python3 -c 'while True: sum(range(10000))' & busy=$!

echo "== E. production wrapper fm_progress_check (python3 = $(python3 --version 2>&1)) =="
sample_loop prod-silent "$silent" 2 fm_progress_check
sample_loop prod-busy "$busy" 2 fm_progress_check

for py in "$(command -v python3)" /usr/bin/python3; do
  v=$($py --version 2>&1)
  echo "== F. bare CLI, each sample a new interpreter: $py ($v) =="
  sample_loop "cli-silent-$($py -c 'import sys;print(sys.version_info[1])')" "$silent" 2 "$py" "$WT/bin/fm-duration.py" progress-check
  sample_loop "cli-busy-$($py -c 'import sys;print(sys.version_info[1])')" "$busy" 2 "$py" "$WT/bin/fm-duration.py" progress-check
done

echo "== G. a record written under the old 'clock_monotonic' label starts a fresh window =="
rec="$TMP/old-clock.json"
python3 "$WT/bin/fm-duration.py" progress-check "$rec" "$silent" 2 >/dev/null; rc0=$?
python3 - "$rec" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
r['clock'] = 'clock_monotonic'
r['since'] = 0.0          # a quiet window that, if trusted, is far past 2s
json.dump(r, open(sys.argv[1], 'w'))
PY
rc=0; python3 "$WT/bin/fm-duration.py" progress-check "$rec" "$silent" 2 || rc=$?
echo "first sample rc=$rc0; with forged old-label record since=0: rc=$rc (expect 0, not 124)"
echo "rewritten record: $(cat "$rec")"
sleep 2.5
rc=0; python3 "$WT/bin/fm-duration.py" progress-check "$rec" "$silent" 2 || rc=$?
echo "after 2.5s more silence in the new clock domain: rc=$rc (expect 124)"

kill "$silent" "$busy"; wait 2>/dev/null
rm -rf "$TMP"
