#!/usr/bin/env bash
# fm-control.sh relaunch: the transactional replace-the-agent verb.
#
# Relaunch and continuation authorization change durable records, so these
# tests pin their transactions hermetically (stubbed session provider, no
# real agent):
#   1. A same-harness relaunch keeps every identity axis and reuses the SAME
#      endpoint and worktree - it replaces an agent, it never forks a task.
#   2. A harness switch is one ordinary relaunch: the record follows, the
#      previous harness's per-task wiring is cleared, and profile axes chosen
#      for the old harness do not silently carry to the new one.
#   3. The progress note is required where the replacement needs it, lands in
#      the instructions the replacement reads, and never rewrites a charter.
#   4. A refusal before the agent is stopped changes nothing.
#   5. A launch failure after the agent is stopped keeps the prior record,
#      reports the concrete state, and preserves the work.
#   6. fm-spawn --relaunch refuses on its own: a live agent, a contradicting
#      flag, an extra positional, or a backend that cannot prove the previous
#      agent exited.
set -u

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
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR

relaunch_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  chmod -R u+w "$TMP_ROOT" 2>/dev/null || true
  rm -rf "$TMP_ROOT"
}
trap relaunch_cleanup EXIT

# The same lifecycle-modelling tmux stub as tests/fm-control.test.sh: the
# harness's exit command stops the agent, and a launch-brief literal starts the
# harness named in `becomes`.
make_process_table_stub() { # <case-dir>
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
if [ -f "$D/herdr-agent-registration" ]; then
  case "$*" in
    '-axo pid=,ppid=,comm=') printf '4242 1 bash\n'; exit 0 ;;
    '-p 4242 -o args=') printf 'bash\n'; exit 0 ;;
  esac
fi
exec /bin/ps "$@"
SH
  chmod +x "$1/fakebin/ps"
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
  show-environment)
    if [ "${2:-}" = -t ]; then
      printf '%s\n' "${3:-}" >> "$D/env-sessions"
      [ "$#" -ne 3 ] || exit 0
      cat "$D/tmux-env-${3:-}-${4:-}" 2>/dev/null
    elif [ "${2:-}" = -g ]; then
      [ "$#" -ne 2 ] || exit 0
      cat "$D/tmux-env-global-${3:-}" 2>/dev/null
    else
      exit 1
    fi
    exit $? ;;
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
          if [ -n "${FM_FAKE_LAUNCH_STATUS_PATH:-}" ] && [ -n "${FM_FAKE_LAUNCH_STATUS_EVENT:-}" ]; then
            printf '%s\n' "$FM_FAKE_LAUNCH_STATUS_EVENT" > "$FM_FAKE_LAUNCH_STATUS_PATH"
          fi
          [ -z "${FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START:-}" ] || exit 1
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
      case "$payload" in
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
          if [ -n "${FM_FAKE_CWD_RACE_READY:-}" ] && [ ! -e "$FM_FAKE_CWD_RACE_READY" ]; then
            : > "$FM_FAKE_CWD_RACE_READY"
            deadline=$((SECONDS + ${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}))
            while [ ! -e "$FM_FAKE_CWD_RACE_RELEASE" ]; do
              if [ "$SECONDS" -ge "$deadline" ]; then
                : > "$FM_FAKE_CWD_RACE_READY.expired"
                exit 1
              fi
              /bin/sleep 0.05
            done
          fi
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
if [ -n "${FM_FAKE_JOURNAL_PHASE_MV_FAIL:-}" ]; then
  for path in "$@"; do
    if [ -f "$path" ] && grep -Fqx "phase=$FM_FAKE_JOURNAL_PHASE_MV_FAIL" "$path"; then
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

# --- 1. same-harness relaunch -----------------------------------------------

test_same_harness_relaunch_keeps_identity_and_reuses_the_endpoint() {
  local dir out rc gen_before gen_after
  dir=$(new_case same rl1)
  add_ship_task "$dir" rl1 claude
  gen_before=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" rl1)
  printf 'busy_gen=%s\n' "$gen_before" >> "$dir/home/state/rl1.meta"
  out=$(run_control "$dir" rl1 relaunch --note "stopped mid-refactor"); rc=$?
  expect_code 0 "$rc" "a same-harness relaunch should succeed"$'\n'"$out"
  assert_contains "$out" "relaunched rl1 harness=claude from=claude" "the outcome should name the transition"
  [ "$(meta_field "$dir" rl1 window)" = "fmses:fm-rl1" ] \
    || fail "the endpoint must be reused, not recreated"
  [ "$(meta_field "$dir" rl1 worktree)" = "$dir/wt" ] \
    || fail "the worktree must be reused, not reallocated"
  [ "$(meta_field "$dir" rl1 kind)" = ship ] || fail "kind must survive the relaunch"
  [ "$(meta_field "$dir" rl1 project)" = "$dir/proj" ] || fail "project must survive the relaunch"
  gen_after=$(meta_field "$dir" rl1 busy_gen)
  [ -n "$gen_after" ] && [ "$gen_after" != "$gen_before" ] \
    || fail "a relaunch must arm a fresh busy generation, got '$gen_after'"
  [ "$(journal_field "$dir" rl1 phase)" = complete ] \
    || fail "the transaction journal should end complete"
  assert_grep "/exit" "$dir/fake/literal" "the previous agent should have been exited"
  assert_grep "cd -- '$dir/wt'" "$dir/fake/keys" "the replacement launch must enter the recorded worktree"
  assert_grep "Firstmate operational input waiting: read" "$dir/fake/literal" "the replacement should have been launched"
  pass "fm-control relaunch: a same-harness relaunch replaces the agent in the same endpoint and worktree"
}

test_no_dispatch_non_omp_relaunch_does_not_require_jq() {
  local dir id=rl-no-json-tool out rc
  dir=$(new_case no-json-tool "$id")
  add_ship_task "$dir" "$id" codex
  printf codex > "$dir/fake/command"
  printf codex > "$dir/fake/becomes"
  [ ! -e "$dir/home/config/crew-dispatch.json" ] || fail "the no-jq relaunch case must not have dispatch configuration"
  cat > "$dir/fakebin/jq" <<'SH'
#!/usr/bin/env bash
exit 127
SH
  chmod +x "$dir/fakebin/jq"

  out=$(run_control "$dir" "$id" relaunch --note "continue the task"); rc=$?
  expect_code 0 "$rc" "ordinary codex relaunch without dispatch must not require jq: $out"
  assert_contains "$out" "relaunched $id harness=codex from=codex" "ordinary relaunch did not succeed"
  assert_equals codex "$(meta_field "$dir" "$id" harness)" "ordinary relaunch changed the durable harness"
  assert_equals default "$(meta_field "$dir" "$id" model)" "ordinary relaunch corrupted the durable model"
  assert_equals default "$(meta_field "$dir" "$id" effort)" "ordinary relaunch corrupted the durable effort"
  assert_equals complete "$(journal_field "$dir" "$id" phase)" "ordinary relaunch did not complete its transaction"
  assert_equals "$dir/wt" "$(meta_field "$dir" "$id" worktree)" "ordinary relaunch changed the worktree"
  assert_not_contains "$out" 'model-matrix fallback' "ordinary relaunch must not invent matrix routing"
  pass "an ordinary non-OMP relaunch without crew-dispatch.json succeeds without required jq and preserves its durable profile"
}

enable_exhausted_claude_dispatch() {
  local dir=$1
  mkdir -p "$dir/home/config"
  printf '%s\n' '{"rules":[{"when":"assigned work","use":{"harness":"claude"},"fallback":[{"harness":"omp","model":"openrouter/z-ai/glm-5.3-flash","effort":"high"}]}]}' \
    > "$dir/home/config/crew-dispatch.json"
  cat > "$dir/fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"schemaVersion":6,"providers":[{"provider":"claude","accountKey":"default","quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]}}]}'
SH
  cat > "$dir/fakebin/omp" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  models) printf '%s\n' '{"models":[{"provider":"openrouter","id":"z-ai/glm-5.3-flash","selector":"openrouter/z-ai/glm-5.3-flash"}]}' ;;
  *) printf '%s\n' "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY-}" "ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN-}" > "${0%/*}/worker.env" ;;
esac
SH
  cat > "$dir/fakebin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY-}" "ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN-}" > "${0%/*}/worker.env"
SH
  chmod +x "$dir/fakebin/quota-axi" "$dir/fakebin/omp" "$dir/fakebin/claude"
}

test_claude_relaunch_preserves_unknown_adopted_auth_and_forwarded_credentials() {
  local dir id credential policy out rc expected_harness expected_model expected_effort launch
  local -a pane_env
  for credential in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do
    for policy in ambient retained filtered flag-only target-session caller-only; do
      id="rl-auth-$credential-$policy"
      dir=$(new_case "$id" "$id")
      add_ship_task "$dir" "$id" claude
      enable_exhausted_claude_dispatch "$dir"
      printf 'dispatch_rule=rule_1\n' >> "$dir/home/state/$id.meta"
      case "$policy" in
        ambient|flag-only|target-session) printf 'api_key=allow\n' >> "$dir/home/state/$id.meta" ;;
        retained)
          printf '%s\n' PATH "$credential" > "$dir/home/config/launch-env-allowlist"
          printf 'api_key=allow\n' >> "$dir/home/state/$id.meta"
          ;;
        filtered) printf 'PATH\n' > "$dir/home/config/launch-env-allowlist" ;;
      esac
      expected_harness=claude expected_model=default expected_effort=default
      if [ "$policy" = target-session ]; then
        printf '%s\n' "$credential=synthetic-launch-credential" > "$dir/fake/tmux-env-fmses-$credential"
      fi
      case "$policy" in
        ambient|retained|filtered)
          printf '%s\n' "$credential=synthetic-launch-credential" > "$dir/fake/tmux-env-fmses-$credential"
          ;;
        caller-only)
          printf '%s\n' "-$credential" > "$dir/fake/tmux-env-fmses-$credential"
          printf '%s\n' "$credential=unrelated-global-credential" > "$dir/fake/tmux-env-global-$credential"
          ;;
      esac
      printf '%s' "$expected_harness" > "$dir/fake/becomes"
      out=$(
        unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
        if [ "$policy" != flag-only ] && [ "$policy" != target-session ]; then
          export "$credential=synthetic-launch-credential"
        fi
        TMUX=supervisor,1,0 run_control "$dir" "$id" relaunch --note "continue with the selected authentication"
      )
      rc=$?
      expect_code 0 "$rc" "$credential $policy relaunch must succeed: $out"
      assert_contains "$out" "relaunched $id harness=$expected_harness from=claude" "$credential $policy relaunched the wrong harness"
      assert_equals "$expected_harness" "$(meta_field "$dir" "$id" harness)" "$credential $policy recorded the wrong harness"
      assert_equals "$expected_model" "$(meta_field "$dir" "$id" model)" "$credential $policy recorded the wrong model"
      assert_equals "$expected_effort" "$(meta_field "$dir" "$id" effort)" "$credential $policy recorded the wrong effort"
      assert_equals rule_1 "$(meta_field "$dir" "$id" dispatch_rule)" "$credential $policy lost dispatch identity"
      assert_equals complete "$(journal_field "$dir" "$id" phase)" "$credential $policy did not complete its transaction"
      case "$policy" in
        ambient|retained|flag-only|target-session)
          assert_equals allow "$(meta_field "$dir" "$id" api_key)" "$credential $policy lost the deliberate billing opt-in"
          ;;
      esac
      launch=$(cat "$dir/fake/launch")
      pane_env=(-u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN
        -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR
        -u CLAUDE_CONFIG_DIR HOME="$dir/user-home")
      if [ "$policy" != flag-only ] && [ "$policy" != caller-only ]; then
        pane_env+=("$credential=synthetic-launch-credential")
      fi
      fm_eval_launch "$launch" "$dir/wt" "$dir/fakebin" "${pane_env[@]}" \
        > "$dir/worker.out" 2>&1 || fail "$credential $policy staged replacement could not be consumed"
      case "$policy" in
        ambient|retained|target-session)
          grep -Fxq "$credential=synthetic-launch-credential" "$dir/fakebin/worker.env" || fail "$credential did not reach the Claude replacement"
          ;;
        *)
          grep -Fxq "$credential=" "$dir/fakebin/worker.env" || fail "$credential reached the Claude replacement despite absent or filtered authentication"
          ;;
      esac
    done
  done
  pass "Claude relaunch retains its route when adopted-pane authentication is unknown and forwards only permitted API credentials"
}

test_relaunch_refuses_before_exit_when_the_composer_holds_pending_text() {
  local dir out rc
  dir=$(new_case pending-exit rl43)
  add_ship_task "$dir" rl43 claude
  printf 'i' > "$dir/fake/composer"

  out=$(run_control "$dir" rl43 relaunch --note "preserve the pending draft"); rc=$?

  expect_code 1 "$rc" "a relaunch must refuse before typing an exit command into pending composer text"
  assert_contains "$out" "composer visibly holds pending text" \
    "the refusal should name the pending composer text"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a pending composer refusal must leave the old agent running"
  assert_no_grep "/exit" "$dir/fake/literal" \
    "the exit command must not be concatenated onto pending composer text"
  pass "fm-control relaunch: pending composer text refuses before the exit command is typed"
}

test_relaunch_refuses_before_exit_when_the_composer_state_is_unproven() {
  local dir out rc
  dir=$(new_case unproven-exit rl44)
  add_ship_task "$dir" rl44 claude

  out=$(FM_FAKE_COMPOSER_READ_FAIL=1 \
    run_control "$dir" rl44 relaunch --note "preserve on an unreadable composer"); rc=$?

  expect_code 1 "$rc" "a relaunch must refuse before typing an exit command when the composer state cannot be proven empty"
  assert_contains "$out" "not proven empty" \
    "the refusal should name the unproven composer state, not claim pending text"
  assert_not_contains "$out" "visibly holds pending text" \
    "an unreadable composer is not the same claim as observed pending text"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "an unproven composer refusal must leave the old agent running"
  assert_no_grep "/exit" "$dir/fake/literal" \
    "the exit command must not be typed when the composer state is not proven empty"
  pass "fm-control relaunch: an unreadable composer fails safe before the exit command is typed"
}

test_relaunch_from_linked_home_preserves_recorded_worktree() {
  local dir out rc head fetch_head
  dir=$(new_case linked-home rl42)
  add_ship_task "$dir" rl42 claude
  git -C "$dir/proj" worktree add --quiet --detach "$dir/secondmate" HEAD
  sed "s|^project=.*|project=$dir/secondmate|" "$dir/home/state/rl42.meta" > "$dir/linked.meta"
  mv "$dir/linked.meta" "$dir/home/state/rl42.meta"
  printf 'committed task work\n' > "$dir/wt/task.txt"
  git -C "$dir/wt" add task.txt
  git -C "$dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm task-work
  head=$(git -C "$dir/wt" rev-parse HEAD)
  printf 'unfinished task work\n' >> "$dir/wt/task.txt"
  fetch_head=$(git -C "$dir/wt" rev-parse --git-path FETCH_HEAD)

  out=$(run_control "$dir" rl42 relaunch --note "continue from linked home"); rc=$?
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# evidence begin: linked-home relaunch\n'
    printf '$ bin/fm-control.sh rl42 relaunch --note "continue from linked home"\n%s\nexit=%s\n' "$out" "$rc"
    printf 'worker HEAD before=%s after=%s\n' "$head" "$(git -C "$dir/wt" rev-parse HEAD)"
    printf 'saved task metadata:\n'; cat "$dir/home/state/rl42.meta"
    printf 'worker status:\n'; git -C "$dir/wt" status --short
    printf 'preserved task.txt:\n'; cat "$dir/wt/task.txt"
    if [ -e "$fetch_head" ]; then
      printf 'worker FETCH_HEAD:\n'; cat "$fetch_head"
    else
      printf 'worker FETCH_HEAD absent\n'
    fi
    printf '# evidence end\n'
  fi
  expect_code 0 "$rc" "a linked spawning home should relaunch its recorded copy"$'\n'"$out"
  [ "$(meta_field "$dir" rl42 worktree)" = "$dir/wt" ] || fail "relaunch replaced the recorded copy"
  [ "$(meta_field "$dir" rl42 project)" = "$dir/secondmate" ] || fail "relaunch replaced the linked spawning home"
  [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$head" ] || fail "relaunch reset committed task work"
  assert_grep 'unfinished task work' "$dir/wt/task.txt" "relaunch discarded unfinished task work"
  [ ! -e "$fetch_head" ] || fail "relaunch fetched instead of preserving the recorded copy"
  pass "fm-control relaunch: a linked spawning home preserves committed and unfinished work in the recorded copy"
}

test_relaunch_preserves_durable_task_metadata() {
  local dir out rc
  dir=$(new_case durable-meta rl19)
  add_ship_task "$dir" rl19 claude
  {
    printf '%s\n' 'pr=https://github.com/example/repo/pull/19'
    printf '%s\n' 'pr_head=feature/relaunch'
    printf '%s\n' 'x_request=request-19'
    printf '%s\n' 'decisions_reviewed=1'
  } >> "$dir/home/state/rl19.meta"

  out=$(run_control "$dir" rl19 relaunch --note "continuing review work"); rc=$?
  expect_code 0 "$rc" "relaunch should preserve durable metadata"$'\n'"$out"
  [ "$(meta_field "$dir" rl19 pr)" = "https://github.com/example/repo/pull/19" ] \
    || fail "the task PR must survive relaunch"
  [ "$(meta_field "$dir" rl19 pr_head)" = "feature/relaunch" ] \
    || fail "the task PR head must survive relaunch"
  [ "$(meta_field "$dir" rl19 x_request)" = "request-19" ] \
    || fail "the task X request must survive relaunch"
  [ "$(meta_field "$dir" rl19 decisions_reviewed)" = 1 ] \
    || fail "the task decision state must survive relaunch"
  pass "fm-control relaunch: durable task metadata survives replacement launch publication"
}

test_relaunch_serializes_concurrent_durable_metadata_publication() {
  local dir control_pid link_pid rc i=0 traceparent prepare launch_release waiting ready release
  dir=$(new_case metadata-race rl28)
  add_ship_task "$dir" rl28 claude
  printf '%s\n' "$$" > "$dir/home/state/.lock"
  printf '%s on\n' "$$" > "$dir/home/state/.trace-context-effective"
  make_mv_failure_stub "$dir"
  prepare="$dir/trace-prepare"
  launch_release="$dir/trace-release"
  waiting="$dir/meta-writer-waiting"
  ready="$dir/meta-writer-ready"
  release="$dir/meta-writer-release"
  FM_REAL_MV=$(command -v mv) \
    FM_FAKE_TRACE_PREPARE="$prepare" \
    FM_FAKE_TRACE_RELEASE="$launch_release" \
    run_control "$dir" rl28 relaunch --note "continue after publication" > "$dir/control.out" &
  control_pid=$!
  while [ ! -e "$prepare" ] && [ "$i" -lt 500 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$prepare" ] || {
    kill "$control_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "relaunch did not reach trace delivery"
  }
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_REAL_MV="$(command -v mv)" \
    FM_FAKE_LOCK_WAITING="$waiting" \
    FM_FAKE_META_WRITER_TARGET="$dir/home/state/rl28.meta" \
    FM_FAKE_META_WRITER_READY="$ready" \
    FM_FAKE_META_WRITER_RELEASE="$release" \
    "$X_LINK" rl28 request-28 --carry-count 1 --carry-ts 1700000000 \
      --carry-platform x --carry-max 280 > "$dir/link.out" 2>&1 &
  link_pid=$!
  i=0
  while [ ! -e "$waiting" ] && [ "$i" -lt 500 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$waiting" ] && [ ! -e "$ready" ] || {
    : > "$launch_release"
    : > "$release"
    wait "$link_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "a durable metadata writer was not blocked during relaunch delivery"
  }
  : > "$launch_release"
  i=0
  while [ ! -e "$ready" ] && [ "$i" -lt 500 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$ready" ] || {
    kill "$link_pid" "$control_pid" 2>/dev/null || true
    wait "$link_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "durable metadata writer did not resume after relaunch delivery committed"
  }
  : > "$release"
  wait "$link_pid"; rc=$?
  expect_code 0 "$rc" "concurrent X metadata publication should serialize"$'\n'"$(cat "$dir/link.out")"
  wait "$control_pid"; rc=$?
  expect_code 0 "$rc" "relaunch should complete before serialized metadata publication"$'\n'"$(cat "$dir/control.out")"
  [ "$(meta_field "$dir" rl28 x_request)" = request-28 ] \
    || fail "relaunch erased metadata published concurrently through the X interface"
  [ "$(meta_field "$dir" rl28 x_followups)" = 1 ] \
    || fail "relaunch erased the concurrent follow-up count"
  traceparent=$(meta_field "$dir" rl28 traceparent)
  fm_trace_context_valid "$traceparent" \
    || fail "concurrent metadata publication erased the replacement's trace carrier"
  assert_relaunch_worker_trace "$dir" "$traceparent"
  pass "fm-control relaunch: delivery and concurrent task metadata publication serialize"
}

test_disabled_relaunch_clears_prior_trace_context() {
  local dir out rc
  dir=$(new_case trace-off rl33)
  add_ship_task "$dir" rl33 claude
  printf '%s\n' 'traceparent=00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01' \
    >> "$dir/home/state/rl33.meta"
  printf '%s\n' "$$" > "$dir/home/state/.lock"
  printf '%s off\n' "$$" > "$dir/home/state/.trace-context-effective"

  out=$(run_control "$dir" rl33 relaunch --note "crossing trace boundary"); rc=$?
  expect_code 0 "$rc" "disabled relaunch should succeed"$'\n'"$out"
  [ -z "$(meta_field "$dir" rl33 traceparent)" ] \
    || fail "disabled relaunch must remove the prior trace carrier from metadata"
  assert_relaunch_worker_trace "$dir" unset
  pass "fm-control relaunch: disabling tracing clears metadata and pane context"
}

test_relaunch_appends_the_progress_note_to_the_instructions() {
  local dir out rc brief launch_brief first_line role_line task_line
  dir=$(new_case note rl2)
  add_ship_task "$dir" rl2 claude
  cp "$ROOT/AGENTS.md" "$dir/wt/AGENTS.md"
  out=$(run_control "$dir" rl2 relaunch --note "reproduced the crash in parser.go"); rc=$?
  expect_code 0 "$rc" "relaunch should succeed"$'\n'"$out"
  brief="$dir/home/data/rl2/brief.md"
  assert_grep "Exercise relaunch behavior for rl2." "$brief" "the original instructions must survive"
  assert_grep "## Progress note" "$brief" "the note should be a dated section in the instructions"
  assert_grep "reproduced the crash in parser.go" "$brief" "the note text should reach the replacement"
  assert_grep "reproduced the crash in parser.go" "$dir/home/state/rl2.control-relaunch.note" \
    "the note should also be preserved beside the transaction record"
  launch_brief="$dir/home/data/rl2/launch-brief.md"
  first_line=$(sed -n '1p' "$launch_brief")
  [ "$first_line" = '# Current worker role contract' ] ||
    fail "a Firstmate-worktree relaunch did not establish the crewmate identity first"
  role_line=$(grep -n '^# Current worker role contract$' "$launch_brief" | cut -d: -f1)
  task_line=$(grep -n '^# Task$' "$launch_brief" | head -1 | cut -d: -f1)
  [ "$role_line" -lt "$task_line" ] || fail "the relaunched worker identity followed its task content"
  assert_grep "$dir/home/state/rl2.inbox" "$launch_brief" \
    "the Firstmate-worktree relaunch omitted the worker's exact steering inbox"
  assert_grep 'do not reject it as another home' "$launch_brief" \
    "the Firstmate-worktree relaunch did not distinguish its inbox from cross-home state"
  pass "fm-control relaunch: progress and the Firstmate-worktree worker identity reach the replacement"
}

test_relaunch_requires_a_note_for_a_ship_task() {
  local dir out rc before
  dir=$(new_case nonote rl3)
  add_ship_task "$dir" rl3 claude
  before=$(cat "$dir/home/data/rl3/brief.md")
  out=$(run_control "$dir" rl3 relaunch); rc=$?
  expect_code 1 "$rc" "a ship relaunch without a note should refuse"
  assert_contains "$out" "requires --note" "the refusal should name the missing note"
  [ "$(cat "$dir/home/data/rl3/brief.md")" = "$before" ] \
    || fail "a refused relaunch must not touch the instructions"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused relaunch must send nothing"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: a ship task refuses without the progress note its replacement needs"
}

# --- 2. harness switch -------------------------------------------------------

test_harness_switch_moves_the_record_and_clears_prior_wiring() {
  local dir out rc
  dir=$(new_case switch rl4)
  add_ship_task "$dir" rl4 claude
  # Wiring the previous claude incarnation left in the worktree.
  mkdir -p "$dir/wt/.claude"
  printf '{"hooks":{}}\n' > "$dir/wt/.claude/settings.local.json"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl4 relaunch --harness codex --note "switching runtime"); rc=$?
  expect_code 0 "$rc" "a harness switch should succeed"$'\n'"$out"
  assert_contains "$out" "harness=codex from=claude" "the outcome should name both harnesses"
  [ "$(meta_field "$dir" rl4 harness)" = codex ] || fail "the record should follow the switch"
  [ ! -e "$dir/wt/.claude/settings.local.json" ] \
    || fail "the previous harness's per-task wiring must be cleared on a switch"
  assert_grep "codex" "$dir/fake/literal" "the replacement launch should be the new harness"
  [ "$(journal_field "$dir" rl4 from_harness)" = claude ] || fail "the journal should record the origin harness"
  [ "$(journal_field "$dir" rl4 to_harness)" = codex ] || fail "the journal should record the target harness"
  pass "fm-control relaunch: switching harness is one ordinary relaunch, and the old wiring goes with the old agent"
}

test_harness_switch_does_not_carry_the_old_profile_axes() {
  local dir out rc
  dir=$(new_case profile rl5)
  add_ship_task "$dir" rl5 claude
  sed 's/^model=default$/model=opus/; s/^effort=default$/effort=xhigh/' \
    "$dir/home/state/rl5.meta" > "$dir/home/state/rl5.meta.tmp"
  mv "$dir/home/state/rl5.meta.tmp" "$dir/home/state/rl5.meta"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl5 relaunch --harness codex --note "switching runtime"); rc=$?
  expect_code 0 "$rc" "a harness switch should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" rl5 model)" = default ] \
    || fail "a model chosen for the old harness must not carry to a different one"
  [ "$(meta_field "$dir" rl5 effort)" = default ] \
    || fail "an effort chosen for the old harness must not carry to a different one"
  pass "fm-control relaunch: a harness switch resets model and effort unless they are named too"
}

test_harness_switch_resolves_a_prefixed_recorded_harness() {
  local dir out rc auth
  dir=$(new_case prefixcontrol rl32)
  add_ship_task "$dir" rl32 grok-2
  printf 'grok-2' > "$dir/fake/command"
  mkdir -p "$dir/grokhome/hooks/fm-turn-end.d"
  printf 'fm.abcdefabcdef\n' > "$dir/home/state/rl32.grok-turnend-token"
  auth="$dir/grokhome/hooks/fm-turn-end.d/fm.abcdefabcdef"
  printf '%s\n' "$dir/home/state/rl32.turn-ended" > "$auth"
  printf 'token=fm.abcdefabcdef\n' > "$dir/wt/.fm-grok-turnend"

  out=$(run_control "$dir" rl32 relaunch --harness claude --note "switching runtime"); rc=$?
  expect_code 0 "$rc" "relaunch should resolve a prefixed recorded harness"$'\n'"$out"
  [ "$(sed -n '1p' "$dir/fake/literal")" = /exit ] \
    || fail "relaunch should stop a grok-prefixed task with grok's exit command"
  [ "$(meta_field "$dir" rl32 harness)" = claude ] \
    || fail "relaunch should publish the explicitly selected replacement harness"
  [ "$(journal_field "$dir" rl32 from_harness)" = grok-2 ] \
    || fail "relaunch should retain the recorded harness basename in its provenance"
  assert_contains "$out" "harness=claude from=grok-2" \
    "relaunch should report the recorded-to-selected harness transition"
  [ ! -e "$auth" ] && [ ! -e "$dir/home/state/rl32.grok-turnend-token" ] \
    && [ ! -e "$dir/wt/.fm-grok-turnend" ] \
    || fail "relaunch should retire wiring owned by the prefixed prior harness"
  pass "fm-control relaunch: a prefixed recorded harness can switch adapters transactionally"
}

test_prefixed_recorded_harness_requires_explicit_replacement() {
  local dir out rc meta brief
  dir=$(new_case prefixrefuse rl34)
  add_ship_task "$dir" rl34 grok-2
  printf 'grok-2' > "$dir/fake/command"
  meta="$dir/home/state/rl34.meta"
  brief="$dir/home/data/rl34/brief.md"
  cp "$meta" "$dir/meta.before"
  cp "$brief" "$dir/brief.before"

  out=$(run_control "$dir" rl34 relaunch --note "continue safely"); rc=$?
  expect_code 1 "$rc" "implicit relaunch from a prefixed command should refuse"
  assert_contains "$out" "original launch command cannot be reconstructed from its recorded basename" \
    "the refusal should name the missing launch identity"
  assert_contains "$out" "would substitute the canonical adapter 'grok'" \
    "the refusal should name the unsafe substitution"
  assert_contains "$out" "Pass an explicit --harness" \
    "the refusal should name the deliberate replacement path"
  cmp -s "$meta" "$dir/meta.before" \
    || fail "a refused prefixed relaunch must leave metadata byte-identical"
  cmp -s "$brief" "$dir/brief.before" \
    || fail "a refused prefixed relaunch must leave instructions byte-identical"
  [ "$(cat "$dir/fake/command")" = grok-2 ] \
    || fail "a refused prefixed relaunch must leave the original agent alive"
  [ -z "$(cat "$dir/fake/literal")" ] && [ -z "$(cat "$dir/fake/keys")" ] \
    || fail "a refused prefixed relaunch must deliver no lifecycle input"
  [ ! -e "$dir/home/state/rl34.control-relaunch" ] \
    || fail "a refused prefixed relaunch must not create a durable journal"
  pass "fm-control relaunch: a prefixed command requires an explicit replacement harness"
}

test_same_harness_relaunch_keeps_the_profile_axes() {
  local dir out rc
  dir=$(new_case keepprofile rl6)
  add_ship_task "$dir" rl6 claude
  sed 's/^model=default$/model=opus/; s/^effort=default$/effort=high/' \
    "$dir/home/state/rl6.meta" > "$dir/home/state/rl6.meta.tmp"
  mv "$dir/home/state/rl6.meta.tmp" "$dir/home/state/rl6.meta"
  out=$(run_control "$dir" rl6 relaunch --note "same runtime"); rc=$?
  expect_code 0 "$rc" "a same-harness relaunch should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" rl6 model)" = opus ] || fail "the model should carry across a same-harness relaunch"
  [ "$(meta_field "$dir" rl6 effort)" = high ] || fail "the effort should carry across a same-harness relaunch"
  pass "fm-control relaunch: a same-harness relaunch keeps the profile axes it was running with"
}

