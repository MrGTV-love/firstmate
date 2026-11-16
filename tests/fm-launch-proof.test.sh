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

test_launch_proof_pinned_personal_switch() {
  local meta task="$TMP/task.jsonl" personal="$TMP/personal.jsonl"
  local SWITCH_INFO actual PINNED_STATE="$TMP/pinned-home/state"
  # Main 1777 (1): an omp token on a versioned record also passes the refusal
  # checks. The record has its own home, so no other case's record claims its
  # pane, and the probe's group and kernel cwd are answered synthetically (it
  # shares the test runner's group); every other ps query is the real one.
  mkdir -p "$PINNED_STATE"
  meta="$PINNED_STATE/pinned.meta"
  ps() {
    if [ "$*" = '-axo pid=,ppid=,pgid=' ]; then printf '%s 1 %s\n' "$PID" "$PID"; else command ps "$@"; fi
  }
  # shellcheck disable=SC2329 # the library's working-directory reader calls it
  lsof() { printf 'p%s\0\nfcwd\0n%s\0\n' "$PID" "$TMP"; }
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
    > "$PINNED_STATE/pinned.omp-session.json"
  [ "$(fm_launch_proof_herdr "$meta")" = managed ] || fail 'matching pinned task and current session must be managed'
  jq --arg personal "$personal" '.current_session_file=$personal' "$PINNED_STATE/pinned.omp-session.json" \
    > "$PINNED_STATE/pinned.omp-session.json.next"
  mv "$PINNED_STATE/pinned.omp-session.json.next" "$PINNED_STATE/pinned.omp-session.json"
  actual=$(fm_launch_proof_herdr "$meta")
  [ "$actual" = unmanaged ] || fail "same live PID retains its real kernel pin after personal switch: expected unmanaged, got $actual"
  proof_record() {
    jq -nc --arg gen "${1:-expected}" --argjson pid "${2:-$PID}" \
      --arg task "$task" --arg current "${3:-$task}" \
      '{version:1,spawn_gen:$gen,pid:$pid,task_session_file:$task,current_session_file:$current}' \
      > "$PINNED_STATE/pinned.omp-session.json"
  }
  proof_record other
  [ "$(fm_launch_proof_herdr "$meta")" = unmanaged ] || fail 'stale sidecar generation must not authenticate a live matching pin'
  proof_record expected 2000000000
  [ "$(fm_launch_proof_herdr "$meta")" = unmanaged ] || fail 'proof from another PID must not authenticate the selected process'
  proof_record expected "$PID" ''
  jq '.current_session_file=null' "$PINNED_STATE/pinned.omp-session.json" > "$TMP/invalidated"
  mv "$TMP/invalidated" "$PINNED_STATE/pinned.omp-session.json"
  [ "$(fm_launch_proof_herdr "$meta")" = unmanaged ] || fail 'shutdown-invalidated current session must not authenticate a retained pin'
  printf 'malformed\n' > "$PINNED_STATE/pinned.omp-session.json"
  [ "$(fm_launch_proof_herdr "$meta")" = unmanaged ] || fail 'malformed sidecar must not authenticate a matching pin'
  rm "$PINNED_STATE/pinned.omp-session.json"
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
  # shellcheck disable=SC2329 # the library under test calls this stand-in
  fm_backend_herdr_cli() {
    case "$*" in
      'lab pane process-info --pane w1:p1') printf '%s' "$INFO" ;;
      'lab pane get w1:p1') printf '{"result":{"pane":{"pane_id":"w1:p1"}}}' ;;
      'lab agent get w1:p1') printf '{"error":{"code":"agent_not_found"}}' ;;
      *) printf '%s\n' "$*" >> "$TMP/endpoint-violations"; return 1 ;;
    esac
  }
  PARENTS=
  # The process-group table the refusal checks read (pid ppid pgid rows); by
  # default the probe alone. Its parent links answer the live ppid reads, and
  # the synthetic helpers it names have synthetic readable environments, so no
  # real process other than the probe is read (Main 1807 (3)).
  GROUP_TABLE=
  # shellcheck disable=SC2329 # the library under test calls this stand-in
  ps() {
    if [ "$*" = '-axo pid=,ppid=' ] && [ -n "$PARENTS" ]; then
      printf '%s\n' "$PARENTS"
    elif [ "$*" = '-axo pid=,ppid=,pgid=' ]; then
      if [ -n "$GROUP_TABLE" ]; then printf '%s\n' "$GROUP_TABLE"; else printf '%s 1 %s\n' "$PID" "$PID"; fi
    elif [ "${1:-}" = -p ] && [ "${3:-} ${4:-}" = '-o ppid=' ]; then
      awk -v p="$2" '$1 == p {print $2}' <<< "${GROUP_TABLE:-$PID 1 $PID}"
    else
      command ps "$@"
    fi
  }
  eval "$(declare -f fm_remote_herdr_process_env | sed '1s/fm_remote_herdr_process_env/probe_process_env/')"
  fm_remote_herdr_process_env() {
    case "$1" in
      2|999) printf 'PATH=/synthetic\nHOME=/synthetic\n' ;;
      *) probe_process_env "$1" ;;
    esac
  }
  # The probe's kernel working directory, as the claude refusal check reads it.
  # shellcheck disable=SC2329 # the library under test calls this stand-in
  lsof() { printf 'p%s\0\nfcwd\0n%s\0\n' "$PID" "$WORKTREE"; }
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
  # Main 1807 (3): the helper Herdr listed must be in the one group table the
  # checks read; a later table that lacks it leaves it unjudged, so it refuses.
  assert_proof unknown 'a listed foreground helper the later group table lacks is not judged, so it refuses'
  GROUP_TABLE=$(printf '%s 1 %s\n2 %s %s\n' "$PID" "$PID" "$PID" "$PID")
  assert_proof managed 'kernel pin must support interpreter-based agents with foreground helpers the group table lists'
  INFO=$(printf '%s' "$INFO" | jq '.result.process_info.foreground_process_group_id = 999
    | .result.process_info.foreground_processes += [{pid:999,name:"bash",argv0:"sh",argv:["sh"]}]')
  PARENTS=$(printf '%s 999\n999 1\n2 %s\n' "$PID" "$PID")
  GROUP_TABLE=$(printf '999 1 999\n%s 999 999\n2 %s 999\n' "$PID" "$PID")
  assert_proof managed 'a launcher shell must not hide the pinned primary agent'
  INFO=$(printf '%s' "$INFO" | jq '.result.process_info.foreground_process_group_id = 2')
  assert_proof unknown 'a marked child must not authenticate an unreadable foreground leader'
  PARENTS=
  GROUP_TABLE=
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
  # Main 1709 ruling 1: a listed process the later table lacks is unaccounted
  # for, so the selector refuses rather than drop it.
  PARENTS=$(printf '%s 1\n' "$PID")
  unattributed 'a non-agent child gone from the process table refuses attribution'
  assert_proof unknown 'a vanished non-agent child leaves the pinned agent unattributed'
  foreground "$PID" "$CAT" '{"pid":4,"name":"cat","argv0":"cat","argv":["cat"]}'
  unattributed 'several vanished non-agent children refuse attribution'
  foreground 999 "$SHELL_LEADER" "$CAT"
  PARENTS=$(printf '999 1\n%s 999\n' "$PID")
  unattributed 'a vanished child beside a launcher shell refuses attribution'
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
  pass 'a listed process that vanished between the two process reads refuses attribution'

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


test_launch_proof_claude_verdict_and_refusal() (
  # Main 1637 (D1): the only proof is the launch record Firstmate wrote
  # (launch_proof=env-v1 and spawn_gen) and the FM_SPAWN_GEN token it put in the
  # agent's environment, each read once. There is no claude adoption route.
  local T="$TMP/claude-verdict"
  local LANE="$T/lane/firstmate" OPERATOR="$T/operator" STATE="$T/main-state" META out kind verdict
  mkdir -p "$T" "$LANE/state" "$STATE" "$OPERATOR"
  META="$STATE/vernant-t1.meta"
  PIN_GEN=s1793120312.10459.5003
  # shellcheck disable=SC2329 # the library under test calls this stand-in
  ps() {
    case "$*" in
      '-axo pid=,ppid=,pgid=') [ -f "$T/table-empty" ] && return 0; printf '%s\n' '53733 1 53733'; [ ! -f "$T/env-56557" ] || printf '%s\n' '56557 53733 53733' ;;
      '-axo pid=,ppid=') printf '%s\n' '53733 1' ;;
      '-p 53733 -o comm=') echo 2.1.316 ;;
      '-p 53733 -o args=') echo 'claude --resume 5a3eec19-de12-4999-bed2-bbd561089154' ;;
      *) return 1 ;;
    esac
  }
  # Every environment read is counted per process.
  # shellcheck disable=SC2329 # the library under test calls this stand-in
  fm_remote_herdr_process_env() {
    printf x >> "$T/reads-$1"
    [ "$1" != 56557 ] || { [ -f "$T/env-56557" ] && [ -s "$T/env-56557" ] || return 1; cat "$T/env-56557"; return; }
    [ -f "$T/env-unreadable" ] && return 1
    [ ! -f "$T/env-bare" ] || { printf 'ONLY=1\n'; return; }
    printf 'PATH=/usr/bin\nHOME=%s\n%s' "$OPERATOR" "$(cat "$T/env-extra" 2>/dev/null)"; }
  # Any working-directory read is recorded: only the managed path reads it, as
  # a refusal check (Main 1709 ruling 1), never as proof.
  # shellcheck disable=SC2329 # the library's working-directory reader calls it
  lsof() { : > "$T/lsof-called"; printf 'p53733\0\nfcwd\0n%s\0\n' "$LANE"; }
  # shellcheck disable=SC2329 # the library under test calls this stand-in
  fm_backend_herdr_cli() {
    case "$*" in
      'lab pane get w1:p2') [ ! -f "$T/pane-missing" ] || return 1; printf '{"result":{"pane":{"pane_id":"w1:p2"}}}' ;;
      'lab pane process-info --pane w1:p2')
        [ ! -f "$T/pane-missing" ] || return 1
        if [ -f "$T/fg-none" ]; then
          printf '%s' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","foreground_processes":[]}}}'
        elif [ -f "$T/fg-two" ]; then
          printf '%s' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","foreground_processes":[{"pid":53733,"name":"2.1.316","argv0":"claude"},{"pid":53740,"name":"2.1.316","argv0":"claude"}]}}}'
        elif [ -f "$T/fg-shell" ]; then
          printf '%s' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","foreground_process_group_id":53733,"foreground_processes":[{"pid":53733,"name":"zsh","argv0":"-zsh"}]}}}'
        else
          printf '%s' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","foreground_process_group_id":53733,"foreground_processes":[{"pid":53733,"name":"2.1.316","argv0":"claude"}]}}}'
        fi ;;
      *) return 1 ;;
    esac
  }
  row() { [ -z "${FM_TEST_ROWS:-}" ] || printf 'ROW %-90s | %s\n' "$1" "$2"; }
  # refused_row <expected-verdict> <row>: the verdict, a refusal, and its ROW line.
  refused_row() {
    local got cause
    got=$(fm_launch_proof_herdr "$META")
    assert_equals "$1" "$got" "$2"
    cause=$(fm_launch_proof_herdr_refusal "$META" "$(fm_meta_get "$META" window)") && fail "$2: authorized"
    assert_not_contains "$cause" 'adopt' "$2: never names adopt"
    row "$2" "verdict $got; refused: ${cause%%;*}"
  }
  meta_for() { # <harness> <launch_proof> [<kind>]
    printf 'window=lab:w1:p2\nherdr_session=lab\nherdr_pane_id=w1:p2\nbackend=herdr\nharness=%s\nkind=%s\nspawn_gen=%s\nworktree=%s\nhome=%s\n' \
      "$1" "${3:-secondmate}" "$PIN_GEN" "$LANE" "$LANE" > "$META"
    [ -z "${2:-}" ] || printf 'launch_proof=%s\n' "$2" >> "$META"
  }
  # verdict_once <expected> <why>: the verdict, with the agent's environment read exactly once.
  verdict_once() {
    rm -f "$T"/reads-*
    verdict=$(fm_launch_proof_herdr "$META")
    assert_equals "$1" "$verdict" "$2"
    [ "$(cat "$T/reads-53733" 2>/dev/null)" = x ] \
      || fail "$2: the agent's environment was read $(wc -c < "$T/reads-53733" 2>/dev/null | tr -d ' ') times, not once"
  }

  # The token matches the launch record: managed, with no adoption.
  meta_for claude env-v1
  printf 'FM_SPAWN_GEN=%s\n' "$PIN_GEN" > "$T/env-extra"
  verdict_once managed 'a token matching the launch record is managed'
  fm_launch_proof_herdr_authorizes "$META" "$(fm_meta_get "$META" window)" || fail 'a pinned claude must authorize lifecycle input'

  # The token is absent: an unpinned native restore, refused with its named reason.
  rm -f "$T/env-extra"
  verdict_once unmanaged 'a readable environment without the token is unmanaged'
  out=$(fm_launch_proof_herdr_refusal "$META" "$(fm_meta_get "$META" window)") && fail 'an unpinned claude was authorized'
  assert_contains "$out" 'unpinned native restore' 'the cause names an unpinned native restore'
  assert_contains "$out" 'environment was readable and carries no launch pin' 'the cause says the environment was readable and had no pin'
  assert_contains "$out" 'no Firstmate launch record proves it' 'the cause says nothing Firstmate wrote proves it'
  assert_not_contains "$out" 'adopt' 'an unpinned claude is never sent to adopt'
  assert_not_contains "$out" 'unreadable' 'the unpinned case is not called unreadable'
  for kind in ship scout; do
    meta_for claude env-v1 "$kind"
    out=$(fm_launch_proof_herdr_refusal "$META" "$(fm_meta_get "$META" window)") && fail "an unpinned claude $kind was authorized"
    assert_contains "$out" 'unpinned native restore' "the $kind cause names an unpinned native restore"
    assert_not_contains "$out" 'adopt' "a $kind is never sent to adopt"
  done

  # A claude adoption record licenses nothing, whatever it names.
  meta_for claude env-v1
  jq -nc --arg gen "$PIN_GEN" '{version:1, harness:"claude", spawn_gen:$gen, window:"lab:w1:p2", pid:53733, harness_pid:53733,
    session_id:"5a3eec19-de12-4999-bed2-bbd561089154", tie:"recorded"}' > "$STATE/vernant-t1.claude-adoption.json"
  verdict_once unmanaged 'a claude adoption record does not make an unpinned lane managed'
  fm_launch_proof_herdr_authorizes "$META" "$(fm_meta_get "$META" window)" && fail 'a claude adoption record authorized an unpinned lane'
  rm -f "$STATE/vernant-t1.claude-adoption.json"

  # The token differs: pinned to another launch, for the agent or a member of its group.
  printf 'FM_SPAWN_GEN=s9.9.9\n' > "$T/env-extra"
  for kind in secondmate ship; do
    meta_for claude env-v1 "$kind"
    verdict_once pinned-elsewhere "a $kind token for another launch is pinned-elsewhere"
    out=$(fm_launch_proof_herdr_refusal "$META" "$(fm_meta_get "$META" window)") && fail "a $kind claude pinned to another generation was authorized"
    assert_contains "$out" 'live agent is pinned to another launch generation' "the $kind cause names the foreign pin"
    assert_not_contains "$out" 'adopt' "a $kind pinned process is never sent to adopt"
  done
  : > "$T/table-empty"
  verdict_once pinned-elsewhere 'the agent token is judged even without a process-table row'
  rm -f "$T/table-empty" "$T/env-extra"
  meta_for claude env-v1
  printf 'PATH=/usr/bin\nHOME=%s\nFM_SPAWN_GEN=s9.9.9\n' "$OPERATOR" > "$T/env-56557"
  verdict_once pinned-elsewhere 'a group member pinned to another generation is pinned-elsewhere'
  [ "$(cat "$T/reads-56557" 2>/dev/null)" = x ] || fail 'the group member was not read exactly once'
  rm -f "$T/env-56557"

  # The environment cannot be read: unknown, with its own reason.
  : > "$T/env-unreadable"
  verdict_once unknown 'an unreadable environment is unknown'
  out=$(fm_launch_proof_herdr_refusal "$META" "$(fm_meta_get "$META" window)") && fail 'an unreadable claude environment was authorized'
  assert_contains "$out" 'launch settings are unreadable' 'the unreadable cause is kept'
  assert_not_contains "$out" 'unpinned native restore' 'the unreadable case is not reported as unpinned'
  rm -f "$T/env-unreadable"

  # The launch record cannot be read: no spawn_gen, or an unknown launch_proof.
  grep -v '^spawn_gen=' "$META" > "$T/meta-nogen" && mv "$T/meta-nogen" "$META"
  assert_equals unknown "$(fm_launch_proof_herdr "$META")" 'a versioned claude record without spawn_gen is unknown'
  out=$(fm_launch_proof_herdr_refusal "$META" "$(fm_meta_get "$META" window)") && fail 'a versioned claude record without spawn_gen was authorized'
  assert_not_contains "$out" 'environment was readable' 'a record without spawn_gen does not claim a readable environment'
  meta_for claude env-v9
  assert_equals unknown "$(fm_launch_proof_herdr "$META")" 'an unknown launch_proof is unknown'
  fm_launch_proof_herdr_authorizes "$META" "$(fm_meta_get "$META" window)" && fail 'an unknown launch_proof authorized lifecycle input'

  # E3 rows, as amended by Main 1637: each refuses; nothing but the token is proof.
  meta_for claude env-v1
  : > "$T/pane-missing"; refused_row unknown '(a) the recorded pane does not exist'; rm -f "$T/pane-missing"
  : > "$T/fg-none"; refused_row unknown '(b) no foreground process'; rm -f "$T/fg-none"
  : > "$T/fg-two"; refused_row unknown '(b) two foreground processes and no group'; rm -f "$T/fg-two"
  : > "$T/fg-shell"; refused_row unknown '(c) the foreground is a shell, not the harness'; rm -f "$T/fg-shell"
  rm -f "$T/lsof-called"
  refused_row unmanaged '(d) the working directory is never read: an unpinned restore refuses whatever its cwd'
  [ ! -e "$T/lsof-called" ] || fail '(d) the verdict read a working directory'
  printf 'window=lab:w1:p2\nharness=claude\nhome=%s\n' "$LANE" > "$STATE/other.meta"
  refused_row unmanaged '(f) another record claims the same pane: still refused, never adopted'
  rm -f "$STATE/other.meta"
  : > "$T/env-bare"; refused_row unknown '(g) the environment carries neither PATH nor HOME'; rm -f "$T/env-bare"
  printf 'claude_session_id=5a3eec19-de12-4999-bed2-bbd561089154\n' >> "$META"
  refused_row unmanaged '(h) T1: a recorded claude_session_id equal to the live id is no proof'
  meta_for claude env-v1
  : > "$T/env-56557"
  refused_row unmanaged 'Main 022: an unreadable live group member of an unpinned agent still refuses'
  printf 'FM_SPAWN_GEN=%s\n' "$PIN_GEN" > "$T/env-extra"
  refused_row unknown 'Main 1709 ruling 1: a matching token never authorizes while a group member is unreadable'
  rm -f "$T/env-56557"
  verdict_once managed '(k) a matching token keeps its base outcome once every refusal check passes'
  row '(k) a matching token, every refusal check passed' "verdict $verdict"
  rm -f "$T/env-extra"

  # (j) legacy and other harnesses keep their pre-proof rules.
  meta_for claude ''
  assert_equals unknown "$(fm_launch_proof_herdr "$META")" 'a legacy claude record keeps the unknown verdict'
  fm_launch_proof_herdr_authorizes "$META" "$(fm_meta_get "$META" window)" || fail 'a legacy record must keep its pre-proof authorization'
  meta_for codex env-v1
  assert_equals unknown "$(fm_launch_proof_herdr "$META")" 'another harness keeps the unknown verdict'
  pass 'claude verdicts: only the launch record and its token prove an agent, each read once; no adoption record licenses anything'
)

