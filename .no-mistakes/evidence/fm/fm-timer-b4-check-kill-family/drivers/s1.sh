#!/usr/bin/env bash
# Scenario 1: default FM_CHECK_TIMEOUT (30). Slow-but-progressing checks run past 30 s.
# usage: s1.sh <code-root> <label>
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh" "$1"; L=$2
mklab
addcheck a-slow-stderr <<'SH'
#!/usr/bin/env bash
for ((i=0;i<45;i++)); do printf 'step %s\n' "$i" >&2; sleep 1; done
printf 'slow-stderr-done after 45s\n'
SH
addcheck b-cpu-silent <<'SH'
#!/usr/bin/env bash
exec python3 -c 'import time
end = time.time() + 40
while time.time() < end: pass
print("cpu-silent-done after 40s")'
SH
addcheck c-hung <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/hung-pid"
exec sleep 600
SH
addcheck d-after <<'SH'
#!/usr/bin/env bash
printf 'after-ran\n'
SH
{
echo "== $L: watcher sweep, FM_CHECK_TIMEOUT unset (default 30), started $(ts)"
startwatch "$D/s1-$L" FM_CHECK_INTERVAL=999999
start=$SECONDS
waitsweep 400; echo "sweep finished: rc=$? after $((SECONDS-start))s"
stopwatch
echo "-- wake queue (check column 5):"; cut -f5 "$FM_HOME/state/.wake-queue" | sed "s#$FM_HOME#\$FM_HOME#g"
echo "-- triage log:"; sed "s#$FM_HOME#\$FM_HOME#g" "$FM_HOME/state/.watch-triage.log" 2>/dev/null
hp=$(cat "$FM_HOME/state/hung-pid" 2>/dev/null); if [ -n "$hp" ] && live "$hp"; then echo "hung check pid $hp STILL ALIVE"; kill -KILL "$hp"; else echo "hung check pid $hp gone"; fi
echo "-- stray processes from lab: $(pgrep -f "$FM_HOME" | wc -l | tr -d ' ')"
} 2>&1
droplab
