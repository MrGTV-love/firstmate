#!/usr/bin/env bash
# Scenarios 3+4: watcher killed (SIGKILL) or stopped (TERM) while a TERM-ignoring
# check with a same-group child and a detached (new-session) child is running.
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh" "$1"; L=$2
for sig in KILL TERM; do
  mklab
  cat > "$FM_HOME/state/detached.sh" <<'SH'
#!/usr/bin/env bash
trap '' TERM
printf '%s\n' "$$" > "$FM_HOME/state/detached-pid"
exec sleep 600
SH
  chmod +x "$FM_HOME/state/detached.sh"
  addcheck stubborn >/dev/null <<'SH'
#!/usr/bin/env bash
trap '' TERM
printf '%s\n' "$$" > "$FM_HOME/state/check-pid"
sleep 600 & printf '%s\n' "$!" > "$FM_HOME/state/child-pid"
python3 -c 'import subprocess, sys, time; subprocess.Popen([sys.argv[1]], start_new_session=True); time.sleep(600)' "$FM_HOME/state/detached.sh" &
while :; do printf 'working\n' >&2; sleep 0.2; done
SH
  startwatch "$D/s3-$L-$sig" FM_CHECK_INTERVAL=999999
  for ((i=0;i<300;i++)); do [ -s "$FM_HOME/state/detached-pid" ] && [ -s "$FM_HOME/state/child-pid" ] && break; sleep 0.1; done
  sleep 2
  c=$(cat "$FM_HOME/state/check-pid"); k=$(cat "$FM_HOME/state/child-pid"); d=$(cat "$FM_HOME/state/detached-pid")
  echo "$L SIG$sig: check=$c child=$k detached=$d all live: $(live $c && live $k && live $d && echo yes || echo no)"
  t0=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
  kill -$sig "$WPID"
  for ((i=0;i<300;i++)); do live "$WPID" || break; sleep 0.1; done
  wait "$WPID" 2>/dev/null
  t1=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
  echo "  watcher exited after $(echo "$t1 - $t0" | bc)s (alive now: $(live $WPID && echo yes || echo no))"
  # Wait up to 15 s for independent cleanup (guardian) to finish.
  for ((i=0;i<150;i++)); do live $c || live $k || live $d || break; sleep 0.1; done
  t2=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
  left=""; for p in $c $k $d; do live $p && left="$left $p"; done
  if [ -n "$left" ]; then echo "  LEAK: still alive:$left"; kill -KILL $left; else echo "  check tree gone $(echo "$t2 - $t0" | bc)s after signal (check, child, detached child)"; fi
  if [ -e "$FM_HOME/state/.watch.lock" ]; then echo "  .watch.lock present: $(ls -la "$FM_HOME/state/.watch.lock" | awk '{print $1}')"; else echo "  .watch.lock released"; fi
  echo "  stray processes naming the lab: $(pgrep -f "$FM_HOME" | wc -l | tr -d ' ')"
  droplab
done
