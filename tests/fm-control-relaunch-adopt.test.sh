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
# shellcheck source=tests/fm-control-relaunch-slot-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-control-relaunch-slot-helpers.sh"

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

# D1: a launch artifact the worker edited is kept byte for byte beside the fresh wiring; an unchanged one is simply regenerated.
test_adopt_keeps_a_worker_edited_launch_artifact() {
  local id=adoptart out rc settings kept
  make_adopt_case adopt-artifact "$id" src
  settings="$ADOPT_DIR/wt/.claude/settings.local.json"
  out=$(run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
  expect_code 0 "$rc" "the first relaunch must be admitted"$'\n'"$out"
  [ -f "$settings" ] || fail 'the launch wrote no settings file to compare against'
  out=$(run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
  expect_code 0 "$rc" "a relaunch over an unchanged artifact must be admitted"$'\n'"$out"
  [ -z "$(ls "$ADOPT_DIR/wt/.claude" | grep 'fm-kept' || true)" ] || fail 'an unchanged generated artifact got a kept copy'
  printf '{"permissions":{"allow":["Bash(make test)"]}}\n' > "$settings"
  out=$(run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
  expect_code 0 "$rc" "a relaunch over an edited artifact must be admitted"$'\n'"$out"
  kept=$(ls "$ADOPT_DIR/wt/.claude" | grep 'settings.local.json.fm-kept' | head -n 1)
  [ -n "$kept" ] || fail 'the worker-edited settings file was not kept'
  [ "$(cat "$ADOPT_DIR/wt/.claude/$kept")" = '{"permissions":{"allow":["Bash(make test)"]}}' ] || fail 'the kept copy is not byte-identical to the edit'
  assert_contains "$out" "kept the worker's edited launch artifact .claude/settings.local.json byte for byte at .claude/$kept" 'the launch did not say where the edit was kept'
  assert_grep PreToolUse "$settings" 'the fresh wiring was not written beside the kept edit'
  git -C "$ADOPT_DIR/wt" status --porcelain --untracked-files=all | grep -q 'fm-kept' && fail 'the kept copy dirtied the copy'
  pass "fm-control relaunch: an edited launch artifact is kept byte for byte and an unchanged one is regenerated"
}

control_relaunch_test_cases=(
test_adopt_relaunch_keeps_the_manifest_and_survives_a_second_relaunch
test_adopt_refuses_a_manifest_that_is_not_this_tasks_own_by_name
test_adopt_refuses_a_copy_another_task_records
test_adopt_admits_own_out_of_scope_work_and_prints_it
test_adopt_admits_a_dirty_copy_and_a_stopped_rebase
test_adopt_route_is_only_for_the_own_slot
test_adopt_keeps_a_worker_edited_launch_artifact
)

control_relaunch_run "$@"
