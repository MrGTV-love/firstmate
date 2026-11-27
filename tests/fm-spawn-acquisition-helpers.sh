#!/usr/bin/env bash
# Shared setup of tests/fm-spawn-acquisition-cleanup.test.sh and tests/fm-spawn-acquisition-real-treehouse.test.sh: a lab
# home, the cleanup trap, the fake sleep and process-leased `treehouse get`, the project and copy checkouts, the private
# tmux (or the guarded Herdr lab), and the shell clock. The sourcing script sets BACKEND first; its second argument names
# the Herdr presentation mode.
# The scripts that source this file read globals it assigns, so they read as "unused" here, and ROOT comes from
# tests/fixtures.sh, which each of them loads first.
# shellcheck disable=SC2034,SC2153
TMP_ROOT=$(fm_test_tmproot fm-spawn-acquisition)
export HISTFILE="$TMP_ROOT/terminal-history"
LAB_HOME_HELPER="$ROOT/bin/fm-lab-home.sh"
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
FM_HOME="$TMP_ROOT/home"
export FM_HOME
"$LAB_HOME_HELPER" create "$FM_HOME" >/dev/null || fail "cannot create lab home"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
LAB_TMUX_DIR=
HERDR_LAB_SESSION=
A_SPAWN_PID=
B_SPAWN_PID=
A_POLL_READY=
B_ALLOW=
SESSION_LOCK=
# fm-spawn.sh detaches a refresh, and panes leave programs behind. Any tmux client
# they start recreates tmux-<uid> in the socket directory, so stop what this test
# owns first. A process can fork after a sweep reads the process list, so only a
# sweep that finds nothing proves that nothing is left to write.
stop_owned_children() {
  local swept
  for _ in $(seq 1 50); do
    swept=$("$ROOT/bin/fm-test-reap-orphans.sh" --owner-pid "$$" --root "$TMP_ROOT") || return 1
    [ -n "$swept" ] || return 0
  done
  return 1
}
cleanup_acquisition() {
  local rc=$?
  local pid alive gate lab_server
  [ -z "$SESSION_LOCK" ] || fm_lock_release "$SESSION_LOCK" || rc=1
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
    lab_server=$(TMUX_TMPDIR="$LAB_TMUX_DIR" "$REAL_TMUX" display-message -p '#{pid}' 2>/dev/null) || lab_server=
    TMUX_TMPDIR="$LAB_TMUX_DIR" "$REAL_TMUX" kill-server 2>/dev/null || true
    # The sweep reaches a pane's program only once the server is gone. A server
    # that outlives this wait makes teardown refuse, so it cannot pass unseen.
    for _ in $(seq 1 500); do
      [ -n "$lab_server" ] || break
      kill -0 "$lab_server" 2>/dev/null || break
      /bin/sleep 0.02
    done
    stop_owned_children || rc=1
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
if [ "${1:-}" = 1 ] && [ -n "${FM_TEST_TICK_FILE:-}" ]; then
  echo tick >> "$FM_TEST_TICK_FILE"
fi
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
# The real `treehouse pool-dir` always names the project's pool folder; every copy here is a plain folder, so the folder
# it names (empty) holds none of them, and the spawn may use one as an ordinary copy.
mkdir -p "$TMP_ROOT/treehouse-pool"
cat > "$FAKEBIN/treehouse" <<SH
#!/usr/bin/env bash
[ "\${1:-}" != pool-dir ] || { printf '%s\n' '$TMP_ROOT/treehouse-pool'; exit 0; }
[ "\${1:-}" = get ] || exit 0
. '$TMP_ROOT/get-config'
if [ "\$MODE" = passover ] && [ ! -e "\$FIRSTPID" ]; then
  # The first get of a pass-over case enters copy A and opens its subshell there, staying its parent, as the real get does.
  printf '%s\n' "\$\$" > "\$FIRSTPID"
  cd "\$PASSED" || exit 1
  HISTFILE='$TMP_ROOT/get-history' /bin/bash --noprofile --norc -c 'printf "%s\n" "\$\$" > "\$1"; exec /bin/bash --noprofile --norc -i' _ "\$ASHELL"
  exit 0
fi
[ "\$MODE" != passover ] || MODE=slow
trap 'rm -f "\$LEASE"; exit 0' HUP INT TERM
# A get that ignores an interrupt stands in for one that no interrupt can prove cancelled.
[ "\${IGNORE_INT:-0}" != 1 ] || trap '' INT
trap 'rm -f "\$LEASE"' EXIT
printf '%s\n' "\$\$" > "\$PIDFILE"
touch "\$LEASE"
if [ "\$MODE" = slow ]; then
  while [ ! -e "\$ALLOW" ]; do /bin/sleep 0.02; done
fi
if [ "\$MODE" = late ] || [ "\$MODE" = laterexit ]; then
  # Take longer than the old 60-poll window: wait for 75 one-second polls.
  while [ "\$(wc -l < "\$TICKS")" -lt 75 ]; do /bin/sleep 0.02; done
  # Reach the worktree while the poll that follows is still reading the pane's foreground.
  [ "\$MODE" != late ] || /bin/sleep 0.6
fi
if [ "\$MODE" = earlyexit ]; then
  while [ "\$(wc -l < "\$TICKS" 2>/dev/null || echo 0)" -lt 1 ]; do /bin/sleep 0.02; done
fi
if [ "\$MODE" = exits ] || [ "\$MODE" = laterexit ] || [ "\$MODE" = earlyexit ]; then
  rm -f "\$LEASE"
  echo 'treehouse: simulated failure' >&2
  exit 1
fi
cd "\$DEST" || exit 1
touch "\$ARRIVED"
if [ "\$MODE" = busy ]; then
  # Hold the pane in a foreground program that never reads a typed line. It is one long-lived process: a short-lived
  # child in the copy can exit while the idle proof reads it, and a process the proof cannot read is never excused.
  python3 -c 'import os, sys, time
while not os.path.exists(sys.argv[1]): time.sleep(0.02)' "\$ALLOW"
fi
HISTFILE='$TMP_ROOT/get-history' /bin/bash --noprofile --norc -i
SH
chmod +x "$FAKEBIN/treehouse"
# The real `treehouse` is a native program, so the kernel names its process `treehouse` and the slot rules can tell a
# launcher this spawn opened from any other process in a copy. A bare shell script would be named `bash`, so the fake
# runs its script body under a renamed copy of bash and shows `treehouse get` as its own command line.
mv "$FAKEBIN/treehouse" "$FAKEBIN/treehouse.body"
mkdir -p "$FAKEBIN/real"
cp /bin/bash "$FAKEBIN/real/treehouse"
[ "$(uname)" != Darwin ] || codesign -f -s - "$FAKEBIN/real/treehouse" >/dev/null 2>&1 || true
cat > "$FAKEBIN/treehouse" <<SH
#!/usr/bin/env bash
exec -a treehouse '$FAKEBIN/real/treehouse' -c "\$(cat '$FAKEBIN/treehouse.body')" treehouse "\$@"
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
LATE="$TMP_ROOT/late"
fm_git_init_commit "$LATE"
# An ordinary caller checkout must not lend its origin to acquired origin-less copies.
CALLER="$TMP_ROOT/caller"
fm_git_init_commit "$CALLER"
git -C "$CALLER" config remote.origin.url "file://$TMP_ROOT/caller-only-origin.git"
cd "$CALLER" || fail "cannot enter caller checkout"
# A dirty acquired copy exercises refusal AFTER discovery, before launch.
printf 'uncommitted\n' >> "$DIRTY/README.md"
if [ "$BACKEND" = tmux ]; then
  REAL_TMUX=$(command -v tmux)
  LAB_TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$FM_HOME") || fail "cannot isolate tmux"
  export TMUX_TMPDIR="$LAB_TMUX_DIR"
  unset TMUX
  # The unrelated sentinel lives exactly as long as this test process, so only
  # spawn, never a wall-clock expiry, can remove it before teardown.
  "$REAL_TMUX" -f /dev/null new-session -d -s firstmate -n sentinel \
    "while kill -0 $$ 2>/dev/null; do /bin/sleep 1; done" || fail "cannot start private tmux"
  SENTINEL_WINDOW=$("$REAL_TMUX" display-message -p -t firstmate:sentinel '#{window_id}') || fail 'cannot identify sentinel window'
  SENTINEL_PID=$("$REAL_TMUX" display-message -p -t firstmate:sentinel '#{pane_pid}') || fail 'cannot identify sentinel pane'
  "$REAL_TMUX" set-option -g default-shell /bin/bash
  "$REAL_TMUX" set-option -g default-command '/bin/bash --noprofile --norc'
  "$REAL_TMUX" set-environment -g PATH "$FAKEBIN:$PATH"
  "$REAL_TMUX" set-environment -g HISTFILE "$HISTFILE"
  # A busy host makes the foreground read slow: FM_TEST_TTY_STALL seconds on the
  # pane tty lookup, once 75 polls have passed.
  cat > "$FAKEBIN/tmux" <<SH
#!/usr/bin/env bash
if [ -n "\${FM_TEST_TTY_STALL:-}" ] && [ "\$(wc -l < "\$FM_TEST_TICK_FILE")" -ge 75 ]; then
  case "\$*" in *'#{pane_tty}'*) /bin/sleep "\$FM_TEST_TTY_STALL" ;; esac
fi
exec '$REAL_TMUX' "\$@"
SH
  chmod +x "$FAKEBIN/tmux"
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
load_acquisition_herdr() {
  # The adapter is not followed from this test; bin/backends/herdr.sh is still linted as its own root.
  # shellcheck source=/dev/null
  . "$ROOT/bin/backends/herdr.sh"
}

# Each fake poll adds FM_TEST_TICK_SECONDS to the shell clock, so a run can reach
# a wall-clock bound without waiting for it. The clock holds still until the fake
# get has started (FM_TEST_TICK_GATE exists), so a slow host cannot spend the
# no-progress allowance before the get under test has begun.
cat > "$TMP_ROOT/clock.sh" <<'SH'
sleep() {
  if [ "${1:-}" = 1 ] && [ -n "${FM_TEST_TICK_SECONDS:-}" ] && [ -e "${FM_TEST_TICK_GATE:-/}" ]; then
    SECONDS=$((SECONDS + FM_TEST_TICK_SECONDS))
  fi
  command sleep "$@"
}
SH
