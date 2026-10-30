#!/usr/bin/env bash
# Live scenario driver for fm_test_wait_until (branch helper) vs main's capped helper.
# Usage: scenarios.sh <worktree> <evidence-dir>
set -u
WT=$1 E=$2
. "$WT/tests/lib.sh"
T=$(fm_test_tmproot fm-wait-scenarios)
now() { python3 -c 'import time; print("%.2f" % time.time())'; }
publisher() {  # <journal> <result> <dilation>: 24 steps of 0.1s*dilation, journals each step
  python3 -c '
import pathlib, sys, time
j, r, d = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3])
for s in range(24):
    time.sleep(0.1 * d); j.write_text(str(s))
r.write_text("published")' "$@" &
}
echo "== host: $(uptime)"
echo "== S1 slow-host healthy publisher. Quiet run takes ~2.4s; main's caller picks a 6s ceiling (2.5x margin)."
for d in 1 5; do
  publisher "$T/old-j$d" "$T/old-r$d" "$d"; p=$!; s=$(now)
  bash -c ". '$E/main-old-helper.sh'; fm_test_wait_until 6 test -s '$T/old-r$d'"; rc=$?
  echo "main helper   ${d}x slow: rc=$rc after $(python3 -c "print('%.1f' % ($(now)-$s))")s"; wait $p
  publisher "$T/new-j$d" "$T/new-r$d" "$d"; p=$!; s=$(now)
  fm_test_wait_until --while-alive "$p" --progress-file "$T/new-j$d" -- test -s "$T/new-r$d"; rc=$?
  echo "branch helper ${d}x slow: rc=$rc after $(python3 -c "print('%.1f' % ($(now)-$s))")s"; wait $p
done
echo "== S2 dead peer, outcome never written (default 900s inactivity in force)"
bash -c 'sleep 1; exit 0' & p=$!; s=$(now)
fm_test_wait_until --while-alive "$p" -- test -s "$T/never"; rc=$?
echo "dead peer: rc=$rc after $(python3 -c "print('%.1f' % ($(now)-$s))")s"
echo "== S3 live but silent peer (no observable change), --inactivity 2"
sleep 60 & p=$!; s=$(now)
fm_test_wait_until --while-alive "$p" --inactivity 2 -- test -s "$T/never"; rc=$?
alive=no; kill -0 $p 2>/dev/null && alive=yes
echo "silent peer: rc=$rc after $(python3 -c "print('%.1f' % ($(now)-$s))")s; peer still alive (not killed by helper)=$alive"; kill $p; wait $p 2>/dev/null
echo "== S4 live poller that never publishes, slowed 5x (0.5s per cycle), --cycles 4"
python3 -c '
import os, sys, time
c = 0
while True:
    time.sleep(0.5); c += 1
    open(sys.argv[1]+".t","w").write(str(c)); os.replace(sys.argv[1]+".t", sys.argv[1])' "$T/count" & p=$!; s=$(now)
fm_test_wait_until --while-alive "$p" --cycles 4 "$T/count" -- test -s "$T/never"; rc=$?
echo "idle poller: rc=$rc after $(python3 -c "print('%.1f' % ($(now)-$s))")s count=$(cat "$T/count")"; kill $p; wait $p 2>/dev/null
echo "== S5 adversarial: old capped API and missing observable are refused, not silently capped"
fm_test_wait_until 5 true; echo "old API 'fm_test_wait_until 5 true': rc=$?"
fm_test_wait_until -- true; echo "no observable '-- true': rc=$?"
echo "== S6 adversarial: peer dies while its forked child is still working; child publishes 1.5s later"
bash -c '( sleep 1.5; printf x > "$1" ) & printf %s $! > "$2"; sleep 1' _ "$T/late" "$T/latepid" & p=$!
fm_test_wait_until --while-alive "$p" -- test -s "$T/latepid"
s=$(now); fm_test_wait_until --while-alive "$p" -- test -s "$T/late"; rc=$?
echo "child-published after parent exit: rc=$rc after $(python3 -c "print('%.1f' % ($(now)-$s))")s"; wait $p
