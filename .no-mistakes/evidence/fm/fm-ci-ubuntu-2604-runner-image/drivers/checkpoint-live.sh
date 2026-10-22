#!/usr/bin/env bash
# Live drive of the real bin/fm-watch-checkpoint.sh + real bin/fm-watch.sh in
# disposable lab homes. Usage: checkpoint-live.sh <repo-root>
set -u
ROOT=$1
export FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
FAILS=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; FAILS=$((FAILS+1)); }
lab() { local d; d=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); mkdir -p "$d/state" "$d/data" "$d/config" && : > "$d/data/backlog.md" || return 1; printf '%s\n' "$d"; }
now() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }
echo "host: $(uname -sr) $( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") ) timeout=$(command -v timeout || echo none) perl=$(command -v perl)"
echo "head: $(cat "$ROOT/.snapshot-head" 2>/dev/null || git -C "$ROOT" rev-parse HEAD)"

echo "== A. quiet checkpoint ends at its bound with exit 124 and frees the lock"
H=$(lab); t0=$(now); rc=0
FM_HOME="$H" "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 3 >"$H/a.out" 2>"$H/a.err" || rc=$?
t1=$(now); echo "exit=$rc elapsed=$(perl -e "printf '%.2f', $t1-$t0")s stdout=$(cat "$H/a.out")"
[ "$rc" = 124 ] && grep -q 'checkpoint: no actionable wake within 3s' "$H/a.out" && [ ! -e "$H/state/.watch.lock" ] \
  && ok "A quiet exit 124, lock released" || { bad "A"; cat "$H/a.err"; ls -la "$H/state"; }
rm -rf "$H"

echo "== B. async caller (bash 'cmd &' ignores INT) still interrupts and cleans up"
H=$(lab); rc=0
FM_HOME="$H" bash -c '"$1" --seconds 3 & echo "child SIGINT disposition: $(grep SigIgn /proc/$!/status 2>/dev/null || echo n/a)"; wait $!' _ "$ROOT/bin/fm-watch-checkpoint.sh" >"$H/b.out" 2>"$H/b.err" || rc=$?
echo "exit=$rc stdout=$(tr '\n' '|' < "$H/b.out")"
lk=$([ -e "$H/state/.watch.lock" ] && echo present || echo absent); echo "lock after first checkpoint: $lk"
rc2=0; FM_HOME="$H" "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 >"$H/b2.out" 2>"$H/b2.err" || rc2=$?
echo "next checkpoint exit=$rc2 stderr=$(cat "$H/b2.err")"
if [ "$rc" = 124 ] && [ "$lk" = absent ] && { [ "$rc2" = 124 ] || [ "$rc2" = 0 ]; } && ! grep -q 'already running outside' "$H/b2.err"; then ok "B ignored-INT caller: 124, lock released, next checkpoint runs"; else bad "B"; cat "$H/b.err"; fi
rm -rf "$H"

echo "== C. harness KILLs the checkpoint's process group: watcher still stops, next checkpoint runs"
H=$(lab)
FM_HOME="$H" perl -e 'setpgrp(0,0); exec @ARGV' "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 180 >"$H/c.out" 2>"$H/c.err" &
cp=$!; i=0
while [ ! -s "$H/state/.watch.lock/pid" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i+1)); done
wp=$(cat "$H/state/.watch.lock/pid" 2>/dev/null); echo "checkpoint pgid=$cp watcher pid=$wp"
ps -o pid,pgid,ppid,command -p "$wp" 2>/dev/null | sed 's/^/  /'
t0=$(now); kill -KILL -- "-$cp"; wait "$cp" 2>/dev/null
while kill -0 "$wp" 2>/dev/null && [ "$i" -lt 400 ]; do sleep 0.05; i=$((i+1)); done
t1=$(now); gone=$(kill -0 "$wp" 2>/dev/null && echo alive || echo gone)
echo "watcher after group KILL: $gone after $(perl -e "printf '%.2f', $t1-$t0")s; lock present: $([ -e "$H/state/.watch.lock" ] && echo yes || echo no)"
rc=0; FM_HOME="$H" "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 >"$H/c2.out" 2>"$H/c2.err" || rc=$?
echo "next checkpoint exit=$rc stdout=$(cat "$H/c2.out") stderr=$(cat "$H/c2.err")"
if [ "$gone" = gone ] && { [ "$rc" = 124 ] || [ "$rc" = 0 ]; } && ! grep -q 'already running outside' "$H/c2.err"; then ok "C group-KILL: watcher stopped, next checkpoint free"; else bad "C"; kill -KILL "$wp" 2>/dev/null; fi
rm -rf "$H"

echo "== D. checkout path containing a space"
H=$(lab); S=$(mktemp -d "${TMPDIR:-/tmp}/fm space.XXXXXX"); cp -R "$ROOT/bin" "$S/bin"
rc=0; FM_HOME="$H" "$S/bin/fm-watch-checkpoint.sh" --seconds 3 >"$H/d.out" 2>"$H/d.err" &
dp=$!; i=0; while [ ! -s "$H/state/.watch.lock/pid" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
wp=$(cat "$H/state/.watch.lock/pid" 2>/dev/null); echo "watcher pid under spaced path: ${wp:-none} cmd: $(ps -o command= -p "${wp:-1}" 2>/dev/null)"
wait "$dp" || rc=$?
echo "exit=$rc stdout=$(cat "$H/d.out") stderr=$(cat "$H/d.err")"
if [ -n "$wp" ] && [ "$rc" = 124 ] && [ ! -s "$H/d.err" ]; then ok "D watcher launched from '$S/bin'"; else bad "D"; fi
rm -rf "$H" "$S"
echo "FAILS=$FAILS"
[ "$FAILS" = 0 ]