# Main 1709 ruling 1 and Main 1716 (A, C): a matching token is managed only after
# the refusal checks pass, in this order: the process table, each other group
# member (one environment read each), the descendant rule, the agent's kernel
# working directory, and the claim inventory. E3 (k) applies only after them.
# Every reader is synthetic; no real process, pane or home is read.
test_launch_proof_claude_refusal_checks() (
  local T="$TMP/refusal-checks"
  local H="$T/home" LANE="$T/lane" META verdict out
  mkdir -p "$H/state" "$LANE" "$T/elsewhere"
  META="$H/state/lane.meta"
  local G=s1793120312.10459.5003
  # The recorded d1 shape (evidence real-lanes.txt): the TeamClaude node wrapper
  # is attributed, claude is its child, a tool process is claude's child.
  world() {
    rm -rf "$T/w"; mkdir -p "$T/w"
    printf '%s\n' '500 1 500' '53539 500 53539' '53733 53539 53539' '56557 53733 53539' > "$T/w/table"
    printf '%s\n' '[{"pid":56557,"name":"railway","argv0":"railway"},{"pid":53733,"name":"2.1.316","argv0":"claude"},{"pid":53539,"name":"node","argv0":"node"}]' > "$T/w/fg"
    printf '53539' > "$T/w/group"
    local p
    for p in 53539 53733 56557; do printf 'PATH=/usr/bin\nHOME=/Users/op\nFM_SPAWN_GEN=%s\n' "$G" > "$T/w/env-$p"; done
    printf '%s' "$LANE" > "$T/w/cwd"
    printf 'window=lab:w1:p2\nherdr_session=lab\nherdr_pane_id=w1:p2\nbackend=herdr\nharness=claude\nkind=secondmate\nspawn_gen=%s\nworktree=%s\nhome=%s\nlaunch_proof=env-v1\n' \
      "$G" "$LANE" "$LANE" > "$META"
    find "$H/state" -name '*.meta' ! -name lane.meta -exec rm -f {} +
    rm -rf "$T/A|$T" "$T/B" "$T/C" "$H/data" "$LANE/state"
    mkdir -p "$LANE/state"
  }
  # shellcheck disable=SC2329 # the library under test calls this stand-in
  ps() {
    case "$*" in
      '-axo pid=,ppid=')
        awk '{print $1, $2}' "$T/w/table"
        [ ! -f "$T/w/ps-fail" ] || return 1 ;;
      '-axo pid=,ppid=,pgid=')
        [ ! -f "$T/w/pgid-fail" ] || { head -1 "$T/w/table"; return 1; }
        if [ -f "$T/w/no-agent" ]; then grep -v '^53539 ' "$T/w/table"
        elif [ -f "$T/w/pg-drop" ]; then grep -v "^$(cat "$T/w/pg-drop") " "$T/w/table"
        else cat "$T/w/table"; fi ;;
      '-p '*' -o ppid=')
        local p=$2
        if [ -f "$T/w/live-ppid-$p" ]; then cat "$T/w/live-ppid-$p"; else awk -v p="$p" '$1 == p {print $2}' "$T/w/table"; fi ;;
      *) return 1 ;;
    esac
  }
  # shellcheck disable=SC2329 # the library under test calls this stand-in
  fm_remote_herdr_process_env() {
    printf x >> "$T/w/reads-$1"
    [ -f "$T/w/env-$1" ] || return 1
    cat "$T/w/env-$1"
  }
  # shellcheck disable=SC2329 # the library's working-directory reader calls it
  lsof() {
    [ ! -f "$T/w/cwd-fail" ] || return 1
    printf 'p53539\0\nfcwd\0n%s\0\n' "$(cat "$T/w/cwd")"
    [ ! -f "$T/w/cwd-partial" ] || return 1
  }
  # shellcheck disable=SC2329 # the library under test calls this stand-in
  fm_backend_herdr_cli() {
    case "$*" in
      'lab pane process-info --pane w1:p2')
        # A record replaced while the decision runs (Main 1807 (2)).
        if [ -f "$T/w/rewrite" ]; then cp "$T/w/rewrite" "$META"; rm -f "$T/w/rewrite"; fi
        jq -nc --argjson fg "$(cat "$T/w/fg")" --argjson group "$(cat "$T/w/group")" \
          '{result:{type:"pane_process_info",process_info:{pane_id:"w1:p2",foreground_process_group_id:$group,foreground_processes:$fg}}}' ;;
      *) return 1 ;;
    esac
  }
  row() { [ -z "${FM_TEST_ROWS:-}" ] || printf 'ROW %-90s | %s\n' "$1" "$2"; }
  # judged <expected-verdict> <row> [<cause substring>]
  judged() {
    verdict=$(fm_launch_proof_herdr "$META")
    assert_equals "$1" "$verdict" "$2"
    if [ "$1" = managed ]; then
      fm_launch_proof_herdr_authorizes "$META" "$(fm_meta_get "$META" window)" || fail "$2: a managed agent was refused"
      row "$2" "verdict managed; authorized"
      return 0
    fi
    out=$(fm_launch_proof_herdr_refusal "$META" "$(fm_meta_get "$META" window)") && fail "$2: authorized"
    [ -z "${3:-}" ] || assert_contains "$out" "$3" "$2: names its cause"
    assert_not_contains "$out" 'adopt' "$2: never names adopt"
    row "$2" "verdict $verdict; refused: ${out%%;*}"
  }

  world
  judged managed '(k) the recorded d1 shape with a matching token passes every refusal check'
  rm -f "$T"/w/reads-*
  assert_equals managed "$(fm_launch_proof_herdr "$META")" '(k) one verdict'
  for p in 53539 53733 56557; do
    [ "$(cat "$T/w/reads-$p" 2>/dev/null)" = x ] || fail "(k) the environment of $p was not read exactly once"
  done

  # Members, one environment read each (falsify-matching-pin.py).
  world; printf 'PATH=/usr/bin\nHOME=/Users/op\nFM_SPAWN_GEN=s9.9.9\n' > "$T/w/env-56557"
  judged pinned-elsewhere '(e) a matching token with a group member pinned to another generation' 'pinned to another launch generation'
  world; rm "$T/w/env-56557"
  judged unknown 'Main 1716 (A): a matching token with an unreadable group member' 'environment of live group process 56557 cannot be read'
  world; printf 'ONLY=1\n' > "$T/w/env-56557"
  judged unknown '(g) a matching token with a member whose environment shows neither PATH nor HOME' 'environment of live group process 56557 cannot be read'
  world; printf 'PATH=/usr/bin\nHOME=/Users/op\n' > "$T/w/env-56557"
  judged managed 'control: a readable descendant without the token is the agent'"'"'s own'

  # The descendant rule, as a refusal only.
  world; printf '%s\n' '60000 500 53539' >> "$T/w/table"; printf 'PATH=/usr/bin\nHOME=/Users/op\nFM_SPAWN_GEN=%s\n' "$G" > "$T/w/env-60000"
  judged contested 'a readable group member that is neither the agent, its launcher nor its descendant' 'live group process 60000 is not the agent'
  world; printf '1' > "$T/w/live-ppid-56557"
  judged unknown 'a parent link that changed between the table and the live read' 'parent chain of live group process 56557 changed'
  world
  printf '%s\n' '400 1 400' '53539 400 400' '53733 53539 400' '56557 53733 400' > "$T/w/table"
  printf '400' > "$T/w/group"
  printf '%s\n' '[{"pid":400,"name":"zsh","argv0":"-zsh"},{"pid":56557,"name":"railway","argv0":"railway"},{"pid":53733,"name":"2.1.316","argv0":"claude"},{"pid":53539,"name":"node","argv0":"node"}]' > "$T/w/fg"
  printf 'PATH=/usr/bin\nHOME=/Users/op\n' > "$T/w/env-400"
  judged managed 'control: a launcher shell that leads the group is the agent'"'"'s ancestor'

  # The process table.
  world; : > "$T/w/pgid-fail"
  judged unknown 'a process-group table that is partial or fails' 'process table could not be read'
  world; : > "$T/w/no-agent"
  judged unknown 'a process-group table that does not list the attributed agent' 'does not list the attributed agent'

  # Main 1807 (3): a process Herdr listed must be in the one group table the
  # checks read; the earlier parent table still lists it, the group table not.
  world; printf '56557' > "$T/w/pg-drop"
  judged unknown 'a listed foreground process missing from the later group table' 'is missing from the process-group table'

  # Main 1807 (2): the record is read once; a replacement while the decision
  # runs (here, to a record with no launch_proof line) does not change it.
  # The replacement happens inside the one authorization decision.
  world; printf '%s' "$T/elsewhere" > "$T/w/cwd"
  grep -v '^launch_proof=' "$META" > "$T/w/rewrite"
  out=$(fm_launch_proof_herdr_refusal "$META" "$(fm_meta_get "$META" window)") && fail 'a record replaced by a legacy one during the decision was authorized'
  assert_contains "$out" 'working directory is not this task' 'the first bytes decide: the versioned checks refuse'
  row 'a versioned record replaced by a legacy one during the decision' "refused: ${out%%;*}"
  world; printf '%s' "$T/elsewhere" > "$T/w/cwd"
  fm_launch_proof_herdr_authorizes "$META" "$(fm_meta_get "$META" window)" && fail 'control: a stable versioned record with a foreign cwd was authorized'
  world; grep -v '^launch_proof=' "$META" > "$META.next"; mv "$META.next" "$META"; printf '%s' "$T/elsewhere" > "$T/w/cwd"
  fm_launch_proof_herdr_authorizes "$META" "$(fm_meta_get "$META" window)" || fail 'control: a genuine legacy record lost its authorization'

  # The agent's kernel working directory.
  world; printf '%s' "$T/elsewhere" > "$T/w/cwd"
  judged contested '(d) a matching token whose working directory is not the recorded home or worktree' 'working directory is not this task'
  world; : > "$T/w/cwd-fail"
  judged unknown 'a working directory that cannot be read' 'working directory cannot be read'
  world; : > "$T/w/cwd-partial"
  judged unknown 'a working-directory read that prints and then fails' 'working directory cannot be read'

  # The claim inventory, in this home and in the homes its records name.
  world; printf 'window=lab:w1:p2\nharness=claude\n' > "$H/state/other.meta"
  judged contested '(f) a matching token while another record claims the same pane' 'another task record (other.meta)'
  world; printf 'window=lab:w7:p7\nherdr_session=lab\nherdr_pane_id=w1:p2\n' > "$H/state/other.meta"
  judged contested '(f) another record names the same Herdr session and pane' 'another task record (other.meta)'
  world; printf 'window=lab:w7:p7\nhome=%s\n' "$LANE" > "$H/state/other.meta"
  judged contested 'another record names the same home' 'another task record (other.meta)'
  world; printf 'window=lab:w7:p7\nworktree=%s\n' "$LANE" > "$H/state/other.meta"
  judged contested 'another record names the same worktree' 'another task record (other.meta)'
  world; printf 'window=lab:w1:p2\nremote_host=mini\n' > "$H/state/other.meta"
  judged managed 'control: a remote record naming the same window is another host'"'"'s pane'
  world; printf 'window=lab:w7:p7\n' > "$H/state/other.meta"; chmod 000 "$H/state/other.meta"
  if [ -r "$H/state/other.meta" ]; then
    pass 'skip: this user can read a mode-000 file, so the unreadable-record row cannot be staged'
  else
    judged unknown 'a task record that cannot be read' 'cannot all be read'
  fi
  chmod 600 "$H/state/other.meta"
  # D2: a home path that contains the separator of a joined seen-list.
  world
  mkdir -p "$T/A|$T/B/state" "$T/B/state"
  printf 'window=lab:w8:p8\nkind=secondmate\nhome=%s\n' "$T/A|$T/B" > "$H/state/a-first.meta"
  printf 'window=lab:w9:p9\nkind=secondmate\nhome=%s\n' "$T/B" > "$H/state/b-second.meta"
  printf 'window=lab:w1:p2\n' > "$T/B/state/claimer.meta"
  judged contested 'D2: a claim in a home whose path is a suffix of an earlier home'"'"'s path' 'another task record (claimer.meta)'
  world; mkdir -p "$T/C/state"
  printf 'window=lab:w8:p8\nkind=secondmate\nhome=%s\n' "$T/C" > "$H/state/c.meta"
  printf 'window=lab:w9:p9\nkind=secondmate\nhome=%s\n' "$H" > "$T/C/state/back.meta"
  judged managed 'control: a cycle of secondmate homes with no competing claim ends'
  world; printf 'window=lab:w8:p8\nkind=secondmate\nhome=%s\n' "$T/gone" > "$H/state/gone.meta"
  judged unknown 'a secondmate home named by a record whose task records cannot be read' 'cannot all be read'
  world; mkdir -p "$H/data"; printf -- '- local-gone - test home (home: %s; scope: test; projects: none; added 2026-11-15)\n' "$T/missing-home" > "$H/data/secondmates.md"
  judged unknown 'a registered local home that cannot be reached' 'cannot all be read'
  rm -rf "$H/data"

  # Main 1716 (C): on the host verb path only the record's own state directory
  # and the home it names are read, without bin/fm-wake-lib.sh.
  world; mkdir -p "$H/data"; printf -- '- local-gone - test home (home: %s; scope: test; projects: none; added 2026-11-15)\n' "$T/missing-home" > "$H/data/secondmates.md"
  verdict=$(FM_LAUNCH_PROOF_VERB_PATH=1 fm_launch_proof_herdr "$META")
  assert_equals managed "$verdict" 'C2 control: the verb path does not walk the root inventory'
  mkdir -p "$LANE/state"; printf 'window=lab:w1:p2\n' > "$LANE/state/crew.meta"
  verdict=$(FM_LAUNCH_PROOF_VERB_PATH=1 fm_launch_proof_herdr "$META")
  assert_equals contested "$verdict" 'C2: the verb path reads the home the record names'
  rm -rf "$H/data"
  world; sed "s|^home=.*|home=$T/gone|" "$META" > "$META.next"; mv "$META.next" "$META"
  verdict=$(FM_LAUNCH_PROOF_VERB_PATH=1 fm_launch_proof_herdr "$META")
  assert_not_equals managed "$verdict" 'C2: the verb path refuses when the named home cannot be read'

  # Ruling 2 (Main 1716 B): only a positively read record decides legacy or versioned.
  world; rm -f "$T"/w/env-*; printf 'PATH=/usr/bin\nHOME=/Users/op\n' > "$T/w/env-53539"
  printf 'PATH=/usr/bin\nHOME=/Users/op\n' > "$T/w/env-53733"; printf 'PATH=/usr/bin\nHOME=/Users/op\n' > "$T/w/env-56557"
  out=$(fm_launch_proof_herdr_refusal "$META" "$(fm_meta_get "$META" window)") && fail 'an unpinned versioned record was authorized'
  assert_contains "$out" 'unpinned native restore' 'the unpinned d1 wrapper shape names an unpinned native restore'
  assert_not_contains "$out" 'unreadable' 'the unpinned d1 wrapper shape is not called unreadable'
  grep -v '^launch_proof=' "$META" > "$META.next"; mv "$META.next" "$META"
  fm_launch_proof_herdr_authorizes "$META" "$(fm_meta_get "$META" window)" || fail '(j) control: a record with no launch_proof line keeps its legacy authorization'
  fm_launch_proof_record_legacy "$META" || fail '(j) control: a record with no launch_proof line is legacy'
  for shape in 'env-v1,' ',' 'env-v1,env-v1' 'env-v9' 'legacy' 'absent'; do
    grep -v '^launch_proof=' "$META" > "$META.next"; mv "$META.next" "$META"
    printf '%s\n' "$shape" | tr ',' '\n' | sed '/^$/d;s/^/launch_proof=/' >> "$META"
    case "$shape" in ','|'env-v1,') printf 'launch_proof=\n' >> "$META" ;; esac
    out=$(fm_launch_proof_herdr_refusal "$META" "$(fm_meta_get "$META" window)") && fail "a record with launch_proof lines '$shape' was authorized"
    fm_launch_proof_record_legacy "$META" && fail "a record with launch_proof lines '$shape' was read as legacy"
    assert_not_equals managed "$(fm_launch_proof_herdr "$META")" "launch_proof lines '$shape' are not managed"
  done
  grep -v '^launch_proof=' "$META" > "$META.next"; mv "$META.next" "$META"; printf 'launch_proof=env-v1\nlaunch_proof=\n' >> "$META"
  out=$(fm_launch_proof_herdr_refusal "$META" "$(fm_meta_get "$META" window)") && fail 'a duplicated launch_proof was authorized'
  assert_contains "$out" 'launch record' 'the record cause names the launch record'
  rm -f "$META"
  fm_launch_proof_herdr_authorizes "$META" "$(fm_meta_get "$META" window)" && fail 'a missing record was authorized'
  fm_launch_proof_record_legacy "$META" && fail 'a missing record was read as legacy'
  pass 'a matching token is managed only after the table, member, descendant, cwd and claim checks pass; only one well-formed record decides'
)

