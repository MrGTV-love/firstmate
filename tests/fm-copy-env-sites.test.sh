#!/usr/bin/env bash
# Behavior tests for the sites that run a script of a task copy or a clone with
# that tree's environment: Vernant's closeout driver (teardown_run_closeout, which
# the copy sweep reaches) and the slot-record retirement (bin/fm-slot-manifest-
# retire.py). bin/fm-copy-env-lib.sh owns the rule: an environment follows the
# tree that owns the script, an inherited VIRTUAL_ENV and the ambient interpreter
# variables never reach the run, and a tree with no usable interpreter is refused
# by name with no fallback to this process's interpreter.
#   C1-C6  teardown_run_closeout (default interpreter, the explicit override,
#          scrub, pass-through, refusal, override over default)
#   S4*    bin/fm-slot-manifest-retire.py: script and interpreter from one tree
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=tests/fm-slot-env-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-slot-env-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-copy-env-sites)
slot_env_setup_base_python
RETIRE="$ROOT/bin/fm-slot-manifest-retire.py"

# ---- closeout driver ---------------------------------------------------------

# The fixture driver records what it saw before doing anything else, then allows.
slot_env_write_closeout_driver() { # <tree>
  mkdir -p "$1/scripts/git-stability"
  cat > "$1/scripts/git-stability/closeout_pr.py" <<'PY'
import json
import os
import sys
from pathlib import Path

NAMES = ("VIRTUAL_ENV", "PYTHONPATH", "PYTHONHOME", "PYTHONUSERBASE", "PYTHONSTARTUP",
         "__PYVENV_LAUNCHER__", "UV_PROJECT_ENVIRONMENT", "CONDA_PREFIX", "FM_SENTINEL", "HOME",
         "TMPDIR", "CODEX_HOOK_STATE_DIR", "WORKTREE_LIFECYCLE_STORE_DIR", "GIT_AUTHOR_NAME")
record = {name: os.environ.get(name) for name in NAMES}
path = os.environ.get("PATH", "")
record.update(sys_executable=sys.executable, sys_prefix=sys.prefix, path=path, path_head=path.split(":")[0],
              cwd=os.getcwd(), argv=sys.argv[1:])
Path(os.environ["FM_TEST_ENV_RECORD"]).write_text(json.dumps(record), encoding="utf-8")
print(json.dumps({"allowed": True}))
PY
}

# slot_env_run_closeout <dir> <tree> [NAME=value...]: runs teardown_run_closeout
# in a clean environment; <dir>/closeout.out holds TEARDOWN_CLOSEOUT_OUT, and the
# status is teardown_run_closeout's.
slot_env_run_closeout() {
  local dir=$1 tree=$2 line
  local -a assign=()
  shift 2
  while IFS= read -r line; do assign+=("$line"); done < <(slot_env_base_assignments "$dir")
  # shellcheck disable=SC2016 # The script is for the child shell to expand.
  env -i "${assign[@]}" "$@" "$SLOT_ENV_BASH" -c '
    . "$FM_ROOT_DIR/bin/fm-teardown-nested-lib.sh"
    rc=0
    teardown_run_closeout "$1" "$2" plan || rc=$?
    printf "%s" "$TEARDOWN_CLOSEOUT_OUT" > "$3"
    exit "$rc"
  ' bash "$tree" "$tree/.claude/worktrees/nested" "$dir/closeout.out"
}

make_closeout_world() { # <name> <copies|symlinks|none>
  local dir
  dir=$(slot_env_make_world "$1" "$2") || return 1
  slot_env_write_closeout_driver "$dir/copy"
  printf '%s\n' "$dir"
}

