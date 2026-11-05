#!/usr/bin/env bash
# A cache hit takes no budget: it returns at once while the budget is full.
. "$(dirname "$0")/lib.sh"
S=/tmp/nm-r2/s8; rm -rf "$S"; mkdir -p "$S/bin"; BIN=$S/bin; standin "$BIN" "$S/spans"
root "$S/hit.sh"; root "$S/hold.sh"; root "$S/miss.sh"
export FM_LINT_SLOT_DIR=$S/pool FM_LINT_ROOT_RSS_KIB=262144 MIB=4 CACHE=$S/cache FM_LINT_HOST_RSS_KIB=262144
HOLD=0.1 L --jobs 1 "$S/hit.sh" > "$S/1.out" 2>&1; echo "first run exit=$? stand-in starts=$(count "$S/spans.starts") (fills the cache)"
: > "$S/spans.starts"
HOLD=15 CACHE=off L --jobs 1 "$S/hold.sh" > "$S/h.out" 2>&1 & H=$!
wait_count "$S/spans.starts" 1 20 || echo "holder did not start"
t=$(perl -MTime::HiRes=time -e 'print time'); HOLD=0.1 L --jobs 1 "$S/hit.sh" > "$S/2.out" 2>&1; rc=$?
echo "cached run with the budget full: exit=$rc seconds=$(perl -MTime::HiRes=time -e "printf '%.2f', time-$t") stand-in starts=$(count "$S/spans.starts") (expect 1, only the holder)"
HOLD=0.1 L --jobs 1 "$S/miss.sh" > "$S/3.out" 2>&1 & M=$!
sleep 3; echo "control, cold root 3 s after it asked with the budget full: stand-in starts=$(count "$S/spans.starts") (expect 1, it waits)"
wait "$H"; wait "$M"; echo "cold root exit=$? starts=$(count "$S/spans.starts") (expect 2)"
