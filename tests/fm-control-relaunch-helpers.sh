#!/usr/bin/env bash
# Shared setup and fixtures for the three control-relaunch groups:
# tests/fm-control-relaunch.test.sh, tests/fm-control-relaunch-recovery.test.sh,
# and tests/fm-control-relaunch-backends.test.sh. Each group sources this file,
# registers control_relaunch_test_cases, and calls control_relaunch_run. The
# fixtures are hermetic: a stubbed session provider and no real agent.
# The groups that source this file read globals it assigns, so they read as
# "unused" here.
# shellcheck disable=SC2034
set -u
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_ROOT_OVERRIDE

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
unset FM_MODEL_CATALOG_DIR
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tasks-axi-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-dod-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-operational-input.sh"

CONTROL="$ROOT/bin/fm-control.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
X_LINK="$ROOT/bin/fm-x-link.sh"
# fm_test_tmproot's own cleanup trap fires when its command substitution exits,
# so recreate the root before resolving it and clean it up from this file's trap.
TMP_ROOT=$(fm_test_tmproot fm-control-relaunch)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TASK_TMPS=()

# The helpers below and in the group files are a byte-for-byte move from the
# former combined suite; tests/fm-control-relaunch.test.sh keeps the original
# name and the --jev-guard entry point.

relaunch_remove_claims() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && fm_test_remove_tree "$d"
  done
  fm_test_remove_tree "$TMP_ROOT"
}

relaunch_cleanup() {
  relaunch_remove_claims
  fm_test_cleanup
}

# The same lifecycle-modelling tmux stub as tests/fm-control.test.sh: the
# harness's exit command stops the agent, and a launch-brief literal starts the
# harness named in `becomes`.
make_process_table_stub() { # <case-dir>
  local real_python
  real_python=$(command -v python3)
  cat > "$1/fakebin/ps" <<'SH'
#!/usr/bin/env bash
D=$FM_FAKE_DIR
# The one process a case stages as holding the task's worktree.
if [ -f "$D/holder-pid" ] && [ "${1:-}" = -p ] && [ "${2:-}" = "$(cat "$D/holder-pid")" ]; then
  case "${3:-} ${4:-}" in
    '-o comm=') cat "$D/holder-comm"; printf '\n'; exit 0 ;;
    '-o args=') cat "$D/holder-args"; printf '\n'; exit 0 ;;
  esac
fi
live_pane=false
for marker in "$D"/herdr-live-*; do
  [ ! -f "$marker" ] || live_pane=true
done
if [ -f "$D/herdr-agent-registration" ] \
  || { [ ! -f "$D/herdr-agent-live" ] && [ "$live_pane" = false ]; }; then
  case "$*" in
    '-axo pid=,ppid=,comm=') printf '4242 1 bash\n'; exit 0 ;;
    '-p 4242 -o args=') printf 'bash\n'; exit 0 ;;
  esac
fi
exec /bin/ps "$@"
SH
  chmod +x "$1/fakebin/ps"
  cat > "$1/fakebin/python3" <<'SH'
#!/usr/bin/env bash
D=$FM_FAKE_DIR
if [ "$#" = 2 ] && [ "$1" = - ]; then
  pid=$2
  if [ -f "$D/herdr-pids/$pid" ]; then D=$(cat "$D/herdr-pids/$pid"); fi
  expected=2000000000
  [ ! -f "$D/recovery-pid" ] || expected=$(cat "$D/recovery-pid")
  if [ -f "$D/recovery-case-id" ] && [ "$pid" = "$expected" ]; then
    [ ! -f "$D/recovery-env-unreadable" ] || exit 1
    printf 'PATH=/test\n'
    if [ -f "$D/launched-command" ]; then
      case "$(cat "$D/replacement-env" 2>/dev/null)" in
        missing) exit 0 ;;
        mismatched) printf 'FM_SPAWN_GEN=other\n'; exit 0 ;;
        unreadable) exit 1 ;;
      esac
      id=$(cat "$D/recovery-case-id")
      gen=$(grep '^spawn_gen=' "$FM_HOME/state/$id.meta" | cut -d= -f2-)
      printf 'FM_SPAWN_GEN=%s\n' "$gen"
    elif [ -f "$D/recovery-spawn-gen" ]; then
      printf 'FM_SPAWN_GEN=%s\n' "$(cat "$D/recovery-spawn-gen")"
    fi
    exit 0
  fi
  if [ -f "$D/herdr-managed-env-$pid" ]; then
    cat "$D/herdr-managed-env-$pid"
    exit 0
  fi
fi
SH
  printf '\nexec %q "$@"\n' "$real_python" >> "$1/fakebin/python3"
  chmod +x "$1/fakebin/python3"
  # The working-directory table the worktree-holder scan reads. By default it
  # holds only processes unrelated to the task - a tmux server and a shell
  # somewhere else, standing in for the several servers a busy machine always
  # has. lsof-mode: holder adds the staged holder; broken fails; partial lists some
  # processes and then fails; nocwd lists a process with no directory; empty is blind.
  cat > "$1/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
D=$FM_FAKE_DIR
encode_cwd() {
  local path=$1
  path=${path//\\/\\\\}
  path=${path//$'\xc3\xa9'/\\xc3\\xa9}
  printf '%s' "$path"
}
excluded=
while [ "$#" -gt 0 ]; do
  if [ "$1" = -p ]; then excluded=${2:-}; shift; fi
  shift
done
mode=$(cat "$D/lsof-mode" 2>/dev/null || printf none)
[ "$mode" != empty ] || exit 0
if [ "$excluded" != "^$$" ]; then
  printf 'p%s\nn%s\n' "$$" "$(encode_cwd "$(pwd -P)")"
fi
case "$mode" in
  broken) echo 'lsof: WARNING: could not read the process table' >&2; exit 1 ;;
  partial) printf 'p111\nn/\np222\nn/private/tmp\n'; echo 'lsof: WARNING: read timeout' >&2; exit 1 ;;
  nocwd) printf 'p111\nn/\np%s\n' "$(cat "$D/holder-pid")"; exit 0 ;;
  holder) printf 'p111\nn/\np222\nn/private/tmp\np%s\nn%s\n' "$(cat "$D/holder-pid")" "$(encode_cwd "$(cat "$D/holder-cwd")")"; exit 0 ;;
esac
printf 'p111\nn/\np222\nn/private/tmp\n'
exit 0
SH
  chmod +x "$1/fakebin/lsof"
}

