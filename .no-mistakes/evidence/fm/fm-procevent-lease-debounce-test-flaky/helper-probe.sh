#!/usr/bin/env bash
# Drives the committed runner_pid helper (extracted verbatim from the test file) against a
# marker that a real writer truncates and rewrites, as bin/fm-procevent.sh does at startup.
set -u
wt=$1
src=$wt/tests/fm-procevent.test.sh
eval "$(sed -n '/^runner_pid() {/,/^}/p' "$src")"
d=$(mktemp -d "${TMPDIR:-/tmp}/rp-probe.XXXXXX"); trap 'rm -rf "$d"' EXIT
m=$d/x.runner; bad=0
# A: empty marker (torn state) must not yield an empty PID; late numeric write is returned.
: > "$m"; ( sleep 0.5; printf '4242\n' > "$m" ) &
out=$(runner_pid "$m" 50); rc=$?
echo "A empty-then-complete: rc=$rc out=<$out>"; [ "$rc" = 0 ] && [ "$out" = 4242 ] || bad=1
wait
# B: non-numeric content never succeeds, prints nothing.
printf 'garbage\n' > "$m"; out=$(runner_pid "$m" 5); rc=$?
echo "B non-numeric: rc=$rc out=<$out>"; [ "$rc" != 0 ] && [ -z "$out" ] || bad=1
# C: permanently empty marker fails with nothing printed (no vacuous pass).
: > "$m"; out=$(runner_pid "$m" 5); rc=$?
echo "C empty: rc=$rc out=<$out>"; [ "$rc" != 0 ] && [ -z "$out" ] || bad=1
# D: missing file fails.
rm -f "$m"; out=$(runner_pid "$m" 3); rc=$?
echo "D missing: rc=$rc out=<$out>"; [ "$rc" != 0 ] && [ -z "$out" ] || bad=1
# E: unterminated numeric (partial write) is not accepted.
printf '777' > "$m"; out=$(runner_pid "$m" 3); rc=$?
echo "E unterminated: rc=$rc out=<$out>"; [ "$rc" != 0 ] && [ -z "$out" ] || bad=1
# F: writer that truncates+rewrites in a tight loop; reader must never return empty/non-numeric.
printf '31337\n' > "$m"
( for _ in $(seq 1 60000); do : > "$m"; printf '31337\n' > "$m"; done ) &
w=$!; wrong=0; n=0
while kill -0 "$w" 2>/dev/null; do
  out=$(runner_pid "$m" 20) || { wrong=$((wrong + 1)); continue; }
  n=$((n + 1)); [ "$out" = 31337 ] || wrong=$((wrong + 1))
done; wait
echo "F tight truncate/rewrite: reads=$n bad_values=$wrong"; [ "$wrong" = 0 ] && [ "$n" -gt 0 ] || bad=1
# G: contrast, the old pattern (nonempty-wait then cat) against the same writer.
printf '31337\n' > "$m"
( for _ in $(seq 1 60000); do : > "$m"; printf '31337\n' > "$m"; done ) &
w=$!; oldbad=0; oldn=0
while kill -0 "$w" 2>/dev/null; do
  [ -s "$m" ] || continue
  v=$(cat "$m"); oldn=$((oldn + 1)); [ "$v" = 31337 ] || oldbad=$((oldbad + 1))
done; wait
echo "G old wait+cat pattern: reads=$oldn empty_or_wrong=$oldbad"
[ "$bad" = 0 ] && echo HELPER-PROBE-OK || echo HELPER-PROBE-FAIL