test_native_ultra_relaunch_preserves_profile_and_rejects_before_stop() {
  local dir out rc id=rl-ultra
  dir=$(new_case native-ultra "$id")
  add_ship_task "$dir" "$id" pi
  printf pi > "$dir/fake/command"
  printf pi > "$dir/fake/becomes"
  printf '#!/usr/bin/env bash\nprintf "Options: --tui-mode\\n"\n' > "$dir/fakebin/pi"
  chmod +x "$dir/fakebin/pi"
  sed 's|^model=default$|model=codex-native/gpt-6-astra|; s/^effort=default$/effort=ultra/' \
    "$dir/home/state/$id.meta" > "$dir/home/state/$id.meta.tmp"
  mv "$dir/home/state/$id.meta.tmp" "$dir/home/state/$id.meta"
  out=$(run_control "$dir" "$id" relaunch --model openai-codex/gpt-6-astra --note "invalid native effort transfer"); rc=$?
  expect_code 1 "$rc" "Ultra transferred to ordinary Pi"
  assert_contains "$out" "ultra effort requires pi or pi-signed" "model-aware relaunch refusal missing"
  [ "$(cat "$dir/fake/command")" = pi ] || fail "invalid Ultra relaunch stopped the running agent"
  [ ! -s "$dir/fake/literal" ] || fail "invalid Ultra relaunch sent lifecycle input"
  out=$(run_control "$dir" "$id" relaunch --note "preserve explicit native effort"); rc=$?
  expect_code 0 "$rc" "native Ultra relaunch failed: $out"
  [ "$(meta_field "$dir" "$id" effort)" = ultra ] || fail "relaunch lost Ultra metadata"
  [ "$(meta_field "$dir" "$id" model)" = codex-native/gpt-6-astra ] || fail "relaunch lost native model"
  assert_contains "$(cat "$dir/fake/literal")" "--codex-effort 'ultra'" "relaunch lost native flag"
  assert_not_contains "$(cat "$dir/fake/literal")" "--thinking 'ultra'" "relaunch used an invalid Pi level"
  pass "native Ultra relaunch preserves its profile and rejects an unsupported model before stopping"
}

test_model_index_resolves_and_refuses_before_stop() {
  local dir out rc id=rl-index
  dir=$(new_case model-index "$id")
  add_ship_task "$dir" "$id" pi
  printf pi > "$dir/fake/command"
  printf pi > "$dir/fake/becomes"
  printf '#!/usr/bin/env bash\nprintf "Options: --tui-mode\\n"\n' > "$dir/fakebin/pi"
  chmod +x "$dir/fakebin/pi"
  sed 's|^model=default$|model=codex-native/gpt-old|; s/^effort=default$/effort=ultra/' \
    "$dir/home/state/$id.meta" > "$dir/home/state/$id.meta.tmp"
  mv "$dir/home/state/$id.meta.tmp" "$dir/home/state/$id.meta"
  mkdir -p "$dir/home/config" "$dir/catalogs"
  printf '%s\n' '{"version":1,"roles":{"native":{"pi":{"model":"codex-native/gpt-6-astra"}}},"retired":["gpt-old"]}' \
    > "$dir/home/config/model-index.json"
  printf '%s\n' '{"models":[{"id":"codex-native/gpt-6-astra"}]}' > "$dir/catalogs/pi.json"
  out=$(FM_MODEL_CATALOG_DIR="$dir/catalogs" run_control "$dir" "$id" relaunch --note "recorded model since retired"); rc=$?
  expect_code 1 "$rc" "a recorded model the index has retired must refuse"
  assert_contains "$out" "retired model: codex-native/gpt-old" "the refusal should name the retired id"
  [ "$(cat "$dir/fake/command")" = pi ] || fail "a retired-model relaunch stopped the running agent"
  [ ! -s "$dir/fake/literal" ] || fail "a retired-model relaunch sent lifecycle input"
  out=$(FM_MODEL_CATALOG_DIR="$dir/catalogs" run_control "$dir" "$id" relaunch --model role:native --note "move to the indexed role"); rc=$?
  expect_code 0 "$rc" "a role relaunch with native Ultra should resolve before its effort check: $out"
  [ "$(meta_field "$dir" "$id" model)" = codex-native/gpt-6-astra ] || fail "the relaunch should record the resolved id"
  assert_contains "$(cat "$dir/fake/literal")" "--codex-effort 'ultra'" "the resolved native model should keep its Ultra flag"
  assert_not_contains "$(cat "$dir/fake/literal")" "role:native" "a role reference must not reach the harness"
  printf '%s\n' '{"models":[{"id":"codex-native/gpt-7"}]}' > "$dir/catalogs/pi.json"
  cp "$dir/fake/literal" "$dir/literal-before"
  out=$(FM_MODEL_CATALOG_DIR="$dir/catalogs" run_control "$dir" "$id" relaunch --note "vendor dropped the id"); rc=$?
  expect_code 1 "$rc" "an index entry its catalog no longer lists must refuse"
  assert_contains "$out" "id 'codex-native/gpt-6-astra' absent or retired in pi catalog" "the refusal should name the absent id"
  [ "$(cat "$dir/fake/command")" = pi ] || fail "a catalog-absent relaunch stopped the running agent"
  cmp -s "$dir/literal-before" "$dir/fake/literal" || fail "a catalog-absent relaunch sent lifecycle input"
  pass "fm-control relaunch: roles resolve, and retired or catalog-absent ids refuse through the model index before the stop"
}

test_model_index_generation_survives_account_checks_and_replacement() {
  local dir out rc id request verdict selected
  for request in role:chosen stand-in:chosen openai/selected; do
    id="rl-generation-${request//[:\/]/-}"
    dir=$(new_case model-generation "$id")
    add_ship_task "$dir" "$id" pi
    printf pi > "$dir/fake/command"
    printf pi > "$dir/fake/becomes"
    mkdir -p "$dir/home/config" "$dir/account"
    printf '%s\nopenai\n' "$dir/account" > "$dir/home/config/pi-account"
    printf '%s\n' '{"version":1,"roles":{"chosen":{"pi":{"model":"openai/selected","stand_in":"openai/standby"}}},"retired":[]}' \
      > "$dir/original-index.json"
    selected=openai/selected
    [ "$request" != stand-in:chosen ] || selected=openai/standby
    cat > "$dir/fakebin/pi" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  auth)
    cp '$dir/later.json' '$dir/home/config/model-index.json'
    printf '%s\n' "\$PI_CODING_AGENT_DIR" >> '$dir/auth-roots'
    printf '{"status":"ready"}\n'
    ;;
  --list-models)
    printf '%s\n' "\$PI_CODING_AGENT_DIR" >> '$dir/catalog-roots'
    printf 'provider model context\n'
    cat "\$PI_CODING_AGENT_DIR/listed"
    ;;
  *) printf 'Options: --tui-mode\n' ;;
esac
SH
    chmod +x "$dir/fakebin/pi"
    for verdict in absent available; do
      cp "$dir/original-index.json" "$dir/home/config/model-index.json"
      : > "$dir/auth-roots"
      : > "$dir/catalog-roots"
      : > "$dir/fake/literal"
      : > "$dir/fake/keys"
      if [ "$verdict" = available ]; then
        printf '%s\n' '{"version":1,"roles":{"chosen":{"pi":{"model":"openai/later","stand_in":"openai/later-standby"}}},"retired":["selected","standby"]}' > "$dir/later.json"
        printf 'openai selected 272K 32K yes no\nopenai standby 272K 32K yes no\n' > "$dir/account/listed"
      else
        printf '%s\n' '{"version":1,"roles":{"chosen":{"pi":{"model":"openai/later","stand_in":"openai/later-standby"}}},"retired":[]}' > "$dir/later.json"
        printf 'openai later 272K 32K yes no\n' > "$dir/account/listed"
      fi
      cp "$dir/home/state/$id.meta" "$dir/meta-before"
      out=$(run_control "$dir" "$id" relaunch --model "$request" --note "preserve selected routing generation"); rc=$?
      cmp -s "$dir/later.json" "$dir/home/config/model-index.json" || fail "account check did not mutate the source generation"
      [ "$(cat "$dir/catalog-roots" | sort -u)" = "$dir/account" ] || fail "generation check changed the worker account"
      if [ "$verdict" = absent ]; then
        expect_code 1 "$rc" "an absent originally selected entry must refuse before stopping: $out"
        assert_contains "$out" "id '$selected' absent or retired in pi catalog" "the frozen entry must remain catalog-gated"
        cmp -s "$dir/meta-before" "$dir/home/state/$id.meta" || fail "generation refusal changed the running task record"
        [ "$(cat "$dir/fake/command")" = pi ] || fail "generation refusal stopped the working agent"
        [ ! -s "$dir/fake/literal" ] || fail "generation refusal sent lifecycle input"
      else
        expect_code 0 "$rc" "the selected available generation must survive auth mutation and replacement: $out"
        [ "$(meta_field "$dir" "$id" model)" = "$selected" ] || fail "replacement switched model generations"
        assert_contains "$(cat "$dir/fake/literal")" "--model '$selected'" "replacement lost the frozen model"
        [ "$(wc -l < "$dir/catalog-roots" | tr -d ' ')" = 2 ] || fail "both pre-stop and replacement must check the selected entry"
      fi
    done
  done
  pass "relaunch freezes role, stand-in, and literal membership across authentication and replacement"
}

test_unpinned_indexed_relaunch_does_not_query_the_supervisor_account() {
  local dir out rc id=rl-context model
  dir=$(new_case model-context "$id")
  add_ship_task "$dir" "$id" pi
  printf pi > "$dir/fake/command"
  printf pi > "$dir/fake/becomes"
  mkdir -p "$dir/home/config" "$dir/supervisor" "$dir/pane"
  : > "$dir/home/config/launch-env-allowlist"
  printf 'openai  supervisor-only  272K  32K  yes  no\n' > "$dir/supervisor/listed"
  printf 'openai  pane-only  272K  32K  yes  no\n' > "$dir/pane/listed"
  cat > "$dir/fakebin/pi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --list-models ]; then
  printf '%s\n' "\${PI_CODING_AGENT_DIR-unset}" >> '$dir/catalog-calls'
  printf 'provider model context\n'
  cat "\$PI_CODING_AGENT_DIR/listed"
  exit
fi
printf 'Options: --tui-mode\n'
SH
  chmod +x "$dir/fakebin/pi"
  for model in pane-only supervisor-only; do
    printf '{"version":1,"roles":{"chosen":{"pi":{"model":"openai/%s"}}},"retired":[]}\n' "$model" > "$dir/home/config/model-index.json"
    out=$(PI_CODING_AGENT_DIR="$dir/supervisor" run_control "$dir" "$id" relaunch \
      --model role:chosen --note "replace without supervisor catalog evidence"); rc=$?
    expect_code 0 "$rc" "an unknown replacement context must not refuse from the supervisor catalog: $out"
    assert_contains "$out" "effective worker account context is not established" "pre-stop and spawn checks must disclose unknown context"
    assert_absent "$dir/catalog-calls" "neither pre-stop nor replacement spawn may query the supervisor Pi catalog"
    [ "$(meta_field "$dir" "$id" model)" = "openai/$model" ] || fail "the replacement must retain its chosen model"
  done
  cp "$dir/home/state/$id.meta" "$dir/meta-before"
  cp "$dir/fake/literal" "$dir/literal-before"
  printf '%s\n' '{"version":1,"roles":{"chosen":{"pi":{"model":"openai/supervisor-only"}}},"retired":["supervisor-only"]}' > "$dir/home/config/model-index.json"
  out=$(PI_CODING_AGENT_DIR="$dir/supervisor" run_control "$dir" "$id" relaunch --note "retired selector"); rc=$?
  expect_code 1 "$rc" "unknown context must still refuse offline retirement before stopping"
  assert_contains "$out" "retired model" "retirement must remain authoritative"
  cmp -s "$dir/meta-before" "$dir/home/state/$id.meta" || fail "an offline refusal must preserve metadata"
  cmp -s "$dir/literal-before" "$dir/fake/literal" || fail "an offline refusal must not send lifecycle input"
  [ "$(cat "$dir/fake/command")" = pi ] || fail "an offline refusal must leave the running agent alone"
  pass "unpinned indexed relaunch discloses unknown context before stopping without supervisor catalog evidence"
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

test_signed_out_worker_account_pin_refuses_before_stop() {
  local dir out rc id=rl-acct-out
  dir=$(new_case acct-out "$id")
  add_ship_task "$dir" "$id" claude
  make_claude_auth_stub "$dir"
  mkdir -p "$dir/home/config" "$dir/work"
  printf '%s\n' "$dir/work" > "$dir/home/config/claude-account"
  cp "$dir/home/state/$id.meta" "$dir/meta-before"
  out=$(run_control "$dir" "$id" relaunch --note "account signed out"); rc=$?
  expect_code 1 "$rc" "a relaunch under a signed-out account pin must refuse"
  assert_contains "$out" "config/claude-account pins Claude workers to $dir/work, which is not signed in" \
    "the refusal should name the pin and the signed-out root"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a signed-out pin must refuse before the running agent stops"
  [ ! -s "$dir/fake/literal" ] || fail "a signed-out pin must refuse before any lifecycle input is sent"
  cmp -s "$dir/meta-before" "$dir/home/state/$id.meta" || fail "a refused relaunch must leave the task record untouched"
  pass "fm-control relaunch: a signed-out worker account pin refuses before the old agent stops"
}

test_worker_account_pin_follows_the_relaunch() {
  local dir out rc id=rl-acct
  dir=$(new_case acct "$id")
  add_ship_task "$dir" "$id" claude
  make_claude_auth_stub "$dir"
  mkdir -p "$dir/home/config" "$dir/work"
  : > "$dir/work/.credentials.json"
  printf '%s\n' "$dir/work" > "$dir/home/config/claude-account"
  out=$(run_control "$dir" "$id" relaunch --note "pinned account"); rc=$?
  expect_code 0 "$rc" "a relaunch under a signed-in account pin should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" account)" = "$dir/work" ] || fail "the relaunched record should carry the pinned account"
  assert_contains "$(cat "$dir/fake/literal")" "CLAUDE_CONFIG_DIR='$dir/work'" \
    "the replacement should launch under the pinned root"
  rm "$dir/home/config/claude-account"
  : > "$dir/fake/literal"
  out=$(run_control "$dir" "$id" relaunch --note "pin removed"); rc=$?
  expect_code 0 "$rc" "a relaunch after the pin is removed should succeed"$'\n'"$out"
  assert_no_grep "account=" "$dir/home/state/$id.meta" "a relaunch without a pin must drop the previous account from the record"
  assert_not_contains "$(cat "$dir/fake/literal")" "CLAUDE_CONFIG_DIR=" \
    "an unpinned replacement must launch exactly as before"
  pass "fm-control relaunch: the replacement follows the home's current worker account pin"
}

test_recorded_api_key_opt_in_follows_the_relaunch() {
  local dir out rc id=rl-apikey
  dir=$(new_case apikey "$id")
  add_ship_task "$dir" "$id" claude
  printf 'api_key=allow\n' >> "$dir/home/state/$id.meta"
  printf 'ANTHROPIC_API_KEY=sk-ant-relaunch-test\n' > "$dir/fake/tmux-env-fmses-ANTHROPIC_API_KEY"
  out=$(ANTHROPIC_API_KEY=sk-ant-relaunch-test \
    run_control "$dir" "$id" relaunch --note "deliberate API billing"); rc=$?
  expect_code 0 "$rc" "a relaunch of a task that opted in to API billing should carry the opt-in"$'\n'"$out"
  assert_not_contains "$out" "would reach the claude worker" \
    "the recorded opt-in must keep the guard from refusing the replacement"
  [ "$(grep -c '^api_key=' "$dir/home/state/$id.meta")" = 1 ] \
    || fail "the relaunched record must carry exactly one api_key line"$'\n'"$(cat "$dir/home/state/$id.meta")"
  [ "$(meta_field "$dir" "$id" api_key)" = allow ] \
    || fail "the relaunched record must keep api_key=allow"
  assert_contains "$(cat "$dir/fake/literal")" "Firstmate operational input waiting: read" \
    "the replacement agent should have been launched"
  pass "fm-control relaunch: a recorded api_key=allow opt-in is carried to the replacement launch"
}

test_api_key_guard_refuses_before_stop() {
  local dir out rc id=rl-key-refuse
  dir=$(new_case key-refuse "$id")
  add_ship_task "$dir" "$id" claude
  out=$(ANTHROPIC_AUTH_TOKEN=sk-ant-test-token run_control "$dir" "$id" relaunch --note "guarded"); rc=$?
  expect_code 1 "$rc" "a key must refuse the replacement before stopping the worker"
  assert_contains "$out" "ANTHROPIC_AUTH_TOKEN" "the refusal names the credential variable"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a guard refusal must leave the original worker running"
  [ ! -s "$dir/fake/literal" ] || fail "a guard refusal must not send lifecycle input"
  pass "fm-control relaunch refuses a credential before stopping the original worker"
}

test_api_key_guard_uses_replacement_profile() {
  local dir out rc id=rl-key-profile
  dir=$(new_case key-profile "$id")
  add_ship_task "$dir" "$id" claude
  out=$(ANTHROPIC_API_KEY=sk-ant-test-key run_control "$dir" "$id" relaunch --harness codex --note "switch runner"); rc=$?
  expect_code 0 "$rc" "a non-Claude replacement must not be refused for a Claude credential"$'\n'"$out"
  pass "fm-control checks the replacement harness rather than the previous harness"

  dir=$(new_case key-pin rl-key-pin)
  add_ship_task "$dir" rl-key-pin claude
  make_claude_auth_stub "$dir"
  mkdir -p "$dir/home/config" "$dir/work"
  : > "$dir/work/.credentials.json"
  printf '%s\n' "$dir/work" > "$dir/home/config/claude-account"
  out=$(ANTHROPIC_API_KEY=sk-ant-test-key run_control "$dir" rl-key-pin relaunch --note "pinned"); rc=$?
  expect_code 0 "$rc" "a pin that sheds the key must permit relaunch"$'\n'"$out"
  pass "fm-control honors the replacement account pin's credential shed"

  dir=$(new_case key-allowlist rl-key-allowlist)
  add_ship_task "$dir" rl-key-allowlist claude
  mkdir -p "$dir/home/config"
  printf '%s\n' HOME PATH > "$dir/home/config/launch-env-allowlist"
  out=$(ANTHROPIC_AUTH_TOKEN=sk-ant-test-token run_control "$dir" rl-key-allowlist relaunch --note "filtered"); rc=$?
  expect_code 0 "$rc" "an allowlist that filters the token must permit relaunch"$'\n'"$out"
  pass "fm-control honors the replacement launch allowlist"
}

test_api_key_guard_refuses_tmux_key_before_stop() {
  local dir out rc id=rl-key-tmux
  dir=$(new_case key-tmux "$id")
  add_ship_task "$dir" "$id" claude
  out=$(FM_FAKE_TMUX_GLOBAL_ENV_ANTHROPIC_API_KEY=sk-ant-server-key \
    run_control "$dir" "$id" relaunch --note "guarded"); rc=$?
  expect_code 1 "$rc" "a tmux-only key must refuse before stopping the worker"
  assert_contains "$out" "ANTHROPIC_API_KEY is set in the tmux global environment" \
    "the refusal must identify the tmux scope"
  [ ! -s "$dir/fake/literal" ] || fail "a tmux key refusal must not send lifecycle input"
  pass "fm-control checks tmux environment before stopping the original worker"
}

test_spawn_relaunch_without_the_opt_in_drops_the_recorded_api_key() {
  local dir out rc id=rl-apikey-drop
  dir=$(new_case apikey-drop "$id")
  add_ship_task "$dir" "$id" claude
  printf 'api_key=allow\n' >> "$dir/home/state/$id.meta"
  printf 'zsh' > "$dir/fake/command"
  out=$(unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; run_spawn "$dir" "$id" --relaunch); rc=$?
  expect_code 0 "$rc" "a relaunch without the opt-in and without a key should succeed"$'\n'"$out"
  assert_no_grep "^api_key=" "$dir/home/state/$id.meta" \
    "a relaunch that does not opt in must not inherit the previous api_key=allow line"
  pass "fm-spawn --relaunch: a replacement that does not opt in drops the recorded api_key line"
}

test_explicit_model_wins_over_the_recorded_one() {
  local dir out rc
  dir=$(new_case explicit rl7)
  add_ship_task "$dir" rl7 claude
  out=$(run_control "$dir" rl7 relaunch --model sonnet --effort low --note "dialling down"); rc=$?
  expect_code 0 "$rc" "relaunch with explicit axes should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" rl7 model)" = sonnet ] || fail "an explicit model should be recorded"
  [ "$(meta_field "$dir" rl7 effort)" = low ] || fail "an explicit effort should be recorded"
  pass "fm-control relaunch: explicit model and effort win over the recorded ones"
}

test_relaunch_onto_an_unverified_harness_is_refused() {
  local dir out rc
  dir=$(new_case badharness rl8)
  add_ship_task "$dir" rl8 claude
  out=$(run_control "$dir" rl8 relaunch --harness someagent --note "x"); rc=$?
  expect_code 1 "$rc" "an unverified target harness should refuse"
  assert_contains "$out" "not a verified harness" "the refusal should name the unverified adapter"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: refuses to relaunch onto an adapter with no verified mechanics"
}

test_prior_harness_turnend_registry_entry_is_cleared() {
  local dir auth
  dir=$(new_case grokauth rl9)
  add_ship_task "$dir" rl9 grok
  mkdir -p "$dir/grokhome/hooks/fm-turn-end.d"
  printf 'fm.abcdefabcdef\n' > "$dir/home/state/rl9.grok-turnend-token"
  auth="$dir/grokhome/hooks/fm-turn-end.d/fm.abcdefabcdef"
  printf '%s\n' "$dir/home/state/rl9.turn-ended" > "$auth"
  printf 'grok' > "$dir/fake/command"
  printf 'grok' > "$dir/fake/becomes"
  run_control "$dir" rl9 relaunch --note "restart on the same runtime" >/dev/null
  [ ! -e "$auth" ] \
    || fail "the previous incarnation's turn-end registry entry must not outlive it"
  pass "fm-control relaunch: the retired incarnation's global turn-end token is revoked"
}

test_wiring_removal_failure_refuses_before_replacement_arm() {
  local dir hook out rc real_rm
  dir=$(new_case wiring-failure rl29)
  add_ship_task "$dir" rl29 claude
  hook="$dir/wt/.claude/settings.local.json"
  mkdir -p "${hook%/*}"
  printf '{}\n' > "$hook"
  real_rm=$(command -v rm)
  make_rm_failure_stub "$dir"
  out=$(FM_REAL_RM="$real_rm" FM_FAKE_RM_FAIL_PATH="$hook" \
    run_control "$dir" rl29 relaunch --note "retry after wiring cleanup"); rc=$?
  expect_code 1 "$rc" "an undeletable prior hook must fail closed"$'\n'"$out"
  assert_contains "$out" "could not retire claude wiring" \
    "the failure should identify prior wiring cleanup"
  [ -e "$hook" ] || fail "the fixture should retain the undeletable prior hook"
  assert_no_grep "Firstmate operational input waiting: read" "$dir/fake/literal" \
    "replacement launch must not be armed after wiring cleanup fails"
  [ "$(journal_field "$dir" rl29 phase)" = failed:launching ] \
    || fail "the transaction should record the partial launch failure"
  [ "$(journal_field "$dir" rl29 rollback)" = prior-record-kept ] \
    || fail "unpublished rollback should retain the live durable record"
  pass "fm-control relaunch: wiring cleanup failure refuses replacement arming"
}

test_turnend_auth_paths_are_owned_by_the_control_adapter() {
  local dir state grok_path kimi_path token_path
  dir=$(fm_test_tmproot fm-control-auth)
  state="$dir/state"
  mkdir -p "$state"
  printf 'fm.111111111111\n' > "$state/x.grok-turnend-token"
  printf 'fm.222222222222\n' > "$state/x.kimi-turnend-token"
  token_path=$(fm_control_harness_turnend_token_path grok "$state" x)
  [ "$token_path" = "$state/x.grok-turnend-token" ] \
    || fail "the grok token path should be computed without reading it"
  grok_path=$(GROK_HOME="$dir/gh" fm_control_harness_turnend_auth_path grok fm.111111111111)
  [ "$grok_path" = "$dir/gh/hooks/fm-turn-end.d/fm.111111111111" ] \
    || fail "grok's registry path should resolve under GROK_HOME, got '$grok_path'"
  kimi_path=$(HOME="$dir/kh" fm_control_harness_turnend_auth_path kimi fm.222222222222)
  [ "$kimi_path" = "$dir/kh/.kimi-code/fm-turn-end.d/fm.222222222222" ] \
    || fail "kimi's registry path should resolve under the home store, got '$kimi_path'"
  grok_path=$(GROK_HOME="$dir/gh" fm_control_harness_turnend_auth_path grok 'not a token/../..')
  [ -z "$grok_path" ] || fail "a malformed token must resolve to no path, got '$grok_path'"
  pass "fm-control-lib: one owner resolves each harness's turn-end registry entry, and refuses a malformed token"
}

test_secondmate_relaunch_picks_up_the_configured_harness_pin() {
  local dir home out rc
  dir=$(new_case smpin sm3)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'codex some-model high\n' > "$home/config/secondmate-harness"
  mkdir -p "$home/data/sm3"
  printf '# secondmate brief\n' > "$home/data/sm3/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm3\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm3"
    echo "endpoint_task_id=sm3"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sm3.meta"
  printf '%s\n' "fm-sm3" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sm3 relaunch); rc=$?
  expect_code 0 "$rc" "a configured secondmate harness should relaunch"$'\n'"$out"
  [ "$(journal_field "$dir" sm3 to_harness)" = codex ] \
    || fail "a secondmate relaunch should pick up the configured harness pin, got '$(journal_field "$dir" sm3 to_harness)'"
  [ "$(journal_field "$dir" sm3 to_model)" = some-model ] \
    || fail "the configured model token should come with the pin"
  [ "$(journal_field "$dir" sm3 to_effort)" = high ] \
    || fail "the configured effort token should come with the pin"
  assert_not_contains "$out" "not a verified harness" "codex is a verified harness"
  pass "fm-control relaunch: a secondmate relaunch re-resolves its durable configured harness pin"
}

test_secondmate_relaunch_ignores_invalid_configured_effort_before_stop() {
  local dir home out rc
  dir=$(new_case invalid-effort sm6)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/sm6"
  printf 'codex some-model impossible\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/sm6/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm6\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm6"
    echo "endpoint_task_id=sm6"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sm6.meta"
  printf '%s\n' "fm-sm6" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sm6 relaunch); rc=$?
  expect_code 0 "$rc" "an invalid configured effort should be ignored before stop"$'\n'"$out"
  assert_contains "$out" "effort token 'impossible'" \
    "relaunch should surface the same warning as a normal secondmate spawn"
  [ "$(journal_field "$dir" sm6 to_effort)" = default ] \
    || fail "invalid configured effort should normalize to default"
  pass "fm-control relaunch: invalid configured effort is ignored before stop"
}

# muse is a verified adapter, but only for crewmates and scouts: it has no
# primary supervision protocol, so bin/fm-spawn.sh refuses it for a secondmate.
# That refusal alone is not enough here, because the launch owner is reached
# only AFTER the running agent has been stopped - a secondmate would be left
# with no agent at all. The control plane asks the same capability question
# before it touches anything, so the refusal lands while the agent is still up.
test_secondmate_relaunch_onto_a_crewmate_only_adapter_refuses_before_stop() {
  local dir home out rc
  dir=$(new_case smkind sm7)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/sm7"
  printf '# secondmate brief\n' > "$home/data/sm7/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm7\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm7"
    echo "endpoint_task_id=sm7"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sm7.meta"
  printf '%s\n' "fm-sm7" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  out=$(run_control "$dir" sm7 relaunch --harness muse); rc=$?
  expect_code 1 "$rc" "a crewmate-only adapter should refuse a secondmate relaunch"
  assert_contains "$out" "not verified to run a secondmate task" \
    "the refusal should name the kind the adapter cannot run"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "the refusal must land before the running agent is stopped"
  [ "$(meta_field "$dir" sm7 harness)" = claude ] \
    || fail "a refused relaunch must leave the durable record on the recorded harness"
  pass "fm-control relaunch: an adapter unverified for this task kind refuses before the agent is stopped"
}

test_explicit_secondmate_harness_ignores_configured_profile_axes() {
  local dir home out rc
  dir=$(new_case smexplicit sm4)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude opus high\n' > "$home/config/secondmate-harness"
  mkdir -p "$home/data/sm4"
  printf '# secondmate brief\n' > "$home/data/sm4/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm4\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm4"
    echo "endpoint_task_id=sm4"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=opus"
    echo "effort=high"
    echo "home=$dir/smhome"
  } > "$home/state/sm4.meta"
  printf '%s\n' "fm-sm4" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sm4 relaunch --harness codex); rc=$?
  expect_code 0 "$rc" "an explicit secondmate harness should relaunch"$'\n'"$out"
  [ "$(meta_field "$dir" sm4 model)" = default ] \
    || fail "an explicit secondmate harness must not inherit the configured model"
  [ "$(meta_field "$dir" sm4 effort)" = default ] \
    || fail "an explicit secondmate harness must not inherit the configured effort"
  pass "fm-control relaunch: explicit secondmate harness resets unnamed profile axes"
}

test_ship_relaunch_ignores_the_crew_harness_config() {
  local dir out
  dir=$(new_case crewcfg rl20)
  add_ship_task "$dir" rl20 claude
  mkdir -p "$dir/home/config"
  printf 'codex\n' > "$dir/home/config/crew-harness"
  out=$(run_control "$dir" rl20 relaunch --note "same worker, same runtime")
  assert_contains "$out" "harness=claude from=claude" \
    "a ship relaunch must keep its recorded harness rather than re-reading crew config"
  [ "$(meta_field "$dir" rl20 harness)" = claude ] \
    || fail "a ship relaunch must not silently move onto the configured crew harness"
  pass "fm-control relaunch: a ship task keeps its recorded harness instead of re-reading crew config"
}

test_spawn_relaunch_without_a_harness_reuses_the_recorded_one() {
  local dir out
  dir=$(new_case spawnharness rl21)
  add_ship_task "$dir" rl21 claude
  mkdir -p "$dir/home/config"
  printf 'codex\n' > "$dir/home/config/crew-harness"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl21 --relaunch)
  [ "$(meta_field "$dir" rl21 harness)" = claude ] \
    || fail "fm-spawn --relaunch without --harness must reuse the recorded harness, got '$(meta_field "$dir" rl21 harness)'"
  assert_contains "$out" "spawned rl21 harness=claude" "the launch should report the recorded harness"
  pass "fm-spawn --relaunch: with no explicit harness it reuses the task's recorded one, never the crew default"
}

# A promoted scout records kind=ship and a custom ship branch in its meta, but
# its brief is the scout scaffold: it never gained a Ship branch line, and a
# relaunch cannot regenerate the brief (--branch-prefix is refused there). The
# recorded branch is authoritative, so the relaunch must proceed on it.
test_spawn_relaunch_of_promoted_scout_uses_the_recorded_branch() {
  local dir out
  dir=$(new_case promotebranch rl42)
  add_ship_task "$dir" rl42 claude
  printf 'branch=fix/rl42\n' >> "$dir/home/state/rl42.meta"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl42 --relaunch)
  assert_contains "$out" "spawned rl42" "the relaunch should complete on the recorded branch"
  assert_contains "$out" "records no ship branch" "the brief gap should be reported, not silent"
  assert_contains "$out" "recorded branch fix/rl42" "the relaunch should name the branch it adopted"
  [ "$(meta_field "$dir" rl42 branch)" = "fix/rl42" ] \
    || fail "the recorded branch must survive the relaunch"
  pass "fm-spawn --relaunch: a promoted scout with a recorded custom branch relaunches on it instead of being refused"
}

