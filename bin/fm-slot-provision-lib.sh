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
  # Spawn executes in the acquired pane's ancestry, so its own cwd holder is
  # attributable to this invocation. The provisioner still rejects unrelated
  # live holders. Promotion's same-owner declaration uses the local runner.
  "$runner" "$project" "$report" "$copy/scripts/git-stability/provision_existing_slot.py" \
    --repo-root "$project" --worktree-path "$copy" --owner-id "$id" \
    --branch "$branch" --base-sha "$base" "${args[@]}" || rc=$?
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

# --- Reset guard: no destroying reset without proof the slot holds no unique work ---
#
# fm_slot_guarded_reset is the ONLY place the spawn path hard-resets a pooled slot. A hard reset moves an attached branch's ref, orphans a
# detached HEAD's commits, overwrites tracked edits, and overwrites an ignored
# or untracked file at a path the reset target tracks. Before it runs, the
# guard proves these facts about the slot, each from one removable fact call in
# fm_slot_guard_observe, and refuses on the first fact it cannot prove:
#   head_not_contained (S1)   a detached HEAD is not an ancestor of origin's
#                             current default branch (the remote's ls-remote answer;
#                             with --base-branch, the recorded origin/HEAD, else
#                             ls-remote), by refs/remotes/origin/<that branch> and the
#                             tip the spawn fetched of it, never a --base-branch, or
#                             of the manifest's base_sha
#   owner_branch_not_contained (S2)  the attached branch, or the branch the slot's
#                             lifecycle manifest names, has an uncontained tip
#   tree_not_clean (S3)       any tracked, staged or untracked change
#   ignored_collision (S3b)   an ignored entry collides with a path the reset
#                             target tracks (same path, inside it, or an ancestor
#                             of it) and is neither classified scratch by
#                             fm_mp_classify_entry nor held by a verified archive
#   holder_* (S4)             a process outside the spawn's lineage and its own
#                             endpoint's pane has its cwd in the slot, a git
#                             worktree lock, a live foreign lease, recent contention
#   unknown_* (S5)            any read that fails (git, manifest, lsof, lease,
#                             lock, contention source) refuses with its own name
#   changed_since_first_read (S5b)  the facts are observed twice, the second pass
#                             right before the reset: the slow holder probes first,
#                             then HEAD, owner tips, anchor tips, the clean tree and
#                             the ignored entries, then the manifest bytes; any
#                             difference refuses.
# A refusal runs no reset and no checkout. On a refusal HEAD, local branches, the
# index, the files and every other ref stay byte-identical, with exactly two
# exceptions, neither of which changes local work, made by the spawn before its final
# check: (1) the spawn's fetch moves refs/remotes/origin/<b>, where <b> is the branch it
# fetched to start from (origin's default branch, or the --base-branch), only forward
# by compare-and-set, and repoints refs/remotes/origin/HEAD at origin's default branch;
# (2) the governed path adds refs/fm/anchor/<task>-<sha> to preserve a detached HEAD.
# The window between the final manifest read and the reset is a stated residual: a
# writer that takes no lock can still change the slot in it.
# The manifest, lease store and contention log are the governed project's
# (fm_slot_required): their layout is the one scripts/git_management/
# worktree_lifecycle.py and scripts/hooks/_worktree_lease_core.py document. They are
# read here as plain files, never through the project's code, so the guard never
# writes into the project. A project without the provisioner has none of them.
# Context the caller sets before the call:
#   FM_SLOT_GUARD_PROJECT      the project checkout
#   FM_SLOT_GUARD_TASK         this spawn's task id
#   FM_SLOT_GUARD_ARCHIVE_ROOT the data directory holding */merge-prune-preserved
#   FM_SLOT_GUARD_PANE_PID     the acquired endpoint's shell pid, or empty
# FM_SLOT_RESET_GUARD_SEAM (test only) is run once between the two observations, and
# FM_SLOT_RESET_GUARD_HOLDER_SEAM (test only) right after the final pass's holder probes.
FM_SLOT_GUARD_PROJECT=
FM_SLOT_GUARD_TASK=
FM_SLOT_GUARD_ARCHIVE_ROOT=
FM_SLOT_GUARD_PANE_PID=
# The pool lease identity recorded when this spawn took the slot (see fm_slot_guard_record_lease_identity).
FM_SLOT_GUARD_LEASE_PID=
FM_SLOT_GUARD_LEASE_STARTED=
FM_SLOT_GUARD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_SLOT_GUARD_REASON=
FM_SLOT_GUARD_SLOT=
FM_SLOT_GUARD_REAL=
FM_SLOT_GUARD_RECORD=
FM_SLOT_GUARD_MANIFEST=
FM_SLOT_GUARD_MANIFEST_BRANCH=
FM_SLOT_GUARD_MANIFEST_BASE=
FM_SLOT_GUARD_HEAD=
FM_SLOT_GUARD_ATTACHED=
FM_SLOT_GUARD_ANCHORS=()
FM_SLOT_GUARD_ANCHOR_SHAS=()
FM_SLOT_GUARD_OWNER_REFS=()
FM_SLOT_GUARD_OWNER_TIPS=()

fm_slot_guard_refuse() { # <reason-code> <detail>
  FM_SLOT_GUARD_REASON=$1
  echo "error: pooled worktree '$FM_SLOT_GUARD_SLOT' reset refused ($1): $2; the slot was left untouched and nothing was launched" >&2
  return 1
}

fm_slot_guard_record() { # <line>
  FM_SLOT_GUARD_RECORD="${FM_SLOT_GUARD_RECORD}$1"$'\n'
}

