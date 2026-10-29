# Sourced helper (test attempt 2) for the live lab drive of the change-gated open-work ledger.
# Every command runs the real scripts from the gate worktree against a marked lab FM_HOME.
W=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M64W8Y7K4BPYQPXVVWJGH2T3
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M64W8Y7K4BPYQPXVVWJGH2T3
export FM_HOME=$(cat "$EV/t2-lab-path.txt")
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
cd "$W"
T=$EV/t2-transcript.txt
O=$FM_HOME/../t2.o; E=$FM_HOME/../t2.e; B=$FM_HOME/../t2.b
say() { printf '\n### %s\n' "$*" | tee -a "$T"; }
run() { printf '$ %s\n' "$*" >> "$T"; "$@" > "$O" 2> "$E"; local rc=$?; cat "$O" "$E" >> "$T"; printf '[exit %s]\n' "$rc" | tee -a "$T"; return $rc; }
drain() { run bin/fm-wake-drain.sh; local rc=$?; sed -n 's/.*--ack-through \([0-9]*\) --recovery-generation \([A-Za-z0-9._-]*\).*/\1 \2/p' "$E" > "$B"; return $rc; }
ack() { set -- $(cat "$B"); local s=$(python3 -c 'import time;print(time.time())'); run bin/fm-wake-drain.sh --ack-through "$1" --recovery-generation "$2"; local rc=$?
  python3 -c "import time;print('[ack wall time %.2fs]' % (time.time()-$s))" | tee -a "$T"; return $rc; }
watch_once() { # [resurface-secs]
  printf '$ FM_OPEN_LOOPS_RESURFACE=%s bin/fm-watch.sh (one cycle, 60s cap)\n' "${1:-3600}" >> "$T"
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 FM_HOME_SUMMARY_INTERVAL=99999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_OPEN_LOOPS_INTERVAL=3600 FM_OPEN_LOOPS_RESURFACE="${1:-3600}" \
    timeout "${2:-60}" bin/fm-watch.sh > "$O" 2>"$E"; local rc=$?
  cut -c1-400 "$O" | tee -a "$T"; printf '[watcher exit %s]\n' "$rc" | tee -a "$T"
  printf 'queue now (kind key payload):\n' >> "$T"; cut -f3-5 "$FM_HOME/state/.wake-queue" 2>/dev/null | cut -c1-200 | tee -a "$T"; return $rc; }
hb() { run bin/fm-open-loops.sh --heartbeat; }
overdue_ids() { jq -r '.rows[]|select(.overdue)|.id' "$FM_HOME/state/open-loops.json" | sort; }
# G1: every overdue row is either in the gate (needs action) or in the waiting list.
g1() { python3 - "$FM_HOME" <<'PY' | tee -a "$T"
import json, subprocess, sys, re
home = sys.argv[1]
led = json.load(open(home + '/state/open-loops.json'))
over = {r['id'] for r in led['rows'] if r.get('overdue')}
dig = subprocess.run(['bin/fm-open-loops.sh', '--digest'], text=True, capture_output=True).stdout
listed = set(re.findall(r'^  "([0-9a-f]+)",', dig, re.M))
pres = subprocess.run(['bin/fm-open-loops.sh', '--check-actions'], text=True, capture_output=True)
gated = set(re.findall(r'"([0-9a-f]{24})"', pres.stdout))
print(f'G1 check: overdue={len(over)} waiting_list={len(listed)} gate_refused={len(gated)} '
      f'missing_from_both={sorted(over - listed - gated)} in_both={sorted(listed & gated)}')
PY
}
