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
      # A versioned claude launch whose readable environment carries a pin for another
      # generation reports pinned-elsewhere; a legacy claude record keeps unknown.
      [ "$harness:$version" != claude:env-v1 ] || expected='pinned-elsewhere'
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
  assert_proof unmanaged 'a versioned claude launch with no pin is a readable unmanaged native restore'
  proof_meta claude
  assert_proof unknown 'a legacy claude record keeps the unknown verdict'
  proof_meta codex env-v1
  assert_proof unknown 'missing incarnation for a harness without an adoption route must stay unknown'
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


# A restored claude agent is authorized only by positive, independent proof that it
# is this task's own conversation. Every fact comes from stubbed readers (process
# table, kernel cwd, process environment, Herdr): a restored `claude --resume <id>`
# as the pane's foreground process. The recorded lane vernant-d1-intake shape,
# `node <nvm bin>/teamclaude run -- --resume <id>` with claude as its direct child,
# is refused: the forwarding-launcher allow-list is empty.
test_launch_proof_claude_adoption() (
  local T="$TMP/claude-adopt" UUID=5a3eec19-de12-4999-bed2-bbd561089154 OTHER_UUID=0b4c1d2e-3f40-4a51-8b62-7c83d94ea5f6
  local LANE="$T/lane/firstmate" OPERATOR="$T/operator" STATE="$T/main/state" META out err rc DOORBELL
  mkdir -p "$T"
  META="$STATE/vernant-t1.meta"
  PIN_GEN=s1793120312.10459.5003

  proc() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$T/procs"; }  # pid ppid pgid name argv0 args
  default_procs() {
    : > "$T/procs"
    proc 53733 1 53733 2.1.316 claude "claude --resume $UUID"
    proc 56557 53733 53733 railway railway 'railway mcp'
    printf 53733 > "$T/fg-group"
  }
  wrapper_procs() { # <launcher-args>: the launcher leads the foreground group, claude is its direct child
    : > "$T/procs"
    proc 53539 1 53539 node node "$1"
    proc 53733 53539 53539 2.1.316 claude "claude --resume $UUID"
    proc 56557 53733 53539 railway railway 'railway mcp'
    printf 53539 > "$T/fg-group"
  }
  # $T/table-omit names one pid the process table leaves out; $T/gone-<pid> marks a
  # process that exited after the table was read.
  ps() {
    case "$*" in
      '-axo pid=,ppid=,pgid=') awk -F'\t' -v o="$(cat "$T/table-omit" 2>/dev/null)" '$1 != o {print $1, $2, $3}' "$T/procs" ;;
      '-axo pid=,ppid=') awk -F'\t' '{print $1, $2}' "$T/procs" ;;
      '-p '*' -o comm='*) [ ! -e "$T/gone-$2" ] || return 1; awk -F'\t' -v p="$2" '$1 == p {print $4; found=1} END {exit !found}' "$T/procs" ;;
      # With argv-<pid>, args is that argv flattened with spaces, as ps prints it.
      '-p '*' -o args='*) [ ! -e "$T/gone-$2" ] && [ ! -e "$T/args-fail-$2" ] || return 1
        if [ -f "$T/argv-$2" ]; then tr '\0' ' ' < "$T/argv-$2" | sed 's/ $//'; echo; return; fi
        awk -F'\t' -v p="$2" '$1 == p {print $6; found=1} END {exit !found}' "$T/procs" ;;
      # live-ppid-<pid> overrides the live parent; lstart-<pid> (then lstart-next-<pid>
      # after its first read) overrides the birth time.
      '-p '*' -o ppid='*) [ ! -e "$T/gone-$2" ] || return 1
        if [ -f "$T/live-ppid-$2" ]; then cat "$T/live-ppid-$2"; else awk -F'\t' -v p="$2" '$1 == p {print $2; found=1} END {exit !found}' "$T/procs"; fi ;;
      '-p '*' -o lstart='*) [ ! -e "$T/gone-$2" ] || return 1
        if [ -f "$T/lstart-$2" ]; then cat "$T/lstart-$2"; [ ! -f "$T/lstart-next-$2" ] || mv "$T/lstart-next-$2" "$T/lstart-$2"
        else awk -F'\t' -v p="$2" '$1 == p {print "Sat Nov 14 10:00:00 2026"; found=1} END {exit !found}' "$T/procs"; fi ;;
      *) fail "unexpected ps query: $*" ;;
    esac
  }
  lsof() { # -w -a -p <pid> -d cwd -F pn0; $T/lsof-fail prints the fields and then fails
    [ -f "$T/cwd-$4" ] || return 1
    printf 'p%s\0\nfcwd\0n%s\0\n' "$4" "$(cat "$T/cwd-$4")"
    [ ! -f "$T/lsof-fail" ]
  }
  # env-seq-<pid>: the first read fails, later reads return the file.
  fm_remote_herdr_process_env() {
    if [ -f "$T/env-seq-$1" ]; then
      [ -f "$T/env-seq-read-$1" ] || { : > "$T/env-seq-read-$1"; return 1; }
      cat "$T/env-seq-$1"; return
    fi
    [ -f "$T/env-$1" ] && cat "$T/env-$1"; }
  # The structured argv reader: $T/argv-<pid> holds NUL-separated fields; otherwise
  # the table's args split on spaces; $T/argv-fail-<pid> cannot be read.
  fm_launch_proof_pid_argv() {
    local f n=0
    [ ! -e "$T/argv-fail-$1" ] || return 1
    if [ -f "$T/argv-$1" ]; then
      while IFS= read -r -d '' f; do n=$((n + 1)); done < "$T/argv-$1"
      printf '%s\0' "$n"; cat "$T/argv-$1"
    else
      local -a words
      read -r -a words <<< "$(awk -F'\t' -v p="$1" '$1 == p {print $6; found=1} END {exit !found}' "$T/procs")" || return 1
      printf '%s\0' "${#words[@]}" "${words[@]}"
    fi
  }
  fm_backend_herdr_cli() {
    case "$*" in
      'lab pane get w1:p2')
        [ ! -f "$T/pane-missing" ] || return 1
        printf '{"result":{"pane":{"pane_id":"w1:p2"}}}' ;;
      'lab pane process-info --pane w1:p2')
        awk -F'\t' -v g="$(cat "$T/fg-group")" '$3 == g' "$T/procs" | jq -Rsc --arg g "$(cat "$T/fg-group")" '
          split("\n") | map(select(length > 0) | split("\t")) as $rows
          | {result:{type:"pane_process_info",process_info:{pane_id:"w1:p2",
              foreground_process_group_id:($g | tonumber),
              foreground_processes:[$rows[] | {pid:(.[0] | tonumber), name:.[3], argv0:.[4]}]}}}' ;;
      *) return 1 ;;
    esac
  }
  env_of() { printf 'PATH=/usr/bin\nHOME=%s\n%s' "$OPERATOR" "${2:-}" > "$T/env-$1"; }
  write_meta() {
    printf 'window=lab:w1:p2\nherdr_session=lab\nherdr_pane_id=w1:p2\nbackend=herdr\nharness=claude\nkind=secondmate\nspawn_gen=%s\nlaunch_proof=env-v1\nworktree=%s\nhome=%s\n' \
      "$PIN_GEN" "$LANE" "$LANE" > "$META"
  }
  transcript_dir() { printf '%s/.claude/projects/%s' "$OPERATOR" "$(fm_launch_proof_claude_project_dir "$LANE")"; }
  write_transcript() { # <first-user-message> <seconds-after-now> [<uuid>]
    local ts
    mkdir -p "$(transcript_dir)"
    ts=$(python3 -c 'import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%S.000Z"))' "$2")
    {
      printf '{"type":"last-prompt","sessionId":"%s"}\n' "${3:-$UUID}"
      jq -nc --arg text "$1" --arg ts "$ts" '{type:"user",timestamp:$ts,message:{role:"user",content:$text}}'
      jq -nc '{type:"assistant",message:{role:"assistant",content:"ok"}}'
    } > "$(transcript_dir)/${3:-$UUID}.jsonl"
  }
  fresh_case() {
    rm -rf "$T/lane" "$T/main" "$T/sib" "$T/nested" "$T/hA" "$T/hB" "$T/operator" "$T"/env-* "$T"/cwd-* "$T/pane-missing" "$T/table-omit" "$T"/gone-* "$T"/live-ppid-* "$T"/lstart-* "$T"/argv-* "$T"/args-fail-* "$T/lsof-fail"
    mkdir -p "$LANE/state" "$STATE" "$OPERATOR"
    default_procs
    write_meta
    env_of 53539; env_of 53733; env_of 56557
    printf '%s' "$LANE" > "$T/cwd-53733"; printf '%s' "$LANE" > "$T/cwd-53539"
    fm_operational_record_write "$LANE/state" launch-brief 'task brief' DOORBELL
    write_transcript "$DOORBELL" 30
  }
  adopt() { out=$(fm_launch_proof_claude_adoption "$META" 2>"$T/err") && rc=0 || rc=$?; err=$(cat "$T/err"); }
  # FM_TEST_ROWS=1 prints one line per row (exit status and the printed cause) for the evidence record.
  row() { [ -z "${FM_TEST_ROWS:-}" ] || printf 'ROW %-96s | exit %s | %s\n' "$1" "$rc" "$2"; }
  accepts() { adopt; [ "$rc" = 0 ] || fail "$1: refused: $err"; row "$1" "authorized: $(printf '%s' "$out" | jq -c '{pid,harness_pid,tie}')"; }
  # Every missing-tie refusal names what lets Main go on (plan row E2(b)).
  no_tie_next() { # <cause-substring> <description>
    [ "$1" = 'no task-specific session tie' ] || return 0
    assert_contains "$err" 'the lane by hand' "$2: names its next action"
  }
  refuses() { # <cause-substring> <description>
    adopt
    [ "$rc" != 0 ] || fail "$2: authorized: $out"
    [ -z "$out" ] || fail "$2: printed a record while refusing"
    assert_contains "$err" "$1" "$2"
    no_tie_next "$1" "$2"
    row "$2" "$err"
  }

  # The recorded d1 transcript location, derived from its recorded home.
  assert_equals -Users-charlesabrooker--treehouse-firstmate-7bab20-2-firstmate \
    "$(fm_launch_proof_claude_project_dir /Users/charlesabrooker/.treehouse/firstmate-7bab20/2/firstmate)" \
    'transcripts live under the home with every non-alphanumeric character replaced'

  fresh_case
  accepts 'compliant restored claude (bare harness, cwd, one claim, launch-brief tie)'
  assert_equals "$UUID" "$(printf '%s' "$out" | jq -r .session_id)" 'candidate names the live session'
  assert_equals 53733 "$(printf '%s' "$out" | jq -r .pid)" 'the bare claude is the attributed process'
  assert_equals 53733 "$(printf '%s' "$out" | jq -r .harness_pid)" 'the bare claude is its own harness'
  assert_equals launch-brief "$(printf '%s' "$out" | jq -r .tie)" 'tie is the launch-brief doorbell'
  # Later transcript content (reading and archiving inbox records) is not the tie: the twin of h3.
  { printf '{"type":"assistant","message":{"role":"assistant","content":"read the inbox"}}\n'
    printf '{"type":"user","timestamp":"2099-01-01T00:00:00.000Z","message":{"role":"user","content":"mv inbox/1.msg inbox/handled/"}}\n'; } >> "$(transcript_dir)/$UUID.jsonl"
  accepts 'the same later inbox activity does not change a launch-brief session'
  pass 'a restored claude agent is adopted on positive proof'

  # The recorded d1 shape: TeamClaude is not on the (empty) forwarding allow-list.
  fresh_case; wrapper_procs "node $T/.nvm/bin/teamclaude run -- --resume $UUID"
  refuses 'listed forwarding launcher' '(c) the d1 shape behind a teamclaude run -- wrapper'
  pass 'a restored claude behind the TeamClaude launcher refuses with its own cause'

  # The retained launcher proof, exercised with a hypothetical entry in this subshell only.
  FM_LAUNCH_PROOF_FORWARDING_LAUNCHERS=examplelauncher
  WRAPPER_ARGS="node $T/.nvm/bin/examplelauncher run -- --resume $UUID"
  fresh_case; wrapper_procs "$WRAPPER_ARGS"
  accepts 'a listed launcher forwarding a direct claude child'
  assert_equals 53539 "$(printf '%s' "$out" | jq -r .pid)" 'candidate names the attributed launcher'
  assert_equals 53733 "$(printf '%s' "$out" | jq -r .harness_pid)" 'candidate names the harness child'
  fresh_case; wrapper_procs "node $T/.nvm/bin/otherwrap run -- --resume $UUID"
  refuses 'forwarding launcher' '(c) a launcher-shaped wrapper that is not on the allow-list'
  fresh_case; wrapper_procs "node $T/.nvm/bin/examplelauncher status"
  refuses 'forwarding launcher' '(c) the listed launcher without its "run --" form'
  fresh_case; : > "$T/procs"
  proc 53539 1 53539 node node "$WRAPPER_ARGS"; proc 53733 53539 53600 2.1.316 claude "claude --resume $UUID"
  proc 53600 1 53539 helper helper 'helper'; printf 53539 > "$T/fg-group"
  refuses 'direct child' '(c) the harness is outside the launcher process group'
  fresh_case; : > "$T/procs"
  proc 53539 1 53539 node node "$WRAPPER_ARGS"; proc 53540 53539 53539 sh sh 'sh -c wrapper'
  proc 53733 53540 53539 2.1.316 claude "claude --resume $UUID"; printf 53539 > "$T/fg-group"
  refuses 'direct child' '(c) the harness is a grandchild, not a direct child'
  fresh_case; : > "$T/procs"
  proc 53539 1 53539 node node "$WRAPPER_ARGS"; proc 53733 53539 53539 2.1.316 claude "claude --resume $OTHER_UUID"
  printf 53539 > "$T/fg-group"
  refuses 'forward exactly' '(c) the launcher forwards other arguments than the harness runs'
  fresh_case; wrapper_procs "$WRAPPER_ARGS"; env_of 53539 'FM_SPAWN_GEN=s9.9.9
