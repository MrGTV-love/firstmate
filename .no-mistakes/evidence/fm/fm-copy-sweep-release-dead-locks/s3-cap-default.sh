#!/usr/bin/env bash
# S3: default per-run cap (5). Seven clean dead-launcher copies, each holding a
# 120 MB node_modules payload (regenerable, so freed net). Run 1 releases 5 and
# defers 2; run 2 releases the 2.
set -u
. "$(dirname "$0")/live-lab-lib.sh"
new_world s3
echo "LAB=$W"
for n in 1 2 3 4 5 6 7; do
  add_copy "c$n"; lock_dead "c$n"
  mkdir -p "$(cp_ "c$n")/node_modules/pkg"
  dd if=/dev/zero of="$(cp_ "c$n")/node_modules/pkg/blob" bs=1048576 count=120 2>/dev/null
done
printf 'node_modules/\n' >> "$SLOT/.git/info/exclude"
unset FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT
echo "=== run 1 (default cap)"
sweep --apply; echo "rc=$?"
echo "--- driver calls run 1: plans=$(grep -vc -- --execute-cleanup "$CTL/closeout.log") executes=$(grep -c -- --execute-cleanup "$CTL/closeout.log")"
for n in 1 2 3 4 5 6 7; do printf 'c%s registered=%s\n' "$n" "$(registered "c$n" && echo yes || echo no)"; done
echo "=== run 2"
sweep --apply; echo "rc=$?"
echo "--- driver calls total: plans=$(grep -vc -- --execute-cleanup "$CTL/closeout.log") executes=$(grep -c -- --execute-cleanup "$CTL/closeout.log")"
for n in 1 2 3 4 5 6 7; do printf 'c%s registered=%s\n' "$n" "$(registered "c$n" && echo yes || echo no)"; done
echo "--- copy-sweep.log lines: $(wc -l < "$HOMED/data/copy-sweep.log" | tr -d ' ')"
rm -rf "$W"; echo "lab removed"
