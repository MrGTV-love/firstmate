#!/usr/bin/env bash
# fm-control.sh relaunch of a governed task that already holds its own slot manifest.
#
# A relaunch is not a new scope declaration (Main 115, rule S): it adopts the task's own
# recorded manifest, never runs the project's provisioner, never edits the recorded scope,
# and is not blocked by the task's own out-of-scope commits or edits.  The fixture
# provisioner here is create-only like the real one (it refuses an existing manifest with
# manifest_exists) and records every execution in a sentinel, so a relaunch that reaches it
# is caught, and a stub that always exits 0 cannot make these cases pass.
# Shared fixtures: tests/fm-control-relaunch-helpers.sh.

# shellcheck source=tests/fm-control-relaunch-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-control-relaunch-helpers.sh"

# write_fixture_provisioner <repo>: a create-only provisioner that counts its runs.
write_fixture_provisioner() {
  mkdir -p "$1/scripts/git-stability"
  cat > "$1/scripts/git-stability/provision_existing_slot.py" <<'PY'
import argparse
import json
import os
import sys
from pathlib import Path

with open(os.environ["FM_TEST_PROVISION_CALLED"], "a", encoding="utf-8") as sentinel:
    sentinel.write(json.dumps(sys.argv[1:]) + "\n")
p = argparse.ArgumentParser()
for flag in ("repo-root", "worktree-path", "owner-id", "branch", "base-sha"):
    p.add_argument("--" + flag, required=True)
p.add_argument("--owned-path", action="append", required=True)
p.add_argument("--base-source")
a = p.parse_args()
manifest = Path(os.environ["FM_TEST_SLOT_RECORD"])
if manifest.exists():
    print(json.dumps({"state": "BLOCKED", "reason": "manifest_exists", "blocked_reasons": ["manifest_exists"],
                      "manifest_path": str(manifest)}))
    raise SystemExit(2)
record = dict(worktree_path=os.path.realpath(a.worktree_path), owner_id=a.owner_id, branch=a.branch,
              base_sha=a.base_sha, owned_paths=a.owned_path, lifecycle_state="worktree_active",
              repo_root=os.path.realpath(a.repo_root))
manifest.write_text(json.dumps(record, sort_keys=True), encoding="utf-8")
print(json.dumps(dict(state="PASS", manifest_path=str(manifest), **record)))
PY
}

# make_adopt_case <name> <id> [scope-path...]: a live governed ship task that was admitted by the
# fixture provisioner, so its record names a manifest, a base and a scope.  Sets ADOPT_DIR,
# ADOPT_META, ADOPT_MANIFEST and ADOPT_SENTINEL.
make_adopt_case() {
  local name=$1 id=$2 path base
  shift 2
  [ "$#" -gt 0 ] || set -- src
  ADOPT_DIR=$(new_case "$name" "$id")
  add_ship_task "$ADOPT_DIR" "$id" claude
  ADOPT_META="$ADOPT_DIR/home/state/$id.meta"
  ADOPT_MANIFEST="$ADOPT_DIR/manifest.json"
  ADOPT_SENTINEL="$ADOPT_DIR/provisioner.called"
  : > "$ADOPT_DIR/fake/run-slot-provision"
  mkdir -p "$ADOPT_DIR/proj/src"
  printf 'owned\n' > "$ADOPT_DIR/proj/src/owned.txt"
  printf 'docs\n' > "$ADOPT_DIR/proj/docs.txt"
  write_fixture_provisioner "$ADOPT_DIR/proj"
  git -C "$ADOPT_DIR/proj" add -A
  git -C "$ADOPT_DIR/proj" -c user.name=Tests -c user.email=tests@example.invalid commit -qm 'project gains owner'
  git -C "$ADOPT_DIR/proj" push -q origin HEAD:main 2>/dev/null || git -C "$ADOPT_DIR/proj" push -q origin HEAD
  git -C "$ADOPT_DIR/wt" merge -q --ff-only "$(git -C "$ADOPT_DIR/proj" rev-parse HEAD)"
  git -C "$ADOPT_DIR/wt" branch -m "task-$id" "fm/$id"
  git -C "$ADOPT_DIR/wt" update-ref refs/remotes/origin/main "$(git -C "$ADOPT_DIR/proj" rev-parse HEAD)"
  base=$(git -C "$ADOPT_DIR/wt" rev-parse HEAD)
  : > "$ADOPT_SENTINEL"
  args=()
  for path in "$@"; do args+=(--owned-path "$path"); done
  FM_TEST_PROVISION_CALLED=$ADOPT_SENTINEL FM_TEST_SLOT_RECORD=$ADOPT_MANIFEST \
    python3 "$ADOPT_DIR/wt/scripts/git-stability/provision_existing_slot.py" \
    --repo-root "$ADOPT_DIR/proj" --worktree-path "$ADOPT_DIR/wt" --owner-id "$id" --branch "fm/$id" \
    --base-sha "$base" "${args[@]}" >/dev/null || fail "fixture first provisioning failed"
  {
    echo "branch=fm/$id"
    echo "slot_manifest=$ADOPT_MANIFEST"
    echo "slot_base_sha=$base"
    for path in "$@"; do echo "slot_owned_path=$path"; done
  } >> "$ADOPT_META"
  : > "$ADOPT_SENTINEL"
}

