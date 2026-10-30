# Sourced helper for the live ledger scenarios: real fm-watch.sh, fm-wake-drain.sh and fm-open-loops.sh in a lab FM_HOME.
W=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M65C2HMM2RP9VRSG8D6HWVHS
cd "$W"
export FM_HOME=/Users/charlesabrooker/tmp/fm-lab.zoj9AC TMUX_TMPDIR=/tmp/fml.WZGPF5
unset TMUX FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_SUPERVISION_ACTOR
S=$FM_HOME/state
watch_once() {  # one real watcher cycle with unrelated cadences off
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 FM_HOME_SUMMARY_INTERVAL=99999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 timeout "${1:-60}" bin/fm-watch.sh 2>/dev/null; echo "watch rc=$?"
}
drain() {  # drain into /tmp/fm-lab-drain.out (summary printed), keep ack boundary in ACK_ARGS
  local err; err=$(mktemp); bin/fm-wake-drain.sh >/tmp/fm-lab-drain.out 2>"$err"; DRAIN_RC=$?
  grep -E '^(OVERDUE|STANDING|WAITING|rows\[|  "|[a-z0-9-]+ \(|help)' /tmp/fm-lab-drain.out | cut -c1-170
  ACK_ARGS=$(sed -n 's/^WAKE_ACK_REQUIRED:.*\(--ack-through [0-9]* --recovery-generation [A-Za-z0-9._-]*\)$/\1/p' "$err")
  echo "drain rc=$DRAIN_RC ack=[${ACK_ARGS:-none}]"; grep -v '^WAKE_ACK_REQUIRED' "$err" | head -5; rm -f "$err"
}
ack() { local t0=$SECONDS; eval "bin/fm-wake-drain.sh $ACK_ARGS" > /tmp/fm-lab-ack.out 2>&1; local rc=$?; echo "ack rc=$rc ($((SECONDS-t0))s)"; head -${1:-8} /tmp/fm-lab-ack.out; return 0; }
