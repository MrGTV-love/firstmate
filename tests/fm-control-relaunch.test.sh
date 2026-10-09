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
          if [ -n "${FM_FAKE_CWD_RACE_READY:-}" ] && [ ! -e "$FM_FAKE_CWD_RACE_READY" ]; then
            : > "$FM_FAKE_CWD_RACE_READY"
            /bin/sleep 1
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

test_relaunch_keeps_a_recorded_pr_parseable_for_monitoring() {
  local dir out rc parsed tracing
  for tracing in off on; do
    dir=$(new_case "pr-parse-$tracing" rl90)
    add_ship_task "$dir" rl90 claude
    printf '%s\n' "$$" > "$dir/home/state/.lock"
    printf '%s %s\n' "$$" "$tracing" > "$dir/home/state/.trace-context-effective"
    {
      printf '%s\n' 'traceparent=00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01'
      printf '%s\n' 'pr=https://github.com/example/repo/pull/90'
      printf '%s\n' 'pr_head=0123456789abcdef0123456789abcdef01234567'
      printf '%s\n' 'x_request=request-90'
    } >> "$dir/home/state/rl90.meta"

    out=$(run_control "$dir" rl90 relaunch --note "keep PR monitoring alive"); rc=$?
    expect_code 0 "$rc" "relaunch of a task with a recorded PR and tracing $tracing should succeed"$'\n'"$out"
    [ -n "$(meta_field "$dir" rl90 control_relaunch_tx)" ] \
      || fail "the published record should still identify its relaunch transaction"
    parsed=$(bash -c '
      . "$1/bin/fm-pr-lib.sh"
      fm_pr_metadata_identity_parse "$2" && printf "%s\n" "$FM_PR_META_URL"
    ' _ "$ROOT" "$dir/home/state/rl90.meta")
    [ "$parsed" = "https://github.com/example/repo/pull/90" ] \
      || fail "PR monitoring must still parse the relaunched task record with tracing $tracing (got: ${parsed:-rejected})"
    if [ "$tracing" = on ]; then
      [ "$(awk -F= '$1 == "traceparent" { count++ } END { print count+0 }' "$dir/home/state/rl90.meta")" = 1 ] \
        || fail "traced relaunch must publish exactly one trace carrier"
      [ "$(meta_field "$dir" rl90 traceparent)" = "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01" ] \
        || fail "traced relaunch must preserve the task's recorded carrier"
    else
      [ -z "$(meta_field "$dir" rl90 traceparent)" ] \
        || fail "untraced relaunch must remove the task's recorded carrier"
    fi
    pass "fm-control relaunch: a recorded PR stays parseable for PR monitoring with tracing $tracing"
  done
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

test_pi_exclude_tools_follow_the_relaunch() {
  local dir out rc id=rl-pi-excl
  dir=$(new_case pi-exclude "$id")
  add_ship_task "$dir" "$id" pi
  printf pi > "$dir/fake/command"
  printf pi > "$dir/fake/becomes"
  printf '#!/usr/bin/env bash\nprintf "Options: --tui-mode\\n"\n' > "$dir/fakebin/pi"
  chmod +x "$dir/fakebin/pi"
  mkdir -p "$dir/home/config"
  printf '%s\n' '# hide writes' 'mcp__srv__writeTool' 'mcp__srv__adminTool' > "$dir/home/config/crew-exclude-tools"
  out=$(run_control "$dir" "$id" relaunch --note "keep exclusions"); rc=$?
  expect_code 0 "$rc" "a Pi relaunch with exclusions should succeed"$'\n'"$out"
  assert_contains "$(cat "$dir/fake/literal")" "--exclude-tools 'mcp__srv__writeTool,mcp__srv__adminTool'" \
    "the relaunched Pi worker must keep the home's tool exclusions"
  rm "$dir/home/config/crew-exclude-tools"
  : > "$dir/fake/literal"
  printf pi > "$dir/fake/command"
  out=$(run_control "$dir" "$id" relaunch --note "exclusions removed"); rc=$?
  expect_code 0 "$rc" "a Pi relaunch after the file is removed should succeed"$'\n'"$out"
  assert_not_contains "$(cat "$dir/fake/literal")" "--exclude-tools" \
    "a relaunch without the file must launch with no exclusions"
  pass "fm-control relaunch: a Pi replacement keeps the home's tool exclusions"
}

test_exclude_tools_refusals_happen_before_the_agent_stops() {
  local dir out rc id=rl-excl-refuse
  dir=$(new_case excl-refuse "$id")
  add_ship_task "$dir" "$id" pi
  printf pi > "$dir/fake/command"
  printf pi > "$dir/fake/becomes"
  printf '#!/usr/bin/env bash\nprintf "Options: --tui-mode\\n"\n' > "$dir/fakebin/pi"
  chmod +x "$dir/fakebin/pi"
  mkdir -p "$dir/home/config"
  printf '%s\n' 'two words' > "$dir/home/config/crew-exclude-tools"
  out=$(run_control "$dir" "$id" relaunch --note "bad list"); rc=$?
  expect_code 1 "$rc" "a malformed exclusion list must refuse the relaunch"
  assert_contains "$out" "config/crew-exclude-tools has a malformed entry" "refusal must name the entry"
  [ "$(cat "$dir/fake/command")" = pi ] || fail "a malformed exclusion list stopped the running agent"
  [ ! -s "$dir/fake/literal" ] || fail "a refused relaunch sent lifecycle input"
  printf '%s\n' 'mcp__srv__writeTool' > "$dir/home/config/crew-exclude-tools"
  out=$(run_control "$dir" "$id" relaunch --harness codex --note "switch runtime"); rc=$?
  expect_code 1 "$rc" "relaunching onto a runtime that cannot hide tools must refuse"
  assert_contains "$out" "config/crew-exclude-tools" "refusal must name the config file"
  [ "$(cat "$dir/fake/command")" = pi ] || fail "an unhonorable exclusion list stopped the running agent"
  [ ! -s "$dir/fake/literal" ] || fail "a refused relaunch sent lifecycle input"
  pass "fm-control relaunch: exclusion-list refusals happen before the running agent stops"
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
  local dir control_pid link_out rc i=0
  dir=$(new_case rollback-race rl30)
  add_ship_task "$dir" rl30 claude
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  FM_FAKE_CWD_RACE_READY="$dir/cwd-race-ready" \
    run_control "$dir" rl30 relaunch --harness codex --note "preserve concurrent metadata" \
      > "$dir/control.out" &
  control_pid=$!
  while [ ! -e "$dir/cwd-race-ready" ] && [ "$i" -lt 200 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$dir/cwd-race-ready" ] || {
    kill "$control_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "relaunch did not reach its pre-publication endpoint check"
  }
  link_out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    "$X_LINK" rl30 request-30 --carry-count 2 --carry-ts 1700000000 \
      --carry-platform x --carry-max 280 2>&1); rc=$?
  expect_code 0 "$rc" "concurrent durable metadata publication should succeed"$'\n'"$link_out"
  wait "$control_pid"; rc=$?
  expect_code 1 "$rc" "the staged pre-publication launch failure should fail closed"
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
  [ -e "$lock" ] || { kill "$holder" 2>/dev/null; fail "could not stage a held control lock"; }
  printf 'held\n' > "$dir/home/state/rl19.composer-dialog"
  out=$(run_control "$dir" rl19 relaunch --note "concurrent"); rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 1 "$rc" "a second concurrent control action should refuse"
  assert_contains "$out" "another lifecycle action is already running" \
    "the refusal should name the concurrent action"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a refused concurrent relaunch must not stop the agent"
  [ "$(cat "$dir/home/state/rl19.composer-dialog" 2>/dev/null)" = held ] \
    || fail "a refused concurrent relaunch must not remove the lock holder's dialog file"
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
      out=$(run_control "$dir" "$id" exit); rc=$?
      expect_code 0 "$rc" "no user tmux server should prove exit for $id"$'\n'"$out"
      assert_contains "$out" endpoint-gone "exit should report proven absence"
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

# --- 8. relocating a task whose recorded worktree is gone -------------------
#
# A pool slot can vanish (pool reset, a quarantined slot destroyed, a disk
# cleanup) while the task's branch and every commit on it survive in the shared
# repository. Before `--worktree`, relaunch refused that task for good: its
# record named a path nothing could re-create, and the only way out was to
# hand-edit the durable record. These tests pin the supported way out and every
# case it must still refuse.

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
  if [ "$keep" = keep-registration ]; then
    git -C "$dir/proj" worktree add -q -f "$dir/dest" "task-$id"
  else
    git -C "$dir/proj" worktree prune
    git -C "$dir/proj" worktree add -q "$dir/dest" "task-$id"
  fi
  printf zsh > "$dir/fake/command"
  printf '%s' "$dir/wt" > "$dir/fake/cwd"
  printf 'working: preserved history\n' > "$dir/home/state/$id.status"
}

# run_relocation_refusal <case-dir> <id> <fragment> <what> [destination]: the
# relocation must refuse before anything is stopped, journaled or edited.
run_relocation_refusal() {
  local dir=$1 id=$2 fragment=$3 what=$4 dest=${5:-$1/dest} out rc meta_before brief_before journal_before=
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

test_relocation_rebinds_a_vanished_worktree_to_a_fresh_copy() {
  local dir out rc id=rl100
  dir=$(new_case relocate-valid "$id")
  make_relocation_case "$dir" "$id"
  out=$(run_control "$dir" "$id" relaunch --worktree "$dir/dest" --note "the old copy vanished"); rc=$?
  expect_code 0 "$rc" "a vanished copy must relocate onto a fresh copy of its branch"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" worktree)" = "$dir/dest" ] || fail "the record was not rebound to the fresh copy"
  [ "$(meta_field "$dir" "$id" branch)" = "task-$id" ] || fail "relocation changed the recorded branch"
  [ "$(meta_field "$dir" "$id" endpoint_task_id)" = "$id" ] || fail "relocation changed the task identity"
  [ "$(meta_field "$dir" "$id" window)" = "fmses:fm-$id" ] || fail "relocation moved the endpoint"
  [ "$(git -C "$dir/dest" rev-parse HEAD)" = "$(cat "$dir/committed-head")" ] || fail "the fresh copy lost committed work"
  [ -z "$(git -C "$dir/dest" status --porcelain)" ] || fail "relocation left the fresh copy dirty"
  assert_present "$dir/dest/.claude/settings.local.json" "the replacement was not wired in the fresh copy"
  assert_grep "cd -- '$dir/dest'" "$dir/fake/keys" "the replacement launched outside the fresh copy"
  assert_contains "$(cat "$dir/home/state/$id.status")" "preserved history" "relocation truncated the status log"
  assert_grep "the old copy vanished" "$dir/home/data/$id/brief.md" "relocation dropped the progress note"
  assert_grep "proven absent" "$dir/home/data/$id/brief.md" "the note must tell the worker its copy was replaced"
  [ "$(journal_field "$dir" "$id" phase)" = complete ] || fail "relocation did not complete its journal"
  [ "$(journal_field "$dir" "$id" relocation_from)" = "$dir/wt" ] || fail "the journal lost the vanished path"
  [ "$(journal_field "$dir" "$id" relocation_to)" = "$dir/dest" ] || fail "the journal lost the fresh copy"
  [ "$(journal_field "$dir" "$id" relocation_head)" = "$(cat "$dir/committed-head")" ] || fail "the journal lost the recorded head"
  [ "$(journal_field "$dir" "$id" relocation_head_source)" = meta-pr_head ] || fail "the journal must name every recorded source it checked"
  [ "$(cat "$dir/fake/cwd")" = "$dir/dest" ] || fail "the idle shell was not moved from the vanished path"
  pass "relocation: a vanished copy rebinds to a fresh copy of its branch, keeping identity, endpoint, status and note"
}

test_relocation_checks_every_recorded_head_and_requires_evidence() {
  local dir id out rc variant source
  for variant in meta-head registered journal pr-head all; do
    id="rl101$variant"
    dir=$(new_case "relocate-evidence-$variant" "$id")
    if [ "$variant" = registered ] || [ "$variant" = all ]; then
      make_relocation_case "$dir" "$id" keep-registration
    else
      make_relocation_case "$dir" "$id"
    fi
    case "$variant" in
      meta-head) printf 'worktree_head=%s\n' "$(cat "$dir/first-head")" >> "$dir/home/state/$id.meta"; source=meta-worktree_head,meta-pr_head ;;
      registered) source=registered-worktree,meta-pr_head ;;
      journal)
        printf 'task=%s\nworktree=%s\nworktree_head=%s\n' "$id" "$dir/wt" "$(cat "$dir/first-head")" > "$dir/home/state/$id.control-relaunch"
        source=journal-worktree_head,meta-pr_head
        ;;
      pr-head) source=meta-pr_head ;;
      all)
        printf 'worktree_head=%s\n' "$(cat "$dir/first-head")" >> "$dir/home/state/$id.meta"
        printf 'task=%s\nworktree=%s\nworktree_head=%s\n' "$id" "$dir/wt" "$(cat "$dir/first-head")" > "$dir/home/state/$id.control-relaunch"
        source=meta-worktree_head,registered-worktree,journal-worktree_head,meta-pr_head
        ;;
    esac
    out=$(run_control "$dir" "$id" relaunch --worktree "$dir/dest" --note "resume"); rc=$?
    expect_code 0 "$rc" "a copy containing the recorded head must relocate ($variant)"$'\n'"$out"
    [ "$(journal_field "$dir" "$id" relocation_head_source)" = "$source" ] \
      || fail "the journal named '$(journal_field "$dir" "$id" relocation_head_source)', not $source ($variant)"
    [ "$(journal_field "$dir" "$id" relocation_head)" = "$(cat "$dir/committed-head")" ] \
      || fail "the proof did not record the copy's HEAD ($variant)"
  done

  # A branch moved BACK to an older commit (a reset while recreating the copy)
  # silently drops the task's commits. Every recorded head must catch that.
  for variant in meta-head registered journal journal-pr journal-relocation; do
    id="rl102$variant"
    dir=$(new_case "relocate-reset-$variant" "$id")
    if [ "$variant" = registered ]; then
      make_relocation_case "$dir" "$id" keep-registration
    else
      make_relocation_case "$dir" "$id"
    fi
    [ "$variant" = journal-pr ] || set_case_meta_field "$dir" "$id" pr_head "$(cat "$dir/first-head")"
    case "$variant" in
      meta-head) set_case_meta_field "$dir" "$id" worktree_head "$(cat "$dir/committed-head")" ;;
      journal)
        printf 'task=%s\nworktree=%s\nworktree_head=%s\n' "$id" "$dir/wt" "$(cat "$dir/committed-head")" > "$dir/home/state/$id.control-relaunch"
        ;;
      journal-pr)
        printf 'task=%s\nworktree=%s\nworktree_head=%s\n' "$id" "$dir/wt" "$(cat "$dir/first-head")" > "$dir/home/state/$id.control-relaunch"
        ;;
      journal-relocation)
        printf 'task=%s\nworktree=%s\nworktree_head=%s\nrelocation_to=%s\nrelocation_head=%s\n' \
          "$id" "$dir/wt" "$(cat "$dir/first-head")" "$dir/wt" "$(cat "$dir/committed-head")" > "$dir/home/state/$id.control-relaunch"
        ;;
    esac
    git -C "$dir/dest" reset -q --hard "$(cat "$dir/first-head")"
    run_relocation_refusal "$dir" "$id" "does not contain" "branch reset behind the recorded head ($variant)"
  done
  id=rl102nohead
  dir=$(new_case relocate-no-head "$id")
  make_relocation_case "$dir" "$id"
  set_case_meta_field "$dir" "$id" pr_head ""
  run_relocation_refusal "$dir" "$id" "no recorded head exists" "no surviving recorded head"
  pass "relocation: every surviving recorded head must be contained, and no evidence refuses"
}