test_promoted_scout_relaunch_receives_the_current_delivery_contract() {
  local dir home id brief launch out mode rule
  for mode in no-mistakes direct-PR local-only; do
    id="rl-promoted-${mode}"
    dir=$(new_case "promoted-scout-$mode" "$id")
    home="$dir/home"
    fm_git_worktree "$dir/proj" "$dir/wt" "task-$id"
    FM_HOME="$home" "$BRIEF" "$id" firstmate --scout >/dev/null \
      || fail "$mode: could not scaffold the scout brief"
    brief="$home/data/$id/brief.md"
    sed 's/{TASK}/Fix the promotion relaunch contract./; s/{FIRSTMATE_SPEC}/Preserve the current delivery mode./' \
      "$brief" > "$brief.filled"
    mv "$brief.filled" "$brief"
    {
      echo "window=fmses:fm-$id"
      echo "endpoint_task_id=$id"
      echo "worktree=$dir/wt"
      echo "project=$dir/proj"
      echo "harness=claude"
      echo "kind=scout"
      echo "tasktmp=/tmp/fm-$id"
      echo "model=default"
      echo "effort=default"
    } > "$home/state/$id.meta"
    printf '%s\n' "fm-$id" > "$dir/fake/windows"
    printf '%s' "$dir/wt" > "$dir/fake/cwd"

    out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      "$PROMOTE" "$id" --mode "$mode" --yolo off 2>&1) \
      || fail "$mode: scout promotion should succeed: $out"
    assert_grep 'This is a SCOUT task' "$brief" \
      "$mode: the reproduction fixture lost the original scout delivery text"
    assert_grep 'Never push to any remote and never open a PR' "$brief" \
      "$mode: the reproduction fixture lost the stale scout prohibition"

    printf 'zsh' > "$dir/fake/command"
    out=$(run_spawn "$dir" "$id" --relaunch) \
      || fail "$mode: promoted scout relaunch should succeed: $out"
    launch="$home/data/$id/launch-brief.md"
    assert_grep "This task is now kind=ship with mode=$mode" "$launch" \
      "$mode: the replacement launch did not receive the promoted task identity"
    assert_grep 'Any earlier "Never push" or scout-only delivery language in this file is superseded' "$launch" \
      "$mode: the replacement launch left the stale scout prohibition readable at face value"
    case "$mode" in
      direct-PR)
        rule="1. Never push to the default branch (push only your \`fm/$id\` branch). Never merge a PR." ;;
      local-only)
        rule="1. Never push to any remote and never open a PR. Work only on your \`fm/$id\` branch; firstmate handles the merge into local \`main\`." ;;
      *)
        rule='1. Never push to the default branch. Never merge a PR.' ;;
    esac
    assert_grep "$rule" "$launch" \
      "$mode: the replacement launch did not receive the current ship push and merge safety rule"
    assert_grep "git checkout -b fm/$id" "$launch" \
      "$mode: the replacement launch did not receive its promoted branch name"
    assert_grep 'Inventory this worktree' "$launch" \
      "$mode: the replacement launch did not receive the scratch-state inventory step"
    assert_grep 'Carry over only the intended fix changes' "$launch" \
      "$mode: the replacement launch did not receive the carry-over boundary"
    assert_grep "Delivery contract: mode=$mode" "$launch" \
      "$mode: the replacement launch did not receive the actual ship delivery mode"
  done
  pass "fm-promote/fm-spawn --relaunch: the current ship contract supersedes stale scout delivery text"
}

# fm-spawn arms per-task wiring on harness PREFIXES, because a task launched
# from a raw command records that command's basename rather than the exact
# adapter name. Retirement must resolve the same way, or a task recorded as
# `grok-2` would have its turn-end token and hook pointer armed and never
# retired - leaving a registry entry that outlives the agent that owned it.
test_prefixed_prior_harness_wiring_is_still_retired() {
  local dir auth
  dir=$(new_case prefixwiring rl30)
  add_ship_task "$dir" rl30 grok-2
  mkdir -p "$dir/grokhome/hooks/fm-turn-end.d"
  printf 'fm.abcdefabcdef\n' > "$dir/home/state/rl30.grok-turnend-token"
  auth="$dir/grokhome/hooks/fm-turn-end.d/fm.abcdefabcdef"
  printf '%s\n' "$dir/home/state/rl30.turn-ended" > "$auth"
  printf 'token=fm.abcdefabcdef\n' > "$dir/wt/.fm-grok-turnend"
  printf 'zsh' > "$dir/fake/command"
  run_spawn "$dir" rl30 --relaunch --harness claude >/dev/null
  [ ! -e "$auth" ] \
    || fail "a prefixed prior harness must still have its turn-end registry entry revoked"
  [ ! -e "$dir/home/state/rl30.grok-turnend-token" ] \
    || fail "a prefixed prior harness must still have its private token retired"
  [ ! -e "$dir/wt/.fm-grok-turnend" ] \
    || fail "a prefixed prior harness must still have its worktree hook pointer removed"
  pass "fm-spawn --relaunch: wiring armed under a prefixed harness name is still retired"
}

# muse installs no hook; its busy source is its own session event log, bound to
# the pane by two firstmate-owned sidecars. Relaunching AWAY from muse must
# retire that binding, or a retired incarnation's session pin outlives the agent
# that produced it.
test_muse_session_binding_is_retired_on_a_harness_switch() {
  local dir
  dir=$(new_case musewiring rl31)
  add_ship_task "$dir" rl31 muse
  printf 'sessions_root=/nonexistent\nworkspace_root=%s\nbinding_id=1.2.3\n' "$dir/wt" \
    > "$dir/home/state/rl31.muse-session"
  printf '/nonexistent/session.jsonl\n' > "$dir/home/state/rl31.muse-session-current"
  printf 'zsh' > "$dir/fake/command"
  run_spawn "$dir" rl31 --relaunch --harness claude >/dev/null
  [ ! -e "$dir/home/state/rl31.muse-session" ] \
    || fail "the retired muse incarnation's session binding must not outlive it"
  [ ! -e "$dir/home/state/rl31.muse-session-current" ] \
    || fail "the retired muse incarnation's resolved session pin must not outlive it"
  pass "fm-spawn --relaunch: switching away from muse retires its session binding"
}

test_cursor_session_binding_is_retired_on_a_harness_switch() {
  local dir
  dir=$(new_case cursorwiring rl35)
  add_ship_task "$dir" rl35 cursor
  printf 'workspace=%s\nprior_conversation=old-conversation\n' "$dir/wt" \
    > "$dir/home/state/rl35.cursor-session"
  printf 'zsh' > "$dir/fake/command"
  run_spawn "$dir" rl35 --relaunch --harness claude >/dev/null
  [ ! -e "$dir/home/state/rl35.cursor-session" ] \
    || fail "the retired cursor incarnation's session binding must not outlive it"
  pass "fm-spawn --relaunch: switching away from cursor retires its session binding"
}

# --- 3 and 4. refusals before the agent is touched ---------------------------

test_missing_worktree_refuses_before_stopping_anything() {
  local dir out rc
  dir=$(new_case nowt rl10)
  add_ship_task "$dir" rl10 claude
  rm -rf "$dir/wt"
  out=$(run_control "$dir" rl10 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "a missing worktree should refuse"
  assert_contains "$out" "recorded worktree" "the refusal should name the missing local copy"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused relaunch must send nothing"
  pass "fm-control relaunch: an unaccountable local copy refuses before the agent is touched"
}

test_missing_instructions_refuse_before_stopping_anything() {
  local dir out rc
  dir=$(new_case nobrief rl11)
  add_ship_task "$dir" rl11 claude
  rm -f "$dir/home/data/rl11/brief.md"
  out=$(run_control "$dir" rl11 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "missing instructions should refuse"
  assert_contains "$out" "no instructions" "the refusal should name the missing instructions"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: a worker with nothing to work from is never launched"
}

test_checkpoint_refusal_leaves_the_record_byte_identical() {
  local dir before after
  dir=$(new_case bytes rl12)
  add_ship_task "$dir" rl12 claude
  before=$(cat "$dir/home/state/rl12.meta")
  rm -rf "$dir/wt/.git"
  run_control "$dir" rl12 relaunch --note "x" >/dev/null 2>&1
  after=$(cat "$dir/home/state/rl12.meta")
  [ "$before" = "$after" ] || fail "a refused relaunch must leave the durable record byte-identical"
  pass "fm-control relaunch: a refusal before the agent is stopped leaves the durable record untouched"
}

test_checkpoint_refuses_uninspectable_head_and_status() {
  local dir out rc real_git
  real_git=$(command -v git)

  dir=$(new_case badhead rl22)
  add_ship_task "$dir" rl22 claude
  make_git_failure_stub "$dir"
  out=$(FM_REAL_GIT="$real_git" FM_FAKE_GIT_FAILURE=head \
    run_control "$dir" rl22 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "an uninspectable HEAD should refuse"
  assert_contains "$out" "HEAD cannot be inspected" "the refusal should name the failed HEAD proof"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "HEAD inspection failure must not stop the agent"

  dir=$(new_case badstatus rl23)
  add_ship_task "$dir" rl23 claude
  make_git_failure_stub "$dir"
  out=$(FM_REAL_GIT="$real_git" FM_FAKE_GIT_FAILURE=status \
    run_control "$dir" rl23 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "an uninspectable worktree status should refuse"
  assert_contains "$out" "status cannot be inspected" "the refusal should name the failed dirty-state proof"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "status inspection failure must not stop the agent"
  pass "fm-control relaunch: checkpoint inspection failures refuse before stopping"
}

# --- 5. failure after the agent is stopped -----------------------------------

test_launch_failure_keeps_the_prior_record_and_reports_it() {
  local dir out rc before
  dir=$(new_case rollback rl13)
  add_ship_task "$dir" rl13 claude
  before=$(cat "$dir/home/state/rl13.meta")
  # The endpoint's shell is not in the recorded worktree, so the launch owner
  # refuses AFTER the previous agent has already been stopped.
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  out=$(run_control "$dir" rl13 relaunch --harness codex --note "carry this forward"); rc=$?
  expect_code 1 "$rc" "a failed launch should fail closed"$'\n'"$out"
  assert_contains "$out" "no agent is running" "the failure should say no agent is running"
  assert_contains "$out" "$dir/wt" "the failure should say where the work is preserved"
  [ "$(cat "$dir/home/state/rl13.meta")" = "$before" ] \
    || fail "a failed launch must keep the prior durable record"
  [ "$(journal_field "$dir" rl13 phase)" = "failed:launching" ] \
    || fail "the journal should record the failed phase, got '$(journal_field "$dir" rl13 phase)'"
  [ "$(journal_field "$dir" rl13 rollback)" = "prior-record-kept" ] \
    || fail "the journal should record what the rollback did"
  assert_grep "carry this forward" "$dir/home/data/rl13/brief.md" \
    "the progress note must survive so a later recovery still has it"
  pass "fm-control relaunch: a launch failure after the stop keeps the prior record and reports the real state"
}

test_prepublication_failure_keeps_concurrent_durable_metadata() {
  local dir control_pid link_pid link_out rc deadline
  dir=$(new_case rollback-race rl30)
  add_ship_task "$dir" rl30 claude
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  FM_FAKE_CWD_RACE_READY="$dir/cwd-race-ready" \
    FM_FAKE_CWD_RACE_RELEASE="$dir/cwd-race-release" \
    run_control "$dir" rl30 relaunch --harness codex --note "preserve concurrent metadata" \
      > "$dir/control.out" &
  control_pid=$!
  deadline=$((SECONDS + FM_TEST_STUB_MAX_BLOCK_SECONDS))
  while [ ! -e "$dir/cwd-race-ready" ] && [ "$SECONDS" -lt "$deadline" ] && kill -0 "$control_pid" 2>/dev/null; do
    /bin/sleep 0.05
  done
  [ -e "$dir/cwd-race-ready" ] || {
    : > "$dir/cwd-race-release"
    kill "$control_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "relaunch did not reach its pre-publication endpoint check: $(cat "$dir/control.out")"
  }
  # The publisher can finish only after spawn releases its metadata lock.
  # Start it concurrently, then release spawn before waiting for publication.
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    "$X_LINK" rl30 request-30 --carry-count 2 --carry-ts 1700000000 \
      --carry-platform x --carry-max 280 > "$dir/link.out" 2>&1 &
  link_pid=$!
  : > "$dir/cwd-race-release"
  wait "$link_pid"; rc=$?
  link_out=$(cat "$dir/link.out")
  expect_code 0 "$rc" "concurrent durable metadata publication should succeed"$'\n'"$link_out"
  wait "$control_pid"; rc=$?
  expect_code 1 "$rc" "the staged pre-publication launch failure should fail closed"
  assert_absent "$dir/cwd-race-ready.expired" \
    "the concurrent metadata race must finish by release, not by fixture timeout"
  [ "$(meta_field "$dir" rl30 x_request)" = request-30 ] \
    || fail "rollback erased the concurrent X request"
  [ "$(meta_field "$dir" rl30 x_followups)" = 2 ] \
    || fail "rollback erased the concurrent follow-up count"
  [ "$(journal_field "$dir" rl30 rollback)" = prior-record-kept ] \
    || fail "pre-publication rollback should leave the live record untouched"
  pass "fm-control relaunch: unpublished rollback keeps concurrent durable metadata"
}

test_post_publication_launch_failure_keeps_the_new_record() {
  local dir out rc
  dir=$(new_case published rl24)
  add_ship_task "$dir" rl24 claude
  printf 'codex' > "$dir/fake/becomes"
  out=$(FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START=1 \
    run_control "$dir" rl24 relaunch --harness codex --note "keep the published record"); rc=$?
  expect_code 1 "$rc" "a post-publication launch failure should fail closed"$'\n'"$out"
  [ "$(meta_field "$dir" rl24 harness)" = codex ] \
    || fail "a published replacement record must not be rewritten to the prior harness"
  [ -n "$(meta_field "$dir" rl24 control_relaunch_tx)" ] \
    || fail "the published replacement record should identify its relaunch transaction"
  [ "$(journal_field "$dir" rl24 rollback)" = none-new-record-kept ] \
    || fail "the journal should record that the published replacement record was kept"
  pass "fm-control relaunch: post-publication failure keeps the new durable record"
}

test_stop_transport_failure_reconciles_a_dead_agent() {
  local dir out rc
  dir=$(new_case stopfail rl25)
  add_ship_task "$dir" rl25 claude
  out=$(FM_FAKE_EXIT_TRANSPORT_FAIL_AFTER_STOP=1 \
    run_control "$dir" rl25 relaunch --note "preserve this after stop"); rc=$?
  expect_code 1 "$rc" "a stop transport failure should fail closed"$'\n'"$out"
  [ "$(cat "$dir/fake/command")" = zsh ] || fail "the fixture should stop the old agent before reporting transport failure"
  [ "$(journal_field "$dir" rl25 phase)" = failed:stopping ] \
    || fail "the journal should retain the pre-stop phase on a partial stop"
  [ "$(journal_field "$dir" rl25 rollback)" = prior-record-kept-agent-dead ] \
    || fail "rollback should reconcile the observed dead agent"
  assert_contains "$out" "no agent is running" "the failure should report the reconciled dead state"
  assert_grep "preserve this after stop" "$dir/home/data/rl25/brief.md" \
    "the progress note should survive once the old agent has stopped"
  pass "fm-control relaunch: partial stop reconciles actual agent state"
}

test_complete_journal_failure_rolls_back_from_durable_phase() {
  local dir out rc real_mv
  dir=$(new_case completejournal rl27)
  add_ship_task "$dir" rl27 claude
  printf 'codex' > "$dir/fake/becomes"
  real_mv=$(command -v mv)
  make_mv_failure_stub "$dir"
  out=$(FM_REAL_MV="$real_mv" FM_FAKE_COMPLETE_JOURNAL_MV_FAIL=1 \
    run_control "$dir" rl27 relaunch --harness codex --note "keep durable phase honest"); rc=$?
  expect_code 1 "$rc" "a failed complete journal replacement should fail closed"$'\n'"$out"
  [ "$(journal_field "$dir" rl27 phase)" = failed:launching ] \
    || fail "rollback should start from the last durable launching phase"
  [ "$(journal_field "$dir" rl27 rollback)" = none-new-agent-confirmed ] \
    || fail "rollback should retain the confirmed-running replacement"
  [ "$(meta_field "$dir" rl27 harness)" = codex ] \
    || fail "journal failure must not rewrite the published replacement record"
  assert_contains "$out" "replacement is running" \
    "journal failure should report the confirmed-running replacement"
  assert_not_contains "$out" "no running agent could be confirmed" \
    "journal failure should not contradict the confirmed agent state"
  pass "fm-control relaunch: failed journal replacement preserves durable phase"
}

test_prepublication_abort_retires_replacement_wiring_and_busy_state() {
  local dir out rc real_mv meta
  dir=$(new_case prepublishcleanup rl28)
  add_ship_task "$dir" rl28 claude
  meta="$dir/home/state/rl28.meta"
  real_mv=$(command -v mv)
  make_mv_failure_stub "$dir"
  out=$(FM_REAL_MV="$real_mv" FM_FAKE_META_PUBLISH_MV_FAIL="$meta" \
    run_control "$dir" rl28 relaunch --note "clean partial replacement state"); rc=$?
  expect_code 1 "$rc" "a failed metadata publication should fail closed"$'\n'"$out"
  [ "$(meta_field "$dir" rl28 harness)" = claude ] \
    || fail "a failed publication should retain the prior durable record"
  [ ! -e "$dir/wt/.claude/settings.local.json" ] \
    || fail "an aborted replacement should remove its harness wiring"
  [ ! -e "$dir/home/state/rl28.busy-gen" ] \
    || fail "an aborted replacement should retire its busy generation"
  [ ! -e "$dir/home/state/rl28.busy-state" ] \
    || fail "an aborted replacement should remove its seeded busy record"
  [ "$(journal_field "$dir" rl28 rollback)" = prior-record-kept ] \
    || fail "the journal should record the unpublished replacement rollback"
  pass "fm-spawn relaunch: prepublication abort removes replacement state"
}

test_journal_records_the_checkpoint_it_proved() {
  local dir head
  dir=$(new_case journal rl14)
  add_ship_task "$dir" rl14 claude
  printf 'scratch\n' > "$dir/wt/uncommitted.txt"
  head=$(git -C "$dir/wt" rev-parse HEAD)
  run_control "$dir" rl14 relaunch --note "keeping the scratch file" >/dev/null
  [ "$(journal_field "$dir" rl14 worktree_head)" = "$head" ] \
    || fail "the checkpoint should record the head it preserved"
  [ "$(journal_field "$dir" rl14 worktree_dirty)" = yes ] \
    || fail "the checkpoint should record that uncommitted work was present"
  [ -f "$dir/wt/uncommitted.txt" ] || fail "uncommitted work must survive a relaunch"
  pass "fm-control relaunch: the checkpoint records the exact unlanded work it preserved"
}

# --- secondmate child-work safety -------------------------------------------

test_secondmate_relaunch_checkpoints_child_work_and_spares_the_charter() {
  local dir home out rc
  dir=$(new_case sm sm1)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude\n' > "$home/config/secondmate-harness"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm1\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# charter\n' > "$dir/smhome/data/charter.md"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  printf 'window=x:fm-c1\n' > "$dir/smhome/state/c1.meta"
  printf 'window=x:fm-c2\n' > "$dir/smhome/state/c2.meta"
  {
    echo "window=fmses:fm-sm1"
    echo "endpoint_task_id=sm1"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
    echo "projects="
  } > "$home/state/sm1.meta"
  printf '%s\n' "fm-sm1" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  # No --note: a secondmate reconciles its own home's records at startup, so
  # the note is optional there.
  out=$(run_control "$dir" sm1 relaunch); rc=$?
  expect_code 0 "$rc" "a checkpointed secondmate should relaunch"$'\n'"$out"
  [ "$(journal_field "$dir" sm1 children)" = 2 ] \
    || fail "the checkpoint must account for the secondmate's child work, got '$(journal_field "$dir" sm1 children)'"
  assert_not_contains "$out" "requires --note" "a secondmate relaunch must not demand a progress note"
  [ "$(cat "$dir/smhome/data/charter.md")" = "# charter" ] \
    || fail "a secondmate's standing charter must never be rewritten by a relaunch"
  assert_present "$dir/smhome/state/c1.meta" "child records must survive the relaunch"
  assert_present "$dir/smhome/state/c2.meta" "child records must survive the relaunch"
  pass "fm-control relaunch: a secondmate's child work is accounted for and its charter is left alone"
}

test_default_secondmate_relaunch_survives_unsafe_routing_sources() {
  local dir home source_kind out rc
  for source_kind in dangling directory; do
    dir=$(new_case "default-routing-$source_kind" sm-default)
    home="$dir/home"
    mkdir -p "$home/config"
    printf 'claude\n' > "$home/config/secondmate-harness"
    printf 'codex\n' > "$home/config/crew-harness"
    case "$source_kind" in
      dangling) ln -s "$home/missing-index" "$home/config/model-index.json" ;;
      directory) mkdir "$home/config/crew-dispatch.json" ;;
    esac
    fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
    mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/config" "$dir/smhome/bin"
    printf 'sm-default\n' > "$dir/smhome/.fm-secondmate-home"
    printf '# charter\n' > "$dir/smhome/data/charter.md"
    printf '# agents\n' > "$dir/smhome/AGENTS.md"
    printf 'config/\n' > "$dir/smhome/.gitignore"
    {
      printf 'window=fmses:fm-sm-default\nendpoint_task_id=sm-default\n'
      printf 'worktree=%s\nproject=%s\nhome=%s\n' "$dir/smhome" "$dir/smhome" "$dir/smhome"
      printf 'harness=claude\nkind=secondmate\nmode=secondmate\nyolo=off\nmodel=default\neffort=default\n'
    } > "$home/state/sm-default.meta"
    printf 'fm-sm-default\n' > "$dir/fake/windows"
    printf '%s' "$dir/smhome" > "$dir/fake/cwd"
    out=$(run_control "$dir" sm-default relaunch); rc=$?
    expect_code 0 "$rc" "default secondmate relaunch must survive $source_kind routing source"$'\n'"$out"
    [ "$(cat "$dir/fake/command")" = claude ] || fail 'default-model replacement left no running agent'
    [ "$(journal_field "$dir" sm-default phase)" = complete ] || fail 'default-model replacement did not complete'
    [ "$(meta_field "$dir" sm-default model)" = default ] || fail 'default-model replacement changed model selection'
    [ "$(cat "$dir/smhome/config/crew-harness")" = codex ] || fail 'routing refusal blocked unrelated inheritance'
    assert_contains "$out" 'inheritance failed' 'unsafe routing source must remain a warning'
  done
  pass 'default-model secondmate replacements keep warning-only routing inheritance'
}

test_secondmate_relaunch_refuses_an_unmarked_home() {
  local dir home out rc
  dir=$(new_case smbad sm2)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude\n' > "$home/config/secondmate-harness"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state"
  printf 'someone-else\n' > "$dir/smhome/.fm-secondmate-home"
  {
    echo "window=fmses:fm-sm2"
    echo "endpoint_task_id=sm2"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
  } > "$home/state/sm2.meta"
  printf '%s\n' "fm-sm2" > "$dir/fake/windows"
  out=$(run_control "$dir" sm2 relaunch); rc=$?
  expect_code 1 "$rc" "a home marked for another secondmate should refuse"
  assert_contains "$out" "not marked as its own seeded secondmate home" \
    "the refusal should name the identity mismatch"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: a secondmate home that is not this secondmate's is refused"
}

test_secondmate_checkpoint_refuses_unreadable_child_state() {
  local dir home out rc
  dir=$(new_case smchildren sm5)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude\n' > "$home/config/secondmate-harness"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state/bad.meta"
  printf 'sm5\n' > "$dir/smhome/.fm-secondmate-home"
  {
    echo "window=fmses:fm-sm5"
    echo "endpoint_task_id=sm5"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "home=$dir/smhome"
  } > "$home/state/sm5.meta"
  printf '%s\n' "fm-sm5" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  out=$(run_control "$dir" sm5 relaunch); rc=$?
  expect_code 1 "$rc" "a non-readable child record should refuse"
  assert_contains "$out" "not a readable regular file" "the refusal should name the unreadable child record"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "child record failure must not stop the secondmate"
  pass "fm-control relaunch: unreadable child records fail checkpoint"
  if [ "$(id -u)" = 0 ]; then
    pass "fm-control relaunch: unlistable state check skipped as root (mode 000 does not restrict root)"
    return 0
  fi
  rmdir "$dir/smhome/state/bad.meta"
  printf 'window=x:c1\n' > "$dir/smhome/state/c1.meta"
  chmod 000 "$dir/smhome/state"
  out=$(run_control "$dir" sm5 relaunch); rc=$?
  chmod 755 "$dir/smhome/state"
  expect_code 1 "$rc" "an unlistable state directory should refuse"
  assert_contains "$out" "no readable state directory" \
    "the refusal should name the unlistable home state directory"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "unlistable child state must not stop the secondmate"
  pass "fm-control relaunch: unlistable state fails checkpoint"
}

test_secondmate_checkpoint_ignores_a_vanished_scratch_find_walk() {
  local dir home out rc real_find
  dir=$(new_case smfindrace sm6)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude\n' > "$home/config/secondmate-harness"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm6\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# charter\n' > "$dir/smhome/data/charter.md"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  printf 'window=x:fm-c1\n' > "$dir/smhome/state/c1.meta"
  printf 'window=x:fm-c2\n' > "$dir/smhome/state/c2.meta"
  : > "$dir/smhome/state/.hash-0"
  : > "$dir/smhome/state/.count-0"
  : > "$dir/smhome/state/.last-0"
  {
    echo "window=fmses:fm-sm6"
    echo "endpoint_task_id=sm6"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
    echo "projects="
  } > "$home/state/sm6.meta"
  printf '%s\n' "fm-sm6" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  real_find=$(command -v find)
  cat > "$dir/fakebin/find" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = "$dir/smhome/state" ]; then
    echo "find: \$arg/.hash-0: No such file or directory" >&2
    exit 1
  fi
done
exec "$real_find" "\$@"
SH
  chmod +x "$dir/fakebin/find"
  out=$(run_control "$dir" sm6 relaunch); rc=$?
  expect_code 0 "$rc" "a vanished watcher scratch file must not refuse relaunch"$'\n'"$out"
  assert_contains "$out" "relaunched sm6" "readable child metas must still allow the replacement launch"
  [ "$(journal_field "$dir" sm6 children)" = 2 ] \
    || fail "readable child metas must still be counted, got '$(journal_field "$dir" sm6 children)'"
  pass "fm-control relaunch: a vanished watcher scratch file does not fail the child-record checkpoint"
}

test_concurrent_relaunch_is_refused() {
  local dir out rc lock holder ready i
  dir=$(new_case lock rl19)
  add_ship_task "$dir" rl19 claude
  lock="$dir/home/state/.control-rl19.lock"
  ready="$dir/control-lock-ready"
  # A live holder of this task's control lock, taken through the same lock
  # library fm-control uses.
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    : > "$ready"
    sleep 30
  ) &
  holder=$!
  i=0
  while [ ! -e "$ready" ] && [ "$i" -lt 100 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$ready" ] || { kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true; fail "could not stage a held control lock"; }
  out=$(run_control "$dir" rl19 relaunch --note "concurrent"); rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 1 "$rc" "a second concurrent control action should refuse"
  assert_contains "$out" "another lifecycle action is already running" \
    "the refusal should name the concurrent action"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a refused concurrent relaunch must not stop the agent"
  pass "fm-control relaunch: two control actions on one task serialize instead of interleaving"
}

# shellcheck disable=SC2031
test_direct_spawn_relaunch_participates_in_the_lifecycle_lock() {
  local dir out rc lock holder ready i=0
  dir=$(new_case spawnlock rl26)
  add_ship_task "$dir" rl26 claude
  printf 'zsh' > "$dir/fake/command"
  lock="$dir/home/state/.control-rl26.lock"
  ready="$dir/spawn-lock-ready"
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    : > "$ready"
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$ready" ] && [ "$i" -lt 100 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$ready" ] || { kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true; fail "could not stage the lifecycle lock"; }
  out=$(run_spawn "$dir" rl26 --relaunch --harness claude); rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 1 "$rc" "direct relaunch spawn should refuse a held lifecycle lock"
  assert_contains "$out" "another lifecycle action is already running" \
    "direct relaunch spawn should name lifecycle contention"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "contended direct relaunch spawn must deliver no launch bytes"
  pass "fm-spawn relaunch: direct entry participates in lifecycle serialization"
}

# shellcheck disable=SC2031
test_promotion_participates_in_the_lifecycle_lock_before_metadata_resolution() {
  local dir out rc lock holder ready i=0
  dir=$(new_case promotelock rl29)
  add_ship_task "$dir" rl29 claude
  lock="$dir/home/state/.control-rl29.lock"
  ready="$dir/promotion-lock-ready"
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    : > "$ready"
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$ready" ] && [ "$i" -lt 100 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$ready" ] || { kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true; fail "could not stage the promotion lifecycle lock"; }
  out=$(FM_HOME="$dir/home" "$PROMOTE" rl29 --mode direct-PR --yolo on 2>&1); rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 1 "$rc" "promotion should refuse a concurrent lifecycle action"
  assert_contains "$out" "another lifecycle action is already running" \
    "promotion should lock before interpreting the task metadata"
  [ "$(meta_field "$dir" rl29 kind)" = ship ] \
    || fail "a contended promotion must leave task metadata unchanged"
  pass "fm-promote: promotion participates in lifecycle serialization"
}

# --- 6. fm-spawn --relaunch's own refusals -----------------------------------

