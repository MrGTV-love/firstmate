#!/usr/bin/env bash
# Launch proof: live kernel environment pins and conservative foreground identity.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP=$(fm_test_tmproot fm-launch-proof)
PID=
cleanup() { [ -z "$PID" ] || kill "$PID" 2>/dev/null || true; fm_test_cleanup; }
trap cleanup EXIT
export FM_HOME="$TMP/home"
mkdir -p "$FM_HOME/state"
export HOME="$TMP/operator-home"
mkdir -p "$HOME"
. "$ROOT/bin/fm-backend.sh"
. "$ROOT/bin/fm-control-lib.sh"
. "$ROOT/bin/fm-launch-proof-lib.sh"
. "$ROOT/bin/fm-dod-lib.sh"
. "$ROOT/bin/fm-operational-input.sh"
start_probe() {
  rm -f "$TMP/ready"
  FM_SPAWN_GEN=$1 FM_PROOF_NOTE=${3:-} python3 -c 'import pathlib,signal,sys; pathlib.Path(sys.argv[1]).touch(); signal.pause()' "$TMP/ready" "${2:-}" &
  PID=$!
  fm_test_record_process "$TMP/probe-$PID.process" "$PID" || fail 'could not record launch-proof probe identity'
  fm_test_track_process "$TMP/probe-$PID.process" "$TMP/ready"
  for _ in $(seq 1 200); do
    [ ! -f "$TMP/ready" ] || return 0
    sleep 0.01
  done
  fail 'process environment probe did not start'
}
stop_probe() {
  kill "$PID"
  wait "$PID" 2>/dev/null || true
  PID=
}

# No real PID or endpoint is read: each ps query must match the synthetic PID.
test_launch_proof_omp_executable_identity() (
  local synthetic_comm synthetic_args
  ps() {
    case "$*" in
      '-p 2000000000 -o comm=') printf '%s\n' "$synthetic_comm" ;;
      '-p 2000000000 -o args=') printf '%s\n' "$synthetic_args" ;;
      *) fail "unexpected identity ps query: $*" ;;
    esac
  }
  assert_identity() { # <expected> <comm> <args> <description>
    local expected=$1 actual=refuse
    synthetic_comm=$2 synthetic_args=$3
    if fm_launch_proof_pid_is_omp 2000000000; then actual=accept; fi
    assert_equals "$expected" "$actual" "$4"
  }
  assert_identity accept omp 'omp --resume=task' 'bare omp is accepted'
  assert_identity accept omp 'bun --resume=task' 'readable omp name alone is sufficient'
  assert_identity accept bun 'omp --resume=task' 'omp argv[0] alone is sufficient'
  assert_identity accept /Users/operator/.bun/bin/omp 'bun --resume=task' 'Bun-installed omp executable name is accepted'
  assert_identity accept bun '/Users/operator/.bun/bin/omp --resume=task' 'Bun-installed omp argv[0] is accepted'
  assert_identity refuse python3 'python3 -c input()' 'unrelated executable is refused'
  assert_identity refuse /opt/omp/bin/python3 'python3 -c input()' 'omp directory in executable path is refused'
  assert_identity refuse python3 '/opt/omp/bin/python3 -c input()' 'omp directory in argv[0] is refused'
  assert_identity refuse bun 'bun /opt/bin/omp' 'omp in a later argument is not argv[0]'
  assert_identity refuse ompd 'ompd --resume=task' 'omp executable name must be exact'
  pass 'omp identity uses only the executable basename or argv[0], including Bun-installed entry points'
)

