#!/usr/bin/env bash
# Existing-copy lifecycle integration for fm-spawn.sh and fm-promote.sh.
# Projects carrying scripts/git-stability/provision_existing_slot.py must attest
# the assigned isolated copy before admission. --owned-path is an explicit,
# repeatable task scope, never inferred from prose or expanded to the whole repo.
# The provisioner owns schema, origin/main merge-base validation, create-only
# refusal, same-owner adoption, and lease/liveness-gated previous-owner replacement.
# Firstmate never deletes/replaces its manifests or creates another worktree.
# Call from a clean checkout on the task branch, using the project's existing
# Python environment (no environment installation/sync). Preserve its full report.
# Requires fm-task-copy-lib.sh for isolation and preservation predicates.
# shellcheck disable=SC2034 # Output globals consumed by the entrypoints.
FM_SLOT_PROVISIONED=0
FM_SLOT_MANIFEST=
FM_SLOT_BASE_SHA=
FM_SLOT_PREVIOUS_BRANCH=
FM_SLOT_PREVIOUS_HEAD=

fm_slot_required() { # <project> <copy>
  [ -f "$1/scripts/git-stability/provision_existing_slot.py" ] ||
    [ -f "$2/scripts/git-stability/provision_existing_slot.py" ]
}

fm_slot_require_scope() { # <owned-path>...
  local path
  [ "$#" -gt 0 ] || { echo 'error: governed slot provisioning requires --owned-path <tracked-path> (repeatable)' >&2; return 1; }
  for path in "$@"; do
    case "$path" in
      ''|*$'\n'*|*$'\r'*) echo 'error: --owned-path must be a nonempty single-line tracked path' >&2; return 1 ;;
    esac
  done
}

fm_slot_check_copy() { # <project> <copy>
  local project=$1 copy=$2 common slot_common status marker git_path
  fm_task_copy_isolated "$copy" "$project" || {
    echo "error: slot provisioning refused: $FM_TASK_COPY_REASON" >&2
    return 1
  }
  common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir) || return 1
  slot_common=$(git -C "$copy" rev-parse --path-format=absolute --git-common-dir) || return 1
  [ "$common" = "$slot_common" ] || { echo 'error: slot provisioning refused: repository_mismatch' >&2; return 1; }
  status=$(git -C "$copy" status --porcelain=v1 --untracked-files=all --ignore-submodules=none) || return 1
  [ -z "$status" ] || { echo 'error: slot provisioning refused: dirty_worktree; preserve and reconcile the scratch state before retrying' >&2; return 1; }
  for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply sequencer; do
    git_path=$(git -C "$copy" rev-parse --path-format=absolute --git-path "$marker") || return 1
    [ ! -e "$git_path" ] || { echo 'error: slot provisioning refused: operation_in_progress' >&2; return 1; }
  done
}

fm_slot_prepare_base() { # <project> <copy> <task-id>
  local project=$1 copy=$2 id=$3 branch
  fm_slot_check_copy "$project" "$copy" || return 1
  branch=$(git -C "$copy" branch --show-current) || return 1
  FM_SLOT_PREVIOUS_BRANCH=$branch
  FM_SLOT_PREVIOUS_HEAD=$(git -C "$copy" rev-parse --verify HEAD) || return 1
  # The ordinary freshness owner resets HEAD. Detach first so it cannot move a
  # previous task's branch; preserve a detached tip through the existing owner.
  if [ -z "$branch" ]; then
    fm_task_copy_preserve "$project" "$id" "$copy" 1 || {
      echo "error: cannot preserve assigned slot before refreshing its base: $FM_TASK_COPY_REASON" >&2
      return 1
    }
  fi
  git -C "$copy" checkout --quiet --detach || return 1
}

fm_slot_restore_base() { # <copy>
  [ -n "$FM_SLOT_PREVIOUS_HEAD" ] || return 0
  if [ -n "$FM_SLOT_PREVIOUS_BRANCH" ]; then
    git -C "$1" checkout --quiet "$FM_SLOT_PREVIOUS_BRANCH" --
  else
    git -C "$1" checkout --quiet --detach "$FM_SLOT_PREVIOUS_HEAD"
  fi
}

