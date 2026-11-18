#!/usr/bin/env bash
# Unit cases for the relaunch adoption decision and its helpers in bin/fm-slot-provision-lib.sh and the custody owner
# bin/fm-task-copy-lib.sh: the pool-slot claim's home, an unreadable foreign record, the drift report's attribution
# (a change the default branch absorbed and reverted, a hidden symlink retarget), the primary-clone provisioner's
# cache-free export (a forged cached module must not run, a substituted file is detected), and the old-copy preflight
# that asks the provisioner that would really run. Every case runs on scratch repositories built here.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-slot-adopt)
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-task-copy-lib.sh
. "$ROOT/bin/fm-task-copy-lib.sh"
# shellcheck source=bin/fm-slot-provision-lib.sh
. "$ROOT/bin/fm-slot-provision-lib.sh"
trap 'fm_test_cleanup' EXIT

GITID=(-c user.name='Firstmate Tests' -c user.email='tests@example.invalid')

# make_world <name>: a project clone on main with a bare origin and a pool slot (<pool>/1/repo) holding branch fm/t,
# its manifest, its task record and an owner claim directory. Sets W_DIR W_PROJ W_SLOT W_STATE W_META W_MANIFEST W_BASE.
make_world() {
  local name=$1
  W_DIR="$TMP_ROOT/$name"
  W_PROJ="$W_DIR/project"
  W_SLOT="$W_DIR/pool/1/repo"
  W_STATE="$W_DIR/home/state"
  W_META="$W_STATE/t.meta"
  W_MANIFEST="$W_DIR/manifest.json"
  mkdir -p "$W_STATE" "$W_DIR/home/data" "$W_DIR/pool/1"
  git init --quiet -b main "$W_PROJ"
  mkdir -p "$W_PROJ/src" "$W_PROJ/docs"
  printf 'owned\n' >"$W_PROJ/src/a.txt"
  printf 'doc\n' >"$W_PROJ/docs/y.txt"
  git -C "$W_PROJ" add -A
  git -C "$W_PROJ" "${GITID[@]}" commit -qm initial
  git clone --quiet --bare "$W_PROJ" "$W_DIR/origin.git"
  git -C "$W_PROJ" remote add origin "file://$W_DIR/origin.git"
  git -C "$W_PROJ" fetch --quiet origin
  W_BASE=$(git -C "$W_PROJ" rev-parse HEAD)
  git -C "$W_PROJ" worktree add --quiet -b fm/t "$W_SLOT" "$W_BASE"
  printf '{}\n' >"$W_DIR/pool/treehouse-state.json"
  python3 - "$W_MANIFEST" "$W_SLOT" "$W_PROJ" "$W_BASE" <<'PY'
import json, os, sys
path, slot, proj, base = sys.argv[1:5]
json.dump(dict(worktree_path=os.path.realpath(slot), owner_id="t", branch="fm/t", base_sha=base, owned_paths=["src"],
               lifecycle_state="worktree_active", repo_root=os.path.realpath(proj)), open(path, "w"))
PY
  {
    printf 'worktree=%s\nproject=%s\nbranch=fm/t\nkind=ship\n' "$W_SLOT" "$W_PROJ"
    printf 'slot_manifest=%s\nslot_base_sha=%s\nslot_owned_path=src\n' "$W_MANIFEST" "$W_BASE"
  } >"$W_META"
  export FM_HOME="$W_DIR/home"
}

adopt() { fm_slot_adopt_check "$W_PROJ" "$W_SLOT" t fm/t "$W_META" "$W_STATE" 2>&1; }