# Whether <commit> is an ancestor of one of the resolved anchors.
# Returns 0 contained, 1 not contained, 2 a git read failed.
fm_slot_guard_contained() { # <commit>
  local commit=$1 anchor rc failed=0
  for anchor in ${FM_SLOT_GUARD_ANCHOR_SHAS[@]+"${FM_SLOT_GUARD_ANCHOR_SHAS[@]}"}; do
    rc=0
    git -C "$FM_SLOT_GUARD_SLOT" merge-base --is-ancestor "$commit" "$anchor" 2>/dev/null || rc=$?
    case $rc in
      0) return 0 ;;
      1) ;;
      *) failed=1 ;;
    esac
  done
  [ "$failed" = 0 ] || return 2
  return 1
}

fm_slot_guard_fact_head() {
  local head
  head=$(git -C "$FM_SLOT_GUARD_SLOT" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || {
    fm_slot_guard_refuse unknown_git_read "the slot's HEAD cannot be read"
    return 1
  }
  FM_SLOT_GUARD_HEAD=$head
  fm_slot_guard_record "head=$head"
}

# The owner branches: the branch checked out in the slot, if any, and the branch
# the slot's readable lifecycle manifest names, if any. Each is recorded with its tip.
fm_slot_guard_fact_owners() {
  local ref rc=0 tip listing line manifest_ref
  FM_SLOT_GUARD_ATTACHED=
  FM_SLOT_GUARD_OWNER_REFS=()
  FM_SLOT_GUARD_OWNER_TIPS=()
  ref=$(git -C "$FM_SLOT_GUARD_SLOT" symbolic-ref -q HEAD 2>/dev/null) || rc=$?
  case $rc in
    0)
      tip=$(git -C "$FM_SLOT_GUARD_SLOT" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null) || {
        fm_slot_guard_refuse unknown_git_read "the attached branch $ref has no readable tip"
        return 1
      }
      FM_SLOT_GUARD_ATTACHED=$ref
      FM_SLOT_GUARD_OWNER_REFS+=("$ref")
      FM_SLOT_GUARD_OWNER_TIPS+=("$tip")
      fm_slot_guard_record "attached=$ref $tip"
      ;;
    1) fm_slot_guard_record "attached=none" ;;
    *)
      fm_slot_guard_refuse unknown_git_read "the slot's HEAD symbolic ref cannot be read"
      return 1
      ;;
  esac
  [ -n "$FM_SLOT_GUARD_MANIFEST_BRANCH" ] || return 0
  manifest_ref="refs/heads/$FM_SLOT_GUARD_MANIFEST_BRANCH"
  [ "$manifest_ref" != "$ref" ] || return 0
  listing=$(git -C "$FM_SLOT_GUARD_SLOT" for-each-ref --format='%(refname) %(objectname)' "$manifest_ref" 2>/dev/null) || {
    fm_slot_guard_refuse unknown_git_read "the manifest's branch $manifest_ref cannot be read"
    return 1
  }
  tip=
  while IFS= read -r line; do
    [ "${line%% *}" = "$manifest_ref" ] && tip=${line#* }
  done <<EOF
$listing
EOF
  if [ -n "$tip" ]; then
    FM_SLOT_GUARD_OWNER_REFS+=("$manifest_ref")
    FM_SLOT_GUARD_OWNER_TIPS+=("$tip")
    fm_slot_guard_record "manifest-branch=$manifest_ref $tip"
  else
    fm_slot_guard_record "manifest-branch=absent"
  fi
}

# One read of the slot's lifecycle manifest. It is the base and owner branch the
# project recorded for this slot, found where the governed project keeps it:
# $WORKTREE_LIFECYCLE_STORE_DIR, else <git-common-dir>/vernant-worktree-lifecycle, else the
# legacy $CODEX_HOOK_STATE_DIR/worktree-lifecycle, as <sha256(realpath slot)[:16]>.json.
# A project without the provisioner has none: the origin default is its only anchor.
# Sets FM_SLOT_GUARD_MANIFEST to absent|ungoverned|<bytes sha256>, and the manifest's
# branch and base_sha. An unreadable or unparsable record refuses.
fm_slot_guard_fact_manifest() {
  local common out state sha branch base legacy_state
  FM_SLOT_GUARD_MANIFEST=ungoverned
  FM_SLOT_GUARD_MANIFEST_BRANCH=
  FM_SLOT_GUARD_MANIFEST_BASE=
  if ! fm_slot_required "$FM_SLOT_GUARD_PROJECT" "$FM_SLOT_GUARD_SLOT"; then
    return 0
  fi
  common=$(git -C "$FM_SLOT_GUARD_SLOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
    fm_slot_guard_refuse unknown_manifest "the slot's git common directory cannot be read, so its lifecycle manifest cannot be located"
    return 1
  }
  legacy_state=${CODEX_HOOK_STATE_DIR:-/tmp/vernant-codex-hooks-$(id -u)}
  out=$(python3 -I -c '
import hashlib, json, os, re, sys
slot, common, override, legacy = sys.argv[1:5]
name = hashlib.sha256(os.path.realpath(slot).encode()).hexdigest()[:16] + ".json"
store = override if override else os.path.join(common, "vernant-worktree-lifecycle")
found = None
for directory in (store, os.path.join(legacy, "worktree-lifecycle")):
    path = os.path.join(directory, name)
    if os.path.lexists(path):
        found = path
        break
if found is None:
    print("absent")
    sys.exit(0)
try:
    if not os.path.isfile(found) or os.path.islink(found):
        raise ValueError("not a regular file")
    raw = open(found, "rb").read()
    data = json.loads(raw.decode("utf-8"))
    if not isinstance(data, dict):
        raise ValueError("not a JSON object")
    base = data.get("base_sha")
    if not isinstance(base, str) or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", base):
        raise ValueError("base_sha is missing or malformed")
    branch = data.get("branch")
    if branch is not None and (not isinstance(branch, str) or not branch or "\n" in branch or "\t" in branch):
        raise ValueError("branch is malformed")
except (OSError, ValueError) as exc:
    print("%s: %s" % (found, exc), file=sys.stderr)
    sys.exit(3)
print("present\t%s\t%s\t%s" % (hashlib.sha256(raw).hexdigest(), branch or "-", base))
' "$FM_SLOT_GUARD_SLOT" "$common" "${WORKTREE_LIFECYCLE_STORE_DIR:-}" "$legacy_state" 2>&1) || {
    fm_slot_guard_refuse unknown_manifest "the slot's lifecycle manifest is unreadable ($out)"
    return 1
  }
  case "$out" in
    absent)
      FM_SLOT_GUARD_MANIFEST=absent
      ;;
    present$'\t'*)
      IFS=$'\t' read -r state sha branch base <<EOF
