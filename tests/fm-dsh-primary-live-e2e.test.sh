#!/usr/bin/env bash
# Real dsh-tui PRIMARY: native startup, one watcher, queue consumption, passive
# turn-end recovery and fm-control interrupt/exit/resume in a named Herdr lab.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
fm_live_gate opt-in FM_DSH_PRIMARY_LIVE herdr jq dsh-tui dsh node
printf 'DSH primary live runtime:\n'
dsh-tui version
printf 'DSH CLI: '; dsh --version
printf 'Node: '; node --version
TASK=${FM_DSH_EVIDENCE_DIR:-$(mktemp -d)}
HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
LAB_HELPER=${LAB_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}
ORIGINAL_PATH=$PATH
mkdir -p "$TASK/bin"
export FM_HERDR_LAB_STATE_DIR="$TASK/primary-herdr-safety"
SESSION=$("$HELPER" name dsh-primary)
LAB_HOME=$(mktemp -d /tmp/fm-dsh-primary.XXXXXX)
PARENT=$(mktemp -d /tmp/fm-dsh-parent.XXXXXX)
SECOND=$(mktemp -d /tmp/fm-dsh-second.XXXXXX)
LAB_HOME=$(cd "$LAB_HOME" && pwd -P)
PARENT=$(cd "$PARENT" && pwd -P)
SECOND=$(cd "$SECOND" && pwd -P)
cleanup() {
  local rc=$?
  trap - EXIT
  if [ -p "$TASK/second-hold/release" ]; then
    exec 3<>"$TASK/second-hold/release"
    echo release >&3
    exec 3>&-
  fi
  # Retire the native owner first: stopping only its watcher while the TUI
  # remains alive permits a legitimate turn-end callback to re-arm it.
  PATH="$ORIGINAL_PATH" "$HELPER" teardown "$SESSION" || rc=1
  for home in "$LAB_HOME" "$SECOND"; do
    [ -d "$home/state" ] || continue
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" bash "$ROOT/bin/fm-watch-arm.sh" --stop || rc=1
  done
  "$LAB_HELPER" teardown "$LAB_HOME" || rc=1
  printf 'primary_home=%s\nparent_home=%s\nsecondmate_home=%s\ncleanup_exit=%s\n' "$LAB_HOME" "$PARENT" "$SECOND" "$rc"
  exit "$rc"
}
trap cleanup EXIT
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
"$LAB_HELPER" create "$LAB_HOME"
"$LAB_HELPER" create "$PARENT"
mkdir "$LAB_HOME/operator-home"
ID="dsh-primary-$$"
printf '%s\n' "$ID" > "$LAB_HOME/.fm-secondmate-home"
# Control accounts for the recorded home's Git changes before restarting it.
# This is a fresh throwaway repository, never another shared pool checkout.
git init -q "$LAB_HOME"
cp "$ROOT/AGENTS.md" "$LAB_HOME/AGENTS.md"
ln -s "$ROOT/bin" "$LAB_HOME/bin"
ln -s "$ROOT/.agents" "$LAB_HOME/.agents"
ln -s "$ROOT/docs" "$LAB_HOME/docs"
for home in "$LAB_HOME" "$PARENT"; do
  printf 'manual\n' > "$home/config/backlog-backend"
  printf 'herdr\n' > "$home/config/runtime-backend"
  printf 'dsh\n' > "$home/config/crew-harness"
  printf 'off\n' > "$home/config/supervision-host-off"
  printf '# Backlog\n\n## Queued\n\n## In flight\n\n## Done\n' > "$home/data/backlog.md"
done
cat > "$LAB_HOME/state/primary-probe.check.sh" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_HOME/state/probe-wake" ]; then
  rm "$FM_HOME/state/probe-wake"
  echo 'primary runtime verification notification'