fm_slot_provision() { # <project> <copy> <task-id> <branch> <report> <owned-path>...
  local project=$1 copy=$2 id=$3 branch=$4 report=$5 base old_branch old_head branch_head rc=0
  shift 5
  FM_SLOT_PROVISIONED=0
  FM_SLOT_MANIFEST=
  FM_SLOT_BASE_SHA=
  fm_slot_require_scope "$@" || return 1
  fm_slot_check_copy "$project" "$copy" || return 1
  [ -f "$copy/scripts/git-stability/provision_existing_slot.py" ] || {
    echo "error: slot provisioner is missing from assigned copy $copy" >&2
    return 1
  }
  git check-ref-format --branch "$branch" >/dev/null || return 1
  old_branch=$(git -C "$copy" branch --show-current) || return 1
  old_head=$(git -C "$copy" rev-parse --verify HEAD) || return 1
  base=$(git -C "$copy" merge-base origin/main HEAD) || {
    echo 'error: slot provisioning requires a resolvable merge-base with origin/main; no manifest was changed' >&2
    return 1
  }
  if [ "$old_branch" != "$branch" ]; then
    if branch_head=$(git -C "$copy" rev-parse --verify --quiet "refs/heads/$branch^{commit}"); then
      [ "$branch_head" = "$old_head" ] || {
        echo "error: existing task branch $branch is not at the assigned copy's HEAD; refusing to reset or overwrite it" >&2
        return 1
      }
      git -C "$copy" checkout --quiet "$branch" -- || return 1
    else
      git -C "$copy" checkout --quiet -b "$branch" -- || return 1
    fi
  fi
  local args=() path
  for path in "$@"; do args+=(--owned-path "$path"); done
  # Keep the bare interpreter form used by the governed launcher, and its
  # primary-project cwd. An absent dependency is an actual launch refusal.
  (
    cd "$project" || exit 1
    PATH="$project/.venv/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 python3 \
      "$copy/scripts/git-stability/provision_existing_slot.py" \
      --repo-root "$project" --worktree-path "$copy" --owner-id "$id" \
      --branch "$branch" --base-sha "$base" "${args[@]}"
  ) >"$report" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    python3 - "$report" "$copy" "$id" "$branch" "$base" "$@" <<'PY' || rc=$?
import json
import os
import sys
try:
    report = json.load(open(sys.argv[1], encoding="utf-8"))
    expected = dict(worktree_path=os.path.realpath(sys.argv[2]), owner_id=sys.argv[3],
                    branch=sys.argv[4], base_sha=sys.argv[5], owned_paths=sys.argv[6:])
    if report.get("state") != "PASS":
        raise ValueError("provisioner did not report PASS")
    manifest = json.load(open(report["manifest_path"], encoding="utf-8"))
    for record in (report, manifest):
        for key, value in expected.items():
            actual = record.get(key)
            if key == "owned_paths":
                actual, value = sorted(actual), sorted(value)
            if actual != value:
                raise ValueError("provisioner identity mismatch: " + key)
    if manifest.get("lifecycle_state") != "worktree_active":
        raise ValueError("manifest is not worktree_active")
except (OSError, ValueError, KeyError, TypeError) as exc:
    print("error: invalid slot provisioner attestation: " + str(exc), file=sys.stderr)
    sys.exit(1)
PY
  fi
  cat "$report" >&2
  if [ "$rc" -ne 0 ]; then
    if [ "$old_branch" != "$branch" ]; then
      if [ -n "$old_branch" ]; then
        git -C "$copy" checkout --quiet "$old_branch" -- || true
      else
        git -C "$copy" checkout --quiet --detach "$old_head" || true
      fi
    fi
    echo "error: slot provisioner refused task $id (exit $rc); no agent or ship transition admitted; report: $report" >&2
    return "$rc"
  fi
  FM_SLOT_MANIFEST=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifest_path"])' "$report") || return 1
  FM_SLOT_BASE_SHA=$base
  FM_SLOT_PROVISIONED=1
}

fm_slot_contract() { # <branch>
  cat <<EOF

# Current assigned-copy lifecycle contract
Firstmate has provisioned this exact assigned copy on branch \`$1\` before admission.
This section supersedes earlier branch-creation or clean-base reset instructions: verify isolation and the existing branch, then continue in place; do not create the branch again or reset it.
Do not create another worktree inside this copy, delete a lifecycle manifest, or force a replacement.
The governed provisioner owns repeat/adoption decisions; a refused renewal, branch change, or wider scope must return to firstmate with the exact refusal, never to a nested-worktree fallback.
EOF
}
