#!/usr/bin/env bash
# Scenario 9 trace: frozen launcher + watcher TERM, watcher run under bash -x with timestamps.
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh" "$1"; L=$2
now() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }
launcher_of() { local pp; pp=$(ps -o ppid= -p "$1" | tr -d ' '); case "$(ps -o command= -p "$pp")" in *fm-check-run.py*) echo "$pp";; esac; }
mklab
addcheck stubborn >/dev/null <<'SH'
#!/usr/bin/env bash
trap '' TERM
printf '%s\n' "$$" > "$FM_HOME/state/check-pid"
sleep 600 & printf '%s\n' "$!" > "$FM_HOME/state/child-pid"
while :; do printf 'working\n' >&2; sleep 0.2; done
SH
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$FM_HOME" FM_POLL=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 \
  PS4='+${SECONDS} ${LINENO} ' bash -x "$ROOT/bin/fm-watch.sh" > "$D/s9t.out" 2> "$D/s9t.trace" &
WPID=$!
for ((i=0;i<300;i++)); do [ -s "$FM_HOME/state/child-pid" ] && break; sleep 0.1; done
sleep 1
c=$(cat "$FM_HOME/state/check-pid"); lp=$(launcher_of "$c")
kill -STOP "$lp"; t0=$(now); echo "TERM at $t0 (launcher $lp frozen)"; kill -TERM "$WPID"
for ((i=0;i<600;i++)); do live "$WPID" || break; sleep 0.1; done
echo "watcher gone after $(echo "$(now) - $t0" | bc)s"
wait "$WPID" 2>/dev/null; kill -CONT "$lp" 2>/dev/null
droplab
