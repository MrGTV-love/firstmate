#!/usr/bin/env bash
set -eu
W=$1; M=$2; F=/tmp/fm-r2fx-9566
mkdir -p "$M"; git -C "$W" archive HEAD | tar -x -C "$M"; S=$M/bin/fm-spawn.sh
start=$(grep -n 'fm_backlog_relaunch_admission "$CONFIG" "$DATA" "$KIND" "$ID" "$RECONCILE_ONLY" || {' "$S" | head -1 | cut -d: -f1); end=$((start+3))
target=$(grep -n 'policy_meta="$STATE/${POS\[0\]}.meta"' "$S" | head -1 | cut -d: -f1)
sed -n "${start},${end}p" "$S" > "$M.block"
awk -v s="$start" -v e="$end" -v t="$target" -v bf="$M.block" 'NR==t { while ((getline l < bf) > 0) print l } NR<s || NR>e { print }' "$S" > "$M.new"; cat "$M.new" > "$S"
echo "moved lines $start-$end above line $target:"; cat "$M.block"
grep -n 'relaunch refused: \$FM_BACKLOG_TRANSITION_ERROR' "$S"
