#!/usr/bin/env bash
# Exercise the real spawn entrypoint and terminal with a fake process-leased get.
# The herdr argument uses a generated, guarded lab session; the default uses private tmux.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
BACKEND=${1:-tmux}
command -v "$BACKEND" >/dev/null 2>&1 || { echo "skip: $BACKEND not found"; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-spawn-acquisition)
export HISTFILE="$TMP_ROOT/terminal-history"
LAB_HOME_HELPER="$ROOT/bin/fm-lab-home.sh"
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
FM_HOME="$TMP_ROOT/home"
export FM_HOME
"$LAB_HOME_HELPER" create "$FM_HOME" >/dev/null || fail "cannot create lab home"
LAB_TMUX_DIR=
HERDR_LAB_SESSION=
A_SPAWN_PID=
B_SPAWN_PID=
A_POLL_READY=
B_ALLOW=
cleanup_acquisition() {
  local rc=$?
  local pid alive gate
  for gate in "$A_POLL_READY" "$B_ALLOW"; do
    [ -z "$gate" ] || touch "$gate"
  done
  for pid in "$A_SPAWN_PID" "$B_SPAWN_PID"; do
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  done
  if [ -n "$A_SPAWN_PID$B_SPAWN_PID" ]; then
    for _ in $(seq 1 100); do
      alive=0
      for pid in "$A_SPAWN_PID" "$B_SPAWN_PID"; do
        [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null || alive=1
      done
      [ "$alive" -eq 1 ] || break
      /bin/sleep 0.02
    done
    for pid in "$A_SPAWN_PID" "$B_SPAWN_PID"; do
      [ -n "$pid" ] || continue
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
  fi
  if [ -n "$LAB_TMUX_DIR" ]; then
    TMUX_TMPDIR="$LAB_TMUX_DIR" "$REAL_TMUX" kill-server 2>/dev/null || true
    "$LAB_HOME_HELPER" teardown "$FM_HOME" || rc=1
  fi
  if [ -n "$HERDR_LAB_SESSION" ]; then
    "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
  fi
  fm_test_cleanup
  exit "$rc"
}
trap cleanup_acquisition EXIT
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
# Speed caller sleeps except marked real cleanup waits; acquisition uses /bin/sleep.
cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = 1 ] && [ -n "${FM_TEST_POLL_READY:-}" ]; then
  while [ ! -e "$FM_TEST_POLL_READY" ]; do /bin/sleep 0.02; done
fi
if [ "${1:-}" = 0.1 ] && [ "${FM_TEST_REAL_CLEANUP_SLEEP:-0}" = 1 ]; then
  if [ -n "${FM_TEST_CLEANUP_WAIT_STARTED:-}" ] && [ -e "${FM_TEST_CLEANUP_WATCH:-}" ]; then
    touch "$FM_TEST_CLEANUP_WAIT_STARTED"
  fi
  exec /bin/sleep "$@"
fi
exec /bin/sleep 0.02
SH
chmod +x "$FAKEBIN/sleep"
cat > "$FAKEBIN/treehouse" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = get ] || exit 0
. '$TMP_ROOT/get-config'
trap 'rm -f "\$LEASE"; exit 0' HUP INT TERM
trap 'rm -f "\$LEASE"' EXIT
printf '%s\n' "\$\$" > "\$PIDFILE"
touch "\$LEASE"
if [ "\$MODE" = slow ]; then
  while [ ! -e "\$ALLOW" ]; do /bin/sleep 0.02; done