fi
SH
chmod 700 "$LAB_HOME/state/primary-probe.check.sh"
FM_HOME="$LAB_HOME" FM_ROOT_OVERRIDE="$LAB_HOME" FM_STATE_OVERRIDE="$LAB_HOME/state" bash "$ROOT/bin/fm-check-register.sh" primary-probe
cat > "$TASK/bin/herdr" <<EOF
#!/usr/bin/env bash
set -eu
# The spawn's client-version preflight names no session; answer it from the lab.
[ "\$*" != 'status --json' ] || exec env PATH='$ORIGINAL_PATH' '$HELPER' run '$SESSION' status --json
args=("\$@")
n=\${#args[@]}
[ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = '$SESSION' ] || { echo 'primary lab refuses an unscoped Herdr call' >&2; exit 98; }
args=("\${args[@]:0:\$((n-2))}")
exec env PATH='$ORIGINAL_PATH' '$HELPER' run '$SESSION' "\${args[@]}"
EOF
chmod +x "$TASK/bin/herdr"
"$HELPER" provision "$SESSION"
export PATH="$TASK/bin:$ORIGINAL_PATH"
lab() { PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" "$@"; }
control() { FM_POLL=1 FM_CHECK_INTERVAL=1 FM_DSH_OPERATOR_HOME="$LAB_HOME/operator-home" FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$PARENT/state" FM_CONFIG_OVERRIDE="$PARENT/config" FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=30 bash "$ROOT/bin/fm-control.sh" "$@"; }
WS=$(lab workspace create --cwd "$LAB_HOME" --label "fm-$ID" --no-focus)
PANE=$(printf '%s' "$WS" | jq -er .result.root_pane.pane_id)
PROMPT='This is an isolated Firstmate runtime lab, not real operational work. Do not investigate the environment, read outside this lab home, load more skills, edit code, or dispatch work. Ignore startup diagnostics from this throwaway home. Remember the word ORCHID73 only in this conversation, then reply exactly FMPRIMARYREADY. On native watcher notification run bin/fm-wake-drain.sh, execute its exact WAKE_ACK_REQUIRED command, and reply FMWAKEHANDLED.'
printf '%s\n' 'Isolated runtime lab. Do not investigate, read outside this home, load skills, dispatch or edit code. Ignore startup diagnostics from this throwaway home. On watcher notification drain and acknowledge. On resuming this conversation reply FMPRIMARYRESUMED and the secret word remembered earlier, without inspecting files. Follow only the supplied tiny runtime checks.' > "$LAB_HOME/data/charter.md"
# A pane line longer than the terminal's canonical-mode limit is refused, so
# the pane runs a short command and the launch lives in a file.
cat > "$TASK/start-primary.sh" <<EOF
#!/usr/bin/env bash
exec env FM_HOME='$LAB_HOME' FM_DSH_OPERATOR_HOME='$LAB_HOME/operator-home' PATH='$PATH' FM_POLL=1 FM_CHECK_INTERVAL=1 bash '$ROOT/bin/fm-dsh-primary.sh' -- '$PROMPT'
EOF
lab pane run "$PANE" "bash '$TASK/start-primary.sh'"
EVENTS="$LAB_HOME/state/.dsh-primary-events.jsonl"
for _ in $(seq 1 120); do
  if [ -f "$EVENTS" ] && jq -s -e 'any(.[]; .event == "watcher-ready")' "$EVENTS" >/dev/null; then break; fi
  sleep 1
done
jq -s -e 'any(.[]; .event == "startup") and any(.[]; .event == "watcher-ready")' "$EVENTS" >/dev/null
LOG=$(python3 "$ROOT/bin/fm-dsh.py" session-file "$LAB_HOME/state" dsh-primary)
assistant_has() {
  python3 - "$LOG" "$1" <<'PY'
import json,sys
for line in open(sys.argv[1]):
    try: event=json.loads(line)
    except ValueError: continue
    if event.get('type') != 'assistant/message': continue
    content=event.get('data',{}).get('message',{}).get('content',[])
    text='\n'.join(part.get('text','') for part in content if part.get('type') == 'text')
    if all(token in text for token in sys.argv[2].split()): sys.exit(0)
sys.exit(1)
PY
}
wait_reply() { local i=0; while [ "$i" -lt 120 ]; do assistant_has "$1" && return 0; sleep 1; i=$((i + 1)); done; lab pane read "$PANE" --source visible; return 1; }
wait_reply FMPRIMARYREADY
# Capture actual emitted startup context and a task-owned binding so the
# existing control plane can drive this primary exactly as a secondmate.
cp "$LAB_HOME/state/dsh-primary.dsh-session" "$PARENT/state/$ID.dsh-session"
cat > "$PARENT/state/$ID.meta" <<EOF
window=$SESSION:$PANE
endpoint_task_id=$ID
worktree=$LAB_HOME
project=$LAB_HOME
home=$LAB_HOME
harness=dsh
kind=secondmate
mode=secondmate
yolo=off
model=deepseek/deepseek-v4-flash
effort=high
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$(printf '%s' "$WS" | jq -er .result.workspace.workspace_id)
herdr_tab_id=$(printf '%s' "$WS" | jq -er .result.root_pane.tab_id)
herdr_pane_id=$PANE
EOF
touch "$LAB_HOME/state/probe-wake"
wait_reply FMWAKEHANDLED
for _ in $(seq 1 120); do
  [ ! -s "$LAB_HOME/state/.wake-queue" ] && [ ! -f "$LAB_HOME/state/probe-wake" ] && break
  sleep 1
done
[ ! -s "$LAB_HOME/state/.wake-queue" ] && [ ! -f "$LAB_HOME/state/probe-wake" ]
# Wait for the acknowledged cycle's actual replacement before depriving the
# primary of supervision; initial startup's 2 -> 0 must not satisfy this case.
for _ in $(seq 1 120); do
  if [ -s "$LAB_HOME/state/.watch.lock/pid" ] && kill -0 "$(cat "$LAB_HOME/state/.watch.lock/pid")" 2>/dev/null; then break; fi
  sleep 1
done
kill -0 "$(cat "$LAB_HOME/state/.watch.lock/pid")"
GUARD_OFFSET=$(wc -l < "$EVENTS" | tr -d ' ')
# Stop only the named lab home's watcher. The native callback must run the
# shared guard, observe code 2 and restore supervision without a loop.
FM_HOME="$LAB_HOME" FM_ROOT_OVERRIDE="$LAB_HOME" FM_STATE_OVERRIDE="$LAB_HOME/state" bash "$ROOT/bin/fm-watch-arm.sh" --stop
lab pane send-text "$PANE" 'Reply exactly FMGUARDPROOF. Do not run commands.'
lab pane send-keys "$PANE" enter
wait_reply FMGUARDPROOF
sleep 3
jq -s -e --argjson offset "$GUARD_OFFSET" '.[$offset:] | any(.[]; .event == "turnend-guard" and .code == 2) and any(.[]; .event == "turnend-guard" and .code == 0)' "$EVENTS" >/dev/null
sleep_calls() { python3 -c 'import sys; print(sum(1 for line in open(sys.argv[1]) if "\"type\":\"tool/call\"" in line.replace(" ", "") and "sleep 40" in line))' "$LOG"; }
# Let the guard recovery turn finish, then interrupt mid-task: only once the
# model has started the requested sleep, so no unanswered request remains.
for _ in $(seq 1 120); do
  [ "$(python3 "$ROOT/bin/fm-dsh.py" state "$PARENT/state" "$ID")" = idle ] && break
  sleep 1
done
[ "$(python3 "$ROOT/bin/fm-dsh.py" state "$PARENT/state" "$ID")" = idle ] || { echo 'the primary never went idle before the interrupt probe' >&2; exit 1; }
CALLS=$(sleep_calls)
lab pane send-text "$PANE" 'Run sleep 40 with Bash, then reply FMINTERUPTPROBE. Do not do anything else.'
lab pane send-keys "$PANE" enter
for _ in $(seq 1 60); do
  [ "$(python3 "$ROOT/bin/fm-dsh.py" state "$PARENT/state" "$ID")" = busy ] && [ "$(sleep_calls)" -gt "$CALLS" ] && break
  sleep 1
done
[ "$(python3 "$ROOT/bin/fm-dsh.py" state "$PARENT/state" "$ID")" = busy ] && [ "$(sleep_calls)" -gt "$CALLS" ] || { echo 'the model never started the requested sleep' >&2; exit 1; }
control "$ID" interrupt
control "$ID" exit
BEFORE=$(python3 "$ROOT/bin/fm-dsh.py" position "$PARENT/state" "$ID")
control "$ID" relaunch --harness dsh --model deepseek/deepseek-v4-flash --effort high --note 'Reply FMPRIMARYRESUMED and the secret word from the earlier conversation. Do not inspect files, investigate, load skills or dispatch work.'
[ "$(python3 "$ROOT/bin/fm-dsh.py" session-file "$PARENT/state" "$ID")" = "$LOG" ]
wait_reply 'FMPRIMARYRESUMED ORCHID73'
AFTER=$(python3 "$ROOT/bin/fm-dsh.py" position "$PARENT/state" "$ID")
[ "$AFTER" != "$BEFORE" ]
# A forced native crash bypasses Cordis disposal. Prove the kernel-observed
# death retires the precise private arm and watcher before resuming again.
NATIVE_PID=$(jq -s -er '[.[] | select(.event == "startup")][-1].pid' "$EVENTS")
# An armed cycle can close and re-arm on a wake at any moment; take the
# newest arm only while it and the home watcher are both alive.
for _ in $(seq 1 120); do
  ARM_PID=$(jq -s -r --argjson pid "$NATIVE_PID" '[.[] | select(.pid == $pid and (.event == "watcher-ready" or .event == "watcher-close"))] | last | select(.event == "watcher-ready") | .arm // empty' "$EVENTS")
  WATCH_PID=$(cat "$LAB_HOME/state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$ARM_PID" ] && [ -n "$WATCH_PID" ] && kill -0 "$ARM_PID" 2>/dev/null && kill -0 "$WATCH_PID" 2>/dev/null && break
  sleep 1
done
for pid in "$NATIVE_PID" "$ARM_PID" "$WATCH_PID"; do
  case "$pid" in ''|*[!0-9]*) echo 'invalid private lifecycle pid' >&2; exit 1 ;; esac
  kill -0 "$pid"
done
kill -KILL "$NATIVE_PID"
for _ in $(seq 1 120); do
  if ! kill -0 "$ARM_PID" 2>/dev/null && ! kill -0 "$WATCH_PID" 2>/dev/null; then break; fi
  sleep 1
done
! kill -0 "$ARM_PID" 2>/dev/null && ! kill -0 "$WATCH_PID" 2>/dev/null
printf 'ok - forced native owner death retired private arm and watcher\n'
control "$ID" relaunch --harness dsh --model deepseek/deepseek-v4-flash --effort high --note 'Native primary was force-killed to prove owner-bound watcher cleanup. Continue the same conversation under the lab charter.'
lab pane send-text "$PANE" 'Reply FMCRASHRESUMED and the secret word remembered earlier. Do not inspect files or run commands.'
lab pane send-keys "$PANE" enter
wait_reply 'FMCRASHRESUMED ORCHID73'
control "$ID" exit
cp "$EVENTS" "$TASK/dsh-primary-events.jsonl"
lab pane read "$PANE" --source recent --lines 180 > "$TASK/dsh-primary-pane.txt"
python3 - "$EVENTS" "$LOG" <<'PY'
import json,sys
rows=[json.loads(line) for line in open(sys.argv[1])]
keys=[key for row in rows if row['event']=='wake-delivery' for key in row['rows']]
assert len(keys)==len(set(keys)), 'a durable wake row was delivered twice'
assert sum(row['event']=='startup' for row in rows)>=2, 'resume must load the native primary adapter again'
assert any(row['event']=='disposed' for row in rows), 'native exit must retire the adapter'
text=open(sys.argv[2]).read()
assert 'primary harness: dsh' in text and 'Mode: DSH native Cordis supervision.' in text, 'the actual startup digest must select the dedicated protocol'
before=[]
for line in open(sys.argv[2]):
    try: event=json.loads(line)
    except ValueError: continue
    if event.get('type')=='assistant/message': break
    if event.get('type')=='user/message':
        before.append('\n'.join(part.get('text','') for part in event['data'].get('content',[]) if part.get('type')=='text'))
assert before and 'Mode: DSH native Cordis supervision.' in before[0], 'the startup digest must be the first user message'
assert any('ORCHID73' in words for words in before[1:]), 'the positional opening prompt must follow the digest before any reply'
print('ok - real dsh-tui primary startup, nested detection, one watcher, delivered and acknowledged wake, passive turn-end recovery, interrupt, exit and same-conversation resume')
PY
# A fresh secondmate: the real spawn prepares a new home's private runtime and
# loads the plugin with no prior conversation. A lab-only bash wrapper, first
# on that spawn's PATH, holds just this home's session-start digest at a FIFO
# barrier. An earlier requirement that the spawn's start proof and composer
# check pass while the digest is held cannot hold on this runtime: DSH awaits
# the plugin's agent/created startup before it publishes the session, so no
# turn exists until the digest is ready. Asserted instead: while held, the
# plugin's startup has begun, the spawn has not reported started, and no
# durable session log holds a turn or user message; after release the spawn
# reports started, which it does only after its start proof and composer
# check pass, and the digest, then the charter, enter ahead of any reply.
SECOND_ID="dsh-second-$$"
"$LAB_HELPER" create "$SECOND"
mkdir "$SECOND/operator-home"
printf '%s\n' "$SECOND_ID" > "$SECOND/.fm-secondmate-home"
git init -q "$SECOND"
cp "$ROOT/AGENTS.md" "$SECOND/AGENTS.md"
ln -s "$ROOT/bin" "$SECOND/bin"
ln -s "$ROOT/.agents" "$SECOND/.agents"
ln -s "$ROOT/docs" "$SECOND/docs"
printf 'manual\n' > "$SECOND/config/backlog-backend"
printf 'herdr\n' > "$SECOND/config/runtime-backend"
printf 'off\n' > "$SECOND/config/supervision-host-off"
printf '# Backlog\n\n## Queued\n\n## In flight\n\n## Done\n' > "$SECOND/data/backlog.md"
# A secondmate's launch brief is its home charter.
printf '%s\n' 'This is an isolated Firstmate runtime lab secondmate, not real operational work. Do not investigate, read outside this home, load skills, edit code or dispatch work. Ignore startup diagnostics. Remember the word TULIP42 only in this conversation, then reply exactly FMSECONDREADY. On resuming this conversation reply FMSECONDRESUMED and the secret word remembered earlier, without inspecting files.' > "$SECOND/data/charter.md"
HOLD="$TASK/second-hold"
mkdir -p "$HOLD/bin"
mkfifo "$HOLD/release"
REAL_BASH=$(command -v bash)
cat > "$HOLD/bin/bash" <<EOF
#!$REAL_BASH
case "\${1:-}" in
  */bin/fm-sessionstart-run.sh)
    if [ "\${FM_HOME:-}" = '$SECOND' ]; then
      : > '$HOLD/reached'
      read -r _ < '$HOLD/release'
    fi
    ;;
esac
exec '$REAL_BASH' "\$@"
EOF
chmod +x "$HOLD/bin/bash"
PATH="$HOLD/bin:$PATH" FM_POLL=1 FM_CHECK_INTERVAL=1 FM_DSH_OPERATOR_HOME="$SECOND/operator-home" HERDR_SESSION="$SESSION" FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$PARENT/state" FM_CONFIG_OVERRIDE="$PARENT/config" FM_SPAWN_NO_GUARD=1 \
  bash "$ROOT/bin/fm-spawn.sh" "$SECOND_ID" "$SECOND" dsh --secondmate --backend herdr --model deepseek/deepseek-v4-flash --effort high > "$HOLD/spawn.out" 2>&1 &
SPAWN_PID=$!
for _ in $(seq 1 120); do
  [ -e "$HOLD/reached" ] && break
  sleep 1
done
[ -e "$HOLD/reached" ] || { cat "$HOLD/spawn.out"; echo 'the secondmate session start never reached the lab barrier' >&2; exit 1; }
sleep 5
grep -q '"event":"startup"' "$SECOND/state/.dsh-primary-events.jsonl" || { echo 'the held secondmate plugin never recorded its startup' >&2; exit 1; }
! grep -q "^spawned $SECOND_ID " "$HOLD/spawn.out" || { echo 'the spawn reported started while its session start was held' >&2; exit 1; }
python3 - "$PARENT/state/$SECOND_ID.dsh-session" <<'PY'
import json,sys
from pathlib import Path
root=Path(json.load(open(sys.argv[1]))['root'])
assert root.is_dir(), 'the held spawn must have prepared its runtime'
logs=sorted((root/'dsh'/'sessions').glob('*/*/session.v*.jsonl'))
for log in logs:
    types=[json.loads(line).get('type') for line in open(log) if line.strip()]
    assert 'turn/start' not in types and 'user/message' not in types, f'{log} holds a turn while the session start is held'
print('held: durable session logs=%d, none with a turn or user message; spawn not yet reported started' % len(logs))
PY
echo release > "$HOLD/release"
wait "$SPAWN_PID" || { cat "$HOLD/spawn.out"; echo 'the secondmate spawn failed after its session start was released' >&2; exit 1; }
grep "^spawned $SECOND_ID " "$HOLD/spawn.out" || { cat "$HOLD/spawn.out"; echo 'the released spawn never reported started' >&2; exit 1; }
echo 'ok - held session start: no turn and no started report; released: start proof and composer check passed'
SECOND_LOG=$(python3 "$ROOT/bin/fm-dsh.py" session-file "$PARENT/state" "$SECOND_ID")
[ "$(sed -n 's/^backend=//p' "$PARENT/state/$SECOND_ID.meta")" = herdr ] && [ "$(sed -n 's/^herdr_session=//p' "$PARENT/state/$SECOND_ID.meta")" = "$SESSION" ] || { echo 'the secondmate spawn left the named Herdr lab' >&2; exit 1; }
SECOND_PANE=$(sed -n 's/^herdr_pane_id=//p' "$PARENT/state/$SECOND_ID.meta")
LOG="$SECOND_LOG" PANE="$SECOND_PANE" wait_reply FMSECONDREADY
control "$SECOND_ID" relaunch --harness dsh --model deepseek/deepseek-v4-flash --effort high --note 'Reply FMSECONDRESUMED and the secret word from the earlier conversation. Do not inspect files, investigate, load skills or dispatch work.'
[ "$(python3 "$ROOT/bin/fm-dsh.py" session-file "$PARENT/state" "$SECOND_ID")" = "$SECOND_LOG" ]
LOG="$SECOND_LOG" PANE="$SECOND_PANE" wait_reply 'FMSECONDRESUMED TULIP42'
control "$SECOND_ID" exit
cp "$SECOND/state/.dsh-primary-events.jsonl" "$TASK/dsh-secondmate-events.jsonl"
python3 - "$SECOND_LOG" <<'PY'
import json,sys
before=[]
for line in open(sys.argv[1]):
    try: event=json.loads(line)
    except ValueError: continue
    if event.get('type')=='assistant/message': break
    if event.get('type')=='user/message':
        before.append('\n'.join(part.get('text','') for part in event['data'].get('content',[]) if part.get('type')=='text'))
assert before and 'Mode: DSH native Cordis supervision.' in before[0], 'the secondmate startup digest must be the first user message'
assert any('TULIP42' in words for words in before[1:]), 'the secondmate brief must follow the digest before any reply'
print('ok - fresh dsh-tui secondmate spawn into a new home, digest ahead of its brief, same-conversation relaunch and exit')
PY