run_adopt_control() { # <case-dir> <id> [args...]
  local dir=$1 id=$2
  shift 2
  FM_TEST_PROVISION_CALLED="$dir/provisioner.called" FM_TEST_SLOT_RECORD="$dir/manifest.json" \
    run_control "$dir" "$id" relaunch --note 'resume after the reboot' "$@"
}

test_adopt_relaunch_keeps_the_manifest_and_survives_a_second_relaunch() {
  local id=adopt1 out rc sum
  make_adopt_case adopt-basic "$id" src
  sum=$(shasum -a 256 "$ADOPT_MANIFEST")
  out=$(run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
  expect_code 0 "$rc" "an own-manifest relaunch must be admitted"$'\n'"$out"
  [ "$(shasum -a 256 "$ADOPT_MANIFEST")" = "$sum" ] || fail 'the relaunch changed the manifest'
  [ ! -s "$ADOPT_SENTINEL" ] || fail "the relaunch ran the provisioner: $(cat "$ADOPT_SENTINEL")"
  [ "$(meta_field "$ADOPT_DIR" "$id" slot_manifest)" = "$ADOPT_MANIFEST" ] || fail 'the record lost its manifest pointer'
  [ "$(meta_field "$ADOPT_DIR" "$id" slot_base_sha)" = "$(git -C "$ADOPT_DIR/wt" rev-parse HEAD)" ] || fail 'the record changed its base'
  out=$(run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
  expect_code 0 "$rc" "a second relaunch must be admitted too"$'\n'"$out"
  [ "$(shasum -a 256 "$ADOPT_MANIFEST")" = "$sum" ] || fail 'the second relaunch changed the manifest'
  [ ! -s "$ADOPT_SENTINEL" ] || fail 'the second relaunch ran the provisioner'
  pass "fm-control relaunch: a governed relaunch adopts its own manifest, twice, without the provisioner"
}

# set_manifest_field <case-dir> <field> <json-value>: rewrite one field of the fixture manifest.
set_manifest_field() {
  python3 - "$1/manifest.json" "$2" "$3" <<'PY'
import json, sys
path, field, value = sys.argv[1:4]
record = json.load(open(path, encoding="utf-8"))
record[field] = json.loads(value)
open(path, "w", encoding="utf-8").write(json.dumps(record, sort_keys=True))
PY
}

assert_adopt_refused_untouched() { # <case-dir> <id> <reason> <label> <out> <rc>
  local dir=$1 id=$2 reason=$3 label=$4 out=$5 rc=$6
  expect_code 1 "$rc" "$label must be refused: $out"
  assert_contains "$out" "slot adoption refused: $reason" "$label did not name its refusal"
  assert_contains "$out" 'the running agent was not stopped' "$label stopped the agent"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "$label stopped the running agent"
  [ ! -s "$dir/provisioner.called" ] || fail "$label ran the provisioner"
  [ ! -e "$dir/home/state/$id.control-relaunch" ] || fail "$label opened a relaunch transaction"
}

# D2: every mismatch between the manifest and the task's own record is refused by name before the stop,
# with the manifest, the record and the copy unchanged; the unmodified control is admitted.
test_adopt_refuses_a_manifest_that_is_not_this_tasks_own_by_name() {
  local id field value reason out rc dir before manifest_sum meta_sum
  for field in worktree_path:'"/elsewhere"':worktree_path_mismatch branch:'"fm/other"':branch_mismatch \
    base_sha:'"0000000000000000000000000000000000000000"':base_mismatch owned_paths:'["docs.txt"]':scope_mismatch \
    lifecycle_state:'"retired"':lifecycle_state_mismatch; do
    IFS=: read -r field value reason <<<"$field"
    id="adoptref-${field%%_*}"
    make_adopt_case "adopt-ref-$field" "$id" src
    dir=$ADOPT_DIR
    set_manifest_field "$dir" "$field" "$value"
    manifest_sum=$(shasum -a 256 "$ADOPT_MANIFEST")
    meta_sum=$(shasum -a 256 "$ADOPT_META")
    out=$(run_adopt_control "$dir" "$id"); rc=$?
    assert_adopt_refused_untouched "$dir" "$id" "$reason" "a manifest with a different $field" "$out" "$rc"
    [ "$manifest_sum" = "$(shasum -a 256 "$ADOPT_MANIFEST")" ] || fail "the $field refusal changed the manifest"
    [ "$meta_sum" = "$(shasum -a 256 "$ADOPT_META")" ] || fail "the $field refusal changed the task record"
  done
  id=adoptref-missing
  make_adopt_case adopt-ref-missing "$id" src
  rm -f "$ADOPT_MANIFEST"
  out=$(run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
  assert_adopt_refused_untouched "$ADOPT_DIR" "$id" manifest_missing 'a missing manifest' "$out" "$rc"
  id=adoptref-json
  make_adopt_case adopt-ref-json "$id" src
  printf '{"truncated' > "$ADOPT_MANIFEST"
  out=$(run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
  assert_adopt_refused_untouched "$ADOPT_DIR" "$id" manifest_unreadable 'a truncated manifest' "$out" "$rc"
  id=adoptref-repo
  make_adopt_case adopt-ref-repo "$id" src
  mkdir -p "$ADOPT_DIR/stranger"
  git -C "$ADOPT_DIR/stranger" init -q
  set_manifest_field "$ADOPT_DIR" repo_root "\"$ADOPT_DIR/stranger\""
  out=$(run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
  assert_adopt_refused_untouched "$ADOPT_DIR" "$id" repository_mismatch 'a manifest of another repository' "$out" "$rc"
  pass "fm-control relaunch: adoption refuses a manifest that is not the task's own, by name, changing nothing"
}

test_adopt_refuses_a_copy_another_task_records() {
  local id=adoptcust out rc other
  make_adopt_case adopt-custody "$id" src
  other="$ADOPT_DIR/home/state/stranger.meta"
  printf 'window=fmses:fm-stranger\nendpoint_task_id=stranger\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\n' \
    "$ADOPT_DIR/wt" "$ADOPT_DIR/proj" > "$other"
  out=$(run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
  assert_adopt_refused_untouched "$ADOPT_DIR" "$id" custody_other_record 'a copy another task records' "$out" "$rc"
  assert_contains "$out" 'stranger' 'the refusal did not name the other task'
  rm -f "$other"
  out=$(run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
  expect_code 0 "$rc" "the same copy with no foreign record is admitted"$'\n'"$out"
  pass "fm-control relaunch: adoption passes the existing custody owner's verdict through"
}

# D3: the task's own out-of-scope commits and edits never block the relaunch, never edit the recorded scope, and are
# printed by both entry points.
test_adopt_admits_own_out_of_scope_work_and_prints_it() {
  local id=adoptdrift out rc sum meta_sum
  make_adopt_case adopt-drift "$id" src
  printf 'fix\n' >> "$ADOPT_DIR/wt/docs.txt"
  git -C "$ADOPT_DIR/wt" -c user.name=T -c user.email=t@example.invalid commit -qam 'pipeline fix outside scope'
  printf 'own\n' > "$ADOPT_DIR/wt/src/inside.txt"
  printf 'scratch\n' > "$ADOPT_DIR/wt/notes outside.txt"
  sum=$(shasum -a 256 "$ADOPT_MANIFEST")
  meta_sum=$(grep -e '^slot_' "$ADOPT_META" | shasum -a 256)
  out=$(run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
  expect_code 0 "$rc" "own out-of-scope work must not block the relaunch"$'\n'"$out"
  assert_contains "$out" 'drift: proven docs.txt' 'the committed out-of-scope path was not printed by the control command'
  assert_contains "$out" 'drift: proven notes outside.txt' 'the untracked out-of-scope path was not printed'
  case "$out" in *'src/inside.txt'*) fail 'an in-scope path was printed as drift' ;; esac
  [ "$sum" = "$(shasum -a 256 "$ADOPT_MANIFEST")" ] || fail 'the manifest changed'
  [ "$meta_sum" = "$(grep -e '^slot_' "$ADOPT_META" | shasum -a 256)" ] || fail 'the recorded scope, base or manifest pointer changed'
  [ ! -s "$ADOPT_SENTINEL" ] || fail 'the provisioner ran'
  [ "$(cat "$ADOPT_DIR/wt/notes outside.txt")" = scratch ] || fail 'the untracked file was lost'
  grep -q 'does not state\|provisioner made' "$ADOPT_DIR/home/data/$id/launch-brief.md" && fail 'the brief claims the provisioner decided'
  assert_grep 'continue in place' "$ADOPT_DIR/home/data/$id/launch-brief.md" 'the launch brief does not direct the worker to continue in the copy'
  assert_no_grep 'Firstmate has provisioned this exact assigned copy' "$ADOPT_DIR/home/data/$id/launch-brief.md" 'the adopted brief uses the fresh-provision wording'
  pass "fm-control relaunch: own out-of-scope commits and edits are admitted, printed, and never added to the scope"
}

# D1 (b): the copy is dirty, or a rebase of the task branch is stopped: both entry points admit it and keep every byte.
test_adopt_admits_a_dirty_copy_and_a_stopped_rebase() {
  local id=adoptdirty out rc before
  make_adopt_case adopt-dirty "$id" src
  printf 'staged\n' > "$ADOPT_DIR/wt/src/staged.txt"
  git -C "$ADOPT_DIR/wt" add src/staged.txt
  printf 'edit\n' >> "$ADOPT_DIR/wt/src/owned.txt"
  printf 'x\n' > "$ADOPT_DIR/wt/src/run.sh"
  chmod +x "$ADOPT_DIR/wt/src/run.sh"
  before=$(cd "$ADOPT_DIR/wt" && { git ls-files -s; git diff --cached; cat src/owned.txt; stat -f '%Lp' src/run.sh; } | shasum -a 256)
  out=$(run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
  expect_code 0 "$rc" "a dirty own copy must be admitted"$'\n'"$out"
  [ "$before" = "$(cd "$ADOPT_DIR/wt" && { git ls-files -s; git diff --cached; cat src/owned.txt; stat -f '%Lp' src/run.sh; } | shasum -a 256)" ] \
    || fail 'the relaunch changed the index, the working files or the executable bit'
  [ ! -s "$ADOPT_SENTINEL" ] || fail 'the provisioner ran'
  # a rebase stopped at a conflict: HEAD is detached while it runs
  id=adoptrebase
  make_adopt_case adopt-rebase "$id" src
  git -C "$ADOPT_DIR/wt" -c user.name=T -c user.email=t@example.invalid commit -q --allow-empty -m base-two
  git -C "$ADOPT_DIR/wt" branch -q side HEAD~1
  git -C "$ADOPT_DIR/wt" checkout -q side
  printf 'side\n' > "$ADOPT_DIR/wt/src/owned.txt"
  git -C "$ADOPT_DIR/wt" -c user.name=T -c user.email=t@example.invalid commit -qam side-change
  git -C "$ADOPT_DIR/wt" checkout -q "fm/$id"
  printf 'task\n' > "$ADOPT_DIR/wt/src/owned.txt"
  git -C "$ADOPT_DIR/wt" -c user.name=T -c user.email=t@example.invalid commit -qam task-change
  git -C "$ADOPT_DIR/wt" rebase side >/dev/null 2>&1 || true
  [ -d "$(git -C "$ADOPT_DIR/wt" rev-parse --path-format=absolute --git-path rebase-merge)" ] || fail 'the fixture rebase did not stop'
  before=$(cd "$ADOPT_DIR/wt" && { find "$(git rev-parse --path-format=absolute --git-path rebase-merge)" -type f -exec shasum -a 256 {} +; cat src/owned.txt; } | shasum -a 256)
  out=$(run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
  expect_code 0 "$rc" "a stopped rebase of the own branch must be admitted"$'\n'"$out"
  [ "$before" = "$(cd "$ADOPT_DIR/wt" && { find "$(git rev-parse --path-format=absolute --git-path rebase-merge)" -type f -exec shasum -a 256 {} +; cat src/owned.txt; } | shasum -a 256)" ] \
    || fail 'the relaunch changed the rebase state or the conflicted file'
  git -C "$ADOPT_DIR/wt" rebase --abort || fail 'the rebase can no longer be aborted after the relaunch'
  pass "fm-control relaunch: a dirty copy and a stopped own rebase are admitted with every byte kept"
}

# D4: the replacement a relocation names is a new destination: it provisions, the old manifest is not adopted.
# A recovery=slot-provision-refused task never adopted a manifest either; both keep the provisioning route.
test_adopt_route_is_only_for_the_own_slot() {
  local id=adoptroute out rc
  make_adopt_case adopt-route "$id" src
  printf 'recovery=slot-provision-refused\n' >> "$ADOPT_META"
  out=$(run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
  expect_code 1 "$rc" "a refused-first-provisioning record keeps the provisioning route: $out"
  [ -s "$ADOPT_SENTINEL" ] || fail 'the provisioning route did not run the provisioner'
  assert_contains "$out" manifest_exists 'the fixture owner did not refuse the existing manifest on the provisioning route'
  pass "fm-control relaunch: only a relaunch into the task's own recorded slot takes the adopt route"
}

control_relaunch_test_cases=(
test_adopt_relaunch_keeps_the_manifest_and_survives_a_second_relaunch
test_adopt_refuses_a_manifest_that_is_not_this_tasks_own_by_name
test_adopt_refuses_a_copy_another_task_records
test_adopt_admits_own_out_of_scope_work_and_prints_it
test_adopt_admits_a_dirty_copy_and_a_stopped_rebase
test_adopt_route_is_only_for_the_own_slot
)

control_relaunch_run "$@"