# Main 1709 ruling 1: the foreground selector refuses when a listed process is
# missing from the later table, or when that table read fails or is partial
# (falsify-missing-foreground.py), for any harness.
test_launch_proof_selector_refuses_missing_or_failed_reads() (
  local T="$TMP/selector" META scenario harness
  mkdir -p "$T"
  META="$T/sel.meta"
  printf 'window=lab:w1:p2\nharness=claude\nspawn_gen=s1\nlaunch_proof=env-v1\n' > "$META"
  # shellcheck disable=SC2329 # the selector under test calls it
  ps() {
    [ "$*" = '-axo pid=,ppid=' ] || return 1
    printf '3101 1\n'
    case "$scenario" in stable) printf '3102 3101\n' ;; missing-member) ;; partial-failure) return 1 ;; esac
  }
  for harness in claude omp; do
    # shellcheck disable=SC2329 # the selector under test calls it
    fm_backend_herdr_cli() {
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","foreground_process_group_id":3101,"foreground_processes":[{"pid":3101,"name":"%s","argv0":"%s"},{"pid":3102,"name":"helper","argv0":"helper"}]}}}' "$harness" "$harness"
    }
    scenario=stable
    assert_equals 3101 "$(fm_launch_proof_herdr_pid "$META")" "$harness control: a stable table attributes the agent"
    for scenario in missing-member partial-failure; do
      fm_launch_proof_herdr_pid "$META" >/dev/null && fail "$harness $scenario: the selector attributed a foreground"
    done
  done
  pass 'the foreground selector refuses a listed process missing from the table and a failed or partial table read'
)

