#!/usr/bin/env bash
# Live lab driver: arm a real watcher in a disposable lab home, then feed
# Claude-shaped PreToolUse payloads to the real bin/fm-arm-pretool-check.sh
# hook (head and base code) for exact-PID and broad kill commands. Finally run
# one allowed exact-PID stop for real and confirm only the lab watcher stopped.
# Usage: drive-exact-pid-kill.sh <head-root> <base-root>
set -u
HEAD_ROOT=$1 BASE_ROOT=$2
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M3RBHP2HEVGS72YBVPJ7PKXK
LOG="$EV/exact-pid-kill.log"
: > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$HEAD_ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux"
RUN=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_ARM_CONFIRM_TIMEOUT
  TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB")
cleanup() {
  "${RUN[@]}" "$HEAD_ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
  [ -z "${ARM_PID:-}" ] || { kill "$ARM_PID" 2>/dev/null; wait "$ARM_PID" 2>/dev/null; }
  rm -rf "$LAB"
}
trap cleanup EXIT

"${RUN[@]}" "$HEAD_ROOT/bin/fm-watch-arm.sh" > "$LAB/arm.out" 2>&1 &
ARM_PID=$!
for _ in $(seq 1 150); do [ -s "$LAB/state/.watch.lock/pid" ] && [ -s "$LAB/arm.out" ] && break; sleep 0.2; done
N=$(cat "$LAB/state/.watch.lock/pid")
say "lab=$LAB  arm: $(head -1 "$LAB/arm.out")"
say "lab watcher pid N=$N: $(ps -p "$N" -o command=)"
say ""

hook() {  # <root> <command> -> prints ALLOW or DENY(reason)
  local root=$1 cmd=$2 payload err rc
  payload=$(jq -cn --arg c "$cmd" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}')
  err=$(printf '%s' "$payload" | "${RUN[@]}" "$root/bin/fm-arm-pretool-check.sh" --claude 2>&1 >/dev/null); rc=$?
  if [ "$rc" -eq 0 ]; then echo ALLOW; else echo "DENY rc=$rc: $(printf '%s' "$err" | tr '\n' ' ' | cut -c1-110)"; fi
}

n=0
check() {  # <expect> <command>
  local expect=$1 cmd=$2 h b verdict
  n=$((n+1))
  h=$(hook "$HEAD_ROOT" "$cmd"); b=$(hook "$BASE_ROOT" "$cmd")
  case "$h" in "$expect"*) verdict=PASS ;; *) verdict=FAIL ;; esac
  say "[$verdict] case $n expect=$expect"
  say "    command: $(printf '%s' "$cmd" | sed 's/$/\\n/' | tr -d '\n' | sed 's/\\n$//')"
  say "    head: $h"
  say "    base: $b"
}

say "=== exact-PID stops of this home's lock pid (must be ALLOWED) ==="
check ALLOW "if ps -p $N -o command= | grep -q fm-watch.sh; then kill -TERM $N; fi"
check ALLOW "if pgrep -fl fm-watch.sh; then command kill -- $N; fi"
check ALLOW $'if ps -p '"$N"$' -o command= | grep -q fm-watch.sh; then\n  kill -TERM '"$N"$'\nfi'
check ALLOW $'while ps -p '"$N"$' -o command= | grep -q fm-watch.sh; do\n  kill -TERM '"$N"$'\n  sleep 1\ndone'
check ALLOW $'if ! ps -p '"$N"$' -o command= | grep -q fm-watch.sh; then :; else\n  kill '"$N"$'\nfi'
say ""
say "=== broad or disguised kills (must stay DENIED) ==="
check DENY "if ps -p $N -o command= | grep -q fm-watch.sh; then pkill -f fm-watch.sh; fi"
check DENY "if ps -p $N -o command= | grep -q fm-watch.sh; then kill -TERM $((N+1)); fi"
check DENY "if ps -p $N -o command= | grep -q fm-watch.sh; then kill -- -$N; fi"
check DENY "if ps -p $N -o command= | grep -q fm-watch.sh; then kill $N $((N+1)); fi"
check DENY "if ps -p $N -o command= | grep -q fm-watch.sh; then kill \$(pgrep -f fm-watch.sh); fi"
check DENY "if ! pkill -f fm-watch; then kill $N; fi"
check DENY "while ! pkill -f fm-watch.sh; do kill $N; done"
check DENY "if true; then if pkill -f fm-watch; then kill $N; fi; fi"
check DENY "if ! bin/fm-watch.sh; then kill $N; fi"
check DENY $'if !\n pkill -f fm-watch; then\n  kill '"$N"$'\nfi'
check DENY $'while true; do\n  bin/fm-watch.sh\n  kill '"$N"$'\ndone'
check DENY "pkill -f fm-watch"
say ""

say "=== run the allowed exact-PID stop for real ==="
CMD="if ps -p $N -o command= | grep -q fm-watch.sh; then kill -TERM $N; fi"
say "hook verdict (head): $(hook "$HEAD_ROOT" "$CMD")"
say "\$ $CMD"
bash -c "$CMD"; say "exit=$?"
for _ in $(seq 1 50); do kill -0 "$N" 2>/dev/null || break; sleep 0.2; done
say "lab watcher pid $N alive after stop: $(kill -0 "$N" 2>/dev/null && echo yes || echo no)"
say "lab lock after stop: $([ -e "$LAB/state/.watch.lock" ] && echo held || echo released)"
wait "$ARM_PID" 2>/dev/null; say "arm reported: $(tail -2 "$LAB/arm.out" | tr '\n' ' ')"
ARM_PID=
say "summary: $(grep -c '^\[PASS\]' "$LOG") pass, $(grep -c '^\[FAIL\]' "$LOG") fail"
