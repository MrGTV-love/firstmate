#!/usr/bin/env bash
# Shared fixtures for the governed-relaunch suites (tests/fm-control-relaunch-adopt.test.sh and
# tests/fm-control-relaunch-provision.test.sh): a create-only fixture provisioner that counts its runs, and a live
# governed ship task admitted by it. Sourced after tests/fm-control-relaunch-helpers.sh.

# write_fixture_provisioner <repo>: a create-only provisioner that counts its runs.
write_fixture_provisioner() {
  mkdir -p "$1/scripts/git-stability"
  cat > "$1/scripts/git-stability/provision_existing_slot.py" <<'PY'
import argparse
import json
import os
import sys
from pathlib import Path

p = argparse.ArgumentParser()
for flag in ("repo-root", "worktree-path", "owner-id", "branch", "base-sha"):
    p.add_argument("--" + flag, required=True)
p.add_argument("--owned-path", action="append", required=True)
p.add_argument("--base-source")
p.add_argument("--check-manifest-only", action="store_true")
a = p.parse_args()
manifest = Path(os.environ["FM_TEST_SLOT_RECORD"])
if a.check_manifest_only:
    # read-only like the real provisioner's pool preselection check: never writes, never counts as a run
    refused = manifest.exists()
    print(json.dumps({"state": "BLOCKED", "reason": "manifest_exists", "manifest_path": str(manifest)} if refused else {"state": "PASS"}))
    raise SystemExit(2 if refused else 0)
with open(os.environ["FM_TEST_PROVISION_CALLED"], "a", encoding="utf-8") as sentinel:
    sentinel.write(json.dumps(sys.argv[1:]) + "\n")
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
  mkdir -p "$ADOPT_DIR/manifests"
  ADOPT_MANIFEST="$ADOPT_DIR/manifests/manifest.json"
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
  FM_TEST_PROVISION_CALLED="$dir/provisioner.called" FM_TEST_SLOT_RECORD="$dir/manifests/manifest.json" \
    run_control "$dir" "$id" relaunch --note 'resume after the reboot' "$@"
}


# make_noman_case <name> <id> <copy-has-script 0|1> <scope-path>...: a live governed ship task whose record names a
# scope but no manifest, with the project holding the provisioner on its main and the copy either holding it too
# (1) or predating it (0). Sets ADOPT_DIR, ADOPT_META, ADOPT_MANIFEST and ADOPT_SENTINEL.
make_noman_case() {
  local name=$1 id=$2 has_script=$3 path
  shift 3
  ADOPT_DIR=$(new_case "$name" "$id")
  add_ship_task "$ADOPT_DIR" "$id" claude
  ADOPT_META="$ADOPT_DIR/home/state/$id.meta"
  mkdir -p "$ADOPT_DIR/manifests"
  ADOPT_MANIFEST="$ADOPT_DIR/manifests/manifest.json"
  ADOPT_SENTINEL="$ADOPT_DIR/provisioner.called"
  : > "$ADOPT_DIR/fake/run-slot-provision"
  : > "$ADOPT_SENTINEL"
  mkdir -p "$ADOPT_DIR/proj/src"
  printf 'owned\n' > "$ADOPT_DIR/proj/src/owned.txt"
  printf 'docs\n' > "$ADOPT_DIR/proj/docs.txt"
  write_fixture_provisioner "$ADOPT_DIR/proj"
  git -C "$ADOPT_DIR/proj" add -A
  git -C "$ADOPT_DIR/proj" -c user.name=Tests -c user.email=tests@example.invalid commit -qm 'project gains owner'
  git -C "$ADOPT_DIR/proj" push -q origin HEAD:main 2>/dev/null || git -C "$ADOPT_DIR/proj" push -q origin HEAD
  [ "$has_script" != 1 ] || git -C "$ADOPT_DIR/wt" merge -q --ff-only "$(git -C "$ADOPT_DIR/proj" rev-parse HEAD)"
  git -C "$ADOPT_DIR/wt" branch -m "task-$id" "fm/$id"
  git -C "$ADOPT_DIR/wt" update-ref refs/remotes/origin/main "$(git -C "$ADOPT_DIR/proj" rev-parse HEAD)"
  {
    echo "branch=fm/$id"
    for path in "$@"; do echo "slot_owned_path=$path"; done
  } >> "$ADOPT_META"
}
