#!/usr/bin/env bash
# After the ordering fix: run the helper's suite 3 times with $BURNERS CPU burners on top of host load.
set -u
WT=$1; pids=()
for _ in $(seq "${BURNERS:-54}"); do python3 -c 'while True: sum(range(10000))' & pids+=($!); done
trap 'kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null' EXIT
sleep 2; worst=0
for i in 1 2 3; do
  echo "== run $i host: $(uptime)"
  bash "$WT/tests/fm-test-wait-until.test.sh" > /tmp/fmwu.$$ 2>&1; rc=$?
  grep -c '^ok' /tmp/fmwu.$$ | sed 's/^/ok lines: /'; grep -v '^ok' /tmp/fmwu.$$; rm -f /tmp/fmwu.$$
  echo "run $i suite rc=$rc"; [ $rc -eq 0 ] || worst=$rc
done
exit $worst