# Main 1777 (1): the refusal checks apply to every harness whose launch record
# carries the matching token (launch_proof=env-v1), not only claude. A legacy
# record (no launch_proof line) keeps its base outcome. Synthetic readers only.
test_launch_proof_token_checks_every_harness() (
  local T="$TMP/every-agent_name" H LANE META G=s42.1.1 agent_name verdict
  H="$T/home" LANE="$T/lane"
  mkdir -p "$H/state" "$LANE/state" "$T/w"
  META="$H/state/lane.meta"
  : > "$LANE/task.jsonl"
  record() { # <agent_name> <launch_proof|''>
    printf 'window=lab:w1:p2\nherdr_session=lab\nherdr_pane_id=w1:p2\nbackend=herdr\nharness=%s\nkind=ship\nspawn_gen=%s\nworktree=%s\nhome=%s\n' \
      "$1" "$G" "$LANE" "$LANE" > "$META"
    [ -z "$2" ] || printf 'launch_proof=%s\n' "$2" >> "$META"
    jq -nc --arg gen "$G" --arg task "$LANE/task.jsonl" \
      '{version:1,spawn_gen:$gen,pid:7101,task_session_file:$task,current_session_file:$task}' > "$H/state/lane.omp-session.json"
    rm -f "$T"/w/env-*
    printf 'PATH=/usr/bin\nHOME=/Users/op\nFM_SPAWN_GEN=%s\n' "$G" > "$T/w/env-7101"
    printf 'PATH=/usr/bin\nHOME=/Users/op\n' > "$T/w/env-7102"
  }
  # shellcheck disable=SC2329 # the library under test calls this stand-in
  ps() {
    case "$*" in
      '-axo pid=,ppid=') printf '7101 1\n7102 7101\n' ;;
      '-axo pid=,ppid=,pgid=') printf '7101 1 7101\n7102 7101 7101\n' ;;
      '-p 7102 -o ppid=') printf '7101\n' ;;
      '-p 7101 -o ppid=') printf '1\n' ;;
      '-p 7101 -o comm='|'-p 7101 -o args=') printf '%s\n' "$agent_name" ;;
      *) return 1 ;;
    esac
  }
  # shellcheck disable=SC2329 # the library under test calls this stand-in
  fm_remote_herdr_process_env() { [ -f "$T/w/env-$1" ] || return 1; cat "$T/w/env-$1"; }
  # shellcheck disable=SC2329 # the library's working-directory reader calls it
  lsof() { printf 'p7101\0\nfcwd\0n%s\0\n' "$LANE"; }
  # shellcheck disable=SC2329 # the library under test calls this stand-in
  fm_backend_herdr_cli() {
    case "$*" in
      'lab pane process-info --pane w1:p2')
        jq -nc --arg name "$agent_name" '{result:{type:"pane_process_info",process_info:{pane_id:"w1:p2",foreground_process_group_id:7101,
          foreground_processes:[{pid:7101,name:$name,argv0:$name},{pid:7102,name:"helper",argv0:"helper"}]}}}' ;;
      *) return 1 ;;
    esac
  }
  row() { [ -z "${FM_TEST_ROWS:-}" ] || printf 'ROW %-90s | %s\n' "$1" "$2"; }
  for agent_name in codex omp; do
    record "$agent_name" env-v1
    verdict=$(fm_launch_proof_herdr "$META")
    assert_equals managed "$verdict" "$agent_name control: a matching token with a clean group is managed"
    fm_launch_proof_herdr_authorizes "$META" "$(fm_meta_get "$META" window)" || fail "$agent_name control: a clean managed agent was refused"
    row "$agent_name control: matching token, clean group" "verdict $verdict"
    printf 'PATH=/usr/bin\nHOME=/Users/op\nFM_SPAWN_GEN=s9.9.9\n' > "$T/w/env-7102"
    verdict=$(fm_launch_proof_herdr "$META")
    assert_equals pinned-elsewhere "$verdict" "$agent_name: a matching token with a member pinned to another generation"
    fm_launch_proof_herdr_authorizes "$META" "$(fm_meta_get "$META" window)" && fail "$agent_name: a foreign-pinned member was authorized"
    row "$agent_name: matching token, member pinned elsewhere" "verdict $verdict; refused"
    rm -f "$T/w/env-7102"
    verdict=$(fm_launch_proof_herdr "$META")
    assert_equals unknown "$verdict" "$agent_name: a matching token with an unreadable member"
    fm_launch_proof_herdr_authorizes "$META" "$(fm_meta_get "$META" window)" && fail "$agent_name: an unreadable member was authorized"
    row "$agent_name: matching token, unreadable member" "verdict $verdict; refused"
    printf 'PATH=/usr/bin\nHOME=/Users/op\n' > "$T/w/env-7102"
    printf 'window=lab:w1:p2\n' > "$H/state/other.meta"
    verdict=$(fm_launch_proof_herdr "$META")
    assert_equals contested "$verdict" "$agent_name: a matching token while another record claims the pane"
    fm_launch_proof_herdr_authorizes "$META" "$(fm_meta_get "$META" window)" && fail "$agent_name: a claimed pane was authorized"
    row "$agent_name: matching token, pane claimed by another record" "verdict $verdict; refused"
    rm -f "$H/state/other.meta"
  done
  # Legacy control: no launch_proof line keeps the base outcome, checks unread.
  agent_name=codex
  record codex ''
  printf 'PATH=/usr/bin\nHOME=/Users/op\nFM_SPAWN_GEN=s9.9.9\n' > "$T/w/env-7102"
  verdict=$(fm_launch_proof_herdr "$META")
  assert_equals managed "$verdict" 'legacy control: a record with no launch_proof keeps its base managed outcome'
  fm_launch_proof_herdr_authorizes "$META" "$(fm_meta_get "$META" window)" || fail 'legacy control: a legacy record lost its authorization'
  row 'legacy control: codex record with no launch_proof, member pinned elsewhere' "verdict $verdict (base outcome)"
  pass 'every agent_name with a versioned record passes the refusal checks before a matching token is managed; a legacy record keeps its base outcome'
)