make_tmux_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit)
          printf 'zsh' > "$D/command"
          [ -z "${FM_FAKE_EXIT_TRANSPORT_FAIL_AFTER_STOP:-}" ] || exit 1
          ;;
        *'encode launch-brief'* | *'Firstmate operational input waiting: read'*)
          printf '%s\n' "$payload" > "$D/launch"
          cat "$D/becomes" > "$D/command"
          [ -z "${FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START:-}" ] || exit 1
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
      case "$payload" in
        "cd -- '"*"'")
          if [ -f "$D/hold-relocation-cd" ]; then
            : > "$D/relocation-cd-held"
            while [ ! -f "$D/relocation-cd-release" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do /bin/sleep 0.01; done
            [ -f "$D/relocation-cd-release" ] || exit 1
          fi
          if [ ! -f "$D/ignore-cd" ]; then
            cwd=${payload#"cd -- '"}
            cwd=${cwd%"'"}
            printf '%s' "$cwd" > "$D/cwd"
          fi
          if [ -f "$D/foreign-wiring-path" ]; then
            path=$(cat "$D/foreign-wiring-path")
            mkdir -p "$(dirname "$path")"
            cp "$D/foreign-wiring" "$path"
            rm "$D/foreign-wiring-path"
            : > "$D/foreign-wiring-created"
          fi
          ;;
        'export GOTMPDIR='*)
          if [ -n "${FM_FAKE_TRACE_PREPARE:-}" ]; then
            : > "$FM_FAKE_TRACE_PREPARE"
            while [ ! -e "$FM_FAKE_TRACE_RELEASE" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do /bin/sleep 0.01; done
          fi
          ;;
        'export TRACEPARENT='*)
          printf '%s\n' "$payload" > "$D/trace-env"
          [ -z "${FM_FAKE_TRACE_EXPORTED:-}" ] || : > "$FM_FAKE_TRACE_EXPORTED"
          ;;
      esac
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*)
          cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    [ -z "${FM_FAKE_COMPOSER_READ_FAIL:-}" ] || exit 1
    if [ -s "$D/composer" ]; then
      printf '╭────╮\n│ %s  │\n╰────╯\n' "$(cat "$D/composer")"
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows)
    # The three shapes real tmux answers a per-session inventory with. The
    # first two are DEFINITIVE and classify `missing`; the third is not and
    # classifies `unreadable`.
    # Reads are counted so a case can change what the NEXT read answers: a
    # window that appears, or a server that stops answering, after the first
    # read. A case resets list-count before each verb it drives.
    count=$(( $(cat "$D/list-count" 2>/dev/null || printf 0) + 1 ))
    printf '%s' "$count" > "$D/list-count"
    if [ -f "$D/broken-after" ] && [ "$count" -gt "$(cat "$D/broken-after")" ]; then
      echo 'lost server' >&2
      exit 1
    fi
    if [ -f "$D/late-window" ] && [ "$count" -gt "$(cat "$D/late-window-after")" ]; then
      cat "$D/late-window"
      exit 0
    fi
    if [ -f "$D/server-dead" ]; then
      echo 'no server running on /tmp/tmux-1000/default' >&2
      exit 1
    fi
    if [ -f "$D/session-missing" ]; then
      echo "can't find session: $(cat "$D/session-name")" >&2
      exit 1
    fi
    if [ -f "$D/inventory-broken" ]; then
      echo 'lost server' >&2
      exit 1
    fi
    [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
  show-environment)
    knob=FM_FAKE_TMUX_ENV_
    for a in "$@"; do
      [ "$a" = -g ] && knob=FM_FAKE_TMUX_GLOBAL_ENV_
    done
    name=${!#}
    knob=$knob$name
    [ -n "${!knob+x}" ] || exit 1
    if [ "${!knob}" = - ]; then
      printf -- '-%s\n' "$name"
    else
      printf '%s=%s\n' "$name" "${!knob}"
    fi
    exit 0 ;;
  new-session)
    # Nothing in the relaunch path may ever create a session; recording the
    # call is how a refusal test proves that.
    shift
    ses=
    while [ $# -gt 0 ]; do
      case "$1" in
        -s) ses=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$ses" >> "$D/created-sessions"
    exit 0 ;;
  new-window)
    # Model the one thing an endpoint re-creation depends on: the window now
    # appears in the session inventory, so the very next agent-state read stops
    # answering `missing`. Echo a stable window id the way the real -P -F does.
    shift
    name=
    cwd=
    ses=
    while [ $# -gt 0 ]; do
      case "$1" in
        -n) name=${2:-}; shift 2 ;;
        -c) cwd=${2:-}; shift 2 ;;
        -t) ses=${2%:}; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$name" >> "$D/windows"
    printf '%s\n' "$name" >> "$D/created-windows"
    printf '%s' "$cwd" > "$D/cwd"
    printf '%s' "$ses" > "$D/session-name"
    rm -f "$D/server-dead" "$D/session-missing"
    printf '@9\n'
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_LOCK_WAITING:-}" ] || : > "$FM_FAKE_LOCK_WAITING"
exit 0
SH
  chmod +x "$fb/sleep"
  make_process_table_stub "$1"
}

# new_case <name> [id] -> echoes a case dir with a live claude ship task.
new_case() {
  local id=${2:-t1} dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' fmses > "$dir/fake/session-name"
  make_tmux_stub "$dir"
  fm_fake_version_tool "$dir/fakebin" omp FM_FAKE_OMP_VERSION 18.1.20
  printf '%s\n' "$dir"
}

# add_ship_task <case-dir> <id> [harness] [session] [worktree]
add_ship_task() {
  local dir=$1 id=$2 harness=${3:-claude} ses=${4:-fmses}
  local home="$dir/home" proj="$dir/proj" wt=${5:-"$dir/wt"}
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise relaunch behavior for $id.

## Firstmate spec
Preserve the task while replacing its agent process.
EOF
  {
    echo "window=$ses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=$harness"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$ses" > "$dir/fake/session-name"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-$id")
}

run_control() {  # <case-dir> <args...>
  local dir=$1; shift
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), and a relaunch reaches it through fm-control.sh, so this runs against a throwaway HOME;
  # without it this suite would write the developer's real ~/.claude.json.
  mkdir -p "$dir/user-home"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HERDR_SESSION="${FM_FAKE_SESSION:-}" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_REAL_GIT="${FM_REAL_GIT:-}" FM_FAKE_GIT_FAILURE="${FM_FAKE_GIT_FAILURE:-}" \
    FM_REAL_MV="${FM_REAL_MV:-}" FM_FAKE_COMPLETE_JOURNAL_MV_FAIL="${FM_FAKE_COMPLETE_JOURNAL_MV_FAIL:-}" \
    FM_FAKE_META_PUBLISH_MV_FAIL="${FM_FAKE_META_PUBLISH_MV_FAIL:-}" \
    FM_FAKE_TRACE_PREPARE="${FM_FAKE_TRACE_PREPARE:-}" \
    FM_FAKE_TRACE_RELEASE="${FM_FAKE_TRACE_RELEASE:-}" \
    FM_FAKE_META_WRITER_READY="${FM_FAKE_META_WRITER_READY:-}" \
    FM_FAKE_TRACE_EXPORTED="${FM_FAKE_TRACE_EXPORTED:-}" \
    "$CONTROL" "$@" 2>&1
}

run_spawn() {  # <case-dir> <args...>
  local dir=$1; shift
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), so it runs against a throwaway HOME;
  # without it this suite would write the developer's real ~/.claude.json.
  mkdir -p "$dir/user-home"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HERDR_SESSION="${FM_FAKE_SESSION:-}" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    "$SPAWN" "$@" 2>&1
}

