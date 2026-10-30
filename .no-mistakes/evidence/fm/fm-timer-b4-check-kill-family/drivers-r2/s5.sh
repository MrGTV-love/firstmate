#!/usr/bin/env bash
# Scenario 5: endless progress (CPU spin, stderr spam) stops at the absolute limit as unknown;
# the sweep continues. FM_DURATION_ABSOLUTE_SECS=10 stands in for the 6 h extreme.
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh" "$1"
for mode in spin spam; do
  mklab
  { printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$$" > "$FM_HOME/state/endless-pid"\n'
    if [ $mode = spin ]; then printf 'while :; do :; done\n'; else printf 'while :; do printf "retrying\\n" >&2; sleep 0.1; done\n'; fi
  } | addcheck a-$mode >/dev/null
  printf '#!/usr/bin/env bash\nprintf "after-ran\\n"\n' | addcheck b-after >/dev/null
  startwatch "$D/s5-$mode" FM_CHECK_INTERVAL=999999 FM_DURATION_ABSOLUTE_SECS=10 FM_CHECK_TIMEOUT=30
  s=$SECONDS; waitsweep 120; el=$((SECONDS-s)); stopwatch
  p=$(cat "$FM_HOME/state/endless-pid")
  echo "== $mode check (FM_CHECK_TIMEOUT=30, absolute 10 s): sweep ${el}s; endless pid $p alive: $(live $p && echo YES || echo no)"
  echo "-- wake queue:"; cut -f5 "$FM_HOME/state/.wake-queue" | sed "s#$FM_HOME#\$FM_HOME#g"
  echo "-- triage:"; sed "s#$FM_HOME#\$FM_HOME#g" "$FM_HOME/state/.watch-triage.log"
  live $p && kill -KILL $p
  droplab
done
