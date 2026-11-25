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
  assert_contains "$out" 'drift: proven docs/out.txt' 'the attributed path is not labelled proven on its own drift line (the report header text "provenance" must not satisfy this)'
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
  # a substitution that is RESTORED (same bytes, same mode) before the run ends still changes the change time
  fm_slot_primary_provisioner "$P_PROJ" || fail 'the clean primary provisioner was refused on the second export'
  fm_slot_export_verify || fail 'an untouched second export failed its own verification'
  cp -p "$FM_SLOT_EXPORT/scripts/git-stability/helper_mod.py" "$P_DIR/helper_mod.saved"
  chmod u+w "$FM_SLOT_EXPORT/scripts/git-stability/helper_mod.py"
  printf '# substituted for the load\n' >>"$FM_SLOT_EXPORT/scripts/git-stability/helper_mod.py"
  cat "$P_DIR/helper_mod.saved" >"$FM_SLOT_EXPORT/scripts/git-stability/helper_mod.py"
  chmod a-w "$FM_SLOT_EXPORT/scripts/git-stability/helper_mod.py"
  cmp -s "$P_DIR/helper_mod.saved" "$FM_SLOT_EXPORT/scripts/git-stability/helper_mod.py" || fail 'the fixture did not restore the bytes'
  if fm_slot_export_verify 2>/dev/null; then fail 'a substitution restored to the same bytes and mode before the run ended was not detected'; fi
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

# A refusal on the second adopt check, after the launch wiring and the record were written, says so; the first check does not.
test_a_second_adoption_refusal_says_the_wiring_and_record_were_written() {
  local out rc
  make_world second-check
  rm -f "$W_MANIFEST"
  out=$(FM_SLOT_ADOPT_WIRED=1 adopt); rc=$?
  [ "$rc" -ne 0 ] || fail "a missing manifest was adopted at the second check: $out"
  assert_contains "$out" manifest_missing 'the second-check refusal did not name the reason'
  assert_contains "$out" 'already written' 'the second-check refusal did not say the wiring and record were already written'
  case "$out" in *'no manifest, scope, record or copy was changed'*) fail "the second-check refusal claims nothing was written: $out" ;; esac
  out=$(adopt); rc=$?
  [ "$rc" -ne 0 ] || fail "a missing manifest was adopted at the first check: $out"
  assert_contains "$out" 'no manifest, scope, record or copy was changed' 'the first-check refusal text changed'
  pass "adopt check: a refusal after the wiring and record were written says so; the first-check refusal keeps its text"
}