test_spawn_relaunch_refuses_a_live_agent() {
  local dir out rc
  dir=$(new_case live rl15)
  add_ship_task "$dir" rl15 claude
  out=$(run_spawn "$dir" rl15 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "relaunching into a live endpoint should refuse"
  assert_contains "$out" "positively agent-free endpoint" "the refusal should demand an agent-free endpoint"
  assert_contains "$out" "fm-control.sh rl15 exit" "the refusal should point at the way to stop it"
  pass "fm-spawn --relaunch: refuses to launch a second agent into a live endpoint"
}

test_spawn_relaunch_refuses_a_symlinked_task_record_before_inspection() {
  local dir meta target out rc
  dir=$(new_case symlink-meta rl37)
  add_ship_task "$dir" rl37 claude
  meta="$dir/home/state/rl37.meta"
  target="$dir/foreign-task-record"
  mv "$meta" "$target"
  ln -s "$target" "$meta"
  mv "$dir/fakebin/tmux" "$dir/fakebin/tmux-real"
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
: > "$dir/relaunch-endpoint-inspected"
exec "$dir/fakebin/tmux-real" "\$@"
SH
  chmod +x "$dir/fakebin/tmux"

  out=$(run_spawn "$dir" rl37 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "relaunching from symlinked metadata should refuse"
  assert_contains "$out" "task record resolves outside its authorized directory" \
    "relaunch did not identify the unsafe task record"
  [ -L "$meta" ] || fail "relaunch replaced or removed the symlinked record"
  assert_present "$target" "relaunch removed the foreign record target"
  assert_absent "$dir/relaunch-endpoint-inspected" \
    "relaunch inspected or acted on an endpoint from unsafe metadata"
  pass "fm-spawn --relaunch: symlinked records refuse before inspection"
}

test_spawn_relaunch_keeps_its_early_meta_lock_continuous() {
  local dir lock out rc
  dir=$(new_case continuous-meta-lock rl38)
  add_ship_task "$dir" rl38 claude
  printf 'zsh' > "$dir/fake/command"
  lock="$dir/home/state/.meta-rl38.lock"
  mv "$dir/fakebin/tmux" "$dir/fakebin/tmux-real"
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
if [ -d "$lock" ]; then
  if [ ! -e "$dir/lock-observation-started" ]; then
    : > "$dir/lock-observation-started"
    : > "$lock/continuity-sentinel"
  elif [ ! -e "$lock/continuity-sentinel" ]; then
    : > "$dir/meta-lock-was-recreated"
  fi
fi
exec "$dir/fakebin/tmux-real" "\$@"
SH
  chmod +x "$dir/fakebin/tmux"

  out=$(run_spawn "$dir" rl38 --relaunch --harness claude); rc=$?
  expect_code 0 "$rc" "relaunch with one continuous meta lock should succeed"$'\n'"$out"
  assert_present "$dir/lock-observation-started" \
    "test did not observe the relaunch-held meta lock"
  assert_absent "$dir/meta-lock-was-recreated" \
    "relaunch released or recreated its already-held meta lock"
  pass "fm-spawn --relaunch: keeps its early meta lock continuous"
}

test_spawn_relaunch_refuses_a_pending_authoritative_close() {
  local dir meta marker out rc
  dir=$(new_case pending-close rl36)
  add_ship_task "$dir" rl36 claude
  meta="$dir/home/state/rl36.meta"
  printf 'spawn_gen=spawn-pending\n' >> "$meta"
  cp "$meta" "$dir/meta.before"
  mkdir -p "$dir/wt/.claude"
  printf 'prior wiring\n' > "$dir/wt/.claude/settings.local.json"
  marker="$dir/home/state/rl36.backlog-close"
  printf 'id=rl36\ndata=%s\nspawn_gen=spawn-pending\narg=--note\narg=local%%20main\n' \
    "$dir/home/data" > "$marker"
  printf 'zsh' > "$dir/fake/command"

  out=$(run_spawn "$dir" rl36 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "relaunching over a pending close should refuse"
  assert_contains "$out" "pending authoritative backlog close" \
    "the refusal should identify the close that still owns the task"
  cmp -s "$dir/meta.before" "$meta" \
    || fail "pending-close refusal replaced the task incarnation"
  assert_grep 'prior wiring' "$dir/wt/.claude/settings.local.json" \
    "pending-close refusal cleared the prior worker wiring"
  assert_present "$marker" "pending-close refusal discarded the authoritative close"
  pass "fm-spawn --relaunch: pending closes refuse before replacement begins"
}

test_spawn_relaunch_refuses_contradicting_flags() {
  local dir out rc
  dir=$(new_case flags rl16)
  add_ship_task "$dir" rl16 claude
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl16 --relaunch --backend herdr); rc=$?
  expect_code 1 "$rc" "--backend should be refused alongside --relaunch"
  assert_contains "$out" "recorded backend" "the refusal should name the recorded backend rule"
  out=$(run_spawn "$dir" rl16 --relaunch --scout); rc=$?
  expect_code 1 "$rc" "--scout should be refused alongside --relaunch"
  assert_contains "$out" "recorded kind" "the refusal should name the recorded kind rule"
  out=$(run_spawn "$dir" rl16 "$dir/proj" --relaunch); rc=$?
  expect_code 1 "$rc" "a project positional should be refused alongside --relaunch"
  assert_contains "$out" "takes the task id only" "the refusal should name the positional rule"
  pass "fm-spawn --relaunch: every identity axis comes from the record, and a contradicting flag refuses"
}

test_spawn_relaunch_refuses_an_unrecorded_task() {
  local dir out rc
  dir=$(new_case norecord rl17)
  add_ship_task "$dir" rl17 claude
  out=$(run_spawn "$dir" nosuchtask --relaunch); rc=$?
  expect_code 1 "$rc" "an unrecorded task should refuse"
  assert_contains "$out" "needs an existing task record" "the refusal should name the missing record"
  pass "fm-spawn --relaunch: an unrecorded task is refused"
}

test_spawn_relaunch_refuses_a_pane_outside_the_worktree() {
  local dir out rc
  dir=$(new_case wrongcwd rl18)
  add_ship_task "$dir" rl18 claude
  printf 'zsh' > "$dir/fake/command"
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  out=$(run_spawn "$dir" rl18 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "a pane outside the worktree should refuse"
  assert_contains "$out" "not its recorded worktree" "the refusal should name the wrong location"
  [ ! -s "$dir/fake/keys" ] || fail "a refused tmux relaunch must send nothing to the pane"
  pass "fm-spawn --relaunch: refuses to start a replacement outside the copy holding its work"
}

# --- 7. reclaiming a task whose endpoint is gone ----------------------------
#
# Before this, `missing` was a terminal state: fm-spawn --relaunch accepted only
# `dead` and told the caller to stop the agent first, while fm-control exit
# refused `missing` outright and told the caller to reconcile the task first -
# and there is no reconcile verb. Each command named the other as its
# prerequisite, so a task whose pane or workspace was destroyed could not be
# reclaimed by anything, and any no-mistakes approval it was parked on had no
# seat left to answer it.

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

# (a) The recorded endpoint is gone while unrelated tmux servers keep running:
# the lsof fixture always lists unrelated processes, and a user's unrelated
# servers can never be shown absent, so none of them may block this task.
test_tmux_gone_endpoint_is_proven_despite_unrelated_servers() {
  local dir shape id out rc wt head_before
  command -v jq >/dev/null 2>&1 || { echo 'skip - configured Herdr reclaim needs jq'; return; }
  for shape in window-absent session-missing server-dead shell-in-worktree; do
    id="rl90${shape//-/}"
    dir=$(new_case "tmux-scoped-$shape" "$id")
    wt="$dir/wt-café\\lane"
    add_ship_task "$dir" "$id" claude fmses "$wt"
    prepare_herdr_reclaim "$dir"
    if [ "$shape" = shell-in-worktree ]; then
      # An idle shell in the copy is the pane's own leftover, not an agent.
      stage_gone "$dir" "$id" window-absent
      stage_holder "$dir" zsh -zsh "$wt/sub"
    else
      stage_gone "$dir" "$id" "$shape"
    fi
    head_before=$(git -C "$wt" rev-parse HEAD)
    printf 'unlanded content\n' > "$wt/dirty.txt"
    printf 'working: preserved history\n' > "$dir/home/state/$id.status"

    mkdir -p "$wt/sub"
    out=$(cd "$wt/sub" && run_control "$dir" "$id" exit); rc=$?
    expect_code 0 "$rc" "a gone recorded endpoint must be proven despite unrelated tmux servers ($shape)"$'\n'"$out"
    assert_contains "$out" endpoint-gone "exit should report proven absence ($shape)"
    rm -f "$dir/fake/list-count"
    out=$(cd "$wt" && FM_FAKE_SESSION=fmlab run_control "$dir" "$id" relaunch --note "resume after reboot"); rc=$?
    expect_code 0 "$rc" "relaunch must proceed for a gone recorded endpoint ($shape)"$'\n'"$out"
    [ "$(meta_field "$dir" "$id" backend)" = herdr ] || fail "reclaim did not publish Herdr ($shape)"
    [ "$(meta_field "$dir" "$id" worktree)" = "$wt" ] || fail "reclaim changed the local copy ($shape)"
    [ "$(git -C "$wt" rev-parse HEAD)" = "$head_before" ] || fail "reclaim moved the branch head ($shape)"
    [ "$(cat "$wt/dirty.txt")" = "unlanded content" ] || fail "reclaim lost uncommitted work ($shape)"
    assert_contains "$(cat "$dir/home/state/$id.status")" "preserved history" "reclaim truncated status ($shape)"
    assert_absent "$dir/fake/created-windows" "reclaim created a tmux endpoint ($shape)"
    assert_absent "$dir/fake/created-sessions" "reclaim started a tmux server ($shape)"
    assert_present "$dir/fake/herdr-created-tabs" "reclaim did not create the Herdr endpoint ($shape)"
  done
  pass "tmux: a gone recorded endpoint is proven and reclaimed while unrelated tmux servers run"
}

# Keep the real process snapshot: a canned lsof table cannot expose a vanished
# command-substitution shell inheriting the recovery caller's working directory.
test_tmux_worktree_local_recovery_with_real_lsof() {
  local dir id entry location wt out rc head_before
  command -v lsof >/dev/null 2>&1 || { echo 'skip - worktree-local recovery needs lsof'; return; }
  command -v jq >/dev/null 2>&1 || { echo 'skip - configured Herdr reclaim needs jq'; return; }
  for entry in relaunch reconcile-only direct; do
    if [ "$entry" = reconcile-only ] && ! fm_tasks_axi_compatible; then
      echo 'skip - reconciliation-only recovery needs compatible tasks-axi'
      continue
    fi
    for location in root descendant; do
      id="rlprobe-$entry-$location"
      dir=$(new_case "$id" "$id")
      wt="$dir/wt-café\\lane"
      add_ship_task "$dir" "$id" claude fmses "$wt"
      stage_gone "$dir" "$id" window-absent
      prepare_herdr_reclaim "$dir"
      rm "$dir/fakebin/lsof"
      mkdir -p "$wt/sub"
      head_before=$(git -C "$wt" rev-parse HEAD)
      printf 'unlanded content\n' > "$wt/dirty.txt"
      [ "$entry" != reconcile-only ] || seed_backlog "$dir" "$id" in_flight
      [ "$location" != descendant ] || wt="$wt/sub"

      out=$(cd "$wt" && run_control "$dir" "$id" exit); rc=$?
      expect_code 0 "$rc" "real lsof must prove exit from the worktree $location"$'\n'"$out"
      assert_contains "$out" endpoint-gone "exit must prove the recorded endpoint gone"
      case "$entry" in
        relaunch)
          out=$(cd "$wt" && FM_FAKE_SESSION=fmlab run_control "$dir" "$id" relaunch --note "resume after reboot"); rc=$?
          ;;
        reconcile-only)
          out=$(cd "$wt" && FM_FAKE_SESSION=fmlab run_control "$dir" "$id" relaunch --reconcile-only --note "restore instruction owner"); rc=$?
          ;;
        direct)
          out=$(cd "$wt" && HERDR_SESSION=fmlab run_spawn "$dir" "$id" --relaunch --harness claude); rc=$?
          ;;
      esac
      expect_code 0 "$rc" "real lsof must permit $entry from the worktree $location"$'\n'"$out"
      wt=$(meta_field "$dir" "$id" worktree)
      [ "$(meta_field "$dir" "$id" backend)" = herdr ] || fail "$entry did not reclaim on Herdr"
      [ "$(git -C "$wt" rev-parse HEAD)" = "$head_before" ] || fail "$entry moved the branch head"
      [ "$(cat "$wt/dirty.txt")" = "unlanded content" ] || fail "$entry lost uncommitted work"
      if [ "$entry" = reconcile-only ]; then
        [ "$(meta_field "$dir" "$id" recovery)" = reconcile-only ] || fail "recovery lost its reconciliation-only scope"
        [ "$(backlog_state "$dir" "$id")" = in_flight ] || fail "recovery changed the backlog state"
      fi
      assert_present "$dir/fake/herdr-created-tabs" "$entry did not create the replacement endpoint"
      assert_absent "$dir/fake/created-windows" "$entry created a tmux endpoint"
    done
  done
  pass "tmux: real lsof permits worktree-local exit, relaunch, reconciliation and direct replacement"
}

# (b) The recorded endpoint may still be live: the window answers, or an agent
# still holds the worktree (its window can sit on a socket this process does
# not address). Either refuses both verbs.
test_tmux_refuses_while_the_recorded_endpoint_may_be_live() {
  local dir shape id wt
  for shape in window-answers-first window-answers-second agent-in-worktree agent-in-subdirectory gemini-agent-in-worktree gemini-spaced-script-in-worktree; do
    id="rl91${shape//-/}"
    dir=$(new_case "tmux-live-$shape-café\\lane" "$id")
    add_ship_task "$dir" "$id"
    stage_gone "$dir" "$id" window-absent
    wt=$(meta_field "$dir" "$id" worktree)
    case "$shape" in
      window-answers-first) printf 'fm-%s\n' "$id" > "$dir/fake/late-window"; printf 1 > "$dir/fake/late-window-after" ;;
      window-answers-second) printf 'fm-%s\n' "$id" > "$dir/fake/late-window"; printf 2 > "$dir/fake/late-window-after" ;;
      agent-in-worktree) stage_holder "$dir" /usr/local/bin/claude 'claude --resume' "$wt" ;;
      agent-in-subdirectory) stage_holder "$dir" claude claude "$wt/src/deep" ;;
      gemini-agent-in-worktree) stage_holder "$dir" MainThread 'node /home/u/.local/bin/gemini -y' "$wt" ;;
      gemini-spaced-script-in-worktree) stage_holder "$dir" MainThread 'node /Users/person/path with spaces/bin/gemini -y' "$wt" ;;
    esac
    assert_tmux_missing_refuses "$dir" "$id" "$shape"
  done
  pass "tmux: an answering window or an agent holding the worktree refuses both verbs"
}

# (c) Evidence that cannot be read is never evidence of absence.
test_tmux_unreadable_evidence_refuses() {
  local dir shape id wt
  for shape in lsof-fails lsof-partial lsof-record-without-cwd lsof-cwd-error lsof-empty-cwd lsof-relative-cwd lsof-blind holder-unreadable holder-unattributed holder-identity-disagrees inventory-unreadable-first inventory-unreadable-second; do
    id="rl92${shape//-/}"
    dir=$(new_case "tmux-unreadable-$shape" "$id")
    add_ship_task "$dir" "$id"
    stage_gone "$dir" "$id" window-absent
    wt=$(meta_field "$dir" "$id" worktree)
    case "$shape" in
      lsof-fails) printf broken > "$dir/fake/lsof-mode" ;;
      lsof-partial) printf partial > "$dir/fake/lsof-mode" ;;
      lsof-record-without-cwd) stage_holder "$dir" claude claude "$wt"; printf nocwd > "$dir/fake/lsof-mode" ;;
      lsof-cwd-error) stage_holder "$dir" claude claude 'cwd|rtd info error: Permission denied' ;;
      lsof-empty-cwd) stage_holder "$dir" claude claude '' ;;
      lsof-relative-cwd) stage_holder "$dir" claude claude 'relative/directory' ;;
      lsof-blind) printf empty > "$dir/fake/lsof-mode" ;;
      holder-unreadable)
        # A live holder (this very shell) whose name and command line cannot be read.
        stage_holder "$dir" '' '' "$wt"
        printf '%s' "$$" > "$dir/fake/holder-pid"
        ;;
      holder-unattributed) stage_holder "$dir" node 'node /Users/person/project/server.js' "$wt" ;;
      holder-identity-disagrees) stage_holder "$dir" bash 'node /Users/person/project/server.js' "$wt/src/deep" ;;
      inventory-unreadable-first) printf 1 > "$dir/fake/broken-after" ;;
      inventory-unreadable-second) printf 2 > "$dir/fake/broken-after" ;;
    esac
    assert_tmux_missing_refuses "$dir" "$id" "$shape"
  done
  pass "tmux: an unreadable process table or tmux answer refuses both verbs"
}

test_tmux_no_server_reclaim_keeps_work_and_task() {
  local dir second out rc head_before mode id wt first_id second_id first_endpoint
  command -v jq >/dev/null 2>&1 || { echo 'skip - configured Herdr reclaim needs jq'; return; }
  for mode in server-dead session-missing; do
    first_id="rl82${mode}a"
    second_id="rl82${mode}b"
    dir=$(new_case "tmux-sequential-reclaim-$mode" "$first_id")
    second=$(new_case "tmux-second-$mode" "$second_id")
    add_ship_task "$dir" "$first_id"
    add_ship_task "$second" "$second_id"
    cp "$second/home/state/$second_id.meta" "$dir/home/state/$second_id.meta"
    mkdir -p "$dir/home/data/$second_id"
    cp "$second/home/data/$second_id/brief.md" "$dir/home/data/$second_id/brief.md"
    make_herdr_stub "$dir"
    : > "$dir/fake/$mode"
    : > "$dir/fake/stale-socket"
    printf '%%none' > "$dir/fake/herdr-pane"
    : > "$dir/fake/herdr-log"
    : > "$dir/fake/herdr-stopped"
    mkdir -p "$dir/home/config"
    printf herdr > "$dir/home/config/backend"
    first_endpoint=
    for id in "$first_id" "$second_id"; do
      wt=$(meta_field "$dir" "$id" worktree)
      head_before=$(git -C "$wt" rev-parse HEAD)
      printf 'unlanded content\n' > "$wt/dirty.txt"
      printf 'working: preserved history\n' > "$dir/home/state/$id.status"
      printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$dir/home/state/$id.check.sh"
      chmod 0700 "$dir/home/state/$id.check.sh"
      FM_HOME="$dir/home" "$ROOT/bin/fm-check-register.sh" "$id" >/dev/null || fail "cannot arm reclaim check"
      printf 'busy_gen=gone-%s\n' "$id" >> "$dir/home/state/$id.meta"
      out=$(run_control "$dir" "$id" exit); rc=$?
      expect_code 0 "$rc" "no user tmux server should prove exit for $id"$'\n'"$out"
      assert_contains "$out" endpoint-gone "exit should report proven absence"
      assert_equals "gen=gone-$id" "$(cat "$dir/home/state/$id.control-exit")" "proven-gone exit must cancel the recorded incarnation"
      out=$(FM_FAKE_SESSION=fmlab run_control "$dir" "$id" relaunch --note "resume after reboot"); rc=$?
      expect_code 0 "$rc" "no user tmux server should permit Herdr reclaim for $id"$'\n'"$out"
      [ "$(meta_field "$dir" "$id" backend)" = herdr ] || fail "reclaim did not publish Herdr"
      [ "$(meta_field "$dir" "$id" endpoint_task_id)" = "$id" ] || fail "reclaim changed task identity"
      [ "$(meta_field "$dir" "$id" worktree)" = "$wt" ] || fail "reclaim changed the local copy"
      [ "$(git -C "$wt" rev-parse HEAD)" = "$head_before" ] || fail "reclaim moved the branch head"
      [ "$(git -C "$wt" symbolic-ref --short HEAD)" = "task-$id" ] || fail "reclaim switched branches"
      [ "$(cat "$wt/dirty.txt")" = "unlanded content" ] || fail "reclaim lost uncommitted work"
      assert_present "$dir/home/state/$id.check-trust" "reclaim broke armed poll registration"
      assert_contains "$(cat "$dir/home/state/$id.status")" "preserved history" "reclaim truncated status"
      assert_contains "$(cat "$dir/home/data/$id/brief.md")" "resume after reboot" "reclaim omitted note"
      assert_absent "$dir/fake/created-windows" "Herdr reclaim created a tmux endpoint"
      assert_absent "$dir/fake/created-sessions" "Herdr reclaim started a tmux server"
      if [ "$id" = "$first_id" ]; then
        first_endpoint=$(meta_field "$dir" "$id" window)
        [ "$first_endpoint" = 'fmlab:%9' ] || fail "first replacement has the wrong binding"
      else
        [ "$(meta_field "$dir" "$id" window)" = 'fmlab:%10' ] || fail "second replacement has the wrong binding"
      fi
    done
    [ "$(meta_field "$dir" "$first_id" window)" = "$first_endpoint" ] || fail "second reclaim rebound the first task"
    [ "$(wc -l < "$dir/fake/herdr-created-tabs" | tr -d ' ')" = 2 ] || fail "reclaim did not create exactly two tabs"
    for id in "$first_id" "$second_id"; do
      out=$(run_control "$dir" "$id" interrupt); rc=$?
      expect_code 0 "$rc" "both replacement agents must remain reachable and alive"$'\n'"$out"
    done
  done
  pass "tmux: two missing tasks reclaim sequentially onto Herdr, preserving work, note and poll"
}

test_tmux_reclaim_refuses_other_configured_backends() {
  local dir backend out rc before brief_before
  for backend in tmux zellij cmux orca unknown; do
    dir=$(new_case "tmux-reclaim-$backend" "rl84$backend")
    add_ship_task "$dir" "rl84$backend"
    : > "$dir/fake/server-dead"
    mkdir -p "$dir/home/config"
    printf '%s' "$backend" > "$dir/home/config/backend"
    before=$(cat "$dir/home/state/rl84$backend.meta")
    brief_before=$(cat "$dir/home/data/rl84$backend/brief.md")
    out=$(run_spawn "$dir" "rl84$backend" --relaunch); rc=$?
    expect_code 1 "$rc" "direct reclaim must refuse configured $backend"$'\n'"$out"
    out=$(run_control "$dir" "rl84$backend" relaunch --note "resume"); rc=$?
    expect_code 1 "$rc" "control reclaim must refuse configured $backend"$'\n'"$out"
    [ "$(cat "$dir/home/state/rl84$backend.meta")" = "$before" ] || fail "refused reclaim changed binding"
    assert_contains "$(cat "$dir/home/data/rl84$backend/brief.md")" "$brief_before" "refused reclaim lost prior instructions"
    assert_absent "$dir/fake/created-windows" "refused reclaim created a tmux endpoint"
    assert_absent "$dir/fake/created-sessions" "refused reclaim started a tmux server"
    assert_absent "$dir/fake/herdr-created-tabs" "refused reclaim created a Herdr endpoint"
    [ ! -s "$dir/fake/literal" ] || fail "refused reclaim delivered launch input"
  done
  pass "tmux: a proven-gone endpoint refuses every configured backend other than Herdr"
}

test_reclaim_refuses_an_unreadable_endpoint() {
  local dir out rc
  dir=$(new_case gone-unreadable rl63)
  add_ship_task "$dir" rl63 claude
  # The inventory itself fails non-definitively. That is not evidence of
  # absence, and reading it as one is exactly how two agents end up in one
  # endpoint.
  : > "$dir/fake/inventory-broken"

  out=$(run_spawn "$dir" rl63 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "an unreadable endpoint must still refuse"
  assert_contains "$out" "positively agent-free endpoint" \
    "only a POSITIVELY proven agent-free endpoint may be relaunched into"
  assert_absent "$dir/fake/created-windows" \
    "a refused relaunch must not create an endpoint"
  [ ! -s "$dir/fake/literal" ] || fail "a refused relaunch must launch nothing"
  pass "reclaim: an unclassifiable endpoint is still refused, so two agents cannot share one"
}

# --- herdr: a stopped server is not a destroyed endpoint --------------------
#
# Stopping and restarting a named Herdr server preserves workspace, tab, pane
# and label ids; only the harness processes and their registrations die
# (docs/herdr-backend.md "Restart and liveness behavior"). The recovery-grade
# classifier still reads a stopped server as `missing`, so a reclaim that
# believed that verdict would abandon a pane that was about to come back and
# open a second tab beside it.
#
# Canned/stateful fake only - never a real herdr session.
make_herdr_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  # The herdr server-ensure poll must actually wait between reads, so this case
  # keeps the real sleep rather than the tmux cases' instant stub.
  rm -f "$fb/sleep"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/herdr-log"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  if [ -f "$D/herdr-stopped" ]; then
    printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":false}}\n'
  else
    printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true}}\n'
  fi
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
    if [ -f "$D/herdr-agent-registration" ]; then
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
    # A retained registration with a shell-only pane models an exited agent
    # whose Herdr status authority still belongs to its previous session.
    if [ -f "$D/herdr-agent-registration" ]; then
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_processes":[]}}}\n' \
        "${4:-}"
    else
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_processes":[{"pid":4243,"name":"claude","argv":["claude"],"cmdline":"claude"}]}}}\n' \
        "${4:-}"
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
    case "$payload" in
      *'encode launch-brief'* | *'Firstmate operational input waiting: read'*)
        printf '%s\n' "$payload" > "$D/launched-command"
        : > "$D/herdr-live-${3:-}"
        : > "$D/herdr-agent-live" ;;
    esac
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

# add_herdr_ship_task <case-dir> <id> [session] [surviving-pane]: a ship task
# recorded on the herdr backend, with its server stopped so its endpoint
# classifies `missing`. <surviving-pane> is the pane id the fake will answer for
# once that server is back; default is the recorded one (it survived the
# restart). Pass a different id to model a pane that genuinely did not.
add_herdr_ship_task() {  # <case-dir> <id> [session] [surviving-pane]
  local dir=$1 id=$2 ses=${3:-fmlab} survivor=${4:-'%7'}
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
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
  TASK_TMPS+=("/tmp/fm-$id")
}

# Sets HERDR_CASE_DIR rather than echoing it, so callers invoke it as a plain
# statement. A `dir=$(herdr_case_or_skip ...)` would run add_herdr_ship_task in
# a command-substitution subshell, where its TASK_TMPS registration would
# mutate a discarded copy and the EXIT trap would never remove the
# out-of-tmproot /tmp/fm-<id> root the spawn creates.
HERDR_CASE_DIR=
herdr_case_or_skip() {  # <name> <id> [session] [surviving-pane]
  HERDR_CASE_DIR=
  command -v jq >/dev/null 2>&1 || return 1
  HERDR_CASE_DIR=$(new_case "$1" "$2")
  add_herdr_ship_task "$HERDR_CASE_DIR" "$2" "${3:-fmlab}" "${4:-%7}"
  make_herdr_stub "$HERDR_CASE_DIR"
  return 0
}

test_herdr_relaunch_resumes_only_the_registered_pi_session() {
  local dir out rc=0 command registered
  for registered in pi claude; do
    herdr_case_or_skip "resume-$registered" "resume-$registered" || {
      echo "skip - herdr relaunch needs jq (the herdr adapter parses JSON with it)"
      return 0
    }
    dir=$HERDR_CASE_DIR
    rm -f "$dir/fake/herdr-stopped"
    sed 's/^harness=claude$/harness=pi/' "$dir/home/state/resume-$registered.meta" > "$dir/pi.meta" \
      || fail 'could not prepare Pi relaunch metadata'
    mv "$dir/pi.meta" "$dir/home/state/resume-$registered.meta" \
      || fail 'could not publish Pi relaunch metadata'
    # Keep the pane's status authority registered to an existing Pi session,
    # while process-info proves that its previous agent has exited.
    printf '{"result":{"agent":{"agent":"%s","agent_status":"idle","agent_session":{"kind":"path","value":"/tmp/pi-bound-session.jsonl"}}}}\n' \
      "$registered" > "$dir/fake/herdr-agent-registration"
    out=$(run_spawn "$dir" "resume-$registered" --relaunch --harness pi) || rc=$?
    expect_code 0 "$rc" "Herdr Pi relaunch should complete ($registered registration)"$'\n'"$out"
    command=$(cat "$dir/fake/launched-command")
    if [ "$registered" = pi ]; then
      assert_contains "$command" "--session '/tmp/pi-bound-session.jsonl'" \
        "the replacement Pi must resume the session that owns Herdr status authority"
    else
      assert_not_contains "$command" "--session" \
        "a Pi replacement must not resume a foreign adapter's conversation"
    fi
    rc=0
  done
  pass "fm-spawn --relaunch: resumes the bound Pi session only for a Pi registration"
}

test_herdr_reclaim_adopts_a_pane_that_outlived_its_server() {
  local dir out rc=0 log stray
  herdr_case_or_skip gone-herdr rl68 || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR

  out=$(run_spawn "$dir" rl68 --relaunch --harness claude) || rc=$?
  log=$(cat "$dir/fake/herdr-log")
  expect_code 0 "$rc" "a pane that outlived its stopped server is adoptable"$'\n'"$out"$'\n'"$log"

  assert_contains "$log" "server --session fmlab" \
    "the reclaim must bring the RECORDED session's server back before deciding anything"
  assert_contains "$log" "agent get %7 --session fmlab" \
    "the reclaim must re-read the recorded pane once its server is running"
  assert_not_contains "$log" "workspace create" \
    "adopting a preserved pane must not create a workspace"
  assert_not_contains "$log" "tab create" \
    "adopting a preserved pane must not open a second tab beside it"
  # Every call belongs to the session the record names. A rebind resolves its
  # container from the ambient session instead, which is how the preserved pane
  # ends up orphaned in a workspace nothing points at.
  stray=$(printf '%s\n' "$log" | grep -v -- '--session fmlab$' | grep -v '^status --json$' || true)
  [ -z "$stray" ] || fail "a herdr reclaim touched a session the record does not name: $stray"
  assert_contains "$out" "window=fmlab:%7" "the reclaim should report the adopted endpoint"
  [ "$(meta_field "$dir" rl68 herdr_pane_id)" = '%7' ] \
    || fail "the adopted record's pane id changed, got $(meta_field "$dir" rl68 herdr_pane_id)"
  [ "$(meta_field "$dir" rl68 herdr_tab_id)" = tab1 ] \
    || fail "the adopted record's tab id changed, got $(meta_field "$dir" rl68 herdr_tab_id)"
  [ "$(meta_field "$dir" rl68 window)" = 'fmlab:%7' ] \
    || fail "the adopted record's endpoint moved, got $(meta_field "$dir" rl68 window)"
  assert_contains "$log" "pane send-text %7 " \
    "the replacement's launch brief must be delivered into the adopted pane"
  pass "reclaim: a herdr pane that outlived its stopped server is adopted, never orphaned beside a new tab"
}

