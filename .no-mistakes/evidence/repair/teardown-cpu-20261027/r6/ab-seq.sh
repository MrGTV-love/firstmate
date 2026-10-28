#!/bin/bash
# Sequential counterbalanced order p1-A, p1-B, p2-B, p2-A. Stops on first non-zero exit or retained residue.
set -u
EV=$1 T=$2
: > "$EV/ab-sequence.txt"
for spec in p1-A:A p1-B:B p2-B:B p2-A:A; do
  label=${spec%%:*} side=${spec##*:}
  rc=$("$EV/ab-run.sh" "$label" "$T/$side" "$EV")
  oks=$(grep -c '^ok ' "$EV/$label/stdout.log")
  rec=$(grep -E 'owned_tmp_(removed|residue)' "$EV/$label/receipt.txt")
  echo "$label rc=$rc $oks ok-lines; $rec" >> "$EV/ab-sequence.txt"
  if [ "$rc" != 0 ] || ! grep -q owned_tmp_removed "$EV/$label/receipt.txt"; then echo "STOP after $label" >> "$EV/ab-sequence.txt"; exit 1; fi
done
echo done >> "$EV/ab-sequence.txt"
