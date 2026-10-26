#!/usr/bin/env bash
# Live driver: real bin/fm-duration.py (NEW = change, OLD = base 74175a5) on real macOS processes.
# Setuid-root /usr/bin/top is a real process whose libproc (native) CPU read fails for this user.
set -u
NEW=$1/bin/fm-duration.py; OLD=$2/bin/fm-duration.py; T=$(mktemp -d /tmp/fm-live.XXXX)
check() { # label script record pid
  local out code; out=$(python3 "$2" progress-check "$3" "$4" 1 2>&1); code=$?
  printf '  %-4s exit=%-3s record=%-3s %s\n' "$1" "$code" "$( [ -e "$3" ] && echo yes || echo no )" "$out"
}
series() { # title pid
  echo "== $1 (pid $2) =="
  for v in NEW OLD; do
    rec=$T/$v.$2.json; rm -f "$rec"; s=$NEW; [ $v = OLD ] && s=$OLD
    for i in 1 2 3 4; do check $v "$s" "$rec" "$2"; sleep 0.7; done
  done
}
echo "host: $(uname -srm); python: $(python3 -V 2>&1); load: $(sysctl -n vm.loadavg)"

# S1: root is setuid-root top (native root read fails), idle after first sample.
top -l 0 -s 3600 >/dev/null 2>&1 & ROOT=$!; sleep 2
ps -o pid,ppid,user,ruser,time,command -p $ROOT
series "S1 root-blind: unreadable native ROOT, idle tree" $ROOT
kill $ROOT; wait $ROOT 2>/dev/null

# S2: root is own bash (readable); only CHILD is setuid top that keeps sampling (non-root ps fallback, progress).
bash -c 'top -l 0 -s 1 >/dev/null 2>&1 & wait' & ROOT=$!; sleep 2
ps -o pid,ppid,user,time,command -p $ROOT; ps -o pid,ppid,user,time,command -g $ROOT 2>/dev/null | grep '[t]op'
series "S2 non-root ps fallback: busy unreadable CHILD" $ROOT
pkill -P $ROOT; wait $ROOT 2>/dev/null

# S3: root is own bash; only CHILD is setuid top, idle (non-root ps fallback, true idle still stops).
bash -c 'top -l 0 -s 3600 >/dev/null 2>&1 & wait' & ROOT=$!; sleep 2
series "S3 non-root ps fallback: idle unreadable CHILD" $ROOT
pkill -P $ROOT; wait $ROOT 2>/dev/null

# S4: own idle tree (all readable) still stops.
bash -c 'sleep 600 & wait' & ROOT=$!; sleep 1
series "S4 own idle tree" $ROOT
pkill -P $ROOT; wait $ROOT 2>/dev/null

# S5: own productive tree whose CPU lives only in reaped children.
bash -c 'while :; do python3 -c "import time
u=time.monotonic()+0.4
while time.monotonic()<u: sum(i*i for i in range(1000))"; sleep 0.2; done' & ROOT=$!; sleep 1
series "S5 own tree, work only in reaped children" $ROOT
pkill -P $ROOT; kill $ROOT; wait $ROOT 2>/dev/null

# S6: keep-going runner (operational surface) with an unreadable root, inactivity 2s.
for v in NEW OLD; do s=$NEW; [ $v = OLD ] && s=$OLD
  start=$(date +%s); python3 "$s" keep-going 2 -- top -l 0 -s 3600 >/dev/null 2>$T/kg.err & KG=$!
  sleep 8; if kill -0 $KG 2>/dev/null; then state="still running after 8s (not stopped)"; pkill -P $KG; kill $KG; wait $KG 2>/dev/null
  else wait $KG; state="exited code=$? after $(( $(date +%s)-start ))s"; fi
  echo "== S6 keep-going 2 -- setuid top (idle) [$v]: $state; stderr: $(tr '\n' ' ' < $T/kg.err)"
done

# S7: keep-going runner, own productive tree with reaped children (12s of work, inactivity 2s), and own idle.
for v in NEW; do
  start=$(date +%s); python3 "$NEW" keep-going 2 -- bash -c 'for i in $(seq 12); do python3 -c "import time
u=time.monotonic()+0.8
while time.monotonic()<u: pass"; done' >/dev/null 2>$T/kg.err; c=$?
  echo "== S7a keep-going 2 -- 12 reaped CPU children [$v]: exit=$c after $(( $(date +%s)-start ))s; stderr: $(tr '\n' ' ' < $T/kg.err)"
  start=$(date +%s); python3 "$NEW" keep-going 2 -- sleep 60 >/dev/null 2>$T/kg.err; c=$?
  echo "== S7b keep-going 2 -- sleep 60 [$v]: exit=$c after $(( $(date +%s)-start ))s; stderr: $(tr '\n' ' ' < $T/kg.err)"
done
rm -rf "$T"