test_c1_closeout_pollution_never_reaches_the_driver() {
  local dir rc=0 field
  dir=$(make_closeout_world c1 symlinks) || fail 'the fixture world was not built'
  slot_env_add_decoy_venv "$dir"
  slot_env_snapshot_decoy "$dir" before
  slot_env_run_closeout "$dir" "$dir/copy" "${SLOT_ENV_POLLUTION[@]}" "VIRTUAL_ENV=$dir/decoy" \
    "PATH=$dir/decoy/bin:$dir/stubs:$dir/pybin:/usr/bin:/bin" || rc=$?
  [ -z "${FM_TEST_SHOW_RECORD:-}" ] || { printf 'record: '; cat "$dir/env-record.json" 2>/dev/null; printf '\n'; }
  expect_code 0 "$rc" "C1: closeout failed: $(cat "$dir/closeout.out" 2>/dev/null)"
  assert_equals "$dir/copy/.venv" "$(slot_env_field "$dir" VIRTUAL_ENV)" 'C1: VIRTUAL_ENV is not the tree venv'
  for field in PYTHONPATH PYTHONHOME PYTHONUSERBASE PYTHONSTARTUP __PYVENV_LAUNCHER__ UV_PROJECT_ENVIRONMENT CONDA_PREFIX; do
    assert_equals "" "$(slot_env_field "$dir" "$field")" "C1: $field reached the closeout driver"
  done
  assert_equals "$dir/copy/.venv/bin" "$(slot_env_field "$dir" path_head)" 'C1: the first PATH entry is not the tree venv bin'
  assert_equals "$dir/copy/.venv/bin:$dir/stubs:$dir/pybin:/usr/bin:/bin" "$(slot_env_field "$dir" path)" 'C1: PATH is not the tree venv bin plus the inherited PATH minus foreign venv bins'
  assert_equals "$dir/copy/.venv/bin/python" "$(slot_env_field "$dir" sys_executable)" 'C1: the driver did not run in the tree interpreter'
  assert_equals sentinel "$(slot_env_field "$dir" FM_SENTINEL)" 'C1: FM_SENTINEL was dropped'
  assert_equals "$dir/home" "$(slot_env_field "$dir" HOME)" 'C1: HOME was changed'
  assert_equals "$dir/codex-hooks" "$(slot_env_field "$dir" CODEX_HOOK_STATE_DIR)" 'C1: CODEX_HOOK_STATE_DIR was changed'
  assert_equals "$dir/lifecycle" "$(slot_env_field "$dir" WORKTREE_LIFECYCLE_STORE_DIR)" 'C1: WORKTREE_LIFECYCLE_STORE_DIR was changed'
  assert_equals "Fixture" "$(slot_env_field "$dir" GIT_AUTHOR_NAME)" 'C1: a GIT_ identity variable was changed'
  assert_equals "$dir/copy" "$(slot_env_field "$dir" cwd)" 'C1: the driver did not run from the slot'
  slot_env_snapshot_decoy "$dir" after
  cmp -s "$dir/decoy-before.txt" "$dir/decoy-after.txt" || fail 'C1: the decoy venv changed'
  pass 'C1: the closeout driver runs in its tree environment with the ambient environment scrubbed'
}

# The operator's explicit interpreter is honored; the scrub still applies.
closeout_with_override() { # <name> <python-relative-to-dir> [NAME=value...]
  local name=$1 override=$2 dir rc=0
  shift 2
  dir=$(make_closeout_world "$name" symlinks) || fail 'the fixture world was not built'
  slot_env_add_decoy_venv "$dir"
  slot_env_run_closeout "$dir" "$dir/copy" "FM_TEARDOWN_VERNANT_PYTHON=$dir/$override" "VIRTUAL_ENV=$dir/decoy" \
    "PATH=$dir/decoy/bin:$dir/stubs:$dir/pybin:/usr/bin:/bin" "${SLOT_ENV_POLLUTION[@]}" || rc=$?
  expect_code 0 "$rc" "C2 $name: closeout failed: $(cat "$dir/closeout.out" 2>/dev/null)"
  printf '%s\n' "$dir"
}

test_c2_override_outside_any_venv() {
  local dir field
  dir=$(closeout_with_override c2 pybin/python3 | tail -n 1)
  assert_equals "" "$(slot_env_field "$dir" VIRTUAL_ENV)" 'C2: VIRTUAL_ENV must be unset for an interpreter outside any .venv'
  assert_equals "$dir/stubs:$dir/pybin:/usr/bin:/bin" "$(slot_env_field "$dir" path)" 'C2: foreign venv bins must be filtered and no venv bin may lead PATH'
  for field in PYTHONPATH PYTHONHOME PYTHONUSERBASE PYTHONSTARTUP __PYVENV_LAUNCHER__ UV_PROJECT_ENVIRONMENT CONDA_PREFIX; do
    assert_equals "" "$(slot_env_field "$dir" "$field")" "C2: $field reached the closeout driver"
  done
  pass 'C2: an explicit interpreter outside any .venv runs with VIRTUAL_ENV unset and its own bin not put on PATH'
}

