#!/usr/bin/env bash
# Live drive of the sanctioned writer (bin/fm-status-append.sh) inside a disposable
# lab FM_HOME minted by bin/fm-lab-home.sh. Run from the gate worktree.
# S1: an endless loop through the helper stops at the cap; done: uses the reserve;
#     past cap+reserve everything is refused; no distinct line before the cap is lost.
# S1b: incident shape (few thousand distinct lines then one line repeated) refused at cap.
# S3a: a stopped lock holder never hangs the helper: exit 75 within the 10 s bound.
# S3b: the guard scan spares a sanctioned append that holds the over-cap log open.
set -u
REPO=$PWD
eval "$("$REPO/bin/fm-lab-home.sh" env 2>/dev/null)"
LAB=$FM_HOME
trap '"$REPO/bin/fm-lab-home.sh" teardown "$LAB" && rm -rf "$LAB"; echo "lab removed: $LAB"' EXIT
APPEND="$REPO/bin/fm-status-append.sh"; GUARD="$REPO/bin/fm-status-cap-guard.sh"
sz() { stat -f %z "$1"; }
echo "lab FM_HOME=$LAB"
export FM_STATUS_CAP_BYTES=65536 FM_STATUS_CAP_RESERVE_BYTES=4096

echo "== S1 sanctioned loop =="
f="$LAB/state/loop.status"; : > "$f"
ok=0; rc=0
( ulimit -f 4096
  for i in $(seq 1 10000); do
    "$APPEND" "$f" "working: step $i of an endless loop" 2>>"$LAB/loop.err" || exit $?
  done; exit 0 ) ; rc=$?
echo "loop exit=$rc  size=$(sz "$f") cap=$FM_STATUS_CAP_BYTES  lines=$(wc -l < "$f" | tr -d ' ')"
echo "stderr of refusal: $(tail -1 "$LAB/loop.err")"
last=$(tail -1 "$f"); n=${last#working: step }; n=${n%% *}
echo "distinct lines kept = $(sort -u "$f" | wc -l | tr -d ' ') (last accepted step $n); every step 1..$n present: $( [ "$(grep -c '^working: step' "$f")" -eq "$n" ] && echo yes || echo NO)"
"$APPEND" "$f" "working: one more ordinary line"; echo "ordinary line at cap exit=$?"
"$APPEND" "$f" "done: finished despite the cap"; echo "done: at cap exit=$? (reserve)  size=$(sz "$f")"
i=0; while "$APPEND" "$f" "blocked: filling the reserve $i" 2>/dev/null; do i=$((i+1)); [ $i -lt 2000 ] || break; done
echo "blocked: lines accepted into reserve=$i then refused; size=$(sz "$f") limit=$((65536+4096))"
"$APPEND" "$f" "done: past the limit" 2>"$LAB/past.err"; echo "done: past cap+reserve exit=$? stderr: $(cat "$LAB/past.err")"

echo "== S1b 2026-10-18 shape (cap 16384) =="; export FM_STATUS_CAP_BYTES=16384
g="$LAB/state/d1-intake.status"; : > "$g"
for i in $(seq 1 300); do printf 'working [at=%s]: distinct event %s\n' "$i" "$i"; done > "$LAB/distinct.txt"

while IFS= read -r l; do "$APPEND" "$g" "$l" || echo "LOST distinct line: $l"; done < "$LAB/distinct.txt"
rc=0; c=0
( ulimit -f 4096; while :; do "$APPEND" "$g" "text" 2>>"$LAB/rep.err" || exit $?; done ) ; rc=$?
echo "repeat loop exit=$rc size=$(sz "$g") (cap 16384) repeats written=$(grep -cx text "$g")"
echo "distinct lines present: $(grep -c '^working \[at=' "$g")/300; refusal: $(tail -1 "$LAB/rep.err")"

echo "== S3a stopped lock holder =="
h="$LAB/state/held.status"; printf 'working: before\n' > "$h"; before=$(sz "$h")
perl -MFcntl=:flock -e 'open(my $f,"<",$ARGV[0]) or exit 1; flock($f,LOCK_EX) or exit 1; open(my $r,">",$ARGV[1]); print $r "x\n"; close $r; sleep 120;' "$h" "$LAB/ready" &
holder=$!; while [ ! -s "$LAB/ready" ]; do sleep 0.1; done
kill -STOP $holder
t0=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
"$APPEND" "$h" "done: finished" 2>"$LAB/held.err"; rc=$?
t1=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
echo "append behind SIGSTOPped holder: exit=$rc after $(echo "$t1 - $t0" | bc) s; stderr: $(cat "$LAB/held.err"); size unchanged: $( [ "$(sz "$h")" -eq "$before" ] && echo yes || echo NO)"
kill -9 $holder; wait $holder 2>/dev/null
"$APPEND" "$h" "done: finished"; echo "after holder gone exit=$? last=$(tail -1 "$h")"

echo "== S3b guard spares the sanctioned append =="
b="$LAB/state/busy.status"; head -c 300000 /dev/zero | tr '\0' x > "$b"; printf '\n' >> "$b"
export FM_STATUS_CAP_BYTES=262144; unset FM_STATUS_CAP_RESERVE_BYTES  # default reserve 1 MiB
rm -f "$LAB/ready2"
perl -MFcntl=:flock -e 'open(my $f,"<",$ARGV[0]) or exit 1; flock($f,LOCK_EX) or exit 1; open(my $r,">",$ARGV[1]); print $r "x\n"; close $r; sleep 120;' "$b" "$LAB/ready2" &
holder=$!; while [ ! -s "$LAB/ready2" ]; do sleep 0.1; done
"$APPEND" "$b" "done: landed after the scan" 2>"$LAB/busy.err" & apid=$!
pp=; for i in $(seq 1 100); do pp=$(pgrep -P $apid perl | head -1); [ -z "$pp" ] || break; sleep 0.05; done
sleep 0.3
out=$("$GUARD" scan); echo "guard scan record: $out"
echo "capped append perl pid $pp state=$(ps -p "$pp" -o state= | tr -d ' ') (T would mean stopped)"
kill -9 $holder; wait $holder 2>/dev/null; wait $apid; echo "held append exit=$? last=$(tail -1 "$b" | cut -c1-60)"
"$APPEND" "$b" "done: a later line"; echo "later append exit=$? last=$(tail -1 "$b" | cut -c1-60)"
