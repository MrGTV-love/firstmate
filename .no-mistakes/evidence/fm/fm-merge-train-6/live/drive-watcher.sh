#!/usr/bin/env bash
# Live drive: real host facts, real fm-mem-guard.sh probe, real fm-watch.sh, disposable lab home.
# Usage: drive-watcher.sh <label> <bin-root>   (bin-root holds bin/ of the code under test)
set -u
label=$1; CODE=$2; WT=$(pwd)
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_ROOT_OVERRIDE FM_MEMORY_FIXTURE_DIR
eval "$("$WT/bin/fm-lab-home.sh" env 2>/dev/null)"
L=$FM_HOME; S=$L/state; echo "[$label] lab home: $L  code: $CODE"
trap '[ -n "${hog:-}" ] && kill "$hog" 2>/dev/null; rm -rf "${hd:-/nonexistent}"; "$WT/bin/fm-lab-home.sh" teardown "$L" && rm -rf "$L"; echo "[$label] lab removed"' EXIT
total=$(sysctl -n hw.memsize)
# Boundary 1 GiB: only processes that really exceed it on this host alarm.
jq -n --arg host "$(python3 -c 'import socket; print(socket.gethostname())')" --argjson t "$total" \
 '{schema:"fm-memory-baseline.v1",host:$host,total_bytes:$t,non_fleet_max_bytes:1073741824,smallest_reading_max_bytes:536870912,samples:2,derivation:"lab boundary for live evidence"}' > "$S/.memory-baseline.json"
printf '9999999999\n' > "$S/.memory-health-next"   # watcher must not probe; the driver does
FM_HOME=$L "$CODE/bin/fm-mem-guard.sh" probe > "$L/probe1.json" || echo "[$label] probe1 rc=$?"
echo "[$label] real probe: pressure=$(jq .pressure_level "$L/probe1.json") fixture=$(jq .fixture "$L/probe1.json") alarms=$(jq '.alarms|length' "$L/probe1.json")"
echo "[$label] queued memory rows after probe 1: $(awk -F'\t' '$4 ~ /^memory-health/' "$S/.wake-queue" 2>/dev/null | wc -l | tr -d ' ')"
start() { env FM_HOME="$L" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 FM_HOME_SUMMARY_INTERVAL=99999999 FM_OPEN_LOOPS_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_IDLE_REAP_INTERVAL=0 FM_TYPESAFE_HEALTH_INTERVAL=0 FM_WATCH_HANDLING_SUCCESSOR=1 "$CODE/bin/fm-watch.sh" >"$1" 2>"$1.err" </dev/null & wpid=$!; }
waitfor() { # <file> <pattern> <secs>
  local i=0; while [ $i -lt $(( $3 * 5 )) ]; do grep -q "$2" "$1" 2>/dev/null && return 0; kill -0 $wpid 2>/dev/null || { grep -q "$2" "$1" 2>/dev/null; return; }; sleep 0.2; i=$((i+1)); done; return 1; }
start "$L/w1.out"; waitfor "$L/w1.out" 'memory-health' 20 && echo "[$label] watcher 1 woke" || echo "[$label] watcher 1 NO WAKE"
kill $wpid 2>/dev/null; wait $wpid 2>/dev/null
echo "[$label] watcher 1 wake rows: $(tr ';' '\n' < "$L/w1.out" | grep -c 'non-fleet process\|uncalibrated')"; cut -c1-400 "$L/w1.out"
echo "[$label] marker lines after watcher 1: $(wc -l < "$S/.seen-memory-health" 2>/dev/null | tr -d ' ')"; echo "[$label] watcher 1 stderr: $(cat "$L/w1.out.err")"
# A real new process crosses the boundary: a new alarm row in a later probe.
# cwd outside every fleet path and reparented to launchd, so it is non-fleet like any host daemon. It ends itself in 75 s.
hd=$(mktemp -d /tmp/fmlabhog.XXXXXX); hb=$hd/fmlabhog; cp /usr/bin/perl "$hb"; ( cd "$hd" && nohup "$hb" -e 'open(F,">","pid");print F $$;close F;$x="a"x(1400*1024*1024); sleep 75' >/dev/null 2>&1 & ); sleep 1; hog=$(cat "$hd/pid")
for i in $(seq 1 40); do r=$(ps -o rss= -p $hog 2>/dev/null | tr -d ' '); [ "${r:-0}" -gt 1200000 ] && break; sleep 0.25; done; echo "[$label] hog pid=$hog rss_kib=$r"
FM_HOME=$L "$CODE/bin/fm-mem-guard.sh" probe > "$L/probe2.json" || echo "[$label] probe2 rc=$?"
echo "[$label] queued memory rows after probe 2: $(awk -F'\t' '$4 ~ /^memory-health/' "$S/.wake-queue" | wc -l | tr -d ' ')"
got=no; for n in 1 2 3 4; do : > "$L/w2.out"; start "$L/w2.out"; if waitfor "$L/w2.out" 'fmlabhog' 15; then got=yes; kill $wpid 2>/dev/null; wait $wpid 2>/dev/null; break; fi; kill $wpid 2>/dev/null; wait $wpid 2>/dev/null; cat "$L/w2.out.err" >> "$L/w2.errs"; echo "[$label] watcher pass $n wake without the row: $(cut -c1-120 "$L/w2.out")"; done
[ $got = yes ] && echo "[$label] RESULT: a later watcher pass presented the third row" || echo "[$label] RESULT: 4 watcher passes did NOT present the third row"
cat "$L/w2.out.err" >> "$L/w2.errs"
cut -c1-300 "$L/w2.out"; echo "[$label] watcher 2 stderr: $(sort "$L/w2.errs" | uniq -c | head -5)"
echo "[$label] old rows repeated in watcher 2: $(grep -v fmlabhog "$L/w2.out" | grep -c 'non-fleet process')  (rows in its wake mentioning other processes: $(tr ';' '\n' <"$L/w2.out" | grep 'non-fleet process' | grep -vc fmlabhog))"
