#!/usr/bin/env bash
# Behavior tests for the environment a spawn's slot provisioning runs in.
#
# bin/fm-spawn.sh runs the project's provisioner for an assigned copy inside the
# acquired pane (spawn_slot_run_in_pane). That script lives in the copy, so it
# must run in the copy's own environment whatever the pane carries and whatever
# the nested clone holds. These tests drive the real spawn entry on the fake tmux
# backend; the pollution is injected where the staged script inherits it (the
# fake pane's environment file), not only in the spawn caller's shell.
#   P1   the clone has no .venv; the copy's venv alone can import a module
#   P1b  the same with a venv made by python -m venv (python links outside)
#   P2   the pane carries VIRTUAL_ENV and other interpreter variables
#   P3   a governed copy with no usable environment is refused before any change
#   P3f  a copy whose freshness target brings the provisioner is refused before
#        the freshness reset moves it
#   P4   an ordinary copy of a project with no provisioner spawns as before
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=tests/fm-slot-env-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-slot-env-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-slot-env)
slot_env_setup_base_python

# The spawn world: the shared scratch world plus a firstmate home, a fake tmux and
# the stubs the spawn path needs. The copy is the pool slot the spawn is handed.
make_spawn_world() { # <name> <copies|symlinks|none>
  local name=$1 mode=$2 dir fakebin
  dir=$(slot_env_make_world "$name" "$mode") || return 1
  fakebin=$(make_spawn_fakebin "$dir/fake" codex)
  fm_test_fake_no_mistakes "$fakebin"
  fm_test_fake_gh "$fakebin"
  fm_test_fake_gh_axi "$fakebin"
  fm_test_spawn_home "$dir/home" codex
  printf 'manual\n' > "$dir/home/config/backlog-backend"
  fm_test_spawn_brief "$dir/home" "$name"
  printf '%s\n' "$dir"
}

# run_spawn <dir> <id> [NAME=value...]: spawn the world's copy as a governed ship.
# The spawn caller's environment carries only the fixture's own variables; the
# pane's polluted environment, when a case wants one, is in FM_FAKE_PANE_ENV_FILE.
run_spawn() {
  local dir=$1 id=$2 rc=0
  shift 2
  (
    # shellcheck disable=SC2030,SC2031 # The subshell owns this PATH on purpose.
    PATH="$dir/stubs:$dir/pybin:$PATH"
    export PATH
    export FM_STUB_LOG="$dir/stub-calls.log" FM_TEST_ENV_RECORD="$dir/env-record.json"
    export FM_TEST_SLOT_RECORD="$dir/slot-record.json" FM_TEST_TOOL_NAME=fm-env-tool FM_TEST_TOOL_LOG="$dir/tool.log"
    export FM_SENTINEL=sentinel FM_FAKE_LAUNCH_LOG="$dir/launch.log"
    export CODEX_HOOK_STATE_DIR="$dir/codex-hooks" WORKTREE_LIFECYCLE_STORE_DIR="$dir/lifecycle"
    while [ "$#" -gt 0 ]; do export "${1%%=*}=${1#*=}"; shift; done
    fm_test_run_spawn "$dir/home" "$dir/copy" "$dir/fake/fakebin" "$id" "$dir/project" \
      --backend tmux --mode local-only --yolo off --owned-path scripts
  ) >"$dir/spawn.out" 2>&1 || rc=$?
  return "$rc"
}

# Fake-pane environment file for the S2-shaped cases: the ambient environment the
# acquired shell carries.
write_pane_env() { # <dir>
  local dir=$1
  {
    printf 'VIRTUAL_ENV=%q\n' "$dir/decoy"
    # shellcheck disable=SC2031 # run_spawn's PATH change stays in its subshell; this reads the parent PATH.
    printf 'PATH=%q\n' "$dir/decoy/bin:$dir/project/.venv/bin:$PATH"
    local assignment
    for assignment in "${SLOT_ENV_POLLUTION[@]}"; do
      printf '%s=%q\n' "${assignment%%=*}" "${assignment#*=}"
    done
  } > "$dir/pane-env.sh"
}

