#!/usr/bin/env bash
# Live driver: real fm-mem-guard.sh in the lab ROOT home with native-fact
# fixtures (FM_MEMORY_FIXTURE_DIR) for states the host cannot safely produce.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M5ZXMAD5W9SM4DC85WJ38ZQ5
PB=/Users/charlesabrooker/fleet/fm-mini-home/bin/fm-proc-budget.sh
LAB=$1; export FM_HOME=$LAB
unset NO_MISTAKES_GATE FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
N=$LAB/alarm-native; rm -rf "$N"; mkdir -p "$N"; export FM_MEMORY_FIXTURE_DIR=$N
GIB=1073741824
facts() {  # <pressure> <available-bytes> <processes-json>
  printf '34359738368\n%s\ntotal = 3072.00M used = 1565.88M free = 1506.12M\n' "$1" > "$N/sysctl"
  printf 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 1000.\nPages speculative: 100.\nAnonymous pages: 1048576.\nFile-backed pages: %s.\nPages purgeable: 100.\nPages occupied by compressor: 32768.\n' "$(( $2 / 16384 - 1100 ))" > "$N/vm_stat"
  printf '%s\n' "$3" > "$N/processes.json"
}
procs() {  # <xprotectd-rss> [fleet-node-rss] [fleet-child-rss]
  printf '[{"pid":101,"ppid":1,"comm":"xprotectd","started":"s101","rss_bytes":%s,"fleet":false,"run":null},{"pid":201,"ppid":1,"comm":"node","started":"s201","rss_bytes":%s,"fleet":true,"run":"task:lab"},{"pid":202,"ppid":201,"comm":"python3","started":"s202","rss_bytes":%s,"fleet":false,"run":null}]' "$1" "${2:-$((2*GIB))}" "${3:-$((GIB/4))}"
}
G() { "$PB" --memory-kib 4194304 -- "$WT/bin/fm-mem-guard.sh" "$@"; }
step() { local rc=0 out; out=$(G "$@") || rc=$?; printf 'exit=%s ' "$rc"; jq -c "$JQ" <<<"$out"; }
Q=$LAB/state/.wake-queue
memrows() { local n; n=$(grep -c $'\tcheck\tmemory-health\t' "$Q" 2>/dev/null) || true; echo "${n:-0}"; }
JQ='{source,pressure_level,admission,reasons,non_fleet_max_bytes,alarms:[.alarms[]|{comm,pid,rss_bytes,boundary_bytes}],alarm_hold}'

echo "=== A1 (R5-1 adversarial): probe rows give the envelope; confined admit/sample rows with lower maxima must not widen it"
facts 1 $((8*GIB)) "$(procs $GIB)";       echo -n "probe xprotectd=1GiB      "; step probe
facts 1 $((8*GIB)) "$(procs $((GIB/2)))"; echo -n "probe xprotectd=0.5GiB    "; step probe
facts 1 $((8*GIB)) "$(procs $((GIB/8)))"; echo -n "admit xprotectd=0.125GiB  "; step admit
facts 1 $((8*GIB)) "$(procs $((GIB/16)))";echo -n "sample xprotectd=0.0625GiB "; step sample
facts 1 $((8*GIB)) "$(procs $GIB)"
echo "\$ fm-mem-guard.sh baseline"; rc=0; out=$(G baseline) || rc=$?; echo "exit=$rc"; jq '.baseline|{non_fleet_max_bytes,smallest_reading_max_bytes,samples,non_fleet_max_share,incomplete_samples,derivation}' <<<"$out"
echo "(real-host probe rows in this lab log have fixture=null and must also be excluded; expect samples=2, smallest=536870912 not 134217728/67108864)"

echo; echo "=== A2: below/at boundary and fleet-owned giants never alarm"
before=$(memrows)
facts 1 $((8*GIB)) "$(procs $GIB $((20*GIB)) $((12*GIB)))"; echo -n "probe xprotectd=1GiB(=boundary), fleet node 20GiB, fleet child 12GiB  "; step probe
echo "memory-health alarm rows added: $(( $(memrows) - before ))"

