#!/usr/bin/env bash
# Exercise the real spawn entrypoint and terminal with a fake process-leased get.
# --herdr uses only a generated, guarded lab session; the default uses private tmux.
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
cleanup_acquisition() {
  local rc=$?
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
# Speed only the caller's polling sleeps. The acquisition uses /bin/sleep.
cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
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
