#!/usr/bin/env bash
set -u
W=$1
. "$W/tests/lib.sh"
D=$(fm_test_tmproot drive-cli) || exit 1
now() { python3 -c 'import time; print("%.1f" % time.time())'; }
echo "== progress-check CLI guards"
python3 "$W/bin/fm-duration.py" progress-check "$D/rec" 0 5; echo "pid 0 without files rc=$?"
python3 "$W/bin/fm-duration.py" progress-check "$D/rec" 0 5 --while-alive "$D/f"; echo "pid 0 with --while-alive rc=$?"
python3 -c 'import time; time.sleep(0.3)' & p=$!; wait $p
python3 "$W/bin/fm-duration.py" progress-check "$D/rec2" $p default --while-alive; echo "dead pid --while-alive first sample rc=$? (3 = dead peer)"
echo "== dead peer with a silent child: fail only after child is gone"
bash -c '( echo $BASHPID > "$1.child"; sleep 2 ) & sleep 0.5' _ "$D/silent" & p=$!
fm_test_wait_until --while-alive $p -- test -s "$D/silent.child"
t0=$(now); fm_test_wait_until --while-alive $p -- test -s "$D/silent.outcome"; rc=$?
c=$(cat "$D/silent.child")
echo "rc=$rc after $(python3 -c "print('%.1f'%($(now)-$t0))")s; child $c alive at verdict: $(kill -0 $c 2>/dev/null && echo yes || echo no)"