$out
EOF
      FM_SLOT_GUARD_MANIFEST=$sha
      [ "$branch" = - ] || FM_SLOT_GUARD_MANIFEST_BRANCH=$branch
      FM_SLOT_GUARD_MANIFEST_BASE=$base
      if [ -n "$FM_SLOT_GUARD_MANIFEST_BRANCH" ] &&
        ! git check-ref-format "refs/heads/$FM_SLOT_GUARD_MANIFEST_BRANCH" 2>/dev/null; then
        fm_slot_guard_refuse unknown_manifest "the slot's lifecycle manifest names an invalid branch"
        return 1
      fi
      ;;
    *)
      fm_slot_guard_refuse unknown_manifest "the slot's lifecycle manifest read gave an unexpected answer"
      return 1
      ;;
  esac
  fm_slot_guard_record "manifest=$FM_SLOT_GUARD_MANIFEST branch=${FM_SLOT_GUARD_MANIFEST_BRANCH:--} base=${FM_SLOT_GUARD_MANIFEST_BASE:--}"
}

# Resolve the anchors: the caller's origin default branch ref and fetched tip, and
# the manifest's base_sha. A preflight (strict 0) may judge nothing when none resolves;
# the authoritative pass (strict 1) may not.
fm_slot_guard_fact_anchors() { # <strict:0|1>
  local strict=$1 anchor sha
  FM_SLOT_GUARD_ANCHOR_SHAS=()
  for anchor in ${FM_SLOT_GUARD_ANCHORS[@]+"${FM_SLOT_GUARD_ANCHORS[@]}"}; do
    sha=$(git -C "$FM_SLOT_GUARD_SLOT" rev-parse --verify --quiet "$anchor^{commit}" 2>/dev/null) || sha=
    [ -z "$sha" ] || FM_SLOT_GUARD_ANCHOR_SHAS+=("$sha")
  done
  if [ -n "$FM_SLOT_GUARD_MANIFEST_BASE" ]; then
    sha=$(git -C "$FM_SLOT_GUARD_SLOT" rev-parse --verify --quiet "$FM_SLOT_GUARD_MANIFEST_BASE^{commit}" 2>/dev/null) || sha=
    [ -z "$sha" ] || FM_SLOT_GUARD_ANCHOR_SHAS+=("$sha")
  fi
  fm_slot_guard_record "anchors=${FM_SLOT_GUARD_ANCHOR_SHAS[*]-}"
  if [ "${#FM_SLOT_GUARD_ANCHOR_SHAS[@]}" -eq 0 ] && [ "$strict" = 1 ]; then
    fm_slot_guard_refuse unknown_anchor "neither the fetched origin default branch nor a recorded base resolves to a commit, so containment cannot be proved"
    return 1
  fi
}

# S1: a detached HEAD must be contained. An attached HEAD is the owner branch's
# tip, which S2 judges.
fm_slot_guard_fact_head_contained() {
  local rc=0
  [ -z "$FM_SLOT_GUARD_ATTACHED" ] || return 0
  [ "${#FM_SLOT_GUARD_ANCHOR_SHAS[@]}" -gt 0 ] || return 0
  fm_slot_guard_contained "$FM_SLOT_GUARD_HEAD" || rc=$?
  case $rc in
    0) ;;
    1)
      fm_slot_guard_refuse head_not_contained "the detached HEAD ${FM_SLOT_GUARD_HEAD:0:12} is not contained in the fetched origin default branch or the recorded base, so a reset would orphan its commits"
      return 1
      ;;
    *)
      fm_slot_guard_refuse unknown_git_read "containment of the detached HEAD cannot be read"
      return 1
      ;;
  esac
}

# S2: every owner branch tip must be contained, by the same anchors.
fm_slot_guard_fact_owners_contained() {
  local i rc
  [ "${#FM_SLOT_GUARD_ANCHOR_SHAS[@]}" -gt 0 ] || return 0
  for ((i = 0; i < ${#FM_SLOT_GUARD_OWNER_REFS[@]}; i++)); do
    rc=0
    fm_slot_guard_contained "${FM_SLOT_GUARD_OWNER_TIPS[$i]}" || rc=$?
    case $rc in
      0) ;;
      1)
        fm_slot_guard_refuse owner_branch_not_contained "owner branch ${FM_SLOT_GUARD_OWNER_REFS[$i]} at ${FM_SLOT_GUARD_OWNER_TIPS[$i]:0:12} is not contained in the fetched origin default branch or the recorded base, so a reset or branch change would lose its commits"
        return 1
        ;;
      *)
        fm_slot_guard_refuse unknown_git_read "containment of owner branch ${FM_SLOT_GUARD_OWNER_REFS[$i]} cannot be read"
        return 1
        ;;
    esac
  done
}