test_relocation_refuses_unreadable_head_evidence() {
  local dir id variant locked common admin fragment out rc before brief_before journal_before
  local -a args
  [ "$(id -u)" != 0 ] || { echo "skip - unreadable head evidence needs a non-root user"; return; }
  for variant in registration reflog journal journal-ordinary; do
    id="rl110${variant//-/}"
    dir=$(new_case "relocate-unreadable-$variant" "$id")
    locked=
    journal_before=
    if [ "$variant" = journal-ordinary ]; then
      add_ship_task "$dir" "$id"
      printf zsh > "$dir/fake/command"
    else
      make_relocation_case "$dir" "$id" keep-registration
      set_case_meta_field "$dir" "$id" pr_head "$(cat "$dir/first-head")"
      git -C "$dir/dest" reset -q --hard "$(cat "$dir/first-head")"
    fi
    case "$variant" in
      registration|reflog)
        common=$(git -C "$dir/proj" rev-parse --path-format=absolute --git-common-dir)
        for admin in "$common"/worktrees/*; do
          [ "$(cat "$admin/gitdir")" = "$dir/wt/.git" ] || continue
          if [ "$variant" = registration ]; then
            locked="$admin/gitdir"
            fragment="worktree registration"
          else
            locked="$admin/logs/HEAD"
            fragment="recorded worktree reflog"
          fi
          break
        done
        [ -n "$locked" ] || fail "the vanished worktree registration was not retained"
        ;;
      journal*)
        locked="$dir/home/state/$id.control-relaunch"
        if [ "$variant" = journal ]; then
          printf 'task=%s\nworktree=%s\nworktree_head=%s\n' "$id" "$dir/wt" "$(cat "$dir/committed-head")" > "$locked"
        else
          printf 'task=%s\nworktree=%s\nworktree_head=%s\n' "$id" "$dir/wt" "$(git -C "$dir/wt" rev-parse HEAD)" > "$locked"
        fi
        journal_before=$(cat "$locked")
        fragment="control journal"
        ;;
    esac
    before=$(cat "$dir/home/state/$id.meta")
    brief_before=$(cat "$dir/home/data/$id/brief.md")
    chmod 000 "$locked"
    args=("$id" relaunch --note "resume")
    [ "$variant" = journal-ordinary ] || args+=(--worktree "$dir/dest")
    out=$(run_control "$dir" "${args[@]}"); rc=$?
    expect_code 1 "$rc" "control must refuse unreadable historical evidence ($variant)"$'\n'"$out"
    assert_contains "$out" "$fragment" "control refused for the wrong reason ($variant)"
    if [ "$variant" != journal-ordinary ]; then
      out=$(run_spawn "$dir" "$id" --relaunch --worktree "$dir/dest"); rc=$?
      expect_code 1 "$rc" "direct spawn must refuse unreadable historical evidence ($variant)"$'\n'"$out"
      assert_contains "$out" "$fragment" "direct spawn refused for the wrong reason ($variant)"
    fi
    chmod 644 "$locked"
    [ "$(cat "$dir/home/state/$id.meta")" = "$before" ] || fail "unreadable evidence refusal changed the record ($variant)"
    [ "$(cat "$dir/home/data/$id/brief.md")" = "$brief_before" ] || fail "unreadable evidence refusal changed the instructions ($variant)"
    if [ -n "$journal_before" ]; then
      [ "$(cat "$dir/home/state/$id.control-relaunch")" = "$journal_before" ] || fail "unreadable journal was overwritten ($variant)"
    else
      assert_absent "$dir/home/state/$id.control-relaunch" "unreadable evidence refusal wrote a journal ($variant)"
    fi
    [ ! -s "$dir/fake/literal" ] || fail "unreadable evidence refusal launched a worker ($variant)"
  done
  pass "relocation: unreadable registrations, reflogs and journals refuse without discarding evidence"
}

test_relocation_refuses_every_unsafe_destination() {
  local dir id variant fragment root_uid foreign
  root_uid=$(id -u)
  for variant in present dangling-symlink unreadable-ancestry branch detached head-unrelated head-missing head-malformed \
      owned owned-alias other-repo primary subdir dirty scout secondmate relative missing-dest same-as-recorded; do
    id="rl103${variant//-/}"
    dir=$(new_case "relocate-refuse-$variant" "$id")
    make_relocation_case "$dir" "$id"
    fragment=
    case "$variant" in
      present) mkdir "$dir/wt"; fragment="still exists" ;;
      dangling-symlink) ln -s "$dir/nowhere" "$dir/wt"; fragment="still exists" ;;
      unreadable-ancestry)
        [ "$root_uid" != 0 ] || { echo "skip - unreadable ancestry needs a non-root user"; continue; }
        mkdir -p "$dir/locked"
        set_case_meta_field "$dir" "$id" worktree "$dir/locked/wt"
        chmod 000 "$dir/locked"
        fragment="cannot be proven"
        ;;
      branch) git -C "$dir/dest" checkout -q -b elsewhere; fragment="does not equal the recorded branch" ;;
      detached) git -C "$dir/dest" checkout -q --detach; fragment="does not equal the recorded branch" ;;
      head-unrelated)
        foreign=$(printf 'unrelated\n' | git -C "$dir/proj" -c user.name=t -c user.email=t@example.com commit-tree "$(git -C "$dir/proj" rev-parse 'HEAD^{tree}')")
        printf 'worktree_head=%s\n' "$foreign" >> "$dir/home/state/$id.meta"
        fragment="does not contain"
        ;;
      head-missing)
        printf 'worktree_head=%s\n' 0123456789abcdef0123456789abcdef01234567 >> "$dir/home/state/$id.meta"
        fragment="not in the repository"
        ;;
      head-malformed) printf 'worktree_head=not-a-commit\n' >> "$dir/home/state/$id.meta"; fragment="full commit id" ;;
      owned) printf 'worktree=%s\n' "$dir/dest" > "$dir/home/state/other.meta"; fragment="recorded by another task" ;;
      owned-alias)
        ln -s "$dir/dest" "$dir/alias"
        printf 'worktree=%s\n' "$dir/alias" > "$dir/home/state/other.meta"
        fragment="recorded by another task"
        ;;
      other-repo)
        fm_git_worktree "$dir/foreign-proj" "$dir/foreign-wt" "task-$id"
        fragment="same repository"
        ;;
      primary) fragment="isolated worktree" ;;
      subdir) mkdir "$dir/dest/subdir"; fragment="not a worktree root" ;;
      dirty) printf 'someone else\n' > "$dir/dest/stray.txt"; fragment="uncommitted changes" ;;
      scout) set_case_meta_field "$dir" "$id" kind scout; fragment="ships only" ;;
      secondmate)
        set_case_meta_field "$dir" "$id" kind secondmate
        mkdir -p "$dir/home/config"
        printf 'claude\n' > "$dir/home/config/secondmate-harness"
        fragment="ships only"
        ;;
      relative) fragment="absolute path" ;;
      missing-dest) fragment="not a readable directory" ;;
      same-as-recorded) fragment="still exists" ;;
    esac
    case "$variant" in
      other-repo) run_relocation_refusal "$dir" "$id" "$fragment" "$variant" "$dir/foreign-wt" ;;
      primary) run_relocation_refusal "$dir" "$id" "$fragment" "$variant" "$dir/proj" ;;
      subdir) run_relocation_refusal "$dir" "$id" "$fragment" "$variant" "$dir/dest/subdir" ;;
      relative) run_relocation_refusal "$dir" "$id" "$fragment" "$variant" "dest" ;;
      missing-dest) run_relocation_refusal "$dir" "$id" "$fragment" "$variant" "$dir/nope" ;;
      same-as-recorded) mkdir "$dir/wt"; run_relocation_refusal "$dir" "$id" "$fragment" "$variant" "$dir/wt" ;;
      *) run_relocation_refusal "$dir" "$id" "$fragment" "$variant" ;;
    esac
    chmod 755 "$dir/locked" 2>/dev/null || true
  done
  pass "relocation: a present copy, a wrong branch, unaccounted heads, a shared or foreign copy and every other unsafe destination refuse"
}

test_relocation_refuses_a_copy_another_local_home_records() {
  local dir id variant field owned out rc before brief_before journal_before fragment locked
  for variant in worktree worktree-alias home home-alias unavailable own-record unreadable-registry-worktree unreadable-registry-home; do
    id="rl108${variant//-/}"
    dir=$(new_case "relocate-local-home-$variant" "$id")
    make_relocation_case "$dir" "$id"
    locked=
    if [[ "$variant" = unreadable-registry-* ]] && [ "$(id -u)" = 0 ]; then
      echo "skip - unreadable registry needs a non-root user"
      continue
    fi
    printf -- '- mate - a local mate (home: %s; scope: project work; projects: project; added 2026-09-01)\n' \
      "$dir/mate" > "$dir/home/data/secondmates.md"
    printf 'task=%s\nworktree=%s\nworktree_head=%s\n' "$id" "$dir/wt" "$(cat "$dir/first-head")" \
      > "$dir/home/state/$id.control-relaunch"
    if [ "$variant" != unavailable ]; then
      mkdir -p "$dir/mate/state"
    fi
    case "$variant" in
      worktree*|home*)
        field=${variant%%-*}
        owned="$dir/dest"
        if [[ "$variant" = *-alias ]]; then
          ln -s "$dir/dest" "$dir/alias"
          owned="$dir/alias"
        fi
        printf '%s=%s\n' "$field" "$owned" > "$dir/mate/state/$id.meta"
        fragment="recorded by another task"
        ;;
      unavailable) fragment="registered local Firstmate home is unavailable" ;;
      unreadable-registry-*)
        mkdir -p "$dir/mate/data" "$dir/hidden/state" "$dir/sibling/state"
        printf -- '- sibling - a local mate (home: %s; scope: project work; projects: project; added 2026-09-01)\n' \
          "$dir/sibling" >> "$dir/home/data/secondmates.md"
        locked="$dir/mate/data/secondmates.md"
        printf -- '- hidden - a local mate (home: %s; scope: project work; projects: project; added 2026-09-01)\n' \
          "$dir/hidden" > "$locked"
        printf '%s=%s\n' "${variant##*-}" "$dir/dest" > "$dir/hidden/state/$id.meta"
        chmod 000 "$locked"
        fragment="local Firstmate registry cannot be read"
        ;;
      own-record)
        set_case_meta_field "$dir" "$id" home "$dir/dest"
        out=$(run_control "$dir" "$id" relaunch --worktree "$dir/dest" --note "resume"); rc=$?
        expect_code 0 "$rc" "the exact own record must be excluded from the local-home scan"$'\n'"$out"
        [ "$(meta_field "$dir" "$id" worktree)" = "$dir/dest" ] || fail "own-record exclusion did not allow relocation"
        continue
        ;;
    esac
    before=$(cat "$dir/home/state/$id.meta")
    brief_before=$(cat "$dir/home/data/$id/brief.md")
    journal_before=$(cat "$dir/home/state/$id.control-relaunch")
    run_relocation_refusal "$dir" "$id" "$fragment" "$variant"
    out=$(run_spawn "$dir" "$id" --relaunch --worktree "$dir/dest"); rc=$?
    expect_code 1 "$rc" "direct spawn must refuse the local-home ownership hazard ($variant)"$'\n'"$out"
    assert_contains "$out" "$fragment" "direct spawn refused for the wrong reason ($variant)"
    [ "$(cat "$dir/home/state/$id.meta")" = "$before" ] || fail "direct refusal changed the record ($variant)"
    [ "$(cat "$dir/home/data/$id/brief.md")" = "$brief_before" ] || fail "direct refusal changed the instructions ($variant)"
    [ "$(cat "$dir/home/state/$id.control-relaunch")" = "$journal_before" ] || fail "direct refusal changed the journal ($variant)"
    [ ! -s "$dir/fake/literal" ] || fail "direct refusal launched into another home's copy ($variant)"
    [ -z "$locked" ] || chmod 644 "$locked"
  done
  pass "relocation: every registered local home's records are checked, an unavailable home refuses, and the exact own record is excluded"
}

test_relocation_never_overwrites_or_deletes_a_foreign_harness_file() {
  local dir id rel before out rc n=0
  for rel in .claude/settings.local.json .opencode/plugins/fm-busy-state.js .fm-grok-turnend .fm-kimi-turnend; do
    n=$((n + 1))
    id="rl104$n"
    dir=$(new_case "relocate-wiring-$n" "$id")
    make_relocation_case "$dir" "$id"
    mkdir -p "$(dirname "$dir/dest/$rel")"
    printf 'the project owns this file: %s\n' "$rel" > "$dir/dest/$rel"
    # A project commonly ignores these local files, which is exactly when the
    # clean-copy check cannot see them and the harness-file check must.
    printf '%s\n' "$rel" >> "$(git -C "$dir/dest" rev-parse --path-format=absolute --git-path info/exclude)"
    before=$(cat "$dir/dest/$rel")
    run_relocation_refusal "$dir" "$id" "harness file" "foreign $rel"
    [ "$(cat "$dir/dest/$rel")" = "$before" ] || fail "a refused relocation changed $rel"
    rm "$dir/dest/$rel"
    printf '%s\n' "$before" > "$dir/fake/foreign-wiring"
    printf '%s\n' "$dir/dest/$rel" > "$dir/fake/foreign-wiring-path"
    out=$(run_spawn "$dir" "$id" --relaunch --worktree "$dir/dest"); rc=$?
    expect_code 1 "$rc" "the launch owner must refuse a foreign $rel"$'\n'"$out"
    assert_contains "$out" "harness file" "the launch owner refused for the wrong reason ($rel)"
    assert_present "$dir/fake/foreign-wiring-created" "the foreign file must arrive after admission ($rel)"
    [ "$(cat "$dir/dest/$rel")" = "$before" ] || fail "the launch owner changed $rel"
    [ "$(meta_field "$dir" "$id" worktree)" = "$dir/wt" ] || fail "a refused launch rebound the record ($rel)"
  done
  pass "relocation: a destination's own harness files are never overwritten or deleted"
}

test_relocation_proof_survives_every_failure_journal_rewrite() {
  local dir id variant out rc phase expect_meta
  for variant in launch-refused stop-transport publish-failed complete-journal; do
    id="rl105${variant//-/}"
    dir=$(new_case "relocate-journal-$variant" "$id")
    make_relocation_case "$dir" "$id"
    expect_meta=$(cat "$dir/home/state/$id.meta")
    case "$variant" in
      launch-refused)
        printf '%s' "$dir/proj" > "$dir/fake/cwd"
        : > "$dir/fake/ignore-cd"
        out=$(run_control "$dir" "$id" relaunch --worktree "$dir/dest" --note "resume"); rc=$?
        phase=failed:launching
        ;;
      stop-transport)
        printf claude > "$dir/fake/command"
        out=$(FM_FAKE_EXIT_TRANSPORT_FAIL_AFTER_STOP=1 \
          run_control "$dir" "$id" relaunch --worktree "$dir/dest" --note "resume"); rc=$?
        phase=failed:stopping
        ;;
      publish-failed)
        make_mv_failure_stub "$dir"
        out=$(FM_REAL_MV="$(command -v mv)" FM_FAKE_META_PUBLISH_MV_FAIL="$dir/home/state/$id.meta" \
          run_control "$dir" "$id" relaunch --worktree "$dir/dest" --note "resume"); rc=$?
        phase=failed:launching
        ;;
      complete-journal)
        printf codex > "$dir/fake/becomes"
        make_mv_failure_stub "$dir"
        out=$(FM_REAL_MV="$(command -v mv)" FM_FAKE_COMPLETE_JOURNAL_MV_FAIL=1 \
          run_control "$dir" "$id" relaunch --harness codex --worktree "$dir/dest" --note "resume"); rc=$?
        phase=failed:launching
        ;;
    esac
    expect_code 1 "$rc" "the staged failure must fail closed ($variant)"$'\n'"$out"
    [ "$(journal_field "$dir" "$id" phase)" = "$phase" ] \
      || fail "the journal phase was '$(journal_field "$dir" "$id" phase)', not $phase ($variant)"
    [ "$(journal_field "$dir" "$id" relocation_from)" = "$dir/wt" ] || fail "the failure journal lost relocation_from ($variant)"
    [ "$(journal_field "$dir" "$id" relocation_to)" = "$dir/dest" ] || fail "the failure journal lost relocation_to ($variant)"
    [ "$(journal_field "$dir" "$id" relocation_head)" = "$(cat "$dir/committed-head")" ] \
      || fail "the failure journal lost relocation_head ($variant)"
    if [ "$variant" != complete-journal ]; then
      [ "$(cat "$dir/home/state/$id.meta")" = "$expect_meta" ] || fail "an unpublished failure changed the record ($variant)"
    fi
  done

  # The proof is what lets the identical command run again after a failure: the
  # vanished path is still the recorded one, and the journal still vouches for it.
  id=rl105retry
  dir=$(new_case relocate-retry "$id")
  make_relocation_case "$dir" "$id"
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  : > "$dir/fake/ignore-cd"
  out=$(run_control "$dir" "$id" relaunch --worktree "$dir/dest" --note "first attempt"); rc=$?
  expect_code 1 "$rc" "the first attempt must fail after the stop"$'\n'"$out"
  set_case_meta_field "$dir" "$id" pr_head "$(cat "$dir/first-head")"
  git -C "$dir/dest" reset -q --hard "$(cat "$dir/first-head")"
  printf '%s' "$dir/dest" > "$dir/fake/cwd"
  out=$(run_control "$dir" "$id" relaunch --worktree "$dir/dest" --note "second attempt"); rc=$?
  expect_code 1 "$rc" "a copy that lost the journaled head must still be refused on retry"$'\n'"$out"
  assert_contains "$out" "does not contain" "the retry must be judged against the journaled head"
  git -C "$dir/dest" reset -q --hard "$(cat "$dir/committed-head")"
  rm "$dir/fake/ignore-cd"
  out=$(run_control "$dir" "$id" relaunch --worktree "$dir/dest" --note "third attempt"); rc=$?
  expect_code 0 "$rc" "the identical relocation must succeed once the copy is right"$'\n'"$out"
  [ "$(journal_field "$dir" "$id" relocation_head_source)" = journal-relocation_head,journal-worktree_head,meta-pr_head ] \
    || fail "the retry must check both surviving journal heads and the PR head, got '$(journal_field "$dir" "$id" relocation_head_source)'"
  pass "relocation: the vanished path and recorded head survive every failure journal rewrite and judge the retry"
}

test_relocation_proof_survives_later_ordinary_launch_failure() {
  local dir out rc id=rl105ordinary field expected newer
  dir=$(new_case relocate-ordinary-failure "$id")
  make_relocation_case "$dir" "$id"
  printf codex > "$dir/fake/becomes"
  out=$(FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START=1 \
    run_control "$dir" "$id" relaunch --harness codex --worktree "$dir/dest" --note "relocate"); rc=$?
  expect_code 1 "$rc" "relocation must report a post-publication launch failure"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" worktree)" = "$dir/dest" ] || fail "published relocation did not retain its destination"
  [ "$(journal_field "$dir" "$id" worktree)" = "$dir/dest" ] || fail "failure journal still names the vanished worktree"
  git_commit_file "$dir/dest" later.txt "committed after relocation"
  newer=$(git -C "$dir/dest" rev-parse HEAD)
  out=$(FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START=1 \
    run_control "$dir" "$id" relaunch --note "ordinary retry"); rc=$?
  expect_code 1 "$rc" "ordinary retry must report the staged launch failure"$'\n'"$out"
  [ "$(journal_field "$dir" "$id" phase)" = failed:launching ] || fail "ordinary retry failed before launching"
  for field in from to head head_source; do
    case "$field" in
      from) expected="$dir/wt" ;;
      to) expected="$dir/dest" ;;
      head) expected=$(cat "$dir/committed-head") ;;
      head_source) expected=meta-pr_head ;;
    esac
    [ "$(journal_field "$dir" "$id" "relocation_$field")" = "$expected" ] \
      || fail "ordinary launch failure lost relocation_$field"
  done
  [ "$(journal_field "$dir" "$id" worktree_head)" = "$newer" ] || fail "ordinary launch failure lost the newer checkpoint"
  set_case_meta_field "$dir" "$id" pr_head ""
  git -C "$dir/proj" worktree remove --force "$dir/dest"
  git -C "$dir/proj" branch -f "task-$id" "$(cat "$dir/committed-head")"
  git -C "$dir/proj" worktree add -q "$dir/next" "task-$id"
  printf zsh > "$dir/fake/command"
  : > "$dir/fake/literal"
  run_relocation_refusal "$dir" "$id" "journal-worktree_head" "newer checkpoint after ordinary launch failure" "$dir/next"
  out=$(run_spawn "$dir" "$id" --relaunch --worktree "$dir/next"); rc=$?
  expect_code 1 "$rc" "direct spawn must preserve the failed ordinary relaunch checkpoint"$'\n'"$out"
  assert_contains "$out" "journal-worktree_head" "direct spawn missed the failed ordinary checkpoint"
  git -C "$dir/next" reset -q --hard "$newer"
  out=$(run_control "$dir" "$id" relaunch --worktree "$dir/next" --note "relocate again"); rc=$?
  expect_code 0 "$rc" "a later relocation must recover proof through relocation_to"$'\n'"$out"
  [ "$(journal_field "$dir" "$id" relocation_from)" = "$dir/dest" ] || fail "new relocation did not replace the prior proof"
  [ "$(journal_field "$dir" "$id" relocation_to)" = "$dir/next" ] || fail "new relocation did not record its destination"
  [ "$(journal_field "$dir" "$id" relocation_head_source)" = journal-relocation_head,journal-worktree_head ] || fail "later relocation did not use both surviving journal heads"
  pass "relocation: proof survives ordinary launch failures and proves a later destination"
}

test_relocation_requires_a_newer_ordinary_relaunch_checkpoint() {
  local dir out rc newer id=rl109checkpoint
  dir=$(new_case relocate-newer-checkpoint "$id")
  make_relocation_case "$dir" "$id"
  printf codex > "$dir/fake/becomes"
  out=$(run_control "$dir" "$id" relaunch --harness codex --worktree "$dir/dest" --note "relocate"); rc=$?
  expect_code 0 "$rc" "the first relocation must complete"$'\n'"$out"
  git_commit_file "$dir/dest" later.txt "committed after relocation"
  newer=$(git -C "$dir/dest" rev-parse HEAD)
  printf zsh > "$dir/fake/command"
  out=$(run_control "$dir" "$id" relaunch --note "checkpoint newer work"); rc=$?
  expect_code 0 "$rc" "the ordinary relaunch must complete at the newer head"$'\n'"$out"
  [ "$(journal_field "$dir" "$id" worktree_head)" = "$newer" ] || fail "ordinary relaunch did not checkpoint newer work"
  [ "$(journal_field "$dir" "$id" relocation_head)" = "$(cat "$dir/committed-head")" ] || fail "ordinary relaunch lost the earlier relocation proof"
  git -C "$dir/proj" worktree remove --force "$dir/dest"
  git -C "$dir/proj" branch -f "task-$id" "$(cat "$dir/committed-head")"
  git -C "$dir/proj" worktree add -q "$dir/next" "task-$id"
  printf zsh > "$dir/fake/command"
  : > "$dir/fake/literal"
  run_relocation_refusal "$dir" "$id" "journal-worktree_head" "newer ordinary checkpoint" "$dir/next"
  out=$(run_spawn "$dir" "$id" --relaunch --worktree "$dir/next"); rc=$?
  expect_code 1 "$rc" "direct spawn must also preserve the newer checkpoint"$'\n'"$out"
  assert_contains "$out" "journal-worktree_head" "direct spawn missed the newer checkpoint"
  [ "$(meta_field "$dir" "$id" worktree)" = "$dir/dest" ] || fail "checkpoint refusal rebound the task"
  git -C "$dir/next" reset -q --hard "$newer"
  out=$(run_control "$dir" "$id" relaunch --worktree "$dir/next" --note "resume all committed work"); rc=$?
  expect_code 0 "$rc" "a copy containing both journal heads must relocate"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" worktree)" = "$dir/next" ] || fail "the containing copy was not published"
  [ "$(git -C "$dir/next" rev-parse HEAD)" = "$newer" ] || fail "relocation lost newer committed work"
  pass "relocation: a newer ordinary relaunch checkpoint cannot be hidden by preserved relocation evidence"
}

test_relocation_claims_and_respects_pool_slot_ownership() {
  local dir id pool marker out rc before
  for id in rl106claimed rl106foreignhome rl106emptyhome rl106mine rl106free; do
    dir=$(new_case "relocate-pool-$id" "$id")
    make_relocation_case "$dir" "$id"
    pool="$dir/pool"
    git -C "$dir/proj" worktree remove --force "$dir/dest"
    mkdir -p "$pool/1"
    printf '{}\n' > "$pool/treehouse-state.json"
    git -C "$dir/proj" worktree add -q "$pool/1/repo" "task-$id"
    printf '%s' "$pool/1/repo" > "$dir/fake/cwd"
    marker="$pool/1/.fm-slot-owner"
    if [ "$id" = rl106claimed ]; then
      printf 'task=someone-else\nhome=/elsewhere\n' > "$marker"
      run_relocation_refusal "$dir" "$id" "claimed by task someone-else" "slot claimed by another task" "$pool/1/repo"
      [ "$(cat "$marker")" = $'task=someone-else\nhome=/elsewhere' ] || fail "a refused relocation changed another task's claim"
    elif [ "$id" = rl106foreignhome ] || [ "$id" = rl106emptyhome ]; then
      mkdir "$dir/other-home"
      if [ "$id" = rl106foreignhome ]; then
        printf 'task=%s\nhome=%s\n' "$id" "$dir/other-home" > "$marker"
      else
        printf 'task=%s\nhome=\n' "$id" > "$marker"
      fi
      before=$(cat "$marker")
      run_relocation_refusal "$dir" "$id" "not this home" "slot claimed by same id outside this home" "$pool/1/repo"
      out=$(run_spawn "$dir" "$id" --relaunch --worktree "$pool/1/repo"); rc=$?
      expect_code 1 "$rc" "direct spawn must refuse the foreign home claim"$'\n'"$out"
      assert_contains "$out" "not this home" "direct spawn refused for the wrong reason"
      [ "$(cat "$marker")" = "$before" ] || fail "a refused relocation overwrote a foreign home claim"
    else
      if [ "$id" = rl106mine ]; then
        ln -s "$dir/home" "$dir/home-alias"
        printf 'task=%s\nhome=%s\n' "$id" "$dir/home-alias" > "$marker"
      fi
      out=$(run_control "$dir" "$id" relaunch --worktree "$pool/1/repo" --note "resume"); rc=$?
      expect_code 0 "$rc" "an unclaimed pool slot must relocate"$'\n'"$out"
      assert_grep "task=$id" "$marker" "relocation did not claim the pool slot for its task"
      assert_grep "home=$dir/home" "$marker" "the slot claim must name the owning home"
    fi
  done
  pass "relocation: a pool slot claimed by another task refuses, and an unclaimed one is claimed for the task"
}

test_concurrent_non_pool_relocations_publish_only_one_owner() {
  local dir second id=rl111race first_pid out rc first_rc i=0 before
  dir=$(new_case relocate-race-first "$id")
  make_relocation_case "$dir" "$id"
  set_case_meta_field "$dir" "$id" harness codex
  printf codex > "$dir/fake/becomes"
  second=$(new_case relocate-race-second "$id")
  mkdir -p "$second/home/data/$id"
  cp "$dir/home/data/$id/brief.md" "$second/home/data/$id/brief.md"
  cp "$dir/home/state/$id.meta" "$second/home/state/$id.meta"
  set_case_meta_field "$second" "$id" worktree "$second/missing"
  printf zsh > "$second/fake/command"
  printf codex > "$second/fake/becomes"
  printf '%s' "$second/missing" > "$second/fake/cwd"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' \
    "$dir/home" > "$second/home/.fm-secondmate-parent"
  printf -- '- mate - fixture (home: %s; scope: test; projects: project; added 2026-01-01)\n' \
    "$second/home" > "$dir/home/data/secondmates.md"
  before=$(cat "$second/home/state/$id.meta")
  : > "$dir/fake/hold-relocation-cd"
  run_spawn "$dir" "$id" --relaunch --worktree "$dir/dest" > "$dir/first.out" 2>&1 &
  first_pid=$!
  while [ ! -f "$dir/fake/relocation-cd-held" ] && kill -0 "$first_pid" 2>/dev/null && [ "$i" -lt 1000 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  if [ ! -f "$dir/fake/relocation-cd-held" ]; then
    : > "$dir/fake/relocation-cd-release"
    wait "$first_pid" || true
    fail "the first relocation never reached cwd handoff: $(cat "$dir/first.out")"
  fi
  out=$(run_spawn "$second" "$id" --relaunch --worktree "$dir/dest"); rc=$?
  : > "$dir/fake/relocation-cd-release"
  first_rc=0
  wait "$first_pid" || first_rc=$?
  expect_code 0 "$first_rc" "the lock-holding relocation failed: $(cat "$dir/first.out")"
  expect_code 1 "$rc" "the second home published into an acquired copy: $out"
  assert_contains "$out" "refusing to race relocation ownership" "concurrent relocation did not refuse under the shared lock"
  [ "$(meta_field "$dir" "$id" worktree)" = "$dir/dest" ] || fail "the first home did not publish its destination"
  [ "$(cat "$second/home/state/$id.meta")" = "$before" ] || fail "the second home published a competing owner"
  [ ! -s "$second/fake/literal" ] || fail "the second home launched into the first home's copy"
  out=$(run_spawn "$second" "$id" --relaunch --worktree "$dir/dest"); rc=$?
  expect_code 1 "$rc" "a retry ignored the published owner: $out"
  assert_contains "$out" "recorded by another task" "the published owner was not visible after lock release"
  pass "concurrent non-pool relocations from two homes publish and launch exactly one owner"
}

test_unpublished_relocation_releases_only_its_new_pool_claim() {
  local dir id variant pool marker out rc before
  for variant in cwd wiring brief publish existing published; do
    id="rl112$variant"
    dir=$(new_case "relocate-claim-abort-$variant" "$id")
    make_relocation_case "$dir" "$id"
    cp "$dir/home/data/$id/brief.md" "$dir/brief-before"
    pool="$dir/pool"
    git -C "$dir/proj" worktree remove --force "$dir/dest"
    mkdir -p "$pool/1" "$pool/2"
    printf '{}\n' > "$pool/treehouse-state.json"
    git -C "$dir/proj" worktree add -q "$pool/1/repo" "task-$id"
    git -C "$dir/proj" worktree add -q -f "$pool/2/repo" "task-$id"
    marker="$pool/1/.fm-slot-owner"
    before=$(cat "$dir/home/state/$id.meta")
    case "$variant" in
      cwd|existing)
        : > "$dir/fake/ignore-cd"
        if [ "$variant" = existing ]; then
          printf 'task=%s\nhome=%s\n' "$id" "$dir/home" > "$marker"
        fi
        out=$(run_spawn "$dir" "$id" --relaunch --worktree "$pool/1/repo"); rc=$?
        assert_contains "$out" "not its recorded worktree" "cwd failure did not reach handoff"
        rm "$dir/fake/ignore-cd"
        ;;
      wiring)
        printf 'owned by another tool\n' > "$dir/fake/foreign-wiring"
        printf '%s\n' "$pool/1/repo/.claude/settings.local.json" > "$dir/fake/foreign-wiring-path"
        out=$(run_spawn "$dir" "$id" --relaunch --worktree "$pool/1/repo"); rc=$?
        assert_present "$dir/fake/foreign-wiring-created" "wiring failure never reached late admission"
        [ "$(cat "$pool/1/repo/.claude/settings.local.json")" = 'owned by another tool' ] || fail "late refusal overwrote foreign wiring"
        ;;
      brief)
        printf '# Task\n' > "$dir/home/data/$id/brief.md"
        out=$(run_spawn "$dir" "$id" --relaunch --worktree "$pool/1/repo"); rc=$?
        assert_contains "$out" "must contain nonempty" "brief failure refused before the intended boundary"
        ;;
      publish)
        make_mv_failure_stub "$dir"
        out=$(FM_REAL_MV=$(command -v mv) FM_FAKE_META_PUBLISH_MV_FAIL="$dir/home/state/$id.meta" \
          run_control "$dir" "$id" relaunch --worktree "$pool/1/repo" --note "resume"); rc=$?
        assert_contains "$out" "replacement task record" "publication failure did not reach the replacement record"
        rm "$dir/fakebin/mv"
        ;;
      published)
        out=$(FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START=1 \
          run_control "$dir" "$id" relaunch --worktree "$pool/1/repo" --note "resume"); rc=$?
        ;;
    esac
    expect_code 1 "$rc" "the staged relocation abort did not fail ($variant): $out"
    if [ "$variant" = published ]; then
      [ "$(meta_field "$dir" "$id" worktree)" = "$pool/1/repo" ] || fail "a published relocation lost its destination"
      [ "$(cat "$marker")" = "$(printf 'task=%s\nhome=%s' "$id" "$dir/home")" ] || fail "post-publication failure removed the owning claim"
      continue
    fi
    [ "$(cat "$dir/home/state/$id.meta")" = "$before" ] || fail "an unpublished abort changed the prior record ($variant)"
    if [ "$variant" = existing ]; then
      [ "$(cat "$marker")" = "$(printf 'task=%s\nhome=%s' "$id" "$dir/home")" ] || fail "abort removed a pre-existing claim"
    else
      assert_absent "$marker" "unpublished abort leaked its new slot claim ($variant)"
    fi
    cp "$dir/brief-before" "$dir/home/data/$id/brief.md"
    out=$(run_control "$dir" "$id" relaunch --worktree "$pool/2/repo" --note "retry elsewhere"); rc=$?
    expect_code 0 "$rc" "a retry onto another copy failed ($variant): $out"
    [ "$(meta_field "$dir" "$id" worktree)" = "$pool/2/repo" ] || fail "retry did not publish the other copy ($variant)"
    assert_grep "home=$dir/home" "$pool/2/.fm-slot-owner" "retry did not claim the second copy"
    [ "$variant" = existing ] || assert_absent "$marker" "retry left the first copy claimed ($variant)"
  done
  pass "unpublished relocation aborts release new claims; pre-existing and published claims survive"
}

test_relocation_flag_is_scoped_to_relaunch() {
  local dir out rc id=rl107
  dir=$(new_case relocate-flags "$id")
  make_relocation_case "$dir" "$id"
  out=$(run_control "$dir" "$id" exit --worktree "$dir/dest"); rc=$?
  expect_code 1 "$rc" "--worktree must not apply to exit"$'\n'"$out"
  assert_contains "$out" "apply to 'relaunch' only" "the exit refusal must name the verb restriction"
  out=$(run_control "$dir" "$id" relaunch --worktree); rc=$?
  expect_code 1 "$rc" "--worktree needs a value"$'\n'"$out"
  assert_contains "$out" "--worktree requires a value" "the refusal must name the missing value"
  out=$(run_spawn "$dir" "$id" --worktree "$dir/dest"); rc=$?
  expect_code 1 "$rc" "a fresh spawn must refuse --worktree"$'\n'"$out"
  assert_contains "$out" "applies to --relaunch only" "the spawn refusal must name relaunch"
  out=$(run_spawn "$dir" "$id" --relaunch --worktree "$dir/dest"); rc=$?
  expect_code 0 "$rc" "the launch owner must accept a validated relocation on its own"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" worktree)" = "$dir/dest" ] || fail "the launch owner did not rebind the record"
  pass "relocation: --worktree belongs to relaunch only, and the launch owner repeats the proof itself"
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

  out=$(run_control "$dir" rl72 exit) || rc=$?
  expect_code 0 "$rc" "a pane that outlived its stopped server holds no agent, which is success"$'\n'"$out"
  assert_contains "$out" "already-stopped" \
    "the endpoint is there and idle, which is the ordinary already-stopped outcome"
  assert_not_contains "$out" "endpoint-gone" \
    "a pane that survived its server's restart was never gone"
  [ "$(meta_field "$dir" rl72 window)" = 'fmlab:%7' ] \
    || fail "exit must leave the recorded endpoint exactly as it found it"
  pass "fm-control exit: a herdr pane that outlived its stopped server is already-stopped, not gone"
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

test_exit_and_relaunch_remove_the_dialog_file() {
  local dir out rc
  dir=$(new_case dialog-file-exit rl70)
  add_ship_task "$dir" rl70 claude
  out=$(run_control "$dir" rl70 exit); rc=$?
  expect_code 0 "$rc" "exit should stop the agent"$'\n'"$out"
  [ ! -e "$dir/home/state/rl70.composer-dialog" ] \
    || fail "exit should remove the dialog file"

  dir=$(new_case dialog-file-relaunch rl71)
  add_ship_task "$dir" rl71 claude
  out=$(run_control "$dir" rl71 relaunch --note "replace the agent"); rc=$?
  expect_code 0 "$rc" "relaunch should replace the agent"$'\n'"$out"
  [ ! -e "$dir/home/state/rl71.composer-dialog" ] \
    || fail "relaunch should remove the dialog file"
  pass "fm-control removes the dialog file after exit and after relaunch"
}

# The lock release removes paths at or under the control lock with rm, so a
# recording rm sees the state directory at the moment of release without a
# second overlapping command.
test_exit_removes_the_dialog_file_before_releasing_the_lock() {
  local dir out rc lock sink trace
  dir=$(new_case dialog-file-order rl72)
  add_ship_task "$dir" rl72 claude
  lock="$dir/home/state/.control-rl72.lock"
  sink="$dir/home/state/rl72.composer-dialog"
  trace="$dir/fake/rm-trace"
  cat > "$dir/fakebin/rm" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    "$lock"|"$lock"/*)
      if [ -e "$sink" ]; then echo present; else echo absent; fi >> "$trace"
      break
      ;;
  esac
done
exec "$(command -v rm)" "\$@"
SH
  chmod +x "$dir/fakebin/rm"
  out=$(run_control "$dir" rl72 exit); rc=$?
  expect_code 0 "$rc" "exit should stop the agent"$'\n'"$out"
  [ ! -e "$lock" ] || fail "exit should release the control lock"
  [ "$(tail -n 1 "$trace" 2>/dev/null)" = absent ] \
    || fail "the dialog file must be gone when the control lock is released, got: $(cat "$trace" 2>/dev/null)"
  pass "fm-control exit removes the dialog file before it releases the control lock"
}

test_exit_and_relaunch_remove_the_dialog_file
test_exit_removes_the_dialog_file_before_releasing_the_lock
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
test_same_harness_relaunch_keeps_identity_and_reuses_the_endpoint
test_relaunch_refuses_before_exit_when_the_composer_holds_pending_text
test_relaunch_refuses_before_exit_when_the_composer_state_is_unproven
test_relaunch_from_linked_home_preserves_recorded_worktree
test_relaunch_preserves_durable_task_metadata
test_relaunch_keeps_a_recorded_pr_parseable_for_monitoring
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
test_pi_exclude_tools_follow_the_relaunch
test_exclude_tools_refusals_happen_before_the_agent_stops
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
test_relocation_rebinds_a_vanished_worktree_to_a_fresh_copy
test_relocation_checks_every_recorded_head_and_requires_evidence
test_relocation_refuses_every_unsafe_destination
test_relocation_refuses_unreadable_head_evidence
test_relocation_refuses_a_copy_another_local_home_records
test_relocation_never_overwrites_or_deletes_a_foreign_harness_file
test_relocation_proof_survives_every_failure_journal_rewrite
test_relocation_proof_survives_later_ordinary_launch_failure
test_relocation_requires_a_newer_ordinary_relaunch_checkpoint
test_relocation_claims_and_respects_pool_slot_ownership
test_concurrent_non_pool_relocations_publish_only_one_owner
test_unpublished_relocation_releases_only_its_new_pool_claim
test_relocation_flag_is_scoped_to_relaunch
test_herdr_relaunch_resumes_only_the_registered_pi_session
test_herdr_reclaim_adopts_a_pane_that_outlived_its_server
test_herdr_exit_reports_already_stopped_when_the_pane_outlived_its_server
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
