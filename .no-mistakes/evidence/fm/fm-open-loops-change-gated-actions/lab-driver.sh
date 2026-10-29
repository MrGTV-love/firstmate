# Sourced helper for the live lab drive of the change-gated open-work ledger.
# All commands run the real scripts from the gate worktree against a marked lab FM_HOME.
W=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M64W8Y7K4BPYQPXVVWJGH2T3
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M64W8Y7K4BPYQPXVVWJGH2T3
export FM_HOME=/Users/charlesabrooker/tmp/fm-lab.g6rL6N TMUX_TMPDIR=/tmp/fml.jijHUj
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
cd "$W"
T=$EV/live-transcript.txt
say() { printf '\n### %s\n' "$*" | tee -a "$T"; }
run() { printf '$ %s\n' "$*" >> "$T"; "$@" > /tmp/lab.o 2> /tmp/lab.e; local rc=$?; cat /tmp/lab.o /tmp/lab.e | tee -a "$T"; printf '[exit %s]\n' "$rc" | tee -a "$T"; return $rc; }
drain() { run bin/fm-wake-drain.sh; local rc=$?; sed -n 's/.*--ack-through \([0-9]*\) --recovery-generation \([A-Za-z0-9._-]*\).*/\1 \2/p' /tmp/lab.e > /tmp/lab.b; return $rc; }
ack() { set -- $(cat /tmp/lab.b); run bin/fm-wake-drain.sh --ack-through "$1" --recovery-generation "$2"; }
watch_once() { # [resurface-secs]
  printf '$ FM_OPEN_LOOPS_RESURFACE=%s bin/fm-watch.sh (one cycle, 60s cap)\n' "${1:-3600}" >> "$T"
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 FM_HOME_SUMMARY_INTERVAL=99999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_OPEN_LOOPS_INTERVAL=3600 FM_OPEN_LOOPS_RESURFACE="${1:-3600}" \
    timeout "${2:-60}" bin/fm-watch.sh > /tmp/lab.o 2>/tmp/lab.e; local rc=$?
  cat /tmp/lab.o | tee -a "$T"; printf '[watcher exit %s]\n' "$rc" | tee -a "$T"
  printf 'queue now:\n' >> "$T"; cut -f2-5 "$FM_HOME/state/.wake-queue" 2>/dev/null | tee -a "$T"; return $rc; }
hb() { run bin/fm-open-loops.sh --heartbeat; }
