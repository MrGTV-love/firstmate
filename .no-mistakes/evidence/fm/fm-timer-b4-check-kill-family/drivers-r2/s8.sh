#!/usr/bin/env bash
# Scenario 8: mail check armed in a lab and run by the real watcher. The mail plane
# (fm-mail.sh) is a stand-in: a poll that waits silently like an IMAP IDLE.
#   pass A: poll idles 20 s (past main's 15 s budget) then reports and queues mail 42.
#   pass B: poll hangs silently for 600 s -> watcher stops it; result must be unknown, not "no mail".
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh" "$1"; L=$2
for pass in A B; do
  mklab
  mb="$FM_HOME/mailbin"; mkdir -p "$mb"
  cp "$ROOT/bin/fm-mail-check.sh" "$mb/"
  for lib in "$ROOT"/bin/*-lib.sh "$ROOT"/bin/fm-check-register.sh "$ROOT"/bin/fm-check-unregister.sh "$ROOT"/bin/fm-duration.py; do ln -s "$lib" "$mb/"; done
  if [ $pass = A ]; then
    printf '%s\n' '#!/usr/bin/env bash' 'sleep 20' 'printf "%s\t1\tcheck\tmail:42\tcheck: mail 42\n" "$(date +%s)" >> "$FM_HOME/state/.wake-queue"' 'printf "fm-mail: woke for 42\n"' > "$mb/fm-mail.sh"
  else
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$$" > "$FM_HOME/state/poll-pid"' 'exec sleep 600' > "$mb/fm-mail.sh"
  fi
  chmod +x "$mb/fm-mail.sh"
  env -u FM_STATE_OVERRIDE FM_HOME="$FM_HOME" "$mb/fm-mail-check.sh" arm 2>&1 | sed "s#$FM_HOME#\$FM_HOME#g"
  echo "== $L pass $pass started $(ts) (default watcher settings)"
  startwatch "$D/s8-$L-$pass" FM_CHECK_INTERVAL=999999
  s=$SECONDS; waitsweep 300; el=$((SECONDS-s)); stopwatch
  echo "sweep took ${el}s"
  echo "-- wake queue:"; cut -f4,5 "$FM_HOME/state/.wake-queue" 2>/dev/null | sed "s#$FM_HOME#\$FM_HOME#g"
  echo "-- triage:"; sed "s#$FM_HOME#\$FM_HOME#g" "$FM_HOME/state/.watch-triage.log" 2>/dev/null
  if [ -s "$FM_HOME/state/poll-pid" ]; then p=$(cat "$FM_HOME/state/poll-pid"); echo "-- hung poll pid alive: $(live $p && echo YES || echo no)"; live $p && kill -KILL $p; fi
  echo "-- .mail-check record: $(cat "$FM_HOME/state/.mail-check" 2>/dev/null | head -2 | tr '\n' '|')"
  droplab
done
