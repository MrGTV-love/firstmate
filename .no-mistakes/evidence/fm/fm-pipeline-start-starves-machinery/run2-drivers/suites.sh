#!/bin/bash
W=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M8E1D7QY5TQFJE72NF01KKDN
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M8E1D7QY5TQFJE72NF01KKDN
cd $W
PY=$(python3 -c 'import sys;print(sys.executable)')
for t in admission gate attribution; do
  T=$(mktemp -d /private/tmp/fmcp-run2/suite/$t.XXXX)
  s=$(date +%s)
  if [ $t = attribution ]; then python3 tests/fm-cpu-pass-$t.py "$W" "$T" > $EV/run2-$t-suite.txt 2>&1; else python3 tests/fm-cpu-pass-$t.py "$W" "$T" "$PY" > $EV/run2-$t-suite.txt 2>&1; fi
  echo "exit=$? secs=$(($(date +%s)-s)) head=$(git rev-parse HEAD)" >> $EV/run2-$t-suite.txt
done
echo ALLDONE > /private/tmp/fmcp-run2/suites.done
