#!/usr/bin/env bash
# Live driver: real host probes in a lab ROOT home, then baseline derivation.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M5ZXMAD5W9SM4DC85WJ38ZQ5
PB=/Users/charlesabrooker/fleet/fm-mini-home/bin/fm-proc-budget.sh
export FM_HOME=$1
unset NO_MISTAKES_GATE FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_MEMORY_FIXTURE_DIR
G() { "$PB" --memory-kib 4194304 -- "$WT/bin/fm-mem-guard.sh" "$@"; }
echo "### L4: three real probes from the lab root home (\$ FM_HOME=<lab> bin/fm-mem-guard.sh probe)"
for i in 1 2 3; do
  rc=0; out=$(G probe) || rc=$?
  echo "probe $i exit=$rc"; jq -c '{source,pressure_level,admission,errors,non_fleet_max_bytes,calibration,headroom,headroom_calibration,alarms:(.alarms|length)}' <<<"$out"
  sleep 3
done
echo; echo "### lab state/.memory-calibration.json (run records from real runs on this host)"
jq '{schema,host,total_bytes,pressured,runs:(.runs|to_entries|map({key,value:{peak_bytes:.value.peak_bytes,samples:.value.samples,incomplete_samples:.value.incomplete_samples,max_gap_seconds:.value.max_gap_seconds}})|from_entries)}' "$FM_HOME/state/.memory-calibration.json"
echo; echo "### lab state/.wake-queue (uncalibrated check wake, queued once)"
cat "$FM_HOME/state/.wake-queue"
echo; echo "### lab state/.memory-alarmed"; cat "$FM_HOME/state/.memory-alarmed"
echo; echo "### L5: \$ FM_HOME=<lab> bin/fm-mem-guard.sh baseline  (derives only from root probe rows; sample/admit rows exist in the log)"
jq -r '.source' "$FM_HOME/state/memory-readings.jsonl" | sort | uniq -c
jq -c 'select(.source=="probe") | {checked_at,non_fleet_max_bytes}' "$FM_HOME/state/memory-readings.jsonl"
rc=0; out=$(G baseline) || rc=$?; echo "baseline exit=$rc"
jq '{admission,reasons,baseline}' <<<"$out"
echo; echo "### baseline file on disk"; cat "$FM_HOME/state/.memory-baseline.json" 2>/dev/null || echo "(none written)"
echo; echo "### admit after baseline (real host) shows baseline, alarm list, headroom fields"
rc=0; out=$(G admit) || rc=$?; echo "exit=$rc"; jq -c '{admission,reasons,calibration,alarms:[.alarms[]|{comm,pid,rss_bytes,boundary_bytes}],alarm_hold,headroom,headroom_calibration}' <<<"$out"
