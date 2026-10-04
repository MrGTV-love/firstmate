#!/usr/bin/env bash
# Launch proof: live kernel environments, exact native-resume boundaries, and
# conservative refusal on ambiguous or unavailable process identity.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP=$(mktemp -d)
PID=
cleanup() { [ -z "$PID" ] || kill "$PID" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export FM_HOME="$TMP/home"
mkdir -p "$FM_HOME/state"
. "$ROOT/bin/fm-backend.sh"
. "$ROOT/bin/fm-launch-proof-lib.sh"
start_probe() {
  rm -f "$TMP/ready"
  FM_SPAWN_GEN=$1 python3 -c 'import pathlib,sys,time; pathlib.Path(sys.argv[1]).touch(); time.sleep(120)' "$TMP/ready" &
  PID=$!
  for _ in $(seq 1 200); do
    [ ! -f "$TMP/ready" ] || return 0
    sleep 0.01
  done
  fail 'process environment probe did not start'
}
start_probe ''
[ "$(fm_launch_proof_pid "$PID" expected)" = unmanaged ] || fail 'readable bare process must be unmanaged'
kill "$PID"; wait "$PID" 2>/dev/null || true
start_probe expected
[ "$(fm_launch_proof_pid "$PID" expected)" = managed ] || fail 'live matching incarnation must be managed'
[ "$(fm_launch_proof_pid "$PID" different)" = unmanaged ] || fail 'another incarnation must not authenticate this launch'
kill "$PID"; wait "$PID" 2>/dev/null || true
[ "$(fm_launch_proof_pid "$PID" expected)" = unknown ] || fail 'gone process must never authorize recovery'
PID=
pass 'live process environment distinguishes managed, missing, mismatched, and gone launches'

META="$FM_HOME/state/t.meta"
printf 'window=lab:w1:p1\nharness=omp\n' > "$META"
INFO=
fm_backend_herdr_cli() { printf '%s' "$INFO"; }
PARENTS=
ps() {
  if [ "$*" = '-axo pid=,ppid=' ] && [ -n "$PARENTS" ]; then
    printf '%s\n' "$PARENTS"
  else
    command ps "$@"
  fi
}
process() { # <argv-json> [pid]
  INFO=$(jq -nc --argjson argv "$1" --argjson pid "${2:-2}" '
    {result:{type:"pane_process_info",process_info:{pane_id:"w1:p1",
      foreground_processes:[{argv:$argv,pid:$pid}]}}}')
}
assert_proof() { [ "$(fm_launch_proof_herdr "$META")" = "$1" ] || fail "$2"; }
process '["omp","--resume=/a/session.jsonl"]'
assert_proof unmanaged 'bare restored omp must be recoverable'
process '["omp","--config","overlay","--auto-approve","--resume=/a/session.jsonl"]'
assert_proof unknown 'legacy absence must not restart a configured resume'
process '["omp","--resume="]'
assert_proof unknown 'empty resume identity must not authorize recovery'
process '["omp","a prompt mentioning --resume=/a/session.jsonl"]'
assert_proof unknown 'quoted resume text must not count as a restored launch'
process '["claude","--resume","foreign"]'
assert_proof unknown 'foreign foreground agent must not authorize recorded omp recovery'
INFO='{"result":{"type":"pane_process_info","process_info":{"pane_id":"foreign","foreground_processes":[]}}}'
assert_proof unknown 'mismatched endpoint must stay unknown'
process '["omp","--resume=/a/session.jsonl"]'
INFO=$(printf '%s' "$INFO" | jq '.result.process_info.foreground_processes += .result.process_info.foreground_processes')
assert_proof unknown 'two foreground agents must refuse recovery'
pass 'native resume proof requires exact recorded harness, endpoint and bare argv'

process '["omp","--resume=/a/session.jsonl"]' 200
PARENTS=$'200 1\n201 200'
INFO=$(printf '%s' "$INFO" | jq '.result.process_info.foreground_process_group_id = 200
  | .result.process_info.foreground_processes =
    [{argv:["omp","__omp_worker_mnemopi_embed"],pid:201}] + .result.process_info.foreground_processes')
assert_proof unmanaged 'foreground helpers must not hide the bare restored group leader'
INFO=$(printf '%s' "$INFO" | jq '.result.process_info.foreground_process_group_id = 999')
assert_proof unknown 'a missing group leader must not be inferred from its children'

start_probe expected
printf 'window=lab:w1:p1\nharness=omp\nlaunch_proof=env-v1\nspawn_gen=expected\n' > "$META"
process '["node","/installed/agent.js"]' "$PID"
PARENTS=$(printf '%s 1\n2 %s\n' "$PID" "$PID")
INFO=$(printf '%s' "$INFO" | jq --argjson pid "$PID" '
  .result.process_info.foreground_process_group_id = $pid
  | .result.process_info.foreground_processes =
    [{argv:["helper"],pid:2}] + .result.process_info.foreground_processes')
assert_proof managed 'kernel launch proof must support interpreter-based agents with foreground helpers'
INFO=$(printf '%s' "$INFO" | jq '.result.process_info.foreground_process_group_id = 999
  | .result.process_info.foreground_processes += [{pid:999,name:"bash",argv0:"sh",argv:["sh"]}]')
PARENTS=$(printf '%s 999\n999 1\n2 %s\n' "$PID" "$PID")
assert_proof managed 'a launcher shell must not hide the marked primary agent'
INFO=$(printf '%s' "$INFO" | jq '.result.process_info.foreground_process_group_id = 2')
assert_proof unknown 'a marked child must never authenticate an unreadable foreground leader'
kill "$PID"; wait "$PID" 2>/dev/null || true
PID=
PARENTS=
pass 'foreground agent ancestry owns launch proof, independently of shells, helpers and executable packaging'

for tuple in 'pi --session' 'pi-signed --session' 'claude --resume' 'codex resume' 'agy --conversation' 'cursor --resume' 'grok --resume' 'kimi --session' 'opencode --session' 'devin --resume'; do
  read -r harness flag <<< "$tuple"
  printf 'window=lab:w1:p1\nharness=%s\n' "$harness" > "$META"
  binary=$harness
  [ "$harness" != pi-signed ] || binary=pi
  [ "$harness" != cursor ] || binary=cursor-agent
  process "$(jq -nc --arg b "$binary" --arg f "$flag" '[$b,$f,"session-ref"]')"
  assert_proof unmanaged "bare native $harness resume must be recoverable"
done
pass 'legacy native restoration is attributed across Herdr supported resume adapters'

mkdir -p "$TMP/native/bin" "$TMP/native/pkg"
printf '#!/usr/bin/env node\n' > "$TMP/native/pkg/entry.js"
chmod +x "$TMP/native/pkg/entry.js"
ln -s ../pkg/entry.js "$TMP/native/bin/pi"
export PATH="$TMP/native/bin:$PATH"
for harness in pi pi-signed; do
  printf 'window=lab:w1:p1\nharness=%s\n' "$harness" > "$META"
  process "$(jq -nc --arg script "$TMP/native/pkg/entry.js" '["node",$script,"--session","session-ref"]')"
  assert_proof unmanaged "native $harness interpreter must resolve to its installed entry point"
  process "$(jq -nc --arg script "$TMP/native/pkg/entry.js" '["node",$script,"--config","overlay","--session","session-ref"]')"
  assert_proof unknown 'configured interpreter launch must not be mistaken for a bare restore'
done
printf '#!/usr/bin/env node\n' > "$TMP/native/pkg/foreign.js"
process "$(jq -nc --arg script "$TMP/native/pkg/foreign.js" '["node",$script,"--session","session-ref"]')"
assert_proof unknown 'an unrelated script with resume arguments must not authenticate the recorded adapter'
printf 'window=lab:w1:p1\nharness=cursor\n' > "$META"
process '["agent","--resume","session-ref"]'
assert_proof unknown 'a generic agent executable supplies no Cursor ownership evidence'
pass 'legacy shebang entry points follow the installed CLI symlink, while foreign scripts and generic agent names refuse'