# S3: the whole tree is clean, judged with every untracked file listed. The spawn
# also runs this fact first of all, so a dirty slot with no origin (no reset at all)
# is still refused. A caller may name a describer (FM_SLOT_GUARD_DIRTY_DESCRIBER),
# called as <slot> <status>, that explains a status which is no uncommitted work.
FM_SLOT_GUARD_DIRTY_DESCRIBER=
fm_slot_guard_fact_clean() {
  local status
  status=$(git -C "$FM_SLOT_GUARD_SLOT" -c core.quotePath=false status --porcelain=v1 --untracked-files=all --ignore-submodules=none 2>/dev/null) || {
    FM_SLOT_GUARD_REASON=unknown_git_read
    echo "error: could not inspect pooled worktree '$FM_SLOT_GUARD_SLOT' before refreshing its base (reset refused: unknown_git_read); the slot was left untouched" >&2
    return 1
  }
  [ -n "$status" ] || return 0
  FM_SLOT_GUARD_REASON=tree_not_clean
  if [ -n "$FM_SLOT_GUARD_DIRTY_DESCRIBER" ] && "$FM_SLOT_GUARD_DIRTY_DESCRIBER" "$FM_SLOT_GUARD_SLOT" "$status"; then
    echo "error: pooled worktree '$FM_SLOT_GUARD_SLOT' has a stale submodule checkout, not uncommitted work; refusing to launch and leaving it untouched" >&2
  else
    echo "error: pooled worktree '$FM_SLOT_GUARD_SLOT' is not clean; refusing to discard uncommitted work while refreshing its base (reset refused: tree_not_clean: $(printf '%s\n' "$status" | sed -n '1,3p' | tr '\n' ';'))" >&2
  fi
  return 1
}

# The first look a spawn takes at a pooled slot, before anything else.
fm_slot_guard_check_clean() { # <slot>
  fm_slot_guard_begin "$1" HEAD || return 1
  fm_slot_guard_fact_clean
}

# One ignored entry is scratch when the existing closeout classifier says so, with
# nothing it would preserve. The classifier is sourced in a subshell, so the guard
# adds no names to the spawn.
fm_slot_guard_entry_is_scratch() { # <slot-relative path> <whole-ignored-directory list>
  local rel=$1 dirs=$2 prefix='' part rest=$1
  (
    set +e
    # shellcheck source=bin/fm-merge-prune-lib.sh
    . "$FM_SLOT_GUARD_LIB_DIR/fm-merge-prune-lib.sh" >/dev/null 2>&1 || exit 2
    scratch() {
      FM_MP_PRESERVE=()
      fm_mp_classify_entry "$FM_SLOT_GUARD_REAL" "$1" >/dev/null 2>&1 || return 1
      [ "${#FM_MP_PRESERVE[@]}" -eq 0 ]
    }
    scratch "$rel" && exit 0
    # `git ls-files -o -i` lists each ignored file on its own. A file inside a
    # directory that `--directory` lists as wholly ignored is judged, like the
    # closeout classifier judges it, by that directory's name; an ancestor that is
    # not wholly ignored (it holds tracked or unignored files) is never judged.
    while :; do
      part=${rest%%/*}
      [ "$part" != "$rest" ] || exit 1
      prefix="${prefix:+$prefix/}$part"
      rest=${rest#*/}
      grep -Fxq -- "$prefix" "$dirs" 2>/dev/null || continue
      scratch "$prefix" && exit 0
    done
  )
}

# Whether a verified archive holds the entry with the bytes it has now: the
# SHA256SUMS written by fm_mp_preserve_one under data/<id>/merge-prune-preserved,
# which must itself verify.
fm_slot_guard_entry_archived() { # <slot-relative path>
  local rel=$1 file sum sums
  file="$FM_SLOT_GUARD_REAL/$rel"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ -n "$FM_SLOT_GUARD_ARCHIVE_ROOT" ] || return 1
  sum=$(shasum -a 256 -- "$file" 2>/dev/null | awk '{print $1}') || return 1
  [ -n "$sum" ] || return 1
  for sums in "$FM_SLOT_GUARD_ARCHIVE_ROOT"/*/merge-prune-preserved/*/*/SHA256SUMS; do
    [ -f "$sums" ] || continue
    grep -Fxq -- "$sum  $rel" "$sums" 2>/dev/null || continue
    if (cd "$(dirname "$sums")" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1); then
      return 0
    fi
  done
  return 1
}

# S3b: ignored work the reset would overwrite. The ignored entries are listed
# with `git ls-files -o -i --exclude-standard`; the reset target's tracked paths
# with `git ls-tree -r --name-only <target>`. An entry collides when it equals a
# target path, lies inside one, or is an ancestor of one (a tracked path below an
# ignored file makes the reset delete that file to create the directory).
fm_slot_guard_fact_ignored() { # <strict:0|1>
  local scratch ignored tracked hits dirs entry bad='' settings
  if [ "$1" = 0 ] && ! git -C "$FM_SLOT_GUARD_SLOT" rev-parse --verify --quiet "$FM_SLOT_GUARD_TARGET^{tree}" >/dev/null 2>&1; then
    return 0
  fi
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-slot-guard.XXXXXX" 2>/dev/null) || {
    fm_slot_guard_refuse unknown_ignored_inventory "a scratch file for the ignored-entry inventory cannot be created"
    return 1
  }
  ignored="$scratch/ignored" tracked="$scratch/tracked" hits="$scratch/hits" dirs="$scratch/dirs"
  if ! git -C "$FM_SLOT_GUARD_SLOT" ls-files -o -i --exclude-standard -z >"$ignored" 2>/dev/null ||
    ! git -C "$FM_SLOT_GUARD_SLOT" ls-files -o -i --exclude-standard --directory -z >"$dirs.z" 2>/dev/null; then
    rm -rf -- "$scratch"
    fm_slot_guard_refuse unknown_ignored_inventory "the slot's ignored entries cannot be listed"
    return 1
  fi
  tr '\0' '\n' <"$dirs.z" | sed -n 's|/$||p' >"$dirs"
  settings=$(git -C "$FM_SLOT_GUARD_SLOT" config --bool --get-regexp '^core\.(ignorecase|precomposeunicode)$' 2>/dev/null) || {
    [ "$?" = 1 ] || {
      rm -rf -- "$scratch"
      fm_slot_guard_refuse unknown_ignored_inventory "the slot's path-comparison settings cannot be read"
      return 1
    }
    settings=
  }
  if ! git -C "$FM_SLOT_GUARD_SLOT" ls-tree -r --name-only -z "$FM_SLOT_GUARD_TARGET" >"$tracked" 2>/dev/null; then
    rm -rf -- "$scratch"
    fm_slot_guard_refuse unknown_ignored_inventory "the reset target's tracked paths cannot be listed"
    return 1
  fi
  if ! python3 -I -c '
