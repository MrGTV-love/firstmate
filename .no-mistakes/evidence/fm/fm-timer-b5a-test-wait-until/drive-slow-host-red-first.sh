#!/usr/bin/env bash
# M2 red-first: same publisher, quiet (0.1s/step) vs slowed 10x (1.0s/step), 8 CPU burners.
# main's helper uses a ceiling picked on a quiet machine (3s, quiet run ~1.2s).
set -u
W=$1; E=$2
. "$W/tests/lib.sh"
D=$(fm_test_tmproot drive-red) || exit 1
now() { python3 -c 'import time; print("%.1f" % time.time())'; }
el() { python3 -c "print('%.1f'%($(now)-$1))"; }
publisher() { python3 -c '
import pathlib, sys, time
j, r = map(pathlib.Path, sys.argv[1:3])
for s in range(12):
    time.sleep(float(sys.argv[3])); j.write_text(str(s))
r.write_text("published")' "$@" & }
burners=(); for _ in $(seq 1 8); do python3 -c 'while True: sum(range(10000))' & burners+=($!); done
echo "load: $(uptime)"
for step in 0.1 1.0; do
  echo "== publisher step ${step}s (12 steps)"
  publisher "$D/jm$step" "$D/rm$step" "$step"; p=$!
  ( eval "$(cat "$E/main-fm_test_wait_until.sh")"; t0=$(now); fm_test_wait_until 3 test -s "$D/rm$step"; rc=$?
    echo "  main   (fm_test_wait_until 3 ...): rc=$rc after $(el $t0)s result=$(cat "$D/rm$step" 2>/dev/null || echo ABSENT)" )
  wait $p
  publisher "$D/jb$step" "$D/rb$step" "$step"; p=$!
  t0=$(now); fm_test_wait_until --while-alive $p --progress-file "$D/jb$step" --inactivity 3 -- test -s "$D/rb$step"; rc=$?
  echo "  branch (--while-alive --progress-file --inactivity 3): rc=$rc after $(el $t0)s result=$(cat "$D/rb$step" 2>/dev/null || echo ABSENT)"
  wait $p
done
kill "${burners[@]}"; wait "${burners[@]}" 2>/dev/null