# Main 1856 F6, F7, F8 and (b): a NUL byte in a record or a peer refuses, a
# failed peer read refuses the claim, a short group-table row or a parent read
# that prints and then fails refuses, and a claude alias whose record carries
# the token gets the same checks. Every reader is a stand-in.
test_launch_proof_round8_reads() (
  local T="$TMP/round8" META G=s8.1.1 TABLE LIVE_FAIL='' FOREIGN='' verdict
  mkdir -p "$T/home/state" "$T/lane/state"
  META="$T/home/state/lane.meta"
  # The claim inventory reads only this state directory and the named home.
  # shellcheck disable=SC2030 # each case scopes this to its own subshell
  local -x FM_LAUNCH_PROOF_VERB_PATH=1
  record() { # <harness> [no-proof]
    printf 'window=lab:w1:p2\nherdr_session=lab\nherdr_pane_id=w1:p2\nbackend=herdr\nharness=%s\nkind=ship\nspawn_gen=%s\nworktree=%s\nhome=%s\n' \
      "$1" "$G" "$T/lane" "$T/lane" > "$META"
    [ "${2:-}" = no-proof ] || printf 'launch_proof=env-v1\n' >> "$META"
  }
  TABLE=$(printf '7101 1 7101\n7102 7101 7101')
  # shellcheck disable=SC2329 # the library's process readers call these stand-ins
  ps() {
    case "$*" in
      '-axo pid=,ppid=,pgid=') printf '%s\n' "$TABLE" ;;
      '-axo pid=,ppid=') printf '7101 1\n7102 7101\n' ;;
      '-p 7102 -o ppid=') printf '7101\n'; [ -z "$LIVE_FAIL" ] || return 1 ;;
      '-p 7101 -o ppid=') printf '1\n' ;;
      *) return 1 ;;
    esac
  }
  # shellcheck disable=SC2329
  fm_remote_herdr_process_env() {
    case "$1" in
      7101) printf 'PATH=/x\nHOME=/y\nFM_SPAWN_GEN=%s\n' "$G" ;;
      7102) printf 'PATH=/x\nHOME=/y\n'; [ -z "$FOREIGN" ] || printf 'FM_SPAWN_GEN=s9\n' ;;
      *) return 1 ;;
    esac
  }
  # shellcheck disable=SC2329
  lsof() { printf 'p7101\0\nfcwd\0n%s\0\n' "$T/lane"; }
  # shellcheck disable=SC2329
  fm_agent_process_classify_name() { printf agent; }
  # shellcheck disable=SC2329
  fm_backend_herdr_cli() {
    printf '%s' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","foreground_process_group_id":7101,"foreground_processes":[{"pid":7101,"name":"agent","argv0":"agent"},{"pid":7102,"name":"helper","argv0":"helper"}]}}}'
  }
  record claude
  assert_equals managed "$(fm_launch_proof_herdr "$META")" 'F6 control: a clean versioned record is managed'
  record claude no-proof
  printf 'launch_proof=env-v1\000\n' >> "$META"
  assert_equals unknown "$(fm_launch_proof_herdr "$META")" 'F6: a launch_proof value followed by a NUL byte is unknown'
  fm_launch_proof_herdr_authorizes "$META" "$(fm_meta_get "$META" window)" && fail 'F6: a NUL-bearing record was authorized'
  record claude
  printf 'window=lab:w9:p9\n' > "$T/home/state/peer.meta"
  assert_equals managed "$(fm_launch_proof_herdr "$META")" 'F7 control: a readable peer naming another pane'
  printf 'window=lab:w1:p2\n' > "$T/home/state/peer.meta"
  assert_equals contested "$(fm_launch_proof_herdr "$META")" 'F7 control: a readable peer claiming this pane'
  printf 'window=lab:w9:p9\n' > "$T/home/state/peer.meta"
  # shellcheck disable=SC2329
  cat() { case "$*" in *peer.meta*) return 1 ;; *) command cat "$@" ;; esac; }
  assert_equals unknown "$(fm_launch_proof_herdr "$META")" 'F7: a peer read that fails after its readability test is unknown'
  unset -f cat
  printf 'window=lab:w9\000\n' > "$T/home/state/peer.meta"
  assert_equals unknown "$(fm_launch_proof_herdr "$META")" 'F7: a peer record holding a NUL byte is unknown'
  rm -f "$T/home/state/peer.meta"
  TABLE=$(printf '7101 1 7101\n7102 7101')
  assert_equals unknown "$(fm_launch_proof_herdr "$META")" 'F8: a group table with a short row is unknown'
  TABLE=$(printf '7101 1 7101\n7102 7101 7101')
  LIVE_FAIL=1
  assert_equals unknown "$(fm_launch_proof_herdr "$META")" 'F8: a parent read that prints a parent and then fails is unknown'
  LIVE_FAIL=
  assert_equals managed "$(fm_launch_proof_herdr "$META")" 'F8 control: a complete table and clean reads'
  record claude-custom
  assert_equals managed "$(fm_launch_proof_herdr "$META")" '(b) control: a claude alias with the token and a clean group'
  FOREIGN=1
  assert_equals pinned-elsewhere "$(fm_launch_proof_herdr "$META")" '(b): a claude alias with the token and a member pinned elsewhere'
  pass 'records and peers are read as bytes, failed reads and short rows refuse, and a claude alias with the token gets the same checks'
)

