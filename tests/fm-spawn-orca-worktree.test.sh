#!/usr/bin/env bash
# tests/fm-spawn-orca-worktree.test.sh - regression coverage for the
# backend=orca carve-outs in bin/fm-spawn.sh's worktree-entry proof (#4991,
# bacadc4).
#
# spawn_current_path (bin/fm-spawn.sh) has no `orca` case, because Orca hands
# back a terminal that is already bound to the worktree it just created -
# there is no shared pane whose cwd firstmate must poll for. Without an
# explicit skip, spawn_assert_agent_worktree's post-launch proof would poll
# spawn_current_path in a loop, read nothing but empty output every time, and
# hard-refuse EVERY Orca launch once its 20-read deadline elapsed. This test
# spawns a real (fake-Orca-backed) task and asserts it succeeds and records
# the worktree Orca actually created, proving the skip does not just avoid an
# error but lets a genuine Orca launch complete.
#
# The matching relaunch-side carve-out at the `[ "$RELAUNCH" -eq 1 ] &&
# [ "$BACKEND" = orca ]` branch is guarded by an earlier, unconditional gate:
# fm_control_backend_state_verified (bin/fm-control-lib.sh) only recognizes
# tmux and herdr as having a recovery-grade agent-state classifier, so any
# `--relaunch` on backend=orca is refused before that branch can ever run.
# The second test below pins that refusal so a future change that starts
# routing orca through the classifier does not silently reach the untested
# branch without also covering it.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-orca-worktree)

# make_orca_fakebin <dir>: a fake `orca` CLI that performs a REAL `git
# worktree add` for `worktree create` (so fm_task_copy_isolated's checks are
# exercised against a genuine, isolated worktree) and answers every other
# lifecycle call (status/repo/terminal/send) with the minimal JSON shape
# bin/backends/orca.sh's node-based parsers accept.
make_orca_fakebin() {
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
DIR="${FM_TEST_ORCA_DIR:?}"
case "$1 $2" in
  "status --json")
    printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
    exit 0
    ;;
  "repo show")
    exit 1
    ;;
  "repo add")
    printf '{"ok":true,"result":{"repo":{"id":"repo1"}}}\n'
    exit 0
    ;;
  "worktree create")
    name=
    prev=
    for a in "$@"; do
      [ "$prev" = --name ] && name=$a
      prev=$a
    done
    wt="$DIR/orca-worktrees/$name"
    mkdir -p "$DIR/orca-worktrees"
    git -C "$DIR/project" worktree add --quiet -b "orca-$name" "$wt" >&2 || exit 1
    printf '{"ok":true,"result":{"worktree":{"id":"wt-%s","path":"%s"}}}\n' "$name" "$wt"
    exit 0
    ;;
  "terminal create")
    [ "${FM_TEST_ORCA_TERMINAL_FAIL:-0}" != 1 ] || exit 1
    if [ -n "${FM_TEST_ORCA_LATE_META:-}" ]; then
      printf 'kind=ship\n' > "$FM_TEST_ORCA_LATE_META"
    fi
    if [ -n "${FM_TEST_ORCA_LATE_BACKLOG:-}" ]; then
      printf '## In flight\n- [ ] %s - relocated after early admission\n' "$FM_TEST_ORCA_TASK_ID" > "$FM_TEST_ORCA_LATE_BACKLOG"
    fi
    # A real Orca terminal runs a shell whose working directory is the worktree. With FM_TEST_ORCA_SHELL=1 the fake
    # starts one (its pid goes to terminal-pids for the test to stop).
    if [ "${FM_TEST_ORCA_SHELL:-0}" = 1 ]; then
      id=
      prev=
      for a in "$@"; do
        [ "$prev" = --worktree ] && id=${a#id:}
        prev=$a
      done
      ( cd "$DIR/orca-worktrees/${id#wt-}" && exec sh -c 'while :; do sleep 1; done' ) </dev/null >/dev/null 2>&1 &
      printf '%s\n' "$!" >>"$DIR/terminal-pids"
    fi
    printf '{"ok":true,"result":{"terminal":{"handle":"term-1"}}}\n'
    exit 0
    ;;
  "terminal send")
    printf '{"ok":true}\n'
    exit 0
    ;;
  "worktree rm")
    if [ "${FM_TEST_ORCA_REMOVE_FAIL:-0}" = 1 ]; then
      : > "$DIR/remove-refused"
      exit 1
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fb/orca"
  printf '%s\n' "$fb"
}