'
  refuses 'pinned to another launch generation' '(e) the launcher is pinned to another generation'
  FM_LAUNCH_PROOF_FORWARDING_LAUNCHERS=''
  pass 'the retained forwarding-launcher proof refuses every unproven launcher shape'

  # (a) pane
  fresh_case; : > "$T/pane-missing"
  refuses 'pane to exist' '(a) the recorded pane does not exist'
  # (b) foreground none / more than one
  fresh_case; printf 99999 > "$T/fg-group"
  refuses 'uniquely resolved' '(b) the foreground resolves to none'
  fresh_case; : > "$T/procs"
  proc 999 1 999 bash sh 'bash'; proc 70001 999 999 2.1.316 claude "claude --resume $UUID"
  proc 70002 999 999 2.1.316 claude "claude --resume $OTHER_UUID"; printf 999 > "$T/fg-group"
  refuses 'uniquely resolved' '(b) two agent candidates resolve to more than one'
  # (c) foreground is neither the harness nor a proven forwarding launcher
  fresh_case; : > "$T/procs"; proc 777 1 777 vim vim 'vim notes.txt'; printf 777 > "$T/fg-group"
  refuses 'forwarding launcher' '(c) an editor holds the pane'
  fresh_case; : > "$T/procs"; proc 777 1 777 bash bash 'bash'; printf 777 > "$T/fg-group"
  refuses 'uniquely resolved' '(c) only a shell holds the pane'
  fresh_case; : > "$T/procs"; proc 777 1 777 python3 python3 'python3 /tmp/runner.py'
  proc 53733 777 777 2.1.316 claude "claude --resume $UUID"; printf 777 > "$T/fg-group"
  refuses 'forwarding launcher' '(c) an interpreter parent with a harness-shaped child'
  # (d) kernel working directory
  fresh_case; printf '%s' "$T" > "$T/cwd-53733"
  refuses 'cwd to be this task' '(d) the harness cwd is an unrelated directory'
  fresh_case; mkdir -p "$T/other-home/firstmate"; printf '%s' "$T/other-home/firstmate" > "$T/cwd-53733"
  refuses 'cwd to be this task' '(d) the harness cwd is another home'
  fresh_case; mkdir -p "$LANE/sub"; printf '%s' "$LANE/sub" > "$T/cwd-53733"
  refuses 'cwd to be this task' '(d) the harness cwd is a subdirectory of the recorded home'
  # (e) a process pinned to another generation
  fresh_case; env_of 53733 'FM_SPAWN_GEN=s9.9.9
