#!/usr/bin/env bash
# S1 report-only and S2 single dead-launcher release with preserve and GiB report.
set -u
. "$(dirname "$0")/live-lab-lib.sh"
new_world s12
echo "LAB=$W"
add_copy locked
lock_dead locked
printf 'unique.dat\n' >> "$SLOT/.git/info/exclude"
head -c 3000000 /dev/urandom > "$(cp_ locked)/unique.dat"
head -c 2000000 /dev/urandom > "$(cp_ locked)/scratch.bin"
printf 'scratch.bin\n' >> "$SLOT/.git/info/exclude"
admin=$(git -C "$(cp_ locked)" rev-parse --absolute-git-dir)
echo "--- lock bytes: $(cat "$admin/locked")"
echo "=== S1: report mode (no flag)"
sweep; echo "rc=$?"
echo "--- closeout.log after report: $( [ -f "$CTL/closeout.log" ] && cat "$CTL/closeout.log" || echo '(absent: driver never called)')"
echo "--- still registered: $(registered locked && echo yes || echo no)"
echo "--- data/copy-sweep after report: $(find "$HOMED/data" -mindepth 1 | sed "s|$HOMED/||" | tr '\n' ' ')"
echo "=== S2: --apply"
sweep --apply; echo "rc=$?"
echo "--- closeout.log:"; cat "$CTL/closeout.log"
echo "--- still on disk: $( [ -e "$(cp_ locked)" ] && echo yes || echo no ); registered: $(registered locked && echo yes || echo no)"
echo "--- branch kept in slot: $(git -C "$SLOT" rev-parse --short fm/locked) remote: $(git -C "$W/origin.git" rev-parse --short fm/locked)"
p=$(find "$HOMED/data/copy-sweep" -path '*nested-copy-preserved*' -name unique.dat -type f | head -1)
echo "--- preserved unique.dat: ${p#$HOMED/}"
echo "--- preserved bytes identical to original: $(cmp -s "$p" /dev/null; [ "$(wc -c < "$p" | tr -d ' ')" = 3000000 ] && echo 'size 3000000 ok')"
echo "--- SHA256SUMS:"; cat "$(dirname "$p")/SHA256SUMS"
echo "--- data/copy-sweep.log:"; cat "$HOMED/data/copy-sweep.log"
echo "--- retained receipts left: $(ls "$HOMED/data/copy-sweep/retained" 2>/dev/null | wc -l | tr -d ' ')"
echo "=== S2b: second --apply is idempotent"
sweep --apply; echo "rc=$?"
rm -rf "$W"; echo "lab removed"