test_c3_override_under_tree_venv() {
  local dir
  dir=$(closeout_with_override c3 copy/.venv/bin/python | tail -n 1)
  assert_equals "$dir/copy/.venv" "$(slot_env_field "$dir" VIRTUAL_ENV)" 'C3: VIRTUAL_ENV must be the tree venv'
  assert_equals "$dir/copy/.venv/bin" "$(slot_env_field "$dir" path_head)" 'C3: the tree venv bin must lead PATH'
  pass 'C3: an explicit interpreter under the tree venv gets the tree environment'
}

test_c4_override_under_another_venv() {
  local dir
  dir=$(closeout_with_override c4 decoy/bin/python | tail -n 1)
  assert_equals "" "$(slot_env_field "$dir" VIRTUAL_ENV)" 'C4: VIRTUAL_ENV must be unset for an interpreter under another venv'
  assert_equals "$dir/stubs:$dir/pybin:/usr/bin:/bin" "$(slot_env_field "$dir" path)" 'C4: the other venv bin must not be on PATH'
  pass 'C4: an explicit interpreter under another venv runs with VIRTUAL_ENV unset and its bin filtered'
}

# A tree with no interpreter of its own is refused by name; the caller's python3
# is never used in its place, and nothing is created or installed.
test_c5_closeout_without_tree_environment_refuses() {
  local dir rc=0 out
  dir=$(make_closeout_world c5 none) || fail 'the fixture world was not built'
  slot_env_listing "$dir" > "$dir/listing-before.txt"
  slot_env_run_closeout "$dir" "$dir/copy" || rc=$?
  expect_code 127 "$rc" 'C5: a tree with no interpreter must be refused'
  out=$(cat "$dir/closeout.out")
  assert_contains "$out" "$dir/copy/.venv/bin/python" 'C5: the refusal does not name the missing interpreter'
  assert_contains "$out" 'not available' 'C5: the refusal is not named'
  [ ! -e "$dir/env-record.json" ] || fail 'C5: the driver ran in another environment'
  slot_env_listing "$dir" > "$dir/listing-after.txt"
  cmp -s "$dir/listing-before.txt" "$dir/listing-after.txt" || fail 'C5: entries appeared or vanished'
  [ ! -s "$dir/stub-calls.log" ] || fail "C5: something was installed or created: $(cat "$dir/stub-calls.log")"
  pass 'C5: a closeout tree with no interpreter is refused by name with no fallback and nothing created'
}

# The operator's explicit interpreter wins over the tree's default, and a run
# with neither is refused. tests/fm-copy-sweep.test.sh drives the real sweep's
# existence test against the same choice.
test_c6_closeout_default_and_override_choice() {
  local dir rc
  dir=$(make_closeout_world c6 symlinks) || fail 'the fixture world was not built'
  rc=0
  slot_env_run_closeout "$dir" "$dir/copy" || rc=$?
  assert_equals 0 "$rc" 'C6: closeout refused a usable default interpreter'
  rc=0
  slot_env_run_closeout "$dir" "$dir/copy" "FM_TEARDOWN_VERNANT_PYTHON=$dir/nonexistent-python" || rc=$?
  assert_equals 127 "$rc" 'C6: closeout ran an interpreter the operator did not name'
  rm -rf "$dir/copy/.venv"
  rc=0
  slot_env_run_closeout "$dir" "$dir/copy" "FM_TEARDOWN_VERNANT_PYTHON=$dir/pybin/python3" || rc=$?
  assert_equals 0 "$rc" 'C6: closeout refused a usable explicit interpreter'
  rc=0
  slot_env_run_closeout "$dir" "$dir/copy" || rc=$?
  assert_equals 127 "$rc" 'C6: closeout ran with no interpreter at all'
  pass 'C6: teardown_run_closeout takes the explicit interpreter over the default and refuses when neither is usable'
}

# ---- slot-record retirement --------------------------------------------------

