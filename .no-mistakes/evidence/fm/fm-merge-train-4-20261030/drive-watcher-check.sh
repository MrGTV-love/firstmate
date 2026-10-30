#!/usr/bin/env bash
# drive-watcher-check.sh <repo-root> <kind: slow|silent> <FM_CHECK_TIMEOUT>
# Mints a disposable lab home, registers one custom check, runs the real
# bin/fm-watch.sh once until it exits on a wake, and prints the outcome.
set -u
R=$1 kind=$2 to=$3
eval "$("$R/bin/fm-lab-home.sh" env 2>/tmp/fm-lab-env.$$)"
teardown=$(grep -o '[^ ]*/bin/fm-lab-home.sh teardown .*' /tmp/fm-lab-env.$$ | head -1); rm -f /tmp/fm-lab-env.$$
echo "lab FM_HOME=$FM_HOME"
mkdir -p "$FM_HOME/state"
c="$FM_HOME/state/$kind.check.sh"
if [ "$kind" = slow ]; then
  cat > "$c" <<'C'
#!/usr/bin/env bash
# Slow but progressing: one stderr line per second for 15 s, then a result.
for i in $(seq 1 15); do echo "tick $i" >&2; sleep 1; done
echo "slow-check-finished-after-15s"
C
else
  cat > "$c" <<'C'
#!/usr/bin/env bash
# Silent and CPU-idle: no output, sleeps far past the no-progress minimum.
echo $$ > "$FM_HOME/state/silent.pid"
exec sleep 300
C
fi
chmod 700 "$c"
FM_HOME="$FM_HOME" "$R/bin/fm-check-register.sh" "$kind"
start=$(date +%s)
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$FM_HOME" FM_CHECK_TIMEOUT="$to" FM_CHECK_INTERVAL=0 FM_POLL=0.2 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
  perl -e 'alarm 120; exec @ARGV' "$R/bin/fm-watch.sh" > "$FM_HOME/watch.out" 2> "$FM_HOME/watch.err"
rc=$?
end=$(date +%s)
echo "watcher rc=$rc elapsed=$((end-start))s FM_CHECK_TIMEOUT=$to"
echo "--- watcher stdout (wake reason)"; cat "$FM_HOME/watch.out"
echo "--- watcher stderr (tail)"; tail -5 "$FM_HOME/watch.err"
echo "--- triage log lines naming the check"; grep -h "$kind" "$FM_HOME/state/.watch-triage.log" 2>/dev/null | tail -5
echo "--- full triage log tail"; tail -8 "$FM_HOME/state/.watch-triage.log" 2>/dev/null
echo "--- state/*.check-stopped"; ls "$FM_HOME/state" | grep check-stopped || echo "(none)"
if [ -f "$FM_HOME/state/silent.pid" ]; then p=$(cat "$FM_HOME/state/silent.pid"); if kill -0 "$p" 2>/dev/null; then echo "silent check pid $p STILL ALIVE"; kill "$p"; else echo "silent check pid $p is gone (tree cleaned)"; fi; fi
tmux -L fm-lab kill-server 2>/dev/null || true
eval "$teardown" && echo "lab torn down"