test_p1_clone_without_venv_spawns_in_copy_env() {
  local dir rc=0
  dir=$(make_spawn_world p1-$$ copies) || fail 'the fixture world was not built'
  run_spawn "$dir" "p1-$$" || rc=$?
  expect_code 0 "$rc" "P1: spawn failed: $(tail -n 15 "$dir/spawn.out")"
  assert_equals "$dir/copy/.venv/bin/python" "$(slot_env_field "$dir" sys_executable)" 'P1: the pane provisioner did not run in the copy venv python'
  slot_env_assert_under "$(slot_env_field "$dir" sys_prefix)" "$dir/copy" 'P1: sys.prefix is not inside the copy'
  [ ! -e "$dir/project/.venv" ] || fail 'P1: a clone .venv appeared'
  pass 'P1: a spawn with no clone .venv provisions in the copy environment'
}

test_p1b_real_venv_links_outside_copy() {
  local dir rc=0
  dir=$(make_spawn_world p1b-$$ symlinks) || fail 'the fixture world was not built'
  run_spawn "$dir" "p1b-$$" || rc=$?
  expect_code 0 "$rc" "P1b: spawn failed: $(tail -n 15 "$dir/spawn.out")"
  assert_equals "$dir/copy/.venv/bin/python" "$(slot_env_field "$dir" sys_executable)" 'P1b: sys.executable is not the unresolved copy venv python'
  slot_env_assert_under "$(slot_env_field "$dir" sys_prefix)" "$dir/copy" 'P1b: sys.prefix is not inside the copy'
  pass 'P1b: a real python -m venv copy environment provisions through the spawn path'
}

test_p2_pane_pollution_never_reaches_the_provisioner() {
  local dir rc=0 field
  dir=$(make_spawn_world p2-$$ copies) || fail 'the fixture world was not built'
  slot_env_add_clone_venv "$dir"
  slot_env_add_decoy_venv "$dir"
  write_pane_env "$dir"
  slot_env_snapshot_decoy "$dir" before
  run_spawn "$dir" "p2-$$" "FM_FAKE_PANE_ENV_FILE=$dir/pane-env.sh" || rc=$?
  [ -z "${FM_TEST_SHOW_RECORD:-}" ] || { printf 'record: '; cat "$dir/env-record.json" 2>/dev/null; printf '\nborrowed: '; tr '\n' ' ' < "$dir/borrowed.log"; printf '\n'; }
  expect_code 0 "$rc" "P2: spawn failed: $(tail -n 15 "$dir/spawn.out")"
  assert_equals "$dir/copy/.venv" "$(slot_env_field "$dir" VIRTUAL_ENV)" 'P2: VIRTUAL_ENV is not the copy venv'
  for field in PYTHONPATH PYTHONHOME PYTHONUSERBASE PYTHONSTARTUP __PYVENV_LAUNCHER__ UV_PROJECT_ENVIRONMENT CONDA_PREFIX; do
    assert_equals "" "$(slot_env_field "$dir" "$field")" "P2: $field reached the provisioner"
  done
  assert_equals "$dir/copy/.venv/bin" "$(slot_env_field "$dir" path_head)" 'P2: the first PATH entry is not the copy venv bin'
  case ":$(slot_env_field "$dir" path):" in
    *":$dir/decoy/bin:"*|*":$dir/project/.venv/bin:"*) fail 'P2: a foreign venv bin is still on PATH' ;;
  esac
  assert_equals "$dir/copy/.venv/bin/python" "$(slot_env_field "$dir" sys_executable)" 'P2: provisioner interpreter is not the copy venv python'
  assert_equals "$dir/project" "$(slot_env_field "$dir" cwd)" 'P2: the working directory changed'
  assert_equals sentinel "$(slot_env_field "$dir" FM_SENTINEL)" 'P2: FM_SENTINEL was dropped'
  assert_equals "$dir/codex-hooks" "$(slot_env_field "$dir" CODEX_HOOK_STATE_DIR)" 'P2: CODEX_HOOK_STATE_DIR was changed'
  assert_equals "$dir/lifecycle" "$(slot_env_field "$dir" WORKTREE_LIFECYCLE_STORE_DIR)" 'P2: WORKTREE_LIFECYCLE_STORE_DIR was changed'
  ! grep -q provision_existing_slot "$dir/borrowed.log" || fail "P2: a clone or decoy interpreter ran the provisioner: $(cat "$dir/borrowed.log")"
  [ ! -s "$dir/tool.log" ] || fail 'P2: a tool that only a foreign venv holds was found'
  [ ! -s "$dir/stub-calls.log" ] || fail "P2: pip, uv or python -m venv was called: $(cat "$dir/stub-calls.log")"
  slot_env_snapshot_decoy "$dir" after
  cmp -s "$dir/decoy-before.txt" "$dir/decoy-after.txt" || fail 'P2: the decoy venv or its editable pointer changed'
  pass 'P2: an ambient VIRTUAL_ENV in the pane, interpreter variables and a clone .venv never reach the spawn provisioner'
}