fi
cd "\$DEST" || exit 1
touch "\$ARRIVED"
HISTFILE='$TMP_ROOT/get-history' /bin/bash --noprofile --norc -i
SH
chmod +x "$FAKEBIN/treehouse"
fm_test_fake_no_mistakes "$FAKEBIN"
fm_test_fake_gh "$FAKEBIN"
fm_test_fake_gh_axi "$FAKEBIN"
fm_fake_exit0 "$FAKEBIN" codex
fm_fake_exit0 "$FAKEBIN" claude
printf 'codex\n' > "$FM_HOME/config/crew-harness"
printf '%s\n' "${2:-off}" > "$FM_HOME/config/herdr-presentation-spaces"
PROJECT="$TMP_ROOT/project"
FOREIGN="$TMP_ROOT/foreign"
fm_git_init_commit "$PROJECT"
fm_git_init_commit "$FOREIGN"
DIRTY="$TMP_ROOT/dirty"
fm_git_init_commit "$DIRTY"
CLEAN="$TMP_ROOT/clean"
fm_git_init_commit "$CLEAN"
# A dirty acquired copy exercises refusal AFTER discovery, before launch.
printf 'uncommitted\n' >> "$DIRTY/README.md"
if [ "$BACKEND" = tmux ]; then
  REAL_TMUX=$(command -v tmux)
  LAB_TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$FM_HOME") || fail "cannot isolate tmux"
  export TMUX_TMPDIR="$LAB_TMUX_DIR"
  unset TMUX
  "$REAL_TMUX" -f /dev/null new-session -d -s firstmate -n sentinel '/bin/sleep 300' || fail "cannot start private tmux"
  "$REAL_TMUX" set-option -g default-shell /bin/bash
  "$REAL_TMUX" set-option -g default-command '/bin/bash --noprofile --norc'
  "$REAL_TMUX" set-environment -g PATH "$FAKEBIN:$PATH"
  "$REAL_TMUX" set-environment -g HISTFILE "$HISTFILE"
else
  HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-spawn-isolation-timeout-leaks-pool-slot) || fail "cannot name Herdr lab"
  "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "cannot provision Herdr lab"
  ws=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create --label sentinel | jq -er '.result.workspace.workspace_id') || fail 'cannot create sentinel workspace'
  sentinel=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab create --workspace "$ws" --cwd "$TMP_ROOT" --label sentinel --no-focus --env "HISTFILE=$HISTFILE" \
    | jq -er '.result.root_pane.pane_id') || fail 'cannot create sentinel'
  export HERDR_SESSION="$HERDR_LAB_SESSION"
  unset HERDR_PANE_ID HERDR_SOCKET_PATH
  REAL_PATH=$PATH
  export FM_GET_REAL_PATH="$REAL_PATH" FM_GET_LAB_HELPER="$HERDR_LAB_HELPER" FM_GET_LAB_SESSION="$HERDR_LAB_SESSION" FM_GET_FAKEBIN="$FAKEBIN"
  # Route every adapter CLI call through the helper, stripping its redundant
  # explicit session only after checking that it is this generated lab.
  cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
args=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = --session ]; then
    [ "$2" = "$FM_GET_LAB_SESSION" ] || exit 1
    shift 2
  else
    args+=("$1")
    shift
  fi
done
if [ "${args[0]:-} ${args[1]:-}" = 'tab create' ]; then
  args+=(--env "HISTFILE=$HISTFILE")