test_orca_fresh_spawn_enters_the_worktree_it_created() {
  local case_dir home id=orca-fresh-a1 fb out status wt_recorded
  case_dir="$TMP_ROOT/fresh"
  home="$case_dir/home"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'manual\n' > "$home/config/backlog-backend"
  fm_git_init_commit "$case_dir/project"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise an Orca-backed spawn for $id.

## Firstmate spec
Confirm the launch enters the worktree Orca created for it.
EOF
  fb=$(make_orca_fakebin "$case_dir")

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" PATH="$fb:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --backend orca 2>&1)
  status=$?

  expect_code 0 "$status" "an Orca-backed spawn should succeed"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"$'\n'"$out"
  wt_recorded=$(grep '^worktree=' "$home/state/$id.meta" | cut -d= -f2-)
  [ -n "$wt_recorded" ] || fail "meta did not record a worktree"
  [ -d "$wt_recorded" ] || fail "the recorded worktree '$wt_recorded' does not exist"
  [ "$(cd "$wt_recorded" && git rev-parse --show-toplevel)" = "$(cd "$wt_recorded" && pwd -P)" ] \
    || fail "the recorded worktree is not the isolated worktree Orca created"
  pass "an Orca-backed fresh spawn enters the worktree Orca created for it, instead of hard-refusing on the post-launch proof"
}

test_orca_relaunch_is_refused_before_the_worktree_carveout_could_run() {
  local case_dir home proj wt id=orca-relaunch-a2 out status
  case_dir="$TMP_ROOT/relaunch"
  home="$case_dir/home"
  proj="$case_dir/proj"
  wt="$case_dir/wt"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  printf 'manual\n' > "$home/config/backlog-backend"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise a relaunch attempt against a recorded Orca task.

## Firstmate spec
Confirm the relaunch is refused before any worktree re-entry logic runs.
EOF
  {
    echo "window=fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=codex"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "backend=orca"
    echo "orca_worktree_id=wt-1::$wt"
    echo "terminal=term-1"
  } > "$home/state/$id.meta"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$id" --relaunch 2>&1)
  status=$?

  expect_code 1 "$status" "a relaunch against a recorded Orca task should refuse"$'\n'"$out"
  assert_contains "$out" "no recovery-grade agent-state classifier" \
    "the refusal should name the missing classifier, proving relaunch never reaches the worktree carve-out"
  pass "a relaunch against an Orca-backed task is refused before the RELAUNCH+orca worktree carve-out could run"
}

# R4-2: a fresh Orca worktree is created by this spawn; it is not a Treehouse pool slot, so the pool slot's idle proof does
# not run on it. The Orca terminal's own shell sits in the worktree, and the spawn still proceeds. With an origin ahead of
# the project, the worktree is moved forward to origin's tip.
stop_orca_shells() { # <case-dir>: stops only the shells the fake recorded
  local pid
  [ -f "$1/terminal-pids" ] || return 0
  while IFS= read -r pid; do
    kill "$pid" 2>/dev/null || true
  done <"$1/terminal-pids"
  rm -f "$1/terminal-pids"
}

orca_shell_case() { # <name> <id> <with-origin 0|1>: runs the spawn; sets ORCA_OUT ORCA_STATUS ORCA_HOME ORCA_TIP
  local case_dir home id=$2 fb pub
  case_dir="$TMP_ROOT/$1"
  home="$case_dir/home"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'manual\n' > "$home/config/backlog-backend"
  fm_git_init_commit "$case_dir/project"
  ORCA_TIP=
  if [ "$3" = 1 ]; then
    git clone --quiet --bare "$case_dir/project" "$case_dir/origin.git"
    git -C "$case_dir/project" remote add origin "file://$case_dir/origin.git"
    git -C "$case_dir/project" fetch --quiet origin
    git -C "$case_dir/project" remote set-head origin --auto >/dev/null
    pub="$case_dir/publisher"
    git clone --quiet "file://$case_dir/origin.git" "$pub"
    printf 'from origin\n' > "$pub/advanced.txt"
    git -C "$pub" add advanced.txt
    git -C "$pub" -c user.name=Tests -c user.email=tests@example.invalid commit -qm advance
    git -C "$pub" push --quiet origin HEAD
    ORCA_TIP=$(git -C "$pub" rev-parse HEAD)
  fi
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise an Orca-backed spawn for $id.

## Firstmate spec
Confirm the launch proceeds while the Orca terminal's shell sits in the worktree.
EOF
  fb=$(make_orca_fakebin "$case_dir")
  ORCA_OUT=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" FM_TEST_ORCA_SHELL=1 PATH="$fb:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --backend orca 2>&1)
  ORCA_STATUS=$?
  [ -s "$case_dir/terminal-pids" ] || { stop_orca_shells "$case_dir"; fail "the fake Orca terminal started no shell, so the case proves nothing"; }
  stop_orca_shells "$case_dir"
  ORCA_HOME=$home
}

