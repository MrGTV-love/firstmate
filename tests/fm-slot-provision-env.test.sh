#!/usr/bin/env bash
# Behavior tests for the environment the slot provisioner runs in.
#
# A provisioner script lives in the assigned copy, so it must run in the
# environment of that copy: <copy>/.venv/bin/python by absolute path, the copy's
# venv first on PATH, no ambient VIRTUAL_ENV, and never the environment of the
# nested project clone a home keeps. bin/fm-copy-env-lib.sh owns the rule.
# Each scenario builds a scratch nested clone and a scratch provisioned copy,
# runs fm_slot_provision through the local runner (the promote path), and reads
# the record the fixture provisioner wrote before it imported anything.
#   S1   the nested clone has no .venv; the copy's venv alone can import a module
#   S1b  the same with a venv made by python -m venv (python links outside the copy)
#   S2   an inherited VIRTUAL_ENV, other interpreter variables and a clone .venv
#        with its own markers are all polluted; none of them reaches the run
#   S3   a copy with no usable environment is refused before any change
#   NS   provisioning creates no venv and installs nothing
# The spawn path (spawn_slot_run_in_pane) is exercised through bin/fm-spawn.sh in
# tests/fm-spawn-slot-env.test.sh, and the closeout and retire sites in
# tests/fm-copy-env-sites.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=tests/fm-slot-env-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-slot-env-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-slot-provision-env)
slot_env_setup_base_python

# Library-level run of the promote path. Prints nothing; the caller reads the
# world's files. <world> <extra env assignments...>
run_local_provision() { # <world-dir> [NAME=value...]
  local dir=$1
  shift
  slot_env_run_provision "$dir" fm_slot_run_local "$@"
}

test_s1_clone_without_venv_runs_in_copy_env() {
  local dir rc=0
  dir=$(slot_env_make_world s1 copies)
  run_local_provision "$dir" || rc=$?
  expect_code 0 "$rc" "S1: provisioning failed: $(slot_env_tail "$dir")"
  [ -f "$dir/env-record.json" ] || fail 'S1: the fixture provisioner recorded nothing'
  assert_equals "$dir/copy/.venv/bin/python" "$(slot_env_field "$dir" sys_executable)" 'S1: provisioner interpreter is not the copy venv python as given'
  slot_env_assert_under "$(slot_env_field "$dir" sys_prefix)" "$dir/copy" 'S1: sys.prefix is not inside the copy'
  [ ! -e "$dir/project/.venv" ] || fail 'S1: the fixture gave the clone a .venv'
  pass 'S1: a clone with no .venv provisions in the copy environment'
}