# Execute the complete staged replacement command with a model-free worker.
# A stale pane carrier must be replaced when tracing is on and unset when off.
assert_relaunch_worker_trace() {  # <case-dir> <expected-carrier>
  local dir=$1 expected=$2 out rc launch
  mkdir -p "$dir/trace-probe-bin" "$dir/user-home" "$dir/trace-probe-config"
  cat > "$dir/trace-probe-bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${TRACEPARENT-unset}" > "$FM_TRACE_PROBE"
SH
  chmod +x "$dir/trace-probe-bin/claude"
  [ -s "$dir/fake/launch" ] || fail "relaunch did not stage a replacement command"
  launch=$(cat "$dir/fake/launch")
  # Enabled carriers arrive through the ordinary pre-launch pane channel.
  [ ! -f "$dir/fake/trace-env" ] || launch="$(cat "$dir/fake/trace-env"); $launch"
  out=$(fm_eval_launch "$launch" "$dir/wt" "$dir/trace-probe-bin" \
    -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
    -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR="$dir/trace-probe-config" \
    FM_TRACE_PROBE="$dir/trace-probe" \
    TRACEPARENT=00-cccccccccccccccccccccccccccccccc-dddddddddddddddd-01); rc=$?
  expect_code 0 "$rc" "staged relaunch should reach the fake worker"$'\n'"$out"
  [ -f "$dir/trace-probe" ] || fail "staged relaunch did not execute the fake worker"
  [ "$(cat "$dir/trace-probe")" = "$expected" ] \
    || fail "replacement worker trace carrier did not match '$expected'"
}

meta_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.meta" | tail -1 | cut -d= -f2-
}

journal_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.control-relaunch" | tail -1 | cut -d= -f2-
}

make_git_failure_stub() {  # <case-dir>
  cat > "$1/fakebin/git" <<'SH'
#!/usr/bin/env bash
case "${FM_FAKE_GIT_FAILURE:-}:$*" in
  head:*' rev-parse --verify HEAD'|head:*' symbolic-ref -q HEAD') exit 128 ;;
  status:*' status --porcelain') exit 128 ;;
esac
exec "$FM_REAL_GIT" "$@"
SH
  chmod +x "$1/fakebin/git"
}

make_mv_failure_stub() {  # <case-dir>
  cat > "$1/fakebin/mv" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_COMPLETE_JOURNAL_MV_FAIL:-}" ]; then
  for path in "$@"; do
    if [ -f "$path" ] && grep -Fqx 'phase=complete' "$path"; then
      exit 1
    fi
  done
fi
if [ -n "${FM_FAKE_META_PUBLISH_MV_FAIL:-}" ]; then
  for path in "$@"; do
    [ "$path" != "$FM_FAKE_META_PUBLISH_MV_FAIL" ] || exit 1
  done
fi
source_path=
target_path=
for path in "$@"; do
  source_path=$target_path
  target_path=$path
done
if [ -n "${FM_FAKE_META_WRITER_TARGET:-}" ] \
   && [ "$target_path" = "$FM_FAKE_META_WRITER_TARGET" ] \
   && grep -q '^x_request=' "$source_path" 2>/dev/null; then
  : > "$FM_FAKE_META_WRITER_READY"
  while [ ! -e "$FM_FAKE_META_WRITER_RELEASE" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do /bin/sleep 0.01; done
fi
exec "$FM_REAL_MV" "$@"
SH
  chmod +x "$1/fakebin/mv"
}

make_spawn_return_barrier_stub() {
  local dir=$1 real_bash
  real_bash=$(command -v bash)
  cat > "$dir/fakebin/bash" <<SH
#!/bin/bash
if [ "\${1:-}" != "$SPAWN" ]; then
  exec "$real_bash" "\$@"
fi
"$real_bash" "\$@"
rc=\$?
printf '%s\n' "\$rc" > "\$FM_FAKE_SPAWN_RETURN_READY"
deadline=\$((SECONDS + \${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}))
while [ ! -e "\$FM_FAKE_SPAWN_RETURN_RELEASE" ]; do
  if [ "\$SECONDS" -ge "\$deadline" ]; then
    : > "\$FM_FAKE_SPAWN_RETURN_READY.expired"
    exit 124
  fi
  /bin/sleep 0.05
done
exit "\$rc"
SH
  chmod +x "$dir/fakebin/bash"
}

wait_fixture_process() {
  local pid=$1 deadline=$((SECONDS + FM_TEST_STUB_MAX_BLOCK_SECONDS))
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      kill -KILL "$pid" 2>/dev/null || true
      return 124
    fi
    /bin/sleep 0.05
  done
  wait "$pid"
}

make_rm_failure_stub() {  # <case-dir>
  cat > "$1/fakebin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ -n "${FM_FAKE_RM_FAIL_PATH:-}" ] && [ "$arg" = "$FM_FAKE_RM_FAIL_PATH" ]; then
    exit 1
  fi
done
exec "$FM_REAL_RM" "$@"
SH
  chmod +x "$1/fakebin/rm"
}

# Give a case home a real backlog carrying <id>, so the relaunch path's paired
# backlog transition (bin/fm-backlog-transition-lib.sh) is live rather than
# skipped for want of a backlog file.
seed_backlog() {  # <case-dir> <id> <queued|in_flight>
  local dir=$1 id=$2 want=$3 file="$1/home/data/backlog.md"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$file"
  tasks-axi add "$id" "relaunch fixture task" --kind ship --file "$file" >/dev/null
  [ "$want" != in_flight ] || tasks-axi start "$id" --file "$file" >/dev/null
}

backlog_state() {  # <case-dir> <id>
  tasks-axi show "$2" --file "$1/home/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

# Shadow tasks-axi so every `start` fails and every other verb is real. A
# relaunch that re-reads the row before acting never calls it; one that assumes
# it must re-run the transition trips over it.
break_tasks_axi_start() {  # <case-dir>
  local dir=$1 real
  real=$(command -v tasks-axi)
  cat > "$dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = start ]; then
  echo 'error: "start refused"' >&2
  exit 1
fi
exec "$real" "\$@"
SH
  chmod +x "$dir/fakebin/tasks-axi"
}

make_continuation_owner_fixture() {
  local dir=$1
  printf '%s\n' "$$" > "$dir/home/state/.lock"
  printf '%s\n' "$$" > "$dir/fake/primary-pid"
  mv "$dir/fakebin/ps" "$dir/fakebin/ps-runtime"
  cat > "$dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
primary=$(cat "$FM_FAKE_DIR/primary-pid")
foreign=$(cat "$FM_FAKE_DIR/foreign-pid" 2>/dev/null || true)
case "$*" in
  "-o comm= -p $primary"|"-o args= -p $primary")
    printf 'omp\n'; exit 0 ;;
  "-o comm= -p $foreign"|"-o args= -p $foreign")
    [ -z "$foreign" ] || { printf 'omp\n'; exit 0; } ;;
esac
exec "${0%/*}/ps-runtime" "$@"
SH
  chmod +x "$dir/fakebin/ps"
  mv "$dir/fakebin/tmux" "$dir/fakebin/tmux-runtime"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_DIR/endpoint-calls"