test_orca_fresh_spawn_proceeds_with_its_terminal_shell_in_the_worktree() {
  orca_shell_case orca-shell orca-shell-a3 0
  expect_code 0 "$ORCA_STATUS" "an Orca spawn whose terminal shell sits in its worktree should proceed"$'\n'"$ORCA_OUT"
  assert_contains "$ORCA_OUT" "spawned orca-shell-a3" "spawn did not report success"$'\n'"$ORCA_OUT"
  pass "a fresh Orca spawn proceeds while its own terminal's shell sits in the worktree it created"
}

test_orca_fresh_spawn_with_an_origin_moves_to_origins_tip() {
  local wt
  orca_shell_case orca-origin orca-origin-a4 1
  expect_code 0 "$ORCA_STATUS" "an Orca spawn with an origin should proceed"$'\n'"$ORCA_OUT"
  wt=$(grep '^worktree=' "$ORCA_HOME/state/orca-origin-a4.meta" | cut -d= -f2-)
  [ "$(git -C "$wt" rev-parse HEAD)" = "$ORCA_TIP" ] || fail "the Orca worktree is at $(git -C "$wt" rev-parse HEAD), not origin's tip $ORCA_TIP"
  pass "a fresh Orca spawn with an origin moves its worktree forward to origin's tip"
}
test_orca_abort_recovery_obeys_task_set_custody() {
  local held case_dir home id fb out status lock
  . "$ROOT/bin/fm-wake-lib.sh"
  for held in 0 1; do
    id="orca-recovery-$held-$$"
    case_dir="$TMP_ROOT/$id"
    home="$case_dir/home"
    fm_test_spawn_home "$home" codex
    printf 'manual\n' > "$home/config/backlog-backend"
    fm_test_spawn_brief "$home" "$id"
    fm_git_init_commit "$case_dir/project"
    fb=$(make_orca_fakebin "$case_dir")
    lock=$(fm_task_set_lock_path "$home/state") || fail 'cannot resolve fixture task-set lock'
    if [ "$held" = 1 ]; then
      fm_lock_try_acquire "$lock" || fail 'cannot hold fixture task set'
      fm_lock_set_role "$lock" forced-teardown || fail 'cannot label fixture task-set holder'
    fi
    status=0
    out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" \
      FM_TEST_ORCA_TERMINAL_FAIL=1 FM_TEST_ORCA_REMOVE_FAIL=1 PATH="$fb:$PATH" \
      "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --backend orca 2>&1) || status=$?
    printf 'Orca recovery held=%s exit=%s\n%s\n' "$held" "$status" "$out"
    expect_code 1 "$status" 'Orca terminal failure must abort the spawn'
    if [ "$held" = 1 ]; then
      assert_contains "$out" 'task set is locked by a forced teardown' 'Orca recovery bypassed task-set contention'
      [ ! -e "$home/state/$id.meta" ] || fail 'Orca recovery published inside forced teardown custody'
      assert_grep "wt-fm-$id" "$home/state/$id.status" 'Orca retained worktree is not named by a durable record'
      [ "$(cat "$lock/role")" = forced-teardown ] || fail 'Orca recovery removed teardown custody'
      fm_lock_release "$lock"
    else
      [ -e "$case_dir/remove-refused" ] || fail 'fixture never reached failed worktree removal'
      assert_grep 'cleanup_recovery=orca' "$home/state/$id.meta" 'Orca abort lost its recovery record'
    fi
    [ ! -e "$home/state/.control-$id.lock" ] || fail 'Orca recovery retained control custody'
    [ ! -e "$home/state/.spawn-$id.lock" ] || fail 'Orca recovery retained spawn custody'
    fm_lock_try_acquire "$lock" || fail 'Orca recovery retained task-set custody'
    fm_lock_release "$lock"
  done
  pass 'Orca abort recovery publishes only with task-set custody and finishes cleanup after refusal'
}