test_s1b_real_venv_links_outside_copy() {
  local dir rc=0 target
  dir=$(slot_env_make_world s1b symlinks)
  target=$(readlink "$dir/copy/.venv/bin/python") || fail 'S1b: the copy venv python is not a symlink'
  case "$target" in "$dir/copy"/*) fail 'S1b: the venv python does not link outside the copy' ;; esac
  [ -f "$dir/copy/.venv/pyvenv.cfg" ] || fail 'S1b: the copy venv has no pyvenv.cfg'
  run_local_provision "$dir" || rc=$?
  expect_code 0 "$rc" "S1b: provisioning failed: $(slot_env_tail "$dir")"
  assert_equals "$dir/copy/.venv/bin/python" "$(slot_env_field "$dir" sys_executable)" 'S1b: sys.executable is not the unresolved copy venv python'
  slot_env_assert_under "$(slot_env_field "$dir" sys_prefix)" "$dir/copy" 'S1b: sys.prefix is not inside the copy'
  pass 'S1b: a real python -m venv copy environment provisions although its interpreter links outside the copy'
}

# A temp path reached through a symlink must keep its spelling: the run is
# compared by the path as given, never by realpath.
test_s1_symlinked_copy_path_is_not_resolved() {
  local dir rc=0 alias
  dir=$(slot_env_make_world s1sym copies)
  alias="$dir/alias-copy"
  ln -s "$dir/copy" "$alias"
  SLOT_ENV_COPY_ARG=$alias run_local_provision "$dir" || rc=$?
  expect_code 0 "$rc" "S1 symlink: provisioning failed: $(slot_env_tail "$dir")"
  # Python itself may spell its own sys.executable through the real directory, so
  # the owner's spelling is read where only the owner decides it.
  assert_equals "$alias/.venv" "$(slot_env_field "$dir" VIRTUAL_ENV)" 'S1 symlink: VIRTUAL_ENV was resolved'
  assert_equals "$alias/.venv/bin" "$(slot_env_field "$dir" path_head)" 'S1 symlink: the leading PATH entry was resolved'
  case "$(slot_env_field "$dir" sys_executable)" in
    "$alias/.venv/bin/python"|"$dir/copy/.venv/bin/python") ;;
    *) fail "S1 symlink: the provisioner ran another interpreter: $(slot_env_field "$dir" sys_executable)" ;;
  esac
  pass 'S1: the copy path is used as given when it is reached through a symlink'
}

test_s2_pollution_never_reaches_the_provisioner() {
  local dir rc=0 field
  dir=$(slot_env_make_world s2 copies)
  slot_env_add_clone_venv "$dir"
  slot_env_add_decoy_venv "$dir"
  slot_env_snapshot_decoy "$dir" before
  run_local_provision "$dir" "${SLOT_ENV_POLLUTION[@]}" "VIRTUAL_ENV=$dir/decoy" \
    "PATH=$dir/decoy/bin:$dir/project/.venv/bin:$dir/stubs:$dir/pybin:/usr/bin:/bin" || rc=$?
  # The base-validity record: what the provisioner saw is printed on request so a
  # base run can show the injection reached it (the run itself may have failed).
  [ -z "${FM_TEST_SHOW_RECORD:-}" ] || { printf 'record: '; cat "$dir/env-record.json" 2>/dev/null; printf '\nborrowed: '; tr '\n' ' ' < "$dir/borrowed.log"; printf '\n'; }
  expect_code 0 "$rc" "S2: provisioning failed: $(slot_env_tail "$dir")"
  assert_equals "$dir/copy/.venv" "$(slot_env_field "$dir" VIRTUAL_ENV)" 'S2: VIRTUAL_ENV is not the copy venv'
  for field in PYTHONPATH PYTHONHOME PYTHONUSERBASE PYTHONSTARTUP __PYVENV_LAUNCHER__ UV_PROJECT_ENVIRONMENT CONDA_PREFIX; do
    assert_equals "" "$(slot_env_field "$dir" "$field")" "S2: $field reached the provisioner"
  done
  assert_equals "$dir/copy/.venv/bin" "$(slot_env_field "$dir" path_head)" 'S2: the first PATH entry is not the copy venv bin'
  assert_equals "$dir/copy/.venv/bin:$dir/stubs:$dir/pybin:/usr/bin:/bin" "$(slot_env_field "$dir" path)" 'S2: PATH is not the copy venv bin plus the inherited PATH minus foreign venv bins'
  assert_equals "$dir/copy/.venv/bin/python" "$(slot_env_field "$dir" sys_executable)" 'S2: provisioner interpreter is not the copy venv python'
  assert_equals "$dir/project" "$(slot_env_field "$dir" cwd)" 'S2: the working directory changed'
  assert_equals "$dir/copy/scripts/git-stability" "$(slot_env_field "$dir" sys_path0)" 'S2: sys.path[0] is not the copy provisioner directory'
  # Firstmate's own attestation parser may run on the caller's python3; only an
  # interpreter that ran the provisioner would be a borrowed environment.
  ! grep -q provision_existing_slot "$dir/borrowed.log" || fail "S2: a clone or decoy interpreter ran the provisioner: $(cat "$dir/borrowed.log")"
  [ ! -s "$dir/tool.log" ] || fail 'S2: a tool that only a foreign venv holds was found'
  slot_env_snapshot_decoy "$dir" after
  cmp -s "$dir/decoy-before.txt" "$dir/decoy-after.txt" || fail 'S2: the decoy venv or its editable pointer changed'
  pass 'S2: an inherited VIRTUAL_ENV, ambient interpreter variables and a clone .venv never reach the provisioner'
}

test_s2_pass_through_variables_arrive_unchanged() {
  local dir rc=0
  dir=$(slot_env_make_world s2pass copies)
  run_local_provision "$dir" "FM_SENTINEL=sentinel-value" "CODEX_HOOK_STATE_DIR=$dir/codex-hooks" \
    "WORKTREE_LIFECYCLE_STORE_DIR=$dir/lifecycle" "GIT_AUTHOR_NAME=Pass Through" || rc=$?
  expect_code 0 "$rc" "S2 pass-through: provisioning failed: $(slot_env_tail "$dir")"
  assert_equals sentinel-value "$(slot_env_field "$dir" FM_SENTINEL)" 'S2: FM_SENTINEL was dropped'
  assert_equals "$dir/home" "$(slot_env_field "$dir" HOME)" 'S2: HOME was changed'
  assert_equals "$dir/tmp" "$(slot_env_field "$dir" TMPDIR)" 'S2: TMPDIR was changed'
  assert_equals "$dir/codex-hooks" "$(slot_env_field "$dir" CODEX_HOOK_STATE_DIR)" 'S2: CODEX_HOOK_STATE_DIR was changed'
  assert_equals "$dir/lifecycle" "$(slot_env_field "$dir" WORKTREE_LIFECYCLE_STORE_DIR)" 'S2: WORKTREE_LIFECYCLE_STORE_DIR was changed'
  assert_equals "Pass Through" "$(slot_env_field "$dir" GIT_AUTHOR_NAME)" 'S2: a GIT_ identity variable was changed'
  pass 'S2: named pass-through variables reach the provisioner unchanged'
}

# S3: a copy with no usable environment is refused by name before any change.
# <shape> is one of the unusable shapes; <label> names the check.
run_s3_shape() { # <shape>
  local shape=$1 dir rc=0 out head branch
  dir=$(slot_env_make_world "s3-$shape" none)
  slot_env_break_copy_env "$dir" "$shape"
  slot_env_listing "$dir" > "$dir/listing-before.txt"
  head=$(git -C "$dir/copy" rev-parse HEAD)
  branch=$(git -C "$dir/copy" branch --show-current)
  run_local_provision "$dir" || rc=$?
  [ "$rc" != 0 ] || fail "S3 $shape: a copy with no usable environment was provisioned"
  out=$(cat "$dir/refusal.txt" 2>/dev/null; cat "$dir/report.json" 2>/dev/null)
  assert_contains "$out" 'slot provisioning refused:' "S3 $shape: the refusal is not named"
  assert_contains "$out" "$dir/copy" "S3 $shape: the refusal does not name the copy"
  case "$shape" in
    missing) assert_contains "$out" copy_environment_missing "S3 $shape: wrong reason" ;;
    notexec) assert_contains "$out" copy_environment_missing "S3 $shape: wrong reason" ;;
    venv-outside|bin-outside) assert_contains "$out" copy_environment_outside_copy "S3 $shape: wrong reason" ;;
  esac
  assert_equals "$head" "$(git -C "$dir/copy" rev-parse HEAD)" "S3 $shape: the copy HEAD moved"
  assert_equals "$branch" "$(git -C "$dir/copy" branch --show-current)" "S3 $shape: the copy branch changed"
  [ -z "$(git -C "$dir/copy" for-each-ref refs/heads/fm)" ] || fail "S3 $shape: a task branch was created"
  [ ! -e "$dir/env-record.json" ] || fail "S3 $shape: the provisioner ran"
  slot_env_listing "$dir" > "$dir/listing-after.txt"
  cmp -s "$dir/listing-before.txt" "$dir/listing-after.txt" || fail "S3 $shape: entries appeared or vanished: $(diff "$dir/listing-before.txt" "$dir/listing-after.txt" | head -5)"
  [ ! -s "$dir/stub-calls.log" ] || fail "S3 $shape: something was installed or created: $(cat "$dir/stub-calls.log")"
  pass "S3: $shape refuses by name before any change"
}

test_s3_missing_python() { run_s3_shape missing; }
test_s3_python_not_executable() { run_s3_shape notexec; }
test_s3_venv_resolves_outside_copy() { run_s3_shape venv-outside; }
test_s3_venv_bin_resolves_outside_copy() { run_s3_shape bin-outside; }

# fm_slot_check_copy is the shared check that fm-control relaunch and
# fm-spawn's governed branch call, so it must carry the named reason itself.
test_s3_check_copy_carries_the_reason() {
  local dir out rc=0
  dir=$(slot_env_make_world s3check none)
  out=$(slot_env_run_check_copy "$dir" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'S3: fm_slot_check_copy admitted a copy with no environment'
  assert_contains "$out" 'slot provisioning refused: copy_environment_missing' 'S3: fm_slot_check_copy lost the named reason'
  assert_contains "$out" "$dir/copy/.venv/bin/python" 'S3: the reason does not name the missing interpreter'
  pass 'S3: fm_slot_check_copy names the missing environment'
}

# NO-STOPGAP: a copy with no environment gets no venv and no installation, and a
# copy that has one is run, not rebuilt.
test_no_stopgap_creates_nothing() {
  local dir rc=0
  dir=$(slot_env_make_world nostop none)
  slot_env_listing "$dir" > "$dir/listing-before.txt"
  run_local_provision "$dir" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail 'NO-STOPGAP: a copy with no environment was provisioned'
  slot_env_listing "$dir" > "$dir/listing-after.txt"
  cmp -s "$dir/listing-before.txt" "$dir/listing-after.txt" || fail "NO-STOPGAP: entries changed: $(diff "$dir/listing-before.txt" "$dir/listing-after.txt" | head -5)"
  [ ! -e "$dir/copy/.venv" ] && [ ! -e "$dir/project/.venv" ] || fail 'NO-STOPGAP: a .venv appeared'
  [ ! -s "$dir/stub-calls.log" ] || fail "NO-STOPGAP: pip, uv or python -m venv was called: $(cat "$dir/stub-calls.log")"
  pass 'NO-STOPGAP: provisioning a copy with no environment creates no venv and installs nothing'
}

test_no_stopgap_runs_existing_env_without_rebuilding() {
  local dir rc=0
  dir=$(slot_env_make_world nostop-ok copies)
  slot_env_listing "$dir" | grep -v '/.venv/.*__pycache__' > "$dir/listing-before.txt"
  run_local_provision "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "NO-STOPGAP: provisioning failed: $(slot_env_tail "$dir")"
  [ ! -s "$dir/stub-calls.log" ] || fail "NO-STOPGAP: pip, uv or python -m venv was called: $(cat "$dir/stub-calls.log")"
  [ ! -e "$dir/project/.venv" ] || fail 'NO-STOPGAP: a clone .venv appeared'
  pass 'NO-STOPGAP: an existing copy environment is run, never rebuilt'
}

# The environment rule is shared by every site; the library itself is checked
# for the exact PATH and the explicit-interpreter cases.
test_owner_path_filter_and_override() {
  local dir out
  dir=$(slot_env_make_world owner copies)
  slot_env_add_decoy_venv "$dir"
  mkdir -p "$dir/home/cfgvenv/bin"
  : > "$dir/home/cfgvenv/pyvenv.cfg"
  out=$(slot_env_owner_probe "$dir" "$dir/copy" "" "VIRTUAL_ENV=$dir/decoy" "PATH=$dir/decoy/bin:/x/.venv/bin:/usr/bin:$dir/home/cfgvenv/bin:/bin")
  assert_equals "VIRTUAL_ENV=$dir/copy/.venv
PATH=$dir/copy/.venv/bin:/usr/bin:/bin" "$out" 'owner: default environment is wrong'
  out=$(slot_env_owner_probe "$dir" "$dir/copy" "$dir/pybin/python3" "VIRTUAL_ENV=$dir/decoy" "PATH=$dir/decoy/bin:/usr/bin:/bin")
  assert_equals "VIRTUAL_ENV=
PATH=/usr/bin:/bin" "$out" 'owner: an explicit interpreter outside any .venv must unset VIRTUAL_ENV and add no venv bin'
  out=$(slot_env_owner_probe "$dir" "$dir/copy" "$dir/copy/.venv/bin/python" "VIRTUAL_ENV=$dir/decoy" "PATH=/usr/bin:/bin")
  assert_equals "VIRTUAL_ENV=$dir/copy/.venv
PATH=$dir/copy/.venv/bin:/usr/bin:/bin" "$out" 'owner: an explicit interpreter under the copy venv uses the copy venv'
  out=$(slot_env_owner_probe "$dir" "$dir/copy" "$dir/decoy/bin/python" "VIRTUAL_ENV=$dir/decoy" "PATH=$dir/decoy/bin:/usr/bin:/bin")
  assert_equals "VIRTUAL_ENV=
PATH=/usr/bin:/bin" "$out" 'owner: an explicit interpreter under another venv must unset VIRTUAL_ENV'
  pass 'owner: PATH filter and explicit-interpreter cases'
}

fm_test_run_cases \
  test_s1_clone_without_venv_runs_in_copy_env \
  test_s1b_real_venv_links_outside_copy \
  test_s1_symlinked_copy_path_is_not_resolved \
  test_s2_pollution_never_reaches_the_provisioner \
  test_s2_pass_through_variables_arrive_unchanged \
  test_s3_missing_python \
  test_s3_python_not_executable \
  test_s3_venv_resolves_outside_copy \
  test_s3_venv_bin_resolves_outside_copy \
  test_s3_check_copy_carries_the_reason \
  test_no_stopgap_creates_nothing \
  test_no_stopgap_runs_existing_env_without_rebuilding \
  test_owner_path_filter_and_override \
  -- "$@"
