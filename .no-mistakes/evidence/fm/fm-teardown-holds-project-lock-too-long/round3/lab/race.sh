#!/usr/bin/env bash
# race.sh <src-root> <label> <teardown-id> <spawn-id>
# Spawn <teardown-id> (setup), then tear it down while a fresh spawn of <spawn-id>
# starts as soon as the teardown's first project-lock hold ends. Records lock samples.
set -u
SRC=$1 L=$2 T=$3 S=$4
LAB=$(cat /tmp/claude-fm-lab-path); W=$LAB/work; OUT=$LAB/run-$L; mkdir -p $OUT
LOCK=$LAB/state/.treehouse-project-614ad475d610c136520ea23d6ae0e0ace09f8e1d.lock
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
F=$LAB/tools/fmenv.sh
cd "$SRC"
echo "setup-spawn $T start $(now)" >> $OUT/timeline
$F bin/fm-spawn.sh $T "$W/demo" --scout 'bash -c "sleep 3600" fm-worker __BRIEF__' > $OUT/spawn-$T.out 2>&1; echo "setup-spawn $T rc=$? end $(now)" >> $OUT/timeline
$F bin/fm-captain-hold.sh complete $T --none >/dev/null 2>&1
: > $OUT/lock.log; $LAB/tools/lockwatch.sh $LOCK $OUT/lock.log & WP=$!
echo "teardown $T start $(now)" >> $OUT/timeline
( $F bin/fm-teardown.sh $T > $OUT/teardown-$T.out 2>&1; echo "teardown $T rc=$? end $(now)" >> $OUT/timeline ) & TP=$!
# wait for first hold to start then end (or for teardown to finish)
seen=0
while kill -0 $TP 2>/dev/null; do
  if [ -d "$LOCK" ]; then sleep 1; break; fi
  sleep 0.05
done
echo "race-spawn $S start $(now) teardown_alive=$(kill -0 $TP 2>/dev/null && echo yes || echo no)" >> $OUT/timeline
$F bin/fm-spawn.sh $S "$W/demo" --scout 'bash -c "sleep 3600" fm-worker __BRIEF__' > $OUT/spawn-$S.out 2>&1; echo "race-spawn $S rc=$? end $(now) teardown_alive=$(kill -0 $TP 2>/dev/null && echo yes || echo no)" >> $OUT/timeline
wait $TP; sleep 0.3; kill $WP
cat $OUT/timeline; echo ---; cat $OUT/lock.log