# Main 1874 finding 4: the claim inventory reads each peer once, and the homes
# it follows come from that same read. The stable controls keep their outcome:
# a ship peer's home is not followed, and a secondmate peer's home whose record
# claims the pane is a claim. A peer rewritten right after its read (a nonclaim
# ship record that becomes a secondmate naming the claiming home) is never read
# a second time, so the decision rests on the bytes it judged.
test_launch_proof_claims_follow_homes_from_one_read() (
  local T="$TMP/claims-one-read" META rc REWRITE=''
  mkdir -p "$T/home/state" "$T/lane/state" "$T/other/state"
  META="$T/home/state/lane.meta"
  printf 'window=lab:w1:p2\nharness=claude\nhome=%s\n' "$T/lane" > "$META"
  printf 'window=lab:w1:p2\n' > "$T/other/state/claimer.meta"
  # shellcheck disable=SC2030,SC2031 # each case scopes this to its own subshell
  local -x FM_LAUNCH_PROOF_VERB_PATH=
  # shellcheck disable=SC2329 # the inventory calls this stand-in
  fm_launch_proof_claim_states() { :; }
  eval "real_$(declare -f fm_launch_proof_bytes)"
  # shellcheck disable=SC2329 # the claim scan reads each peer through this seam
  fm_launch_proof_bytes() {
    real_fm_launch_proof_bytes "$@" || return
    case "$1" in
      */peer.meta)
        printf 'read\n' >> "$T/peer-reads"
        [ -z "$REWRITE" ] || printf 'window=lab:w8:p8\nkind=secondmate\nhome=%s\n' "$T/other" > "$1"
        ;;
    esac
  }
  printf 'window=lab:w8:p8\nkind=ship\nhome=%s\n' "$T/other" > "$T/home/state/peer.meta"
  fm_launch_proof_claims "$META" "$T/lane" "$T/lane" "$T/lane" >/dev/null || fail 'control: a ship peer home was followed'
  printf 'window=lab:w8:p8\nkind=secondmate\nhome=%s\n' "$T/other" > "$T/home/state/peer.meta"
  rc=0; fm_launch_proof_claims "$META" "$T/lane" "$T/lane" "$T/lane" >/dev/null || rc=$?
  assert_equals 1 "$rc" 'control: a secondmate peer home whose record claims the pane is a claim'
  printf 'window=lab:w8:p8\nkind=ship\nhome=%s\n' "$T/other" > "$T/home/state/peer.meta"
  rm -f "$T/peer-reads"; REWRITE=1
  rc=0; fm_launch_proof_claims "$META" "$T/lane" "$T/lane" "$T/lane" >/dev/null || rc=$?
  REWRITE=''
  assert_equals 1 "$(grep -c . "$T/peer-reads")" 'a peer rewritten after its read was read a second time'
  assert_equals 0 "$rc" 'the decision rests on the bytes it judged: a ship peer, whose home is not followed'
  pass 'the claim inventory reads each peer once and follows secondmate homes from that read'
)