test_same_task_claim_from_another_home_is_not_this_tasks_own() {
  local out rc
  make_world claim-home
  printf 'task=t\nhome=%s\n' "$W_DIR/foreign-home" >"$W_DIR/pool/1/.fm-slot-owner"
  mkdir -p "$W_DIR/foreign-home"
  out=$(adopt); rc=$?
  [ "$rc" -ne 0 ] || fail "a same-ID claim naming another home was adopted: $out"
  assert_contains "$out" custody_slot_claim 'the refusal did not name the claim'
  printf 'task=t\nhome=\n' >"$W_DIR/pool/1/.fm-slot-owner"
  out=$(adopt); rc=$?
  [ "$rc" -ne 0 ] || fail "a same-ID claim naming no home was adopted: $out"
  printf 'task=somebody-else\nhome=%s\n' "$W_DIR/home" >"$W_DIR/pool/1/.fm-slot-owner"
  out=$(adopt); rc=$?
  [ "$rc" -ne 0 ] || fail "another task's claim was adopted: $out"
  # controls: the own claim, through an alias of this home, and no claim at all
  ln -s "$W_DIR/home" "$W_DIR/home-alias"
  printf 'task=t\nhome=%s\n' "$W_DIR/home-alias" >"$W_DIR/pool/1/.fm-slot-owner"
  out=$(adopt); rc=$?
  [ "$rc" -eq 0 ] || fail "the own claim through an alias of this home was refused: $out"
  rm -f "$W_DIR/pool/1/.fm-slot-owner"
  out=$(adopt); rc=$?
  [ "$rc" -eq 0 ] || fail "a legacy task with no claim was refused: $out"
  pass "adoption: a same-task claim naming another home or no home is refused; the own claim (alias too) and no claim are admitted"
}

test_an_unreadable_foreign_record_is_an_error_not_no_conflict() {
  local out rc
  make_world custody-unreadable
  printf 'worktree=%s\nproject=%s\nkind=ship\n' "$W_SLOT" "$W_PROJ" >"$W_STATE/foreign.meta"
  out=$(adopt); rc=$?
  [ "$rc" -ne 0 ] || fail "a readable foreign record naming the copy was ignored: $out"
  assert_contains "$out" custody_other_record 'the readable foreign record was not named'
  chmod 000 "$W_STATE/foreign.meta"
  out=$(adopt); rc=$?
  chmod 600 "$W_STATE/foreign.meta"
  [ "$rc" -ne 0 ] || fail "an unreadable foreign record counted as no conflicting holder: $out"
  assert_contains "$out" custody_unreadable 'the unreadable record was not refused by name'
  rm -f "$W_STATE/foreign.meta"
  out=$(adopt); rc=$?
  [ "$rc" -eq 0 ] || fail "the own copy with no foreign record was refused: $out"
  pass "adoption: an unreadable foreign custody record is refused by name, a readable one is named, the own copy is admitted"
}

drift() { fm_slot_drift_report "$W_SLOT" t fm/t "$W_BASE" src 2>&1; }

test_a_hidden_symlink_retarget_is_task_drift() {
  local out
  make_world drift-symlink
  ln -s original-target "$W_PROJ/docs/link"
  git -C "$W_PROJ" add docs/link
  git -C "$W_PROJ" "${GITID[@]}" commit -qm 'add link'
  git -C "$W_SLOT" merge --quiet --ff-only fm/t main 2>/dev/null || git -C "$W_SLOT" reset --quiet --hard "$(git -C "$W_PROJ" rev-parse main)"
  W_BASE=$(git -C "$W_SLOT" rev-parse HEAD)
  git -C "$W_SLOT" update-ref refs/remotes/origin/main "$W_BASE"
  out=$(drift)
  case "$out" in *docs/link*) fail "an unchanged tracked symlink was listed: $out" ;; esac
  git -C "$W_SLOT" update-index --assume-unchanged docs/link
  rm "$W_SLOT/docs/link"
  ln -s new-target "$W_SLOT/docs/link"
  [ -z "$(git -C "$W_SLOT" status --porcelain)" ] || fail 'the fixture is not hidden from status'
  out=$(drift)
  assert_contains "$out" 'drift: proven docs/link' 'the hidden symlink retarget was omitted from the drift report'
  pass "drift: a hidden (assume-unchanged) tracked symlink retarget is listed, an unchanged one is not"
}

