#!/usr/bin/env bash
# Existing-copy lifecycle integration for fm-spawn.sh and fm-promote.sh.
# Projects carrying scripts/git-stability/provision_existing_slot.py must attest
# the assigned isolated copy before admission. --owned-path is an explicit,
# repeatable task scope, never inferred from prose or expanded to the whole repo.
# The provisioner owns schema, default origin/main merge-base validation, explicit
# local-default qualification, same-owner adoption and lease/liveness-gated replacement.
# A selected local-default ref/SHA is passed explicitly by spawn; no local choice
# is rederived from origin/main, and legacy callers send no new project flag.
# Firstmate never deletes/replaces its manifests or creates another worktree.
# A declared successor passes the resolved predecessor copy to that provisioner
# as --supersedes through FM_SLOT_SUPERSEDES; the provisioner alone records it.
# fm_slot_provision re-checks the predecessor's recorded branch just before that call.
# fm_slot_resolve_successor needs fm-pr-lib.sh (fm_task_id_path_safe) and fm_meta_get.
# Call from a clean checkout on the task branch, using the project's existing
# Python environment (no environment installation/sync). Preserve its full report.
# Requires fm-task-copy-lib.sh for isolation and preservation predicates.
# shellcheck disable=SC2034 # Output globals consumed by the entrypoints.
FM_SLOT_PROVISIONED=0
FM_SLOT_MANIFEST=
FM_SLOT_BASE_SHA=
FM_SLOT_BASE_REF=
FM_SLOT_PREPARED_HEAD=
FM_SLOT_PREVIOUS_BRANCH=
FM_SLOT_PREVIOUS_HEAD=
# Input to fm_slot_provision, reset here so an inherited value never reaches it.
FM_SLOT_SUPERSEDES=
FM_SLOT_SUCCESSOR_WT=
FM_SLOT_SUCCESSOR_ID=
FM_SLOT_SUCCESSOR_META=
FM_SLOT_SUCCESSOR_BRANCH=

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

fm_slot_realdir() { # <dir>; the physical path, or failure for an empty or missing one
  [ -n "$1" ] && [ -d "$1" ] && (cd -P -- "$1" 2>/dev/null && pwd -P)
}

