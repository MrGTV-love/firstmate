#!/usr/bin/env bash
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5JEP7JBE1M3121EZV5RJ1V3
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux"; : > "$LAB/config/supervision-host-off"
echo "=== C: sanctioned writer bin/fm-status-append.sh, the incident loop routed through the helper (default 32 MiB cap shrunk to 8192 for the demo)"
S="$LAB/state/c1.status"
( ulimit -f 8192
  i=0; ok=0; refused=0
  while [ $i -lt 5000 ]; do i=$((i+1))
    FM_STATUS_CAP_BYTES=8192 FM_STATUS_CAP_RESERVE_BYTES=1024 "$WT/bin/fm-status-append.sh" "$S" "working [at=$(date +%s)]: text" 2>>"$LAB/c1.err"
    case $? in 0) ok=$((ok+1));; 75) refused=$((refused+1));; *) echo "other exit";; esac
  done
  echo "appended=$ok refused(exit 75)=$refused final size=$(stat -f %z "$S") (cap 8192)"
)
echo "first refusal message: $(head -1 "$LAB/c1.err")"
FM_STATUS_CAP_BYTES=8192 FM_STATUS_CAP_RESERVE_BYTES=1024 "$WT/bin/fm-status-append.sh" "$S" "done [at=$(date +%s)]: finished at the cap"; echo "done: line exit=$? ; last line: $(tail -1 "$S"); size=$(stat -f %z "$S")"
echo
echo "=== D: a 2 GiB sparse status log in the lab (3000 events, a hole, a repeated tail)"
H="$LAB/state/huge.status"
perl -e 'for $i (1..3000) { print "working [at=$i]: distinct event $i\n" }' > "$H"
dd if=/dev/zero of="$H" bs=1 count=0 seek=$((2147483648 - 1048576)) 2>/dev/null
perl -e 'print "working [at=1790000000]: text\n" x 36157' | head -c 1048576 >> "$H"
echo "size=$(stat -f %z "$H") bytes; real blocks=$(du -k "$H" | cut -f1) KiB"
printf 'window=firstmate:fm-huge\nworktree=%s\nproject=alpha\nharness=claude\nkind=ship\n' "$LAB" > "$LAB/state/huge.meta"
t0=$(perl -MTime::HiRes=time -e 'print time')
env -u NO_MISTAKES_GATE FM_HOME="$LAB" "$WT/bin/fm-wake-drain.sh" > "$LAB/d.out" 2> "$LAB/d.err"; rc=$?
t1=$(perl -MTime::HiRes=time -e 'print time')
printf 'wake drain exit=%s in %.2fs\n' "$rc" "$(echo "$t1 - $t0" | bc)"
echo "drain stderr naming the refused log:"; grep -i 'huge' "$LAB/d.err" | head -3
echo "files over 1 MB beside the logs: $(find "$LAB/state" -type f -size +1048576c ! -name '*.status' | wc -l | tr -d ' ')"
echo "--- watcher on the same home (no writer holds the log):"
t0=$SECONDS
out=$(timeout 120 env -u TMUX -u NO_MISTAKES_GATE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 \
    FM_HOME_SUMMARY_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_OPEN_LOOPS_INTERVAL=99999999 \
    "$WT/bin/fm-watch.sh" 2>"$LAB.w.err"); rc=$?
echo "watcher exit=$rc after $((SECONDS-t0))s (default 32 MiB cap); wake text: $out"
echo "log still 2 GiB and untouched: $(stat -f %z "$H")"
TMUX_TMPDIR="$LAB/tmux" tmux kill-server 2>/dev/null
rm -rf "$LAB" "$LAB.w.err"; echo "lab removed: $( [ -d "$LAB" ] || echo yes)"
