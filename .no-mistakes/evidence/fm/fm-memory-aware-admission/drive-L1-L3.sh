#!/usr/bin/env bash
# Live driver: real host native facts, lab FM_HOME, real fm-mem-guard.sh.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M5ZXMAD5W9SM4DC85WJ38ZQ5
PB=/Users/charlesabrooker/fleet/fm-mini-home/bin/fm-proc-budget.sh
export FM_HOME=$1
unset NO_MISTAKES_GATE FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_MEMORY_FIXTURE_DIR
G() { "$PB" --memory-kib 4194304 -- "$WT/bin/fm-mem-guard.sh" "$@"; }
echo "### host: $(hostname)  date: $(date -u +%FT%TZ)"
echo "### native facts as the shell sees them (for comparison)"; sysctl -n hw.memsize kern.memorystatus_vm_pressure_level vm.swapusage
echo; echo "### L1: \$ FM_HOME=<lab> bin/fm-mem-guard.sh sample  (real host, no fixture)"
rc=0; out=$(G sample) || rc=$?; echo "exit=$rc"
jq '{source,host,fixture,platform,errors,pressure_level,total_bytes,unused_bytes,available_bytes,anonymous_bytes,compressor_bytes,swap_total_bytes,swap_used_bytes,swap_free_bytes,admission,reasons,non_fleet_max_bytes,rss_unreadable_count:(.rss_unreadable_pids|length),runs,calibration,headroom_calibration,top_processes:[.top_processes[]|{pid,comm,rss_bytes,fleet,run}]}' <<<"$out"
echo; echo "### L2: \$ FM_HOME=<lab> bin/fm-mem-guard.sh admit  (real host)"
rc=0; out=$(G admit) || rc=$?; echo "exit=$rc"; jq -c '{source,pressure_level,admission,reasons,errors}' <<<"$out"
echo; echo "### L3: \$ FM_HOME=<lab> bin/fm-mem-guard.sh run -- /bin/echo NEW-RUN-STARTED  (real host)"
rc=0; G run -- /bin/echo NEW-RUN-STARTED || rc=$?; echo "exit=$rc"
echo; echo "### readings log rows in lab state/memory-readings.jsonl"
jq -c '{checked_at,source,pressure_level,admission,fixture}' "$FM_HOME/state/memory-readings.jsonl"
