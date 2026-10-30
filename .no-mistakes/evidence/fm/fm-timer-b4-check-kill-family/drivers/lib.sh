# Shared driver helpers. Usage: . lib.sh <repo-root>
ROOT=$1
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M660RK8MW2W9FJGDSPWM42CN
live() { kill -0 "$1" 2>/dev/null || return 1; case "$(ps -p "$1" -o stat= 2>/dev/null)" in Z*) return 1;; esac; }
mklab() {
  eval "$("$ROOT/bin/fm-lab-home.sh" env 2>/dev/null)"
  export FM_HOME TMUX_TMPDIR
  mkdir -p "$FM_HOME/state"
}
droplab() { "$ROOT/bin/fm-lab-home.sh" teardown "$FM_HOME" >/dev/null 2>&1; rm -rf "$FM_HOME"; }
addcheck() {  # <id> ; body on stdin
  cat > "$FM_HOME/state/$1.check.sh"; chmod 0700 "$FM_HOME/state/$1.check.sh"
  (cd "$ROOT" && env -u FM_STATE_OVERRIDE bash bin/fm-check-register.sh "$1")
}
startwatch() {  # <log-prefix> [env...]
  local p=$1; shift
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$FM_HOME" FM_POLL=1 FM_HEARTBEAT=999999 "$@" \
    "$ROOT/bin/fm-watch.sh" > "$p.out" 2> "$p.err" &
  WPID=$!
}
waitsweep() {  # <max-seconds>
  local i
  for ((i = 0; i < $1 * 10; i++)); do
    [ ! -e "$FM_HOME/state/.last-check" ] || return 0
    live "$WPID" || return 0
    sleep 0.1
  done
  return 1
}
stopwatch() { kill -TERM "$WPID" 2>/dev/null; for ((i=0;i<300;i++)); do live "$WPID" || break; sleep 0.1; done; wait "$WPID" 2>/dev/null; }
ts() { date '+%H:%M:%S'; }