exec "${0%/*}/tmux-runtime" "$@"
SH
  chmod +x "$dir/fakebin/tmux"
}

seed_continuation_case() {
  local dir=$1 id=$2
  add_ship_task "$dir" "$id"
  seed_backlog "$dir" "$id" in_flight
  printf 'working: reconcile unread instructions only\n' > "$dir/home/state/$id.status"
  mkdir -p "$dir/home/state/$id.inbox/handled" "$dir/wt/.claude"
  printf 'Unread instruction remains unread.\n' > "$dir/home/state/$id.inbox/005.msg"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/home/state/$id.check.sh"
  chmod 0700 "$dir/home/state/$id.check.sh"
  FM_HOME="$dir/home" "$ROOT/bin/fm-check-register.sh" "$id" >/dev/null \
    || fail "could not register the preserved continuation check"
  printf '{"fixture":"preserved worker wiring"}\n' > "$dir/wt/.claude/settings.local.json"
  printf 'uncommitted task work\n' > "$dir/wt/retained.txt"
  "$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" "$id" >/dev/null
  make_continuation_owner_fixture "$dir"
  {
    printf '%s\n' 'recovery=reconcile-only' 'spawn_gen=preserved-incarnation'
    printf '%s\n' 'pr=https://example.invalid/pull/continuation' 'x_request=preserved-request'
    printf '%s\n' 'custom_record=spaces and = signs stay unchanged'
    printf '%s' 'continuation_required=preserve-this-custom-field'
  } >> "$dir/home/state/$id.meta"
}

run_continuation_control() {
  local dir=$1
  shift
  (
    unset FM_TASK_ID FM_SUPERVISION_ACTOR PI_CODING_AGENT CLAUDE_PID CLAUDE_CODE_SESSION_ID
    [ -z "${FM_FAKE_TASK_ID:-}" ] || export FM_TASK_ID="$FM_FAKE_TASK_ID"
    [ -z "${FM_FAKE_ACTOR:-}" ] || export FM_SUPERVISION_ACTOR="$FM_FAKE_ACTOR"
    run_control "$dir" "$@"
  )
}

snapshot_continuation_case() {
  local dir=$1
  cp -R "$dir/home/state" "$dir/state-before"
  cp -R "$dir/home/data" "$dir/data-before"
  cp -R "$dir/fake" "$dir/fake-before"
  cp -R "$dir/wt" "$dir/work-before"
  git -C "$dir/wt" rev-parse HEAD > "$dir/head-before"
  git -C "$dir/wt" symbolic-ref HEAD > "$dir/branch-before"
}

assert_continuation_snapshot() {
  local dir=$1 id=$2 clearance=${3:-0}
  if [ "$clearance" = 1 ]; then
    perl -ne 'print unless $_ eq "recovery=reconcile-only\n" || $_ eq "recovery=reconcile-only"' \
      "$dir/state-before/$id.meta" > "$dir/expected.meta"
    mv "$dir/expected.meta" "$dir/state-before/$id.meta"
  fi
  diff -r "$dir/state-before" "$dir/home/state" >/dev/null \
    || fail "continuation authorization changed state beyond its allowed recovery row"
  diff -r "$dir/data-before" "$dir/home/data" >/dev/null \
    || fail "continuation authorization changed backlog or instructions"
  diff -r "$dir/fake-before" "$dir/fake" >/dev/null \
    || fail "continuation authorization inspected or changed the runtime endpoint"
  diff -r "$dir/work-before" "$dir/wt" >/dev/null \
    || fail "continuation authorization changed task files or worker wiring"
  [ "$(cat "$dir/head-before")" = "$(git -C "$dir/wt" rev-parse HEAD)" ] \
    || fail "continuation authorization changed committed task work"
  [ "$(cat "$dir/branch-before")" = "$(git -C "$dir/wt" symbolic-ref HEAD)" ] \
    || fail "continuation authorization changed the task branch"
}

await_fixture_ready() {
  local ready=$1 pid=$2 label=$3 i=0
  while [ ! -e "$ready" ] && [ "$i" -lt 500 ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$ready" ] || { printf '%s\n' "$label did not reach its readiness barrier" >&2; return 1; }
}

pause_continuation_admission() {
  local dir=$1 real
  real=$(command -v tasks-axi)
  cat > "$dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = show ] && [ -n "\${FM_FAKE_ADMISSION_READY:-}" ]; then
  : > "\$FM_FAKE_ADMISSION_READY"
  while [ ! -e "\$FM_FAKE_ADMISSION_RELEASE" ] && [ "\$SECONDS" -lt "\${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do /bin/sleep 0.01; done
fi
exec "$real" "\$@"
SH
  chmod +x "$dir/fakebin/tasks-axi"
}

# A fake claude that answers `claude auth status` the way the real runner
# does: signed in only when the selected config root holds a stored login.
make_claude_auth_stub() {  # <case-dir>
  cat > "$1/fakebin/claude" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = status ] || exit 0
[ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" ]
SH
  chmod +x "$1/fakebin/claude"
}

# stage_gone <case-dir> <id> <shape>: make the recorded tmux endpoint read
# `missing` in one of the three ways real tmux reports a destroyed endpoint.
stage_gone() {
  local dir=$1 id=$2 shape=$3
  case "$shape" in
    window-absent) printf 'scratch\nfm-someone-else\n' > "$dir/fake/windows" ;;
    session-missing) : > "$dir/fake/session-missing" ;;
    server-dead) : > "$dir/fake/server-dead" ;;
    *) fail "unknown gone shape $shape for $id" ;;
  esac
}

# stage_holder <case-dir> <comm> <args> <cwd>: a live process whose working
# directory is <cwd>, as the machine's working-directory table reports it.
stage_holder() {
  printf holder > "$1/fake/lsof-mode"
  printf 4343 > "$1/fake/holder-pid"
  printf '%s' "$2" > "$1/fake/holder-comm"
  printf '%s' "$3" > "$1/fake/holder-args"
  printf '%s' "$4" > "$1/fake/holder-cwd"
}