# Main 1874 finding 7: the foreground selector refuses a parent table with a
# short row, even when every listed process and its ancestry are present.
test_launch_proof_selector_refuses_a_short_parent_row() (
  local T="$TMP/selector-short" META SHORT=''
  mkdir -p "$T/home/state"
  META="$T/home/state/s.meta"
  printf 'window=lab:w1:p2\nharness=claude\n' > "$META"
  # shellcheck disable=SC2329 # the selector calls these stand-ins
  fm_backend_herdr_cli() {
    printf '%s' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","foreground_process_group_id":7101,"foreground_processes":[{"pid":7101,"name":"agent","argv0":"agent"},{"pid":7102,"name":"helper","argv0":"helper"}]}}}'
  }
  # shellcheck disable=SC2329
  fm_agent_process_classify_name() { printf agent; }
  # shellcheck disable=SC2329
  ps() { case "$*" in '-axo pid=,ppid=') printf '7101 1\n7102 7101\n'; [ -z "$SHORT" ] || printf '7103\n' ;; *) return 1 ;; esac; }
  assert_equals 7101 "$(fm_launch_proof_herdr_pid "$META")" 'control: a complete parent table selects the agent'
  SHORT=1
  fm_launch_proof_herdr_pid "$META" >/dev/null && fail 'a parent table with a short row selected an agent'
  pass 'the foreground selector refuses a parent table with a short row and keeps the complete-table control'
)

