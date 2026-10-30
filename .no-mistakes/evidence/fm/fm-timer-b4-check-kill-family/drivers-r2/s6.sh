#!/usr/bin/env bash
# Scenario 6: a check that keeps hanging wakes firstmate once per episode.
# Between passes firstmate's real drain + ack (bin/fm-wake-drain.sh) consumes the wake.
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh" "$1"
mklab
drain_ack() {
  local err=$FM_HOME/drain.err seq gen
  env -u FM_STATE_OVERRIDE FM_HOME="$FM_HOME" "$ROOT/bin/fm-wake-drain.sh" > "$FM_HOME/drain.out" 2> "$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -z "$seq" ] || env -u FM_STATE_OVERRIDE FM_HOME="$FM_HOME" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}
printf '#!/usr/bin/env bash\n[ ! -e "$FM_HOME/state/hang" ] || exec sleep 600\nprintf "healthy-run\\n"\n' | addcheck flaky >/dev/null
for run in 1-hang 2-hang-again 3-hang-third 4-healthy 5-hang-new-episode; do
  case $run in *healthy) rm -f "$FM_HOME/state/hang";; *) : > "$FM_HOME/state/hang";; esac
  rm -f "$FM_HOME/state/.last-check"
  before=$(wc -l < "$FM_HOME/state/.watch-triage.log" 2>/dev/null || echo 0)
  succ=1; [ $run = 1-hang ] && succ=0
  startwatch "$D/s6-$run" FM_CHECK_INTERVAL=999999 FM_CHECK_TIMEOUT=2 FM_WATCH_HANDLING_SUCCESSOR=$succ
  waitsweep 120; stopwatch
  after=$(wc -l < "$FM_HOME/state/.watch-triage.log" 2>/dev/null || echo 0)
  n=$(grep -c 'result unknown, retry next pass' "$FM_HOME/state/.wake-queue" 2>/dev/null)
  echo "pass $run: sweep done=$([ -e "$FM_HOME/state/.last-check" ] && echo yes || echo no); stops logged this pass=$((after-before)); unknown wakes queued=$n"
  echo "   queue: $(cut -f5 "$FM_HOME/state/.wake-queue" 2>/dev/null | sed "s#$FM_HOME#\$FM_HOME#g" | tr '\n' '|')"
  drain_ack
done
echo "-- triage log (every stop is logged):"; sed "s#$FM_HOME#\$FM_HOME#g" "$FM_HOME/state/.watch-triage.log"
droplab