'
  refuses 'pinned to another launch generation' '(e) the harness is pinned to another generation'
  # a pin that matches belongs to the managed route, not to adoption
  fresh_case; env_of 53733 "FM_SPAWN_GEN=$PIN_GEN
"
  refuses 'without a usable launch pin' '(e) a matching pin needs no adoption'
  # (f) another record claims the pane or the home
  fresh_case
  printf 'window=lab:w1:p2\nharness=claude\nworktree=%s\n' "$T/elsewhere" > "$STATE/other.meta"
  refuses 'claimed by other.meta' '(f) another task claims the same pane'
  fresh_case
  printf 'window=lab:w9:p9\nharness=claude\nhome=%s\n' "$LANE" > "$STATE/other.meta"
  refuses 'claimed by other.meta' '(f) another task claims the same home'
  fresh_case
  printf 'window=lab:w9:p9\nharness=claude\nworktree=%s\n' "$LANE" > "$STATE/other.meta"
  refuses 'claimed by other.meta' '(f) another task claims the same worktree'
  fresh_case
  printf 'window=lab:w9:p9\nherdr_session=lab\nherdr_pane_id=w1:p2\nharness=claude\n' > "$STATE/other.meta"
  refuses 'claimed by other.meta' '(f) another task claims the same Herdr session and pane id under a different window text'
  fresh_case; ln -s "$LANE" "$T/lane-link"
  printf 'window=lab:w9:p9\nharness=claude\nhome=%s\n' "$T/lane-link" > "$STATE/other.meta"
  refuses 'claimed by other.meta' '(f) another task names the same home through a symlink'
  rm -f "$T/lane-link"
  fresh_case
  printf 'kind=secondmate\nwindow=lab:w8:p8\nhome=%s\nworktree=%s\n' "$T/peer-home" "$T/peer-home" > "$STATE/peer.meta"
  mkdir -p "$T/peer-home/state"
  printf 'window=lab:w1:p2\nharness=claude\n' > "$T/peer-home/state/child.meta"
  refuses 'claimed by child.meta' '(f) a record in another readable home claims the same pane'
  # (g) the environment cannot be read
  fresh_case; rm -f "$T/env-53733"
  refuses 'without a usable launch pin' '(g) the harness environment cannot be read'
  fresh_case; printf 'ONLY=1\n' > "$T/env-53733"
  refuses 'without a usable launch pin' '(g) the environment carries neither PATH nor HOME'
  fresh_case; env_of 56557 'FM_SPAWN_GEN=s9.9.9
