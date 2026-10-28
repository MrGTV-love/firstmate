#!/usr/bin/env bash
# Live drive of bin/fm-status-append.sh against a lab-home status log.
set -u
A="$PWD/bin/fm-status-append.sh"; ST="$FM_HOME/state"; F="$ST/d1-intake.status"
export FM_STATUS_CAP_BYTES=65536 FM_STATUS_CAP_RESERVE_BYTES=8192
sz(){ stat -f %z "$1"; }
: > "$F"
echo "== S1: incident-shape verbless 'text' loop through the helper (cap=65536, reserve=8192), hard stop at 100000 iterations"
i=0; rc=0
while [ $i -lt 100000 ]; do i=$((i+1)); "$A" "$F" "text $(date +%s)" 2>"$ST/s1.err"; rc=$?; [ $rc -eq 0 ] || break; done
echo "iterations=$i last_exit=$rc size=$(sz "$F") cap=65536"
echo "refusal stderr: $(cat "$ST/s1.err")"
echo "== S1b: working: and note: also stop at the cap"
"$A" "$F" "working [at=$(date +%s)]: still going"; echo "working exit=$?"
"$A" "$F" "note [at=$(date +%s)]: hi"; echo "note exit=$?"
echo "size=$(sz "$F")"
echo "== S2: a done: line still lands in the reserve"
"$A" "$F" "done [at=$(date +%s)]: finished after the loop"; echo "done exit=$?"; echo "size=$(sz "$F")"; echo "last line: $(tail -n1 "$F")"
echo "== S2b: blocked: still lands"
"$A" "$F" "blocked [at=$(date +%s)]: need a call"; echo "blocked exit=$?"; echo "last line: $(tail -n1 "$F")"
echo "== S3: a log already past cap+reserve refuses even done:"
G="$ST/huge.status"; : > "$G"; mkfile -n 80k "$G" 2>/dev/null || head -c 81920 /dev/zero > "$G"
b=$(sz "$G"); "$A" "$G" "done [at=$(date +%s)]: try"; echo "done exit=$? size_before=$b size_after=$(sz "$G")"
echo "== S3b: malformed call (newline in line) is exit 2 and writes nothing"
"$A" "$F" "$(printf 'a\nb')"; echo "exit=$?"