test_a_change_the_default_branch_absorbed_and_reverted_is_still_task_drift() {
  local out revert
  make_world drift-reverted
  printf 'task change\n' >"$W_SLOT/docs/out.txt"
  git -C "$W_SLOT" add docs/out.txt
  git -C "$W_SLOT" "${GITID[@]}" commit -qm 'task commit outside scope'
  # the default branch absorbs the task commit, then reverts it, so no net diff remains against the fork point
  git -C "$W_SLOT" update-ref refs/remotes/origin/main HEAD
  revert=$(git -C "$W_SLOT" "${GITID[@]}" commit-tree "$W_BASE^{tree}" -p HEAD -m 'revert the task change')
  git -C "$W_SLOT" update-ref refs/remotes/origin/main "$revert"
  out=$(drift)
  assert_contains "$out" 'docs/out.txt' 'a task change that main absorbed and reverted vanished from the drift report'
  assert_contains "$out" 'proven' 'the attributed path is not labelled proven'
  # control: upstream-only work that the task merely received is not the task's drift
  make_world drift-upstream
  git -C "$W_PROJ" checkout --quiet -b side
  printf 'upstream\n' >"$W_PROJ/docs/y.txt"
  git -C "$W_PROJ" "${GITID[@]}" commit -qam 'main changes docs/y'
  git -C "$W_SLOT" fetch --quiet "$W_PROJ" side
  git -C "$W_SLOT" merge --quiet --ff-only FETCH_HEAD
  git -C "$W_SLOT" update-ref refs/remotes/origin/main FETCH_HEAD
  out=$(drift)
  case "$out" in *docs/y.txt*) fail "an upstream-only path was listed as the task's: $out" ;; esac
  pass "drift: a task change that main absorbed and reverted is listed; an upstream-only path is not"
}

# make_primary <name>: a project whose primary checkout holds a provisioner that imports a sibling module, committed on main.
make_primary() {
  local name=$1
  P_DIR="$TMP_ROOT/$name"
  P_PROJ="$P_DIR/project"
  git init --quiet -b main "$P_PROJ"
  mkdir -p "$P_PROJ/scripts/git-stability"
  printf 'print("TIP_MODULE")\n' >"$P_PROJ/scripts/git-stability/helper_mod.py"
  printf 'import helper_mod  # noqa\nimport sys\nif "--check-manifest-only" in sys.argv:\n    print("{\\"state\\": \\"BLOCKED\\", \\"reason\\": \\"manifest_exists\\"}")\n' \
    >"$P_PROJ/scripts/git-stability/provision_existing_slot.py"
  git -C "$P_PROJ" add -A
  git -C "$P_PROJ" "${GITID[@]}" commit -qm initial
}

plant_forged_cache() { # <primary>: a matching-header cached module whose code differs from its source
  python3 - "$1/scripts/git-stability/helper_mod.py" <<'PY'
import importlib.util, marshal, os, struct, sys
src = sys.argv[1]
info = os.stat(src)
tag = sys.implementation.cache_tag
cache = os.path.join(os.path.dirname(src), "__pycache__")
os.makedirs(cache, exist_ok=True)
code = compile('print("FORGED_MODULE")', src, "exec")
with open(os.path.join(cache, "helper_mod.%s.pyc" % tag), "wb") as handle:
    handle.write(importlib.util.MAGIC_NUMBER + struct.pack("<I", 0) + struct.pack("<II", int(info.st_mtime) & 0xFFFFFFFF, info.st_size & 0xFFFFFFFF) + marshal.dumps(code))
PY
}