'
  refuses 'pinned to another launch generation' '(e) a helper in the harness group is pinned to another generation'
  # (h) the session tie
  fresh_case; : > "$T/procs"; proc 53733 1 53733 2.1.316 claude 'claude --model opus'; printf 53733 > "$T/fg-group"
  refuses 'no task-specific session tie' '(h) no session id on the harness argv'
  fresh_case; rm -f "$(transcript_dir)/$UUID.jsonl"
  refuses 'no task-specific session tie' '(h) no readable transcript'
  fresh_case; write_transcript "Please look at $LANE/state/operational-inbox and tell me what is there" 30
  refuses 'no task-specific session tie' '(h) the first message only names the inbox'
  fresh_case; mkdir -p "$T/foreign/state"; fm_operational_record_write "$T/foreign/state" launch-brief 'foreign brief' FOREIGN
  # shellcheck disable=SC2153 # FOREIGN is assigned by name by fm_operational_record_write.
  write_transcript "$FOREIGN" 30
  refuses 'no task-specific session tie' '(h) the doorbell names a record outside the task home'
  fresh_case; rm -f "$LANE"/state/operational-inbox/*.msg
  refuses 'no task-specific session tie' '(h) the doorbell names a record that no longer exists'
  fresh_case; fm_operational_record_write "$LANE/state" session-start 'not a launch brief' OTHERBELL
  write_transcript "$OTHERBELL" 30
  refuses 'no task-specific session tie' '(h) the record is not of kind launch-brief'
  fresh_case; write_transcript "$DOORBELL" -3600
  refuses 'no task-specific session tie' '(h) the record is newer than the first message'
  fresh_case; printf 'claude_session_id=%s\n' "$OTHER_UUID" >> "$META"
  refuses 'recorded session id differs from the live session' '(h) a recorded id that differs from argv vetoes a valid doorbell'
  fresh_case; printf 'claude_session_id=%s\n' "$UUID" >> "$META"; rm -f "$(transcript_dir)/$UUID.jsonl"
  accepts '(T1) a recorded session id equal to the live id is a tie without a transcript'
  assert_equals recorded "$(printf '%s' "$out" | jq -r .tie)" 'T1 is reported as the recorded tie'
  # A malformed transcript refuses quietly: no traceback reaches the operator's terminal.
  fresh_case; printf '%s\n' '{"type":"user","message":{"role":"user","content":[7]},"timestamp":"x"}' > "$(transcript_dir)/$UUID.jsonl"
  refuses 'no task-specific session tie' '(h) a transcript whose first message has a malformed content item'
  assert_not_contains "$err" Traceback 'a malformed transcript must not print a traceback'
  fresh_case; printf '%s\n' '{"type":"user","message":{"role":"user","content":"hello"}}' > "$(transcript_dir)/$UUID.jsonl"
  refuses 'no task-specific session tie' '(h) a transcript whose first message has no timestamp'
  assert_not_contains "$err" Traceback 'a transcript without a timestamp must not print a traceback'
  # (h3) the authentic personal diagnostic session
  fresh_case
  write_transcript "Where is the inbox? Is $LANE/state/operational-inbox the right place?" 30
  { printf '{"type":"assistant","message":{"role":"assistant","content":"reading %s/state/operational-inbox"}}\n' "$LANE"
    printf '{"type":"user","timestamp":"2099-01-01T00:00:00.000Z","message":{"role":"user","content":"archive the processed record into handled/"}}\n'; } >> "$(transcript_dir)/$UUID.jsonl"
  mkdir -p "$LANE/state/operational-inbox/handled"
  refuses 'no task-specific session tie' '(h3) a personal session reading and archiving the inbox is not the task'
  # (h2) the task agent exited and a bare personal claude holds the same pane and home
  fresh_case; : > "$T/procs"; proc 53733 1 53733 2.1.316 claude 'claude'; printf 53733 > "$T/fg-group"
  refuses 'no task-specific session tie' '(h2) a bare personal claude in the same pane, home and cwd'
  pass 'every missing, foreign or contradicting fact refuses the adoption with its own cause'

  # The owner's --session-id statement names the live id, which anyone can read from ps,
  # so it ties only a session whose transcript still opens with this task's doorbell
  # and whose launch-brief record is gone; the personal-session rows still refuse.
  stated() { out=$(fm_launch_proof_claude_adoption "$META" "$UUID" operator 2>"$T/err") && rc=0 || rc=$?; err=$(cat "$T/err"); }
  refuses_stated() { # <cause-substring> <description>
    stated
    [ "$rc" != 0 ] || fail "$2: authorized: $out"
    [ -z "$out" ] || fail "$2: printed a record while refusing"
    assert_contains "$err" "$1" "$2"
    no_tie_next "$1" "$2"
    row "$2" "$err"
  }
  fresh_case
  write_transcript "Where is the inbox? Is $LANE/state/operational-inbox the right place?" 30
  { printf '{"type":"assistant","message":{"role":"assistant","content":"reading %s/state/operational-inbox"}}\n' "$LANE"
    printf '{"type":"user","timestamp":"2099-01-01T00:00:00.000Z","message":{"role":"user","content":"archive the processed record into handled/"}}\n'; } >> "$(transcript_dir)/$UUID.jsonl"
  refuses_stated 'no task-specific session tie' '(h3) with --session-id: a personal session reading and archiving the inbox is not the task'
  fresh_case; write_transcript 'help me refactor this function' 30
  refuses_stated 'no task-specific session tie' '(h2) with --session-id: a bare personal claude --resume in the same pane, home and cwd'
  rm -f "$LANE"/state/operational-inbox/*.msg
  refuses_stated 'no task-specific session tie' '(h2) with --session-id: a personal session stays refused once the brief is gone'
  fresh_case; mkdir -p "$T/foreign/state"; fm_operational_record_write "$T/foreign/state" launch-brief 'foreign brief' FOREIGN
  # shellcheck disable=SC2153 # FOREIGN is assigned by name by fm_operational_record_write.
  write_transcript "$FOREIGN" 30; rm -f "$T"/foreign/state/operational-inbox/*.msg
  refuses_stated 'no task-specific session tie' 'with --session-id: a doorbell of another home is not this task'"'"'s'
  fresh_case
  refuses_stated 'launch-brief record still exists' 'with --session-id: a present launch brief is proven by plain adopt, not by the statement'
  # A present record that plain adopt would also refuse gets that record's own cause, never advice to run plain adopt.
  fresh_case; fm_operational_record_write "$LANE/state" session-start 'not a launch brief' OTHERBELL
  write_transcript "$OTHERBELL" 30
  refuses_stated 'is not the launch-brief doorbell' 'with --session-id: a present record that is not a launch brief keeps its own cause'
  assert_not_contains "$err" 'run adopt without --session-id' 'a present non-launch-brief record is not sent to plain adopt'
  fresh_case; write_transcript "$DOORBELL" -3600
  refuses_stated 'newer than the first user message' 'with --session-id: a present record newer than the message keeps its own cause'
  assert_not_contains "$err" 'run adopt without --session-id' 'a present record newer than the message is not sent to plain adopt'
  fresh_case; rm -f "$LANE"/state/operational-inbox/*.msg
  stated
  [ "$rc" = 0 ] || fail "with --session-id: the past-retention lane must adopt: $err"
  assert_equals operator "$(printf '%s' "$out" | jq -r .tie)" 'the past-retention statement names the operator tie'
  row 'with --session-id: a lane whose first message is its own doorbell and whose brief is gone' "authorized: $(printf '%s' "$out" | jq -c '{pid,harness_pid,tie}')"
  pass 'the owner statement ties only a past-retention launch-brief session, never a personal one'

  # N1: a forked resume runs a new conversation, so no tie of its source applies.
  for fork in '--fork-session' '--session-id 0b4c1d2e-3f40-4a51-8b62-7c83d94ea5f6' '--continue'; do
    fresh_case; : > "$T/procs"; proc 53733 1 53733 2.1.316 claude "claude --resume $UUID $fork"; printf 53733 > "$T/fg-group"
    refuses 'runs a conversation other than the one it resumes' "(h) N1 launch-brief tie: claude --resume <id> $fork"
    printf 'claude_session_id=%s\n' "$UUID" >> "$META"
    refuses 'runs a conversation other than the one it resumes' "(h) N1 recorded tie: claude --resume <id> $fork"
    write_meta; rm -f "$LANE"/state/operational-inbox/*.msg
    refuses_stated 'runs a conversation other than the one it resumes' "(h) N1 owner statement: claude --resume <id> $fork"
  done
  fresh_case
  accepts 'N1 control: an ordinary resume of the same session adopts'
  fresh_case; : > "$T/procs"; proc 53733 1 53733 2.1.316 claude "claude --session-id $UUID --resume $UUID"; printf 53733 > "$T/fg-group"
  accepts 'N1 control: a --session-id naming the resumed id (a confined launch) is the same conversation'

  # N2: every local home the root inventory reaches, and no unreadable record.
  register() { # <home-dir> <id> <child-home>
    mkdir -p "$1/data"
    printf -- '- %s - lane (home: %s; scope: s; projects: p; added 2026-11-14)\n' "$2" "$3" >> "$1/data/secondmates.md"
  }
  fresh_case; mkdir -p "$T/sib/state"; register "$T/main" sib "$T/sib"
  printf 'window=lab:w1:p2\nharness=claude\n' > "$T/sib/state/claimer.meta"
  refuses 'claimed by claimer.meta' '(f) N2 a sibling home registered at the root claims the same pane'
  fresh_case; mkdir -p "$T/sib/state" "$T/nested/state"; register "$T/main" sib "$T/sib"; register "$T/sib" nested "$T/nested"
  printf 'window=lab:w9:p9\nharness=claude\nhome=%s\n' "$LANE" > "$T/nested/state/deep.meta"
  refuses 'claimed by deep.meta' '(f) N2 a nested home two registries down claims the same home'
  fresh_case; mkdir -p "$T/sib/state"; register "$T/main" sib "$T/sib"
  printf 'window=lab:w9:p9\nharness=claude\n' > "$T/sib/state/locked.meta"; chmod 000 "$T/sib/state/locked.meta"
  refuses 'cannot be read' '(f) N2 an unreadable peer record is unknown, never "no conflict"'
  chmod 600 "$T/sib/state/locked.meta"
  fresh_case; register "$T/main" gone "$T/does-not-exist"
  refuses 'complete inventory' '(f) N2 a registered home that cannot be resolved refuses'
  fresh_case; mkdir -p "$T/sib/state"; register "$T/main" sib "$T/sib"
  printf 'window=lab:w9:p9\nharness=claude\nhome=%s\n' "$T/sib" > "$T/sib/state/own.meta"
  accepts 'N2 control: readable sibling and nested homes without a conflicting claim'

  # N3: every member of the harness's process group is read, and the table must list the anchor.
  # Main 022: an unreadable member the live table shows descending from the proven
  # harness (live parent chain, same birth across the read) is ours; any other refuses.
  fresh_case; proc 56559 1 53733 helper helper 'helper'
  refuses 'cannot be read' '(e) N3 a live group member outside the harness descent whose environment cannot be read'
  fresh_case; proc 56559 1 53733 helper helper 'helper'; printf 'ONLY=1\n' > "$T/env-56559"
  refuses 'cannot be read' '(e) N3 a live group member outside the harness descent whose environment carries neither PATH nor HOME'
  fresh_case; proc 56561 56557 53733 sh sh 'sh -c tool'; printf 1 > "$T/live-ppid-56557"
  refuses 'cannot be read' '(e) N3 an unreadable grandchild whose parent was reparented (chain broken)'
  fresh_case; proc 56558 53733 53733 caffeinate caffeinate 'caffeinate -i'; printf 1 > "$T/live-ppid-56558"
  refuses 'cannot be read' '(e) N3 a member whose live parent no longer matches the table'
  fresh_case; proc 56558 53733 53733 caffeinate caffeinate 'caffeinate -i'
  printf 'Sat Nov 14 10:00:00 2026\n' > "$T/lstart-56558"; printf 'Sat Nov 14 10:05:00 2026\n' > "$T/lstart-next-56558"
  refuses 'cannot be read' '(e) N3 a member whose birth identity changed during the read'
  fresh_case; proc 56558 53733 53733 caffeinate caffeinate 'caffeinate -i'
  accepts 'N3 the d7/d1 shape: a live caffeinate child of the harness whose environment cannot be read'
  fresh_case; proc 56561 56557 53733 sh sh 'sh -c tool'
  accepts 'N3 a grandchild of the harness through a readable member, whose environment cannot be read'
  fresh_case; printf 53733 > "$T/table-omit"; env_of 56557 'FM_SPAWN_GEN=s9.9.9
'
  refuses 'process table' '(e) N3 the process table omits the anchor while a foreign-pinned member is listed'
  fresh_case; printf 53733 > "$T/table-omit"
  refuses 'process table' '(e) N3 the process table omits the anchor'
  # Main 1564 (c): a member that cannot be read is not proven to have exited.
  fresh_case; rm -f "$T/env-56557"; : > "$T/gone-56557"
  refuses 'cannot be read' '(e) F3 a member that can no longer be read is not proven to have exited'
  fresh_case
  accepts 'N3 control: every group member readable and unpinned'

  # N6: a line before the first user record that cannot be classified hides which message came first.
  for bad in '{"type":"user","message":{"role":"user","content":"personal' '[1]' 'not json'; do
    fresh_case
    { printf '{"type":"last-prompt","sessionId":"%s"}\n' "$UUID"; printf '%s\n' "$bad"
      jq -nc --arg text "$DOORBELL" --arg ts 2099-01-01T00:00:00.000Z '{type:"user",timestamp:$ts,message:{role:"user",content:$text}}'
    } > "$(transcript_dir)/$UUID.jsonl"
    refuses 'no task-specific session tie' "(h) N6 an unclassifiable line before the doorbell: $bad"
  done
  fresh_case
  { printf '\n{"type":"last-prompt","sessionId":"%s"}\n\n' "$UUID"
    jq -nc --arg text "$DOORBELL" --arg ts 2099-01-01T00:00:00.000Z '{type:"user",timestamp:$ts,message:{role:"user",content:$text}}'
    printf 'trailing junk after the first user record\n'
  } > "$(transcript_dir)/$UUID.jsonl"
  accepts 'N6 control: blank lines before, and anything after, the doorbell'

  # N7: lsof escapes a backslash in the cwd; the decoded physical path is compared exactly.
  local SAVED_LANE=$LANE
  LANE="$T/back\\slash/firstmate"
  fresh_case; printf '%s' "${LANE//\\/\\\\}" > "$T/cwd-53733"
  accepts 'N7 a recorded home whose name holds a backslash, read through the lsof escape'
  printf '%s' "$T/back\\x41slash/firstmate" > "$T/cwd-53733"
  refuses 'cwd' '(d) N7 an escape that decodes to another directory'
  printf '%s' "$T/back\\qslash/firstmate" > "$T/cwd-53733"
  refuses 'cwd' '(d) N7 an ambiguous escape'
  rm -rf "$T/back\\slash"
  LANE=$SAVED_LANE
  pass 'N1-N3, N6 and N7: forks, unreached or unreadable homes and processes, a hidden first message, and escaped paths'

  # F1: the session tie reads argv as separate fields; prompt text never acts as an option.
  fresh_case; printf 'claude_session_id=%s\n' "$UUID" >> "$META"
  printf 'claude\0--append-system-prompt\0discuss --resume %s\0' "$UUID" > "$T/argv-53733"
  refuses 'no task-specific session tie' '(h) F1 a prompt operand that reads like --resume is not a resume'
  fresh_case; printf 'claude_session_id=%s\n' "$UUID" >> "$META"
  printf 'claude\0--append-system-prompt\0--resume\0%s\0' "$UUID" > "$T/argv-53733"
  refuses 'no task-specific session tie' '(h) F1 a --resume that is the operand of a value option is not a resume'
  fresh_case; printf 'claude_session_id=%s\n' "$UUID" >> "$META"; : > "$T/argv-fail-53733"
  refuses 'no task-specific session tie' '(h) F1 an argv that cannot be read as separate fields'
  fresh_case
  printf 'claude\0--resume\0%s\0--append-system-prompt\0please do not --fork-session here\0' "$UUID" > "$T/argv-53733"
  accepts 'F1 control: a genuine resume whose prompt mentions --fork-session'
  fresh_case; printf 'claude\0--dangerously-skip-permissions\0--resume\0%s\0' "$UUID" > "$T/argv-53733"
  accepts 'F1 control: a resume after a boolean flag'

  # F2: homes named by records are followed to a fixed point, with a cycle guard.
  fresh_case; mkdir -p "$T/hA/state" "$T/hB/state"
  printf 'kind=secondmate\nwindow=lab:w7:p7\nhome=%s\n' "$T/hA" > "$STATE/a.meta"
  printf 'kind=secondmate\nwindow=lab:w6:p6\nhome=%s\n' "$T/hB" > "$T/hA/state/b.meta"
  printf 'window=lab:w1:p2\nharness=claude\n' > "$T/hB/state/claim.meta"
  refuses 'claimed by claim.meta' '(f) F2 a home two record-links away claims the same pane'
  fresh_case; mkdir -p "$T/hA/state" "$T/hB/state"
  printf 'kind=secondmate\nwindow=lab:w7:p7\nhome=%s\n' "$T/hA" > "$STATE/a.meta"
  printf 'kind=secondmate\nwindow=lab:w6:p6\nhome=%s\n' "$T/hB" > "$T/hA/state/b.meta"
  printf 'kind=secondmate\nwindow=lab:w5:p5\nhome=%s\n' "$T/hA" > "$T/hB/state/back.meta"
  accepts 'F2 control: a record-linked chain with a cycle and no conflicting claim'

  # F3: one read per member judges both readability and pin; missing or unreadable is unproven.
  fresh_case; printf 56557 > "$T/table-omit"
  refuses 'process table' '(e) F3 a Herdr foreground member the process table omits'
  fresh_case; proc 56559 1 53733 helper helper 'helper'; : > "$T/args-fail-56559"
  refuses 'cannot be read' '(e) F3 an unrelated unreadable member whose args query fails is not proven to have exited'
  fresh_case; proc 56559 1 53733 helper helper 'helper'
  printf 'PATH=/usr/bin\nHOME=/x\nFM_SPAWN_GEN=s9.9.9\n' > "$T/env-seq-56559"
  refuses 'cannot be read' '(e) F3 a member unreadable on the first read and foreign-pinned on the second'

  # F4: only the JSON boolean true marks a sidechain; another value refuses.
  fresh_case
  { printf '{"type":"last-prompt","sessionId":"%s"}\n' "$UUID"
    printf '%s\n' '{"type":"user","isSidechain":"false","timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"my own project"}}'
    jq -nc --arg text "$DOORBELL" --arg ts 2099-01-01T00:00:00.000Z '{type:"user",timestamp:$ts,message:{role:"user",content:$text}}'
  } > "$(transcript_dir)/$UUID.jsonl"
  refuses 'no task-specific session tie' '(h) F4 an earlier user record whose isSidechain is the string "false"'
  fresh_case
  { printf '{"type":"last-prompt","sessionId":"%s"}\n' "$UUID"
    printf '%s\n' '{"type":"user","isSidechain":1,"timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"my own project"}}'
    jq -nc --arg text "$DOORBELL" --arg ts 2099-01-01T00:00:00.000Z '{type:"user",timestamp:$ts,message:{role:"user",content:$text}}'
  } > "$(transcript_dir)/$UUID.jsonl"
  refuses 'no task-specific session tie' '(h) F4 an earlier user record whose isSidechain is not a boolean'
  fresh_case
  { printf '{"type":"last-prompt","sessionId":"%s"}\n' "$UUID"
    printf '%s\n' '{"type":"user","isSidechain":true,"timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"a subagent prompt"}}'
    jq -nc --arg text "$DOORBELL" --arg ts 2099-01-01T00:00:00.000Z '{type:"user",timestamp:$ts,message:{role:"user",content:$text}}'
  } > "$(transcript_dir)/$UUID.jsonl"
  accepts 'F4 control: a real sidechain record (boolean true) before the doorbell'

  # F5: a cwd reader that fails gives no proof, whatever it printed.
  fresh_case; : > "$T/lsof-fail"
  refuses 'kernel cwd' '(d) F5 lsof prints the cwd fields and then fails'
  pass 'F1-F5: argv fields, record-linked homes, one read per member, boolean sidechains, failed readers'
)

test_launch_proof_claude_verdict_and_refusal() (
  local T="$TMP/claude-verdict" UUID=5a3eec19-de12-4999-bed2-bbd561089154
  local LANE="$T/lane/firstmate" OPERATOR="$T/operator" STATE="$T/main-state" META DOORBELL out
  mkdir -p "$T" "$LANE/state" "$STATE" "$OPERATOR"
  META="$STATE/vernant-t1.meta"
  PIN_GEN=s1793120312.10459.5003
  ps() {
    case "$*" in
      '-axo pid=,ppid=,pgid=') [ -f "$T/table-empty" ] && return 0; printf '%s\n' '53733 1 53733'; [ ! -f "$T/env-56557" ] || printf '%s\n' '56557 53733 53733'; [ ! -f "$T/unrelated" ] || printf '%s\n' '56560 1 53733' ;;
      '-axo pid=,ppid=') printf '%s\n' '53733 1' ;;
      '-p 53733 -o comm=') echo 2.1.316 ;;
      '-p 53733 -o args=') if [ -f "$T/argv" ]; then tr '\0' ' ' < "$T/argv" | sed 's/ $//'; echo; elif [ -f "$T/args" ]; then cat "$T/args"; else echo "claude --resume $UUID"; fi ;;
      '-p 56557 -o args=') [ -f "$T/env-56557" ] && echo 'railway mcp' ;;
      '-p 56557 -o ppid=') [ -f "$T/env-56557" ] && echo 53733 ;;
      '-p 56557 -o lstart=') [ -f "$T/env-56557" ] && echo 'Sat Nov 14 10:00:00 2026' ;;
      '-p 56560 -o args=') [ -f "$T/unrelated" ] && echo helper ;;
      '-p 56560 -o ppid=') [ -f "$T/unrelated" ] && echo 1 ;;
      '-p 56560 -o lstart=') [ -f "$T/unrelated" ] && echo 'Sat Nov 14 10:00:00 2026' ;;
      *) fail "unexpected ps query: $*" ;;
    esac
  }
  lsof() { printf 'p%s\0\nfcwd\0n%s\0\n' "$4" "$LANE"; }
  # The structured argv reader: $T/argv holds NUL-separated fields; otherwise the args text split on spaces.
  fm_launch_proof_pid_argv() {
    local f n=0
    if [ "$1" = 53733 ] && [ -f "$T/argv" ]; then
      while IFS= read -r -d '' f; do n=$((n + 1)); done < "$T/argv"
      printf '%s\0' "$n"; cat "$T/argv"; return
    fi
    local -a words
    read -r -a words <<< "$(ps -p "$1" -o args=)" || return 1
    printf '%s\0' "${#words[@]}" "${words[@]}"
  }
  fm_remote_herdr_process_env() {
    [ "$1" != 56557 ] || { cat "$T/env-56557"; return; }
    [ "$1" != 56560 ] || return 1
    [ -f "$T/env-unreadable" ] && return 1; printf 'PATH=/usr/bin\nHOME=%s\n%s' "$OPERATOR" "$(cat "$T/env-extra" 2>/dev/null)"; }
  fm_backend_herdr_cli() {
    case "$*" in
      'lab pane get w1:p2') printf '{"result":{"pane":{"pane_id":"w1:p2"}}}' ;;
      'lab pane process-info --pane w1:p2')
        printf '%s' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","foreground_process_group_id":53733,"foreground_processes":[{"pid":53733,"name":"2.1.316","argv0":"claude"}]}}}' ;;
      *) return 1 ;;
    esac
  }
  meta_for() { # <harness> <launch_proof> [<kind>]
    printf 'window=lab:w1:p2\nherdr_session=lab\nherdr_pane_id=w1:p2\nbackend=herdr\nharness=%s\nkind=%s\nspawn_gen=%s\nworktree=%s\nhome=%s\n' \
      "$1" "${3:-secondmate}" "$PIN_GEN" "$LANE" "$LANE" > "$META"
    [ -z "${2:-}" ] || printf 'launch_proof=%s\n' "$2" >> "$META"
  }
  fm_operational_record_write "$LANE/state" launch-brief 'task brief' DOORBELL
  mkdir -p "$OPERATOR/.claude/projects/$(fm_launch_proof_claude_project_dir "$LANE")"
  jq -nc --arg text "$DOORBELL" --arg ts "$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=30)).strftime("%Y-%m-%dT%H:%M:%S.000Z"))')" \
    '{type:"user",timestamp:$ts,message:{role:"user",content:$text}}' \
    > "$OPERATOR/.claude/projects/$(fm_launch_proof_claude_project_dir "$LANE")/$UUID.jsonl"

  # E1: a readable environment without a pin is an unpinned native restore, never "unreadable".
  meta_for claude env-v1
  assert_equals unmanaged "$(fm_launch_proof_herdr "$META")" 'a readable claude environment without a pin is unmanaged'
  out=$(fm_launch_proof_herdr_refusal "$META") && fail 'an unadopted unpinned claude was authorized'
  assert_contains "$out" 'unpinned native restore' 'the cause names an unpinned native restore'
  assert_contains "$out" 'environment was readable and carries no launch pin' 'the cause says the environment was readable and had no pin'
  assert_contains "$out" 'bin/fm-control.sh vernant-t1 adopt' 'the cause names the explicit route'
  assert_not_contains "$out" 'unreadable' 'the unpinned case is not called unreadable'
  # adopt accepts only secondmates, so a ship or scout is never sent to it.
  for kind in ship scout; do
    meta_for claude env-v1 "$kind"
    out=$(fm_launch_proof_herdr_refusal "$META") && fail "an unadopted unpinned claude $kind was authorized"
    assert_contains "$out" 'unpinned native restore' "the $kind cause names an unpinned native restore"
    assert_contains "$out" 'unmanaged restored worker: adopt supports secondmates only; Main inspects the pane and decides' \
      "the $kind next action says adopt supports secondmates only"
    assert_not_contains "$out" 'fm-control.sh vernant-t1 adopt' "a $kind is never told to run adopt"
  done
  meta_for claude env-v1
  # E1: an environment that cannot be read keeps the unreadable wording and its own next action.
  : > "$T/env-unreadable"
  assert_equals unknown "$(fm_launch_proof_herdr "$META")" 'an unreadable environment stays unknown'
  out=$(fm_launch_proof_herdr_refusal "$META") && fail 'an unreadable claude environment was authorized'
  assert_contains "$out" 'launch settings are unreadable' 'the unreadable cause is kept'
  assert_contains "$out" 'decide the lane by hand' 'the unreadable case has its own next action'
  assert_not_contains "$out" 'unpinned native restore' 'the unreadable case is not reported as unpinned'
  rm -f "$T/env-unreadable"
  # E3 (e): a pin for another launch generation is its own verdict, cause and next step.
  printf 'FM_SPAWN_GEN=s9.9.9\n' > "$T/env-extra"
  for kind in secondmate ship; do
    meta_for claude env-v1 "$kind"
    assert_equals pinned-elsewhere "$(fm_launch_proof_herdr "$META")" "a $kind claude pinned to another generation has its own verdict"
    out=$(fm_launch_proof_herdr_refusal "$META") && fail "a $kind claude pinned to another generation was authorized"
    assert_contains "$out" 'live agent is pinned to another launch generation' "the $kind cause names the foreign pin"
    assert_contains "$out" 'adopt cannot authorize it; Main inspects the pane and decides the lane by hand' "the $kind next step is not adopt"
    assert_not_contains "$out" 'unpinned native restore' "a $kind pinned process is not called unpinned"
    assert_not_contains "$out" 'fm-control.sh vernant-t1 adopt' "a $kind pinned process is never sent to adopt"
  done
  # The anchor's own foreign pin counts even when the process table lacks the anchor.
  : > "$T/table-empty"
  assert_equals pinned-elsewhere "$(fm_launch_proof_herdr "$META")" 'the anchor pin is read even without a process-table row'
  rm -f "$T/table-empty" "$T/env-extra"
  meta_for claude env-v1
  # A record without spawn_gen never had its environment compared, so it is not called readable.
  grep -v '^spawn_gen=' "$META" > "$T/meta-nogen" && mv "$T/meta-nogen" "$META"
  assert_equals unknown "$(fm_launch_proof_herdr "$META")" 'a versioned claude record without spawn_gen is unknown'
  out=$(fm_launch_proof_herdr_refusal "$META") && fail 'a versioned claude record without spawn_gen was authorized'
  assert_not_contains "$out" 'environment was readable' 'a record without spawn_gen does not claim a readable environment'
  assert_not_contains "$out" 'fm-control.sh vernant-t1 adopt' 'a record without spawn_gen is not sent to adopt'
  meta_for claude env-v1
  # A short-lived child in the agent's process group pinned to another generation:
  # adopt refuses that tree, so the verdict names the foreign pin, not adopt.
  printf 'PATH=/usr/bin\nHOME=%s\nFM_SPAWN_GEN=s9.9.9\n' "$OPERATOR" > "$T/env-56557"
  assert_equals pinned-elsewhere "$(fm_launch_proof_herdr "$META")" 'a group child pinned to another generation is pinned-elsewhere'
  out=$(fm_launch_proof_herdr_refusal "$META") && fail 'a claude with a foreign-pinned group child was authorized'
  assert_contains "$out" 'live agent is pinned to another launch generation' 'the group child cause names the foreign pin'
  assert_not_contains "$out" 'fm-control.sh vernant-t1 adopt' 'a foreign-pinned tree is never sent to adopt'
  fm_launch_proof_claude_adoption "$META" >/dev/null 2>"$T/adopt-err" && fail 'adopt accepted a foreign-pinned tree'
  assert_contains "$(cat "$T/adopt-err")" 'pinned to another launch generation' 'adopt refuses the same tree'
  rm -f "$T/env-56557"
  assert_equals unmanaged "$(fm_launch_proof_herdr "$META")" 'without the pinned child the plain restore is unmanaged again'
  out=$(fm_launch_proof_herdr_refusal "$META") && fail 'an unadopted unpinned claude was authorized'
  assert_contains "$out" 'unpinned native restore' 'the plain restore keeps its cause'
  assert_contains "$out" 'bin/fm-control.sh vernant-t1 adopt' 'the plain restore keeps the adopt advice'

  # Adoption is a second route: the record authorizes only while every proof still holds.
  fm_launch_proof_claude_adoption "$META" > "$STATE/vernant-t1.claude-adoption.json" 2>/dev/null \
    || fail 'could not build the adoption record'
  assert_equals managed "$(fm_launch_proof_herdr "$META")" 'an adopted record is managed while the proofs hold'
  fm_launch_proof_herdr_authorizes "$META" || fail 'an adopted lane must authorize lifecycle input'
  # (i) the pane changed hands: any contradicted proof makes the record inert again.
  printf 'FM_SPAWN_GEN=s9.9.9\n' > "$T/env-extra"
  assert_equals pinned-elsewhere "$(fm_launch_proof_herdr "$META")" 'a harness pinned elsewhere voids the adoption at use'
  rm -f "$T/env-extra"
  jq '.session_id = "0b4c1d2e-3f40-4a51-8b62-7c83d94ea5f6"' "$STATE/vernant-t1.claude-adoption.json" > "$T/rec" && mv "$T/rec" "$STATE/vernant-t1.claude-adoption.json"
  assert_equals unmanaged "$(fm_launch_proof_herdr "$META")" 'a record naming another session voids the adoption'
  fm_launch_proof_claude_adoption "$META" > "$STATE/vernant-t1.claude-adoption.json" 2>/dev/null
  jq '.pid = 4242' "$STATE/vernant-t1.claude-adoption.json" > "$T/rec" && mv "$T/rec" "$STATE/vernant-t1.claude-adoption.json"
  assert_equals unmanaged "$(fm_launch_proof_herdr "$META")" 'a record naming another process voids the adoption'
  fm_launch_proof_claude_adoption "$META" > "$STATE/vernant-t1.claude-adoption.json" 2>/dev/null
  printf 'spawn_gen=s2.2.2\n' >> "$META"
  assert_equals unmanaged "$(fm_launch_proof_herdr "$META")" 'a new launch generation leaves the old adoption inert'
  rm -f "$STATE/vernant-t1.claude-adoption.json"
  meta_for claude env-v1
  assert_equals unmanaged "$(fm_launch_proof_herdr "$META")" 'without a record the lane is unmanaged again'

  # (j) legacy and other harnesses keep their pre-proof rules; (k) a matching pin is managed.
  meta_for claude ''
  assert_equals unknown "$(fm_launch_proof_herdr "$META")" 'a legacy claude record keeps the unknown verdict'
  fm_launch_proof_herdr_authorizes "$META" || fail 'a legacy record must keep its pre-proof authorization'
  meta_for codex env-v1
  assert_equals unknown "$(fm_launch_proof_herdr "$META")" 'another harness without an adoption route keeps the unknown verdict'
  meta_for claude env-v1
  printf 'FM_SPAWN_GEN=%s\n' "$PIN_GEN" > "$T/env-extra"
  assert_equals managed "$(fm_launch_proof_herdr "$META")" 'a matching pin is managed without any adoption'
  fm_launch_proof_herdr_authorizes "$META" || fail 'a pinned claude must authorize lifecycle input'
  # Inbox retention never ends an adoption: the published tie stands while the transcript still opens with the doorbell.
  rm -f "$T/env-extra"
  meta_for claude env-v1
  fm_launch_proof_claude_adoption "$META" > "$STATE/vernant-t1.claude-adoption.json" 2>/dev/null \
    || fail 'could not adopt before the prune'
  local BRIEF_RECORD LATER
  fm_operational_doorbell_path "$DOORBELL" BRIEF_RECORD || fail 'the doorbell names no record'
  touch -t "$(date -v-8d +%Y%m%d%H%M 2>/dev/null || date -d '8 days ago' +%Y%m%d%H%M)" "$BRIEF_RECORD"
  fm_operational_record_write "$LANE/state" away-supervisor 'later input' LATER || fail 'a later inbox write failed'
  [ -n "$LATER" ] || fail 'the later inbox write returned no doorbell'
  [ ! -e "$BRIEF_RECORD" ] || fail 'the 7-day prune kept the launch brief'
  assert_equals managed "$(fm_launch_proof_herdr "$META")" 'an adoption outlives the pruned launch brief'
  fm_launch_proof_herdr_authorizes "$META" || fail 'a pruned brief ended the adoption'
  printf 'claude_session_id=0b4c1d2e-3f40-4a51-8b62-7c83d94ea5f6\n' >> "$META"
  assert_equals unmanaged "$(fm_launch_proof_herdr "$META")" 'a differing recorded session id still vetoes a kept tie'
  meta_for claude env-v1
  : > "$T/env-unreadable"
  assert_equals unknown "$(fm_launch_proof_herdr "$META")" 'a kept tie does not survive a contradicted live proof'
  rm -f "$T/env-unreadable" "$STATE/vernant-t1.claude-adoption.json"
  # A brief already past retention: only the owner's own statement of the live session ties it.
  fm_launch_proof_claude_adoption "$META" >/dev/null 2>"$T/err" && fail 'a lane with a pruned brief adopted without a tie'
  assert_contains "$(cat "$T/err")" 'no task-specific session tie' 'a pruned brief refuses with the missing tie'
  out=$(fm_launch_proof_claude_adoption "$META" "$UUID" operator 2>/dev/null) || fail 'the owner statement of the live session must adopt'
  assert_equals operator "$(printf '%s' "$out" | jq -r .tie)" 'the record names the operator tie'
  fm_launch_proof_claude_adoption "$META" 0b4c1d2e-3f40-4a51-8b62-7c83d94ea5f6 operator >/dev/null 2>"$T/err" \
    && fail 'a statement naming another session adopted'
  assert_contains "$(cat "$T/err")" 'the live session is not the session this adoption names' 'a wrong statement names its cause'
  printf 'claude_session_id=0b4c1d2e-3f40-4a51-8b62-7c83d94ea5f6\n' >> "$META"
  fm_launch_proof_claude_adoption "$META" "$UUID" operator >/dev/null 2>"$T/err" && fail 'a statement overrode the recorded veto'
  assert_contains "$(cat "$T/err")" 'recorded session id differs' 'the recorded veto wins over a statement'
  meta_for claude env-v1
  printf '%s\n' "$out" > "$STATE/vernant-t1.claude-adoption.json"
  assert_equals managed "$(fm_launch_proof_herdr "$META")" 'an operator adoption is managed while the proofs hold'
  # The recheck rereads the transcript doorbell at every use, never only the record file.
  local TRANSCRIPT ADOPTION="$STATE/vernant-t1.claude-adoption.json" tie
  TRANSCRIPT="$OPERATOR/.claude/projects/$(fm_launch_proof_claude_project_dir "$LANE")/$UUID.jsonl"
  cp "$TRANSCRIPT" "$T/task-transcript"
  jq -nc --arg ts 2026-01-01T00:00:00.000Z '{type:"user",timestamp:$ts,message:{role:"user",content:"help me with my own project"}}' > "$TRANSCRIPT"
  assert_equals unmanaged "$(fm_launch_proof_herdr "$META")" 'an operator adoption whose transcript no longer opens with the task doorbell is inert'
  rm -f "$TRANSCRIPT"
  assert_equals unmanaged "$(fm_launch_proof_herdr "$META")" 'an operator adoption whose transcript is gone is inert'
  # A hand-written record for a personal session licenses nothing, whatever tie it names.
  jq -nc --arg ts 2026-01-01T00:00:00.000Z '{type:"user",timestamp:$ts,message:{role:"user",content:"help me with my own project"}}' > "$TRANSCRIPT"
  for tie in operator launch-brief recorded; do
    jq -nc --arg gen "$PIN_GEN" --arg uuid "$UUID" --arg tie "$tie" \
      '{version:1, harness:"claude", spawn_gen:$gen, window:"lab:w1:p2", pid:53733, harness_pid:53733, session_id:$uuid, tie:$tie}' > "$ADOPTION"
    assert_equals unmanaged "$(fm_launch_proof_herdr "$META")" "a hand-written $tie record does not tie a personal session"
  done
  cp "$T/task-transcript" "$TRANSCRIPT"
  rm -f "$STATE/vernant-t1.claude-adoption.json"
  # A verdict read, recheck included, changes no file anywhere.
  snapshot() { python3 -I -c 'import os,sys
for root in sys.argv[1:]:
    for d, dirs, files in os.walk(root):
        dirs.sort()
        for n in sorted(dirs + files):
            st = os.lstat(os.path.join(d, n)); print(os.path.join(d, n), st.st_size, st.st_mtime_ns)' "$T" "$FM_HOME"; }
  fm_launch_proof_claude_adoption "$META" "$UUID" operator > "$ADOPTION" 2>/dev/null || fail 'could not re-adopt on the statement'
  local BEFORE
  BEFORE=$(snapshot)
  assert_equals managed "$(fm_launch_proof_herdr "$META")" 'the stated adoption is managed while every proof holds'
  [ "$BEFORE" = "$(snapshot)" ] || fail 'a verdict read created or changed a file'
  # N1 at use: the same pane now runs a fork of the adopted session.
  printf 'claude --resume %s --fork-session\n' "$UUID" > "$T/args"
  assert_equals unmanaged "$(fm_launch_proof_herdr "$META")" 'N1 a forked resume voids the adoption at use'
  rm -f "$T/args"
  assert_equals managed "$(fm_launch_proof_herdr "$META")" 'N1 control: the ordinary resume is managed again'
  # N6 at use: an unclassifiable line now precedes the doorbell.
  { printf 'not json\n'; cat "$T/task-transcript"; } > "$TRANSCRIPT"
  assert_equals unmanaged "$(fm_launch_proof_herdr "$META")" 'N6 an unclassifiable line before the doorbell voids the adoption at use'
  cp "$T/task-transcript" "$TRANSCRIPT"
  # F1 at use: the live argv now has the resume only inside a prompt operand.
  printf 'claude\0--append-system-prompt\0discuss --resume %s\0' "$UUID" > "$T/argv"
  assert_equals unmanaged "$(fm_launch_proof_herdr "$META")" 'F1 a prompt operand that reads like --resume voids the adoption at use'
  rm -f "$T/argv"
  assert_equals managed "$(fm_launch_proof_herdr "$META")" 'F1 control: the separate --resume is managed again'
  # F4 at use: a malformed sidechain value now precedes the doorbell.
  { printf '%s\n' '{"type":"user","isSidechain":"false","timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"mine"}}'; cat "$T/task-transcript"; } > "$TRANSCRIPT"
  assert_equals unmanaged "$(fm_launch_proof_herdr "$META")" 'F4 a non-boolean isSidechain before the doorbell voids the adoption at use'
  cp "$T/task-transcript" "$TRANSCRIPT"
  # N3 at use: an unreadable live member outside the harness descent voids the adoption;
  # one descending from the harness (the caffeinate shape, Main 022) does not.
  : > "$T/unrelated"
  assert_equals unmanaged "$(fm_launch_proof_herdr "$META")" 'N3 an unreadable live member outside the harness descent voids the adoption at use'
  rm -f "$T/unrelated"
  : > "$T/env-56557"
  assert_equals managed "$(fm_launch_proof_herdr "$META")" 'N3 an unreadable live child of the harness keeps the adoption at use'
  rm -f "$T/env-56557"
  assert_equals managed "$(fm_launch_proof_herdr "$META")" 'N3 control: managed with no extra member'
  rm -f "$STATE/vernant-t1.claude-adoption.json"
  pass 'claude verdicts: unpinned is unmanaged, adoption is rechecked at use, legacy and other harnesses are unchanged'
)

fm_test_only
test_launch_proof_omp_executable_identity
test_launch_proof_recorded_native_identity
test_launch_proof_pinned_personal_switch
test_launch_proof_claude_adoption
test_launch_proof_claude_verdict_and_refusal