# The fixture entry point records what it saw, retires the records it is told
# about (the slot's record in the durable store) and attests.
slot_env_write_retire_entry() { # <tree>
  mkdir -p "$1/scripts/git-stability"
  cat > "$1/scripts/git-stability/retire_slot_manifest.py" <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path

NAMES = ("VIRTUAL_ENV", "PYTHONPATH", "PYTHONHOME", "PYTHONUSERBASE", "PYTHONSTARTUP",
         "__PYVENV_LAUNCHER__", "UV_PROJECT_ENVIRONMENT", "CONDA_PREFIX", "FM_SENTINEL", "HOME",
         "TMPDIR", "CODEX_HOOK_STATE_DIR", "WORKTREE_LIFECYCLE_STORE_DIR", "GIT_AUTHOR_NAME")
record = {name: os.environ.get(name) for name in NAMES}
path = os.environ.get("PATH", "")
record.update(sys_executable=sys.executable, sys_prefix=sys.prefix, path=path, path_head=path.split(":")[0],
              cwd=os.getcwd(), script=os.path.abspath(__file__), argv=sys.argv[1:])
Path(os.environ["FM_TEST_ENV_RECORD"]).write_text(json.dumps(record), encoding="utf-8")
args = sys.argv[1:]
slot = args[args.index("--slot-path") + 1]
name = hashlib.sha256(str(Path(slot).resolve()).encode()).hexdigest()[:16] + ".json"
for root in (os.environ["WORKTREE_LIFECYCLE_STORE_DIR"], args[args.index("--state-dir") + 1] + "/worktree-lifecycle"):
    try:
        os.unlink(os.path.join(root, name))
    except FileNotFoundError:
        pass
print(json.dumps({"status": "retired"}))
PY
}

# A retire world: a nested project clone (a git repository), a slot copy with a
# lifecycle record, and nothing else. <project-tree> and <copy-tree> say what each
# tree holds: script, venv, both, or none.
make_retire_world() { # <name> <project: none|script|venv|both> <copy: none|script|venv|both>
  local name=$1 pshape=$2 cshape=$3 dir slot hashname
  dir=$(slot_env_make_world "$name" none) || return 1
  slot=$dir/copy
  retire_tree_shape "$dir/project" "$pshape" clone
  retire_tree_shape "$slot" "$cshape" copy
  hashname=$("$SLOT_ENV_BASE_PY" -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:16] + ".json")' "$(cd -P "$slot" && pwd -P)")
  mkdir -p "$dir/lifecycle" "$dir/state"
  printf '{"branch": "fm/retire-task", "owner_id": "retire-task", "worktree_path": "%s", "repo_root": "%s"}\n' \
    "$slot" "$dir/project" > "$dir/lifecycle/$hashname"
  printf '{}\n' > "$dir/proof.json"
  printf '%s\n' "$dir"
}

retire_tree_shape() { # <tree> <none|script|venv|both> <clone|copy>
  local tree=$1 shape=$2 kind=$3
  case "$shape" in script|both) slot_env_write_retire_entry "$tree" ;; esac
  case "$shape" in
    venv|both)
      if [ "$kind" = copy ]; then
        "$SLOT_ENV_BASE_PY" -m venv --without-pip "$tree/.venv" || fail 'fixture venv build failed'
      else
        mkdir -p "$tree/.venv/bin"
        ln -s "$SLOT_ENV_BASE_PY" "$tree/.venv/bin/python"
      fi
      ;;
  esac
}

# Runs the retire script for the slot under a clean environment (apply phase).
# <dir> <phase: apply|prove> [NAME=value...]; output in <dir>/retire.out and .err.
slot_env_run_retire() {
  local dir=$1 phase=$2 line
  local -a assign=() phase_args=()
  shift 2
  while IFS= read -r line; do assign+=("$line"); done < <(slot_env_base_assignments "$dir")
  if [ "$phase" = apply ]; then
    phase_args=(--apply --proof-file "$dir/proof.json")
  else
    phase_args=(--prove-to "$dir/proof-out.json")
  fi
  env -i "${assign[@]}" "$@" "$SLOT_ENV_BASE_PY" "$RETIRE" --project "$dir/project" \
    --firstmate-state "$dir/state" --slot "$dir/copy" --owner-id retire-task \
    --owner-branch fm/retire-task --state-dir "$dir/codex-hooks" "${phase_args[@]}" \
    >"$dir/retire.out" 2>"$dir/retire.err"
}

retire_record_script() { slot_env_field "$1" script; }