test_launch_proof_pinned_personal_switch() {
  local meta="$FM_HOME/state/pinned.meta" task="$TMP/task.jsonl" personal="$TMP/personal.jsonl"
  local SWITCH_INFO actual
  start_probe expected
  printf 'task session\n' > "$task"
  printf 'personal session\n' > "$personal"
  printf 'window=lab:w1:p1\nharness=omp\nworktree=%s\nspawn_gen=expected\nlaunch_proof=env-v1\n' "$TMP" > "$meta"
  SWITCH_INFO=$(jq -nc --argjson pid "$PID" --arg cwd "$TMP" --arg task "$task" '
    {result:{type:"pane_process_info",process_info:{pane_id:"w1:p1",
      foreground_processes:[{argv:["omp",("--resume="+$task)],pid:$pid,cwd:$cwd}]}}}')
  fm_backend_herdr_cli() {
    case "$*" in
      'lab pane process-info --pane w1:p1') printf '%s' "$SWITCH_INFO" ;;
      *) printf '%s\n' "$*" >> "$TMP/endpoint-violations"; return 1 ;;
    esac
  }
  jq -nc --arg gen expected --argjson pid "$PID" --arg task "$task" \
    '{version:1,spawn_gen:$gen,pid:$pid,task_session_file:$task,current_session_file:$task}' \
    > "$FM_HOME/state/pinned.omp-session.json"
  [ "$(fm_launch_proof_herdr "$meta")" = managed ] || fail 'matching pinned task and current session must be managed'
  jq --arg personal "$personal" '.current_session_file=$personal' "$FM_HOME/state/pinned.omp-session.json" \
    > "$FM_HOME/state/pinned.omp-session.json.next"
  mv "$FM_HOME/state/pinned.omp-session.json.next" "$FM_HOME/state/pinned.omp-session.json"
  actual=$(fm_launch_proof_herdr "$meta")
  [ "$actual" = unmanaged ] || fail "same live PID retains its real kernel pin after personal switch: expected unmanaged, got $actual"
  proof_record() {
    jq -nc --arg gen "${1:-expected}" --argjson pid "${2:-$PID}" \
      --arg task "$task" --arg current "${3:-$task}" \
      '{version:1,spawn_gen:$gen,pid:$pid,task_session_file:$task,current_session_file:$current}' \
      > "$FM_HOME/state/pinned.omp-session.json"
  }
  proof_record other
  [ "$(fm_launch_proof_herdr "$meta")" = unmanaged ] || fail 'stale sidecar generation must not authenticate a live matching pin'
  proof_record expected 2000000000
  [ "$(fm_launch_proof_herdr "$meta")" = unmanaged ] || fail 'proof from another PID must not authenticate the selected process'
  proof_record expected "$PID" ''
  jq '.current_session_file=null' "$FM_HOME/state/pinned.omp-session.json" > "$TMP/invalidated"
  mv "$TMP/invalidated" "$FM_HOME/state/pinned.omp-session.json"
  [ "$(fm_launch_proof_herdr "$meta")" = unmanaged ] || fail 'shutdown-invalidated current session must not authenticate a retained pin'
  printf 'malformed\n' > "$FM_HOME/state/pinned.omp-session.json"
  [ "$(fm_launch_proof_herdr "$meta")" = unmanaged ] || fail 'malformed sidecar must not authenticate a matching pin'
  rm "$FM_HOME/state/pinned.omp-session.json"
  [ "$(fm_launch_proof_herdr "$meta")" = unmanaged ] || fail 'missing current-session proof must not authenticate a matching pin'
  ln -s "$task" "$TMP/task-link.jsonl"
  proof_record expected "$PID" "$TMP/task-link.jsonl"
  [ "$(fm_launch_proof_herdr "$meta")" = managed ] || fail 'resolved current and task session paths must identify the same file'
  [ ! -e "$TMP/endpoint-violations" ] \
    || fail "pinned switch must inspect only its recorded endpoint: $(cat "$TMP/endpoint-violations")"
  stop_probe
  pass 'serialized current-session proof rejects a same-PID pinned personal switch'
}

