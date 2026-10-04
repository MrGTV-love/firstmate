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
process '["omp","--resume","/a/session.jsonl"]'
assert_proof unknown 'split omp resume arguments must not authorize native restoration recovery'
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

printf 'window=lab:w1:p1\nharness=codex\n' > "$META"
process '["codex","resume","session-ref"]'
assert_proof unknown 'legacy non-omp resume must not authorize recovery'
printf 'window=lab:w1:p1\nharness=omp\n' > "$META"
process '["node","/installed/omp/entry.js","--resume=session-ref"]'
assert_proof unknown 'legacy node entry points must not authorize omp recovery'
process '["python3","/installed/omp/entry.py","--resume=session-ref"]'
assert_proof unknown 'legacy Python entry points must not authorize omp recovery'
process '["/installed/omp/versions/1.0","--resume=session-ref"]'
assert_proof unknown 'legacy omp path components must not replace exact executable identity'
process '["omp","--resume=session-ref"]'
INFO=$(printf '%s' "$INFO" | jq '.result.process_info.foreground_processes[0].name = "node"')
assert_proof unknown 'a reported interpreter must not authenticate legacy omp argv'
process '["omp","--resume=session-ref"]'
INFO=$(printf '%s' "$INFO" | jq '.result.process_info.foreground_processes[0].argv0 = "python3"')
assert_proof unknown 'a reported interpreter argv0 must not authenticate legacy omp argv'
process '["/installed/bin/omp","--resume=session-ref"]'
assert_proof unmanaged 'an exact omp executable basename and equals-form resume must remain recoverable'
printf 'window=lab:w1:p1\nharness=omp\nlaunch_proof=env-v2\n' > "$META"
assert_proof unknown 'an unsupported proof boundary must not fall back to legacy argv'
pass 'legacy recovery is limited to exact compiled omp equals-form resume'

start_probe expected
printf 'window=lab:w1:p1\nharness=omp\nlaunch_proof=env-v1\nspawn_gen=different\n' > "$META"
process '["node","/foreign/agent.js"]' "$PID"
assert_proof unknown 'a mismatched incarnation must not authorize foreign interpreter recovery'
process '["omp","a prompt"]' "$PID"
assert_proof unmanaged 'a mismatched incarnation must remain recoverable for attributed omp'
for harness in $(fm_control_harnesses) claude-custom omp-custom unrecognized; do
  [ "$harness" != omp ] || continue
  printf 'window=lab:w1:p1\nharness=%s\nlaunch_proof=env-v1\nspawn_gen=different\n' "$harness" > "$META"
  process "[\"$harness\",\"a prompt\"]" "$PID"
  assert_proof unknown "a mismatched incarnation must not authorize recorded $harness recovery"
  printf 'window=lab:w1:p1\nharness=%s\nlaunch_proof=env-v1\nspawn_gen=expected\n' "$harness" > "$META"
  process '["node","/installed/agent.js"]' "$PID"
  assert_proof managed "matching incarnation must remain managed for recorded $harness"
done
kill "$PID"; wait "$PID" 2>/dev/null || true
start_probe ''
printf 'window=lab:w1:p1\nharness=omp\nlaunch_proof=env-v1\nspawn_gen=expected\n' > "$META"
process '["python3","/foreign/script.py"]' "$PID"
assert_proof unknown 'unmarked foreign Python must not authorize recorded omp recovery'
process '["node","/foreign/agent.js"]' "$PID"
assert_proof unknown 'unmarked foreign node must not authorize recorded omp recovery'
process '["claude","--resume","foreign"]' "$PID"
assert_proof unknown 'unmarked foreign Claude must not authorize recorded omp recovery'
process '["unknown-agent"]' "$PID"
assert_proof unknown 'unmarked unknown executable must not authorize recovery'
process '["omp","a prompt"]' "$PID"
assert_proof unmanaged 'unmarked attributed omp argv fallback must authorize recovery'
process '["/installed/bin/omp","a prompt"]' "$PID"
assert_proof unmanaged 'unmarked attributed omp executable path must authorize recovery'
process '["node","/installed/agent.js"]' "$PID"
INFO=$(printf '%s' "$INFO" | jq '.result.process_info.foreground_processes[0].name = "omp"')
assert_proof unmanaged 'unmarked recorded omp process name must supply attribution'
printf 'window=lab:w1:p1\nharness=claude-custom\nlaunch_proof=env-v1\nspawn_gen=expected\n' > "$META"
process '["/installed/claude/versions/1.0","a prompt"]' "$PID"
assert_proof unknown 'unmarked recorded Claude must not authorize unmanaged recovery'
process '["omp","a prompt"]' "$PID"
assert_proof unknown 'an attributed but different harness family must not authorize recovery'
printf 'window=lab:w1:p1\nharness=unrecognized\nlaunch_proof=env-v1\nspawn_gen=expected\n' > "$META"
assert_proof unknown 'an unsupported recorded harness must not authorize recovery'
for harness in $(fm_control_harnesses) omp-custom; do
  [ "$harness" != omp ] || continue
  printf 'window=lab:w1:p1\nharness=%s\nlaunch_proof=env-v1\nspawn_gen=expected\n' "$harness" > "$META"
  process "[\"$harness\",\"a prompt\"]" "$PID"
  assert_proof unknown "missing incarnation must not authorize recorded $harness recovery"
done
kill "$PID"; wait "$PID" 2>/dev/null || true
PID=
pass 'env-v1 unmanaged recovery requires recorded omp attribution while matching pins remain managed for every harness'