import sys, unicodedata
settings = dict(line.split(" ", 1) for line in sys.argv[4].splitlines() if " " in line)
ignorecase = settings.get("core.ignorecase") == "true"
precompose = settings.get("core.precomposeunicode") == "true"
def key(path):
    text = path.decode("utf-8", "surrogateescape")
    if precompose:
        text = unicodedata.normalize("NFC", text)
    if ignorecase:
        text = text.casefold()
    return text
def names(path):
    return [item for item in open(path, "rb").read().split(b"\0") if item]
tracked = set(key(item) for item in names(sys.argv[1]))
below = set()
for path in tracked:
    parts = path.split("/")
    for i in range(1, len(parts)):
        below.add("/".join(parts[:i]))
found = set()
for entry in names(sys.argv[2]):
    entry = entry.rstrip(b"/")
    folded = key(entry)
    parts = folded.split("/")
    inside = any("/".join(parts[:i]) in tracked for i in range(1, len(parts)))
    if folded in tracked or folded in below or inside:
        found.add(entry)
open(sys.argv[3], "wb").write(b"".join(item + b"\n" for item in sorted(found)))
' "$tracked" "$ignored" "$hits" "$settings" 2>/dev/null; then
    rm -rf -- "$scratch"
    fm_slot_guard_refuse unknown_ignored_inventory "the ignored entries could not be compared with the reset target"
    return 1
  fi
  while IFS= read -r entry || [ -n "$entry" ]; do
    [ -n "$entry" ] || continue
    if fm_slot_guard_entry_is_scratch "$entry" "$dirs"; then
      continue
    elif fm_slot_guard_entry_archived "$entry"; then
      continue
    fi
    bad="${bad:+$bad, }$entry"
  done <"$hits"
  rm -rf -- "$scratch"
  if [ -n "$bad" ]; then
    fm_slot_guard_refuse ignored_collision "ignored work at a path the reset target tracks would be overwritten and no verified archive holds it: $bad"
    return 1
  fi
}

# S4 (a): processes with their cwd inside the slot, from one lsof read.
# The spawn's own lineage (its ancestors, its descendants) and the acquired
# endpoint's pane tree are the only exclusions; a holder whose parent chain cannot
# be followed counts as a holder. Arguments are extra pids whose ownership is
# wanted: each is answered "own", "dead", "foreign" or "unknown".
# The pane tree comes from the endpoint's pane pid (tmux, herdr). A backend that
# reports none (zellij, cmux, orca) is probed once more from INSIDE the acquired
# pane through the caller's runner: the pane's shell is then a real ancestor of the
# probe, so it is excluded exactly and nothing else is.
FM_SLOT_GUARD_PANE_RUNNER=
FM_SLOT_GUARD_REPORT_DIR=
FM_SLOT_GUARD_HOLDER_REPORT=
FM_SLOT_GUARD_PROBE_PY=$(cat <<'FMPROBEPY'
import os, subprocess, sys
slot, selfspec, pane = sys.argv[1:4]
extra = sys.argv[4:]
if selfspec == "@self":
    selfpid = os.getpid()
    proc = subprocess.run(["lsof", "-n", "-P", "-w", "-d", "cwd", "-F", "pRcn"], capture_output=True, text=True, stdin=subprocess.DEVNULL)
    if proc.returncode > 1 or not proc.stdout:
        sys.exit(5)
    data = proc.stdout
else:
    selfpid = int(selfspec)
    data = sys.stdin.read()
rows, cur = {}, None
for line in data.split("\n"):
    if not line:
        continue
    tag, value = line[0], line[1:]
    if tag == "p":
        cur = int(value)
        rows[cur] = {"ppid": None, "cwd": None, "cmd": ""}
    elif cur is None:
        sys.exit(3)
    elif tag == "R":
        rows[cur]["ppid"] = int(value)
    elif tag == "c":
        rows[cur]["cmd"] = value
    elif tag == "n":
        rows[cur]["cwd"] = value
if selfpid not in rows:
    sys.exit(4)
def parent(pid):
    return rows[pid]["ppid"] if pid in rows else None
def reaches(pid, target):
    for _ in range(256):
        if pid is None:
            return False
        if pid == target:
            return True
        pid = parent(pid)
    return False
ancestors, pid = set(), selfpid
for _ in range(256):
    if pid is None or pid in ancestors:
        break
    ancestors.add(pid)
    pid = parent(pid)
panepid = int(pane) if pane.isdigit() else None
def own(pid):
    return pid in ancestors or reaches(pid, selfpid) or (panepid is not None and reaches(pid, panepid))
for pid, row in sorted(rows.items()):
    cwd = row["cwd"]
    if cwd and (cwd == slot or cwd.startswith(slot.rstrip("/") + "/")) and not own(pid):
        print("H\t%d\t%s" % (pid, row["cmd"]))
for arg in extra:
    if not arg.isdigit():
        print("P\t%s\tunknown" % arg)
        continue
    pid = int(arg)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        print("P\t%d\tdead" % pid)
        continue
    except PermissionError:
        pass
    print("P\t%d\t%s" % (pid, "own" if own(pid) else ("foreign" if pid in rows else "unknown")))
FMPROBEPY
)

