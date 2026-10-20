#!/usr/bin/env bash
# adversarial-writers.sh <repo>
# Real fm-status-cap-guard.sh scan against writers it must handle correctly or must leave alone.
# Each writer holds a hard file-size limit (ulimit -f) and a hard iteration count.
#  A  omp-named bash, descriptor held open, no pause (the incident's shape)      -> stopped
#  B  notomp-named bash, descriptor held open                                      -> named, left running
#  C  omp-named bash, the literal `printf 'text\n' "$(date +%s)" >> file` loop that
#     reopens the log on every append (the fork-per-append shape)                  -> documented limit: named "none found"
#  D  a REAL idle `omp shell` bystander in another tmux pane that never touches the log -> must stay untouched
set -u
R=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$R/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
export TMUX_TMPDIR; TMUX_TMPDIR=$("$R/bin/fm-lab-home.sh" tmux-dir "$LAB")
TM() { tmux -L fm-lab "$@"; }
PIDS=""
cleanup() { for p in $PIDS; do kill -CONT "$p" 2>/dev/null; kill -9 "$p" 2>/dev/null; done; TM kill-server 2>/dev/null; "$R/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
mkdir -p "$LAB/bin"; ln -s "$(command -v bash)" "$LAB/bin/omp"; ln -s "$(command -v bash)" "$LAB/bin/notomp"
CAP=1000000
letter() { ps -p "$1" -o state= 2>/dev/null | tr -d ' ' | cut -c1; }
scan() { FM_STATE_OVERRIDE="$LAB/state" FM_STATUS_CAP_BYTES=$CAP "$R/bin/fm-status-cap-guard.sh" scan; }
# bystander: real omp shell idle in its own pane
TM new-session -d -s bystander -x 200 -y 50 -c "$LAB" "bash --norc --noprofile -i"
BP=$(TM display -p -t bystander '#{pane_pid}'); TM send-keys -t bystander "omp shell -C $LAB" Enter; sleep 4
BY=$(ps -axo pid=,ppid=,comm= | awk -v p="$BP" '$2==p && $3 ~ /omp$/ {print $1; exit}'); PIDS="$PIDS $BY"
echo "bystander real omp shell pid=$BY state=$(letter "$BY")"
held() { # <shell> <file> <pidfile>
  ( ulimit -f 40000; "$1" -c 'exec 9>>"$1"; i=0; while [ "$i" -lt 600000 ]; do i=$((i+1)); printf "text\n%.0s" 1 2 3 4 5 6 7 8 9 10 >&9; done' _ "$2" & echo $! > "$3"; wait $! 2>/dev/null ) &
}
waitsize() { local f=$1 w=0; while [ "$(stat -f %z "$f" 2>/dev/null || echo 0)" -le $CAP ] && [ "$w" -lt 300 ]; do sleep 0.1; w=$((w+1)); done; }
rm -f "$LAB/state/"*.status; mkdir -p "$LAB/state"
echo; echo "=== A: omp-named writer holding the log open ==="
held "$LAB/bin/omp" "$LAB/state/a.status" "$LAB/a.pid"; while [ ! -s "$LAB/a.pid" ]; do sleep 0.1; done; A=$(cat "$LAB/a.pid"); PIDS="$PIDS $A"
waitsize "$LAB/state/a.status"
scan | sed "s#$LAB#<lab>#g" | cut -f3- | cut -c1-420
echo "writer A state=$(letter "$A") (T = stopped); bystander state=$(letter "$BY") (S = untouched); a.status size=$(stat -f %z "$LAB/state/a.status") still present"
echo; echo "=== B: notomp-named writer holding the log open ==="
held "$LAB/bin/notomp" "$LAB/state/b.status" "$LAB/b.pid"; while [ ! -s "$LAB/b.pid" ]; do sleep 0.1; done; B=$(cat "$LAB/b.pid"); PIDS="$PIDS $B"
waitsize "$LAB/state/b.status"
scan | sed "s#$LAB#<lab>#g" | cut -f3- | cut -c1-420
echo "writer B state=$(letter "$B") (R/S/U/N flags = still running; not T); bystander state=$(letter "$BY")"
kill -9 "$B" 2>/dev/null
echo; echo "=== C: omp-named bash loop of the literal shape printf 'text\\n' \"\$(date +%s)\" >> file (reopens on every append) ==="
( ulimit -f 40000; "$LAB/bin/omp" -c 'i=0; while [ "$i" -lt 400000 ]; do i=$((i+1)); printf "text\n" "$(date +%s)" >> "$1"; done' _ "$LAB/state/c.status" & echo $! > "$LAB/c.pid"; wait $! 2>/dev/null ) &
while [ ! -s "$LAB/c.pid" ]; do sleep 0.1; done; C=$(cat "$LAB/c.pid"); PIDS="$PIDS $C"
# let it pass a small cap: use a 20000-byte cap for this shape only (it writes ~1 KB/s)
w=0; while [ "$(stat -f %z "$LAB/state/c.status" 2>/dev/null || echo 0)" -le 20000 ] && [ "$w" -lt 600 ]; do sleep 0.2; w=$((w+1)); done
echo "c.status size at scan start=$(stat -f %z "$LAB/state/c.status")"
FM_STATE_OVERRIDE="$LAB/state" FM_STATUS_CAP_BYTES=20000 "$R/bin/fm-status-cap-guard.sh" scan | grep 'file=c.status' | sed "s#$LAB#<lab>#g" | cut -f3- | cut -c1-420
echo "writer C state=$(letter "$C") (not T = not stopped: the documented limit for a writer that reopens the log on every append; the log wakes and is named, and the append rate of this shape is ~1 KB/s)"
kill -9 "$C" 2>/dev/null
echo; echo "=== after ==="
echo "omp-named lab writers stopped: A=$(letter "$A")  bystander real omp=$(letter "$BY")"
