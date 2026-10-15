#!/usr/bin/env bash
# window.sh <label> <retiring-id> <fresh-id> [teardown-args...]
# Real reservation-window race: the retiring task's worker window is closed (its
# Treehouse process lease lapses), its teardown is paused (SIGSTOP) as soon as
# its first project-lock hold ends, a real fresh spawn then takes the slot, and
# the teardown is resumed (SIGCONT).
set -u
L=$1 A=$2 B=$3; shift 3
LAB=$(cat /tmp/claude-fm-lab-path); W=$LAB/work; OUT=$LAB/run-$L; mkdir -p $OUT
LOCK=$LAB/state/.treehouse-project-614ad475d610c136520ea23d6ae0e0ace09f8e1d.lock
POOL=$W/pool/.treehouse/demo-7386f6
F=$LAB/tools/fmenv.sh
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
snap() { echo "== $1"; jq -c '.worktrees[]|{name,leased,lease_holder,owner_pid}' $POOL/treehouse-state.json; for d in $POOL/*/; do echo "claim $(basename $d): $(tr '\n' ' ' < $d/.fm-slot-owner 2>/dev/null)"; git -C $d/demo log --oneline -1 2>/dev/null | sed 's/^/  head: /'; git -C $d/demo status --short 2>/dev/null | sed 's/^/  dirty: /'; done; ls -a $LAB/state | grep -E "^($A|$B)\." | sed 's/^/  state: /'; grep -E " ($A|$B) " $LAB/data/backlog.md | sed 's/^/  backlog: /'; }
snap before > $OUT/snap.log
TMUX_TMPDIR=$LAB/tmux tmux -L fm-lab kill-window -t "firstmate:fm-$A"; sleep 1
echo "killed worker window fm-$A at $(now)" >> $OUT/timeline
( $F bin/fm-teardown.sh $A "$@" > $OUT/teardown-$A.out 2>&1; echo "teardown $A rc=$? end $(now)" >> $OUT/timeline ) &
TP=$!
P=
while :; do
  if [ -d "$LOCK" ]; then P=$(cat $LOCK/pid 2>/dev/null); elif [ -n "$P" ]; then kill -STOP $P; echo "paused teardown pid $P after first hold at $(now)" >> $OUT/timeline; break; fi
  kill -0 $TP 2>/dev/null || { echo "teardown ended before pause" >> $OUT/timeline; break; }
  sleep 0.02
done
snap paused >> $OUT/snap.log
$F bin/fm-spawn.sh $B "$W/demo" --scout 'bash -c "sleep 3600" fm-worker __BRIEF__' > $OUT/spawn-$B.out 2>&1; echo "fresh spawn $B rc=$? end $(now)" >> $OUT/timeline
snap after-fresh-spawn >> $OUT/snap.log
[ -n "$P" ] && kill -CONT $P && echo "resumed teardown pid $P at $(now)" >> $OUT/timeline
wait $TP
snap final >> $OUT/snap.log
cat $OUT/timeline; echo; grep -v 'new version\|treehouse update' $OUT/teardown-$A.out; echo; tail -1 $OUT/spawn-$B.out; echo; cat $OUT/snap.log