test_herdr_exit_reports_already_stopped_when_the_pane_outlived_its_server() {
  local dir out rc=0
  herdr_case_or_skip gone-herdr-exit rl72 || {
    echo "skip - herdr exit needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  printf 'busy_gen=retired-rl72\n' >> "$dir/home/state/rl72.meta"

  out=$(run_control "$dir" rl72 exit) || rc=$?
  expect_code 0 "$rc" "a pane that outlived its stopped server holds no agent, which is success"$'\n'"$out"
  assert_equals gen=retired-rl72 "$(cat "$dir/home/state/rl72.control-exit")" "surviving dead endpoint exit must cancel its retired incarnation"
  assert_contains "$out" "already-stopped" \
    "the endpoint is there and idle, which is the ordinary already-stopped outcome"
  assert_not_contains "$out" "endpoint-gone" \
    "a pane that survived its server's restart was never gone"
  [ "$(meta_field "$dir" rl72 window)" = 'fmlab:%7' ] \
    || fail "exit must leave the recorded endpoint exactly as it found it"
  pass "fm-control exit: a herdr pane that outlived its stopped server is already-stopped, not gone"
}

test_herdr_exit_resolves_retired_quota_identity_after_server_recovery() {
  local dir id=rl72-quota out rc=0 gen journal_before
  herdr_case_or_skip gone-herdr-quota-exit "$id" || {
    echo "skip - herdr quota exit needs jq"
    return 0
  }
  dir=$HERDR_CASE_DIR
  "$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" "$id" --state idle --source omp-ext --event quota-exhausted >/dev/null
  gen=$(cat "$dir/home/state/$id.busy-gen")
  "$ROOT/bin/fm-busy-event.sh" retire "$dir/home/state" "$id" --current-gen >/dev/null
  printf 'unfinished change\n' > "$dir/wt/unfinished.txt"
  {
    printf 'task=%s\nworktree=%s\nkind=ship\n' "$id" "$dir/wt"
    printf 'backend=herdr\nendpoint=fmlab:%%7\n'
    printf 'phase=failed:noted\nrollback=instructions-restored\n'
    printf 'quota_gen=%s\nquota_seq=1\nrelaunch_tx=quota-partial\n' "$gen"
    printf 'from_busy_gen=-\nfrom_relaunch_tx=-\n'
    printf 'from_harness=claude\nfrom_model=default\nfrom_effort=default\n'
  } > "$dir/home/state/$id.control-relaunch"
  journal_before=$(cat "$dir/home/state/$id.control-relaunch")
  out=$(run_control "$dir" "$id" exit) || rc=$?
  expect_code 0 "$rc" "recovered dead endpoint must satisfy explicit exit: $out"
  assert_contains "$out" already-stopped "the restored endpoint must remain stopped"
  assert_equals "gen=$gen" "$(cat "$dir/home/state/$id.control-exit")" "successful absence recovery must resolve the validated retired quota identity"
  out=$(run_session_end_scan "$dir"); rc=$?
  expect_code 0 "$rc" "cancelled recovered-dead quota scan must succeed: $out"
  assert_equals '' "$out" "the recovered journal must not relaunch after explicit exit"
  assert_equals "$journal_before" "$(cat "$dir/home/state/$id.control-relaunch")" "cancelled recovered journal must remain unchanged"
  assert_no_grep 'pane send-text' "$dir/fake/herdr-log" "cancelled recovery must not type or launch"
  assert_absent "$dir/home/state/$id.busy-gen" "server recovery must not resurrect retired busy generation"
  assert_absent "$dir/home/state/$id.busy-state" "server recovery must not resurrect busy state"
  assert_equals 'unfinished change' "$(cat "$dir/wt/unfinished.txt")" "server recovery cancellation must preserve work"
  pass "explicit exit resolves a retired quota identity only after recovering its dead Herdr endpoint"
}

test_herdr_rebind_stays_in_the_recorded_session() {
  local dir out rc=0 log
  # The record names session `fmlab`; this seat has no ambient HERDR_SESSION, so
  # the adapter's own default is `default`. The recorded pane does NOT come back
  # with the server, so this reclaim really does rebind - and the rebind must
  # land in `fmlab`, never in `default`.
  herdr_case_or_skip gone-herdr-pin rl73 fmlab '%none' || {
    echo "skip - herdr rebind needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR

  out=$(run_spawn "$dir" rl73 --relaunch --harness claude) || rc=$?
  log=$(cat "$dir/fake/herdr-log")
  expect_code 0 "$rc" "a herdr pane that did not survive its server should be rebound"$'\n'"$out"$'\n'"$log"

  assert_contains "$log" "tab create" "a destroyed pane must be replaced by a fresh tab"
  [ -z "$(grep -v -- '--session fmlab$' <<<"$log" | grep -v '^status --json$' || true)" ] \
    || fail "the rebind used a herdr session the record does not name: $log"
  [ "$(meta_field "$dir" rl73 herdr_session)" = fmlab ] \
    || fail "the rebound record left its recorded herdr session, got $(meta_field "$dir" rl73 herdr_session)"
  [ "$(meta_field "$dir" rl73 window)" = 'fmlab:%9' ] \
    || fail "the rebound endpoint should be the new pane in the recorded session, got $(meta_field "$dir" rl73 window)"
  [ "$(meta_field "$dir" rl73 herdr_pane_id)" = '%9' ] \
    || fail "the rebound record should name the pane the reclaim minted, got $(meta_field "$dir" rl73 herdr_pane_id)"
  pass "reclaim: a herdr rebind is created in the session the record names, never the ambient one"
}

test_herdr_reclaim_refuses_an_agent_that_came_back() {
  local dir out rc log
  herdr_case_or_skip gone-herdr-alive rl74 || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  # The server was stopped, so the first read says `missing` - but starting it
  # brings the pane AND its agent back. A rebind here would put a second agent
  # in this task's worktree, which is the whole reason absence is re-proven.
  : > "$dir/fake/herdr-agent-live"

  out=$(run_spawn "$dir" rl74 --relaunch --harness claude); rc=$?
  log=$(cat "$dir/fake/herdr-log")
  expect_code 1 "$rc" "a returning agent must refuse, never be duplicated"$'\n'"$out"$'\n'"$log"
  assert_contains "$out" "alive" "the refusal should name the state it actually read"
  assert_not_contains "$log" "tab create" "a refused reclaim must not mint a second tab"
  assert_not_contains "$log" "workspace create" "a refused reclaim must not create a workspace"
  [ "$(meta_field "$dir" rl74 herdr_pane_id)" = '%7' ] \
    || fail "a refused reclaim rewrote the record's pane id"
  pass "reclaim: a herdr agent that came back with its server refuses, so one worktree keeps one agent"
}

test_herdr_reclaim_keeps_the_task_whole() {
  local dir out rc=0 head_before
  herdr_case_or_skip gone-herdr-work rl75 fmlab '%none' || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  printf 'landed on the branch\n' > "$dir/wt/committed.txt"
  git -C "$dir/wt" add committed.txt
  git -C "$dir/wt" -c user.email=t@example.com -c user.name=t commit -qm "work in progress"
  head_before=$(git -C "$dir/wt" rev-parse HEAD)
  printf 'never committed\n' > "$dir/wt/dirty.txt"

  # A reclaim rebinds the ENDPOINT and nothing else. Everything that identifies
  # the task must come through untouched: a record row the reclaim does not
  # own, the armed watcher check and the private binding that authorizes it,
  # and the status log the supervisor reads.
  printf '%s\n' "pr=https://example.invalid/pr/7" >> "$dir/home/state/rl75.meta"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$dir/home/state/rl75.check.sh"
  chmod 0700 "$dir/home/state/rl75.check.sh"
  FM_HOME="$dir/home" "$ROOT/bin/fm-check-register.sh" rl75 >/dev/null \
    || fail "could not arm a custom check for the reclaim fixture"
  printf 'working: parked on an approval nobody can answer\n' >> "$dir/home/state/rl75.status"

  out=$(run_control "$dir" rl75 relaunch --note "the pane was destroyed; pick the work back up") || rc=$?
  expect_code 0 "$rc" "the owning seat should be able to reclaim a task whose pane is gone"$'\n'"$out"

  [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$head_before" ] \
    || fail "a reclaim moved the worktree's HEAD"
  [ "$(git -C "$dir/wt" rev-parse --abbrev-ref HEAD)" = "task-rl75" ] \
    || fail "a reclaim changed the worktree's branch"
  assert_contains "$(cat "$dir/wt/dirty.txt")" "never committed" \
    "a reclaim destroyed or rewrote an uncommitted change"
  assert_present "$dir/wt/committed.txt" "a reclaim destroyed committed work"

  [ "$(meta_field "$dir" rl75 worktree)" = "$dir/wt" ] \
    || fail "a reclaim must keep the recorded worktree"
  [ "$(meta_field "$dir" rl75 pr)" = "https://example.invalid/pr/7" ] \
    || fail "a reclaim dropped a record row it does not own"
  assert_present "$dir/home/state/rl75.check.sh" "a reclaim retired the task's armed check"
  assert_present "$dir/home/state/rl75.check-trust" "a reclaim broke the armed check's registration"
  assert_contains "$(cat "$dir/home/state/rl75.status")" "parked on an approval nobody can answer" \
    "a reclaim truncated the status log"
  assert_contains "$(cat "$dir/home/data/rl75/brief.md")" "the pane was destroyed" \
    "the replacement must inherit the progress note"
  [ "$(journal_field "$dir" rl75 exit_result)" = endpoint-gone ] \
    || fail "the transaction should record that the endpoint was already gone"
  pass "reclaim: a herdr reclaim rebinds the endpoint and leaves the whole rest of the task alone"
}

test_herdr_rebind_failure_from_a_plain_shell_names_the_real_cause() {
  local dir out rc
  # No HERDR_* env at all, which is how an operator reclaims from ssh or cron.
  # The adapter's ambient session then reads `default` while the record names
  # `fmlab`, but the cross-session launcher guard was never consulted - this
  # seat claims no launcher pane, so placement fell back to the recorded
  # session's labeled container and the container failed for its own reason.
  herdr_case_or_skip gone-herdr-plain rl77 fmlab '%none' || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  : > "$dir/fake/herdr-workspace-create-fails"

  out=$(run_spawn "$dir" rl77 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "a container that cannot be ensured must refuse"$'\n'"$out"
  assert_contains "$out" "fmlab" "the refusal should name the session the reclaim was targeting"
  assert_not_contains "$out" "this seat is running in herdr session" \
    "a seat with no launcher pane never hit the cross-session guard, so the refusal must not blame one"
  assert_not_contains "$out" "a reclaim never moves a task to another session" \
    "the operator must not be sent to re-run from another seat when that would not help"
  pass "reclaim: a rebind refused from a plain shell reports the real cause, not a fabricated session mismatch"
}

test_herdr_reclaim_of_a_secondmate_names_its_own_owner() {
  local dir out rc
  herdr_case_or_skip gone-herdr-secondmate rl76 fmlab '%none' || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  printf '%s\n' "kind=secondmate" "home=$dir/wt" >> "$dir/home/state/rl76.meta"

  out=$(run_spawn "$dir" rl76 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "a secondmate reclaim belongs to the secondmate respawn path"
  assert_contains "$out" "--secondmate" "the refusal should name the path that owns this recovery"
  assert_not_contains "$(cat "$dir/fake/herdr-log")" "tab create" \
    "the refusal must happen before any endpoint is created"
  pass "reclaim: a herdr secondmate whose endpoint is gone is sent to its own respawn owner"
}

test_held_relaunch_refuses_without_stopping_the_live_owner() {
  local dir out rc=0
  dir=$(new_case held-owner rlheld)
  add_ship_task "$dir" rlheld
  seed_backlog "$dir" rlheld in_flight
  tasks-axi hold rlheld --reason "captain decision pending" --kind captain \
    --file "$dir/home/data/backlog.md" >/dev/null
  cp "$dir/home/state/rlheld.meta" "$dir/meta-before"
  cp "$dir/home/data/rlheld/brief.md" "$dir/brief-before"
  cp "$dir/home/data/backlog.md" "$dir/backlog-before"

  out=$(run_control "$dir" rlheld relaunch --note "fresh context"); rc=$?
  expect_code 1 "$rc" "a held replacement must refuse"
  assert_contains "$out" "not dispatchable" "refusal should identify admission"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a predictable replacement refusal stranded the live owner"
  [ ! -s "$dir/fake/literal" ] || fail "refused admission sent lifecycle input"
  cmp -s "$dir/meta-before" "$dir/home/state/rlheld.meta" || fail "refusal changed metadata"
  cmp -s "$dir/brief-before" "$dir/home/data/rlheld/brief.md" || fail "refusal changed instructions"
  cmp -s "$dir/backlog-before" "$dir/home/data/backlog.md" || fail "refusal changed the hold"
  pass "held replacement admission refuses before touching the live owner"
}

test_exited_owner_reconciliation_preserves_holds_dependencies_and_work() {
  local dir id restriction out rc head
  for restriction in held dependency both; do
    id="rlrecover-$restriction"
    dir=$(new_case "recover-$restriction" "$id")
    add_ship_task "$dir" "$id"
    seed_backlog "$dir" "$id" in_flight
    if [ "$restriction" != dependency ]; then
      tasks-axi hold "$id" --reason "captain decision pending" --kind captain \
        --file "$dir/home/data/backlog.md" >/dev/null
    fi
    if [ "$restriction" != held ]; then
      tasks-axi add prerequisite "genuine unfinished dependency" --kind ship \
        --file "$dir/home/data/backlog.md" >/dev/null
      tasks-axi block "$id" --by prerequisite --file "$dir/home/data/backlog.md" >/dev/null
    fi
    printf 'retained commit\n' > "$dir/wt/retained.txt"
    git -C "$dir/wt" add retained.txt
    git -C "$dir/wt" commit -qm "fixture retained work"
    head=$(git -C "$dir/wt" rev-parse HEAD)
    printf 'uncommitted work\n' >> "$dir/wt/retained.txt"
    printf 'untracked work\n' > "$dir/wt/untracked.txt"
    mkdir -p "$dir/home/state/$id.inbox/handled"
    printf 'Reconcile factual wait only; no validation permission.\n' > "$dir/home/state/$id.inbox/005.msg"
    cp "$dir/home/state/$id.inbox/005.msg" "$dir/instruction-before"
    cp "$dir/home/data/backlog.md" "$dir/backlog-before"
    printf zsh > "$dir/fake/command"
    break_tasks_axi_start "$dir"

    rc=0
    out=$(run_control "$dir" "$id" relaunch --reconcile-only --note "Read unread instructions; retain the genuine blocker.") || rc=$?
    expect_code 0 "$rc" "$restriction exited-owner recovery should succeed"$'\n'"$out"
    [ "$(meta_field "$dir" "$id" recovery)" = reconcile-only ] || fail "recovery scope was not recorded"
    [ "$(cat "$dir/fake/command")" = claude ] || fail "replacement instruction owner was not launched"
    [ "$(meta_field "$dir" "$id" worktree)" = "$dir/wt" ] || fail "recovery changed the local copy"
    [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$head" ] || fail "recovery moved the preserved commit"
    assert_contains "$(cat "$dir/wt/retained.txt")" "uncommitted work" "recovery lost dirty files"
    [ "$(cat "$dir/wt/untracked.txt")" = "untracked work" ] || fail "recovery lost untracked files"
    cmp -s "$dir/backlog-before" "$dir/home/data/backlog.md" || fail "recovery changed hold/dependency state"
    cmp -s "$dir/instruction-before" "$dir/home/state/$id.inbox/005.msg" || fail "recovery consumed unread instructions"
    rc=0
    out=$(run_control "$dir" "$id" relaunch --note "try ordinary continuation") || rc=$?
    expect_code 1 "$rc" "a recovered owner must still fail ordinary blocked dispatch"
    [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused ordinary relaunch stopped the recovered owner"
  done
  pass "exited-owner recovery preserves commits, files, instructions, and real holds/dependencies without continuation authority"
}

test_session_end_replacement_cannot_convert_recovery_to_execution() {
  local dir id=rlrecover-exit out rc=0 gen
  dir=$(new_case recover-session-end "$id")
  add_ship_task "$dir" "$id"
  seed_backlog "$dir" "$id" in_flight
  tasks-axi add prerequisite "genuine unfinished dependency" --kind ship \
    --file "$dir/home/data/backlog.md" >/dev/null
  tasks-axi block "$id" --by prerequisite --file "$dir/home/data/backlog.md" >/dev/null
  printf zsh > "$dir/fake/command"
  out=$(run_control "$dir" "$id" relaunch --reconcile-only --note "Reconcile only.") || rc=$?
  expect_code 0 "$rc" "dependency-only recovery should succeed"$'\n'"$out"
  # The recovered owner exits before it declares a wait. Completing the real
  # prerequisite permits dispatch structurally, but is not continuation consent.
  printf zsh > "$dir/fake/command"
  gen=$(cat "$dir/home/state/$id.busy-gen")
  "$ROOT/bin/fm-busy-event.sh" apply "$dir/home/state" "$id" idle --gen "$gen" \
    --source claude-hook --event session-end >/dev/null
  tasks-axi 'done' prerequisite --file "$dir/home/data/backlog.md" >/dev/null
  cp "$dir/home/data/backlog.md" "$dir/backlog-before-auto"
  cat > "$dir/session-end.sh" <<'SH'
#!/usr/bin/env bash
set -eu
. "$1/bin/fm-session-end-relaunch-lib.sh"
fm_session_end_relaunch_scan "$2"
[ "$FM_SESSION_END_WAKE" = "check: $3 auto-relaunched after session-end" ]
SH
  rc=0
  out=$(env -u HERDR_ENV -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_SESSION_END_LAUNCH_WAIT=1 \
    bash "$dir/session-end.sh" "$ROOT" "$dir/home/state" "$id" 2>&1) || rc=$?
  expect_code 0 "$rc" "automatic recovery replacement should stay bounded"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" recovery)" = reconcile-only ] \
    || fail "automatic replacement removed recovery scope after the dependency completed"
  assert_grep '# Current reconciliation-only recovery contract' "$dir/home/data/$id/launch-brief.md" \
    "automatic replacement did not inherit the recovery-only instruction contract"
  assert_grep 'not resuming implementation' "$dir/home/data/$id/launch-brief.md" \
    "automatic replacement instructions incorrectly authorize implementation"
  cmp -s "$dir/backlog-before-auto" "$dir/home/data/backlog.md" \
    || fail "automatic replacement changed task/dependency state"
  # Direct launch callers must inherit the same restriction, not only control.
  printf zsh > "$dir/fake/command"
  rc=0
  out=$(run_spawn "$dir" "$id" --relaunch --harness claude) || rc=$?
  expect_code 0 "$rc" "direct replacement of a recovered owner should remain bounded"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" recovery)" = reconcile-only ] \
    || fail "direct replacement removed recovery scope"
  assert_grep '# Current reconciliation-only recovery contract' "$dir/home/data/$id/launch-brief.md" \
    "direct replacement did not inherit the recovery-only instruction contract"
  make_continuation_owner_fixture "$dir"
  cp "$dir/home/state/$id.meta" "$dir/meta-before-clearance"
  cp "$dir/home/data/$id/brief.md" "$dir/brief-before-clearance"
  rc=0
  out=$(run_control "$dir" "$id" relaunch --note "no implicit permission from a completed dependency") || rc=$?
  expect_code 1 "$rc" "ordinary live relaunch must still inherit recovery after dependency completion"
  assert_contains "$out" "requires a proven exited owner" "ordinary syntax dropped its inherited reconciliation restriction"
  cmp -s "$dir/meta-before-clearance" "$dir/home/state/$id.meta" || fail "refused inherited recovery changed metadata"
  cmp -s "$dir/brief-before-clearance" "$dir/home/data/$id/brief.md" || fail "refused inherited recovery changed instructions"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "inherited recovery refusal stopped the recovered owner"
  snapshot_continuation_case "$dir"
  rc=0
  out=$(run_continuation_control "$dir" "$id" authorize-continuation) || rc=$?
  expect_code 0 "$rc" "the actual owner may explicitly clear now-unblocked recovery"$'\n'"$out"
  assert_continuation_snapshot "$dir" "$id" 1
  printf zsh > "$dir/fake/command"
  rc=0
  out=$(run_spawn "$dir" "$id" --relaunch --harness claude) || rc=$?
  expect_code 0 "$rc" "direct replacement after explicit clearance should be ordinary"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" recovery)" = '' ] || fail "direct replacement restored recovery after explicit clearance"
  assert_no_grep '# Current reconciliation-only recovery contract' "$dir/home/data/$id/launch-brief.md" \
    "direct replacement after clearance retained the obsolete recovery-only role"
  id=rlcleared-auto
  dir=$(new_case recover-cleared-auto "$id")
  add_ship_task "$dir" "$id"
  seed_backlog "$dir" "$id" in_flight
  printf 'recovery=reconcile-only\n' >> "$dir/home/state/$id.meta"
  make_continuation_owner_fixture "$dir"
  snapshot_continuation_case "$dir"
  rc=0
  out=$(run_continuation_control "$dir" "$id" authorize-continuation) || rc=$?
  expect_code 0 "$rc" "a separately budgeted owner may explicitly clear recovery before its first automatic replacement"$'\n'"$out"
  assert_continuation_snapshot "$dir" "$id" 1
  cp "$dir/home/data/backlog.md" "$dir/backlog-before-auto"
  arm_session_end "$dir" "$id"
  printf zsh > "$dir/fake/command"
  rc=0
  out=$(run_session_end_scan "$dir") || rc=$?
  expect_code 0 "$rc" "automatic replacement after explicit clearance should be ordinary"$'\n'"$out"
  assert_contains "$out" "$id auto-relaunched after session-end" "cleared automatic replacement did not relaunch"
  [ "$(meta_field "$dir" "$id" recovery)" = '' ] || fail "automatic replacement restored recovery after explicit clearance"
  assert_no_grep '# Current reconciliation-only recovery contract' "$dir/home/data/$id/launch-brief.md" \
    "automatic replacement after clearance retained the obsolete recovery-only role"
  cmp -s "$dir/backlog-before-auto" "$dir/home/data/backlog.md" || fail "clearance and later replacements changed a completed dependency or task state"
  pass "automatic, direct, and ordinary replacement inherit recovery until explicit clearance, then remain ordinary"
}

test_reconciliation_refuses_live_queued_and_unowned_dispatch() {
  local dir out rc
  dir=$(new_case recovery-live rlrecoverylive)
  add_ship_task "$dir" rlrecoverylive
  seed_backlog "$dir" rlrecoverylive in_flight
  rc=0
  out=$(run_control "$dir" rlrecoverylive relaunch --reconcile-only --note "reconcile") || rc=$?
  expect_code 1 "$rc" "reconciliation must not stop a live owner"
  assert_contains "$out" "requires a proven exited owner" "live-owner refusal lost the reason"
  [ ! -s "$dir/fake/literal" ] || fail "recovery sent input to a live owner"
  tasks-axi reopen rlrecoverylive --file "$dir/home/data/backlog.md" >/dev/null
  printf zsh > "$dir/fake/command"
  rc=0
  out=$(run_control "$dir" rlrecoverylive relaunch --reconcile-only --note "reconcile") || rc=$?
  expect_code 1 "$rc" "reconciliation must not start queued work"
  assert_contains "$out" "requires an existing In-flight" "queued refusal lost its reason"
  rc=0
  out=$(run_spawn "$dir" rlrecoverylive --reconcile-only --mode no-mistakes --yolo off) || rc=$?
  expect_code 1 "$rc" "fresh dispatch must not use recovery admission"
  assert_contains "$out" "applies only to --relaunch" "fresh dispatch recovery flag was not refused"
  rm "$dir/home/data/backlog.md"
  rc=0
  out=$(run_control "$dir" rlrecoverylive relaunch --reconcile-only --note "reconcile") || rc=$?
  expect_code 1 "$rc" "reconciliation must not assume a missing backlog has no blocker"
  assert_contains "$out" "requires a readable automatic backlog" "missing backlog refusal lost its reason"
  pass "reconciliation-only admission refuses live owners, queued work, fresh dispatch, and absent backlog authority"
}

test_blocked_relaunch_admission_is_shared_across_supported_harnesses() {
  local dir harness out rc
  for harness in claude codex opencode pi pi-signed grok kimi cursor gemini muse rovo omp agy devin; do
    dir=$(new_case "held-$harness" "rlaxis-$harness")
    add_ship_task "$dir" "rlaxis-$harness" "$harness"
    seed_backlog "$dir" "rlaxis-$harness" in_flight
    tasks-axi hold "rlaxis-$harness" --reason "captain decision pending" --kind captain \
      --file "$dir/home/data/backlog.md" >/dev/null
    rc=0
    out=$(run_control "$dir" "rlaxis-$harness" relaunch --note "fresh context") || rc=$?
    expect_code 1 "$rc" "$harness must refuse held replacement"
    assert_contains "$out" "not dispatchable" "$harness did not use shared structural admission"
    [ ! -s "$dir/fake/literal" ] || fail "$harness received lifecycle input on refusal"
  done
  pass "all supported worker harnesses share pre-stop blocked replacement admission"
}

test_herdr_held_owner_refusal_and_exited_reconciliation() {
  local dir out rc=0
  herdr_case_or_skip held-herdr rlheldherdr || {
    echo "skip - Herdr admission fixtures need jq"
    return 0
  }
  dir=$HERDR_CASE_DIR
  rm "$dir/fake/herdr-stopped"
  : > "$dir/fake/herdr-agent-live"
  seed_backlog "$dir" rlheldherdr in_flight
  tasks-axi hold rlheldherdr --reason "captain decision pending" --kind captain \
    --file "$dir/home/data/backlog.md" >/dev/null
  cp "$dir/home/data/backlog.md" "$dir/backlog-before"
  out=$(run_control "$dir" rlheldherdr relaunch --note "fresh context") || rc=$?
  expect_code 1 "$rc" "Herdr held replacement must refuse"
  assert_contains "$out" "not dispatchable" "Herdr admission lost its refusal"
  assert_not_contains "$(cat "$dir/fake/herdr-log")" "pane send-" "refused Herdr replacement sent lifecycle input"
  [ -f "$dir/fake/herdr-agent-live" ] || fail "Herdr live owner was stopped"
  rm "$dir/fake/herdr-agent-live"
  rc=0
  out=$(run_control "$dir" rlheldherdr relaunch --reconcile-only --note "Reconcile only.") || rc=$?
  expect_code 0 "$rc" "Herdr exited instruction owner should recover"$'\n'"$out"
  [ "$(meta_field "$dir" rlheldherdr window)" = "fmlab:%7" ] || fail "Herdr recovery changed endpoint"
  [ "$(meta_field "$dir" rlheldherdr recovery)" = reconcile-only ] || fail "Herdr recovery lost scope"
  cmp -s "$dir/backlog-before" "$dir/home/data/backlog.md" || fail "Herdr recovery changed the hold"
  pass "Herdr shares pre-stop held admission and recovery-only exited-owner preservation"
}

test_continuation_authorization_requires_the_lock_owning_main() {
  local dir id owner out rc foreign_pid
  for owner in missing foreign dead worker branch branch-away; do
    id="rlclear-$owner"
    dir=$(new_case "clear-$owner" "$id")
    seed_continuation_case "$dir" "$id"
    foreign_pid=
    case "$owner" in
      missing) rm "$dir/home/state/.lock" ;;
      foreign)
        /bin/sleep 30 &
        # shellcheck disable=SC2031 # The parent just launched this child; $! is not inherited.
        foreign_pid=$!
        printf '%s\n' "$foreign_pid" > "$dir/fake/foreign-pid"
        printf '%s\n' "$foreign_pid" > "$dir/home/state/.lock"
        ;;
      dead)
        /bin/sleep 0 &
        # shellcheck disable=SC2031 # The parent just launched this child; $! is not inherited.
        foreign_pid=$!
        wait "$foreign_pid"
        printf '%s\n' "$foreign_pid" > "$dir/home/state/.lock"
        foreign_pid=
        ;;
      branch-away)
        FM_HOME="$dir/home" "$ROOT/bin/fm-afk-contract.sh" enter --spend 3 >/dev/null \
          || fail "could not establish the confirmed away posture"
        FM_HOME="$dir/home" "$ROOT/bin/fm-afk-contract.sh" validate >/dev/null \
          || fail "the away refusal fixture has no valid authority record"
        ;;
    esac
    printf '\nwindow=wrong-session:wrong-task\n' >> "$dir/home/state/$id.meta"
    snapshot_continuation_case "$dir"
    rc=0
    case "$owner" in
      worker)
        out=$(FM_FAKE_TASK_ID="$id" run_continuation_control "$dir" "$id" authorize-continuation) || rc=$?
        ;;
      branch|branch-away)
        out=$(FM_FAKE_ACTOR=branch run_continuation_control "$dir" "$id" authorize-continuation) || rc=$?
        ;;
      *)
        out=$(run_continuation_control "$dir" "$id" authorize-continuation) || rc=$?
        ;;
    esac
    if [ -n "$foreign_pid" ]; then
      kill "$foreign_pid" 2>/dev/null || true
      wait "$foreign_pid" 2>/dev/null || true
    fi
    case "$owner" in
      worker)
        expect_code 1 "$rc" "a marked worker must not authorize continuation even under the owning session"
        assert_contains "$out" "workers cannot authorize continuation" "worker refusal lost its authority boundary"
        ;;
      branch|branch-away)
        expect_code 6 "$rc" "$owner must not inherit continuation authority"
        assert_contains "$out" "the supervision branch never performs this action" "branch refusal lost its role partition"
        ;;
      *)
        expect_code 1 "$rc" "$owner session ownership must refuse continuation authorization"
        assert_contains "$out" "requires the actual lock-owning main Firstmate" "owner refusal lost its authority boundary"
        ;;
    esac
    assert_continuation_snapshot "$dir" "$id"
  done
  pass "continuation authorization refuses missing, foreign, dead, worker, and attended/away branch authority without side effects"
}

test_continuation_authorization_rejects_relaunch_options_and_arbitrary_input() {
  local dir id form out rc expected
  for form in note reconcile text unknown-verb; do
    id="rlclear-options-$form"
    dir=$(new_case "clear-options-$form" "$id")
    seed_continuation_case "$dir" "$id"
    snapshot_continuation_case "$dir"
    rc=0
    expected=1
    case "$form" in
      note)
        out=$(run_continuation_control "$dir" "$id" authorize-continuation --note "not a continuation instruction") || rc=$?
        assert_contains "$out" "apply to 'relaunch' only" "authorization accepted relaunch notes"
        ;;
      reconcile)
        out=$(run_continuation_control "$dir" "$id" authorize-continuation --reconcile-only) || rc=$?
        assert_contains "$out" "apply to 'relaunch' only" "authorization accepted recovery launch options"
        ;;
      text)
        out=$(run_continuation_control "$dir" "$id" authorize-continuation "implement the rest") || rc=$?
        assert_contains "$out" "unexpected argument" "authorization accepted arbitrary instruction text"
        ;;
      unknown-verb)
        expected=2
        out=$(run_continuation_control "$dir" "$id" continue) || rc=$?
        assert_contains "$out" "allowed verbs:" "a non-allowlisted continuation verb did not refuse"
        ;;
    esac
    expect_code "$expected" "$rc" "$form must refuse without mutation or delivery"
    assert_continuation_snapshot "$dir" "$id"
  done
  pass "continuation clearance accepts no relaunch options, arbitrary text, or non-allowlisted verbs"
}

test_continuation_authorization_preserves_blocked_ordinary_admission() {
  local dir id restriction out rc
  for restriction in held dependency both; do
    id="rlclear-block-$restriction"
    dir=$(new_case "clear-block-$restriction" "$id")
    seed_continuation_case "$dir" "$id"
    if [ "$restriction" != dependency ]; then
      tasks-axi hold "$id" --reason "captain decision pending" --kind captain \
        --file "$dir/home/data/backlog.md" >/dev/null
    fi
    if [ "$restriction" != held ]; then
      tasks-axi add prerequisite "genuine unfinished dependency" --kind ship \
        --file "$dir/home/data/backlog.md" >/dev/null
      tasks-axi block "$id" --by prerequisite --file "$dir/home/data/backlog.md" >/dev/null
    fi
    snapshot_continuation_case "$dir"
    rc=0
    out=$(run_continuation_control "$dir" "$id" authorize-continuation) || rc=$?
    expect_code 1 "$rc" "$restriction must refuse ordinary continuation admission"
    assert_contains "$out" "not dispatchable" "clearance used recovery admission instead of ordinary dispatch admission"
    assert_continuation_snapshot "$dir" "$id"
  done
  pass "held and dependency-blocked continuation authorization refuses ordinary admission and preserves every byte"
}