test_s4a_clone_without_script_or_venv_retires_in_copy() {
  local dir rc=0
  dir=$(make_retire_world s4a none both) || fail 'the fixture world was not built'
  slot_env_run_retire "$dir" apply || rc=$?
  expect_code 0 "$rc" "S4a: retire failed: $(cat "$dir/retire.out" "$dir/retire.err")"
  assert_equals "$dir/copy/scripts/git-stability/retire_slot_manifest.py" "$(retire_record_script "$dir")" 'S4a: the copy script did not run'
  assert_equals "$dir/copy/.venv/bin/python" "$(slot_env_field "$dir" sys_executable)" 'S4a: the copy interpreter did not run it'
  [ -z "$(ls "$dir/lifecycle")" ] || fail 'S4a: the slot record was not retired'
  pass 'S4a: a clone with no script and no .venv retires through the copy script and the copy interpreter'
}

test_s4c_clone_script_without_venv_uses_copy_tree() {
  local dir rc=0
  dir=$(make_retire_world s4c script both) || fail 'the fixture world was not built'
  slot_env_run_retire "$dir" apply || rc=$?
  expect_code 0 "$rc" "S4c: retire failed: $(cat "$dir/retire.out" "$dir/retire.err")"
  assert_equals "$dir/copy/scripts/git-stability/retire_slot_manifest.py" "$(retire_record_script "$dir")" 'S4c: the clone script ran without its interpreter'
  assert_equals "$dir/copy/.venv/bin/python" "$(slot_env_field "$dir" sys_executable)" 'S4c: the copy interpreter did not run it'
  pass 'S4c: a clone script with no .venv yields to the copy script and the copy interpreter'
}

test_s4_project_with_script_and_venv_still_wins() {
  local dir rc=0
  dir=$(make_retire_world s4keep both both) || fail 'the fixture world was not built'
  slot_env_run_retire "$dir" apply || rc=$?
  expect_code 0 "$rc" "S4 preserve: retire failed: $(cat "$dir/retire.out" "$dir/retire.err")"
  assert_equals "$dir/project/scripts/git-stability/retire_slot_manifest.py" "$(retire_record_script "$dir")" 'S4 preserve: the project script no longer wins'
  assert_equals "$dir/project/.venv" "$(slot_env_field "$dir" VIRTUAL_ENV)" 'S4 preserve: the project environment did not run it'
  pass 'S4 preserve: a project holding script and interpreter still runs its own'
}

test_s4b_script_without_usable_interpreter_refuses_by_name() {
  local shape pshape cshape dir rc out
  for shape in "script none" "none script" "script script" "script venv" "venv script"; do
    read -r pshape cshape <<<"$shape"
    dir=$(make_retire_world "s4b-$pshape-$cshape" "$pshape" "$cshape") || fail 'the fixture world was not built'
    rc=0
    slot_env_run_retire "$dir" apply || rc=$?
    [ "$rc" = 1 ] || fail "S4b ($shape): expected a refusal, got exit $rc: $(cat "$dir/retire.out" "$dir/retire.err")"
    out=$(cat "$dir/retire.out" "$dir/retire.err")
    assert_contains "$out" 'no usable interpreter for' "S4b ($shape): the refusal is not named"
    assert_contains "$out" 'next step: give the tree that holds the script its own .venv' "S4b ($shape): the refusal names no next step"
    assert_contains "$out" 'rerun teardown' "S4b ($shape): the refusal does not say how to continue"
    [ ! -e "$dir/env-record.json" ] || fail "S4b ($shape): the script ran in another environment"
    [ -n "$(ls "$dir/lifecycle")" ] || fail "S4b ($shape): the slot record was removed"
  done
  pass 'S4b: a script with no usable interpreter is refused by name with its next step and no fallback'
}

test_s4d_no_script_keeps_the_old_behavior() {
  local dir rc=0
  dir=$(make_retire_world s4d none none) || fail 'the fixture world was not built'
  slot_env_run_retire "$dir" apply || rc=$?
  expect_code 0 "$rc" "S4d: a slot with no entry point must not fail: $(cat "$dir/retire.err")"
  assert_contains "$(cat "$dir/retire.out")" 'retire_slot_manifest.py; lifecycle records unchanged' 'S4d: the old report line changed'
  [ -n "$(ls "$dir/lifecycle")" ] || fail 'S4d: the record was changed'
  pass 'S4d: no entry point in either tree keeps the existing report-and-continue behavior'
}

