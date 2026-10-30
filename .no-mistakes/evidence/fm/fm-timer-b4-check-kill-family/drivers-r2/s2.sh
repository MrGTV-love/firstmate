#!/usr/bin/env bash
# Scenario 2: same check work at 1x and 5x slowdown (sleep shim), default watcher settings.
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh" "$1"; L=$2
for factor in 1 5; do
  mklab
  addcheck work >/dev/null <<'SH'
#!/usr/bin/env bash
# 9 units of work; FM_TEST_SLOW multiplies each unit's duration.
for ((i=0;i<9;i++)); do printf 'unit %s\n' "$i" >&2; sleep "$FM_TEST_SLOW"; done
printf 'work-done\n'
SH
  startwatch "$D/s2-$L-$factor" FM_CHECK_INTERVAL=999999 FM_TEST_SLOW=$factor
  start=$SECONDS; waitsweep 300; el=$((SECONDS-start)); stopwatch
  if grep -q 'work-done' "$FM_HOME/state/.wake-queue" 2>/dev/null; then r="SUCCEEDED (work-done reported)"; else r="FAILED (no work-done; check was killed)"; fi
  echo "$L ${factor}x: sweep ${el}s -> $r"
  droplab
done