test_launch_proof_recorded_native_identity() {
  start_probe ''
  [ "$(fm_launch_proof_pid "$PID" expected)" = unmanaged ] || fail 'readable bare process must be unmanaged'
  [ "$(fm_launch_proof_pid "$PID" '')" = unmanaged ] || fail 'missing recorded incarnation must be unmanaged'
  stop_probe
  start_probe '' 'FM_SPAWN_GEN=expected'
  [ "$(fm_launch_proof_pid "$PID" expected)" = unmanaged ] || fail 'argv text must not impersonate a launch environment pin'
  stop_probe
  start_probe '' '' 'ordinary value FM_SPAWN_GEN=expected'
  [ "$(fm_launch_proof_pid "$PID" expected)" = unmanaged ] || fail 'text inside another environment value must not impersonate a launch pin'
  stop_probe
  start_probe '' '' $'ordinary value\nFM_SPAWN_GEN=expected'
  [ "$(fm_launch_proof_pid "$PID" expected)" = unmanaged ] || fail 'an embedded multiline value must not authenticate a launch pin'
  stop_probe
  start_probe expected '' $'ordinary value\nFM_SPAWN_GEN=spoof'
  [ "$(fm_launch_proof_pid "$PID" expected)" = managed ] || fail 'an unrelated multiline value must not invalidate a genuine launch pin'
  stop_probe
  start_probe $'expected\nFM_SPAWN_GEN=spoof'
  [ "$(fm_launch_proof_pid "$PID" expected)" = unknown ] || fail 'a line-breaking launch marker must refuse attribution'
  stop_probe
  start_probe expected
  [ "$(fm_launch_proof_pid "$PID" expected)" = managed ] || fail 'live matching incarnation must be managed'
  [ "$(fm_launch_proof_pid "$PID" different)" = unmanaged ] || fail 'another incarnation must not authenticate this launch'
  [ "$(fm_launch_proof_pid "$PID" '')" = unmanaged ] || fail 'a live pin without its recorded generation must not authenticate'
  gone_pid=$PID
  stop_probe
  [ "$(fm_launch_proof_pid "$gone_pid" expected)" = unknown ] || fail 'gone process must never authorize lifecycle action'
  pass 'live process environment distinguishes matching pins, missing records, mismatches and unavailable proof'

  META="$FM_HOME/state/t.meta"
  WORKTREE="$TMP/worktree"
  mkdir -p "$WORKTREE" "$FM_HOME/data/t"
  proof_meta() {
    printf 'window=lab:w1:p1\nharness=%s\nworktree=%s\nspawn_gen=%s\n' "$1" "$WORKTREE" "${3:-expected}" > "$META"
    [ -z "${2:-}" ] || printf 'launch_proof=%s\n' "$2" >> "$META"
    if [ "$1" = omp ]; then
      : > "$WORKTREE/task-proof.jsonl"
      jq -nc --arg gen "${3:-expected}" --argjson pid "$PID" --arg task "$WORKTREE/task-proof.jsonl" \
        '{version:1,spawn_gen:$gen,pid:$pid,task_session_file:$task,current_session_file:$task}' \
        > "$FM_HOME/state/t.omp-session.json"
    else
      rm -f "$FM_HOME/state/t.omp-session.json"
    fi
  }
  INFO=
  fm_backend_herdr_cli() {
    case "$*" in
      'lab pane process-info --pane w1:p1') printf '%s' "$INFO" ;;
      'lab pane get w1:p1') printf '{"result":{"pane":{"pane_id":"w1:p1"}}}' ;;
      'lab agent get w1:p1') printf '{"error":{"code":"agent_not_found"}}' ;;
      *) printf '%s\n' "$*" >> "$TMP/endpoint-violations"; return 1 ;;
    esac
  }
  PARENTS=
  ps() {
    if [ "$*" = '-axo pid=,ppid=' ] && [ -n "$PARENTS" ]; then
      printf '%s\n' "$PARENTS"
    else
      command ps "$@"
    fi
  }
  process() { # <argv-json> [pid]
    INFO=$(jq -nc --argjson argv "$1" --argjson pid "${2:-$PID}" --arg cwd "$WORKTREE" '
      {result:{type:"pane_process_info",process_info:{pane_id:"w1:p1",
        foreground_processes:[{argv:$argv,pid:$pid,cwd:$cwd}]}}}')
  }
  assert_proof() {
    [ "$(fm_launch_proof_herdr "$META")" = "$1" ] || fail "$2"
    [ ! -e "$TMP/endpoint-violations" ] \
      || fail "launch proof must inspect only its recorded endpoint: $(cat "$TMP/endpoint-violations")"
  }

  start_probe expected
  for version in legacy env-v1; do
    for harness in $(fm_control_harnesses) claude-custom omp-custom unrecognized; do
      proof_meta "$harness"
      [ "$version" != env-v1 ] || proof_meta "$harness" env-v1
      process '["node","/installed/agent.js"]'
      assert_proof managed "$version matching live PID pin must remain managed for recorded $harness"
      proof_meta "$harness" "${version#legacy}" different
      process '["node","/installed/agent.js"]'
      expected=unknown
      [ "$harness" != omp ] || expected=unmanaged
      assert_proof "$expected" "$version mismatched live PID pin must never authenticate recorded $harness"
    done
  done
  proof_meta omp env-v2
  assert_proof unknown 'matching incarnation must not bypass an unsupported proof boundary'
  proof_meta omp env-v1
  process '["node","/installed/agent.js"]'
  PARENTS=$(printf '%s 1\n2 %s\n' "$PID" "$PID")
  INFO=$(printf '%s' "$INFO" | jq --argjson pid "$PID" '
    .result.process_info.foreground_process_group_id = $pid
    | .result.process_info.foreground_processes =
      [{argv:["helper"],pid:2}] + .result.process_info.foreground_processes')
  assert_proof managed 'kernel pin must support interpreter-based agents with foreground helpers'
  INFO=$(printf '%s' "$INFO" | jq '.result.process_info.foreground_process_group_id = 999
    | .result.process_info.foreground_processes += [{pid:999,name:"bash",argv0:"sh",argv:["sh"]}]')
  PARENTS=$(printf '%s 999\n999 1\n2 %s\n' "$PID" "$PID")
  assert_proof managed 'a launcher shell must not hide the pinned primary agent'
  INFO=$(printf '%s' "$INFO" | jq '.result.process_info.foreground_process_group_id = 2')
  assert_proof unknown 'a marked child must not authenticate an unreadable foreground leader'
  PARENTS=
  process '["omp","--resume=recorded"]' 2000000000
  assert_proof unknown 'pin evidence from another live PID must never authenticate the foreground process'
  stop_probe
  pass 'recorded generation binds the positively identified live PID across harnesses, shells and helpers'

  # Herdr lists the foreground first and the process table is read after it, so a
  # short-lived non-agent child (cat) can be listed yet gone from the table.
  start_probe expected
  proof_meta claude env-v1
  CAT='{"pid":3,"name":"cat","argv0":"cat","argv":["cat"]}'
  OTHER='{"pid":5,"name":"omp","argv0":"omp","argv":["omp"]}'
  SHELL_LEADER='{"pid":999,"name":"bash","argv0":"sh","argv":["sh"]}'
  foreground() { # <group> <extra-process-json>...  (the pinned agent is always listed)
    local group=$1 extra
    shift
    extra=$(printf '%s\n' "$@" | jq -sc '.')
    INFO=$(jq -nc --argjson pid "$PID" --arg cwd "$WORKTREE" --argjson group "$group" --argjson extra "$extra" '
      {result:{type:"pane_process_info",process_info:{pane_id:"w1:p1",foreground_process_group_id:$group,
        foreground_processes:([{argv:["node","/installed/agent.js"],pid:$pid,cwd:$cwd}] + $extra)}}}')
  }
  attributed() { # <message>: the unique agent pid, not merely any verdict
    local got
    got=$(fm_launch_proof_herdr_pid "$META") || fail "$1"
    [ "$got" = "$PID" ] || fail "$1: attributed $got instead of the agent $PID"
  }
  unattributed() { # <message>
    ! fm_launch_proof_herdr_pid "$META" >/dev/null || fail "$1"
  }
  foreground "$PID" "$CAT"
  PARENTS=$(printf '%s 1\n3 %s\n' "$PID" "$PID")
  attributed 'a normal pane with a present non-agent child must still attribute the agent'
  PARENTS=$(printf '%s 1\n' "$PID")
  attributed 'a non-agent child gone from the process table must not fail attribution'
  assert_proof managed 'a vanished non-agent child must leave the pinned agent managed'
  foreground "$PID" "$CAT" '{"pid":4,"name":"cat","argv0":"cat","argv":["cat"]}'
  attributed 'several vanished non-agent children must not fail attribution'
  foreground 999 "$SHELL_LEADER" "$CAT"
  PARENTS=$(printf '999 1\n%s 999\n' "$PID")
  attributed 'a vanished child beside a launcher shell must not hide the pinned agent'
  foreground "$PID" "$CAT"
  PARENTS=$(printf '4242 1\n3 %s\n' "$PID")
  unattributed 'an agent gone from the process table must not hand attribution to its child'
  PARENTS=$(printf '4242 1\n')
  unattributed 'an agent and its child both gone from the process table must still refuse attribution'
  assert_proof unknown 'an unattributable agent must stay unknown'
  foreground 999 "$SHELL_LEADER" "$CAT"
  PARENTS=$(printf '999 1\n3 %s\n' "$PID")
  unattributed 'a launcher-shell agent gone from the process table must not hand attribution to its child'
  PARENTS=$(printf '999 1\n')
  unattributed 'a launcher-shell agent and its child both gone must still refuse attribution'
  PARENTS=$(printf '999 1\n%s 77\n' "$PID")
  unattributed 'an agent whose chain to the group leader is broken must still refuse attribution'
  foreground 999 "$SHELL_LEADER" "$OTHER"
  PARENTS=$(printf '999 1\n%s 999\n5 999\n' "$PID")
  unattributed 'two agent candidates must still refuse attribution'
  foreground 999 "$SHELL_LEADER" "$OTHER" "$CAT"
  unattributed 'a vanished child must not make two agent candidates unique'
  PARENTS=
  stop_probe
  pass 'a non-agent child that vanished between the two process reads no longer fails agent attribution'

  start_probe ''
  BRIEF="$(fm_brief_worker_role "$FM_HOME/state" t "$ROOT")"$'\n\nTask assigned by Firstmate.'
  fm_operational_input_encode launch-brief "$BRIEF" MESSAGE
  jq -nc --arg cwd "$WORKTREE" '{type:"session",version:3,id:"recorded",cwd:$cwd}' > "$WORKTREE/recorded.jsonl"
  # shellcheck disable=SC2153 # MESSAGE is assigned by name by fm_operational_input_encode.
  jq -nc --arg text "$MESSAGE" '{type:"message",message:{role:"user",content:[{type:"text",text:$text}]}}' \
    >> "$WORKTREE/recorded.jsonl"
  cp "$WORKTREE/recorded.jsonl" "$WORKTREE/startup.jsonl"
  jq -nc --arg cwd "$WORKTREE" '{type:"session",version:3,id:"personal",cwd:$cwd}' > "$WORKTREE/personal.jsonl"
  jq -nc '{type:"message",message:{role:"user",content:"personal prompt"}}' >> "$WORKTREE/personal.jsonl"
  for version in legacy env-v1; do
    cp "$WORKTREE/startup.jsonl" "$WORKTREE/recorded.jsonl"
    proof_meta omp
    [ "$version" != env-v1 ] || proof_meta omp env-v1
    process "[\"omp\",\"--resume=$WORKTREE/recorded.jsonl\"]"
    assert_proof unmanaged "$version native restore with exact task-owned startup must remain unmanaged"
    for argv in '["omp"]' '["omp","--resume","recorded"]' \
      '["omp","--resume="]' '["omp","--config","overlay","--resume=recorded"]' \
      '["/installed/bin/omp","personal prompt"]' '["node","/installed/omp/entry.js","--resume=recorded"]'; do
      process "$argv"
      assert_proof unmanaged "$version argv must not replace a missing live spawn pin"
    done
    process "[\"omp\",\"--resume=$WORKTREE/recorded.jsonl\"]"
    INFO=$(printf '%s' "$INFO" | jq 'del(.result.process_info.foreground_processes[0].cwd)')
    assert_proof unmanaged "$version cwd must not replace a missing live spawn pin"
    printf 'malformed native session\n' > "$WORKTREE/recorded.jsonl"
    assert_proof unmanaged "$version session-file contents must not replace a missing live spawn pin"
    rm "$WORKTREE/recorded.jsonl"
    assert_proof unmanaged "$version missing native session file must remain unmanaged"
  done
  proof_meta omp env-v1 ''
  printf 'spawn_gen=\n' >> "$META"
  assert_proof unmanaged 'missing generation must not fall back to native launch attribution'
  proof_meta claude env-v1
  process '["claude","--resume","foreign"]'
  assert_proof unknown 'missing incarnation for another harness must stay unknown'
  proof_meta omp env-v2
  assert_proof unknown 'unsupported proof version must never fall back to native argv'
  proof_meta omp env-v1
  process '["omp","--resume=recorded"]'
  INFO=$(printf '%s' "$INFO" | jq '.result.process_info.foreground_processes += .result.process_info.foreground_processes')
  assert_proof unknown 'duplicate foreground identity must refuse attribution'
  process '["omp","--resume=recorded"]'
  INFO=$(printf '%s' "$INFO" | jq '.result.process_info.pane_id = "foreign"')
  assert_proof unknown 'mismatched endpoint must stay unknown'
  process '["omp","--resume=recorded"]'
  INFO=$(printf '%s' "$INFO" | jq '.result.process_info.foreground_processes = []')
  assert_proof unknown 'missing foreground identity must stay unknown'
  stop_probe
  pass 'native restoration stays unmanaged without argv, cwd or initial-message shortcuts'
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
  exit 0
fi
test_launch_proof_omp_executable_identity
test_launch_proof_recorded_native_identity
test_launch_proof_pinned_personal_switch