echo; echo "=== A3: one non-fleet outlier above the boundary raises one identifying alarm wake"
facts 1 $((8*GIB)) "$(procs $((11*GIB)))"; echo -n "probe xprotectd=11GiB  "; step probe
echo "memory-health alarm rows added: $(( $(memrows) - before ))"
grep $'\tcheck\tmemory-health\t' "$Q" | tail -1 | cut -f5
echo -n "repeat probe xprotectd=11GiB  "; step probe
facts 1 $((8*GIB)) "$(procs $((GIB*3/4)))"; echo -n "probe xprotectd=0.75GiB (between floor and boundary: episode holds)  "; step probe
facts 1 $((8*GIB)) "$(procs $((11*GIB)))"; echo -n "probe xprotectd=11GiB again  "; step probe
echo "memory-health alarm rows added after repeats: $(( $(memrows) - before ))  (expect 1)"
facts 1 $((8*GIB)) "$(procs $((GIB/2)))"; echo -n "probe xprotectd=0.5GiB (at floor: episode ends)  "; step probe
echo "state/.memory-alarmed after floor: $(tr '\n' ' ' < "$LAB/state/.memory-alarmed")"
facts 1 $((8*GIB)) "$(procs $((11*GIB)))"; echo -n "probe xprotectd=11GiB (new episode)  "; step probe
echo "memory-health alarm rows added: $(( $(memrows) - before ))  (expect 2)"
echo "state/.memory-alarmed: $(tr '\n' ' ' < "$LAB/state/.memory-alarmed")"

echo; echo "=== B: headroom margin is recorded and shown but never refuses normal-pressure work (Main186 Option A)"
facts 2 $((6*GIB)) "$(procs $GIB)"; echo -n "probe at pressure 2, available 6GiB  "; JQ='{source,pressure_level,admission,reasons}' step probe
facts 1 $((1*GIB)) "$(procs $GIB)"; echo -n "admit at pressure 1, available 1GiB  "; JQ='{admission,reasons,available_bytes,headroom}' step admit
echo "calibration pressured record: $(jq -c .pressured "$LAB/state/.memory-calibration.json")"

echo; echo "=== C: unreadable facts defer honestly (exit 75) and never fabricate values"
facts 1 $((8*GIB)) "$(procs $GIB)"; rm "$N/vm_stat"
echo -n "admit with vm_stat missing  "; JQ='{admission,reasons,has_available:has("available_bytes"),has_unused:has("unused_bytes"),calibration}' step admit
echo -n "probe with vm_stat missing  "; JQ='{admission,errors}' step probe
grep $'\tcheck\tmemory-health-unavailable\t' "$Q" | tail -1 | cut -f5
facts 0 $((8*GIB)) "$(procs $GIB)"; echo -n "admit with pressure level 0  "; JQ='{admission,errors}' step admit
facts 1 $((8*GIB)) '[{"pid":101,"rss_bytes":"unknown"}]'; echo -n "admit with malformed process census  "; JQ='{admission,errors}' step admit

echo; echo "=== D: run-start wrapper refuses a NEW run under pressure and never stops running work"
sleep 600 & RUNNING=$!
MARK=$LAB/new-run-started; rm -f "$MARK"
facts 2 $((8*GIB)) "$(procs $GIB)"
rc=0; G run -- /usr/bin/touch "$MARK" 2>"$LAB/run.err" || rc=$?
echo "pressure 2: exit=$rc new-run-started=$([ -e "$MARK" ] && echo yes || echo no) running-PID-$RUNNING=$(kill -0 $RUNNING 2>/dev/null && echo alive || echo GONE)"
echo "stderr reading: $(jq -c '{admission,reasons}' "$LAB/run.err")"
facts 4 $((8*GIB)) "$(procs $GIB)"
rc=0; G run -- /usr/bin/touch "$MARK" 2>/dev/null || rc=$?
echo "pressure 4: exit=$rc new-run-started=$([ -e "$MARK" ] && echo yes || echo no) running=$(kill -0 $RUNNING 2>/dev/null && echo alive || echo GONE)"
facts 1 $((8*GIB)) "$(procs $GIB)"
rc=0; G run -- /usr/bin/touch "$MARK" || rc=$?
echo "pressure 1: exit=$rc new-run-started=$([ -e "$MARK" ] && echo yes || echo no) running=$(kill -0 $RUNNING 2>/dev/null && echo alive || echo GONE)"
kill $RUNNING

echo; echo "=== every reading is one parseable JSONL row; fixture rows are marked"
python3 -I -c 'import json,sys,collections; rows=[json.loads(l) for l in open(sys.argv[1])]; print(len(rows),"rows parse;", dict(collections.Counter((r["source"], "fixture" if r["fixture"] else "real") for r in rows)))' "$LAB/state/memory-readings.jsonl"