# A missing endpoint whose absence cannot be shown for THIS task still
# refuses, and the refusal comes from the shared absence proof (its message
# names the reading) rather than from any later backend policy.
assert_tmux_missing_refuses() {  # <case-dir> <id> <what-was-staged>
  local dir=$1 id=$2 what=$3 out rc brief_before

  rm -f "$dir/fake/list-count"
  out=$(run_spawn "$dir" "$id" --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "relaunch must refuse a tmux endpoint whose absence cannot be proven ($what)"$'\n'"$out"
  assert_contains "$out" "may still hold a live agent" "the refusal must come from the absence proof ($what)"
  assert_absent "$dir/fake/created-windows" "a refused relaunch must not create a window ($what)"
  assert_absent "$dir/fake/created-sessions" "a refused relaunch must not create a session ($what)"
  [ ! -s "$dir/fake/literal" ] || fail "a refused relaunch must send nothing into any pane ($what)"

  brief_before=$(cat "$dir/home/data/$id/brief.md")
  rm -f "$dir/fake/list-count"
  out=$(run_control "$dir" "$id" exit); rc=$?
  expect_code 1 "$rc" "exit must refuse a tmux endpoint whose absence cannot be proven ($what)"$'\n'"$out"
  assert_not_contains "$out" "endpoint-gone" \
    "exit must not report a stop it cannot see ($what)"
  [ ! -s "$dir/fake/literal" ] || fail "a refused exit must send nothing into any pane ($what)"

  rm -f "$dir/fake/list-count"
  out=$(run_control "$dir" "$id" relaunch --note "this note must never reach a live agent"); rc=$?
  expect_code 1 "$rc" "the relaunch transaction must fail closed ($what)"$'\n'"$out"
  assert_contains "$out" "will not claim an agent stopped" "the transaction must stop at the absence proof ($what)"
  [ "$(cat "$dir/home/data/$id/brief.md")" = "$brief_before" ] \
    || fail "a refused relaunch edited instructions an agent that may still be running is reading ($what)"
  assert_absent "$dir/fake/created-windows" "a refused transaction must not create a window ($what)"
  assert_absent "$dir/fake/created-sessions" "a refused transaction must not create a session ($what)"
  [ ! -s "$dir/fake/literal" ] || fail "a refused transaction must launch nothing ($what)"

  fm_tasks_axi_compatible || { echo 'skip - reconciliation-only holder proof needs compatible tasks-axi'; return; }
  seed_backlog "$dir" "$id" in_flight

  rm -f "$dir/fake/list-count"
  out=$(run_control "$dir" "$id" relaunch --reconcile-only --note "this note must never reach a live agent"); rc=$?
  expect_code 1 "$rc" "reconciliation-only recovery must fail closed ($what)"$'\n'"$out"
  assert_contains "$out" "requires a proven exited owner" "reconciliation-only admission must reject inconclusive ownership ($what)"
  [ "$(cat "$dir/home/data/$id/brief.md")" = "$brief_before" ] \
    || fail "a refused reconciliation edited the live owner's instructions ($what)"
  assert_absent "$dir/fake/created-windows" "a refused reconciliation must not create a window ($what)"
  assert_absent "$dir/fake/created-sessions" "a refused reconciliation must not create a session ($what)"
  [ ! -s "$dir/fake/literal" ] || fail "a refused reconciliation must launch nothing ($what)"
}

# prepare_herdr_reclaim <case-dir>: configure the home to replace a proven-gone
# tmux endpoint on Herdr. Returns 1 when the Herdr adapter's jq is missing.
prepare_herdr_reclaim() {
  command -v jq >/dev/null 2>&1 || return 1
  make_herdr_stub "$1"
  mkdir -p "$1/home/config"
  printf herdr > "$1/home/config/backend"
  printf '%%none' > "$1/fake/herdr-pane"
  : > "$1/fake/herdr-log"
  : > "$1/fake/herdr-stopped"
}

git_commit_file() {  # <worktree> <file> <message>
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" -c user.name=t -c user.email=t@example.com commit -qm "$3"
}

set_case_meta_field() {  # <case-dir> <id> <key> <value>
  local meta="$1/home/state/$2.meta"
  awk -F= -v key="$3" -v value="$4" '
    $1 != key { print }
    END { printf "%s=%s\n", key, value }
  ' "$meta" > "$meta.tmp" && mv "$meta.tmp" "$meta"
}

# make_relocation_case <case-dir> <id> [keep-registration]: a ship task with one
# commit made in its copy, then the copy vanishes.
# <case-dir>/first-head and committed-head hold the branch's two commits.
make_relocation_case() {
  local dir=$1 id=$2 keep=${3:-}
  add_ship_task "$dir" "$id" claude
  printf 'branch=task-%s\n' "$id" >> "$dir/home/state/$id.meta"
  git -C "$dir/wt" rev-parse HEAD > "$dir/first-head"
  git_commit_file "$dir/wt" committed.txt "committed before the copy vanished"
  git -C "$dir/wt" rev-parse HEAD > "$dir/committed-head"
  printf 'pr_head=%s\n' "$(cat "$dir/committed-head")" >> "$dir/home/state/$id.meta"
  rm -rf "$dir/wt"
  # G-20: a relocation destination must be a Treehouse pool slot, so the fresh
  # copy gets the managed pool's <pool>/<slot>/<repo> layout with its pool state
  # beside it. A plain linked worktree is no longer a destination the launcher
  # accepts, and test_relocation_refuses_a_non_lease_copy proves that.
  mkdir -p "$dir/th/1"
  printf '{}\n' > "$dir/th/treehouse-state.json"
  if [ "$keep" = keep-registration ]; then
    git -C "$dir/proj" worktree add -q -f "$dir/th/1/dest" "task-$id"
  else
    git -C "$dir/proj" worktree prune
    git -C "$dir/proj" worktree add -q "$dir/th/1/dest" "task-$id"
  fi
  printf zsh > "$dir/fake/command"
  printf '%s' "$dir/wt" > "$dir/fake/cwd"
  printf 'working: preserved history\n' > "$dir/home/state/$id.status"
}

# run_relocation_refusal <case-dir> <id> <fragment> <what> [destination]: the
# relocation must refuse before anything is stopped, journaled or edited.
run_relocation_refusal() {
  local dir=$1 id=$2 fragment=$3 what=$4 dest=${5:-$1/th/1/dest} out rc meta_before brief_before journal_before=
  meta_before=$(cat "$dir/home/state/$id.meta")
  brief_before=$(cat "$dir/home/data/$id/brief.md")
  if [ -f "$dir/home/state/$id.control-relaunch" ]; then
    journal_before=$(cat "$dir/home/state/$id.control-relaunch")
  fi
  out=$(run_control "$dir" "$id" relaunch --worktree "$dest" --note "resume"); rc=$?
  expect_code 1 "$rc" "relocation must refuse ($what)"$'\n'"$out"
  assert_contains "$out" "$fragment" "relocation refused for the wrong reason ($what)"
  [ "$(cat "$dir/home/state/$id.meta")" = "$meta_before" ] \
    || fail "a refused relocation changed the durable record ($what)"
  [ "$(cat "$dir/home/data/$id/brief.md")" = "$brief_before" ] \
    || fail "a refused relocation edited the instructions ($what)"
  if [ -n "$journal_before" ]; then
    [ "$(cat "$dir/home/state/$id.control-relaunch")" = "$journal_before" ] \
      || fail "a refused relocation changed its existing journal ($what)"
  else
    assert_absent "$dir/home/state/$id.control-relaunch" "a refused relocation wrote a journal ($what)"
  fi
  assert_absent "$dir/fake/created-windows" "a refused relocation created an endpoint ($what)"
  [ ! -s "$dir/fake/literal" ] || fail "a refused relocation sent input to the endpoint ($what)"
}

# --- herdr: a stopped server is not a destroyed endpoint --------------------
#
# Stopping and restarting a named Herdr server preserves workspace, tab, pane
# and label ids; only the harness processes and their registrations die
# (docs/herdr-backend.md "Restart and liveness behavior"). A stopped session
# with proven process and socket absence reads missing; recovery then restores
# the server and must adopt the preserved pane rather than open a second tab.
#
# Canned/stateful fake only - never a real herdr session.
make_herdr_stub() {  # <case-dir>
  local fb="$1/fakebin" socket_dir
  mkdir -p "$fb"
  socket_dir=$(TMPDIR=/tmp fm_test_tmproot fm-lab-recovery) || return 1
  printf '%s/herdr.sock\n' "$socket_dir" > "$1/fake/herdr-socket-path"
  # The herdr server-ensure poll must actually wait between reads, so this case
  # keeps the real sleep rather than the tmux cases' instant stub.
  rm -f "$fb/sleep"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
if [ -f "$D/herdr-sessions/${HERDR_SESSION:-}" ]; then
  D=$(cat "$D/herdr-sessions/$HERDR_SESSION")
fi
printf '%s\n' "$*" >> "$D/herdr-log"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  [ ! -f "$D/herdr-status-fails" ] || exit 1
  if [ -f "$D/herdr-stopped" ]; then
    running=false
  else
    running=true
  fi
  printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":%s,"socket":"%s","session":"%s"}}\n' \
    "$running" "$(cat "$D/herdr-socket-path")" "${HERDR_SESSION:-}"
  exit 0
fi
if [ "${1:-}" = server ]; then
  rm -f "$D/herdr-stopped"
  exit 0
fi
if [ -f "$D/herdr-stopped" ]; then
  # Every operational call against a stopped server fails at the transport,
  # with no JSON body to classify.
  echo 'error: could not connect to the herdr server' >&2
  exit 1
fi
case "${1:-} ${2:-}" in
  'pane get')
    if [ -f "$D/herdr-cwd-${3:-}" ]; then
      cwd=$(cat "$D/herdr-cwd-${3:-}")
    elif [ "${3:-}" = "$(cat "$D/herdr-pane")" ]; then
      cwd=$(cat "$D/cwd")
    else
      # Only the pane this case says survived can be read back. Any other pane
      # id is structurally gone, which is herdr's `pane_not_found`.
      printf '{"error":{"code":"pane_not_found"}}\n'
      exit 0
    fi
    jq -cn --arg pane "${3:-}" --arg cwd "$cwd" \
      '{result:{pane:{pane_id:$pane,foreground_cwd:$cwd}}}'
    exit 0 ;;
  'agent get')
    if [ -f "$D/recovery-inspection-interrupt" ]; then
      : > "$D/recovery-inspection-entered"
      kill -TERM "$(cat "$D/recovery-inspection-interrupt")"
      exit 1
    fi
    if [ -f "$D/recovery-registration-missing" ]; then
      printf '{"error":{"code":"agent_not_found"}}\n'
    elif [ -f "$D/recovery-case-id" ] && [ -f "$D/herdr-agent-live" ]; then
      ref=$(cat "$D/recovery-session-ref")
      agent=omp
      [ ! -f "$D/recovery-registration-ref" ] || ref=$(cat "$D/recovery-registration-ref")
      [ ! -f "$D/recovery-registration-agent" ] || agent=$(cat "$D/recovery-registration-agent")
      jq -nc --arg agent "$agent" --arg ref "$ref" \
        '{result:{agent:{agent:$agent,agent_status:"idle",agent_session:{kind:"path",value:$ref}}}}'
    elif [ -f "$D/herdr-agent-registration" ]; then
      cat "$D/herdr-agent-registration"
    elif [ -f "$D/herdr-live-${3:-}" ] || { [ ! -f "$D/herdr-cwd-${3:-}" ] && [ -f "$D/herdr-agent-live" ]; }; then
      # The agent came back with its server. Nothing here is reclaimable.
      printf '{"result":{"agent":{"agent_status":"idle"}}}\n'
    else
      # A pane that comes back holding no agent is the adoptable state.
      printf '{"error":{"code":"agent_not_found"}}\n'
    fi
    exit 0 ;;
  'pane process-info')
    if [ -f "$D/recovery-case-id" ]; then
      if [ -f "$D/herdr-agent-live" ]; then
        pid=2000000000
        [ ! -f "$D/recovery-pid" ] || pid=$(cat "$D/recovery-pid")
        if [ -f "$D/recovery-foreign-foreground" ]; then
          printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_processes":[{"pid":%s,"name":"python3","argv":["python3","-c","input()"],"cmdline":"python3 -c input()"}]}}}\n' \
            "$(cat "$D/herdr-pane")" "$pid"
          exit 0
        fi
        harness=omp
        [ ! -f "$D/recovery-harness" ] || harness=$(cat "$D/recovery-harness")
        cwd=$(cat "$D/cwd")
        ref=$(cat "$D/recovery-session-ref")
        [ ! -f "$D/recovery-process-cwd" ] || cwd=$(cat "$D/recovery-process-cwd")
        [ ! -f "$D/recovery-process-ref" ] || ref=$(cat "$D/recovery-process-ref")
        argv=$(jq -nc --arg harness "$harness" --arg ref "$ref" '[$harness,"--resume=" + $ref]')
        [ ! -f "$D/recovery-process-argv" ] || argv=$(cat "$D/recovery-process-argv")
        jq -nc --arg pane "$(cat "$D/herdr-pane")" --argjson pid "$pid" \
          --arg harness "$harness" --arg cwd "$cwd" --argjson argv "$argv" \
          '{result:{type:"pane_process_info",process_info:{pane_id:$pane,shell_pid:4242,
            foreground_processes:[{pid:$pid,name:$harness,argv0:$harness,argv:$argv,cwd:$cwd}]}}}'
      else
        printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%%7","shell_pid":4242,"foreground_processes":[]}}}\n'
      fi
      exit 0
    fi
    # A retained registration with a shell-only pane models an exited agent
    # whose Herdr status authority still belongs to its previous session.
    if [ -f "$D/herdr-agent-registration" ] \
      || { [ ! -f "$D/herdr-live-${4:-}" ] && { [ -f "$D/herdr-cwd-${4:-}" ] || [ ! -f "$D/herdr-agent-live" ]; }; }; then
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_processes":[]}}}\n' \
        "${4:-}"
    else
      pane=${4:-}
      case "${pane#%}" in ''|*[!0-9]*) exit 1 ;; esac
      pid=$((2100000000 + ${pane#%}))
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_processes":[{"pid":%s,"name":"claude","argv":["claude"],"cmdline":"claude"}]}}}\n' \
        "$pane" "$pid"
    fi
    exit 0 ;;
  'pane run')
    if [ "${4:-}" = 'treehouse get' ] && [ -f "$D/herdr-treehouse-worktree" ]; then
      cp "$D/herdr-treehouse-worktree" "$D/herdr-cwd-${3:-}"
    fi
    exit 0 ;;
  'pane send-text')
    # Mirrors the tmux fake's `becomes`: delivering the launch brief is what
    # makes an agent exist on this pane, so the control plane's alive-wait can
    # observe the replacement come up. A launch arrives as a short line sourcing
    # the staged launch file rather than the literal command, so read that file
    # back before deciding what was delivered - exactly as the tmux fake above
    # and tests/fixtures.sh do.
    payload=${4:-}
    case "$payload" in
      ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
    esac
    if [ -f "$D/recovery-case-id" ] && [ "$payload" = /quit ]; then
      : > "$D/exit-pending"
    fi
    case "$payload" in
      *'encode launch-brief'* | *'Firstmate operational input waiting: read'*)
        if [ ! -f "$D/recovery-case-id" ]; then
          pane=${3:-}
          case "${pane#%}" in ''|*[!0-9]*) exit 1 ;; esac
          pid=$((2100000000 + ${pane#%}))
          pin_pattern='export FM_SPAWN_GEN=[^[:alnum:]]*([[:alnum:].]+)'
          [[ "$payload" =~ $pin_pattern ]] || exit 1
          printf 'PATH=/test\nFM_SPAWN_GEN=%s\n' "${BASH_REMATCH[1]}" > "$D/herdr-managed-env-$pid"
        fi
        if [ -f "$D/recovery-case-id" ]; then
          id=$(cat "$D/recovery-case-id")
          pid=$(cat "$D/recovery-pid")
          pin_pattern='export FM_SPAWN_GEN=[^[:alnum:]]*([[:alnum:].]+)'
          [[ "$payload" =~ $pin_pattern ]] || exit 1
          task=$(cat "$D/recovery-session-ref")
          jq -nc --arg gen "${BASH_REMATCH[1]}" --argjson pid "$pid" --arg task "$task" \
            '{version:1,spawn_gen:$gen,pid:$pid,task_session_file:$task,current_session_file:$task}' \
            > "$FM_HOME/state/$id.omp-session.json"
        fi
        printf '%s\n' "$payload" > "$D/launched-command"
        : > "$D/herdr-live-${3:-}"
        : > "$D/herdr-agent-live" ;;
    esac
    exit 0 ;;
  'pane read')
    if [ -f "$D/recovery-case-id" ]; then
      if [ -f "$D/exit-pending" ]; then
        printf '╭── π > recovery╮\n╰─ /quit ─╯\n'
      elif [ -f "$D/recovery-pending" ]; then
        printf '╭── π > recovery╮\n╰─ %s ─╯\n' "$(cat "$D/recovery-pending")"
      else
        printf '╭── π > recovery╮\n╰─  ─╯\n'
      fi
    fi
    exit 0 ;;
  'pane send-keys')
    if [ -f "$D/recovery-case-id" ]; then
      if [ "${4:-}" = escape ] && [ -f "$D/recovery-pending" ]; then
        case "$(cat "$D/recovery-pending")" in
          '!'*|'$'*) : > "$D/recovery-pending" ;;
        esac
      fi
      if [ "${4:-}" = ctrl+d ] \
        || { [ "${4:-}" = enter ] && [ -f "$D/exit-pending" ]; }; then
        rm -f "$D/herdr-agent-live" "$D/exit-pending"
      fi
    fi
    exit 0 ;;
  'workspace list')
    printf '{"result":{"workspaces":[]}}\n'
    exit 0 ;;
  'workspace create')
    if [ -f "$D/herdr-workspace-create-fails" ]; then
      echo 'error: workspace create failed' >&2
      exit 1
    fi
    printf '{"result":{"workspace":{"workspace_id":"wsnew"},"tab":{"tab_id":"seedtab"}}}\n'
    exit 0 ;;
  'tab list')
    printf '{"result":{"tabs":[]}}\n'
    exit 0 ;;
  'tab create')
    # The re-created endpoint. Recording it lets a case prove the pane the
    # record ends up naming is the one this call minted.
    printf '%s\n' "$*" >> "$D/herdr-created-tabs"
    pane="%$((8 + $(wc -l < "$D/herdr-created-tabs")))"
    cwd=
    for ((i=3; i <= $#; i++)); do
      if [ "${!i}" = --cwd ]; then
        i=$((i + 1))
        cwd=${!i}
        break
      fi
    done
    printf '%s' "$cwd" > "$D/herdr-cwd-$pane"
    printf '{"result":{"tab":{"tab_id":"tab%s"},"root_pane":{"pane_id":"%s"}}}\n' "${pane#%}" "$pane"
    printf '%s' "$pane" > "$D/herdr-pane"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  make_process_table_stub "$1"
}

claim_herdr_task_tmps() {  # <home> <id>
  local home=$1 id=$2 homehash path
  homehash=$(cd "$home" && pwd -P) || return 1
  homehash=$(printf '%s' "$homehash" | shasum -a 256 | cut -d' ' -f1) || return 1
  for path in "/tmp/fm-$id" "/tmp/fm-$id+$homehash"; do
    (umask 077 && mkdir "$path") 2>/dev/null || return 1
    TASK_TMPS+=("$path")
  done
}

# add_herdr_ship_task <case-dir> <id> [session] [surviving-pane]: a ship task
# recorded on the herdr backend, with its server stopped so its endpoint
# classifies `missing`. <surviving-pane> is the pane id the fake will answer for
# once that server is back; default is the recorded one (it survived the
# restart). Pass a different id to model a pane that genuinely did not.
add_herdr_ship_task() {  # <case-dir> <id> [session] [surviving-pane]
  local dir=$1 id=$2 ses=${3:-fmlab} survivor=${4:-'%7'}
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  claim_herdr_task_tmps "$home" "$id" \
    || fail "fixture task or launch temp directory already exists or cannot be claimed for $id"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise a herdr reclaim safely.

## Firstmate spec
Keep the recorded endpoint when it outlives its server.
EOF
  {
    echo "window=$ses:%7"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
    echo "backend=herdr"
    echo "herdr_session=$ses"
    echo "herdr_workspace_id=ws1"
    echo "herdr_tab_id=tab1"
    echo "herdr_pane_id=%7"
  } > "$home/state/$id.meta"
  printf '%s' "$wt" > "$dir/fake/cwd"
  printf '%s' "$survivor" > "$dir/fake/herdr-pane"
  : > "$dir/fake/herdr-log"
  : > "$dir/fake/herdr-stopped"
}

herdr_case_or_skip() {  # <name> <id> [session] [surviving-pane]
  HERDR_CASE_DIR=
  command -v jq >/dev/null 2>&1 || return 1
  HERDR_CASE_DIR=$(new_case "$1" "$2")
  add_herdr_ship_task "$HERDR_CASE_DIR" "$2" "${3:-fmlab}" "${4:-%7}"
  make_herdr_stub "$HERDR_CASE_DIR"
  return 0
}

recovery_case_or_skip() {  # <name> <id-suffix> [session] [surviving-pane]
  HERDR_CASE_ID="rcv-$$-${TMP_ROOT##*.}-$2"
  herdr_case_or_skip "$1" "$HERDR_CASE_ID" "${3:-fmlab}" "${4:-%7}"
}

enable_teamclaude() {  # <case-dir>
  mkdir -p "$1/home/config"
  printf 'teamclaude\n' > "$1/home/config/claude-launcher"
  fm_test_fake_teamclaude "$1/fakebin"
}

# teamclaude_launch_line <log>: the newest launch the pane received.
teamclaude_launch_line() {
  grep -F 'Firstmate operational input waiting: read' "$1" | tail -1
}

# arm_session_end <case-dir> <id>: record that the task's Claude session ended.
arm_session_end() {
  local state="$1/home/state" gen
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$2" --state idle --source claude-hook --event launch-brief >/dev/null
  gen=$(cat "$state/$2.busy-gen")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$2" idle --gen "$gen" --source claude-hook --event session-end >/dev/null
}

# run_session_end_scan <case-dir>: the watcher's real session-end auto-relaunch,
# which runs the real fm-control relaunch. Prints the wake it raised.
run_session_end_scan() {
  local dir=$1
  mkdir -p "$dir/user-home"
  (
    unset HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID
    # shellcheck disable=SC2030,SC2031 # This subshell's own environment is the point.
    export PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
      HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
      FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-session-end-relaunch-lib.sh"
    fm_session_end_relaunch_scan "$dir/home/state" 300 || exit 1
    printf '%s\n' "$FM_SESSION_END_WAKE"
  )
}

# add_teamclaude_secondmate <case-dir> <id>: a live Claude second mate record in
# a marked home, on the backend the case's session-provider stub models.
add_teamclaude_secondmate() {
  local dir=$1 id=$2 home="$1/home" smhome="$1/$2-home"
  fm_git_worktree "$dir/$id-repo" "$smhome" "sm-$id"
  mkdir -p "$smhome/state" "$smhome/data" "$smhome/bin" "$home/config"
  printf '%s\n' "$id" > "$smhome/.fm-secondmate-home"
  printf '# charter\n' > "$smhome/data/charter.md"
  printf '# agents\n' > "$smhome/AGENTS.md"
  printf 'claude\n' > "$home/config/secondmate-harness"
  {
    echo "endpoint_task_id=$id"
    echo "worktree=$smhome"
    echo "project=$smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$smhome"
    echo "projects="
  } >> "$home/state/$id.meta"
  printf '%s' "$smhome" > "$dir/fake/cwd"
}

write_recovery_native_session() { # <path> <cwd> <initial-user-message>
  jq -nc '{type:"title",v:1,title:"",updatedAt:"2026-10-06T00:00:00Z",pad:""}
    | .pad = (" " * (255 - (tojson | length)))' > "$1"
  jq -nc --arg cwd "$2" --arg id "${1##*/}" '{type:"session",version:3,id:$id,cwd:$cwd}' >> "$1"
  jq -nc --arg text "$3" \
    '{type:"message",message:{role:"user",content:[{type:"text",text:$text}]}}' >> "$1"
}

write_recovery_native_launch() { # <case-dir> <owning-home> <id> <kind>
  local dir=$1 home=$2 id=$3 kind=$4 body message
  if [ "$kind" = secondmate ]; then
    body=$(cat "$dir/wt/data/charter.md")
  else
    body="$(fm_brief_worker_role "$home/state" "$id" "$ROOT")"$'\n\n'"$(cat "$home/data/$id/brief.md")"
  fi
  fm_operational_input_encode launch-brief "$body" message || fail "could not generate native launch envelope"
  write_recovery_native_session "$dir/wt/recorded-session.jsonl" "$dir/wt" "$message"
}

write_recovery_session_proof() { # <case-dir> <id> [current-session-file]
  local dir=$1 id=$2
  jq -nc --arg gen old --argjson pid "$(cat "$dir/fake/recovery-pid")" \
    --arg task "$dir/wt/recorded-session.jsonl" --arg current "${3:-$dir/wt/recorded-session.jsonl}" \
    '{version:1,spawn_gen:$gen,pid:$pid,task_session_file:$task,current_session_file:$current}' \
    > "$dir/home/state/$id.omp-session.json"
}

prepare_herdr_recovery() {  # <case-dir> <id> <kind>
  local dir=$1 id=$2 kind=$3
  rm -f "$dir/fake/herdr-stopped"
  printf '%s' "$id" > "$dir/fake/recovery-case-id"
  : > "$dir/fake/herdr-agent-live"
  printf '%s' "$dir/wt/recorded-session.jsonl" > "$dir/fake/recovery-session-ref"
  printf 2000000000 > "$dir/fake/recovery-pid"
  : > "$dir/fake/recovery-spawn-gen"
  printf 'harness=omp\nkind=%s\nlaunch_proof=env-v1\nspawn_gen=old\nmodel=openai-codex/gpt-6-astra\neffort=high\n' "$kind" \
    >> "$dir/home/state/$id.meta"
  cat > "$dir/fakebin/omp" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf 'omp/18.1.20\n' ;;
  models)
    printf '%s\n' '{"models":[{"provider":"openai-codex","id":"gpt-6-astra","selector":"openai-codex/gpt-6-astra"}]}'
    ;;
esac
SH
  chmod +x "$dir/fakebin/omp"
  printf 'preserve interrupted work\n' > "$dir/wt/unlanded.txt"
  if [ "$kind" = secondmate ]; then
    mkdir -p "$dir/wt/state" "$dir/wt/data" "$dir/wt/bin" "$dir/home/config"
    printf 'omp\n' > "$dir/home/config/secondmate-harness"
    printf '%s\n' "$id" > "$dir/wt/.fm-secondmate-home"
    printf '# test home\n' > "$dir/wt/AGENTS.md"
    printf '# test charter\n' > "$dir/wt/data/charter.md"
    printf 'mode=secondmate\nhome=%s\n' "$dir/wt" >> "$dir/home/state/$id.meta"
  fi
  write_recovery_native_launch "$dir" "$dir/home" "$id" "$kind"
  write_recovery_native_session "$dir/wt/personal-session.jsonl" "$dir/wt" "personal task unrelated to Firstmate"
  write_recovery_session_proof "$dir" "$id"
}

# Top-level state the group files share.
trap relaunch_cleanup EXIT
HERDR_CASE_DIR=
HERDR_CASE_ID=

# Each group registers control_relaunch_test_cases and then calls this with its
# own arguments: none runs every case, and named cases run in registered order.
control_relaunch_run() {
  local requested_case test_case registered_case
  # Validate the complete selection before running any behavioral case.
  for requested_case in "$@"; do
    registered_case=false
    # shellcheck disable=SC2154 # Each group assigns control_relaunch_test_cases before calling this.
    for test_case in "${control_relaunch_test_cases[@]}"; do
      if [ "$requested_case" = "$test_case" ]; then
        registered_case=true
        break
      fi
    done
    if [ "$registered_case" = false ]; then
      printf 'Unknown test case: %s\n' "$requested_case" >&2
      printf 'Usage: bash tests/%s [test_function_name ...]\n' "$(basename "$0")" >&2
      exit 2
    fi
  done

  for test_case in "${control_relaunch_test_cases[@]}"; do
    if [ "$#" -eq 0 ]; then
      "$test_case"
      continue
    fi
    for requested_case in "$@"; do
      if [ "$requested_case" = "$test_case" ]; then
        "$test_case"
        break
      fi
    done
  done
}
