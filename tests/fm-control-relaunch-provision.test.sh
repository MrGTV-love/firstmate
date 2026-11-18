#!/usr/bin/env bash
# fm-control.sh relaunch of a governed task that has no recorded slot manifest (the provisioning route).
#
# Two behaviors: a copy that predates the provisioner is provisioned by the primary clone's current main
# (and the next relaunch then adopts the recorded manifest instead of provisioning again), and every provisioning
# refusal the recorded facts foresee is named before the running agent is stopped, with the record unchanged.
# The fixture provisioner is create-only and counts its runs (tests/fm-control-relaunch-slot-helpers.sh).
# Shared fixtures: tests/fm-control-relaunch-helpers.sh.

# shellcheck source=tests/fm-control-relaunch-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-control-relaunch-helpers.sh"
# shellcheck source=tests/fm-control-relaunch-slot-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-control-relaunch-slot-helpers.sh"

assert_refused_before_stop() { # <case-dir> <id> <reason> <label> <out> <rc> <meta-before>
  local dir=$1 id=$2 reason=$3 label=$4 out=$5 rc=$6 before=$7
  expect_code 1 "$rc" "$label must be refused: $out"
  assert_contains "$out" "$reason" "$label did not name its refusal"
  assert_contains "$out" 'the running agent was not stopped' "$label stopped the agent"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "$label stopped the running agent"
  [ "$before" = "$(cat "$dir/home/state/$id.meta")" ] || fail "$label changed the task record"
  [ ! -e "$dir/home/state/$id.control-relaunch" ] || fail "$label opened a relaunch transaction"
  [ ! -s "$dir/provisioner.called" ] || fail "$label ran the provisioner"
}

# D7: the copy predates the provisioner, the project's primary clone holds it. The relaunch needs no --owned-path.
test_old_copy_is_provisioned_by_the_primary_clone_then_adopted() {
  local id=nomanold out rc sum
  make_noman_case noman-old "$id" 0 README.md
  out=$(run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
  expect_code 0 "$rc" "an old copy must be provisioned by the primary clone's provisioner"$'\n'"$out"
  [ "$(wc -l < "$ADOPT_SENTINEL" | tr -d ' ')" = 1 ] || fail "the provisioner did not run exactly once: $(cat "$ADOPT_SENTINEL")"
  grep -F -- "--worktree-path" "$ADOPT_SENTINEL" | grep -F "$ADOPT_DIR/wt" >/dev/null || fail 'the provisioner was not pointed at the old copy'
  [ "$(meta_field "$ADOPT_DIR" "$id" slot_manifest)" = "$ADOPT_MANIFEST" ] || fail 'the record did not gain the manifest'
  python3 - "$ADOPT_MANIFEST" "$ADOPT_DIR/wt" <<'PY' || fail 'the manifest does not record the task scope exactly'
import json, os, sys
m = json.load(open(sys.argv[1]))
assert m["owned_paths"] == ["README.md"], m
assert m["worktree_path"] == os.path.realpath(sys.argv[2]), m
PY
  sum=$(shasum -a 256 "$ADOPT_MANIFEST")
  out=$(run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
  expect_code 0 "$rc" "the next relaunch must adopt the recorded manifest"$'\n'"$out"
  [ "$(wc -l < "$ADOPT_SENTINEL" | tr -d ' ')" = 1 ] || fail 'the second relaunch ran the provisioner again'
  [ "$sum" = "$(shasum -a 256 "$ADOPT_MANIFEST")" ] || fail 'the second relaunch changed the manifest'
  pass "fm-control relaunch: an old copy is provisioned by the primary clone's provisioner once, then adopted"
}

# The provisioner the primary clone would run must hold the default branch tip's bytes.
test_primary_provisioner_must_match_the_default_tip() {
  local id=nomandrift out rc before
  make_noman_case noman-drift "$id" 0 README.md
  printf '# locally modified\n' >> "$ADOPT_DIR/proj/scripts/git-stability/provision_existing_slot.py"
  before=$(cat "$ADOPT_META")
  out=$(run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
  expect_code 1 "$rc" "a modified primary provisioner must be refused: $out"
  assert_contains "$out" "is not the primary clone's current main" 'the refusal did not name the provisioner source'
  [ ! -s "$ADOPT_SENTINEL" ] || fail 'the modified provisioner ran'
  [ ! -e "$ADOPT_MANIFEST" ] || fail 'a manifest was created from a modified provisioner'
  pass "fm-control relaunch: a primary provisioner that differs from the default tip is refused by name"
}

# D8: every foreseeable provisioning refusal is named before the agent is stopped, and the record is unchanged.
test_foreseen_refusals_come_before_the_stop() {
  local id out rc before
  id=foresee-scope
  make_noman_case foresee-scope "$id" 1 missing/dir
  before=$(cat "$ADOPT_META")
  out=$(run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
  assert_refused_before_stop "$ADOPT_DIR" "$id" scope_not_tracked 'a scope path absent at the base' "$out" "$rc" "$before"

  id=foresee-mismatch
  make_noman_case foresee-mismatch "$id" 1 src
  printf 'own\n' >> "$ADOPT_DIR/wt/docs.txt"
  git -C "$ADOPT_DIR/wt" -c user.name=T -c user.email=t@example.invalid commit -qam 'own change outside the scope'
  before=$(cat "$ADOPT_META")
  out=$(run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
  assert_refused_before_stop "$ADOPT_DIR" "$id" scope_mismatch 'an own commit outside the recorded scope on the provisioning route' "$out" "$rc" "$before"

  id=foresee-exists
  make_noman_case foresee-exists "$id" 1 src
  printf '{}' > "$ADOPT_MANIFEST"
  before=$(cat "$ADOPT_META")
  out=$(run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
  assert_refused_before_stop "$ADOPT_DIR" "$id" manifest_exists 'a manifest already at the path the record does not adopt' "$out" "$rc" "$before"

  # Main 1795: an old copy with an uncommitted own edit is refused dirty_worktree by name, and every own path is printed.
  id=foresee-dirty
  make_noman_case foresee-dirty "$id" 1 src
  printf 'in progress\n' > "$ADOPT_DIR/wt/notes outside.txt"
  before=$(cat "$ADOPT_META")
  out=$(run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
  assert_refused_before_stop "$ADOPT_DIR" "$id" dirty_worktree 'a dirty copy on the provisioning route' "$out" "$rc" "$before"
  assert_contains "$out" 'drift: proven notes outside.txt' 'the dirty refusal did not print the drift report'
  [ "$(cat "$ADOPT_DIR/wt/notes outside.txt")" = 'in progress' ] || fail 'the dirty refusal lost the own edit'

  # the control: the same shape without a foreseeable refusal is admitted
  id=foresee-ok
  make_noman_case foresee-ok "$id" 1 src
  out=$(run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
  expect_code 0 "$rc" "a relaunch with nothing foreseeable must be admitted"$'\n'"$out"
  pass "fm-control relaunch: foreseeable provisioning refusals are named before the agent is stopped"
}

control_relaunch_test_cases=(
test_old_copy_is_provisioned_by_the_primary_clone_then_adopted
test_primary_provisioner_must_match_the_default_tip
test_foreseen_refusals_come_before_the_stop
)

control_relaunch_run "$@"