fm_slot_advertises_supersedes() { # <project>
  local script=$1/scripts/git-stability/provision_existing_slot.py help
  [ -f "$script" ] || return 1
  help=$(cd "$1" && PATH="$1/.venv/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 python3 "$script" --help 2>/dev/null) || return 1
  printf '%s\n' "$help" | grep -Eq -- '(^|[^[:alnum:]_-])--supersedes([^[:alnum:]_-]|$)'
}

# Resolve a declared predecessor to its live copy, or refuse with one error line
# before any resource exists. Sets FM_SLOT_SUCCESSOR_WT to the resolved path.
fm_slot_resolve_successor() { # <project> <state-dir> <task-id> <predecessor-id>
  local project=$1 state=$2 id=$3 pred=$4 meta kind wt branch head real top pcommon scommon
  FM_SLOT_SUCCESSOR_WT=
  FM_SLOT_SUCCESSOR_ID=
  FM_SLOT_SUCCESSOR_META=
  FM_SLOT_SUCCESSOR_BRANCH=
  fm_task_id_path_safe "$pred" || { echo 'error: --successor-of needs a safe predecessor task id' >&2; return 1; }
  [ "$pred" != "$id" ] || { echo "error: --successor-of $pred names the task itself" >&2; return 1; }
  meta=$state/$pred.meta
  { [ -f "$meta" ] && [ ! -L "$meta" ]; } || { echo "error: --successor-of $pred has no task record in $state" >&2; return 1; }
  kind=$(fm_meta_get "$meta" kind)
  wt=$(fm_meta_get "$meta" worktree)
  branch=$(fm_meta_get "$meta" branch)
  if [ "$kind" = secondmate ] || [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
    echo "error: --successor-of $pred is a secondmate or remote record with no local task copy" >&2
    return 1
  fi
  { [ -n "$wt" ] && [ -n "$branch" ]; } || { echo "error: --successor-of $pred records no worktree or branch" >&2; return 1; }
  git check-ref-format --branch "$branch" >/dev/null 2>&1 || { echo "error: --successor-of $pred records an invalid branch" >&2; return 1; }
  real=$(fm_slot_realdir "$wt") || { echo "error: --successor-of $pred copy $wt is gone; a successor record needs the live predecessor" >&2; return 1; }
  top=$(fm_slot_realdir "$(git -C "$real" rev-parse --show-toplevel 2>/dev/null)") || top=
  [ "$top" = "$real" ] || { echo "error: --successor-of $pred copy $wt is not a git worktree root" >&2; return 1; }
  pcommon=$(fm_slot_realdir "$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)") || pcommon=
  scommon=$(fm_slot_realdir "$(git -C "$real" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)") || scommon=
  [ "$real" != "$(fm_slot_realdir "$project")" ] || { echo "error: --successor-of $pred copy $wt is the project's primary checkout, not a task copy" >&2; return 1; }
  { [ -n "$pcommon" ] && [ "$pcommon" = "$scommon" ]; } || { echo "error: --successor-of $pred copy $wt belongs to a different repository than $project" >&2; return 1; }
  head=$(git -C "$real" symbolic-ref -q HEAD) || head=
  [ -n "$head" ] || { echo "error: --successor-of $pred copy $wt has a detached HEAD, not its recorded branch $branch" >&2; return 1; }
  [ "$head" = "refs/heads/$branch" ] || { echo "error: --successor-of $pred copy $wt is on ${head#refs/heads/}, not its recorded branch $branch" >&2; return 1; }
  fm_slot_advertises_supersedes "$project" || {
    echo "error: --successor-of needs project $(basename "$project") to advertise --supersedes on scripts/git-stability/provision_existing_slot.py; the successor record needs the Vernant verb" >&2
    return 1
  }
  FM_SLOT_SUCCESSOR_WT=$real
  FM_SLOT_SUCCESSOR_ID=$pred
  FM_SLOT_SUCCESSOR_META=$meta
  FM_SLOT_SUCCESSOR_BRANCH=$branch
}

# The predecessor must still be the task and branch the resolver verified. The
# project's helper corroborates only the copy's current branch, so this binds
# the proof to the branch recorded for the declared task: run it at the point
# the path is handed over, with nothing slow between it and the call.
fm_slot_successor_still_bound() {
  local real head
  { [ -n "$FM_SLOT_SUPERSEDES" ] && [ -n "$FM_SLOT_SUCCESSOR_META" ] && [ -n "$FM_SLOT_SUCCESSOR_BRANCH" ]; } || {
    echo 'error: --successor-of lost its resolved predecessor; refusing to hand an unverified path to the provisioner' >&2
    return 1
  }
  { [ -f "$FM_SLOT_SUCCESSOR_META" ] && [ ! -L "$FM_SLOT_SUCCESSOR_META" ] &&
    [ "$(fm_meta_get "$FM_SLOT_SUCCESSOR_META" branch)" = "$FM_SLOT_SUCCESSOR_BRANCH" ] &&
    [ "$(fm_slot_realdir "$(fm_meta_get "$FM_SLOT_SUCCESSOR_META" worktree)")" = "$FM_SLOT_SUPERSEDES" ]; } || {
    echo "error: --successor-of $FM_SLOT_SUCCESSOR_ID changed its task record after it was checked; refusing to hand it to the provisioner" >&2
    return 1
  }
  real=$(fm_slot_realdir "$FM_SLOT_SUPERSEDES") || real=
  head=$(git -C "${real:-/nonexistent}" symbolic-ref -q HEAD 2>/dev/null) || head=
  { [ "$real" = "$FM_SLOT_SUPERSEDES" ] && [ "$head" = "refs/heads/$FM_SLOT_SUCCESSOR_BRANCH" ]; } || {
    echo "error: --successor-of $FM_SLOT_SUCCESSOR_ID copy is no longer on its recorded branch $FM_SLOT_SUCCESSOR_BRANCH (now ${head#refs/heads/}); refusing to hand it to the provisioner" >&2
    return 1
  }
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

fm_slot_resume_prepared() { # <project> <copy> <task-id> <branch> <prepared-head>
  local project=$1 copy=$2 id=$3 branch=$4 expected=$5 actual
  case "$expected" in
    ''|*[!0-9a-f]*) echo 'error: refused slot has an invalid prepared commit identity' >&2; return 1 ;;
  esac
  { [ "${#expected}" -eq 40 ] || [ "${#expected}" -eq 64 ]; } || {
    echo 'error: refused slot has an invalid prepared commit identity' >&2
    return 1
  }
  git check-ref-format --branch "$branch" >/dev/null || return 1
  actual=$(git -C "$copy" rev-parse --verify --quiet "refs/heads/$branch^{commit}") || actual=
  [ "$actual" = "$expected" ] || {
    echo "error: prepared task branch $branch changed or is missing since provisioning refusal; preserving it" >&2
    return 1
  }
  fm_slot_prepare_base "$project" "$copy" "$id" || return 1
  git -C "$copy" checkout --quiet "$branch" -- || return 1
  if [ "$(git -C "$copy" rev-parse --verify HEAD)" != "$expected" ]; then
    fm_slot_restore_base "$copy" || true
    echo "error: prepared task branch $branch moved during recovery; no worker admitted" >&2
    return 1
  fi
}

fm_slot_run_local() { # <project> <report> <provisioner> <arg>...
  local project=$1 report=$2
  shift 2
  (
    cd "$project" || exit 1
    PATH="$project/.venv/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 python3 "$@"
  ) >"$report" 2>&1
}

fm_slot_provision() { # <runner> <project> <copy> <task-id> <branch> <report> <local-default-ref-or-empty> <selected-sha-or-empty> <owned-path>...
  local runner=$1 project=$2 copy=$3 id=$4 branch=$5 report=$6 local_ref=$7 selected=$8
  local base old_branch old_head branch_head rc=0
  shift 8
  FM_SLOT_PROVISIONED=0
  FM_SLOT_MANIFEST=
  FM_SLOT_BASE_SHA=
  FM_SLOT_BASE_REF=
  FM_SLOT_PREPARED_HEAD=
  FM_SLOT_CREATED=0
  FM_SLOT_CREATED_FROM=
  fm_slot_require_scope "$@" || return 1
  fm_slot_check_copy "$project" "$copy" || return 1
  [ -f "$copy/scripts/git-stability/provision_existing_slot.py" ] || {
    echo "error: slot provisioner is missing from assigned copy $copy" >&2
    return 1
  }
  git check-ref-format --branch "$branch" >/dev/null || return 1
  old_branch=$(git -C "$copy" branch --show-current) || return 1
  old_head=$(git -C "$copy" rev-parse --verify HEAD) || return 1
  if [ -n "$local_ref" ]; then
    case "$local_ref" in refs/heads/*) ;; *) echo 'error: invalid qualified local-default ref' >&2; return 1 ;; esac
    git check-ref-format "$local_ref" || return 1
    base=$(git -C "$copy" rev-parse --verify --quiet "$selected^{commit}") || return 1
    if [ -z "$selected" ] || [ "$base" != "$selected" ] ||
      ! git -C "$copy" merge-base --is-ancestor "$base" "$old_head"; then
      echo 'error: selected local-default baseline is not an immutable ancestor of the task; no manifest was changed' >&2
      return 1
    fi
    # Pass the selected identity, never an origin merge-base that predates it.
    # The actual project owner independently qualifies fresh defaults and existing
    # same-owner declarations, so an admitted baseline can survive default advance.
  else
    [ -z "$selected" ] || { echo 'error: a selected slot baseline requires its qualified local-default ref' >&2; return 1; }
    base=$(git -C "$copy" merge-base origin/main HEAD) || {
      echo 'error: slot provisioning requires a resolvable merge-base with origin/main; no manifest was changed' >&2
      return 1
    }
  fi
  if [ "$old_branch" != "$branch" ]; then
    if branch_head=$(git -C "$copy" rev-parse --verify --quiet "refs/heads/$branch^{commit}"); then
      [ "$branch_head" = "$old_head" ] || {
        echo "error: existing task branch $branch is not at the assigned copy's HEAD; refusing to reset or overwrite it" >&2
        return 1
      }
      git -C "$copy" checkout --quiet "$branch" -- || return 1
    else
      git -C "$copy" checkout --quiet -b "$branch" -- || return 1
      FM_SLOT_CREATED=1
      FM_SLOT_CREATED_FROM=$old_branch
    fi
  fi
  FM_SLOT_PREPARED_HEAD=$old_head
  local args=() path
  [ -z "$local_ref" ] || args+=(--base-source local-default)
  for path in "$@"; do args+=(--owned-path "$path"); done
  [ -z "$FM_SLOT_SUPERSEDES" ] || args+=(--supersedes "$FM_SLOT_SUPERSEDES")
  # Spawn executes in the acquired pane's ancestry, so its own cwd holder is
  # attributable to this invocation. The provisioner still rejects unrelated
  # live holders. Promotion's same-owner declaration uses the local runner.
  if [ -n "$FM_SLOT_SUPERSEDES" ] && ! fm_slot_successor_still_bound; then
    # Same refusal path as the provisioner's own: the checkout is restored below.
    printf '{"state": "REFUSED", "reason": "successor_predecessor_moved"}\n' > "$report"
    rc=2
  else
    "$runner" "$project" "$report" "$copy/scripts/git-stability/provision_existing_slot.py" \
      --repo-root "$project" --worktree-path "$copy" --owner-id "$id" \
      --branch "$branch" --base-sha "$base" "${args[@]}" || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    python3 - "$report" "$copy" "$id" "$branch" "$base" "$local_ref" "$@" <<'PY' || rc=$?
import json
import os
import sys
try:
    report = json.load(open(sys.argv[1], encoding="utf-8"))
    expected = dict(worktree_path=os.path.realpath(sys.argv[2]), owner_id=sys.argv[3],
                    branch=sys.argv[4], base_sha=sys.argv[5], owned_paths=sys.argv[7:])
    if sys.argv[6]:
        expected['base_ref'] = sys.argv[6]
        if report.get('base_source') != 'local-default':
            raise ValueError('provisioner did not attest local-default source')
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
  FM_SLOT_BASE_REF=$local_ref
  FM_SLOT_PROVISIONED=1
}

# A refused promotion has no prepared record, so the task branch its own
# provisioning call created would otherwise block every retry once the scout
# advances. Delete only that exact alias, only while the restored checkout
# still holds its commit and the project's report declares nothing.
fm_slot_drop_created_branch() { # <copy> <branch> <report>
  local copy=$1 branch=$2 report=$3 from=$FM_SLOT_CREATED_FROM head=$FM_SLOT_PREPARED_HEAD reason='' worktrees
  [ "$FM_SLOT_CREATED" = 1 ] || return 0
  if ! python3 -c 'import json, sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
sys.exit(0 if isinstance(report, dict) and report.get("state") != "PASS" and "manifest_path" not in report else 1)' "$report" 2>/dev/null; then
    reason='the project report may declare it'
  elif ! worktrees=$(git -C "$copy" worktree list --porcelain); then
    reason='its worktrees cannot be listed'
  elif [ -n "$from" ] && { [ "$(git -C "$copy" symbolic-ref -q HEAD)" != "refs/heads/$from" ] ||
    [ "$(git -C "$copy" rev-parse --verify --quiet "refs/heads/$from^{commit}")" != "$head" ]; }; then
    reason="the copy is not back on $from at $head"
  elif [ -z "$from" ] && { git -C "$copy" symbolic-ref -q HEAD >/dev/null ||
    [ "$(git -C "$copy" rev-parse --verify --quiet HEAD)" != "$head" ]; }; then
    reason="the copy is not back to a detached $head"
  elif git -C "$copy" symbolic-ref -q "refs/heads/$branch" >/dev/null; then
    reason="$branch is now a symbolic ref"
  elif printf '%s\n' "$worktrees" | grep -Fqx "branch refs/heads/$branch"; then
    reason="$branch is checked out in a worktree"
  elif ! git -C "$copy" update-ref --no-deref -d "refs/heads/$branch" "$head"; then
    reason="$branch moved from $head"
  fi
  [ -z "$reason" ] || {
    echo "warning: preserving task branch $branch created by this refused promotion: $reason" >&2
    return 1
  }
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