test_orca_late_admission_refusal_still_records_retained_copy() {
  local reason case_dir home id fb out status lock actor cap late_meta late_backlog
  . "$ROOT/bin/fm-wake-lib.sh"
  for reason in cap queued; do
    id="orca-late-$reason-$$"
    case_dir="$TMP_ROOT/$id"
    home="$case_dir/home"
    fm_test_spawn_home "$home" codex
    printf 'manual\n' > "$home/config/backlog-backend"
    fm_test_spawn_brief "$home" "$id"
    fm_git_init_commit "$case_dir/project"
    fb=$(make_orca_fakebin "$case_dir")
    actor=main cap=1 late_meta="$home/state/other.meta" late_backlog=''
    if [ "$reason" = queued ]; then
      actor=branch cap=2 late_meta='' late_backlog="$home/data/backlog.md"
      fm_test_tasks_toml "$home/.tasks.toml"
      printf '## Queued\n- [ ] %s - queued work\n' "$id" > "$late_backlog"
    fi
    FM_HOME=$home FM_STATE_OVERRIDE=$home/state "$ROOT/bin/fm-afk-contract.sh" enter --spend "$cap" >/dev/null || fail 'away fixture entry failed'
    status=0
    out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 FM_SUPERVISION_ACTOR="$actor" FM_TEST_ORCA_DIR="$case_dir" \
      FM_TEST_ORCA_REMOVE_FAIL=1 FM_TEST_ORCA_LATE_META="$late_meta" \
      FM_TEST_ORCA_LATE_BACKLOG="$late_backlog" FM_TEST_ORCA_TASK_ID="$id" PATH="$fb:$PATH" \
      "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --backend orca 2>&1) || status=$?
    printf 'Orca late admission reason=%s exit=%s\n%s\n' "$reason" "$status" "$out"
    expect_code 1 "$status" 'late Orca admission must refuse'
    [ -e "$case_dir/remove-refused" ] || fail 'late refusal did not reach failed worktree removal'
    if [ "$reason" = cap ]; then
      assert_contains "$out" 'caps concurrent workers at 1 and 1 ordinary task(s) are live' 'cap did not reject late admission'
      assert_grep 'kind=ship' "$late_meta" 'cleanup removed the unrelated worker'
    else
      assert_contains "$out" 'may dispatch only queued unblocked work' 'relocated work did not reject late admission'
    fi
    assert_grep 'cleanup_recovery=orca' "$home/state/$id.meta" 'rejected late admission lost the Orca recovery record'
    assert_grep "orca_worktree_id=wt-fm-$id" "$home/state/$id.meta" 'Orca recovery record does not name the retained worktree'
    assert_grep "endpoint_task_id=$id" "$home/state/$id.meta" 'Orca recovery record does not name the endpoint task'
    [ ! -e "$home/state/.control-$id.lock" ] || fail 'late Orca refusal retained control custody'
    [ ! -e "$home/state/.spawn-$id.lock" ] || fail 'late Orca refusal retained spawn custody'
    lock=$(fm_task_set_lock_path "$home/state") || fail 'cannot resolve fixture task set'
    fm_lock_try_acquire "$lock" || fail 'late Orca refusal retained task-set custody'
    fm_lock_release "$lock"
  done
  pass 'late spend-cap and relocated-work refusals still record the retained Orca copy without admitting a worker'
}

