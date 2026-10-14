#!/usr/bin/env bash
# cachehit.sh <impl> <scen>: warm the cache, then hold the only host slot and
# rerun the same roots (expect finish), then a cold root (expect blocked until release).
set -u
impl=$1 scen=$2; mkdir -p "$scen"
ts() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
common=(env XDG_CACHE_HOME="$scen/xdg" FM_DURATION_FILE=off FM_LINT_CACHE_DIR="$scen/cache" FM_LINT_SLOT_DIR="$scen/slots" FM_LINT_HOST_SLOTS=1)
roots=(tests/fm-backend-herdr-eventwait-smoke.test.sh bin/fm-lease.sh bin/fm-dod-lib.sh)
s=$(ts); "${common[@]}" "$impl/bin/fm-lint.sh" "${roots[@]}" > "$scen/warm.out" 2>&1; rc=$?
printf 'warm rc=%s wall=%.1f\n' "$rc" "$(perl -e "print $(ts)-$s")"
perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die; open(my $r, ">", $ARGV[1]); close $r; sleep 1 until -e $ARGV[2]' \
  "$scen/slots/slot.0" "$scen/held" "$scen/release" &
hp=$!
until [ -e "$scen/held" ]; do sleep 0.05; done
echo "external holder owns the only host slot"
s=$(ts); timeout 60 "${common[@]}" "$impl/bin/fm-lint.sh" "${roots[@]}" > "$scen/hit.out" 2>&1; rc=$?
printf 'cached rerun with slot held: rc=%s wall=%.1f\n' "$rc" "$(perl -e "print $(ts)-$s")"
grep -i 'cache hit' "$scen/hit.out" | head -3
"${common[@]}" "$impl/bin/fm-lint.sh" tests/fm-supervision-host-hook.test.sh > "$scen/cold.out" 2>&1 &
cp=$!; s=$(ts); sleep 15
if kill -0 "$cp" 2>/dev/null; then echo "cold root still queued after 15 s with slot held (bound enforced)"; else echo "cold root FINISHED while slot held (bound violated)"; fi
touch "$scen/release"; wait "$hp"
wait "$cp"; rc=$?; printf 'cold root after release: rc=%s total wall=%.1f\n' "$rc" "$(perl -e "print $(ts)-$s")"
