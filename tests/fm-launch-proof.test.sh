#!/usr/bin/env bash
# Launch proof: live kernel environment pins and conservative foreground identity.
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
. "$ROOT/bin/fm-control-lib.sh"
. "$ROOT/bin/fm-launch-proof-lib.sh"
. "$ROOT/bin/fm-dod-lib.sh"
. "$ROOT/bin/fm-operational-input.sh"
start_probe() {
  rm -f "$TMP/ready"
  FM_SPAWN_GEN=$1 FM_PROOF_NOTE=${3:-} python3 -c 'import pathlib,sys,time; pathlib.Path(sys.argv[1]).touch(); time.sleep(120)' "$TMP/ready" "${2:-}" &
  PID=$!
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
  [ "$(fm_launch_proof_pid "$PID" expected)" = unknown ] || fail 'an ambiguous multiline environment must not authenticate a launch pin'
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
  }
  INFO=
  ACTIVE_SESSION_REF=
  fm_backend_herdr_cli() {
    case "$*" in
      'lab pane process-info --pane w1:p1') printf '%s' "$INFO" ;;
      'lab agent get --pane w1:p1') jq -nc --arg ref "$ACTIVE_SESSION_REF" '{result:{agent:{session_ref:$ref}}}' ;;
      *) fail 'launch proof must inspect only its recorded endpoint' ;;
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
  assert_proof() { [ "$(fm_launch_proof_herdr "$META")" = "$1" ] || fail "$2"; }

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

  start_probe ''
  BRIEF="$(fm_brief_worker_role "$FM_HOME/state" t)"$'\n\nTask assigned by Firstmate.'
  fm_operational_input_encode launch-brief "$BRIEF" MESSAGE
  jq -nc --arg cwd "$WORKTREE" '{type:"session",version:3,id:"recorded",cwd:$cwd}' > "$WORKTREE/recorded.jsonl"
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
    ACTIVE_SESSION_REF="$WORKTREE/recorded.jsonl"
    assert_proof unmanaged "$version native restore with exact task-owned startup must remain unmanaged"
    before_info=$INFO
    before_environment=$(fm_remote_herdr_process_env "$PID")
    before_session=$(shasum -a 256 "$WORKTREE/recorded.jsonl")
    ACTIVE_SESSION_REF="$WORKTREE/personal.jsonl"
    assert_proof unmanaged "$version same-PID in-process personal-session switch must remain unmanaged"
    [ "$INFO" = "$before_info" ] && [ "$(fm_remote_herdr_process_env "$PID")" = "$before_environment" ] \
      && [ "$(shasum -a 256 "$WORKTREE/recorded.jsonl")" = "$before_session" ] \
      || fail 'native in-process switch must leave PID, argv, environment and historical launch file unchanged'
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
  pass 'native restoration and same-PID conversation switches stay unmanaged without argv, cwd or initial-message shortcuts'
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
  exit 0
fi
test_launch_proof_recorded_native_identity