# --prove-to builds the landing proof whenever the script exists, so a missing
# interpreter is refused at --apply (where the work is) and never hides in the
# proof phase; with no script it writes nothing, as before.
test_s4f_prove_phase_follows_the_same_rule() {
  local dir rc=0
  dir=$(make_retire_world s4f-script script none) || fail 'the fixture world was not built'
  slot_env_run_retire "$dir" prove || rc=$?
  expect_code 0 "$rc" "S4f: the proof phase must not refuse: $(cat "$dir/retire.err")"
  [ -s "$dir/proof-out.json" ] || fail 'S4f: no landing proof was built although the script exists'
  dir=$(make_retire_world s4f-none none none) || fail 'the fixture world was not built'
  rc=0
  slot_env_run_retire "$dir" prove || rc=$?
  expect_code 0 "$rc" 'S4f: the proof phase with no script failed'
  [ ! -e "$dir/proof-out.json" ] || fail 'S4f: a proof was written with no script'
  pass 'S4f: --prove-to builds the proof when the script exists and writes none otherwise'
}

test_s2_retire_pollution_never_reaches_the_entry_point() {
  local dir rc=0 field
  dir=$(make_retire_world s2retire none both) || fail 'the fixture world was not built'
  slot_env_add_decoy_venv "$dir"
  slot_env_snapshot_decoy "$dir" before
  slot_env_run_retire "$dir" apply "${SLOT_ENV_POLLUTION[@]}" "VIRTUAL_ENV=$dir/decoy" \
    "PATH=$dir/decoy/bin:$dir/stubs:$dir/pybin:/usr/bin:/bin" || rc=$?
  [ -z "${FM_TEST_SHOW_RECORD:-}" ] || { printf 'record: '; cat "$dir/env-record.json" 2>/dev/null; printf '\n'; }
  expect_code 0 "$rc" "S2 retire: retire failed: $(cat "$dir/retire.out" "$dir/retire.err")"
  assert_equals "$dir/copy/.venv" "$(slot_env_field "$dir" VIRTUAL_ENV)" 'S2 retire: VIRTUAL_ENV is not the tree venv'
  for field in PYTHONPATH PYTHONHOME PYTHONUSERBASE PYTHONSTARTUP __PYVENV_LAUNCHER__ UV_PROJECT_ENVIRONMENT CONDA_PREFIX; do
    assert_equals "" "$(slot_env_field "$dir" "$field")" "S2 retire: $field reached the entry point"
  done
  assert_equals "$dir/copy/.venv/bin" "$(slot_env_field "$dir" path_head)" 'S2 retire: the tree venv bin does not lead PATH'
  assert_equals "$dir/copy/.venv/bin:$dir/stubs:$dir/pybin:/usr/bin:/bin" "$(slot_env_field "$dir" path)" 'S2 retire: PATH is wrong'
  assert_equals sentinel "$(slot_env_field "$dir" FM_SENTINEL)" 'S2 retire: FM_SENTINEL was dropped'
  assert_equals "$dir/home" "$(slot_env_field "$dir" HOME)" 'S2 retire: HOME was changed'
  assert_equals "$dir/codex-hooks" "$(slot_env_field "$dir" CODEX_HOOK_STATE_DIR)" 'S2 retire: CODEX_HOOK_STATE_DIR was changed'
  assert_equals "$dir/lifecycle" "$(slot_env_field "$dir" WORKTREE_LIFECYCLE_STORE_DIR)" 'S2 retire: WORKTREE_LIFECYCLE_STORE_DIR was changed'
  assert_equals "Fixture" "$(slot_env_field "$dir" GIT_AUTHOR_NAME)" 'S2 retire: a GIT_ identity variable was changed'
  slot_env_snapshot_decoy "$dir" after
  cmp -s "$dir/decoy-before.txt" "$dir/decoy-after.txt" || fail 'S2 retire: the decoy venv changed'
  pass 'S2: the retire entry point runs in its tree environment with the ambient environment scrubbed'
}