# P3: a governed copy with no usable environment is refused before any change.
# The spawn entry's fetch and base validation change entry names under .git, so
# the working tree and any .venv are compared, and HEAD and the branch refs are
# asserted separately.
tree_listing() { # <copy>
  (cd "$1" && find . -path ./.git -prune -o -print | LC_ALL=C sort)
}

run_p3_shape() { # <shape>
  local shape=$1 dir id rc=0 head branch refs out
  id="p3-$shape-$$"
  dir=$(make_spawn_world "$id" none) || fail 'the fixture world was not built'
  slot_env_break_copy_env "$dir" "$shape"
  head=$(git -C "$dir/copy" rev-parse HEAD)
  branch=$(git -C "$dir/copy" branch --show-current)
  refs=$(git -C "$dir/copy" for-each-ref --format='%(refname) %(objectname)' refs/heads)
  tree_listing "$dir/copy" > "$dir/tree-before.txt"
  run_spawn "$dir" "$id" || rc=$?
  [ "$rc" -ne 0 ] || fail "P3 $shape: a governed copy with no usable environment was admitted"
  out=$(cat "$dir/spawn.out")
  assert_contains "$out" 'slot provisioning refused:' "P3 $shape: the refusal is not named"
  assert_contains "$out" "$dir/copy" "P3 $shape: the refusal does not name the copy"
  case "$shape" in
    missing|notexec) assert_contains "$out" copy_environment_missing "P3 $shape: wrong reason" ;;
    *) assert_contains "$out" copy_environment_outside_copy "P3 $shape: wrong reason" ;;
  esac
  assert_equals "$head" "$(git -C "$dir/copy" rev-parse HEAD)" "P3 $shape: the copy HEAD moved"
  assert_equals "$branch" "$(git -C "$dir/copy" branch --show-current)" "P3 $shape: the copy branch changed"
  assert_equals "$refs" "$(git -C "$dir/copy" for-each-ref --format='%(refname) %(objectname)' refs/heads)" "P3 $shape: branch refs changed"
  tree_listing "$dir/copy" > "$dir/tree-after.txt"
  cmp -s "$dir/tree-before.txt" "$dir/tree-after.txt" || fail "P3 $shape: the working tree changed: $(diff "$dir/tree-before.txt" "$dir/tree-after.txt" | head -5)"
  [ ! -e "$dir/env-record.json" ] || fail "P3 $shape: the provisioner ran"
  [ ! -s "$dir/launch.log" ] || fail "P3 $shape: a harness was launched"
  [ ! -s "$dir/stub-calls.log" ] || fail "P3 $shape: something was installed or created: $(cat "$dir/stub-calls.log")"
  pass "P3: $shape is refused through the spawn entry before any change"
}

test_p3_missing_python() { run_p3_shape missing; }
test_p3_python_not_executable() { run_p3_shape notexec; }
test_p3_venv_resolves_outside_copy() { run_p3_shape venv-outside; }
test_p3_venv_bin_resolves_outside_copy() { run_p3_shape bin-outside; }

# The freshness reset can introduce the project's provisioner after the copy was
# classified as ordinary. The usability check must run before that reset moves
# the copy; a copy with no environment keeps its old revision.
advance_origin_with_provisioner() { # <dir> <with|without>
  local dir=$1 with=$2 publisher
  publisher="$dir/publisher"
  git clone --quiet "file://$dir/origin.git" "$publisher"
  if [ "$with" = with ]; then
    slot_env_write_provisioner "$publisher"
  fi
  printf 'advanced\n' > "$publisher/advanced.txt"
  git -C "$publisher" add .
  git -C "$publisher" -c user.name=Tests -c user.email=tests@example.invalid commit -qm advance
  git -C "$publisher" push --quiet origin main
  git -C "$publisher" rev-parse HEAD
}

make_ungoverned_spawn_world() { # <name> <venv: none|copies>
  local name=$1 mode=$2 dir
  dir=$(make_spawn_world "$name" "$mode") || return 1
  # The base revision carries no provisioner at all: remove it from project and copy.
  git -C "$dir/project" rm -q scripts/git-stability/provision_existing_slot.py
  git -C "$dir/project" -c user.name=Tests -c user.email=tests@example.invalid commit -qm 'no provisioner yet'
  git -C "$dir/project" push --quiet origin main
  git -C "$dir/copy" checkout --quiet --detach "$(git -C "$dir/project" rev-parse HEAD)"
  printf '%s\n' "$dir"
}