test_a_forged_cached_module_never_runs_and_a_substitution_is_detected() {
  local out
  make_primary primary-cache
  plant_forged_cache "$P_PROJ"
  out=$(cd "$P_PROJ" && python3 scripts/git-stability/provision_existing_slot.py 2>&1)
  assert_contains "$out" FORGED_MODULE 'the fixture is vacuous: the forged cache does not run on the unprotected route'
  fm_slot_primary_provisioner "$P_PROJ" || fail 'the clean primary provisioner was refused'
  out=$(fm_slot_run_local "$P_PROJ" "$P_DIR/report" "${FM_SLOT_PYARGS[@]}" "$FM_SLOT_PROVISIONER" >/dev/null; cat "$P_DIR/report")
  assert_contains "$out" TIP_MODULE 'the verified tip module did not run'
  case "$out" in *FORGED_MODULE*) fail "a forged cached module ran on the verified route: $out" ;; esac
  case "$FM_SLOT_PROVISIONER" in "$P_PROJ"/*) fail 'the provisioner runs in place from the clone, not from the private export' ;; esac
  fm_slot_export_verify || fail 'an untouched export failed its own verification'
  chmod -R u+w "$FM_SLOT_EXPORT"
  printf '# substituted\n' >>"$FM_SLOT_EXPORT/scripts/git-stability/helper_mod.py"
  if fm_slot_export_verify 2>/dev/null; then fail 'a substitution after the check was not detected'; fi
  fm_slot_export_drop
  # a locally changed imported module is refused before anything runs
  printf '# local edit\n' >>"$P_PROJ/scripts/git-stability/helper_mod.py"
  if fm_slot_primary_provisioner "$P_PROJ" 2>/dev/null; then fail 'a primary clone whose imported module differs from the tip was accepted'; fi
  pass "primary provisioner: a forged cached module does not run, a substituted export file is detected, a locally changed module is refused"
}

test_old_copy_preflight_asks_the_provisioner_that_would_really_run() {
  local out rc
  make_primary primary-preflight
  git -C "$P_PROJ" "${GITID[@]}" commit -q --allow-empty -m second
  git clone --quiet --bare "$P_PROJ" "$P_DIR/origin.git"
  git -C "$P_PROJ" remote add origin "file://$P_DIR/origin.git"
  git -C "$P_PROJ" fetch --quiet origin
  # the assigned copy predates the provisioner: it sits at a commit that has no scripts directory
  printf 'x\n' >"$P_PROJ/README.md"
  git -C "$P_PROJ" add README.md
  git -C "$P_PROJ" "${GITID[@]}" commit -qm 'readme'
  git -C "$P_PROJ" push -q origin main
  git -C "$P_PROJ" fetch -q origin
  git -C "$P_PROJ" worktree add --quiet -b fm/t "$P_DIR/copy" origin/main
  git -C "$P_DIR/copy" rm -rq scripts
  git -C "$P_DIR/copy" "${GITID[@]}" commit -qm 'old copy has no provisioner'
  git -C "$P_DIR/copy" update-ref refs/remotes/origin/main "$(git -C "$P_DIR/copy" rev-parse HEAD)"
  printf 'worktree=%s\nproject=%s\nkind=ship\n' "$P_DIR/copy" "$P_PROJ" >"$P_DIR/t.meta"
  [ ! -e "$P_DIR/copy/scripts/git-stability/provision_existing_slot.py" ] || fail 'the fixture copy still has the provisioner'
  out=$(fm_slot_foresee_refusals "$P_PROJ" "$P_DIR/copy" t fm/t "$P_DIR/t.meta" README.md 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "a clean old copy was refused by the preflight: $out"
  # the provisioner that would run reports a manifest collision through its read-only check
  python3 - "$P_PROJ/scripts/git-stability/provision_existing_slot.py" <<'PY'
import sys
p = sys.argv[1]
open(p, "w").write('import sys\nif "--check-manifest-only" in sys.argv:\n    print("{\\"state\\": \\"BLOCKED\\", \\"reason\\": \\"manifest_exists\\"}")\n')
PY
  git -C "$P_PROJ" "${GITID[@]}" commit -qam 'provisioner reports a collision'
  git -C "$P_PROJ" branch -f main HEAD 2>/dev/null || true
  out=$(fm_slot_foresee_refusals "$P_PROJ" "$P_DIR/copy" t fm/t "$P_DIR/t.meta" README.md 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an old copy with a manifest collision passed the preflight: $out"
  assert_contains "$out" manifest_exists 'the collision was not named by the preflight'
  pass "preflight: an old copy is judged by the primary provisioner's read-only check, collision refused, clean admitted"
}

CASES=(
test_same_task_claim_from_another_home_is_not_this_tasks_own
test_an_unreadable_foreign_record_is_an_error_not_no_conflict
test_a_hidden_symlink_retarget_is_task_drift
test_a_change_the_default_branch_absorbed_and_reverted_is_still_task_drift
test_a_forged_cached_module_never_runs_and_a_substitution_is_detected
test_old_copy_preflight_asks_the_provisioner_that_would_really_run
)

fm_test_run_cases "${CASES[@]}" -- "$@"
echo "# all fm-slot-adopt tests passed"