fi
for ((i=0; i<${#args[@]}; i++)); do
  if [ "${args[i]}" = 'treehouse get' ]; then
    args[i]="export PATH='$FM_GET_FAKEBIN':\$PATH; treehouse get"
  fi
done
PATH="$FM_GET_REAL_PATH" exec "$FM_GET_LAB_HELPER" run "$FM_GET_LAB_SESSION" "${args[@]}"
SH
  chmod +x "$FAKEBIN/herdr"
fi

for MODE in success slow spawning foreign dirty; do
  ID="get-cleanup-$MODE-$$"
  CASE="$TMP_ROOT/case-$MODE"
  mkdir -p "$CASE"
  LEASE="$CASE/lease"
  PIDFILE="$CASE/pid"
  ALLOW="$CASE/allow"
  ARRIVED="$CASE/arrived"
  DEST=$FOREIGN
  [ "$MODE" != spawning ] || DEST=$PROJECT
  HARNESS=codex
  [ "$MODE" != dirty ] || DEST=$DIRTY
  [ "$MODE" != foreign ] || HARNESS=claude
  [ "$MODE" != success ] || DEST=$CLEAN
  printf 'MODE=%q\nLEASE=%q\nPIDFILE=%q\nALLOW=%q\nARRIVED=%q\nDEST=%q\n' \
    "$MODE" "$LEASE" "$PIDFILE" "$ALLOW" "$ARRIVED" "$DEST" > "$TMP_ROOT/get-config"
  fm_test_spawn_brief "$FM_HOME" "$ID" 'Refused acquisition must release its process lease.'
  out=$(FM_ROOT_OVERRIDE='' FM_SPAWN_NO_GUARD=1 CLAUDE_CONFIG_DIR="$CASE/claude" PATH="$FAKEBIN:$PATH" \
    bash "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJECT" --backend "$BACKEND" --harness "$HARNESS" --allow-api-key --mode no-mistakes --yolo off 2>&1)
  rc=$?
  if [ "$MODE" = success ]; then
    expect_code 0 "$rc" "clean acquisition did not launch: $out"
    [ -e "$LEASE" ] || fail 'successful spawn released its acquisition lease'
    protected_lease=$LEASE
    protected_pid=$(cat "$PIDFILE")
    pass "$BACKEND successful launch retains its slot"
    continue
  fi
  [ "$rc" -ne 0 ] || fail "$MODE spawn unexpectedly launched: $out"
  case "$MODE" in
    slow|spawning) assert_contains "$out" 'did not enter an isolated worktree within 60s' 'missing deadline refusal' ;;
    foreign) assert_contains "$out" 'could not pre-register Claude workspace trust' 'missing foreign-copy refusal' ;;
    dirty) assert_contains "$out" 'not clean' 'missing post-acquisition refusal' ;;
  esac
  [ -f "$PIDFILE" ] || fail "fake get never started: $out"
  # Let a pending get complete only AFTER the caller has already refused.
  touch "$ALLOW"
  for _ in $(seq 1 100); do
    [ -e "$LEASE" ] || break
    /bin/sleep 0.02
  done
  [ ! -e "$LEASE" ] || fail "$MODE acquisition retained its slot after refusal: $out"
  pid=$(cat "$PIDFILE")
  ! kill -0 "$pid" 2>/dev/null || fail "$MODE left get subshell $pid alive"
  [ "$MODE" != slow ] || [ ! -e "$ARRIVED" ] || fail 'get completed after the deadline and stranded its slot'
  if [ "$BACKEND" = tmux ]; then
    windows=$("$REAL_TMUX" list-windows -t firstmate -F '#{window_name}') || fail 'spawn destroyed unrelated session'
    assert_not_contains "$windows" "fm-$ID" 'refused attempt pane remained'
    assert_contains "$windows" sentinel 'spawn closed a pane it did not create'
  fi
  if [ "$BACKEND" = herdr ]; then
    "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane get "$sentinel" >/dev/null || fail 'spawn closed an unrelated Herdr pane'
  fi
  if [ ! -e "$protected_lease" ] || ! kill -0 "$protected_pid" 2>/dev/null; then
    fail 'refused attempt ended another worker acquisition'
  fi
  pass "$BACKEND $MODE refusal returns its slot and ends its get subshell"
done