# One probe from inside the acquired pane (the runner is the spawn's own in-pane
# runner, the one governed provisioning already uses on every backend).
fm_slot_guard_probe_in_pane() { # [<pid>...]
  local dir=$FM_SLOT_GUARD_REPORT_DIR script report rc=0
  [ -n "$FM_SLOT_GUARD_PANE_RUNNER" ] && [ -d "$dir" ] || return 1
  script=$(mktemp "$dir/.slot-probe.py.XXXXXX") && report=$(mktemp "$dir/.slot-probe.out.XXXXXX") || return 1
  printf '%s\n' "$FM_SLOT_GUARD_PROBE_PY" >"$script"
  "$FM_SLOT_GUARD_PANE_RUNNER" "$FM_SLOT_GUARD_PROJECT" "$report" "$script" "$FM_SLOT_GUARD_REAL" @self '' "$@" || rc=$?
  if [ "$rc" -eq 0 ]; then FM_SLOT_GUARD_HOLDER_REPORT=$(cat "$report"); fi
  rm -f -- "$script" "$report"
  return "$rc"
}

fm_slot_guard_probe_processes() { # [<pid>...]
  local lsof_out rc=0
  command -v lsof >/dev/null 2>&1 || {
    fm_slot_guard_refuse unknown_holder_probe "lsof is not installed, so processes inside the slot cannot be ruled out"
    return 1
  }
  # lsof exits 1 when nothing matched a selection; a clean working-directory list
  # always holds this process, so an empty or failed read proves nothing.
  lsof_out=$(lsof -n -P -w -d cwd -F pRcn 2>/dev/null </dev/null) || rc=$?
  if [ "$rc" -gt 1 ] || [ -z "$lsof_out" ]; then
    fm_slot_guard_refuse unknown_holder_probe "lsof could not list the processes' working directories (exit $rc)"
    return 1
  fi
  FM_SLOT_GUARD_HOLDER_REPORT=$(printf '%s\n' "$lsof_out" | python3 -I -c "$FM_SLOT_GUARD_PROBE_PY" "$FM_SLOT_GUARD_REAL" "$$" "${FM_SLOT_GUARD_PANE_PID:-}" "$@") || {
    fm_slot_guard_refuse unknown_holder_probe "the working-directory listing could not be read (the spawn's own process is absent from it)"
    return 1
  }
  [ -z "${FM_SLOT_GUARD_PANE_PID:-}" ] || return 0
  printf '%s\n' "$FM_SLOT_GUARD_HOLDER_REPORT" | awk -F'\t' '$1 == "H" || ($1 == "P" && $3 != "dead" && $3 != "own") {found = 1} END {exit !found}' || return 0
  # Something is not attributed and no pane pid is known: judge it again from inside the pane.
  [ -n "$FM_SLOT_GUARD_PANE_RUNNER" ] || return 0
  fm_slot_guard_probe_in_pane "$@" || {
    fm_slot_guard_refuse unknown_holder_probe "the working-directory probe could not run inside the acquired pane"
    return 1
  }
}

fm_slot_guard_fact_holders_cwd() {
  local holders
  fm_slot_guard_probe_processes || return 1
  holders=$(printf '%s\n' "$FM_SLOT_GUARD_HOLDER_REPORT" | awk -F'\t' '$1 == "H" {printf "%s%s(%s)", sep, $3, $2; sep=", "}')
  if [ -n "$holders" ]; then
    fm_slot_guard_refuse holder_cwd "a process outside this spawn's lineage and its own endpoint has its working directory in the slot: $holders"
    return 1
  fi
}

# S4 (b): a git worktree lock on the slot. This spawn never creates one.
fm_slot_guard_fact_holders_lock() {
  local list line path='' locked=0 found=0
  list=$(git -C "$FM_SLOT_GUARD_SLOT" worktree list --porcelain 2>/dev/null) || {
    fm_slot_guard_refuse unknown_lock "the worktree list cannot be read, so a lock on the slot cannot be ruled out"
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "worktree "*) path=${line#worktree } ;;
      locked|"locked "*)
        if [ -n "$path" ] && [ "$path" -ef "$FM_SLOT_GUARD_REAL" ]; then locked=1; fi
        ;;
    esac
    if [ -n "$path" ] && [ "$path" -ef "$FM_SLOT_GUARD_REAL" ]; then found=1; fi
  done <<EOF
$list
EOF
  if [ "$found" = 0 ]; then
    fm_slot_guard_refuse unknown_lock "the slot is not in its repository's worktree list, so a lock on it cannot be ruled out"
    return 1
  fi
  if [ "$locked" = 1 ]; then
    fm_slot_guard_refuse holder_worktree_lock "a git worktree lock is held on the slot"
    return 1
  fi
}