# A provision refused after the primary clone's verified export was made leaves no export or bytecode directory behind.
test_a_refused_provision_leaves_no_export_directory() {
  local out rc tmpd
  make_primary provision-cleanup
  git -C "$P_PROJ" worktree add --quiet -b fm/t "$P_DIR/copy" HEAD
  git -C "$P_DIR/copy" rm -rq scripts
  git -C "$P_DIR/copy" "${GITID[@]}" commit -qm 'old copy has no provisioner'
  tmpd=$P_DIR/tmp
  mkdir -p "$tmpd"
  out=$(TMPDIR="$tmpd" FM_SLOT_PRIMARY_PROVISIONER=1 fm_slot_provision true "$P_PROJ" "$P_DIR/copy" t 'bad..branch' "$P_DIR/report.json" '' '' README.md 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a provision with an invalid branch was accepted: $out"
  [ -z "$(ls -A "$tmpd")" ] || fail "a refused provision left temp directories: $(ls -A "$tmpd")"
  pass "provision: a refused provision after the verified export leaves no export or bytecode directory"
}

# D4(c): the recovery of a refused first provisioning keeps its prior behavior: it never takes the primary clone's
# provisioner for a prepared copy that lacks the script, while every other relaunch may.
test_a_refused_first_provisioning_recovery_never_takes_the_primary_provisioner() {
  local out rc
  make_primary recovery-route
  git -C "$P_PROJ" worktree add --quiet -b fm/t "$P_DIR/copy" HEAD
  git -C "$P_DIR/copy" rm -rq scripts
  git -C "$P_DIR/copy" "${GITID[@]}" commit -qm 'prepared copy has no provisioner'
  printf 'kind=ship\nrecovery=slot-provision-refused\n' >"$P_DIR/recovery.meta"
  printf 'kind=ship\n' >"$P_DIR/ordinary.meta"
  fm_slot_primary_route_allowed "$P_DIR/ordinary.meta" || fail 'an ordinary relaunch was denied the primary provisioner route'
  if fm_slot_primary_route_allowed "$P_DIR/recovery.meta"; then fail 'the recovery of a refused first provisioning was allowed the primary provisioner route'; fi
  # the flag fm-spawn sets from that answer: the recovery refuses the missing copy-local script as before
  out=$(FM_SLOT_PRIMARY_PROVISIONER=0 fm_slot_provision true "$P_PROJ" "$P_DIR/copy" t fm/t "$P_DIR/report.json" '' '' README.md 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a recovery without the route was admitted: $out"
  assert_contains "$out" 'slot provisioner is missing from assigned copy' 'the recovery did not refuse the missing copy-local script'
  # the paired control: the route flag set for an ordinary relaunch gets past that check
  out=$(FM_SLOT_PRIMARY_PROVISIONER=1 fm_slot_provision true "$P_PROJ" "$P_DIR/copy" t fm/t "$P_DIR/report.json" '' '' README.md 2>&1) || true
  case "$out" in *'missing from assigned copy'*) fail "the ordinary route was refused for the missing script: $out" ;; esac
  pass "provision: a refused-first-provisioning recovery refuses the missing copy-local provisioner; an ordinary relaunch takes the primary one"
}

# D8: a pinned provisioner without the read-only manifest check still has its collision named before the stop, from the
# two record paths its own writer uses; a provisioner with a same-owner arm is not foreseen, and a clean copy is admitted.
test_a_pinned_provisioner_without_the_check_option_still_has_its_collision_named() {
  local out rc digest
  make_primary pinned-preflight
  git clone --quiet --bare "$P_PROJ" "$P_DIR/origin.git"
  git -C "$P_PROJ" remote add origin "file://$P_DIR/origin.git"
  printf 'x\n' >"$P_PROJ/README.md"
  git -C "$P_PROJ" add README.md
  git -C "$P_PROJ" "${GITID[@]}" commit -qm readme
  # the pinned provisioner: create-only, no read-only check, no same-owner arm
  printf 'import sys\nprint("create-only")\n' >"$P_PROJ/scripts/git-stability/provision_existing_slot.py"
  git -C "$P_PROJ" "${GITID[@]}" commit -qam 'pinned create-only provisioner'
  git -C "$P_PROJ" push -q origin main
  git -C "$P_PROJ" fetch -q origin
  git -C "$P_PROJ" worktree add --quiet -b fm/t "$P_DIR/copy" origin/main
  git -C "$P_DIR/copy" rm -rq scripts
  git -C "$P_DIR/copy" "${GITID[@]}" commit -qm 'old copy has no provisioner'
  git -C "$P_DIR/copy" update-ref refs/remotes/origin/main "$(git -C "$P_DIR/copy" rev-parse HEAD)"
  printf 'worktree=%s\nproject=%s\nkind=ship\n' "$P_DIR/copy" "$P_PROJ" >"$P_DIR/t.meta"
  mkdir -p "$P_DIR/durable" "$P_DIR/hookstate/worktree-lifecycle"
  digest=$(python3 -c 'import hashlib,os,sys; print(hashlib.sha256(os.path.realpath(sys.argv[1]).encode()).hexdigest()[:16])' "$P_DIR/copy")
  export WORKTREE_LIFECYCLE_STORE_DIR="$P_DIR/durable" CODEX_HOOK_STATE_DIR="$P_DIR/hookstate"
  out=$(fm_slot_foresee_refusals "$P_PROJ" "$P_DIR/copy" t fm/t "$P_DIR/t.meta" README.md 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "a clean old copy with no record was refused: $out"
  printf '{}' >"$P_DIR/durable/$digest.json"
  out=$(fm_slot_foresee_refusals "$P_PROJ" "$P_DIR/copy" t fm/t "$P_DIR/t.meta" README.md 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a durable collision passed the preflight of a provisioner without the check option: $out"
  assert_contains "$out" manifest_exists 'the durable collision was not named'
  assert_contains "$out" "\"manifest_path\": \"$P_DIR/durable/$digest.json\"" 'the collision file was not named in the provisioner form'
  rm -f "$P_DIR/durable/$digest.json"
  printf '{}' >"$P_DIR/hookstate/worktree-lifecycle/$digest.json"
  out=$(fm_slot_foresee_refusals "$P_PROJ" "$P_DIR/copy" t fm/t "$P_DIR/t.meta" README.md 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a legacy collision passed the preflight of a provisioner without the check option: $out"
  assert_contains "$out" manifest_exists 'the legacy collision was not named'
  # a provisioner with a same-owner arm may admit an identical declaration: not foreseen, the existing rollback stays
  printf 'import sys\ndef _same_owner_outcome():\n    pass\n' >"$P_PROJ/scripts/git-stability/provision_existing_slot.py"
  git -C "$P_PROJ" "${GITID[@]}" commit -qam 'provisioner with a same-owner arm'
  out=$(fm_slot_foresee_refusals "$P_PROJ" "$P_DIR/copy" t fm/t "$P_DIR/t.meta" README.md 2>&1); rc=$?
  unset WORKTREE_LIFECYCLE_STORE_DIR CODEX_HOOK_STATE_DIR
  [ "$rc" -eq 0 ] || fail "a provisioner with a same-owner arm was refused by guesswork: $out"
  pass "preflight: a pinned provisioner without the check option has a durable or legacy collision named before the stop; a same-owner provisioner is not guessed"
}

# D2: when a durable lifecycle record exists for the copy it is the authoritative one, the recorded pointer must name it,
# and an existing legacy record must agree with it on the identity fields; a differing shadowed record is refused by name.
test_a_shadowed_or_disagreeing_lifecycle_record_is_refused_by_name() {
  local out rc digest durable legacy
  make_world shadowed
  mkdir -p "$W_DIR/durable" "$W_DIR/hookstate/worktree-lifecycle"
  digest=$(python3 -c 'import hashlib,os,sys; print(hashlib.sha256(os.path.realpath(sys.argv[1]).encode()).hexdigest()[:16])' "$W_SLOT")
  durable="$W_DIR/durable/$digest.json"
  legacy="$W_DIR/hookstate/worktree-lifecycle/$digest.json"
  export WORKTREE_LIFECYCLE_STORE_DIR="$W_DIR/durable" CODEX_HOOK_STATE_DIR="$W_DIR/hookstate"
  point_at() { sed -i.bak "s|^slot_manifest=.*|slot_manifest=$1|" "$W_META" && rm -f "$W_META.bak"; }
  differing() { python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); m["owner_id"]="another-task"; m["branch"]="fm/another"; json.dump(m, open(sys.argv[2],"w"))' "$1" "$2"; }
  # a legacy pointer whose durable record names another owner and branch is the shadowed case
  cp "$W_MANIFEST" "$legacy"
  differing "$W_MANIFEST" "$durable"
  point_at "$legacy"
  out=$(adopt); rc=$?
  [ "$rc" -ne 0 ] || fail "a legacy pointer shadowed by a differing durable record was adopted: $out"
  assert_contains "$out" manifest_shadowed 'the shadowed pointer was not refused by name'
  # a durable pointer whose legacy record names another owner and branch is the disagreeing case
  cp "$W_MANIFEST" "$durable"
  differing "$W_MANIFEST" "$legacy"
  point_at "$durable"
  out=$(adopt); rc=$?
  [ "$rc" -ne 0 ] || fail "a durable pointer whose legacy record disagrees was adopted: $out"
  assert_contains "$out" manifest_records_disagree 'the disagreeing legacy record was not refused by name'
  # F5: two records that differ only in a creation timestamp (its formatting) are the same admission, not a disagreement
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); m["created_at_iso"]="2026-11-01T10:00:00Z"; json.dump(m, open(sys.argv[2],"w"))' "$W_MANIFEST" "$durable"
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); m["created_at_iso"]="2026-11-01T10:00:00.000000+00:00"; json.dump(m, open(sys.argv[2],"w"))' "$W_MANIFEST" "$legacy"
  out=$(adopt); rc=$?
  [ "$rc" -eq 0 ] || fail "records that differ only in a timestamp's formatting were refused: $out"
  # controls: the durable pointer with an identical legacy record, and the durable pointer alone, are admitted
  cp "$W_MANIFEST" "$durable"
  cp "$W_MANIFEST" "$legacy"
  out=$(adopt); rc=$?
  [ "$rc" -eq 0 ] || fail "a durable pointer with an agreeing legacy record was refused: $out"
  rm -f "$legacy"
  out=$(adopt); rc=$?
  unset WORKTREE_LIFECYCLE_STORE_DIR CODEX_HOOK_STATE_DIR
  [ "$rc" -eq 0 ] || fail "a durable pointer alone was refused: $out"
  pass "adoption: a shadowed legacy pointer and a disagreeing legacy record are refused by name; the durable pointer, alone or with an agreeing legacy record, is admitted"
}

# D7 (e): the no-manifest route asks the adoption's custody owner before it provisions (fm-control.sh before the stop,
# fm-spawn.sh before the provisioner and before delivery): a clean copy another task's record names is refused by name.
test_the_no_manifest_route_consults_copy_custody() {
  local out rc
  make_primary noman-custody
  git clone --quiet --bare "$P_PROJ" "$P_DIR/origin.git"
  git -C "$P_PROJ" remote add origin "file://$P_DIR/origin.git"
  git -C "$P_PROJ" fetch --quiet origin
  git -C "$P_PROJ" worktree add --quiet -b fm/t "$P_DIR/copy" origin/main
  git -C "$P_DIR/copy" rm -rq scripts
  git -C "$P_DIR/copy" "${GITID[@]}" commit -qm 'old copy has no provisioner'
  git -C "$P_DIR/copy" update-ref refs/remotes/origin/main "$(git -C "$P_DIR/copy" rev-parse HEAD)"
  mkdir -p "$P_DIR/home/state" "$P_DIR/home/data"
  export FM_HOME="$P_DIR/home"
  printf 'worktree=%s\nproject=%s\nkind=ship\n' "$P_DIR/copy" "$P_PROJ" >"$P_DIR/home/state/t.meta"
  out=$(fm_slot_provision_custody "$P_PROJ" "$P_DIR/copy" t "$P_DIR/home/state/t.meta" "$P_DIR/home/state" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "the own copy was refused by the custody consult: $out"
  # a paused task's record that names the same copy, with no lifecycle manifest anywhere
  printf 'worktree=%s\nproject=%s\nkind=ship\n' "$P_DIR/copy" "$P_PROJ" >"$P_DIR/home/state/other.meta"
  out=$(fm_slot_provision_custody "$P_PROJ" "$P_DIR/copy" t "$P_DIR/home/state/t.meta" "$P_DIR/home/state" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a clean copy another task's record names reached the provisioner: $out"
  assert_contains "$out" 'slot provisioning refused: custody_other_record' 'the foreign holder was not refused by name on the provisioning route'
  rm -f "$P_DIR/home/state/other.meta"
  out=$(fm_slot_provision_custody "$P_PROJ" "$P_DIR/copy" t "$P_DIR/home/state/t.meta" "$P_DIR/home/state" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "the own copy was refused by the spawn-side custody consult: $out"
  pass "no-manifest route: a clean copy another task's record names is refused by name before provisioning; the own copy is admitted"
}

# D3: a tracked out-of-scope file marked assume-unchanged and then deleted is the task's own drift that status cannot show;
# a skip-worktree path that is absent (sparse checkout) is not a difference.
test_a_hidden_deletion_is_task_drift_and_a_sparse_absence_is_not() {
  local out
  make_world drift-hidden-delete
  git -C "$W_SLOT" update-ref refs/remotes/origin/main "$W_BASE"
  git -C "$W_SLOT" update-index --assume-unchanged docs/y.txt
  rm "$W_SLOT/docs/y.txt"
  [ -z "$(git -C "$W_SLOT" status --porcelain)" ] || fail 'the fixture is not hidden from status'
  out=$(drift)
  assert_contains "$out" 'drift: proven docs/y.txt' 'the hidden deletion was omitted from the drift report'
  # control: the same absence under skip-worktree is what a sparse checkout leaves on purpose
  make_world drift-sparse-absent
  git -C "$W_SLOT" update-ref refs/remotes/origin/main "$W_BASE"
  git -C "$W_SLOT" update-index --skip-worktree docs/y.txt
  rm "$W_SLOT/docs/y.txt"
  out=$(drift)
  case "$out" in *docs/y.txt*) fail "a sparse-checkout absence was listed as the task's drift: $out" ;; esac
  pass "drift: a deleted assume-unchanged tracked path is listed; an absent skip-worktree path is not"
}

# D3 R3 (Main 3659): a path that reaches HEAD only through a merged side branch, such as another task's branch, is listed
# uncertain, never proven; the task's own commit stays proven.
test_a_path_that_arrives_only_through_a_merged_peer_branch_is_uncertain_not_proven() {
  local out
  make_world drift-peer
  git -C "$W_SLOT" checkout -q -b peer "$W_BASE"
  printf 'peer\n' >"$W_SLOT/docs/peer.txt"
  git -C "$W_SLOT" add docs/peer.txt
  git -C "$W_SLOT" "${GITID[@]}" commit -qm 'peer task work'
  git -C "$W_SLOT" checkout -q fm/t
  printf 'own\n' >"$W_SLOT/docs/own.txt"
  git -C "$W_SLOT" add docs/own.txt
  git -C "$W_SLOT" "${GITID[@]}" commit -qm 'own out-of-scope work'
  git -C "$W_SLOT" "${GITID[@]}" merge -q --no-ff -m 'merge the peer branch' peer
  out=$(drift)
  assert_contains "$out" 'drift: proven docs/own.txt' "the task's own commit lost its proven label"
  assert_contains "$out" 'drift: uncertain docs/peer.txt' 'the merged peer path was not listed uncertain'
  case "$out" in *'proven docs/peer.txt'*) fail "a merged peer branch's path was labelled proven as the task's own: $out" ;; esac
  pass "drift: a path that arrives only through a merged peer branch is uncertain; the task's own commit stays proven"
}

# D3 (Main 3659): the launch artifacts Firstmate itself wrote, named by state/<id>.wiring-sha, are not the task's drift; a
# path the task really changed still is.
test_firstmate_written_wiring_is_not_reported_as_drift() {
  local out exclude
  make_world drift-wiring
  mkdir -p "$W_SLOT/.claude"
  printf '{}\n' >"$W_SLOT/.claude/settings.local.json"
  exclude=$(git -C "$W_SLOT" rev-parse --path-format=absolute --git-path info/exclude)
  mkdir -p "$(dirname "$exclude")"
  printf '.claude/\n' >>"$exclude"
  printf 'real\n' >"$W_SLOT/docs/real.txt"
  out=$(drift)
  assert_contains "$out" '.claude' 'the fixture is vacuous: the ignored wiring is not reported without its record'
  printf 'abc:100000:600 .claude/settings.local.json merged\n' >"$W_STATE/t.wiring-sha"
  out=$(STATE=$W_STATE drift)
  case "$out" in *.claude*) fail "recorded Firstmate wiring was reported as the task's drift: $out" ;; esac
  assert_contains "$out" 'drift: proven docs/real.txt' "the task's real untracked change disappeared from the report"
  pass "drift: wiring recorded in state/<id>.wiring-sha is not listed; the task's own change still is"
}

# An adopted relaunch keeps a worker-edited launch artifact as <recorded path>.fm-kept.<time>.<n> beside the fresh wiring;
# that kept copy is Firstmate's, so it is not the task's drift either.
test_a_kept_copy_of_recorded_wiring_is_not_reported_as_drift() {
  local out exclude
  make_world drift-kept
  mkdir -p "$W_SLOT/.claude"
  printf '{}\n' >"$W_SLOT/.claude/settings.local.json"
  printf '{"edited":1}\n' >"$W_SLOT/.claude/settings.local.json.fm-kept.1795.0"
  exclude=$(git -C "$W_SLOT" rev-parse --path-format=absolute --git-path info/exclude)
  mkdir -p "$(dirname "$exclude")"
  printf '.claude/settings.local.json\n.claude/settings.local.json.fm-kept.*\n' >>"$exclude"
  printf 'abc:100000:600 .claude/settings.local.json merged\n' >"$W_STATE/t.wiring-sha"
  out=$(STATE=$W_STATE drift)
  assert_contains "$out" 'no out-of-scope path changed' "Firstmate's kept copy of recorded wiring was reported as drift: $out"
  case "$out" in *fm-kept*) fail "the kept copy was listed as the task's drift: $out" ;; esac
  printf '{}\n' >"$W_SLOT/.claude/other.json"
  printf '.claude/other.json\n' >>"$exclude"
  out=$(STATE=$W_STATE drift)
  assert_contains "$out" 'drift: uncertain,ignored .claude/other.json' 'an unrecorded ignored file beside the kept copy disappeared from the report'
  pass "drift: a .fm-kept.<time>.<n> copy of recorded wiring is not listed; an unrecorded ignored file still is"
}

# B1 (exact-head read of 6acb4545): a governed task's own valid manifest is adopted. The record check must not overwrite
# the manifest verdict, so the repository root the adoption judged is the manifest's own repo root, not the word ok.
test_a_governed_tasks_own_manifest_is_adopted_with_the_manifest_repo_root() {
  local out rc want
  make_world adopt-own
  want=$(python3 -c 'import json,os,sys; print(os.path.realpath(json.load(open(sys.argv[1]))["repo_root"]))' "$W_MANIFEST")
  FM_SLOT_ADOPT_ROOT=
  fm_slot_adopt_check "$W_PROJ" "$W_SLOT" t fm/t "$W_META" "$W_STATE" >"$W_DIR/adopt.out" 2>&1; rc=$?
  out=$(cat "$W_DIR/adopt.out")
  [ "$rc" -eq 0 ] || fail "a governed task's own valid manifest was refused: $out"
  [ "${FM_SLOT_ADOPTED:-0}" = 1 ] || fail 'the own manifest was not marked adopted'
  [ "$FM_SLOT_ADOPT_ROOT" = "$want" ] || fail "the judged repository root is '$FM_SLOT_ADOPT_ROOT', not the manifest's '$want'"
  pass "adoption: a governed task's own valid manifest is adopted and the judged root is the manifest's repo root"
}

# B2 (exact-head read of 6acb4545): the record check fails closed. A pointer whose record store is not one of the stores this
# relaunch computes cannot be checked against the other record, so it is refused by name; the same pointer under the
# matching store configuration is adopted.
test_a_pointer_in_an_unknown_record_store_is_refused_and_a_known_one_adopted() {
  local out rc digest
  make_world store-unknown
  mkdir -p "$W_DIR/hookA/worktree-lifecycle" "$W_DIR/durableA" "$W_DIR/hookB" "$W_DIR/durableB"
  digest=$(python3 -c 'import hashlib,os,sys; print(hashlib.sha256(os.path.realpath(sys.argv[1]).encode()).hexdigest()[:16])' "$W_SLOT")
  cp "$W_MANIFEST" "$W_DIR/hookA/worktree-lifecycle/$digest.json"
  sed -i.bak "s|^slot_manifest=.*|slot_manifest=$W_DIR/hookA/worktree-lifecycle/$digest.json|" "$W_META" && rm -f "$W_META.bak"
  # the relaunch runs under another store configuration than the one the legacy pointer was written under
  out=$(WORKTREE_LIFECYCLE_STORE_DIR="$W_DIR/durableB" CODEX_HOOK_STATE_DIR="$W_DIR/hookB" adopt); rc=$?
  [ "$rc" -ne 0 ] || fail "a pointer in a record store this relaunch does not compute was adopted: $out"
  assert_contains "$out" manifest_store_unknown 'the unknown record store was not refused by name'
  # the same pointer under the matching configuration is adopted
  out=$(WORKTREE_LIFECYCLE_STORE_DIR="$W_DIR/durableA" CODEX_HOOK_STATE_DIR="$W_DIR/hookA" adopt); rc=$?
  [ "$rc" -eq 0 ] || fail "the same pointer under the matching store configuration was refused: $out"
  pass "adoption: a pointer in a record store the relaunch does not compute is refused by name; the same pointer under the matching stores is adopted"
}

# fm_slot_rerecord_verdict is the read-only replay of rerecord-slot's three content verdicts against a renewed manifest:
# a forward-merged branch whose renewal adds the directory of a new file is admitted with its labels, and a renewal that
# adds an untouched tracked file, or keeps a base that is no longer the merge-base, is refused by name. Nothing is written.
test_the_rerecord_replay_verdict_judges_a_renewed_manifest() {
  local m1 out rc
  make_world rerecord-replay
  mkdir -p "$W_PROJ/lib"
  printf 'a\n' >"$W_PROJ/lib/a.txt"
  printf 'doc2\n' >"$W_PROJ/docs/y.txt"
  git -C "$W_PROJ" add -A
  git -C "$W_PROJ" "${GITID[@]}" commit -qm 'main M1'
  git -C "$W_PROJ" push --quiet origin main
  git -C "$W_PROJ" fetch --quiet origin
  m1=$(git -C "$W_PROJ" rev-parse HEAD)
  printf 'owned2\n' >"$W_SLOT/src/a.txt"
  git -C "$W_SLOT" "${GITID[@]}" commit -qam 'own change'
  git -C "$W_SLOT" "${GITID[@]}" merge -q --no-edit origin/main
  mkdir -p "$W_SLOT/lib"
  printf 'new\n' >"$W_SLOT/lib/new.txt"
  git -C "$W_SLOT" add -A
  git -C "$W_SLOT" "${GITID[@]}" commit -qm 'new lib file'
  renew() { # <base> <owned-path>...
    python3 - "$W_MANIFEST" "$1" "${@:2}" <<'PY2'
import json, sys
path, base = sys.argv[1:3]
record = json.load(open(path))
record.update(base_sha=base, base_ref="origin/main", owned_paths=sys.argv[3:])
json.dump(record, open(path, "w"))
PY2
  }
  renew "$m1" src lib
  out=$(fm_slot_rerecord_verdict "$W_MANIFEST" "$W_SLOT" "$W_PROJ" t fm/t "$W_BASE" src)
  [ "$(printf '%s\n' "$out" | head -n 1)" = ok ] || fail "the forward-merged renewal was refused: $out"
  assert_contains "$out" 'added_scope=lib rule=c' 'the new directory was not admitted by rule (c)'
  assert_contains "$out" 'scope_split=prior:1 changed:0 ancestor:1' 'the scope split is wrong'
  renew "$m1" src lib docs
  out=$(fm_slot_rerecord_verdict "$W_MANIFEST" "$W_SLOT" "$W_PROJ" t fm/t "$W_BASE" src)
  assert_contains "$out" 'scope_entry_not_own_work' 'an untouched tracked directory was admitted'
  renew "$W_BASE" src lib
  out=$(fm_slot_rerecord_verdict "$W_MANIFEST" "$W_SLOT" "$W_PROJ" t fm/t "$W_BASE" src)
  assert_contains "$out" 'base_not_merge_base' 'a base that is no longer the merge-base was admitted'
  # A copy whose own line or uncommitted set cannot be read is refused by name, never reported ok with every added entry
  # labelled side-branch. The copy is made unreadable to git only for the one read under test.
  renew "$m1" src lib
  out=$(fm_slot_own_line_paths() { return 1; }; fm_slot_rerecord_verdict "$W_MANIFEST" "$W_SLOT" "$W_PROJ" t fm/t "$W_BASE" src); rc=$?
  [ "$rc" -ne 0 ] || fail "an unreadable own line still exited 0: $out"
  [ "$out" = "scope_entry_not_own_work"$'\t'"the task's own first-parent line could not be read from the copy, so no entry can be attributed" ] \
    || fail "an unreadable own line was not refused by name: $out"
  out=$(fm_slot_rerecord_uncommitted_paths() { return 1; }; fm_slot_rerecord_verdict "$W_MANIFEST" "$W_SLOT" "$W_PROJ" t fm/t "$W_BASE" src); rc=$?
  [ "$rc" -ne 0 ] || fail "an unreadable uncommitted set still exited 0: $out"
  [ "${out%%$'\t'*}" = scope_release_strands_work ] || fail "an unreadable uncommitted set was not refused by name: $out"
  [ -z "$(git -C "$W_SLOT" status --porcelain)" ] || fail 'the replay changed the copy'
  pass "rerecord replay: a forward-merged renewal is admitted with its labels; an untouched entry, a stale base, and an unreadable own line or uncommitted set are refused by name; the copy is unchanged"
}

CASES=(
test_same_task_claim_from_another_home_is_not_this_tasks_own
test_an_unreadable_foreign_record_is_an_error_not_no_conflict
test_a_governed_tasks_own_manifest_is_adopted_with_the_manifest_repo_root
test_a_pointer_in_an_unknown_record_store_is_refused_and_a_known_one_adopted
test_a_shadowed_or_disagreeing_lifecycle_record_is_refused_by_name
test_a_hidden_symlink_retarget_is_task_drift
test_a_hidden_deletion_is_task_drift_and_a_sparse_absence_is_not
test_a_path_that_arrives_only_through_a_merged_peer_branch_is_uncertain_not_proven
test_firstmate_written_wiring_is_not_reported_as_drift
test_a_kept_copy_of_recorded_wiring_is_not_reported_as_drift
test_a_change_the_default_branch_absorbed_and_reverted_is_still_task_drift
test_a_forged_cached_module_never_runs_and_a_substitution_is_detected
test_old_copy_preflight_asks_the_provisioner_that_would_really_run
test_a_second_adoption_refusal_says_the_wiring_and_record_were_written
test_a_refused_provision_leaves_no_export_directory
test_a_refused_first_provisioning_recovery_never_takes_the_primary_provisioner
test_a_pinned_provisioner_without_the_check_option_still_has_its_collision_named
test_the_no_manifest_route_consults_copy_custody
test_the_rerecord_replay_verdict_judges_a_renewed_manifest
)

fm_test_run_cases "${CASES[@]}" -- "$@"
echo "# all fm-slot-adopt tests passed"