# Main 1874 finding 2 and (ii): the proof is bound to the endpoint the caller
# acts on, and the endpoint is mandatory. The restart's local decision reads
# its record once: a record that names p1 when the decision reads it and p2
# while the agent state is read never proves p2 for a kept p1 route.
test_launch_proof_binds_the_acting_endpoint() (
  local T="$TMP/bind-endpoint" META P1_PIN=s1 REWRITE='' SHORT='' rc
  mkdir -p "$T/home/state" "$T/lane/state"
  META="$T/home/state/sm.meta"
  rec() { # <pane> -> a coherent local Herdr secondmate record naming lab:w1:<pane>
    printf 'window=lab:w1:%s\nendpoint_task_id=sm\nworktree=%s\nproject=%s\nherdr_session=lab\nherdr_workspace_id=w1\nherdr_tab_id=w1:t1\nherdr_pane_id=w1:%s\nbackend=herdr\nharness=claude\nkind=secondmate\nspawn_gen=s1\nhome=%s\nlaunch_proof=env-v1\n' \
      "$1" "$T/lane" "$T/lane" "$1" "$T/lane"
  }
  # shellcheck disable=SC2030,SC2031 # each case scopes this to its own subshell
  local -x FM_LAUNCH_PROOF_VERB_PATH=1
  # shellcheck source=bin/fm-secondmate-restart-lib.sh
  . "$ROOT/bin/fm-secondmate-restart-lib.sh"
  # shellcheck disable=SC2329 # the decision calls these stand-ins
  fm_backend_source() { return 0; }
  # shellcheck disable=SC2329
  fm_backend_agent_state() { [ -z "$REWRITE" ] || rec p2 > "$META"; printf alive; }
  # shellcheck disable=SC2329
  fm_backend_herdr_cli() {
    local pane pid
    case "$*" in *'--pane w1:p1'*) pane=w1:p1 pid=7201 ;; *'--pane w1:p2'*) pane=w1:p2 pid=7202 ;; *) return 1 ;; esac
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"claude","argv0":"claude"}]}}}' "$pane" "$pid" "$pid"
  }
  # shellcheck disable=SC2329
  fm_agent_process_classify_name() { printf agent; }
  # shellcheck disable=SC2329
  ps() { case "$*" in '-axo pid=,ppid=,pgid=') printf '7201 1 7201\n7202 1 7202\n'; [ -z "$SHORT" ] || printf '7203 1\n' ;; *) return 1 ;; esac; }
  # shellcheck disable=SC2329
  lsof() { printf 'p%s\0\nfcwd\0n%s\0\n' "${4:-}" "$T/lane"; }
  # shellcheck disable=SC2329
  fm_remote_herdr_process_env() {
    printf 'PATH=/x\nHOME=/y\n'
    case "$1" in 7201) [ -z "$P1_PIN" ] || printf 'FM_SPAWN_GEN=%s\n' "$P1_PIN" ;; 7202) printf 'FM_SPAWN_GEN=s1\n' ;; esac
  }
  # Control: the record is stable and the agent in p1 is provable.
  rec p1 > "$META"
  fm_secondmate_restart_attribution "$META" || fail "control: a provable p1 agent was refused: ${FM_SECONDMATE_RESTART_REASON:-}"
  assert_equals lab:w1:p1 "$FM_SECONDMATE_RESTART_ROUTE_TARGET" 'control: the decision keeps the endpoint it proved'
  # Red: p1's agent is not provable; the record moves to p2, whose agent is.
  rec p1 > "$META"; P1_PIN=''; REWRITE=1
  rc=0; fm_secondmate_restart_attribution "$META" || rc=$?
  REWRITE=''
  assert_equals 1 "$rc" 'a decision that kept p1 must not proceed on a proof of p2'
  # The proof owner refuses without an endpoint and for another endpoint.
  rec p2 > "$META"
  fm_launch_proof_herdr_authorizes "$META" lab:w1:p2 || fail 'control: a provable p2 agent at its own endpoint was refused'
  fm_launch_proof_herdr_authorizes "$META" lab:w1:p1 && fail 'a proof of p2 authorized an action on p1'
  fm_launch_proof_herdr_authorizes "$META" && fail 'a proof with no endpoint named authorized an action'
  assert_contains "$(fm_launch_proof_recovery_judge "$META" lab:w1:p1)" 'does not name the endpoint' \
    'a recovery inspection of p1 on a p2 record is unknown'
  # Main 1874: the claude unmanaged verdict reads one complete group table; a
  # short row is unknown (it could hide a member pinned elsewhere).
  P1_PIN=''
  assert_equals unmanaged "$(fm_launch_proof_herdr_verdict "$META" 7201)" 'control: an unpinned claude with a complete table is unmanaged'
  SHORT=1
  assert_equals unknown "$(fm_launch_proof_herdr_verdict "$META" 7201)" 'an unpinned claude with a short group-table row is unknown'
  SHORT=''
  # (ii): an unpinned claude* alias is unknown and refuses, with no token path.
  sed -i.bak 's/^harness=claude$/harness=claude-custom/' "$META"
  assert_equals unknown "$(fm_launch_proof_herdr_verdict "$META" 7201)" '(ii): an unpinned claude alias is unknown'
  fm_launch_proof_herdr_authorizes "$META" lab:w1:p2 || fail '(ii) control: a claude alias with the matching token keeps its checks and passes'
  # shellcheck disable=SC2329 # the selector calls this stand-in
  fm_backend_herdr_cli() {
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","foreground_process_group_id":7201,"foreground_processes":[{"pid":7201,"name":"claude","argv0":"claude"}]}}}'
  }
  fm_launch_proof_herdr_authorizes "$META" lab:w1:p2 && fail '(ii): an unpinned claude alias was authorized'
  pass 'the proof is of the endpoint the caller acts on: no endpoint, another endpoint and a decision that kept p1 while p2 was proved all refuse; an unpinned claude alias is unknown'
)

# Main 1874, Main 1901: there is no omp adoption route. A live omp process
# without its matching launch pin is unmanaged with its named cause, even when
# its session record names it and its current session (the record the removed
# route wrote), and the authorization owner refuses it with that cause. The
# controls: a matching pin whose session record names it is managed, and a
# matching pin whose session record names another process is unmanaged with
# the session cause. Every reader is a stand-in.
test_launch_proof_omp_has_no_adoption_route() (
  local T="$TMP/omp-no-adoption" META PIN='' out
  mkdir -p "$T/home/state" "$T/wt/state"
  META="$T/home/state/om.meta"
  printf 'window=lab:w1:p2\nherdr_session=lab\nherdr_pane_id=w1:p2\nbackend=herdr\nharness=omp\nkind=ship\nspawn_gen=sA\nworktree=%s\nhome=%s\nlaunch_proof=env-v1\n' "$T/wt" "$T/wt" > "$META"
  : > "$T/session.jsonl"
  session_record() { # <pid>
    printf '{"version":1,"spawn_gen":"sA","pid":%s,"task_session_file":"%s","current_session_file":"%s"}\n' \
      "$1" "$T/session.jsonl" "$T/session.jsonl" > "$T/home/state/om.omp-session.json"
  }
  # shellcheck disable=SC2031 # each case scopes this to its own subshell
  local -x FM_LAUNCH_PROOF_VERB_PATH=1
  # shellcheck disable=SC2329 # the verdict calls these stand-ins
  fm_launch_proof_herdr_pid() { printf 4242; }
  # shellcheck disable=SC2329
  fm_remote_herdr_process_env() { printf 'PATH=/x\nHOME=/y\n'; [ -z "$PIN" ] || printf 'FM_SPAWN_GEN=%s\n' "$PIN"; }
  # shellcheck disable=SC2329
  ps() { case "$*" in '-axo pid=,ppid=,pgid=') printf '4242 1 4242\n' ;; *) return 1 ;; esac; }
  # shellcheck disable=SC2329
  lsof() { printf 'p4242\0\nfcwd\0n%s\0\n' "$T/wt"; }
  session_record 4242
  assert_equals unmanaged "$(fm_launch_proof_herdr "$META")" 'an unpinned omp whose session record names it is unmanaged'
  out=$(fm_launch_proof_herdr_refusal "$META" lab:w1:p2) && fail 'an unpinned omp with a once-adopted session record was authorized'
  assert_contains "$out" 'carries no launch pin matching this record' 'the refusal names the omp cause'
  assert_contains "$out" 'bin/fm-control.sh om relaunch' 'the refusal names the next action'
  PIN=sA
  assert_equals managed "$(fm_launch_proof_herdr "$META")" 'control: a matching pin with its session record is managed'
  fm_launch_proof_herdr_authorizes "$META" lab:w1:p2 || fail 'control: a pinned omp with its session record was refused'
  session_record 4343
  out=$(fm_launch_proof_herdr_refusal "$META" lab:w1:p2) && fail 'a pinned omp whose session record names another process was authorized'
  assert_contains "$out" 'its omp session record does not name this live process' 'the refusal names the session cause'
  pass 'omp has no adoption route: an unpinned omp refuses with its cause whatever its session record says, and a pinned omp keeps its session proof'
)

fm_test_only
test_launch_proof_recorded_native_identity
test_launch_proof_pinned_personal_switch
test_launch_proof_claude_verdict_and_refusal
test_launch_proof_claude_refusal_checks
test_launch_proof_selector_refuses_missing_or_failed_reads
test_launch_proof_token_checks_every_harness
test_launch_proof_round8_reads
test_launch_proof_omp_has_no_adoption_route
test_launch_proof_claims_follow_homes_from_one_read
test_launch_proof_selector_refuses_a_short_parent_row
test_launch_proof_binds_the_acting_endpoint