# The lease identity this spawn recorded when it took the slot: the pool entry's owner_pid
# and owner_started_at at the moment the slot's claim named this task (the spawn holds the
# project lock then, so the entry is the spawn's own acquisition). It is the only thing that
# marks a process lease as this spawn's; process ancestry never does.
fm_slot_guard_record_lease_identity() { # <slot>
  local real state entries path pid started
  FM_SLOT_GUARD_LEASE_PID=
  FM_SLOT_GUARD_LEASE_STARTED=
  real=$(CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || return 0
  state="${real%/*/*}/treehouse-state.json"
  [ -f "$state" ] && command -v jq >/dev/null 2>&1 || return 0
  entries=$(jq -r '.worktrees[]? | [(.path // "" | tostring), (.owner_pid // "" | tostring), (.owner_started_at // "" | tostring)] | join("\u001f")' "$state" 2>/dev/null) || return 0
  while IFS=$'\037' read -r path pid started; do
    [ -n "$path" ] && [ "$path" -ef "$real" ] || continue
    FM_SLOT_GUARD_LEASE_PID=$pid
    FM_SLOT_GUARD_LEASE_STARTED=$started
  done <<EOF
$entries
EOF
}

# S4 (c): a live lease on the slot that this spawn did not acquire. The treehouse
# pool's durable lease is foreign unless its holder label is this task's id; a
# process lease is this spawn's only when its owner_pid (and owner_started_at, when
# the entry has one) equals the identity recorded at acquisition. Any other live owner
# refuses, whether or not it sits in the acquired pane's tree. The governed project's
# own lease store adds its file lease, read as a plain file: a live holder, or one
# that cannot be probed and has not expired, refuses.
fm_slot_guard_fact_holders_lease() {
  local state entries leased holder name path pid started verdict common out
  state="${FM_SLOT_GUARD_REAL%/*/*}/treehouse-state.json"
  if fm_treehouse_pool_slot "$FM_SLOT_GUARD_PROJECT" "$FM_SLOT_GUARD_SLOT"; then
    if ! command -v jq >/dev/null 2>&1; then
      fm_slot_guard_refuse unknown_lease "jq is not installed, so the pool's lease state cannot be read"
      return 1
    fi
    entries=$(jq -r '.worktrees[]? | [(.leased == true | tostring), (.lease_holder // "" | tostring), (.name // "" | tostring), (.path // "" | tostring), (.owner_pid // "" | tostring), (.owner_started_at // "" | tostring)] | join("\u001f")' "$state" 2>/dev/null) || {
      fm_slot_guard_refuse unknown_lease "the pool's lease state $state cannot be read"
      return 1
    }
    while IFS=$'\037' read -r leased holder name path pid started; do
      [ -n "$path" ] || continue
      [ "$path" -ef "$FM_SLOT_GUARD_REAL" ] || continue
      if [ "$leased" = true ] && [ "$holder" != "$FM_SLOT_GUARD_TASK" ]; then
        fm_slot_guard_refuse holder_lease "the pool entry '$name' is leased to '${holder:-an unnamed holder}', not to this task"
        return 1
      fi
      [ -n "$pid" ] || continue
      if [ -n "$FM_SLOT_GUARD_LEASE_PID" ] && [ "$pid" = "$FM_SLOT_GUARD_LEASE_PID" ] &&
        { [ -z "$started" ] || [ "$started" = "$FM_SLOT_GUARD_LEASE_STARTED" ]; }; then
        continue
      fi
      fm_slot_guard_probe_processes "$pid" || return 1
      verdict=$(printf '%s\n' "$FM_SLOT_GUARD_HOLDER_REPORT" | awk -F'\t' -v p="$pid" '$1 == "P" && $2 == p {print $3}')
      case "$verdict" in
        dead) ;;
        *)
          fm_slot_guard_refuse holder_lease "the pool entry '$name' is leased to live process $pid, which is not the acquisition this spawn recorded as its own"
          return 1
          ;;
      esac
    done <<EOF
$entries
EOF
  fi
  fm_slot_required "$FM_SLOT_GUARD_PROJECT" "$FM_SLOT_GUARD_SLOT" || return 0
  common=$(git -C "$FM_SLOT_GUARD_SLOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
    fm_slot_guard_refuse unknown_lease "the git common directory cannot be read, so the project's lease store cannot be located"
    return 1
  }
  out=$(fm_slot_guard_store_read lease "$common") || {
    fm_slot_guard_refuse unknown_lease "the project's lease store is unreadable ($out)"
    return 1
  }
  case "$out" in
    "") ;;
    *) fm_slot_guard_refuse holder_lease "the project's lease store records $out"; return 1 ;;
  esac
}

# S4 (d): recent co-tenant contention, from the project's existing contention log
# inside its existing 24-hour window.
fm_slot_guard_fact_holders_contention() {
  local common out
  fm_slot_required "$FM_SLOT_GUARD_PROJECT" "$FM_SLOT_GUARD_SLOT" || return 0
  common=$(git -C "$FM_SLOT_GUARD_SLOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
    fm_slot_guard_refuse unknown_contention "the git common directory cannot be read, so the contention log cannot be located"
    return 1
  }
  out=$(fm_slot_guard_store_read contention "$common") || {
    fm_slot_guard_refuse unknown_contention "the contention log is unreadable ($out)"
    return 1
  }
  if [ -n "$out" ]; then
    fm_slot_guard_refuse holder_contention "the project's contention log records $out"
    return 1
  fi
}

# Reads <common>/vernant-worktree-leases: lease-<sha256("worktree:"+path)[:16]>.json
# and contention.jsonl. Prints nothing when clear, the finding when not; a source that
# cannot be read or whose holder cannot be probed exits 3 with its reason.
fm_slot_guard_store_read() { # lease|contention <common-dir>
  python3 -I -c '
import datetime, hashlib, json, os, sys, time
kind, common, slot, real = sys.argv[1:5]
store = os.path.join(common, "vernant-worktree-leases")
def epoch(value):
    parsed = datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=datetime.timezone.utc)
    return parsed.timestamp()
def fail(text):
    print(text, file=sys.stderr)
    sys.exit(3)
now = time.time()
if kind == "lease":
    for path in sorted({slot, real}):
        name = "lease-" + hashlib.sha256(("worktree:" + path).encode()).hexdigest()[:16] + ".json"
        file = os.path.join(store, name)
        if not os.path.lexists(file):
            continue
        try:
            if not os.path.isfile(file):
                raise ValueError("not a regular file")
            lease = json.loads(open(file, encoding="utf-8").read())
            if not isinstance(lease, dict):
                raise ValueError("not a JSON object")
        except (OSError, ValueError) as exc:
            fail("%s: %s" % (name, exc))
        if lease.get("status") == "released":
            continue
        owner, pid = lease.get("owner_id"), lease.get("owner_pid")
        if isinstance(pid, int) and not isinstance(pid, bool) and pid > 0:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                continue
            except PermissionError:
                pass
            print("a live lease held by %s (pid %d)" % (owner, pid))
            sys.exit(0)
        if lease.get("creation_minted") is True:
            continue
        try:
            expired = epoch(lease["expires_at_iso"]) <= now
        except (KeyError, ValueError):
            fail("%s: the holder cannot be probed and the lease has no readable expiry" % name)
        if not expired:
            fail("%s: the holder cannot be probed and the lease has not expired" % name)