test_p3f_freshness_target_with_provisioner_refuses_before_reset() {
  local dir id rc=0 head advanced out
  id="p3f-$$"
  dir=$(make_ungoverned_spawn_world "$id" none) || fail 'the fixture world was not built'
  head=$(git -C "$dir/copy" rev-parse HEAD)
  advanced=$(advance_origin_with_provisioner "$dir" with)
  mkdir -p "$dir/copy/.venv/bin"
  tree_listing "$dir/copy" > "$dir/tree-before.txt"
  run_spawn "$dir" "$id" || rc=$?
  [ "$rc" -ne 0 ] || fail 'P3f: a copy whose freshness target holds the provisioner was admitted without an environment'
  out=$(cat "$dir/spawn.out")
  assert_contains "$out" 'slot provisioning refused: copy_environment_missing' 'P3f: the refusal is not named'
  assert_equals "$head" "$(git -C "$dir/copy" rev-parse HEAD)" 'P3f: the freshness reset moved the copy before the environment check'
  assert_not_equals "$advanced" "$(git -C "$dir/copy" rev-parse HEAD)" 'P3f: the copy reached the advanced revision'
  tree_listing "$dir/copy" > "$dir/tree-after.txt"
  cmp -s "$dir/tree-before.txt" "$dir/tree-after.txt" || fail 'P3f: the working tree changed'
  [ ! -s "$dir/launch.log" ] || fail 'P3f: a harness was launched'
  [ ! -s "$dir/stub-calls.log" ] || fail "P3f: something was installed or created: $(cat "$dir/stub-calls.log")"
  pass 'P3f: a freshness target that brings the provisioner is refused for a missing environment before the reset'
}

# With the environment present the same shape provisions: the check is not a ban.
test_p3f_freshness_target_with_provisioner_and_environment_provisions() {
  local dir id rc=0 advanced
  id="p3fok-$$"
  dir=$(make_ungoverned_spawn_world "$id" copies) || fail 'the fixture world was not built'
  advanced=$(advance_origin_with_provisioner "$dir" with)
  run_spawn "$dir" "$id" || rc=$?
  expect_code 0 "$rc" "P3f: spawn with an environment failed: $(tail -n 15 "$dir/spawn.out")"
  assert_equals "$advanced" "$(git -C "$dir/copy" rev-parse HEAD)" 'P3f: the copy was not freshened'
  assert_equals "$dir/copy/.venv/bin/python" "$(slot_env_field "$dir" sys_executable)" 'P3f: the provisioner did not run in the copy environment'
  pass 'P3f: a freshness target that brings the provisioner provisions in the copy environment'
}

# P4: an ordinary copy of a project with no provisioner and no .venv spawns as
# it always did; the new check never touches it.
test_p4_ordinary_copy_without_venv_spawns() {
  local dir id rc=0 advanced
  id="p4-$$"
  dir=$(make_ungoverned_spawn_world "$id" none) || fail 'the fixture world was not built'
  advanced=$(advance_origin_with_provisioner "$dir" without)
  run_spawn "$dir" "$id" || rc=$?
  expect_code 0 "$rc" "P4: an ordinary copy was refused: $(tail -n 15 "$dir/spawn.out")"
  assert_equals "$advanced" "$(git -C "$dir/copy" rev-parse HEAD)" 'P4: the ordinary copy was not freshened'
  [ -s "$dir/launch.log" ] || fail 'P4: the ordinary copy launched no harness'
  [ ! -e "$dir/env-record.json" ] || fail 'P4: a provisioner ran for an ordinary copy'
  [ ! -e "$dir/copy/.venv" ] || fail 'P4: a .venv appeared in an ordinary copy'
  pass 'P4: an ordinary copy with no provisioner and no .venv spawns exactly as before'
}

fm_test_run_cases \
  test_p1_clone_without_venv_spawns_in_copy_env \
  test_p1b_real_venv_links_outside_copy \
  test_p2_pane_pollution_never_reaches_the_provisioner \
  test_p3_missing_python \
  test_p3_python_not_executable \
  test_p3_venv_resolves_outside_copy \
  test_p3_venv_bin_resolves_outside_copy \
  test_p3f_freshness_target_with_provisioner_refuses_before_reset \
  test_p3f_freshness_target_with_provisioner_and_environment_provisions \
  test_p4_ordinary_copy_without_venv_spawns \
  -- "$@"