# S4e: the sweep-loop caller (--apply without --slot) calls the same retire()
# and so applies the same rule. The loop reads the owner's done record through
# fm-tasks-axi.sh and the forge through gh-axi, so the script runs from a scratch
# copy of bin with stubs for those two (and the guard-event writer).
test_s4e_sweep_loop_applies_the_same_rule() {
  local dir rc=0 head bin out
  dir=$(make_retire_world s4e none none) || fail 'the fixture world was not built'
  head=$(git -C "$dir/project" rev-parse HEAD)
  bin="$dir/binroot"
  mkdir -p "$bin"
  cp "$ROOT/bin/fm-slot-manifest-retire.py" "$ROOT/bin/fm-copy-env.sh" "$ROOT/bin/fm-copy-env-lib.sh" "$bin/"
  printf '#!/bin/sh\nprintf "  state: done\\n  links: pr:https://github.com/o/r/pull/1\\n"\n' > "$bin/fm-tasks-axi.sh"
  printf '#!/bin/sh\nexit 0\n' > "$bin/fm-guard-event.sh"
  chmod +x "$bin/fm-tasks-axi.sh" "$bin/fm-guard-event.sh"
  printf '#!/bin/sh\nprintf "merged: true\\nhead: %s\\nmerge: %s\\nbranch: fm/retire-task\\n"\n' "$head" "$head" > "$dir/stubs/gh-axi"
  chmod +x "$dir/stubs/gh-axi"
  # The record names the slot copy; the copy must be on origin/main for the proof.
  retire_tree_shape "$dir/project" none clone
  retire_tree_shape "$dir/copy" script copy
  rm -rf "$dir/copy/.venv"
  run_loop() {
    local line
    local -a assign=()
    while IFS= read -r line; do assign+=("$line"); done < <(slot_env_base_assignments "$dir")
    env -i "${assign[@]}" "$SLOT_ENV_BASE_PY" "$bin/fm-slot-manifest-retire.py" --project "$dir/project" \
      --firstmate-state "$dir/state" --state-dir "$dir/codex-hooks" --apply >"$dir/loop.out" 2>"$dir/loop.err"
  }
  # A script and no usable interpreter anywhere: the loop refuses by name, keeps the record.
  run_loop || rc=$?
  [ "$rc" = 1 ] || fail "S4e: expected the loop to fail, got $rc: $(cat "$dir/loop.out" "$dir/loop.err")"
  out=$(cat "$dir/loop.out" "$dir/loop.err")
  assert_contains "$out" 'retire=REFUSED' 'S4e: the loop did not refuse'
  assert_contains "$out" 'no usable interpreter for' 'S4e: the loop refusal is not named'
  [ ! -e "$dir/env-record.json" ] || fail 'S4e: the script ran in another environment'
  [ -n "$(ls "$dir/lifecycle")" ] || fail 'S4e: the slot record was removed'
  # With the copy's own environment the same loop retires through the copy tree.
  "$SLOT_ENV_BASE_PY" -m venv --without-pip "$dir/copy/.venv" || fail 'fixture venv build failed'
  rc=0
  run_loop || rc=$?
  expect_code 0 "$rc" "S4e: the loop failed with a usable environment: $(cat "$dir/loop.out" "$dir/loop.err")"
  assert_equals "$dir/copy/scripts/git-stability/retire_slot_manifest.py" "$(retire_record_script "$dir")" 'S4e: the copy script did not run'
  assert_equals "$dir/copy/.venv/bin/python" "$(slot_env_field "$dir" sys_executable)" 'S4e: the copy interpreter did not run it'
  [ -z "$(ls "$dir/lifecycle")" ] || fail 'S4e: the record was not retired'
  pass 'S4e: the sweep-loop caller refuses without an interpreter and runs in the owning tree with one'
}

fm_test_run_cases \
  test_c1_closeout_pollution_never_reaches_the_driver \
  test_c2_override_outside_any_venv \
  test_c3_override_under_tree_venv \
  test_c4_override_under_another_venv \
  test_c5_closeout_without_tree_environment_refuses \
  test_c6_closeout_default_and_override_choice \
  test_s4a_clone_without_script_or_venv_retires_in_copy \
  test_s4c_clone_script_without_venv_uses_copy_tree \
  test_s4_project_with_script_and_venv_still_wins \
  test_s4b_script_without_usable_interpreter_refuses_by_name \
  test_s4d_no_script_keeps_the_old_behavior \
  test_s4f_prove_phase_follows_the_same_rule \
  test_s2_retire_pollution_never_reaches_the_entry_point \
  test_s4e_sweep_loop_applies_the_same_rule \
  -- "$@"