else:
    file = os.path.join(store, "contention.jsonl")
    if not os.path.lexists(file):
        sys.exit(0)
    try:
        text = open(file, encoding="utf-8", errors="replace").read()
    except OSError as exc:
        fail("contention.jsonl: %s" % exc)
    hits, newest = 0, None
    for line in text.splitlines():
        try:
            row = json.loads(line)
            tree, ts = row["worktree_id"], row["ts_iso"]
            if not isinstance(tree, str) or not isinstance(ts, str):
                continue
            age = max(0.0, now - epoch(ts))
        except (ValueError, KeyError, TypeError):
            continue
        if os.path.realpath(tree) not in (real, os.path.realpath(slot)) and tree not in (slot, real):
            continue
        if age <= 24 * 60 * 60:
            hits += 1
            newest = age if newest is None else min(newest, age)
    if hits:
        print("%d co-tenant contention row(s) for this slot within 24 hours (newest %ds old)" % (hits, int(newest)))
' "$1" "$2" "$FM_SLOT_GUARD_SLOT" "$FM_SLOT_GUARD_REAL" 2>&1
}

fm_slot_guard_fact_holders() {
  fm_slot_guard_fact_holders_cwd || return 1
  fm_slot_guard_fact_holders_lock || return 1
  fm_slot_guard_fact_holders_lease || return 1
  fm_slot_guard_fact_holders_contention || return 1
}

# One full observation of the facts above, in order: the slow holder probes first,
# so the git facts after them are the freshest reads before the reset. The caller
# reads the manifest after it (fm_slot_guard_fact_manifest). Each line is one
# removable fact. An early look (strict 0) leaves the clean-tree fact to the check
# that precedes it, which is fm_slot_guard_check_clean in the freshness path and
# fm_slot_check_copy in the governed one.
fm_slot_guard_observe() { # <strict:0|1> [final]
  FM_SLOT_GUARD_RECORD=
  FM_SLOT_GUARD_REASON=
  fm_slot_guard_fact_holders || return 1
  if [ "${2:-}" = final ] && [ -n "${FM_SLOT_RESET_GUARD_HOLDER_SEAM:-}" ]; then
    (eval "$FM_SLOT_RESET_GUARD_HOLDER_SEAM") || true
  fi
  fm_slot_guard_fact_head || return 1
  fm_slot_guard_fact_owners || return 1
  fm_slot_guard_fact_anchors "$1" || return 1
  fm_slot_guard_fact_head_contained || return 1
  fm_slot_guard_fact_owners_contained || return 1
  [ "$1" = 0 ] || fm_slot_guard_fact_clean || return 1
  fm_slot_guard_fact_ignored "$1" || return 1
}

# Set the slot, reset target and anchors for the next observation.
fm_slot_guard_begin() { # <slot> <target-sha> <anchor>...
  FM_SLOT_GUARD_SLOT=$1
  FM_SLOT_GUARD_TARGET=$2
  shift 2
  FM_SLOT_GUARD_ANCHORS=("$@")
  FM_SLOT_GUARD_REAL=$(CDPATH='' cd -- "$FM_SLOT_GUARD_SLOT" 2>/dev/null && pwd -P) || {
    FM_SLOT_GUARD_REAL=$FM_SLOT_GUARD_SLOT
    fm_slot_guard_refuse unknown_git_read "the slot directory cannot be entered"
    return 1
  }
}

# An early look before the spawn's first change to the slot (a fetch into the slot's
# remote-tracking refs, a detach, an anchor ref). The target and the anchor tip are
# the origin tips the spawn already fetched into private refs, so a refusal here
# moves no ref.
# It is not the authority: fm_slot_guarded_reset proves the same facts again after
# the fetch. It may find no anchor or target yet and then judges only the rest.
fm_slot_reset_preflight() { # <slot> <target> <anchor>...
  local slot=$1 target=$2
  shift 2
  fm_slot_guard_begin "$slot" "$target" "$@" || return 1
  fm_slot_guard_fact_manifest || return 1
  fm_slot_guard_observe 0
}

# The guarded reset. Both observations (the final one probes the holders first, then
# re-reads every git fact), the manifest bytes read again, then the one
# destroying command.
fm_slot_guarded_reset() { # <slot> <target-sha> <target-label> <anchor>...
  local slot=$1 target=$2 label=$3 first manifest_first branch_first base_first
  shift 3
  fm_slot_guard_begin "$slot" "$target" "$@" || return 1
  fm_slot_guard_fact_manifest || return 1
  manifest_first=$FM_SLOT_GUARD_MANIFEST branch_first=$FM_SLOT_GUARD_MANIFEST_BRANCH base_first=$FM_SLOT_GUARD_MANIFEST_BASE
  fm_slot_guard_observe 1 || return 1
  first=$FM_SLOT_GUARD_RECORD
  if [ -n "${FM_SLOT_RESET_GUARD_SEAM:-}" ]; then
    (eval "$FM_SLOT_RESET_GUARD_SEAM") || true
  fi
  fm_slot_guard_observe 1 final || return 1
  if [ "$FM_SLOT_GUARD_RECORD" != "$first" ]; then
    fm_slot_guard_refuse changed_since_first_read "the slot's HEAD, owner branches or anchors changed between the first observation and the final one"
    return 1
  fi
  fm_slot_guard_fact_manifest || return 1
  if [ "$FM_SLOT_GUARD_MANIFEST" != "$manifest_first" ] ||
    [ "$FM_SLOT_GUARD_MANIFEST_BRANCH" != "$branch_first" ] ||
    [ "$FM_SLOT_GUARD_MANIFEST_BASE" != "$base_first" ]; then
    fm_slot_guard_refuse changed_since_first_read "the slot's lifecycle manifest changed between the first observation and the final one"
    return 1
  fi
  if ! git -C "$slot" reset --hard "$target" >/dev/null; then
    echo "error: could not reset pooled worktree '$slot' to '$label'; refusing to launch from a potentially stale base" >&2
    return 1
  fi
}