if [ "$BACKEND" = herdr ] && [ "${2:-off}" = off ]; then
  . "$ROOT/bin/backends/herdr.sh"
  herdr_acquisition_pane() {
    local tabs identity
    tabs=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab list) || return 1
    identity=$(printf '%s' "$tabs" | jq -er --arg label "fm-$1" '
      [.result.tabs[]? | select(.label == $label)]
      | select(length == 1) | .[0] | [.workspace_id, .tab_id] | @tsv
    ') || return 1
    PATH="$FAKEBIN:$PATH" fm_backend_herdr_pane_for_tab "$HERDR_LAB_SESSION" \
      "${identity%%$'\t'*}" "${identity#*$'\t'}"
  }
  A_CASE="$TMP_ROOT/case-contention-a"
  B_CASE="$TMP_ROOT/case-contention-b"
  mkdir -p "$A_CASE" "$B_CASE"
  A_ID="get-cleanup-contention-a-$$"
  B_ID="get-cleanup-contention-b-$$"
  A_LEASE="$A_CASE/lease"
  A_PIDFILE="$A_CASE/pid"
  A_ALLOW="$A_CASE/allow"
  A_ARRIVED="$A_CASE/arrived"
  A_POLL_READY="$A_CASE/poll-ready"
  A_CLEANUP_WATCH="$A_CASE/cleanup-watch"
  A_CLEANUP_WAIT="$A_CASE/cleanup-wait"
  A_OUT="$A_CASE/out"
  B_LEASE="$B_CASE/lease"
  B_PIDFILE="$B_CASE/pid"
  B_ALLOW="$B_CASE/allow"
  B_ARRIVED="$B_CASE/arrived"
  B_OUT="$B_CASE/out"
  B_HOME="$TMP_ROOT/home-contention-b"
  B_PROJECT="$TMP_ROOT/project-contention-b"
  B_CLEAN="$TMP_ROOT/clean-contention-b"
  "$LAB_HOME_HELPER" create "$B_HOME" >/dev/null || fail 'cannot create contention lab home'
  printf 'codex\n' > "$B_HOME/config/crew-harness"
  printf 'on\n' > "$B_HOME/config/herdr-presentation-spaces"
  fm_git_init_commit "$B_PROJECT"
  fm_git_init_commit "$B_CLEAN"
  protected_pane=$(herdr_acquisition_pane "get-cleanup-success-$$") || fail 'cannot record protected acquisition pane'
  printf 'MODE=%q\nLEASE=%q\nPIDFILE=%q\nALLOW=%q\nARRIVED=%q\nDEST=%q\n' \
    slow "$A_LEASE" "$A_PIDFILE" "$A_ALLOW" "$A_ARRIVED" "$FOREIGN" > "$TMP_ROOT/get-config"
  fm_test_spawn_brief "$FM_HOME" "$A_ID" 'Refused acquisition must wait for the shared presentation lock.'
  FM_ROOT_OVERRIDE='' FM_SPAWN_NO_GUARD=1 CLAUDE_CONFIG_DIR="$A_CASE/claude" PATH="$FAKEBIN:$PATH" \
    FM_TEST_POLL_READY="$A_POLL_READY" FM_TEST_REAL_CLEANUP_SLEEP=1 \
    FM_TEST_CLEANUP_WATCH="$A_CLEANUP_WATCH" FM_TEST_CLEANUP_WAIT_STARTED="$A_CLEANUP_WAIT" \
    bash "$ROOT/bin/fm-spawn.sh" "$A_ID" "$PROJECT" --backend herdr --harness codex --allow-api-key --mode no-mistakes --yolo off \
    > "$A_OUT" 2>&1 &
  A_SPAWN_PID=$!
  for _ in $(seq 1 1000); do
    [ ! -s "$A_PIDFILE" ] || [ ! -e "$A_LEASE" ] || break
    kill -0 "$A_SPAWN_PID" 2>/dev/null || break
    /bin/sleep 0.02
  done
  [ -s "$A_PIDFILE" ] && [ -e "$A_LEASE" ] || fail "contention A get never held its lease: $(cat "$A_OUT")"
  a_get_pid=$(cat "$A_PIDFILE")
  kill -0 "$a_get_pid" 2>/dev/null || fail 'contention A get exited before presentation contention'
  a_pane=$(herdr_acquisition_pane "$A_ID") || fail 'cannot record exact contention A pane'
  B_PARENT_OUT=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create --cwd "$B_PROJECT" --label firstmate --no-focus) \
    || fail 'cannot establish contention B parent workspace'
  B_PARENT=$(printf '%s' "$B_PARENT_OUT" | jq -er '.result.workspace.workspace_id') || fail 'contention B parent returned no workspace'
  B_PARENT_PANE=$(printf '%s' "$B_PARENT_OUT" | jq -er '.result.root_pane.pane_id') || fail 'contention B parent returned no pane'
  B_SOCKET=$(PATH="$FAKEBIN:$PATH" fm_backend_herdr_presentation_session_socket_path "$HERDR_LAB_SESSION") \
    || fail 'cannot resolve contention B exact session socket'
  SESSION_LOCK=$(PATH="$FAKEBIN:$PATH" fm_backend_herdr_presentation_session_lock_path "$HERDR_LAB_SESSION") \
    || fail 'cannot resolve shared contention presentation lock'
  printf 'MODE=%q\nLEASE=%q\nPIDFILE=%q\nALLOW=%q\nARRIVED=%q\nDEST=%q\n' \
    slow "$B_LEASE" "$B_PIDFILE" "$B_ALLOW" "$B_ARRIVED" "$B_CLEAN" > "$TMP_ROOT/get-config"
  fm_test_spawn_brief "$B_HOME" "$B_ID" 'Projected acquisition must survive another home refusing its pending get.'
  FM_HOME="$B_HOME" FM_ROOT_OVERRIDE='' FM_SPAWN_NO_GUARD=1 CLAUDE_CONFIG_DIR="$B_CASE/claude" PATH="$FAKEBIN:$PATH" \
    HERDR_PANE_ID="$B_PARENT_PANE" HERDR_SOCKET_PATH="$B_SOCKET" FM_TEST_POLL_READY="$B_ALLOW" \
    bash "$ROOT/bin/fm-spawn.sh" "$B_ID" "$B_PROJECT" --backend herdr --harness codex --allow-api-key --mode no-mistakes --yolo off \
    > "$B_OUT" 2>&1 &
  B_SPAWN_PID=$!
  for _ in $(seq 1 1000); do
    [ ! -s "$B_PIDFILE" ] || [ ! -e "$B_LEASE" ] || break
    kill -0 "$B_SPAWN_PID" 2>/dev/null || break
    /bin/sleep 0.02
  done
  [ -s "$B_PIDFILE" ] && [ -e "$B_LEASE" ] || fail "contention B get never held its lease: $(cat "$B_OUT")"
  b_get_pid=$(cat "$B_PIDFILE")
  kill -0 "$b_get_pid" 2>/dev/null || fail 'contention B get exited before presentation contention'
  [ "$(cat "$SESSION_LOCK/pid")" = "$B_SPAWN_PID" ] || fail 'contention B did not hold the shared session presentation lock'
  B_JOURNAL=$(fm_backend_herdr_projection_journal_path "$B_HOME/state" "$B_ID")
  b_pane=$(fm_backend_herdr_projection_journal_field "$B_JOURNAL" pane_id) || fail 'contention B did not bind a projected pane'
  [ "$(fm_backend_herdr_projection_journal_field "$B_JOURNAL" parent_workspace_id)" = "$B_PARENT" ] \
    || fail 'contention B projected under the wrong exact parent workspace'
  touch "$A_POLL_READY"
  for _ in $(seq 1 3000); do
    grep -Fq 'did not enter an isolated worktree within 60s' "$A_OUT" && break
    kill -0 "$A_SPAWN_PID" 2>/dev/null || break
    /bin/sleep 0.02
  done
  assert_contains "$(cat "$A_OUT")" 'did not enter an isolated worktree within 60s' 'contention A missed the unchanged isolation refusal'
  touch "$A_CLEANUP_WATCH"
  for _ in $(seq 1 1000); do
    [ ! -e "$A_CLEANUP_WAIT" ] || break
    kill -0 "$A_SPAWN_PID" 2>/dev/null || break
    /bin/sleep 0.02
  done
  [ -e "$A_CLEANUP_WAIT" ] || fail "contention A did not enter serialized cleanup waiting: $(cat "$A_OUT")"
  /bin/sleep 10
  kill -0 "$A_SPAWN_PID" 2>/dev/null || fail "contention A cleanup returned before B released the presentation lock: $(cat "$A_OUT")"
  kill -0 "$B_SPAWN_PID" 2>/dev/null || fail "contention B exited while its acquisition was blocked: $(cat "$B_OUT")"
  [ "$(cat "$SESSION_LOCK/pid")" = "$B_SPAWN_PID" ] || fail 'contention B lost the shared presentation lock while blocked'
  [ -e "$A_LEASE" ] && kill -0 "$a_get_pid" 2>/dev/null || fail 'contention A lost its process lease before serialized cleanup'
  [ -e "$B_LEASE" ] && kill -0 "$b_get_pid" 2>/dev/null || fail 'contention A cleanup ended contention B acquisition'
  [ ! -e "$A_ARRIVED" ] && [ ! -e "$B_ARRIVED" ] || fail 'blocked contention acquisition entered a worktree early'
  [ "$(PATH="$FAKEBIN:$PATH" fm_backend_herdr_pane_presence_state "$HERDR_LAB_SESSION" "$a_pane")" = present ] \
    || fail 'contention A pane disappeared before the presentation lock was released'
  [ "$(PATH="$FAKEBIN:$PATH" fm_backend_herdr_pane_presence_state "$HERDR_LAB_SESSION" "$b_pane")" = present ] \
    || fail 'contention A cleanup closed contention B pane'
  pass 'herdr contention keeps both acquisition leases past the former cleanup timeout'
  touch "$B_ALLOW"
  for _ in $(seq 1 3000); do
    kill -0 "$B_SPAWN_PID" 2>/dev/null || break
    /bin/sleep 0.02
  done
  ! kill -0 "$B_SPAWN_PID" 2>/dev/null || fail "contention B launch never returned: $(cat "$B_OUT")"
  wait "$B_SPAWN_PID"
  b_rc=$?
  B_SPAWN_PID=
  expect_code 0 "$b_rc" "contention B clean isolated acquisition did not launch: $(cat "$B_OUT")"
  [ -e "$B_ARRIVED" ] || fail 'contention B never acquired its clean isolated worktree'
  [ -f "$B_HOME/state/$B_ID.meta" ] || fail 'contention B launch did not publish its task record'
  for _ in $(seq 1 3000); do
    kill -0 "$A_SPAWN_PID" 2>/dev/null || break
    /bin/sleep 0.02
  done
  ! kill -0 "$A_SPAWN_PID" 2>/dev/null || fail "contention A cleanup never returned after B launch: $(cat "$A_OUT")"
  wait "$A_SPAWN_PID"
  a_rc=$?
  A_SPAWN_PID=
  [ "$a_rc" -ne 0 ] || fail "contention A unexpectedly launched: $(cat "$A_OUT")"
  [ ! -e "$SESSION_LOCK" ] && [ ! -L "$SESSION_LOCK" ] || fail 'contention cleanup retained the shared presentation lock'
  [ "$(PATH="$FAKEBIN:$PATH" fm_backend_herdr_pane_presence_state "$HERDR_LAB_SESSION" "$a_pane")" = dead ] \
    || fail "contention A exact pane was not confirmed gone: $(cat "$A_OUT")"
  for _ in $(seq 1 100); do
    [ -e "$A_LEASE" ] || kill -0 "$a_get_pid" 2>/dev/null || break
    /bin/sleep 0.02
  done
  [ ! -e "$A_LEASE" ] || fail 'contention A retained its process lease after cleanup'
  ! kill -0 "$a_get_pid" 2>/dev/null || fail 'contention A get survived exact-pane cleanup'
  [ ! -e "$A_ARRIVED" ] || fail 'contention A completed acquisition after its isolation refusal'
  [ -e "$B_LEASE" ] && kill -0 "$b_get_pid" 2>/dev/null || fail 'contention A cleanup ended the successfully launched B acquisition'
  [ -e "$protected_lease" ] && kill -0 "$protected_pid" 2>/dev/null || fail 'contention cleanup ended the previous successful acquisition'
  for pane in "$b_pane" "$protected_pane" "$sentinel"; do
    [ "$(PATH="$FAKEBIN:$PATH" fm_backend_herdr_pane_presence_state "$HERDR_LAB_SESSION" "$pane")" = present ] \
      || fail "contention cleanup closed surviving pane $pane"
  done
  pass 'herdr contention releases only the refused acquisition after projected launch'
fi