test_continuation_authorization_requires_current_automatic_backlog_and_recovery() {
  local dir id restriction out rc expected
  for restriction in missing-backlog manual-backlog unreadable-backlog pending-close missing-kind ambiguous-kind missing-recovery ambiguous-recovery remote symlink; do
    id="rlclear-record-$restriction"
    dir=$(new_case "clear-record-$restriction" "$id")
    seed_continuation_case "$dir" "$id"
    expected=
    case "$restriction" in
      missing-backlog)
        rm "$dir/home/data/backlog.md"
        expected="requires a readable automatic backlog"
        ;;
      manual-backlog)
        mkdir -p "$dir/home/config"
        printf 'manual\n' > "$dir/home/config/backlog-backend"
        expected="requires a readable automatic backlog"
        ;;
      unreadable-backlog)
        rm "$dir/home/data/backlog.md"
        mkdir "$dir/home/data/backlog.md"
        expected="requires a readable automatic backlog"
        ;;
      pending-close)
        printf 'id=%s\ndata=%s\nspawn_gen=preserved-incarnation\n' "$id" "$dir/home/data" \
          > "$dir/home/state/$id.backlog-close"
        expected="pending authoritative backlog close"
        ;;
      missing-kind)
        sed '/^kind=/d' "$dir/home/state/$id.meta" > "$dir/restricted.meta"
        mv "$dir/restricted.meta" "$dir/home/state/$id.meta"
        expected="ship or scout"
        ;;
      ambiguous-kind)
        printf '\nkind=scout\n' >> "$dir/home/state/$id.meta"
        expected="unambiguous ship or scout kind"
        ;;
      missing-recovery)
        sed '/^recovery=/d' "$dir/home/state/$id.meta" > "$dir/restricted.meta"
        mv "$dir/restricted.meta" "$dir/home/state/$id.meta"
        expected="unambiguous recovery field"
        ;;
      ambiguous-recovery)
        printf '\nrecovery=reconcile-only\n' >> "$dir/home/state/$id.meta"
        expected="unambiguous recovery field"
        ;;
      remote)
        printf '\nremote_host=other-host\n' >> "$dir/home/state/$id.meta"
        expected="requires a local ship or scout"
        ;;
      symlink)
        mv "$dir/home/state/$id.meta" "$dir/foreign.meta"
        ln -s "$dir/foreign.meta" "$dir/home/state/$id.meta"
        cp "$dir/foreign.meta" "$dir/foreign-before"
        expected="task record resolves outside its authorized directory"
        ;;
    esac
    snapshot_continuation_case "$dir"
    rc=0
    out=$(run_continuation_control "$dir" "$id" authorize-continuation) || rc=$?
    expect_code 1 "$rc" "$restriction must refuse metadata-only continuation clearance"
    assert_contains "$out" "$expected" "$restriction refusal lost its actual prerequisite"
    assert_continuation_snapshot "$dir" "$id"
    if [ "$restriction" = symlink ]; then
      cmp -s "$dir/foreign-before" "$dir/foreign.meta" || fail "clearance changed a foreign record through a symlink"
    fi
  done
  pass "continuation authorization requires current automatic backlog, local unambiguous recovery records, and no pending close"
}

test_continuation_authorization_only_clears_recovery_before_future_relaunch() {
  local dir id state kind out rc
  for state in live exited; do
    id="rlclear-success-$state"
    dir=$(new_case "clear-success-$state" "$id")
    seed_continuation_case "$dir" "$id"
    kind=ship
    if [ "$state" = exited ]; then
      kind=scout
      perl -pe 's/^kind=ship$/kind=scout/' "$dir/home/state/$id.meta" > "$dir/scout.meta"
      mv "$dir/scout.meta" "$dir/home/state/$id.meta"
      printf zsh > "$dir/fake/command"
    fi
    : > "$dir/fake/inventory-broken"
    snapshot_continuation_case "$dir"
    rc=0
    out=$(run_continuation_control "$dir" "$id" authorize-continuation) || rc=$?
    expect_code 0 "$rc" "unblocked $kind continuation clearance must not require a readable runtime endpoint"$'\n'"$out"
    assert_contains "$out" "continuation-authorized $id" "clearance should report the exact authorized task"
    assert_continuation_snapshot "$dir" "$id" 1
    [ "$(meta_field "$dir" "$id" recovery)" = '' ] || fail "clearance left reconciliation-only recovery recorded"
    [ "$(meta_field "$dir" "$id" continuation_required)" = preserve-this-custom-field ] \
      || fail "clearance removed an unrelated metadata field"
    rm "$dir/fake/inventory-broken"
    rc=0
    out=$(run_control "$dir" "$id" relaunch --note "explicitly cleared continuation") || rc=$?
    expect_code 0 "$rc" "future ordinary relaunch of the $state cleared owner should succeed"$'\n'"$out"
    [ "$(meta_field "$dir" "$id" recovery)" = '' ] || fail "ordinary replacement restored obsolete recovery restriction"
    assert_no_grep '# Current reconciliation-only recovery contract' "$dir/home/data/$id/launch-brief.md" \
      "ordinary replacement after clearance retained the recovery-only launch instructions"
    [ "$(cat "$dir/fake/command")" = claude ] || fail "cleared ordinary replacement did not launch"
  done
  pass "unblocked ship/scout clearance changes only recovery, sends no endpoint input, and permits later live/exited ordinary relaunch"
}

test_continuation_authorization_excludes_control_and_direct_replacements() {
  local dir id=rlclear-first ready release auth_pid out rc
  dir=$(new_case clear-first "$id")
  seed_continuation_case "$dir" "$id"
  printf zsh > "$dir/fake/command"
  cp "$dir/home/state/$id.meta" "$dir/meta-before"
  cp "$dir/home/data/backlog.md" "$dir/backlog-before"
  ready="$dir/admission-ready"
  release="$dir/admission-release"
  pause_continuation_admission "$dir"
  FM_FAKE_ADMISSION_READY="$ready" FM_FAKE_ADMISSION_RELEASE="$release" \
    run_continuation_control "$dir" "$id" authorize-continuation > "$dir/authorize.out" &
  # shellcheck disable=SC2031 # The parent just launched this child; $! is not inherited.
  auth_pid=$!
  await_fixture_ready "$ready" "$auth_pid" "continuation authorization" || {
    : > "$release"
    wait "$auth_pid" 2>/dev/null || true
    fail "could not stage continuation authorization under both locks"
  }
  [ -s "$dir/home/state/.control-$id.lock/pid" ] && [ -s "$dir/home/state/.meta-$id.lock/pid" ] || {
    : > "$release"
    wait "$auth_pid" 2>/dev/null || true
    fail "continuation admission did not hold lifecycle then metadata locks"
  }
  rc=0
  out=$(run_control "$dir" "$id" relaunch --note "must not interleave") || rc=$?
  if [ "$rc" != 1 ] || [[ "$out" != *"another lifecycle action is already running"* ]]; then
    : > "$release"
    wait "$auth_pid" 2>/dev/null || true
    fail "control replacement interleaved with continuation clearance: $rc: $out"
  fi
  rc=0
  out=$(run_spawn "$dir" "$id" --relaunch --harness claude) || rc=$?
  if [ "$rc" != 1 ] || [[ "$out" != *"another lifecycle action is already running"* ]]; then
    : > "$release"
    wait "$auth_pid" 2>/dev/null || true
    fail "direct replacement interleaved with continuation clearance: $rc: $out"
  fi
  cmp -s "$dir/meta-before" "$dir/home/state/$id.meta" || {
    : > "$release"
    wait "$auth_pid" 2>/dev/null || true
    fail "continuation metadata changed before its admission completed"
  }
  [ ! -s "$dir/fake/literal" ] || {
    : > "$release"
    wait "$auth_pid" 2>/dev/null || true
    fail "a replacement delivered launch bytes while continuation authorization held both locks"
  }
  : > "$release"
  wait "$auth_pid"; rc=$?
  expect_code 0 "$rc" "continuation authorization should finish after its deterministic admission release"$'\n'"$(cat "$dir/authorize.out")"
  [ "$(meta_field "$dir" "$id" recovery)" = '' ] || fail "serialized clearance left recovery recorded"
  cmp -s "$dir/backlog-before" "$dir/home/data/backlog.md" || fail "serialized clearance changed backlog admission"
  pass "continuation-first lifecycle/meta locking excludes both control and direct replacement through admission and publication"
}

test_control_and_direct_replacements_exclude_continuation_authorization() {
  local dir id entry ready release replacement_pid out rc
  for entry in control direct; do
    id="rlreplacement-first-$entry"
    dir=$(new_case "replacement-first-$entry" "$id")
    seed_continuation_case "$dir" "$id"
    printf zsh > "$dir/fake/command"
    ready="$dir/launch-ready"
    release="$dir/launch-release"
    if [ "$entry" = control ]; then
      FM_FAKE_TRACE_PREPARE="$ready" FM_FAKE_TRACE_RELEASE="$release" \
        run_control "$dir" "$id" relaunch --note "inherit reconciliation" > "$dir/replacement.out" &
    else
      FM_FAKE_TRACE_PREPARE="$ready" FM_FAKE_TRACE_RELEASE="$release" \
        run_spawn "$dir" "$id" --relaunch --harness claude > "$dir/replacement.out" &
    fi
    # shellcheck disable=SC2031 # Both branches launch a child in this parent before reading $!.
    replacement_pid=$!
    await_fixture_ready "$ready" "$replacement_pid" "$entry replacement" || {
      : > "$release"
      wait "$replacement_pid" 2>/dev/null || true
      fail "could not stage $entry replacement during launch preparation"
    }
    [ -s "$dir/home/state/.control-$id.lock/pid" ] && [ -s "$dir/home/state/.meta-$id.lock/pid" ] || {
      : > "$release"
      wait "$replacement_pid" 2>/dev/null || true
      fail "$entry replacement did not hold its lifecycle/meta locks during launch"
    }
    cp "$dir/home/state/$id.meta" "$dir/meta-during-launch"
    rc=0
    out=$(run_continuation_control "$dir" "$id" authorize-continuation) || rc=$?
    if [ "$rc" != 1 ] || [[ "$out" != *"another lifecycle action is already running"* ]]; then
      : > "$release"
      wait "$replacement_pid" 2>/dev/null || true
      fail "continuation authorization interleaved with $entry replacement: $rc: $out"
    fi
    cmp -s "$dir/meta-during-launch" "$dir/home/state/$id.meta" || {
      : > "$release"
      wait "$replacement_pid" 2>/dev/null || true
      fail "contended clearance changed the replacement's metadata"
    }
    : > "$release"
    wait "$replacement_pid"; rc=$?
    expect_code 0 "$rc" "$entry replacement should finish after deterministic launch release"$'\n'"$(cat "$dir/replacement.out")"
    [ "$(meta_field "$dir" "$id" recovery)" = reconcile-only ] || fail "$entry replacement converted recovery into continuation authority"
    rc=0
    out=$(run_continuation_control "$dir" "$id" authorize-continuation) || rc=$?
    expect_code 0 "$rc" "continuation authorization should succeed only after $entry replacement releases both locks"$'\n'"$out"
    [ "$(meta_field "$dir" "$id" recovery)" = '' ] || fail "post-replacement clearance did not remove recovery"
  done
  pass "control/direct replacement-first lifecycle/meta locking excludes clearance and inherits recovery until explicit later authorization"
}

test_away_branch_replacement_uses_relaunch_not_fresh_dispatch_admission() {
  local dir id mode out rc
  for mode in ordinary recovery held; do
    id="rlaway-replacement-$mode"
    dir=$(new_case "away-replacement-$mode" "$id")
    seed_continuation_case "$dir" "$id"
    if [ "$mode" != recovery ]; then
      sed '/^recovery=/d' "$dir/home/state/$id.meta" > "$dir/ordinary.meta"
      mv "$dir/ordinary.meta" "$dir/home/state/$id.meta"
    else
      printf zsh > "$dir/fake/command"
    fi
    if [ "$mode" != ordinary ]; then
      tasks-axi hold "$id" --reason "captain decision pending" --kind captain \
        --file "$dir/home/data/backlog.md" >/dev/null
    fi
    FM_HOME="$dir/home" "$ROOT/bin/fm-afk-contract.sh" enter --spend 3 >/dev/null \
      || fail "could not establish the away replacement fixture"
    cp "$dir/home/state/$id.meta" "$dir/meta-before"
    cp "$dir/home/data/backlog.md" "$dir/backlog-before"
    cp "$dir/home/data/$id/brief.md" "$dir/brief-before"
    rc=0
    out=$(FM_SUPERVISION_ACTOR=branch run_control "$dir" "$id" relaunch --note "replace under away posture without granting continuation") || rc=$?
    if [ "$mode" = held ]; then
      expect_code 1 "$rc" "away branch ordinary replacement must still refuse a held row"
      assert_contains "$out" "not dispatchable" "ordinary replacement admission must precede the away fresh-dispatch gate"
      cmp -s "$dir/meta-before" "$dir/home/state/$id.meta" || fail "held away replacement changed metadata"
      cmp -s "$dir/brief-before" "$dir/home/data/$id/brief.md" || fail "held away replacement changed instructions"
      [ ! -s "$dir/fake/literal" ] || fail "held away replacement sent launch bytes"
      [ ! -s "$dir/fake/keys" ] || fail "held away replacement sent preparation keys"
      [ "$(cat "$dir/fake/command")" = claude ] || fail "held away replacement stopped the live instruction owner"
    else
      expect_code 0 "$rc" "away branch $mode replacement of existing In-flight work should not require queued fresh work"$'\n'"$out"
      [ "$(cat "$dir/fake/command")" = claude ] || fail "away branch replacement did not restore the instruction owner"
      if [ "$mode" = recovery ]; then
        [ "$(meta_field "$dir" "$id" recovery)" = reconcile-only ] || fail "away replacement dropped reconciliation-only scope"
        assert_grep '# Current reconciliation-only recovery contract' "$dir/home/data/$id/launch-brief.md" \
          "away replacement did not inherit recovery-only instructions"
      else
        [ "$(meta_field "$dir" "$id" recovery)" = '' ] || fail "ordinary away replacement acquired an unsolicited recovery scope"
        assert_no_grep '# Current reconciliation-only recovery contract' "$dir/home/data/$id/launch-brief.md" \
          "ordinary away replacement acquired recovery-only instructions"
      fi
    fi
    cmp -s "$dir/backlog-before" "$dir/home/data/backlog.md" || fail "away replacement changed an existing In-flight row or hold"
    assert_not_contains "$out" "may dispatch only queued unblocked work" "replacement incorrectly entered the away fresh-dispatch gate"
  done
  pass "away branch replacement applies ordinary/recovery replacement admission without fresh queued-only dispatch"
}

# --- config/claude-launcher: every relaunch path starts claude through TeamClaude
#
# Each case selects TeamClaude for the home, drives one real relaunch path, and
# runs the launch command the pane received in a clean shell, so the proxy
# setting claude reports can only have come from teamclaude.

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
    # shellcheck disable=SC2031 # This subshell's own environment is the point.
    export PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
      HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
      FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-session-end-relaunch-lib.sh"
    fm_session_end_relaunch_scan "$dir/home/state" 300 || exit 1
    printf '%s\n' "$FM_SESSION_END_WAKE"
  )
}

test_teamclaude_reaches_tmux_relaunch_paths() {
  local dir out rc
  dir=$(new_case tc-tmux-spawn tc1)
  add_ship_task "$dir" tc1 claude
  enable_teamclaude "$dir"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" tc1 --relaunch --harness claude); rc=$?
  expect_code 0 "$rc" "a TeamClaude fm-spawn --relaunch should succeed"$'\n'"$out"
  fm_test_assert_teamclaude_launch "$dir/fakebin" "$(teamclaude_launch_line "$dir/fake/literal")" \
    "tmux fm-spawn --relaunch"

  dir=$(new_case tc-tmux-control tc2)
  add_ship_task "$dir" tc2 claude
  enable_teamclaude "$dir"
  out=$(run_control "$dir" tc2 relaunch --note "resume under TeamClaude"); rc=$?
  expect_code 0 "$rc" "a TeamClaude fm-control relaunch should succeed"$'\n'"$out"
  fm_test_assert_teamclaude_launch "$dir/fakebin" "$(teamclaude_launch_line "$dir/fake/literal")" \
    "tmux fm-control relaunch"

  dir=$(new_case tc-tmux-session-end tc3)
  add_ship_task "$dir" tc3 claude
  enable_teamclaude "$dir"
  arm_session_end "$dir" tc3
  printf 'zsh' > "$dir/fake/command"
  out=$(run_session_end_scan "$dir"); rc=$?
  expect_code 0 "$rc" "the session-end scan should succeed"$'\n'"$out"
  assert_contains "$out" "tc3 auto-relaunched after session-end" \
    "the session-end scan should relaunch the ended worker"
  fm_test_assert_teamclaude_launch "$dir/fakebin" "$(teamclaude_launch_line "$dir/fake/literal")" \
    "tmux session-end auto-relaunch"
  pass "config/claude-launcher=teamclaude: tmux fm-spawn --relaunch, fm-control relaunch, and session-end auto-relaunch reach claude through TeamClaude"
}

test_teamclaude_reaches_herdr_relaunch_paths() {
  local dir out rc
  herdr_case_or_skip tc-herdr-spawn tc4 || {
    echo "skip - herdr relaunch needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  enable_teamclaude "$dir"
  out=$(run_spawn "$dir" tc4 --relaunch --harness claude); rc=$?
  expect_code 0 "$rc" "a TeamClaude herdr fm-spawn --relaunch should succeed"$'\n'"$out"
  fm_test_assert_teamclaude_launch "$dir/fakebin" "$(cat "$dir/fake/launched-command")" \
    "herdr fm-spawn --relaunch"

  herdr_case_or_skip tc-herdr-control tc5 || return 0
  dir=$HERDR_CASE_DIR
  enable_teamclaude "$dir"
  rm -f "$dir/fake/herdr-stopped"
  out=$(run_control "$dir" tc5 relaunch --note "resume under TeamClaude"); rc=$?
  expect_code 0 "$rc" "a TeamClaude herdr fm-control relaunch should succeed"$'\n'"$out"
  fm_test_assert_teamclaude_launch "$dir/fakebin" "$(cat "$dir/fake/launched-command")" \
    "herdr fm-control relaunch"

  herdr_case_or_skip tc-herdr-session-end tc6 || return 0
  dir=$HERDR_CASE_DIR
  enable_teamclaude "$dir"
  rm -f "$dir/fake/herdr-stopped"
  arm_session_end "$dir" tc6
  out=$(run_session_end_scan "$dir"); rc=$?
  expect_code 0 "$rc" "the herdr session-end scan should succeed"$'\n'"$out"
  assert_contains "$out" "tc6 auto-relaunched after session-end" \
    "the session-end scan should relaunch the ended herdr worker"
  fm_test_assert_teamclaude_launch "$dir/fakebin" "$(cat "$dir/fake/launched-command")" \
    "herdr session-end auto-relaunch"
  pass "config/claude-launcher=teamclaude: herdr fm-spawn --relaunch, fm-control relaunch, and session-end auto-relaunch reach claude through TeamClaude"
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

test_teamclaude_reaches_secondmate_respawn_on_both_backends() {
  local dir out rc
  dir=$(new_case tc-tmux-secondmate tc7)
  printf 'window=fmses:fm-tc7\n' > "$dir/home/state/tc7.meta"
  add_teamclaude_secondmate "$dir" tc7
  printf '%s\n' "fm-tc7" > "$dir/fake/windows"
  enable_teamclaude "$dir"
  out=$(run_control "$dir" tc7 relaunch); rc=$?
  expect_code 0 "$rc" "a TeamClaude tmux secondmate relaunch should succeed"$'\n'"$out"
  fm_test_assert_teamclaude_launch "$dir/fakebin" "$(teamclaude_launch_line "$dir/fake/literal")" \
    "tmux secondmate respawn"

  herdr_case_or_skip tc-herdr-secondmate tc8 || {
    echo "skip - herdr relaunch needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  grep -E '^(window|backend|herdr_[a-z_]+)=' "$dir/home/state/tc8.meta" > "$dir/meta.endpoint"
  mv "$dir/meta.endpoint" "$dir/home/state/tc8.meta"
  add_teamclaude_secondmate "$dir" tc8
  enable_teamclaude "$dir"
  rm -f "$dir/fake/herdr-stopped"
  out=$(run_control "$dir" tc8 relaunch); rc=$?
  expect_code 0 "$rc" "a TeamClaude herdr secondmate relaunch should succeed"$'\n'"$out"
  fm_test_assert_teamclaude_launch "$dir/fakebin" "$(cat "$dir/fake/launched-command")" \
    "herdr secondmate respawn"
  pass "config/claude-launcher=teamclaude: a Claude second mate respawns through TeamClaude on tmux and herdr"
}

# A stopped proxy or a malformed launcher file must refuse while the old agent
# still runs: fm-spawn --relaunch would refuse too, but only after fm-control
# had already stopped it.
test_teamclaude_refusal_lands_before_the_old_agent_stops() {
  local dir out rc id=tc-stop
  dir=$(new_case tc-stopped "$id")
  add_ship_task "$dir" "$id" claude
  enable_teamclaude "$dir"
  cp "$dir/home/state/$id.meta" "$dir/meta-before"
  out=$(FM_FAKE_TEAMCLAUDE_STATUS=1 run_control "$dir" "$id" relaunch --note "proxy stopped"); rc=$?
  expect_code 1 "$rc" "a relaunch with the TeamClaude proxy stopped must refuse"
  assert_contains "$out" "proxy is not running" "the refusal should name the stopped proxy"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a stopped proxy must refuse before the running agent stops"
  [ ! -s "$dir/fake/literal" ] || fail "a stopped proxy must refuse before any lifecycle input is sent"
  cmp -s "$dir/meta-before" "$dir/home/state/$id.meta" || fail "a refused relaunch must leave the task record untouched"

  printf 'proxy\n' > "$dir/home/config/claude-launcher"
  out=$(run_control "$dir" "$id" relaunch --note "malformed launcher"); rc=$?
  expect_code 1 "$rc" "a relaunch with a malformed config/claude-launcher must refuse"
  assert_contains "$out" "the only accepted value is teamclaude" "the refusal should name the accepted value"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a malformed launcher file must refuse before the running agent stops"
  [ ! -s "$dir/fake/literal" ] || fail "a malformed launcher file must refuse before any lifecycle input is sent"
  pass "fm-control relaunch: a stopped TeamClaude proxy or malformed launcher file refuses before the old agent stops"
}

# A fresh herdr spawn needs no relaunch, but it shares this suite's herdr
# stub: the pane the stub's `tab create` mints reads back in the task's copy.
test_teamclaude_reaches_fresh_herdr_spawns() {
  local dir out rc
  command -v jq >/dev/null 2>&1 || {
    echo "skip - herdr spawn needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$(new_case tc-herdr-fresh tc9)
  make_herdr_stub "$dir"
  fm_fake_exit0 "$dir/fakebin" treehouse
  fm_git_worktree "$dir/proj" "$dir/wt" task-tc9
  fm_test_spawn_brief "$dir/home" tc9
  mkdir -p "$dir/home/projects"
  printf '%s' "$dir/wt" > "$dir/fake/cwd"
  printf '%s' "$dir/wt" > "$dir/fake/herdr-treehouse-worktree"
  printf '%s' '%9' > "$dir/fake/herdr-pane"
  enable_teamclaude "$dir"
  TASK_TMPS+=("/tmp/fm-tc9")
  out=$(run_spawn "$dir" tc9 "$dir/proj" claude --backend herdr --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "a TeamClaude fresh herdr spawn should succeed"$'\n'"$out"
  assert_contains "$(cat "$dir/fake/herdr-log")" "tab create" "the fresh spawn should open its own herdr tab"
  fm_test_assert_teamclaude_launch "$dir/fakebin" "$(cat "$dir/fake/launched-command")" \
    "fresh herdr ship spawn"

  dir=$(new_case tc-herdr-fresh-secondmate tc10)
  make_herdr_stub "$dir"
  printf '%s' '%9' > "$dir/fake/herdr-pane"
  add_teamclaude_secondmate "$dir" tc10
  rm "$dir/home/state/tc10.meta"
  enable_teamclaude "$dir"
  out=$(run_spawn "$dir" tc10 "$dir/tc10-home" --secondmate --backend herdr); rc=$?
  expect_code 0 "$rc" "a TeamClaude fresh herdr secondmate spawn should succeed"$'\n'"$out"
  fm_test_assert_teamclaude_launch "$dir/fakebin" "$(cat "$dir/fake/launched-command")" \
    "fresh herdr secondmate launch"
  pass "config/claude-launcher=teamclaude: fresh herdr ship and second mate launches reach claude through TeamClaude"
}

test_relaunch_reverifies_an_already_in_flight_item_instead_of_rewriting_it() {
  local dir out rc=0
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "skipped: tasks-axi is not installed, so the backlog transition is inert"
    return 0
  }
  fm_tasks_axi_compatible || {
    pass "skipped: installed tasks-axi predates ${FM_TASKS_AXI_MIN}, so dispatch refuses automatic backlog transitions"
    return 0
  }
  dir=$(new_case reverify rl40)
  add_ship_task "$dir" rl40 claude
  seed_backlog "$dir" rl40 in_flight
  break_tasks_axi_start "$dir"

  out=$(run_control "$dir" rl40 relaunch --note "picking the work back up") || rc=$?
  expect_code 0 "$rc" "a relaunch must not re-run a transition the row already reflects"$'\n'"$out"
  [ "$(backlog_state "$dir" rl40)" = in_flight ] \
    || fail "a relaunch changed an already In-flight item to $(backlog_state "$dir" rl40)"
  pass "relaunch re-reads the backlog item instead of blindly re-running the transition"
}

test_relaunch_moves_a_drifted_item_back_in_flight() {
  local dir out rc=0
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "skipped: tasks-axi is not installed, so the backlog transition is inert"
    return 0
  }
  fm_tasks_axi_compatible || {
    pass "skipped: installed tasks-axi predates ${FM_TASKS_AXI_MIN}, so dispatch refuses automatic backlog transitions"
    return 0
  }
  dir=$(new_case drifted rl41)
  add_ship_task "$dir" rl41 claude
  seed_backlog "$dir" rl41 queued

  out=$(run_control "$dir" rl41 relaunch --note "picking the work back up") || rc=$?
  expect_code 0 "$rc" "a relaunch onto a drifted item should succeed"$'\n'"$out"
  [ "$(backlog_state "$dir" rl41)" = in_flight ] \
    || fail "a relaunch left its item at $(backlog_state "$dir" rl41)"
  pass "relaunch heals an item that drifted out of In flight while the task stayed live"
}

if fm_tasks_axi_compatible; then
  test_held_relaunch_refuses_without_stopping_the_live_owner
  test_exited_owner_reconciliation_preserves_holds_dependencies_and_work
  test_session_end_replacement_cannot_convert_recovery_to_execution
  test_reconciliation_refuses_live_queued_and_unowned_dispatch
  test_blocked_relaunch_admission_is_shared_across_supported_harnesses
  test_herdr_held_owner_refusal_and_exited_reconciliation
  test_continuation_authorization_requires_the_lock_owning_main
  test_continuation_authorization_rejects_relaunch_options_and_arbitrary_input
  test_continuation_authorization_preserves_blocked_ordinary_admission
  test_continuation_authorization_requires_current_automatic_backlog_and_recovery
  test_continuation_authorization_only_clears_recovery_before_future_relaunch
  test_continuation_authorization_excludes_control_and_direct_replacements
  test_control_and_direct_replacements_exclude_continuation_authorization
  test_away_branch_replacement_uses_relaunch_not_fresh_dispatch_admission
else
  echo "skip - recovery admission fixtures require compatible tasks-axi"
fi

add_quota_recovery_task() {
  local dir=$1 id=$2 model=${3:-openai-codex/gpt-6-luna} meta
  add_ship_task "$dir" "$id" omp
  printf omp > "$dir/fake/command"
  printf omp > "$dir/fake/becomes"
  printf 'unfinished change\n' > "$dir/wt/unfinished.txt"
  meta=$(cat "$dir/home/state/$id.meta")
  meta=${meta/model=default/model=$model}
  if [ "$model" = openai-codex/gpt-6.1-sol ]; then
    meta=${meta/effort=default/effort=high}
  fi
  printf '%s\ndispatch_rule=rule_1\n' "$meta" > "$dir/home/state/$id.meta"
  mkdir -p "$dir/home/config"
  jq -n --arg model "$model" '{rules:[{when:"assigned work",
    use:({harness:"omp",model:$model,provider:"codex"} +
      (if $model=="openai-codex/gpt-6.1-sol" then {effort:"high"} else {} end)),
    fallback:(if $model=="openai-codex/gpt-6-luna" then
      [{harness:"omp",model:"openrouter/z-ai/glm-5.3-flash",effort:"high"}] else [] end)}]}' > "$dir/home/config/crew-dispatch.json"
  jq -n --argjson now "$(date +%s)" '{reports:[
    {provider:"openai-codex",fetchedAt:($now*1000),metadata:{meterStates:{chat:{allowed:false,limitReached:true}}}},
    {provider:"openai-codex",fetchedAt:($now*1000),metadata:{meterStates:{chat:{allowed:false,limitReached:true}}}}
  ]}' > "$dir/usage.json"
  cat > "$dir/fakebin/omp" <<'SH'
#!/usr/bin/env bash
case "$1" in
  usage) cat "$FM_FAKE_DIR/../usage.json" ;;
  models) printf '%s\n' '{"models":[{"provider":"openrouter","id":"z-ai/glm-5.3-flash","selector":"openrouter/z-ai/glm-5.3-flash"}]}' ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$dir/fakebin/omp"
  "$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" "$id" --state idle --source omp-ext --event quota-exhausted >/dev/null
}

make_quota_control_race_stub() {
  cat > "$1/fakebin/session-end-control" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" > "$FM_FAKE_DIR/race-selected"
case "$FM_FAKE_QUOTA_RACE" in
  operator)
    env -u FM_CONTROL_QUOTA_GEN -u FM_CONTROL_QUOTA_SEQ \
      "$FM_TEST_REAL_CONTROL" "$1" exit > "$FM_FAKE_DIR/race-exit-out" 2>&1 || exit $?
    ;;
  origin)
    printf 'gen=%s\n' "$FM_CONTROL_QUOTA_GEN" > "$FM_HOME/state/$1.control-exit"
    ;;
  stale)
    printf 'gen=stale-%s\n' "$1" > "$FM_HOME/state/$1.control-exit"
    ;;
  operator-hold)
    "${FM_TEST_REAL_CONTROL%/*}/fm-captain-hold.sh" hold "$1" \
      --reason "captain decision pending after quota selection" > "$FM_FAKE_DIR/race-hold-out" 2>&1 || exit $?
    cp "$FM_HOME/data/backlog.md" "$FM_FAKE_DIR/race-held-backlog"
    ;;
  captain-held)
    printf 'captain-held: awaiting the captain after quota selection\n' > "$FM_HOME/state/$1.status"
    ;;
  paused)
    printf 'paused: awaiting an upstream release after quota selection\n' > "$FM_HOME/state/$1.status"
    ;;
  inherited-pause)
    printf '%s\n' 'paused [key=release]: awaiting an upstream release' \
      'resolved [key=other]: unrelated decision answered' > "$FM_HOME/state/$1.status"
    ;;
  done|failed)
    printf '%s: task became terminal after quota selection\n' "$FM_FAKE_QUOTA_RACE" > "$FM_HOME/state/$1.status"
    ;;
  pending-close)
    printf 'pending authoritative close after quota selection\n' > "$FM_HOME/state/$1.backlog-close"
    ;;
  dangling-close)
    ln -s "$1.backlog-close-missing" "$FM_HOME/state/$1.backlog-close"
    ;;
  unproven-hold)
    mkdir "$FM_HOME/data/backlog.md"
    ;;
  *) exit 2 ;;
esac
cp "$FM_FAKE_DIR/literal" "$FM_FAKE_DIR/race-before-literal"
"$FM_TEST_REAL_CONTROL" "$@" > "$FM_FAKE_DIR/race-relaunch-out" 2>&1
rc=$?
printf '%s\n' "$rc" > "$FM_FAKE_DIR/race-relaunch-rc"
cat "$FM_FAKE_DIR/race-relaunch-out"
exit "$rc"
SH
  chmod +x "$1/fakebin/session-end-control"
}

