#!/usr/bin/env bash
# Scenario 9: the check launcher (bin/fm-check-run.py) is frozen with SIGSTOP.
#  shutdown: watcher gets TERM while a TERM-ignoring check runs -> watcher must exit, tree cleaned.
#  inactivity: a silent hung check must still be stopped and the sweep must reach the next check.
# usage: s9.sh <code-root> <label>
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh" "$1"; L=$2
now() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }
launcher_of() { local pp; pp=$(ps -o ppid= -p "$1" | tr -d ' '); case "$(ps -o command= -p "$pp")" in *fm-check-run.py*) echo "$pp";; esac; }
# --- shutdown mode
mklab
addcheck stubborn >/dev/null <<'SH'
#!/usr/bin/env bash
trap '' TERM
printf '%s\n' "$$" > "$FM_HOME/state/check-pid"
sleep 600 & printf '%s\n' "$!" > "$FM_HOME/state/child-pid"
while :; do printf 'working\n' >&2; sleep 0.2; done
SH
startwatch "$D/s9-$L-shutdown" FM_CHECK_INTERVAL=999999
for ((i=0;i<300;i++)); do [ -s "$FM_HOME/state/child-pid" ] && break; sleep 0.1; done
sleep 1
c=$(cat "$FM_HOME/state/check-pid"); k=$(cat "$FM_HOME/state/child-pid"); lp=$(launcher_of "$c")
echo "$L shutdown: check=$c child=$k launcher=${lp:-NONE} ($(ps -o command= -p "${lp:-1}" | cut -c1-60))"
kill -STOP "$lp"; echo "  launcher frozen: stat=$(ps -o stat= -p "$lp")"
t0=$(now); kill -TERM "$WPID"
for ((i=0;i<300;i++)); do live "$WPID" || break; sleep 0.1; done
t1=$(now)
if live "$WPID"; then echo "  HANG: watcher still alive $(echo "$t1 - $t0" | bc)s after TERM"; kill -KILL "$WPID"; else echo "  watcher exited $(echo "$t1 - $t0" | bc)s after TERM"; fi
wait "$WPID" 2>/dev/null
for ((i=0;i<100;i++)); do live $c || live $k || live $lp || break; sleep 0.1; done
left=""; for p in $c $k $lp; do live $p && left="$left $p"; done
if [ -n "$left" ]; then echo "  LEFT ALIVE:$left"; kill -CONT $lp 2>/dev/null; kill -KILL $left 2>/dev/null; else echo "  launcher, check and its child all gone $(echo "$(now) - $t0" | bc)s after TERM"; fi
[ -e "$FM_HOME/state/.watch.lock" ] && echo "  .watch.lock still present" || echo "  .watch.lock released"
echo "  stray processes naming the lab: $(pgrep -f "$FM_HOME" | wc -l | tr -d ' ')"
droplab
# --- inactivity mode
mklab
addcheck a-hung >/dev/null <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/hung-pid"
exec sleep 600
SH
printf '#!/usr/bin/env bash\nprintf "after-ran\\n"\n' | addcheck b-after >/dev/null
startwatch "$D/s9-$L-inactivity" FM_CHECK_INTERVAL=999999 FM_CHECK_TIMEOUT=2
for ((i=0;i<300;i++)); do [ -s "$FM_HOME/state/hung-pid" ] && break; sleep 0.1; done
h=$(cat "$FM_HOME/state/hung-pid"); lp=$(launcher_of "$h")
kill -STOP "$lp"; echo "$L inactivity: hung check=$h launcher=${lp:-NONE} frozen: stat=$(ps -o stat= -p "$lp")"
t0=$(now); waitsweep 60; r=$?; t1=$(now)
[ $r = 0 ] && echo "  sweep finished $(echo "$t1 - $t0" | bc)s after freeze" || echo "  HANG: sweep not finished 60 s after freeze"
stopwatch
echo "  -- wake queue:"; cut -f5 "$FM_HOME/state/.wake-queue" 2>/dev/null | sed "s#$FM_HOME#\$FM_HOME#g;s/^/    /"
echo "  -- triage:"; sed "s#$FM_HOME#\$FM_HOME#g;s/^/    /" "$FM_HOME/state/.watch-triage.log" 2>/dev/null
left=""; for p in $h $lp; do live $p && left="$left $p"; done
if [ -n "$left" ]; then echo "  LEFT ALIVE:$left"; kill -CONT $lp 2>/dev/null; kill -KILL $left 2>/dev/null; else echo "  hung check and frozen launcher both gone"; fi
echo "  stray processes naming the lab: $(pgrep -f "$FM_HOME" | wc -l | tr -d ' ')"
droplab