orca_task_spawn_holder_case() {  # <name> <release-on-wait 0|1>: sets ORCA_HOLDER_OUT ORCA_HOLDER_STATUS ORCA_HOLDER_HOME ORCA_HOLDER_ID
  local name=$1 release_on_wait=$2 case_dir home id fb ready release tick="" holder
  id="orca-holder-$name-$$"
  case_dir="$TMP_ROOT/$id"
  home="$case_dir/home"
  fm_test_spawn_home "$home" codex
  printf 'manual\n' > "$home/config/backlog-backend"
  fm_test_spawn_brief "$home" "$id"
  fm_git_init_commit "$case_dir/project"
  fb=$(make_orca_fakebin "$case_dir")
  ready="$case_dir/holder.ready"
  release="$case_dir/holder.release"
  fm_test_hold_task_set_as_spawn "$home/state" "$ready" "$release"
  holder=$FM_TEST_TASK_SET_HOLDER
  fm_test_wait_until --while-alive "$holder" -- test -f "$ready" || fail 'task-spawn holder never took the task set'
  if [ "$release_on_wait" = 1 ]; then
    tick="$case_dir/release-on-wait"
    fm_test_release_on_lock_wait "$tick" "$release"
  fi
  ORCA_HOLDER_STATUS=0
  ORCA_HOLDER_OUT=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" \
    FM_TEST_ORCA_TERMINAL_FAIL=1 FM_TEST_ORCA_REMOVE_FAIL=1 FM_LOCK_WAIT_TICK="$tick" PATH="$fb:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --backend orca 2>&1) || ORCA_HOLDER_STATUS=$?
  : > "$release"
  wait "$holder" 2>/dev/null || true
  ORCA_HOLDER_HOME=$home
  ORCA_HOLDER_ID=$id
}

test_orca_recovery_waits_out_a_task_spawn_holder_that_releases() {
  orca_task_spawn_holder_case released 1
  expect_code 1 "$ORCA_HOLDER_STATUS" "Orca terminal failure must abort the spawn"$'\n'"$ORCA_HOLDER_OUT"
  [ -f "$ORCA_HOLDER_HOME/state/$ORCA_HOLDER_ID.meta" ] || fail "Orca recovery published no record after the task-spawn holder released: $ORCA_HOLDER_OUT"
  assert_grep 'cleanup_recovery=orca' "$ORCA_HOLDER_HOME/state/$ORCA_HOLDER_ID.meta" 'Orca recovery record lost its marker'
  assert_grep "orca_worktree_id=wt-fm-$ORCA_HOLDER_ID" "$ORCA_HOLDER_HOME/state/$ORCA_HOLDER_ID.meta" 'Orca recovery record does not name the retained worktree'
  assert_grep "endpoint_task_id=$ORCA_HOLDER_ID" "$ORCA_HOLDER_HOME/state/$ORCA_HOLDER_ID.meta" 'Orca recovery record does not name the endpoint'
  pass 'Orca recovery waits out a task-spawn holder that releases, then publishes its retained-copy record'
}

test_orca_recovery_refuses_when_a_task_spawn_holder_outlasts_the_bound() {
  orca_task_spawn_holder_case outlasted 0
  expect_code 1 "$ORCA_HOLDER_STATUS" "Orca terminal failure must abort the spawn"$'\n'"$ORCA_HOLDER_OUT"
  [ ! -e "$ORCA_HOLDER_HOME/state/$ORCA_HOLDER_ID.meta" ] || fail 'Orca recovery published while the task-spawn holder still owned the task set'
  assert_contains "$ORCA_HOLDER_OUT" 'task set is locked by another spawn' 'Orca recovery did not refuse with the task-set contention'
  assert_contains "$ORCA_HOLDER_OUT" "retained Orca worktree wt-fm-$ORCA_HOLDER_ID" 'Orca refusal does not name the retained worktree'
  pass 'Orca recovery refuses explicitly and writes no record when a task-spawn holder outlasts the bound'
}

fm_test_only

test_orca_abort_recovery_obeys_task_set_custody
test_orca_late_admission_refusal_still_records_retained_copy
test_orca_recovery_waits_out_a_task_spawn_holder_that_releases
test_orca_recovery_refuses_when_a_task_spawn_holder_outlasts_the_bound

test_orca_fresh_spawn_enters_the_worktree_it_created
test_orca_relaunch_is_refused_before_the_worktree_carveout_could_run
test_orca_fresh_spawn_proceeds_with_its_terminal_shell_in_the_worktree
test_orca_fresh_spawn_with_an_origin_moves_to_origins_tip

echo "# all fm-spawn-orca-worktree tests passed"