add_independent_quota_lane() {
  local dir=$1 second=$2 id=$3
  cp "$second/home/state/$id.meta" "$second/home/state/$id.busy-gen" \
    "$second/home/state/$id.busy-state" "$dir/home/state/"
  cp -R "$second/home/data/$id" "$dir/home/data/"
  printf '%s\n' "fm-$id" >> "$dir/fake/windows"
  printf '%s\n' "$id" > "$dir/fake/second-id"
  printf '%s\n' "$second/fake" > "$dir/fake/second-fake"
  cp "$dir/fakebin/tmux" "$dir/fakebin/tmux-endpoint"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
stub="${BASH_SOURCE[0]%/*}/tmux-endpoint"
second_id=$(cat "$FM_FAKE_DIR/second-id")
previous=
for arg in "$@"; do
  if [ "$previous" = -t ]; then
    case "$arg" in
      *":fm-$second_id"|*":=fm-$second_id")
        export FM_FAKE_DIR="$(cat "$FM_FAKE_DIR/second-fake")"
        break
        ;;
    esac
  fi
  previous=$arg
done
exec "$stub" "$@"
SH
  chmod +x "$dir/fakebin/tmux"
}

test_quota_exit_cancellation_is_rechecked_after_scan_selection() {
  local dir publication cancellation id out rc gen marker_gen record
  local journal_before meta_before brief_before note_before real_mv
  real_mv=$(command -v mv)
  for publication in live unpublished published; do
    for cancellation in operator origin stale; do
      id="rl-quota-race-$publication-$cancellation"
      dir=$(new_case quota-control-race "$id")
      add_quota_recovery_task "$dir" "$id"
      gen=$(cat "$dir/home/state/$id.busy-gen")
      record=$(cat "$dir/home/state/$id.busy-state")
      case "$publication" in
        unpublished)
          make_mv_failure_stub "$dir"
          out=$(FM_REAL_MV="$real_mv" FM_FAKE_JOURNAL_PHASE_MV_FAIL=launching run_session_end_scan "$dir"); rc=$?
          expect_code 0 "$rc" "unpublished race setup must record its failed transaction: $out"
          assert_equals prior-record-kept "$(journal_field "$dir" "$id" rollback)" "unpublished race must retain its original record"
          ;;
        published)
          out=$(FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START=1 run_session_end_scan "$dir"); rc=$?
          expect_code 0 "$rc" "published race setup must record its failed transaction: $out"
          assert_equals none-new-record-kept "$(journal_field "$dir" "$id" rollback)" "published race must retain its replacement record"
          printf zsh > "$dir/fake/command"
          ;;
      esac
      assert_absent "$dir/home/state/$id.control-exit" "internal relaunch stop must not publish an explicit exit marker"
      marker_gen=$(meta_field "$dir" "$id" busy_gen)
      [ -n "$marker_gen" ] || marker_gen=$gen
      if [ "$publication" = published ]; then
        [ "$marker_gen" != "$gen" ] || fail "published race must distinguish current incarnation from quota origin"
      fi
      if [ "$publication" = live ] && [ "$cancellation" = stale ]; then
        printf 'busy_gen=stale-%s\n' "$id" >> "$dir/home/state/$id.meta"
        printf 'gen=stale-%s\n' "$id" > "$dir/home/state/$id.control-exit"
      fi
      journal_before=$(cat "$dir/home/state/$id.control-relaunch" 2>/dev/null || true)
      note_before=$(cat "$dir/home/state/$id.control-relaunch.note" 2>/dev/null || true)
      meta_before=$(cat "$dir/home/state/$id.meta")
      brief_before=$(cat "$dir/home/data/$id/brief.md")
      make_quota_control_race_stub "$dir"
      out=$(FM_REAL_MV="$real_mv" FM_TEST_SEAM=1 \
        FM_SESSION_END_CONTROL="$dir/fakebin/session-end-control" \
        FM_TEST_REAL_CONTROL="$CONTROL" FM_FAKE_QUOTA_RACE="$cancellation" \
        run_session_end_scan "$dir"); rc=$?
      expect_code 0 "$rc" "the selected quota race must finish its scan decision: $out"
      assert_contains "$(cat "$dir/fake/race-selected")" "$id relaunch --note" "the race seam must run only after selecting this lane"
      if [ "$cancellation" = stale ]; then
        assert_contains "$out" "$id auto-relaunched after quota exhaustion" "a stale marker must allow ordinary quota recovery"
        assert_equals complete "$(journal_field "$dir" "$id" phase)" "stale marker recovery must complete"
        assert_equals omp "$(cat "$dir/fake/command")" "stale marker recovery must serve its permitted replacement"
        assert_equals "$gen" "$(journal_field "$dir" "$id" quota_gen)" "stale marker recovery must preserve quota origin"
      else
        assert_contains "$out" "$id auto-relaunch failed after quota exhaustion" "selected cancellation must retain a failure report"
        if [ "$cancellation" = operator ]; then
          assert_contains "$(cat "$dir/fake/race-exit-out")" "$id harness=omp" "the actual operator exit must succeed before quota control"
          assert_equals "gen=$marker_gen" "$(cat "$dir/home/state/$id.control-exit")" "operator exit must cancel the owned incarnation"
          assert_equals zsh "$(cat "$dir/fake/command")" "a selected lane must stay stopped after operator exit"
          if [ "$publication" = live ]; then
            assert_contains "$(cat "$dir/fake/race-exit-out")" "stopped $id" "the live operator race must perform a successful stop"
            assert_absent "$dir/home/state/$id.busy-gen" "successful live exit must retire its busy generation"
            assert_absent "$dir/home/state/$id.busy-state" "successful live exit must retire its busy event"
          else
            assert_contains "$(cat "$dir/fake/race-exit-out")" "already-stopped $id" "journal operator exit must prove the selected incarnation is dead"
          fi
        else
          assert_equals "gen=$gen" "$(cat "$dir/home/state/$id.control-exit")" "origin cancellation must bind the selected quota origin"
        fi
        if [ "$publication" != live ] || [ "$cancellation" = origin ]; then
          assert_contains "$(cat "$dir/fake/race-relaunch-out")" "quota recovery cancelled by explicit exit" "validated quota control must consume the cancellation marker"
        fi
        assert_equals "$(cat "$dir/fake/race-before-literal")" "$(cat "$dir/fake/literal")" "cancelled quota control must not type or launch"
        assert_equals "$journal_before" "$(cat "$dir/home/state/$id.control-relaunch" 2>/dev/null || true)" "cancelled quota control must not replace its journal"
        assert_equals "$note_before" "$(cat "$dir/home/state/$id.control-relaunch.note" 2>/dev/null || true)" "cancelled quota control must not replace its note"
        assert_equals "$meta_before" "$(cat "$dir/home/state/$id.meta")" "cancelled quota control must not replace metadata"
        assert_equals "$brief_before" "$(cat "$dir/home/data/$id/brief.md")" "cancelled quota control must not rewrite instructions"
        if [ "$publication" = live ]; then
          assert_absent "$dir/home/state/$id.control-relaunch" "live cancellation must not create a relaunch journal"
          assert_absent "$dir/home/state/$id.control-relaunch.note" "live cancellation must not create a relaunch note"
          if [ "$cancellation" = origin ]; then
            assert_equals "$record" "$(cat "$dir/home/state/$id.busy-state")" "origin cancellation must preserve the selected live event"
          fi
        fi
        if [ "$cancellation" = operator ]; then
          out=$(FM_REAL_MV="$real_mv" run_control "$dir" "$id" relaunch --note "explicitly resume after automatic cancellation"); rc=$?
          expect_code 0 "$rc" "manual relaunch must remain exempt from quota cancellation: $out"
          assert_equals complete "$(journal_field "$dir" "$id" phase)" "manual relaunch after cancellation must complete"
          assert_equals '' "$(journal_field "$dir" "$id" quota_gen)" "manual relaunch must not inherit cancelled quota provenance"
        fi
      fi
      assert_equals 'unfinished change' "$(cat "$dir/wt/unfinished.txt")" "the selection race must preserve uncommitted work"
    done
  done
  pass "quota control rechecks origin and current-incarnation exits after live and journal scan selection while stale markers and manual relaunch remain permitted"
}

test_quota_hold_and_status_are_rechecked_after_scan_selection() {
  local dir publication hold id out rc gen record command_before keys_before real_mv has_tasks=0 artifact
  local journal_before meta_before brief_before note_before meta_prior_before brief_prior_before
  real_mv=$(command -v mv)
  if command -v tasks-axi >/dev/null 2>&1 && fm_tasks_axi_compatible; then
    has_tasks=1
  else
    pass "skipped: operator hold selection race requires compatible tasks-axi"
  fi
  for publication in live unpublished published; do
    for hold in operator-hold captain-held paused inherited-pause done failed pending-close dangling-close unproven-hold; do
      [ "$hold" != operator-hold ] || [ "$has_tasks" = 1 ] || continue
      id="rl-quota-hold-$publication-$hold"
      dir=$(new_case quota-hold-race "$id")
      add_quota_recovery_task "$dir" "$id"
      gen=$(cat "$dir/home/state/$id.busy-gen")
      record=$(cat "$dir/home/state/$id.busy-state")
      case "$publication" in
        unpublished)
          make_mv_failure_stub "$dir"
          out=$(FM_REAL_MV="$real_mv" FM_FAKE_JOURNAL_PHASE_MV_FAIL=launching run_session_end_scan "$dir"); rc=$?
          expect_code 0 "$rc" "unpublished hold race setup must record its failed transaction: $out"
          assert_equals prior-record-kept "$(journal_field "$dir" "$id" rollback)" "unpublished hold race must retain its original record"
          ;;
        published)
          out=$(FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START=1 run_session_end_scan "$dir"); rc=$?
          expect_code 0 "$rc" "published hold race setup must record its failed transaction: $out"
          assert_equals none-new-record-kept "$(journal_field "$dir" "$id" rollback)" "published hold race must retain its replacement record"
          printf zsh > "$dir/fake/command"
          ;;
      esac
      [ ! -e "$dir/home/state/$id.backlog-close" ] && [ ! -L "$dir/home/state/$id.backlog-close" ] \
        || fail "pending close must not exist before quota selection"
      if [ "$hold" = operator-hold ]; then
        seed_backlog "$dir" "$id" in_flight
      fi
      journal_before=$(cat "$dir/home/state/$id.control-relaunch" 2>/dev/null || true)
      note_before=$(cat "$dir/home/state/$id.control-relaunch.note" 2>/dev/null || true)
      meta_prior_before=$(cat "$dir/home/state/$id.control-relaunch.meta-prior" 2>/dev/null || true)
      brief_prior_before=$(cat "$dir/home/state/$id.control-relaunch.brief-prior" 2>/dev/null || true)
      meta_before=$(cat "$dir/home/state/$id.meta")
      brief_before=$(cat "$dir/home/data/$id/brief.md")
      command_before=$(cat "$dir/fake/command")
      keys_before=$(cat "$dir/fake/keys")
      make_quota_control_race_stub "$dir"
      out=$(FM_REAL_MV="$real_mv" FM_TEST_SEAM=1 \
        FM_SESSION_END_CONTROL="$dir/fakebin/session-end-control" \
        FM_TEST_REAL_CONTROL="$CONTROL" FM_FAKE_QUOTA_RACE="$hold" \
        run_session_end_scan "$dir"); rc=$?
      expect_code 0 "$rc" "the selected quota hold race must finish its scan decision: $out"
      assert_contains "$(cat "$dir/fake/race-selected")" "$id relaunch --note" "the hold must arrive after selecting this lane"
      assert_contains "$out" "$id auto-relaunch failed after quota exhaustion" "selected hold must retain a refusal report"
      assert_equals 1 "$(cat "$dir/fake/race-relaunch-rc")" "locked quota recovery must refuse the selected hold"
      case "$hold" in
        operator-hold|unproven-hold)
          assert_contains "$(cat "$dir/fake/race-relaunch-out")" "requires a proven absence of an open captain hold" "open or unreadable captain hold must fail closed"
          ;;
        captain-held|paused|inherited-pause)
          assert_contains "$(cat "$dir/fake/race-relaunch-out")" "paused or captain-held task" "status wait must still prevent automatic recovery"
          ;;
        done|failed)
          assert_contains "$(cat "$dir/fake/race-relaunch-out")" "terminal task" "terminal status must still prevent automatic recovery"
          ;;
        pending-close|dangling-close)
          assert_equals "error: quota recovery refused for pending authoritative close of $id" "$(cat "$dir/fake/race-relaunch-out")" "pending authoritative close must prevent automatic recovery"
          if [ "$hold" = pending-close ]; then
            [ -f "$dir/home/state/$id.backlog-close" ] && [ ! -L "$dir/home/state/$id.backlog-close" ] \
              || fail "refused quota recovery must preserve a regular pending-close marker"
            assert_equals 'pending authoritative close after quota selection' "$(cat "$dir/home/state/$id.backlog-close")" "refused quota recovery must preserve the pending-close marker"
          else
            [ -L "$dir/home/state/$id.backlog-close" ] && [ ! -e "$dir/home/state/$id.backlog-close" ] \
              || fail "refused quota recovery must preserve a dangling pending-close symlink"
            assert_equals "$id.backlog-close-missing" "$(readlink "$dir/home/state/$id.backlog-close")" "refused quota recovery must preserve the pending-close symlink target"
          fi
          ;;
      esac
      assert_equals "$(cat "$dir/fake/race-before-literal")" "$(cat "$dir/fake/literal")" "held quota recovery must not type or launch"
      assert_equals "$keys_before" "$(cat "$dir/fake/keys")" "held quota recovery must not interrupt or submit"
      assert_equals "$command_before" "$(cat "$dir/fake/command")" "held quota recovery must not stop or replace the agent"
      assert_equals "$journal_before" "$(cat "$dir/home/state/$id.control-relaunch" 2>/dev/null || true)" "held quota recovery must preserve its journal"
      assert_equals "$note_before" "$(cat "$dir/home/state/$id.control-relaunch.note" 2>/dev/null || true)" "held quota recovery must preserve its note"
      assert_equals "$meta_prior_before" "$(cat "$dir/home/state/$id.control-relaunch.meta-prior" 2>/dev/null || true)" "held quota recovery must not checkpoint metadata"
      assert_equals "$brief_prior_before" "$(cat "$dir/home/state/$id.control-relaunch.brief-prior" 2>/dev/null || true)" "held quota recovery must not preserve new instruction backups"
      assert_equals "$meta_before" "$(cat "$dir/home/state/$id.meta")" "held quota recovery must preserve metadata"
      assert_equals "$brief_before" "$(cat "$dir/home/data/$id/brief.md")" "held quota recovery must preserve instructions"
      assert_equals 'unfinished change' "$(cat "$dir/wt/unfinished.txt")" "held quota recovery must preserve uncommitted work"
      if [ "$hold" = operator-hold ]; then
        assert_equals "$id" "$(cat "$dir/fake/race-hold-out")" "the real operator hold must succeed after selection"
        cmp -s "$dir/fake/race-held-backlog" "$dir/home/data/backlog.md" || fail "held quota recovery mutated the operator-held backlog"
      fi
      if [ "$publication" = live ]; then
        for artifact in control-relaunch control-relaunch.note control-relaunch.meta-prior control-relaunch.brief-prior; do
          assert_absent "$dir/home/state/$id.$artifact" "held current-event recovery must create no transaction artifacts"
        done
        assert_equals "$gen" "$(cat "$dir/home/state/$id.busy-gen")" "held current-event recovery must preserve its generation"
        assert_equals "$record" "$(cat "$dir/home/state/$id.busy-state")" "held current-event recovery must preserve its event"
        if [ "$hold" = captain-held ]; then
          out=$(run_control "$dir" "$id" relaunch --note "manually resume the held task"); rc=$?
          expect_code 0 "$rc" "manual relaunch must remain exempt from automatic status hold checks: $out"
          assert_equals complete "$(journal_field "$dir" "$id" phase)" "manual held relaunch must complete"
          assert_equals '' "$(journal_field "$dir" "$id" quota_gen)" "manual held relaunch must not inherit quota provenance"
        fi
      fi
    done
  done
  pass "quota control rechecks captain holds, unreadable holds, inherited pauses, terminal status and pending closes after live and journal selection without lifecycle mutations"
}

test_quota_scan_stops_after_failed_published_or_confirmed_replacement() {
  local dir second failure first_id second_id out rc real_mv second_meta second_gen second_record
  real_mv=$(command -v mv)
  for failure in transport complete-journal; do
    first_id="rl-quota-bound-00-$failure"
    second_id="rl-quota-bound-01-$failure"
    dir=$(new_case quota-replacement-bound "$first_id")
    add_quota_recovery_task "$dir" "$first_id"
    second=$(new_case quota-replacement-second "$second_id")
    add_quota_recovery_task "$second" "$second_id"
    add_independent_quota_lane "$dir" "$second" "$second_id"
    second_meta=$(cat "$dir/home/state/$second_id.meta")
    second_gen=$(cat "$dir/home/state/$second_id.busy-gen")
    second_record=$(cat "$dir/home/state/$second_id.busy-state")
    case "$failure" in
      transport)
        out=$(FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START=1 run_session_end_scan "$dir"); rc=$?
        ;;
      complete-journal)
        make_mv_failure_stub "$dir"
        out=$(FM_REAL_MV="$real_mv" FM_FAKE_COMPLETE_JOURNAL_MV_FAIL=1 run_session_end_scan "$dir"); rc=$?
        ;;
    esac
    expect_code 0 "$rc" "a failed durable publication must complete its scan decision: $out"
    assert_contains "$out" "$first_id auto-relaunch failed after quota exhaustion" "the failed first replacement must retain its failure report"
    assert_not_contains "$out" "$second_id" "the first replacement failure must not be replaced by a second lane's report"
    assert_equals omp "$(cat "$dir/fake/command")" "the failed first transaction must leave its replacement alive"
    assert_equals openai-codex/gpt-6-luna "$(meta_field "$dir" "$first_id" model)" "unknown adopted authentication must retain the first transaction's route"
    assert_equals "$(meta_field "$dir" "$first_id" control_relaunch_tx)" "$(journal_field "$dir" "$first_id" relaunch_tx)" "the first failed transaction must own its published record"
    if [ "$failure" = transport ]; then
      assert_equals none-new-record-kept "$(journal_field "$dir" "$first_id" rollback)" "transport failure must retain the published live replacement"
    else
      assert_equals none-new-agent-confirmed "$(journal_field "$dir" "$first_id" rollback)" "completion publication failure must retain the confirmed replacement"
    fi
    assert_no_grep $'\trelaunched' "$dir/home/state/.session-end-relaunch-$first_id" "a failed first transaction must not be ledgered as successful"
    assert_contains "$(cat "$dir/home/state/.session-end-relaunch-$first_id")" $'\tfailed' "the first transaction must retain its failed ledger outcome"
    assert_absent "$dir/home/state/.session-end-relaunch-$second_id" "a scan with one replacement must not attempt or ledger its second lane"
    assert_absent "$dir/home/state/.session-end-handled-$second_id" "a scan with one replacement must not mark its second lane handled"
    assert_absent "$dir/home/state/$second_id.control-relaunch" "a scan with one replacement must not begin its second transaction"
    assert_absent "$second/fake/launch" "the independently live second endpoint must not receive a launch"
    assert_equals '' "$(cat "$second/fake/literal")" "the independently live second endpoint must not receive lifecycle text"
    assert_equals omp "$(cat "$second/fake/command")" "the second lane's original worker must remain alive"
    assert_equals "$second_meta" "$(cat "$dir/home/state/$second_id.meta")" "the second lane's record must remain unchanged"
    assert_equals "$second_gen" "$(cat "$dir/home/state/$second_id.busy-gen")" "the second lane's generation must remain unchanged"
    assert_equals "$second_record" "$(cat "$dir/home/state/$second_id.busy-state")" "the second lane's eligible quota event must remain unchanged"
    out=$(FM_REAL_MV="$real_mv" run_session_end_scan "$dir"); rc=$?
    expect_code 0 "$rc" "the next scan must recover the still-eligible independent second lane: $out"
    assert_contains "$out" "$second_id auto-relaunched after quota exhaustion" "the second lane must have been eligible independently of the first endpoint"
    assert_equals complete "$(journal_field "$dir" "$second_id" phase)" "the second lane must complete on its own scan"
    assert_contains "$(cat "$dir/home/state/.wake-queue")" "$first_id auto-relaunch failed after quota exhaustion" "the original failed replacement report must remain durable"
    assert_equals 'unfinished change' "$(cat "$dir/wt/unfinished.txt")" "the first failed replacement must preserve work"
    assert_equals 'unfinished change' "$(cat "$second/wt/unfinished.txt")" "the second deferred replacement must preserve work"
  done
  pass "one quota scan never launches or ledgers a second lane after a published live or confirmed replacement fails"
}

test_live_quota_retries_after_initial_pre_stop_failure() {
  local dir id rejected_phase recovery out rc gen seq record expected_phase before real_mv
  real_mv=$(command -v mv)
  for rejected_phase in noted stopping; do
    for recovery in scan direct; do
      id="rl-live-$rejected_phase-$recovery"
      dir=$(new_case live-quota "$id")
      add_quota_recovery_task "$dir" "$id"
      gen=$(cat "$dir/home/state/$id.busy-gen")
      record=$(cat "$dir/home/state/$id.busy-state")
      seq=${record#*seq=}
      seq=${seq%% *}
      before=$(cat "$dir/home/data/$id/brief.md")
      make_mv_failure_stub "$dir"
      out=$(FM_REAL_MV="$real_mv" FM_FAKE_JOURNAL_PHASE_MV_FAIL="$rejected_phase" run_session_end_scan "$dir"); rc=$?
      expect_code 0 "$rc" "the scan must record the initial live failure: $out"
      assert_contains "$out" 'auto-relaunch failed after quota exhaustion' "initial live retry must reach control"
      if [ "$rejected_phase" = noted ]; then expected_phase=checkpoint; else expected_phase=noted; fi
      assert_equals "failed:$expected_phase" "$(journal_field "$dir" "$id" phase)" "failure must retain its durable pre-stop phase"
      assert_equals instructions-restored "$(journal_field "$dir" "$id" rollback)" "failure must restore instructions"
      assert_equals "$before" "$(cat "$dir/home/data/$id/brief.md")" "live worker instructions must remain unchanged"
      assert_equals omp "$(cat "$dir/fake/command")" "pre-stop failure must leave the original worker alive"
      assert_equals "$gen" "$(cat "$dir/home/state/$id.busy-gen")" "pre-stop failure must preserve generation"
      assert_equals "$record" "$(cat "$dir/home/state/$id.busy-state")" "pre-stop failure must preserve event sequence"
      assert_no_grep /quit "$dir/fake/literal" "pre-stop failure must not stop the worker"
      if [ "$recovery" = scan ]; then
        out=$(FM_REAL_MV="$real_mv" run_session_end_scan "$dir"); rc=$?
        assert_contains "$out" 'auto-relaunched after quota exhaustion' "scan must recover the still-current live event"
      else
        out=$(FM_REAL_MV="$real_mv" FM_CONTROL_QUOTA_GEN="$gen" FM_CONTROL_QUOTA_SEQ="$seq" \
          run_control "$dir" "$id" relaunch --note "retry the original live quota event"); rc=$?
        assert_contains "$out" "relaunched $id" "direct caller must recover the still-current live event"
      fi
      expect_code 0 "$rc" "live pre-stop recovery must succeed: $out"
      assert_equals complete "$(journal_field "$dir" "$id" phase)" "live retry must complete"
      assert_equals "$gen" "$(journal_field "$dir" "$id" quota_gen)" "live retry must keep quota origin"
      assert_equals "$seq" "$(journal_field "$dir" "$id" quota_seq)" "live retry must keep quota sequence"
      assert_equals openai-codex/gpt-6-luna "$(meta_field "$dir" "$id" model)" "live retry must retain the route when adopted authentication is unknown"
      assert_equals 'unfinished change' "$(cat "$dir/wt/unfinished.txt")" "live retry must preserve work"
      [ "$(cat "$dir/home/state/$id.busy-gen")" != "$gen" ] || fail "live retry revived the original generation"
    done
  done
  pass "initial live checkpoint/noted quota rollback remains retryable by scan and direct control"
}

test_relaunch_records_the_operator_selected_served_profile() {
  local dir id outcome out rc real_mv
  real_mv=$(command -v mv)
  for outcome in complete transport complete-journal; do
    id="rl-served-$outcome"
    dir=$(new_case served-profile "$id")
    add_quota_recovery_task "$dir" "$id"
    make_mv_failure_stub "$dir"
    case "$outcome" in
      complete) out=$(FM_REAL_MV="$real_mv" run_control "$dir" "$id" relaunch \
        --model openrouter/z-ai/glm-5.3-flash --effort high --note "serve the operator-selected declared stand-in"); rc=$? ;;
      transport) out=$(FM_REAL_MV="$real_mv" FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START=1 \
        run_control "$dir" "$id" relaunch --model openrouter/z-ai/glm-5.3-flash \
        --effort high --note "retain the published operator-selected profile"); rc=$? ;;
      complete-journal) out=$(FM_REAL_MV="$real_mv" FM_FAKE_COMPLETE_JOURNAL_MV_FAIL=1 \
        run_control "$dir" "$id" relaunch --model openrouter/z-ai/glm-5.3-flash \
        --effort high --note "retain the confirmed operator-selected profile"); rc=$? ;;
    esac
    assert_equals omp "$(meta_field "$dir" "$id" harness)" "spawn must publish served harness"
    assert_equals openrouter/z-ai/glm-5.3-flash "$(meta_field "$dir" "$id" model)" "spawn must publish the operator-selected model"
    assert_equals high "$(meta_field "$dir" "$id" effort)" "spawn must publish the operator-selected effort"
    assert_equals omp "$(journal_field "$dir" "$id" to_harness)" "journal must name served harness"
    assert_equals openrouter/z-ai/glm-5.3-flash "$(journal_field "$dir" "$id" to_model)" "journal must name served model"
    assert_equals high "$(journal_field "$dir" "$id" to_effort)" "journal must name served effort"
    assert_equals "$(meta_field "$dir" "$id" control_relaunch_tx)" "$(journal_field "$dir" "$id" relaunch_tx)" "published metadata must bind journal transaction"
    if [ "$outcome" = complete ]; then
      expect_code 0 "$rc" "operator-selected profile must complete: $out"
      assert_contains "$out" 'model=openrouter/z-ai/glm-5.3-flash effort=high' "success must report the actual served profile"
      assert_equals complete "$(journal_field "$dir" "$id" phase)" "operator-selected profile must complete the journal"
    else
      expect_code 1 "$rc" "published failure must remain a failure: $out"
      assert_equals failed:launching "$(journal_field "$dir" "$id" phase)" "published failure must retain durable phase"
      if [ "$outcome" = transport ]; then
        assert_equals none-new-record-kept "$(journal_field "$dir" "$id" rollback)" "transport failure must retain published profile"
      else
        assert_equals none-new-agent-confirmed "$(journal_field "$dir" "$id" rollback)" "complete journal failure must retain confirmed profile"
      fi
    fi
  done
  pass "control records the actual operator-selected serving profile in successful and failed-publication transactions"
}

test_operator_selected_stand_in_preserves_launch_delivery_declarations() {
  local dir id event declaration expected out rc
  for event in done failed paused; do
    id="rl-fallback-$event"
    dir=$(new_case fallback-declaration "$id")
    add_quota_recovery_task "$dir" "$id"
    declaration="$event [at=2026-10-06T00:00:00Z]: replacement declared $event during launch delivery"
    expected="$dir/expected.status"
    printf '%s\n' "$declaration" > "$expected"

    out=$(FM_FAKE_LAUNCH_STATUS_PATH="$dir/home/state/$id.status" \
      FM_FAKE_LAUNCH_STATUS_EVENT="$declaration" \
      run_control "$dir" "$id" relaunch --model openrouter/z-ai/glm-5.3-flash \
        --effort high --note "serve the operator-selected declared stand-in")
    rc=$?
    expect_code 0 "$rc" "$event declaration must not fail operator-selected relaunch: $out"
    assert_equals omp "$(meta_field "$dir" "$id" harness)" "relaunch must publish the served harness"
    assert_equals openrouter/z-ai/glm-5.3-flash "$(meta_field "$dir" "$id" model)" "relaunch must publish the served model"
    assert_equals high "$(meta_field "$dir" "$id" effort)" "relaunch must publish the served effort"
    assert_equals complete "$(journal_field "$dir" "$id" phase)" "operator-selected relaunch must complete its transaction"
    assert_equals openrouter/z-ai/glm-5.3-flash "$(journal_field "$dir" "$id" to_model)" "journal must record the served stand-in"
    [ -s "$dir/fake/launch" ] || fail "$event declaration must come from an actual launch"
    cmp -s "$expected" "$dir/home/state/$id.status" || fail "spawn or control relaunch changed the $event declaration"
    assert_equals "$declaration" "$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_current_line "$2" ship' \
      bash "$ROOT" "$dir/home/state/$id.status")" "the $event declaration must remain authoritative"
  done
  pass "real control relaunches onto operator-selected declared stand-ins preserve done, failed, and paused launch-delivery declarations"
}

test_quota_recovery_retries_real_stop_then_failed_launch() {
  local dir failure id out rc gen seq record now attempt_count literal_before
  local real_mv
  real_mv=$(command -v mv)
  for failure in prelaunch stopping exited postarm; do
    id="rl-quota-$failure"
    dir=$(new_case quota-partial "$id")
    add_quota_recovery_task "$dir" "$id"
    gen=$(cat "$dir/home/state/$id.busy-gen")
    record=$(cat "$dir/home/state/$id.busy-state")
    seq=${record#*seq=}
    seq=${seq%% *}
    now=$(date +%s)
    printf '%s\tattempt\n%s\tattempt\n%s\tattempt\n' "$now" "$((now - 1900))" "$((now - 4000))" \
      > "$dir/home/state/.session-end-relaunch-$id"
    printf '%s\t%s\tfailed\n' "$gen" "$seq" > "$dir/home/state/.session-end-handled-$id"
    case "$failure" in
      prelaunch)
        printf '%s' "$dir/proj" > "$dir/fake/cwd"
        out=$(run_session_end_scan "$dir"); rc=$?
        ;;
      stopping)
        out=$(FM_FAKE_EXIT_TRANSPORT_FAIL_AFTER_STOP=1 run_session_end_scan "$dir"); rc=$?
        ;;
      exited)
        make_mv_failure_stub "$dir"
        out=$(FM_REAL_MV="$real_mv" FM_FAKE_JOURNAL_PHASE_MV_FAIL=launching run_session_end_scan "$dir"); rc=$?
        ;;
      postarm)
        make_mv_failure_stub "$dir"
        out=$(FM_REAL_MV="$real_mv" FM_FAKE_META_PUBLISH_MV_FAIL="$dir/home/state/$id.meta" run_session_end_scan "$dir"); rc=$?
        ;;
    esac
    expect_code 0 "$rc" "the scan must record a failed real quota transaction: $out"
    assert_contains "$out" 'auto-relaunch failed after quota exhaustion' "$failure must fail after the real stop"
    assert_equals zsh "$(cat "$dir/fake/command")" "$failure must leave no running worker"
    assert_equals "$gen" "$(journal_field "$dir" "$id" quota_gen)" "$failure must retain the quota generation"
    assert_equals "$seq" "$(journal_field "$dir" "$id" quota_seq)" "$failure must retain the quota sequence"
    if [ "$failure" = stopping ]; then
      assert_equals failed:stopping "$(journal_field "$dir" "$id" phase)" "stop transport rollback must retain its phase"
      assert_equals prior-record-kept-agent-dead "$(journal_field "$dir" "$id" rollback)" "stop transport rollback must prove death"
    else
      assert_absent "$dir/home/state/$id.busy-gen" "$failure must not resurrect the stopped generation"
      assert_absent "$dir/home/state/$id.busy-state" "$failure must not synthesize a retry busy record"
      assert_equals prior-record-kept "$(journal_field "$dir" "$id" rollback)" "$failure must keep the durable record"
      if [ "$failure" = exited ]; then
        assert_equals failed:exited "$(journal_field "$dir" "$id" phase)" "failed launch journal advancement must retain exited"
      fi
    fi
    printf 'x_request=preserved-%s\n' "$id" >> "$dir/home/state/$id.meta"
    printf '%s' "$dir/wt" > "$dir/fake/cwd"
    out=$(FM_REAL_MV="$real_mv" run_session_end_scan "$dir"); rc=$?
    expect_code 0 "$rc" "the next scan must retry a dead partial quota transaction: $out"
    assert_contains "$out" 'auto-relaunched after quota exhaustion' "$failure must recover despite the attempt caps"
    assert_equals complete "$(journal_field "$dir" "$id" phase)" "$failure retry must complete"
    assert_equals "$gen" "$(journal_field "$dir" "$id" quota_gen)" "$failure retry must retain the original identity"
    assert_equals "$seq" "$(journal_field "$dir" "$id" quota_seq)" "$failure retry must retain the original sequence"
    assert_equals "$(printf '%s\t%s\trelaunched' "$gen" "$seq")" \
      "$(cat "$dir/home/state/.session-end-handled-$id")" "$failure retry must handle the stable identity"
    assert_equals "preserved-$id" "$(meta_field "$dir" "$id" x_request)" "retry must retain concurrent metadata"
    assert_equals 'unfinished change' "$(cat "$dir/wt/unfinished.txt")" "retry must retain work"
    [ "$(cat "$dir/home/state/$id.busy-gen")" != "$gen" ] || fail "retry resurrected the retired generation"
    attempt_count=$(awk -F '\t' '$2 == "attempt" {n++} END {print n}' "$dir/home/state/.session-end-relaunch-$id")
    assert_equals 5 "$attempt_count" "failed transaction and successful retry must both be ledgered"
    literal_before=$(cat "$dir/fake/literal")
    out=$(FM_REAL_MV="$real_mv" run_session_end_scan "$dir"); rc=$?
    expect_code 0 "$rc" "the post-success scan must succeed"
    assert_equals '' "$out" "the handled quota transaction must not wake again"
    assert_equals "$literal_before" "$(cat "$dir/fake/literal")" "the handled quota transaction must not launch again"
  done
  pass "quota recovery retries proven-dead real stopping, exited, launching and post-arm failures without resurrecting busy state"
}

test_explicit_exit_cancels_partial_quota_recovery() {
  local dir failure id out rc gen marker_gen journal_before literal_before meta_before real_mv
  real_mv=$(command -v mv)
  for failure in stopping exited retired-meta postarm published; do
    id="rl-quota-exit-$failure"
    dir=$(new_case quota-explicit-exit "$id")
    add_quota_recovery_task "$dir" "$id"
    gen=$(cat "$dir/home/state/$id.busy-gen")
    if [ "$failure" = retired-meta ]; then
      printf 'busy_gen=%s\n' "$gen" >> "$dir/home/state/$id.meta"
    fi
    case "$failure" in
      stopping)
        out=$(FM_FAKE_EXIT_TRANSPORT_FAIL_AFTER_STOP=1 run_session_end_scan "$dir"); rc=$?
        ;;
      exited|retired-meta)
        make_mv_failure_stub "$dir"
        out=$(FM_REAL_MV="$real_mv" FM_FAKE_JOURNAL_PHASE_MV_FAIL=launching run_session_end_scan "$dir"); rc=$?
        ;;
      postarm)
        make_mv_failure_stub "$dir"
        out=$(FM_REAL_MV="$real_mv" FM_FAKE_META_PUBLISH_MV_FAIL="$dir/home/state/$id.meta" run_session_end_scan "$dir"); rc=$?
        ;;
      published)
        out=$(FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START=1 run_session_end_scan "$dir"); rc=$?
        ;;
    esac
    expect_code 0 "$rc" "quota scan must record the partial failure: $out"
    assert_contains "$out" 'auto-relaunch failed after quota exhaustion' "$failure must reach the real recovery transaction"
    assert_absent "$dir/home/state/$id.control-exit" "internal relaunch stop must not cancel recovery"
    marker_gen=$(meta_field "$dir" "$id" busy_gen)
    [ -n "$marker_gen" ] || marker_gen=$gen
    journal_before=$(cat "$dir/home/state/$id.control-relaunch")
    meta_before=$(cat "$dir/home/state/$id.meta")
    out=$(run_control "$dir" "$id" exit); rc=$?
    expect_code 0 "$rc" "explicit exit must succeed after $failure: $out"
    if [ "$failure" = published ]; then
      assert_contains "$out" stopped "explicit exit must stop the published replacement"
      [ "$marker_gen" != "$gen" ] || fail "published cancellation must bind the replacement generation"
    else
      assert_contains "$out" already-stopped "dead partial recovery must be an idempotent exit"
    fi
    assert_equals "gen=$marker_gen" "$(cat "$dir/home/state/$id.control-exit")" "exit must mark the owned recovery incarnation"
    literal_before=$(cat "$dir/fake/literal")
    printf '%s' "$dir/wt" > "$dir/fake/cwd"
    out=$(FM_REAL_MV="$real_mv" run_session_end_scan "$dir"); rc=$?
    expect_code 0 "$rc" "scan after explicit exit must succeed: $out"
    assert_equals '' "$out" "explicit exit must cancel partial quota retry"
    assert_equals "$literal_before" "$(cat "$dir/fake/literal")" "cancelled recovery must not launch a replacement"
    assert_equals "$journal_before" "$(cat "$dir/home/state/$id.control-relaunch")" "cancellation must preserve the failed journal"
    assert_equals "$meta_before" "$(cat "$dir/home/state/$id.meta")" "cancellation must preserve metadata"
    assert_equals 'unfinished change' "$(cat "$dir/wt/unfinished.txt")" "cancellation must preserve work"
    if [ "$failure" != stopping ]; then
      assert_absent "$dir/home/state/$id.busy-gen" "cancelled recovery must not resurrect a generation"
      assert_absent "$dir/home/state/$id.busy-state" "cancelled recovery must not resurrect a busy record"
    fi
  done
  pass "explicit exits cancel retired and published partial quota recovery without changing work or journals"
}

test_quota_published_failure_retries_only_its_dead_transaction() {
  local dir id=rl-quota-published out rc gen seq record tx literal_before
  dir=$(new_case quota-published "$id")
  add_quota_recovery_task "$dir" "$id"
  gen=$(cat "$dir/home/state/$id.busy-gen")
  record=$(cat "$dir/home/state/$id.busy-state")
  seq=${record#*seq=}
  seq=${seq%% *}
  out=$(FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START=1 run_session_end_scan "$dir"); rc=$?
  expect_code 0 "$rc" "postpublication quota failure must be recorded: $out"
  assert_contains "$out" 'auto-relaunch failed after quota exhaustion' "the transport seam must fail the transaction"
  assert_equals none-new-record-kept "$(journal_field "$dir" "$id" rollback)" "the published replacement must remain recorded"
  tx=$(meta_field "$dir" "$id" control_relaunch_tx)
  assert_equals "$tx" "$(journal_field "$dir" "$id" relaunch_tx)" "rollback must retain its publication transaction"
  literal_before=$(cat "$dir/fake/literal")
  out=$(run_session_end_scan "$dir"); rc=$?
  expect_code 0 "$rc" "a live published replacement must be skipped"
  assert_equals '' "$out" "a failed journal alone must not stop a live replacement"
  assert_equals "$literal_before" "$(cat "$dir/fake/literal")" "a live replacement must not receive lifecycle input"
  printf zsh > "$dir/fake/command"
  printf 'control_relaunch_tx=superseding\n' >> "$dir/home/state/$id.meta"
  out=$(run_session_end_scan "$dir"); rc=$?
  expect_code 0 "$rc" "an unrelated dead publication must be skipped"
  assert_equals '' "$out" "a stale transaction must not authorize recovery"
  printf 'control_relaunch_tx=%s\nx_request=published-concurrent\n' "$tx" >> "$dir/home/state/$id.meta"
  out=$(run_session_end_scan "$dir"); rc=$?
  expect_code 0 "$rc" "the matching dead published quota replacement must recover: $out"
  assert_contains "$out" 'auto-relaunched after quota exhaustion' "a matching dead publication must retry"
  assert_equals openai-codex/gpt-6-luna "$(meta_field "$dir" "$id" model)" "retry must retain the current route when adopted authentication is unknown"
  assert_equals published-concurrent "$(meta_field "$dir" "$id" x_request)" "retry must preserve published concurrent metadata"
  assert_equals "$gen" "$(journal_field "$dir" "$id" quota_gen)" "published retry must retain the quota origin"
  assert_equals "$seq" "$(journal_field "$dir" "$id" quota_seq)" "published retry must retain the quota sequence"
  assert_equals 'unfinished change' "$(cat "$dir/wt/unfinished.txt")" "published retry must preserve work"
  out=$(run_session_end_scan "$dir"); rc=$?
  expect_code 0 "$rc" "a completed published recovery must be skipped"
  assert_equals '' "$out" "completed recovery must deduplicate"
  pass "published quota recovery requires transaction match and a dead endpoint while retaining current metadata"
}

test_quota_live_published_replacement_handles_its_new_event() {
  local dir id=rl-quota-new-live out rc old_gen gen seq record tx
  dir=$(new_case quota-new-live "$id")
  add_quota_recovery_task "$dir" "$id"
  old_gen=$(cat "$dir/home/state/$id.busy-gen")
  out=$(FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START=1 run_session_end_scan "$dir"); rc=$?
  expect_code 0 "$rc" "postpublication quota failure must finish the scanner decision: $out"
  assert_contains "$out" 'auto-relaunch failed after quota exhaustion' "the transport seam must fail after starting the replacement"
  assert_equals failed:launching "$(journal_field "$dir" "$id" phase)" "the old quota transaction must remain a failed launch"
  assert_equals none-new-record-kept "$(journal_field "$dir" "$id" rollback)" "the failed launch must retain the published replacement"
  assert_equals omp "$(cat "$dir/fake/command")" "the published replacement must still be alive"
  tx=$(meta_field "$dir" "$id" control_relaunch_tx)
  assert_equals "$tx" "$(journal_field "$dir" "$id" relaunch_tx)" "the failed journal must match the live published replacement"
  gen=$(cat "$dir/home/state/$id.busy-gen")
  [ "$gen" != "$old_gen" ] || fail "the replacement must have a new busy generation"
  assert_equals "$gen" "$(meta_field "$dir" "$id" busy_gen)" "the replacement record must own its new busy generation"
  printf 'x_request=new-live-quota\n' >> "$dir/home/state/$id.meta"
  "$ROOT/bin/fm-busy-event.sh" apply "$dir/home/state" "$id" idle --gen "$gen" --source omp-ext --event quota-exhausted >/dev/null
  record=$(cat "$dir/home/state/$id.busy-state")
  seq=${record#*seq=}
  seq=${seq%% *}
  assert_contains "$record" "gen=$gen" "the fresh quota event must belong to the live replacement"
  assert_contains "$record" 'event=quota-exhausted' "the replacement must publish a fresh quota event"
  out=$(run_session_end_scan "$dir"); rc=$?
  expect_code 0 "$rc" "the live replacement's new quota event must be handled: $out"
  assert_contains "$out" "$id auto-relaunched after quota exhaustion" "the old failed journal must not hide the live replacement's new event"
  assert_equals complete "$(journal_field "$dir" "$id" phase)" "the new quota transaction must complete"
  assert_equals "$gen" "$(journal_field "$dir" "$id" quota_gen)" "the completed journal must bind the new generation rather than the failed origin"
  assert_equals "$seq" "$(journal_field "$dir" "$id" quota_seq)" "the completed journal must bind the fresh event sequence"
  assert_equals omp "$(cat "$dir/fake/command")" "the new quota recovery must leave a live replacement"
  assert_equals openai-codex/gpt-6-luna "$(meta_field "$dir" "$id" model)" "new recovery must retain the published model when adopted authentication is unknown"
  assert_equals default "$(meta_field "$dir" "$id" effort)" "new recovery must retain the published effort"
  assert_equals new-live-quota "$(meta_field "$dir" "$id" x_request)" "new recovery must preserve concurrent replacement metadata"
  assert_equals "$dir/wt" "$(meta_field "$dir" "$id" worktree)" "new recovery must retain the recorded worktree"
  assert_equals 'unfinished change' "$(cat "$dir/wt/unfinished.txt")" "new recovery must preserve unfinished work"
  out=$(run_session_end_scan "$dir"); rc=$?
  expect_code 0 "$rc" "the completed new quota recovery must deduplicate"
  assert_equals '' "$out" "the handled replacement quota event must not relaunch again"
  pass "a live published replacement handles its own fresh quota generation despite an older failed journal"
}

test_quota_retry_preserves_identity_after_pre_stop_failure() {
  local dir publication rejected_phase id out rc gen seq record current_gen tx real_mv expected_phase
  real_mv=$(command -v mv)
  for publication in unpublished published; do
    for rejected_phase in noted stopping; do
      id="rl-quota-retry-$publication-$rejected_phase"
      dir=$(new_case quota-retry "$id")
      add_quota_recovery_task "$dir" "$id"
      gen=$(cat "$dir/home/state/$id.busy-gen")
      record=$(cat "$dir/home/state/$id.busy-state")
      seq=${record#*seq=}
      seq=${seq%% *}
      if [ "$publication" = unpublished ]; then
        printf '%s' "$dir/proj" > "$dir/fake/cwd"
        out=$(run_session_end_scan "$dir"); rc=$?
        printf '%s' "$dir/wt" > "$dir/fake/cwd"
      else
        out=$(FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START=1 run_session_end_scan "$dir"); rc=$?
        printf zsh > "$dir/fake/command"
      fi
      expect_code 0 "$rc" "the initial quota transaction must record its partial failure: $out"
      assert_contains "$out" 'auto-relaunch failed after quota exhaustion' "the initial transaction must fail"
      current_gen=$(meta_field "$dir" "$id" busy_gen)
      tx=$(meta_field "$dir" "$id" control_relaunch_tx)
      make_mv_failure_stub "$dir"
      out=$(FM_REAL_MV="$real_mv" FM_FAKE_JOURNAL_PHASE_MV_FAIL="$rejected_phase" \
        run_session_end_scan "$dir"); rc=$?
      expect_code 0 "$rc" "the journal-backed retry must record its pre-stop failure: $out"
      assert_contains "$out" 'auto-relaunch failed after quota exhaustion' "the journal-backed retry must reach the phase seam"
      if [ "$rejected_phase" = noted ]; then expected_phase=checkpoint; else expected_phase=noted; fi
      assert_equals "failed:$expected_phase" "$(journal_field "$dir" "$id" phase)" "retry must record the last durable phase"
      assert_equals instructions-restored "$(journal_field "$dir" "$id" rollback)" "pre-stop failure must retain its prior instructions"
      assert_equals "$gen" "$(journal_field "$dir" "$id" quota_gen)" "failed retry must retain the quota origin"
      assert_equals "$seq" "$(journal_field "$dir" "$id" quota_seq)" "failed retry must retain the quota sequence"
      assert_equals "${current_gen:--}" "$(journal_field "$dir" "$id" from_busy_gen)" "retry must bind its current incarnation separately"
      assert_equals "${tx:--}" "$(journal_field "$dir" "$id" from_relaunch_tx)" "retry must retain the current publication binding"
      if [ "$publication" = unpublished ]; then
        assert_absent "$dir/home/state/$id.busy-gen" "unpublished failed retries must not resurrect busy state"
      else
        [ -n "$current_gen" ] && [ "$current_gen" != "$gen" ] || fail "published retry fixture did not arm a replacement generation"
        assert_equals "$current_gen" "$(cat "$dir/home/state/$id.busy-gen")" "failed retry must preserve the current replacement generation"
      fi
      printf 'x_request=retry-concurrent\n' >> "$dir/home/state/$id.meta"
      out=$(FM_REAL_MV="$real_mv" run_session_end_scan "$dir"); rc=$?
      expect_code 0 "$rc" "a failed pre-stop retry must remain retryable: $out"
      assert_contains "$out" 'auto-relaunched after quota exhaustion' "the next scan must recover the same quota transaction"
      assert_equals "$gen" "$(journal_field "$dir" "$id" quota_gen)" "successful retry must retain the original generation"
      assert_equals "$seq" "$(journal_field "$dir" "$id" quota_seq)" "successful retry must retain the original sequence"
      assert_equals retry-concurrent "$(meta_field "$dir" "$id" x_request)" "successful retry must retain concurrent metadata"
      assert_equals 'unfinished change' "$(cat "$dir/wt/unfinished.txt")" "successful retry must retain work"
      out=$(FM_REAL_MV="$real_mv" run_session_end_scan "$dir"); rc=$?
      expect_code 0 "$rc" "the successful repeated recovery must deduplicate"
      assert_equals '' "$out" "the successfully handled quota origin must not relaunch again"
    done
  done
  pass "unpublished and published quota retries survive checkpoint/noted rollback with separate stable origin and current incarnation bindings"
}

test_quota_confirmed_replacement_is_not_retried() {
  local dir id=rl-quota-confirmed out rc real_mv literal_before
  dir=$(new_case quota-confirmed "$id")
  add_quota_recovery_task "$dir" "$id"
  real_mv=$(command -v mv)
  make_mv_failure_stub "$dir"
  out=$(FM_REAL_MV="$real_mv" FM_FAKE_COMPLETE_JOURNAL_MV_FAIL=1 run_session_end_scan "$dir"); rc=$?
  expect_code 0 "$rc" "the scan must record the failed completion journal: $out"
  assert_equals none-new-agent-confirmed "$(journal_field "$dir" "$id" rollback)" "a confirmed replacement must remain confirmed"
  literal_before=$(cat "$dir/fake/literal")
  printf zsh > "$dir/fake/command"
  out=$(FM_REAL_MV="$real_mv" run_session_end_scan "$dir"); rc=$?
  expect_code 0 "$rc" "a confirmed transaction must be skipped even when its endpoint later dies"
  assert_equals '' "$out" "confirmed replacement must not be retried from its old quota journal"
  assert_equals "$literal_before" "$(cat "$dir/fake/literal")" "confirmed transaction must not launch again"
  pass "quota journal recovery never retries a confirmed replacement after completion persistence fails"
}

test_quota_exhaustion_relaunches_only_a_permitted_route() {
  local dir model id out rc declaration expected
  for model in openai-codex/gpt-6-luna openai-codex/gpt-6.1-sol; do
    id=rl-pool
    dir=$(new_case pooled-quota "$id")
    add_quota_recovery_task "$dir" "$id" "$model"
    declaration='done [at=2026-10-06T00:00:00Z]: replacement completed during launch delivery'
    expected="$dir/expected.status"
    printf '%s\n' "$declaration" > "$expected"
    mkdir -p "$dir/user-home"
    out=$(env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
      -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
      PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
      FM_WAKE_QUEUE="$dir/home/state/.wake-queue" \
      FM_FAKE_LAUNCH_STATUS_PATH="$dir/home/state/$id.status" \
      FM_FAKE_LAUNCH_STATUS_EVENT="$declaration" \
      HOME="$dir/user-home" FM_SPAWN_NO_GUARD=1 \
      FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 \
      bash -s -- "$ROOT" "$id" <<'SH'
. "$1/bin/fm-session-end-relaunch-lib.sh"
identity=$(fm_session_end_identity "$FM_HOME/state" "$2") || exit 1
gen=${identity%% *}
seq=${identity#* }
now=$(date +%s)
printf '%s\tattempt\n%s\trelaunched\n%s\tattempt\n%s\tattempt\n%s\tattempt\n%s\tfailed\n' \
  "$((now - 60))" "$((now - 60))" "$((now - 1900))" "$((now - 4000))" "$((now - 30))" "$((now - 30))" \
  > "$FM_HOME/state/.session-end-relaunch-$2"
printf '%s\t%s\tfailed\n' "$gen" "$seq" > "$FM_HOME/state/.session-end-handled-$2"
fm_session_end_relaunch_scan "$FM_HOME/state" 180 || exit
printf "%s\n" "$FM_SESSION_END_WAKE"
SH
    )
    rc=$?
    expect_code 0 "$rc" "supervised quota recovery must reconcile the route: $out"
    assert_equals 'unfinished change' "$(cat "$dir/wt/unfinished.txt")" "automatic replacement must preserve uncommitted work"
    assert_contains "$out" 'auto-relaunched after quota exhaustion' "a live OMP session must recover despite recent session-end relaunch history, a failed same-identity quota attempt, and the daily cap"
    assert_equals "$model" "$(meta_field "$dir" "$id" model)" "unknown adopted authentication must not authorize switching the selected route"
    assert_equals complete "$(journal_field "$dir" "$id" phase)" "the real replacement transaction must complete"
    assert_contains "$out" "harness=omp model=$model" "the supervisor wake must disclose the retained route"
    assert_absent "$dir/fake/created-windows" "in-place recovery must retain the adopted endpoint"
    cmp -s "$expected" "$dir/home/state/$id.status" || fail "automatic routing disclosure changed the replacement's done declaration"
    assert_equals "$declaration" "$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_current_line "$2" ship' \
      bash "$ROOT" "$dir/home/state/$id.status")" "the replacement's done declaration must remain authoritative"
  done
  pass "supervised OMP quota recovery ignores attempt caps and failed handling while retaining routes with unknown adopted authentication and preserving work"
}

test_retiring_omp_removes_only_its_generated_configuration() {
  local dir out rc
  dir=$(new_case omp-config-retirement rl-config)
  add_ship_task "$dir" rl-config omp
  printf 'dispatch_rule=rule_1\n' >> "$dir/home/state/rl-config.meta"
  mkdir -p "$dir/home/config"
  printf '{"rules":[{"when":"OMP work","use":{"harness":"omp"}}]}\n' > "$dir/home/config/crew-dispatch.json"
  printf omp > "$dir/fake/command"
  printf claude > "$dir/fake/becomes"
  printf 'export default () => {};\n' > "$dir/home/state/rl-config.omp-ext.ts"
  mkdir -p "$dir/wt/.omp"
  printf 'user configuration\n' > "$dir/wt/.omp/config.yml"
  out=$(run_control "$dir" rl-config relaunch --harness claude --note "replace the configured runtime explicitly"); rc=$?
  expect_code 0 "$rc" "an explicit runtime replacement must complete: $out"
  assert_absent "$dir/home/state/rl-config.omp-ext.ts" "retired callbacks must not survive replacement"
  assert_equals 'user configuration' "$(cat "$dir/wt/.omp/config.yml")" "retirement must preserve user configuration"
  out=$(run_control "$dir" rl-config relaunch --note "continue after the explicit runtime override"); rc=$?
  expect_code 0 "$rc" "the retired rule must not block subsequent recovery: $out"
  pass "OMP replacement retires generated callbacks without removing user configuration"
}

test_retiring_omp_removes_only_its_generated_configuration
test_ordinary_partial_failure_keeps_its_attempt_caps() {
  local dir id=rl-ordinary-partial out rc now
  dir=$(new_case ordinary-partial "$id")
  add_ship_task "$dir" "$id" claude
  arm_session_end "$dir" "$id"
  printf zsh > "$dir/fake/command"
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  out=$(run_session_end_scan "$dir"); rc=$?
  expect_code 0 "$rc" "ordinary partial launch failure must be recorded: $out"
  assert_contains "$out" 'auto-relaunch failed after session-end' "ordinary launch must fail at the real endpoint gate"
  assert_equals '' "$(journal_field "$dir" "$id" quota_gen)" "ordinary recovery must not acquire quota provenance"
  printf '%s' "$dir/wt" > "$dir/fake/cwd"
  out=$(run_session_end_scan "$dir"); rc=$?
  expect_code 0 "$rc" "ordinary recent failure must remain capped"
  assert_equals '' "$out" "ordinary failed handling must suppress an immediate retry"
  now=$(date +%s)
  printf '%s\tattempt\n%s\tattempt\n%s\tattempt\n' "$((now - 1900))" "$((now - 4000))" "$((now - 8000))" \
    > "$dir/home/state/.session-end-relaunch-$id"
  out=$(run_session_end_scan "$dir"); rc=$?
  expect_code 0 "$rc" "ordinary daily cap must remain enforced"
  assert_contains "$out" 'auto-relaunch paused after 3 attempts' "ordinary recovery must retain its daily cap"
  printf '%s\tattempt\n' "$((now - 90000))" > "$dir/home/state/.session-end-relaunch-$id"
  out=$(run_session_end_scan "$dir"); rc=$?
  expect_code 0 "$rc" "ordinary recovery must remain retryable under its existing cap policy"
  assert_contains "$out" 'auto-relaunched after session-end' "ordinary recovery must succeed after its caps expire"
  assert_equals '' "$(journal_field "$dir" "$id" quota_gen)" "ordinary retry must remain ordinary"
  pass "ordinary partial recovery retains its recent and daily caps and existing retry policy"
}


test_quota_exit_cancellation_is_rechecked_after_scan_selection
test_quota_hold_and_status_are_rechecked_after_scan_selection
test_quota_scan_stops_after_failed_published_or_confirmed_replacement
test_quota_exhaustion_relaunches_only_a_permitted_route
test_quota_recovery_retries_real_stop_then_failed_launch
test_quota_published_failure_retries_only_its_dead_transaction
test_quota_live_published_replacement_handles_its_new_event
test_quota_confirmed_replacement_is_not_retried
test_quota_retry_preserves_identity_after_pre_stop_failure
test_live_quota_retries_after_initial_pre_stop_failure
test_explicit_exit_cancels_partial_quota_recovery
test_relaunch_records_the_operator_selected_served_profile
test_operator_selected_stand_in_preserves_launch_delivery_declarations
test_ordinary_partial_failure_keeps_its_attempt_caps

test_same_harness_relaunch_keeps_identity_and_reuses_the_endpoint
test_no_dispatch_non_omp_relaunch_does_not_require_jq
test_claude_relaunch_preserves_unknown_adopted_auth_and_forwarded_credentials
test_relaunch_refuses_before_exit_when_the_composer_holds_pending_text
test_relaunch_refuses_before_exit_when_the_composer_state_is_unproven
test_relaunch_from_linked_home_preserves_recorded_worktree
test_relaunch_preserves_durable_task_metadata
test_relaunch_serializes_concurrent_durable_metadata_publication
test_disabled_relaunch_clears_prior_trace_context
test_relaunch_appends_the_progress_note_to_the_instructions
test_relaunch_requires_a_note_for_a_ship_task
test_harness_switch_moves_the_record_and_clears_prior_wiring
test_harness_switch_does_not_carry_the_old_profile_axes
test_harness_switch_resolves_a_prefixed_recorded_harness
test_prefixed_recorded_harness_requires_explicit_replacement
test_same_harness_relaunch_keeps_the_profile_axes
test_native_ultra_relaunch_preserves_profile_and_rejects_before_stop
test_model_index_resolves_and_refuses_before_stop
test_model_index_generation_survives_account_checks_and_replacement
test_unpinned_indexed_relaunch_does_not_query_the_supervisor_account
test_signed_out_worker_account_pin_refuses_before_stop
test_worker_account_pin_follows_the_relaunch
test_recorded_api_key_opt_in_follows_the_relaunch
test_api_key_guard_refuses_before_stop
test_api_key_guard_uses_replacement_profile
test_api_key_guard_refuses_tmux_key_before_stop
test_spawn_relaunch_without_the_opt_in_drops_the_recorded_api_key
test_explicit_model_wins_over_the_recorded_one
test_relaunch_onto_an_unverified_harness_is_refused
test_prior_harness_turnend_registry_entry_is_cleared
test_wiring_removal_failure_refuses_before_replacement_arm
test_turnend_auth_paths_are_owned_by_the_control_adapter
test_secondmate_relaunch_picks_up_the_configured_harness_pin
test_secondmate_relaunch_ignores_invalid_configured_effort_before_stop
test_secondmate_relaunch_onto_a_crewmate_only_adapter_refuses_before_stop
test_explicit_secondmate_harness_ignores_configured_profile_axes
test_ship_relaunch_ignores_the_crew_harness_config
test_spawn_relaunch_without_a_harness_reuses_the_recorded_one
test_spawn_relaunch_of_promoted_scout_uses_the_recorded_branch
test_promoted_scout_relaunch_receives_the_current_delivery_contract
test_prefixed_prior_harness_wiring_is_still_retired
test_muse_session_binding_is_retired_on_a_harness_switch
test_cursor_session_binding_is_retired_on_a_harness_switch
test_missing_worktree_refuses_before_stopping_anything
test_missing_instructions_refuse_before_stopping_anything
test_checkpoint_refusal_leaves_the_record_byte_identical
test_checkpoint_refuses_uninspectable_head_and_status
test_launch_failure_keeps_the_prior_record_and_reports_it
test_prepublication_failure_keeps_concurrent_durable_metadata
test_post_publication_launch_failure_keeps_the_new_record
test_stop_transport_failure_reconciles_a_dead_agent
test_complete_journal_failure_rolls_back_from_durable_phase
test_prepublication_abort_retires_replacement_wiring_and_busy_state
test_journal_records_the_checkpoint_it_proved
test_secondmate_relaunch_checkpoints_child_work_and_spares_the_charter
test_default_secondmate_relaunch_survives_unsafe_routing_sources
test_secondmate_relaunch_refuses_an_unmarked_home
test_secondmate_checkpoint_refuses_unreadable_child_state
test_secondmate_checkpoint_ignores_a_vanished_scratch_find_walk
test_concurrent_relaunch_is_refused
test_direct_spawn_relaunch_participates_in_the_lifecycle_lock
test_promotion_participates_in_the_lifecycle_lock_before_metadata_resolution
test_spawn_relaunch_refuses_a_live_agent
test_spawn_relaunch_refuses_a_symlinked_task_record_before_inspection
test_spawn_relaunch_keeps_its_early_meta_lock_continuous
test_spawn_relaunch_refuses_a_pending_authoritative_close
test_spawn_relaunch_refuses_contradicting_flags
test_spawn_relaunch_refuses_an_unrecorded_task
test_spawn_relaunch_refuses_a_pane_outside_the_worktree
test_tmux_gone_endpoint_is_proven_despite_unrelated_servers
test_tmux_worktree_local_recovery_with_real_lsof
test_tmux_refuses_while_the_recorded_endpoint_may_be_live
test_tmux_unreadable_evidence_refuses
test_tmux_no_server_reclaim_keeps_work_and_task
test_tmux_reclaim_refuses_other_configured_backends
test_reclaim_refuses_an_unreadable_endpoint
test_herdr_relaunch_resumes_only_the_registered_pi_session
test_herdr_reclaim_adopts_a_pane_that_outlived_its_server
test_herdr_exit_reports_already_stopped_when_the_pane_outlived_its_server
test_herdr_exit_resolves_retired_quota_identity_after_server_recovery
test_herdr_rebind_stays_in_the_recorded_session
test_herdr_reclaim_refuses_an_agent_that_came_back
test_herdr_reclaim_keeps_the_task_whole
test_herdr_reclaim_of_a_secondmate_names_its_own_owner
test_herdr_rebind_failure_from_a_plain_shell_names_the_real_cause
test_relaunch_reverifies_an_already_in_flight_item_instead_of_rewriting_it
test_relaunch_moves_a_drifted_item_back_in_flight
test_teamclaude_reaches_tmux_relaunch_paths
test_teamclaude_reaches_herdr_relaunch_paths
test_teamclaude_reaches_secondmate_respawn_on_both_backends
test_teamclaude_reaches_fresh_herdr_spawns
test_teamclaude_refusal_lands_before_the_old_agent_stops
