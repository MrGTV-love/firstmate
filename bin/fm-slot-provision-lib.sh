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
# There is no undo. A refusal, or any failed check after a move has begun, leaves HEAD, every ref and every file exactly as
# they are and says so (Main 1886 CUT).
# The one ref change this spawn's own preparation makes before the move: "<anchor ref>=<commit it anchors>" (absent before,
# exactly that commit after). The move admits that one creation and no other change to this copy's own refs.
FM_SLOT_EXPECT_REFS=
# 1 once fm_slot_prepare_base has written anything to the copy (a detach or an anchor ref). From then on the copy is no
# longer "untouched by this spawn", so a failed move is never a skip (rule Q).
FM_SLOT_PREPARED=0

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
  local project=$1 copy=$2 id=$3 branch head
  FM_SLOT_EXPECT_REFS=
  fm_slot_check_copy "$project" "$copy" || return 1
  branch=$(git -C "$copy" branch --show-current) || return 1
  head=$(git -C "$copy" rev-parse --verify HEAD) || return 1
  # The ordinary freshness owner moves HEAD. Detach first so it cannot move a
  # previous task's branch; preserve a detached tip through the existing owner.
  if [ -z "$branch" ]; then
    fm_task_copy_preserve "$project" "$id" "$copy" 1 || {
      echo "error: cannot preserve assigned slot before refreshing its base: $FM_TASK_COPY_REASON" >&2
      return 1
    }
    [ -z "${FM_TASK_COPY_ANCHOR:-}" ] || FM_SLOT_EXPECT_REFS="$FM_TASK_COPY_ANCHOR=$head"
  fi
  # From here something may have been written (an anchor ref), so the copy is no longer untouched by this spawn.
  FM_SLOT_PREPARED=1
  # Detaching moves no file: the same commit stays checked out. Hooks stay off for every checkout here.
  git -C "$copy" -c core.hooksPath=/dev/null checkout --quiet --detach || return 1
  if [ -n "$branch" ]; then FM_SLOT_PREPARE_DETACHED=1; else FM_SLOT_PREPARE_DETACHED=0; fi
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
  fm_slot_attach "$copy" "$branch" "$expected" || return $?
  if [ "$(git -C "$copy" rev-parse --verify HEAD)" != "$expected" ]; then
    echo "error: prepared task branch $branch moved during recovery; no worker admitted; the copy is left exactly where it is ($(fm_slot_where "$copy"))" >&2
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
  local rc=0
  fm_slot_provision_run "$@" || rc=$?
  fm_slot_export_drop
  return "$rc"
}

fm_slot_provision_run() {
  local runner=$1 project=$2 copy=$3 id=$4 branch=$5 report=$6 local_ref=$7 selected=$8
  local base old_branch old_head branch_head provisioner rc=0
  shift 8
  FM_SLOT_PROVISIONED=0
  FM_SLOT_MANIFEST=
  FM_SLOT_BASE_SHA=
  FM_SLOT_BASE_REF=
  FM_SLOT_PREPARED_HEAD=
  fm_slot_require_scope "$@" || return 1
  fm_slot_check_copy "$project" "$copy" || return 1
  provisioner=$copy/scripts/git-stability/provision_existing_slot.py
  FM_SLOT_PYARGS=()
  if [ ! -f "$provisioner" ]; then
    # A relaunch of a task whose copy predates the provisioner runs the primary clone's current main (D7); every
    # other caller still requires the script in the assigned copy.
    [ "${FM_SLOT_PRIMARY_PROVISIONER:-0}" = 1 ] || {
      echo "error: slot provisioner is missing from assigned copy $copy" >&2
      return 1
    }
    fm_slot_primary_provisioner "$project" || return 1
    provisioner=$FM_SLOT_PROVISIONER
  fi
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
      git -C "$copy" -c core.hooksPath=/dev/null checkout --quiet "$branch" -- || return 1
    else
      git -C "$copy" -c core.hooksPath=/dev/null checkout --quiet -b "$branch" -- || return 1
    fi
  fi
  FM_SLOT_PREPARED_HEAD=$old_head
  local args=() path
  [ -z "$local_ref" ] || args+=(--base-source local-default)
  for path in "$@"; do args+=(--owned-path "$path"); done
  # Spawn executes in the acquired pane's ancestry, so its own cwd holder is
  # attributable to this invocation. The provisioner still rejects unrelated
  # live holders. Promotion's same-owner declaration uses the local runner.
  "$runner" "$project" "$report" ${FM_SLOT_PYARGS[@]+"${FM_SLOT_PYARGS[@]}"} "$provisioner" \
    --repo-root "$project" --worktree-path "$copy" --owner-id "$id" \
    --branch "$branch" --base-sha "$base" "${args[@]}" || rc=$?
  if ! fm_slot_export_verify; then
    echo '{"state": "BLOCKED", "reason": "provisioner_source_changed"}' >"$report"
    rc=1
  fi
  fm_slot_export_drop
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
    # A refusal does nothing (Main 1886 CUT): no checkout, no switch of HEAD, no deletion, no undo. The copy stays exactly
    # as the refusal found it, which can be the task branch this function set, and the line below says where that is.
    echo "error: slot provisioner refused task $id (exit $rc); no agent or ship transition admitted; the copy is left exactly where it is ($(fm_slot_where "$copy")); report: $report" >&2
    return "$rc"
  fi
  FM_SLOT_MANIFEST=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifest_path"])' "$report") || return 1
  FM_SLOT_BASE_SHA=$base
  FM_SLOT_BASE_REF=$local_ref
  FM_SLOT_PROVISIONED=1
}

# The provisioner a relaunch runs for a copy that predates it (D7): the primary clone's, and only when the entry
# script and every repository-local module it imports (transitively) hold the bytes of the default branch's tip,
# whatever branch the clone is on. A linked checkout, or a primary checkout whose closure differs from the tip, is
# refused by name. Sets FM_SLOT_PROVISIONER to the script path.
FM_SLOT_PROVISIONER=
FM_SLOT_PRIMARY_PROVISIONER=0
FM_SLOT_CLOSURE_PY=$(cat <<'FMCLOSUREPY'
import ast
import os
import sys

root = sys.argv[1]
entry = os.path.join(root, "scripts/git-stability/provision_existing_slot.py")
seen = []
queue = [entry]
relative = []


def candidates(module, base_dir):
    parts = module.split(".")
    for start in (base_dir, root):
        stem = os.path.join(start, *parts)
        yield stem + ".py"
        yield os.path.join(stem, "__init__.py")


while queue:
    path = queue.pop()
    if path in seen:
        continue
    seen.append(path)
    # Python runs every ancestor package's __init__.py before the module, so those files are part of the closure too.
    ancestor = os.path.dirname(path)
    while os.path.commonpath([root, ancestor]) == root and ancestor != root:
        init = os.path.join(ancestor, "__init__.py")
        if os.path.isfile(init) and init not in seen:
            queue.append(init)
        ancestor = os.path.dirname(ancestor)
    try:
        with open(path, encoding="utf-8") as handle:
            tree = ast.parse(handle.read())
    except (OSError, SyntaxError, UnicodeDecodeError):
        print("unreadable\t" + os.path.relpath(path, root))
        continue
    names = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names += [alias.name for alias in node.names]
        elif isinstance(node, ast.ImportFrom) and node.module and not node.level:
            names.append(node.module)
            names += [node.module + "." + alias.name for alias in node.names]
        elif isinstance(node, ast.ImportFrom) and node.level:
            # A relative import resolves from the importing file's own package directory.
            package = os.path.dirname(path)
            for _ in range(node.level - 1):
                package = os.path.dirname(package)
            stem = [node.module] if node.module else []
            relative.append((package, ".".join(stem), [alias.name for alias in node.names]))
    for name in names:
        for found in candidates(name, os.path.dirname(path)):
            if os.path.isfile(found) and os.path.commonpath([root, os.path.realpath(found)]) == root:
                queue.append(found)
                break
    for package, module, imported in relative:
        for target in ([module] if module else []) + [(module + "." if module else "") + name for name in imported]:
            stem = os.path.join(package, *target.split("."))
            for found in (stem + ".py", os.path.join(stem, "__init__.py")):
                if os.path.isfile(found) and os.path.commonpath([root, os.path.realpath(found)]) == root:
                    queue.append(found)
                    break
    relative.clear()
final = []
for path in seen:
    directory = os.path.dirname(path)
    while os.path.commonpath([root, directory]) == root and directory != root:
        init = os.path.join(directory, "__init__.py")
        if os.path.isfile(init) and init not in final:
            final.append(init)
        directory = os.path.dirname(directory)
    if path not in final:
        final.append(path)
for path in final:
    print("file\t" + os.path.relpath(path, root))
FMCLOSUREPY
)

fm_slot_primary_provisioner() { # <project>
  local project=$1 common primary default tip closure kind rel
  FM_SLOT_PROVISIONER=
  common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
    echo "error: slot provisioner source is not the primary clone's current main: the project's repository is unreadable" >&2
    return 1
  }
  primary=$(dirname "$common")
  { [ "$(git -C "$primary" rev-parse --show-toplevel 2>/dev/null)" = "$primary" ] &&
    [ -f "$primary/scripts/git-stability/provision_existing_slot.py" ]; } || {
    echo "error: slot provisioner source is not the primary clone's current main: $primary is not a checkout holding the provisioner" >&2
    return 1
  }
  default=$(fm_task_copy_default_branch "$primary") || default=
  tip=
  [ -z "$default" ] || tip=$(git -C "$primary" rev-parse --verify --quiet "refs/heads/$default^{commit}") || tip=
  [ -n "$tip" ] || {
    echo "error: slot provisioner source is not the primary clone's current main: the default branch tip cannot be read" >&2
    return 1
  }
  closure=$(python3 -c "$FM_SLOT_CLOSURE_PY" "$primary") || closure=
  [ -n "$closure" ] || {
    echo "error: slot provisioner source is not the primary clone's current main: its import closure cannot be read" >&2
    return 1
  }
  while IFS=$'\t' read -r kind rel; do
    [ "$kind" = file ] || {
      echo "error: slot provisioner source is not the primary clone's current main: $rel cannot be read" >&2
      return 1
    }
    [ "$(git -C "$primary" hash-object -- "$rel" 2>/dev/null)" = "$(git -C "$primary" rev-parse --verify --quiet "$tip:$rel" 2>/dev/null)" ] || {
      echo "error: slot provisioner source is not the primary clone's current main: $rel differs from $default's tip in $primary" >&2
      return 1
    }
  done <<<"$closure"
  # The bytes that run are the tip's, from a private read-only export of exactly the verified closure (written from the
  # tip's blobs, never from the working tree), run with an interpreter cache prefix that is a fresh empty directory so no
  # bytecode that existed before the run can load. Its hashes are checked again after the run (fm_slot_export_verify).
  FM_SLOT_EXPORT=$(mktemp -d "${TMPDIR:-/tmp}/fm-slot-export.XXXXXX") || return 1
  FM_SLOT_PYCACHE=$(mktemp -d "${TMPDIR:-/tmp}/fm-slot-pycache.XXXXXX") || { fm_slot_export_drop; return 1; }
  FM_SLOT_EXPORT_SUMS=$FM_SLOT_EXPORT.sums
  : >"$FM_SLOT_EXPORT_SUMS" || { fm_slot_export_drop; return 1; }
  while IFS=$'\t' read -r kind rel; do
    if ! { mkdir -p "$FM_SLOT_EXPORT/$(dirname "$rel")" && git -C "$primary" show "$tip:$rel" >"$FM_SLOT_EXPORT/$rel"; }; then
      echo "error: slot provisioner source is not the primary clone's current main: $rel could not be exported from $default's tip" >&2
      fm_slot_export_drop
      return 1
    fi
  done <<<"$closure"
  chmod -R a-w "$FM_SLOT_EXPORT" 2>/dev/null || true
  # The record is taken after the files are made read-only: bytes, inode and change time in nanoseconds of every file, so a
  # substitution that is restored before the run ends still changes an inode or a change time (D7 (a)).
  fm_slot_export_fingerprint "$FM_SLOT_EXPORT" >"$FM_SLOT_EXPORT_SUMS" || {
    echo "error: slot provisioner source is not the primary clone's current main: the export could not be recorded" >&2
    fm_slot_export_drop
    return 1
  }
  FM_SLOT_PROVISIONER=$FM_SLOT_EXPORT/scripts/git-stability/provision_existing_slot.py
  FM_SLOT_PYARGS=(-X "pycache_prefix=$FM_SLOT_PYCACHE")
}

FM_SLOT_EXPORT=
FM_SLOT_EXPORT_SUMS=
FM_SLOT_PYCACHE=
FM_SLOT_PYARGS=()
# One line per exported file: sha256, inode, change time in nanoseconds, relative path; sorted by path.
fm_slot_export_fingerprint() { # <export-dir>
  python3 -I - "$1" <<'PY'
import hashlib
import os
import sys

root = sys.argv[1]
rows = []
for base, _dirs, files in os.walk(root):
    for name in files:
        path = os.path.join(base, name)
        info = os.lstat(path)
        with open(path, "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        rows.append((os.path.relpath(path, root), "%s %d %d %s" % (digest, info.st_ino, info.st_ctime_ns, os.path.relpath(path, root))))
for _rel, row in sorted(rows):
    print(row)
PY
}
# Refuse by name when any exported file changed, was replaced (inode) or touched (change time) since the export, or when a
# file appeared: a substitution after the check is detected even when its bytes and mode are restored before the run ends.
fm_slot_export_verify() {
  local now
  [ -n "$FM_SLOT_EXPORT" ] || return 0
  now=$(fm_slot_export_fingerprint "$FM_SLOT_EXPORT" 2>/dev/null) || now=
  [ "$now" = "$(cat "$FM_SLOT_EXPORT_SUMS" 2>/dev/null)" ] && return 0
  if [ "$(printf '%s\n' "$now" | wc -l | tr -d ' ')" != "$(wc -l <"$FM_SLOT_EXPORT_SUMS" | tr -d ' ')" ]; then
    echo "error: slot provisioner source gained files after it was verified (or lost one); the run is refused" >&2
  else
    echo "error: slot provisioner source changed after it was verified (bytes, inode or change time); the run is refused" >&2
  fi
  return 1
}
fm_slot_export_drop() {
  [ -z "$FM_SLOT_EXPORT" ] || { chmod -R u+w "$FM_SLOT_EXPORT" 2>/dev/null; rm -rf -- "$FM_SLOT_EXPORT" "$FM_SLOT_EXPORT_SUMS"; }
  [ -z "$FM_SLOT_PYCACHE" ] || rm -rf -- "$FM_SLOT_PYCACHE"
  FM_SLOT_EXPORT='' FM_SLOT_EXPORT_SUMS='' FM_SLOT_PYCACHE=''
  FM_SLOT_PYARGS=()
}

# The refusals the provisioning route foresees from the task's recorded facts, named before the running agent is
# stopped (Main 1790 s2): the copy checks fm_slot_provision makes, a recorded scope path that is not tracked at the
# base the provisioner will use, an own out-of-scope change, and a manifest already at the path the provisioner would
# write that the record does not adopt (asked of the provisioner's own read-only --check-manifest-only when it has
# one). A refusal that cannot be foreseen leaves the existing rollback to the prior record.
fm_slot_foresee_refusals() { # <project> <copy> <task-id> <branch> <meta> <owned-path>...
  local project=$1 copy=$2 id=$3 branch=$4 meta=$5 base path out reason script scope inside outside mpath
  local -a args=()
  shift 5
  if ! out=$(fm_slot_check_copy "$project" "$copy" 2>&1); then
    printf '%s\n' "$out" >&2
    # An uncommitted own edit is the one own work this route refuses (Main 1795): nothing changes and every own
    # path is printed, so the operator sees what the refusal left untouched.
    case "$out" in
      *dirty_worktree*|*operation_in_progress*)
        fm_slot_drift_report "$copy" "$id" "$branch" \
          "$(git -C "$copy" merge-base origin/main HEAD 2>/dev/null || git -C "$copy" rev-parse HEAD 2>/dev/null)" "$@" ;;
    esac
    return 1
  fi
  [ -z "$(fm_meta_get "$meta" slot_source_ref)" ] || return 0
  base=$(git -C "$copy" merge-base origin/main HEAD 2>/dev/null) || return 0
  for path in "$@"; do
    [ -n "$(git -C "$copy" ls-tree -r --name-only "$base" -- ":(literal)${path%/}" 2>/dev/null)" ] || {
      echo "error: slot provisioning refused: scope_not_tracked: $path is not tracked at the base $base" >&2
      return 1
    }
  done
  out=$(git -C "$copy" diff --name-only --no-renames -z "$base" HEAD 2>/dev/null | tr '\0' '\n') || out=
  outside=
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    inside=0
    for scope in "$@"; do
      case "$path" in "${scope%/}"|"${scope%/}"/*) inside=1 ;; esac
    done
    [ "$inside" = 1 ] || outside=${outside:+$outside, }$path
  done <<<"$out"
  if [ -n "$outside" ]; then
    # Every own out-of-scope path is named, and the drift report prints the same paths with their provenance, so the
    # refusal leaves the operator exactly what the dirty_worktree refusal does.
    echo "error: slot provisioning refused: scope_mismatch: $outside changed outside the recorded scope" >&2
    fm_slot_drift_report "$copy" "$id" "$branch" "$base" "$@"
    return 1
  fi
  # The provisioner that would really run: the copy's own, or for a copy that predates it the verified primary
  # clone export (D7). Its read-only manifest check, when it has one, names a manifest collision before the stop.
  script=$copy/scripts/git-stability/provision_existing_slot.py
  FM_SLOT_PYARGS=()
  if [ ! -f "$script" ]; then
    fm_slot_primary_provisioner "$project" || return 1
    script=$FM_SLOT_PROVISIONER
  fi
  if ! grep -q -e '--check-manifest-only' "$script" 2>/dev/null; then
    # A pinned provisioner without the read-only check and without a same-owner arm refuses every existing manifest at
    # its create-only path (D8), so the same two record paths its own writer uses are read here, and a manifest found
    # there is named before the stop. A provisioner with a same-owner arm may admit an identical declaration, so its
    # outcome cannot be foreseen here and the existing rollback stays.
    mpath=
    grep -q -e '_same_owner_outcome' "$script" 2>/dev/null || mpath=$(fm_slot_record_collision "$project" "$copy") || mpath=
    fm_slot_export_drop
    [ -z "$mpath" ] || {
      echo "error: slot provisioning refused: manifest_exists: a lifecycle manifest is already at the path the provisioner would write, and the task record does not adopt it; \"manifest_path\": \"$mpath\"" >&2
      return 1
    }
    return 0
  fi
  for path in "$@"; do args+=(--owned-path "$path"); done
  out=$(cd "$project" && PYTHONDONTWRITEBYTECODE=1 python3 ${FM_SLOT_PYARGS[@]+"${FM_SLOT_PYARGS[@]}"} "$script" --check-manifest-only --repo-root "$project" \
    --worktree-path "$copy" --owner-id "$id" --branch "$branch" --base-sha "$base" "${args[@]}" 2>/dev/null) || true
  fm_slot_export_verify || { fm_slot_export_drop; return 1; }
  fm_slot_export_drop
  reason=$(printf '%s' "$out" | python3 -c 'import json, sys
try:
    r = json.load(sys.stdin)
    print(r["reason"] if r.get("state") == "BLOCKED" else "")
except Exception:
    print("")' 2>/dev/null) || reason=
  mpath=$(printf '%s' "$out" | python3 -c 'import json, sys
try:
    r = json.load(sys.stdin)
    value = r.get("manifest_path")
    print(value if isinstance(value, str) and "\"" not in value and "\n" not in value else "")
except Exception:
    print("")' 2>/dev/null) || mpath=
  case "$reason" in
    manifest_exists)
      # The collision file is named in the provisioner's own "manifest_path" form, so the session-end refusal memory can
      # hash it and a cleared collision permits one new attempt.
      echo "error: slot provisioning refused: manifest_exists: a lifecycle manifest is already at the path the provisioner would write, and the task record does not adopt it${mpath:+; \"manifest_path\": \"$mpath\"}" >&2
      return 1 ;;
  esac
}

# The two lifecycle record paths a provisioner keeps for <copy>, durable then legacy, one per line, whether or not either
# exists: the same two stores and the same digest of the copy's resolved path that bin/fm-slot-manifest-retire.py uses.
# Returns 1 when the project's repository cannot be read.
fm_slot_record_paths() { # <project> <copy>
  python3 -I - "$1" "$2" <<'PY'
import hashlib
import os
import subprocess
import sys
from pathlib import Path

project, copy = sys.argv[1:3]
common = subprocess.run(["git", "-C", project, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                        capture_output=True, text=True)
if common.returncode:
    sys.exit(1)
common = Path(common.stdout.strip()).resolve()
default = Path("/tmp/vernant-codex-hooks-%d" % os.getuid())
state = Path(os.environ.get("CODEX_HOOK_STATE_DIR") or default)
durable = Path(os.environ.get("WORKTREE_LIFECYCLE_STORE_DIR") or common / "vernant-worktree-lifecycle")
if "WORKTREE_LIFECYCLE_STORE_DIR" not in os.environ and state.resolve() != default.resolve():
    durable = state / "worktree-lifecycle"
name = hashlib.sha256(str(Path(copy).resolve()).encode()).hexdigest()[:16] + ".json"
print(durable / name)
print(state / "worktree-lifecycle" / name)
PY
}

# The lifecycle record already at the path a create-only provisioner would write for <copy>, read-only: the first of the
# two record paths that exists is printed (return 0); nothing is printed and 1 is returned when neither exists.
fm_slot_record_collision() { # <project> <copy>
  local paths path
  paths=$(fm_slot_record_paths "$1" "$2") || return 1
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ -e "$path" ] || [ -L "$path" ]; then printf '%s\n' "$path"; return 0; fi
  done <<<"$paths"
  return 1
}

# Where a copy is, read-only: its branch, "detached" (git says so: exit 1), or "unknown" (any other failure), and its commit.
fm_slot_where() { # <copy>
  local ref sha rc=0
  ref=$(git -C "$1" symbolic-ref -q HEAD 2>/dev/null) || rc=$?
  case "$rc" in 0) ;; 1) ref=detached ;; *) ref=unknown ;; esac
  sha=$(git -C "$1" rev-parse --verify --quiet HEAD 2>/dev/null) || sha=unreadable
  printf '%s at %s' "$ref" "$sha"
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

# --- Adopting the task's own manifest on a relaunch (Main 115, rule S) -------------------------
# A relaunch is not a new scope declaration. A governed task whose record names its slot manifest
# is judged by the record of what was already admitted, never by the fresh-admission rules of the
# provisioner (create-only manifest, scope tracked at the base, every changed path inside scope).
# fm_slot_adopt_route says when that applies and fm_slot_adopt_check is the one decision: it reads
# the manifest, the copy and the custody owners and writes nothing, so the manifest file, its
# directory, the recorded scope and the recorded base stay exactly as they were. Vernant's push-time
# owned_paths gate stays the control for the task's own out-of-scope work, a pool slot another task claims refuses the
# relaunch by name unless that task's record places its copy inside the slot, and no other peer claim is checked; the
# drift report only makes the out-of-scope paths visible.
FM_SLOT_ADOPTED=0
FM_SLOT_ADOPT_ROOT=

# 0 when <meta>'s task is relaunched into its own recorded slot: a recorded manifest, no
# relocation to a replacement copy, and not the recovery of a first provisioning that never finished.
fm_slot_adopt_route() { # <meta> <relocating 0|1>
  [ "${2:-0}" = 0 ] || return 1
  [ -n "$(fm_meta_get "$1" slot_manifest)" ] || return 1
  [ "$(fm_meta_get "$1" recovery)" != slot-provision-refused ]
}

# 0 when a relaunch of <meta>'s task may run the primary clone's verified provisioner for a copy that predates it (D7):
# every relaunch except the recovery of a first provisioning that was refused, which keeps its prior behavior (D4(c))
# and so still requires the script in the assigned copy.
fm_slot_primary_route_allowed() { # <meta>
  [ "$(fm_meta_get "$1" recovery)" != slot-provision-refused ]
}

# The custody decision of a relaunch that provisions a manifest on its own copy (no recorded manifest): named by the same
# refusal prefix as the other provisioning refusals, so the session-end reader classifies it. Returns 0 or 1.
fm_slot_provision_custody() { # <project> <copy> <task-id> <meta> <state-dir>
  fm_slot_custody_check "$@" && return 0
  echo "error: slot provisioning refused: $FM_SLOT_CUSTODY_REASON: $FM_SLOT_CUSTODY_DETAIL; no manifest, scope, record or copy was changed" >&2
  return 1
}

fm_slot_adopt_refuse() { # <reason> <detail>
  local changed='no manifest, scope, record or copy was changed'
  if [ "${FM_SLOT_ADOPT_WIRED:-0}" = 1 ]; then
    changed='the launch wiring in the copy and the task record were already written by this relaunch; the recorded manifest and scope were not changed'
  fi
  echo "error: slot adoption refused: $1${2:+: $2}; $changed" >&2
  return 1
}

# The manifest-versus-record comparison of the adoption decision, as one reusable function so a replay of recorded
# manifests runs exactly the code a relaunch runs. Prints "ok<TAB><repo_root>" or "<reason><TAB><detail>".
fm_slot_adopt_verdict() { # <manifest> <real-copy> <branch> <base-sha> <owned-path>...
  python3 - "$@" <<'PY'
import json
import os
import sys

manifest, copy, branch, base = sys.argv[1:5]
scope = sys.argv[5:]
try:
    with open(manifest, encoding="utf-8") as handle:
        record = json.load(handle)
except (OSError, ValueError):
    print("manifest_unreadable\tthe recorded manifest is not valid JSON")
    sys.exit(0)
if not isinstance(record, dict):
    print("manifest_unreadable\tthe recorded manifest is not a JSON object")
    sys.exit(0)
def field(name):
    value = record.get(name)
    return value if isinstance(value, str) else ""
if os.path.realpath(field("worktree_path")) != copy or not field("worktree_path"):
    print("worktree_path_mismatch\tmanifest names %r, the task copy is %r" % (field("worktree_path"), copy))
elif field("lifecycle_state") != "worktree_active":
    print("lifecycle_state_mismatch\tmanifest state is %r, not worktree_active" % field("lifecycle_state"))
elif field("branch") != branch:
    print("branch_mismatch\tmanifest branch is %r, the task branch is %r" % (field("branch"), branch))
elif field("base_sha") != base:
    print("base_mismatch\tmanifest base is %r, the recorded base is %r" % (field("base_sha"), base))
elif not isinstance(record.get("owned_paths"), list) or sorted(record["owned_paths"]) != sorted(scope):
    print("scope_mismatch\tthe manifest scope differs from the recorded task scope")
elif not field("repo_root"):
    print("repo_root_missing\tthe manifest names no repository root")
else:
    print("ok\t" + field("repo_root"))
PY
}

# The recorded pointer against the lifecycle records the provisioner keeps for the copy (D2): when a durable record exists
# it is the authoritative one and the pointer must name it, and every existing record must agree with the pointed one on
# the identity fields a provisioner compares (a legacy record omits newer fields, so a field is compared only when both
# records carry it). Prints "ok" or "<reason><TAB><detail>"; reads only.
fm_slot_adopt_records() { # <manifest> <durable> <legacy>
  python3 -I - "$@" <<'PY'
import json
import os
import re
import sys

pointer, durable, legacy = sys.argv[1:4]
real = os.path.realpath
existing = [path for path in (durable, legacy) if os.path.lexists(path)]
# A provisioner record is named by a 16-hex digest. One whose directory is not among the two stores computed here was
# written under another store configuration, so the other record cannot be read and the pointer cannot be judged: it is
# refused by name rather than adopted unchecked (fail closed).
if re.fullmatch(r"[0-9a-f]{16}\.json", os.path.basename(pointer)) and \
        real(os.path.dirname(pointer)) not in (real(os.path.dirname(durable)), real(os.path.dirname(legacy))):
    print("manifest_store_unknown\tthe recorded pointer %s is in a record store that is not one of this relaunch's (%s, %s); relaunch with the CODEX_HOOK_STATE_DIR and WORKTREE_LIFECYCLE_STORE_DIR the task was provisioned with" % (pointer, os.path.dirname(durable), os.path.dirname(legacy)))
    sys.exit(0)
if os.path.lexists(durable) and real(pointer) != real(durable):
    print("manifest_shadowed\tthe recorded pointer %s is not the durable record %s, which is the authoritative one" % (pointer, durable))
    sys.exit(0)
if existing and real(pointer) not in [real(path) for path in existing]:
    print("manifest_shadowed\tthe recorded pointer %s is not the provisioner's record %s" % (pointer, existing[0]))
    sys.exit(0)
# A timestamp is not identity and its formatting can differ between the two records, so it is not compared.
identity = ("repo_root", "worktree_path", "branch", "base_ref", "base_sha", "owner_id", "owned_paths")
try:
    with open(pointer, encoding="utf-8") as handle:
        want = json.load(handle)
    for path in existing:
        if real(path) == real(pointer):
            continue
        with open(path, encoding="utf-8") as handle:
            other = json.load(handle)
        for key in identity:
            if key not in want or key not in other:
                continue
            a, b = want[key], other[key]
            if key == "owned_paths" and isinstance(a, list) and isinstance(b, list):
                a, b = sorted(a), sorted(b)
            if a != b:
                print("manifest_records_disagree\tthe recorded pointer and %s differ in %s" % (path, key))
                sys.exit(0)
except (OSError, ValueError, TypeError):
    print("manifest_unreadable\ta lifecycle record of the copy cannot be read")
    sys.exit(0)
print("ok")
PY
}

# The copy-custody decision, one for every route that provisions or adopts a manifest on a copy: the existing owners'
# verdict passed through and fail-closed (another task's record naming this copy, an unreadable home or record, and a
# pool-slot claim that is not provably this task's). Returns 0, or 1 with FM_SLOT_CUSTODY_REASON and
# FM_SLOT_CUSTODY_DETAIL set; reads only.
FM_SLOT_CUSTODY_REASON=
FM_SLOT_CUSTODY_DETAIL=
fm_slot_custody_fail() { # <reason> <detail>
  FM_SLOT_CUSTODY_REASON=$1
  FM_SLOT_CUSTODY_DETAIL=$2
  return 1
}
fm_slot_custody_check() { # <project> <copy> <task-id> <meta> <state-dir>
  local project=$1 copy=$2 id=$3 meta=$4 state=$5 real_copy slot rc=0
  FM_SLOT_CUSTODY_REASON=
  FM_SLOT_CUSTODY_DETAIL=
  real_copy=$(CDPATH='' cd -- "$copy" 2>/dev/null && pwd -P) || { fm_slot_custody_fail copy_unreadable "$copy"; return 1; }
  fm_task_copy_other_record "$meta" "$state" "$copy" || rc=$?
  case "$rc" in
    0) fm_slot_custody_fail custody_other_record "task $FM_TASK_COPY_OTHER_ID's record names this copy as its $FM_TASK_COPY_OTHER_FIELD"; return 1 ;;
    1) ;;
    *) fm_slot_custody_fail custody_unreadable 'a registered home or task record could not be read, so no other holder is proved absent'; return 1 ;;
  esac
  slot=$(fm_task_copy_enclosing_pool_slot "$project" "$real_copy") || slot=
  [ -n "$slot" ] || { fm_treehouse_pool_slot "$project" "$real_copy" && slot=$real_copy; } || slot=
  if [ -n "$slot" ]; then
    fm_treehouse_slot_owner_state "$slot" "$id"
    case "$FM_TREEHOUSE_SLOT_OWNER" in
      absent) ;;
      mine)
        # A claim for this task ID from another home is not this task's own (the relocation path's rule).
        fm_treehouse_slot_claim_home_is_this_home || {
          fm_slot_custody_fail custody_slot_claim "pool slot $slot is claimed for task $id by another home (${FM_TREEHOUSE_SLOT_OWNER_HOME:-no home recorded})"
          return 1
        } ;;
      other)
        fm_slot_adopt_sibling_claim "$slot" "$real_copy" "$state" ||
          { fm_slot_custody_fail custody_slot_claim "pool slot $slot is claimed by task $FM_TREEHOUSE_SLOT_OWNER_ID"; return 1; } ;;
      *) fm_slot_custody_fail custody_slot_claim "the owner claim of pool slot $slot cannot be read"; return 1 ;;
    esac
  fi
}

# Judge the recorded manifest against the task's own record, copy and branch. Returns 0 and sets
# FM_SLOT_MANIFEST, FM_SLOT_BASE_SHA, FM_SLOT_BASE_REF and FM_SLOT_ADOPTED=1 only when every check holds;
# otherwise prints the refusal by name and returns 1.
fm_slot_adopt_check() { # <project> <copy> <task-id> <branch> <meta> <state-dir>
  local project=$1 copy=$2 id=$3 branch=$4 meta=$5 state=$6
  local manifest base ref common slot_common real_copy root verdict records_verdict line git_head head_name marker records
  local -a scope=()
  FM_SLOT_ADOPTED=0
  manifest=$(fm_meta_get "$meta" slot_manifest)
  base=$(fm_meta_get "$meta" slot_base_sha)
  ref=$(fm_meta_get "$meta" slot_source_ref)
  while IFS= read -r line; do scope+=("$line"); done < <(sed -n 's/^slot_owned_path=//p' "$meta")
  [ -n "$manifest" ] || { fm_slot_adopt_refuse manifest_not_recorded 'the task record names no slot manifest'; return 1; }
  [ -n "$base" ] || { fm_slot_adopt_refuse base_not_recorded 'the task record names no slot base'; return 1; }
  [ "${#scope[@]}" -gt 0 ] || { fm_slot_adopt_refuse scope_not_recorded 'the task record names no slot scope'; return 1; }
  fm_slot_require_scope "${scope[@]}" >/dev/null 2>&1 || { fm_slot_adopt_refuse scope_invalid 'the recorded scope is not valid'; return 1; }
  fm_task_copy_isolated "$copy" "$project" || { fm_slot_adopt_refuse not_isolated "$FM_TASK_COPY_REASON"; return 1; }
  common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { fm_slot_adopt_refuse repository_unreadable "$project"; return 1; }
  slot_common=$(git -C "$copy" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { fm_slot_adopt_refuse repository_unreadable "$copy"; return 1; }
  [ "$common" = "$slot_common" ] || { fm_slot_adopt_refuse repository_mismatch "$copy is not a checkout of $project's repository"; return 1; }
  real_copy=$(CDPATH='' cd -- "$copy" 2>/dev/null && pwd -P) || { fm_slot_adopt_refuse copy_unreadable "$copy"; return 1; }
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || { fm_slot_adopt_refuse manifest_missing "$manifest"; return 1; }
  verdict=$(fm_slot_adopt_verdict "$manifest" "$real_copy" "$branch" "$base" "${scope[@]}"
  ) || { fm_slot_adopt_refuse manifest_unreadable "$manifest"; return 1; }
  if [ "${verdict%%$'\t'*}" != ok ]; then
    fm_slot_adopt_refuse "${verdict%%$'\t'*}" "${verdict#*$'\t'}"
    return 1
  fi
  # The repository root is the manifest verdict's; the record check below has its own verdict variable so it can never
  # overwrite it.
  root=${verdict#*$'\t'}
  # The pointer must name the authoritative record and agree with the other one the provisioner keeps for this copy.
  records=$(fm_slot_record_paths "$project" "$real_copy") || { fm_slot_adopt_refuse repository_unreadable "$project"; return 1; }
  records_verdict=$(fm_slot_adopt_records "$manifest" "${records%%$'\n'*}" "${records#*$'\n'}") ||
    { fm_slot_adopt_refuse manifest_unreadable "$manifest"; return 1; }
  if [ "${records_verdict%%$'\t'*}" != ok ]; then
    fm_slot_adopt_refuse "${records_verdict%%$'\t'*}" "${records_verdict#*$'\t'}"
    return 1
  fi
  # The repository is judged by identity: the recorded root is the canonical root the provisioner records (the
  # parent of the common directory, which need not be a checkout) or a checkout of the same repository.
  if ! { [ "$(dirname "$common")" -ef "$root" ] ||
    [ "$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" = "$common" ]; }; then
    fm_slot_adopt_refuse repository_mismatch "the manifest's repository root $root belongs to another repository"
    return 1
  fi
  git_head=$(git -C "$copy" symbolic-ref -q HEAD 2>/dev/null) || git_head=
  if [ "$git_head" != "refs/heads/$branch" ]; then
    head_name=
    for marker in rebase-merge/head-name rebase-apply/head-name; do
      line=$(git -C "$copy" rev-parse --path-format=absolute --git-path "$marker" 2>/dev/null) || continue
      [ -f "$line" ] && head_name=$(cat "$line" 2>/dev/null) && break
    done
    [ "$head_name" = "refs/heads/$branch" ] || {
      fm_slot_adopt_refuse branch_not_checked_out "the copy is on ${git_head:-a detached HEAD}, not $branch, and no rebase of $branch is in progress"
      return 1
    }
  fi
  fm_slot_custody_check "$project" "$copy" "$id" "$meta" "$state" ||
    { fm_slot_adopt_refuse "$FM_SLOT_CUSTODY_REASON" "$FM_SLOT_CUSTODY_DETAIL"; return 1; }
  FM_SLOT_MANIFEST=$manifest
  FM_SLOT_BASE_SHA=$base
  FM_SLOT_BASE_REF=$ref
  FM_SLOT_ADOPT_ROOT=$root
  FM_SLOT_PROVISIONED=1
  FM_SLOT_ADOPTED=1
}

# A pool slot claim naming another task is a legitimate shared slot only when that task's own record, in this
# home or a registered one, names a copy strictly inside the slot that is not this task's copy.
fm_slot_adopt_sibling_claim() { # <slot> <copy> <state-dir>
  local slot=$1 copy=$2 state=$3 state_dir other path real
  [ -n "$FM_TREEHOUSE_SLOT_OWNER_ID" ] || return 1
  fm_local_firstmate_state_dirs "$state" || return 1
  for state_dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    other="$state_dir/$FM_TREEHOUSE_SLOT_OWNER_ID.meta"
    [ -f "$other" ] && [ ! -L "$other" ] || continue
    path=$(fm_meta_get "$other" worktree)
    real=$(fm_task_copy_canonical_dir "$path") || continue
    case "$real" in "$slot"/*) ;; *) continue ;; esac
    fm_task_copy_paths_overlap "$real" "$copy" && continue
    return 0
  done
  return 1
}

FM_SLOT_DRIFT_PY=$(cat <<'FMDRIFTPY'
import os
import subprocess
import sys

copy, base, branch = sys.argv[1:4]
scope = sys.argv[4:]
env = dict(os.environ, GIT_OPTIONAL_LOCKS="0")


def git(*args, ok=(0,)):
    proc = subprocess.run(["git", "-C", copy, *args], capture_output=True, stdin=subprocess.DEVNULL, env=env)
    if proc.returncode not in ok:
        raise RuntimeError("git %s exit %d" % (" ".join(args[:2]), proc.returncode))
    return proc


def names(raw):
    return [part for part in raw.split(b"\0") if part]


def in_scope(path):
    for item in scope:
        item = item.encode().rstrip(b"/")
        if path == item or path.startswith(item + b"/"):
            return True
    return False


def escape(path):
    out = []
    for byte in path:
        ch = chr(byte)
        if ch == "\\":
            out.append("\\\\")
        elif 0x20 <= byte < 0x7F:
            out.append(ch)
        else:
            out.append("\\x%02x" % byte)
    return "".join(out)


limits = []
proven = {}
status = {}
# The launch artifacts Firstmate itself wrote, from the task's wiring record (state/<id>.wiring-sha: "<sha> <rel> [merged]"):
# an ignored path or generated directory made only of those is not the task's drift.
recorded = set()
record_file = os.environ.get("FM_SLOT_DRIFT_WIRING", "")
if record_file and os.path.isfile(record_file):
    with open(record_file, "rb") as handle:
        for row in handle.read().splitlines():
            parts = row.split(None, 2)
            if len(parts) >= 2:
                recorded.add(parts[1])


def wiring_only(path):
    if path in recorded:
        return True
    full = os.path.join(os.fsencode(copy), path)
    if not os.path.isdir(full) or os.path.islink(full):
        return False
    found = False
    for base_dir, _dirs, files in os.walk(full):
        for name in files:
            found = True
            rel = os.path.relpath(os.path.join(base_dir, name), os.fsencode(copy))
            if rel not in recorded:
                return False
    return found


def add(path, *labels):
    if in_scope(path):
        return
    proven.setdefault(path, "proven")
    for label in labels:
        status.setdefault(path, set()).add(label)


def uncertain(path, *labels):
    if in_scope(path):
        return
    proven.setdefault(path, "uncertain")
    for label in labels:
        status.setdefault(path, set()).add(label)


# The default branch tip as the copy sees it, and the point the task forked from it.
tip = git("rev-parse", "--verify", "--quiet", "origin/main^{commit}", ok=(0, 1)).stdout.decode().strip()
head = git("rev-parse", "--verify", "HEAD").stdout.decode().strip()
heads = [head]
for marker in ("rebase-merge/orig-head", "rebase-apply/orig-head"):
    path = git("rev-parse", "--path-format=absolute", "--git-path", marker).stdout.decode().strip()
    if os.path.isfile(path):
        orig = open(path, encoding="utf-8").read().strip()
        if orig and orig not in heads:
            heads.append(orig)
shallow = git("rev-parse", "--is-shallow-repository").stdout.decode().strip() == "true"
for tip_head in heads:
    fork = ""
    if tip:
        fork = git("merge-base", tip, tip_head, ok=(0, 1)).stdout.decode().strip()
    known = bool(fork)
    if not known:
        fork = base
        limits.append("the default branch tip or the fork point is unavailable; the recorded base %s is the reference, so inherited upstream paths may be listed as uncertain" % base[:12])
    net = set(names(git("diff", "--no-renames", "-z", "--name-only", "--ignore-submodules=none", fork, tip_head).stdout))
    own = set()
    if known:
        # The task's own line: the commits on the first-parent chain, a merge counting only for the paths it authored
        # itself (the combined diff). A path that reaches HEAD only through a merged side branch, such as another task's
        # branch, is not established as this task's work, so it is listed uncertain, never proven (D3 R3).
        own |= set(names(git("log", "--first-parent", "--no-merges", "--no-renames", "--name-only", "-z", "--format=", tip_head, "--not", tip).stdout))
        for merge in git("rev-list", "--first-parent", "--merges", tip_head, "--not", tip).stdout.decode().split():
            own |= set(names(git("show", "--cc", "--name-only", "-z", "--format=", merge, ok=(0, 128)).stdout))
    for path in net:
        (add if known and path in own else uncertain)(path)
    if known:
        exclusive = set(names(git("log", "--cc", "--name-only", "-z", "--format=", tip_head, "--not", tip).stdout))
        for path in exclusive - net:
            (add if path in own else uncertain)(path, "reverted-to-base")
# What the branch's own reflog records the task committing counts as the task's work even when the default branch later
# absorbed and reverted it (the merge base then moves past it and no net diff remains). Pulls, merges, fast-forwards
# and rebase picks are not "commit" entries, so work that only came in from the default branch is not attributed here.
reflog = subprocess.run(["git", "-C", copy, "reflog", "show", "--format=%H%x09%gs", "refs/heads/" + branch],
                        capture_output=True, stdin=subprocess.DEVNULL, env=env)
if reflog.returncode != 0:
    limits.append("the task branch reflog cannot be read, so a change the default branch absorbed and reverted may be missing from the list")
else:
    seen_commits = set()
    for row in reflog.stdout.decode("utf-8", "replace").splitlines():
        sha, _, subject = row.partition("\t")
        if not (subject.startswith("commit") or subject.startswith("cherry-pick")) or sha in seen_commits:
            continue
        seen_commits.add(sha)
        shown = git("show", "--cc", "--name-only", "-z", "--format=", sha, ok=(0, 128))
        for path in names(shown.stdout):
            if in_scope(path):
                continue
            now = git("rev-parse", "--verify", "--quiet", "HEAD:" + os.fsdecode(path), ok=(0, 1)).stdout.strip()
            then = git("rev-parse", "--verify", "--quiet", base + ":" + os.fsdecode(path), ok=(0, 1)).stdout.strip()
            add(path, *(("reverted-to-base",) if now == then else ()))
if shallow:
    limits.append("the copy is a shallow clone, so history before its cut-off cannot show who changed a path; the list may be incomplete")
# The working copy: modified, deleted, untracked (every file), renamed or copied (both ends), and ignored.
raw = git("-c", "core.fileMode=true", "status", "--porcelain=v1", "-z", "--untracked-files=all",
          "--ignore-submodules=none", "--ignored=traditional").stdout.split(b"\0")
i = 0
while i < len(raw):
    entry = raw[i]
    i += 1
    if len(entry) < 4:
        continue
    code, path = entry[:2], entry[3:]
    if code[:1] in b"RC":
        add(path)
        if i < len(raw) and raw[i]:
            add(raw[i])
        i += 1
        continue
    if code == b"!!":
        if wiring_only(path.rstrip(b"/")):
            continue
        if path.endswith(b"/"):
            uncertain(path.rstrip(b"/"), "ignored", "generated")
        else:
            uncertain(path, "ignored")
    else:
        add(path.rstrip(b"/") if code == b"??" and path.endswith(b"/") else path)
# Tracked paths that status cannot report (assume-unchanged, skip-worktree) whose existence, type, mode or bytes differ.
for flagged in names(git("ls-files", "-v", "-z").stdout):
    tag, path = flagged[:1], flagged[2:]
    if not (tag.islower() or tag == b"S"):
        continue
    full = os.path.join(os.fsencode(copy), path)
    if not os.path.lexists(full):
        # An assume-unchanged path that is gone was deleted by the task, which status cannot show; a skip-worktree path
        # that is absent is what sparse checkout leaves unmaterialized on purpose, so it is not a difference.
        if tag.islower() and tag != b"s":
            add(path)
        continue
    entry = git("ls-files", "-s", "-z", "--", os.fsdecode(path)).stdout.split(b"\0")[0].split()
    if len(entry) < 2:
        continue
    mode = entry[0].decode()
    if os.path.islink(full):
        blob = subprocess.run(["git", "-C", copy, "hash-object", "--stdin"], input=os.readlink(full), capture_output=True, env=env)
        differs = mode != "120000" or blob.stdout.decode().strip() != entry[1].decode()
    else:
        blob = subprocess.run(["git", "-C", copy, "hash-object", "--", os.fsdecode(path)], capture_output=True, env=env)
        want_mode = "100755" if os.stat(full).st_mode & 0o100 else "100644"
        differs = blob.stdout.decode().strip() != entry[1].decode() or want_mode != mode
    if differs:
        add(path)
print("drift-count\t%d" % len(proven))
for path in sorted(proven):
    labels = [proven[path]] + sorted(status.get(path, ()))
    print("drift\t%s\t%s" % (",".join(labels), escape(path)))
for limit in dict.fromkeys(limits):
    print("limitation\t" + limit)
FMDRIFTPY
)

# The out-of-scope paths this task's own work changed, one labelled path per line, with the standing residuals.
# Reads only; the recorded scope, manifest and record are never edited by what this reports.
fm_slot_drift_report() { # <copy> <task-id> <branch> <base-sha> <owned-path>...
  local copy=$1 id=$2 branch=$3 base=$4 out count line
  shift 4
  # state/<id>.wiring-sha names the launch artifacts Firstmate wrote, so they are not reported as the task's drift. Callers
  # (fm-control.sh and fm-spawn.sh) set STATE; with no STATE no record is read and nothing is filtered.
  out=$(FM_SLOT_DRIFT_WIRING="${STATE:-}/$id.wiring-sha" python3 -c "$FM_SLOT_DRIFT_PY" "$copy" "$base" "$branch" "$@" 2>&1) || {
    echo "relaunch drift report for $id: could not be produced ($(printf '%s' "$out" | tail -n 1)); this is a limitation of the report, not a statement that the task stayed in scope" >&2
    return 0
  }
  count=$(printf '%s\n' "$out" | sed -n 's/^drift-count\t//p')
  if [ "${count:-0}" -eq 0 ]; then
    echo "relaunch drift report for $id: no out-of-scope path changed by this task's own work; the recorded scope is unchanged" >&2
  else
    echo "relaunch drift report for $id: $count out-of-scope path(s) changed by this task's own work; the recorded scope is unchanged (label = provenance[,status]; unusual bytes in a path are written as a doubled backslash or a backslash, x and two hex digits)" >&2
    printf '%s\n' "$out" | while IFS= read -r line; do
      case "$line" in drift$'\t'*) printf '  drift: %s\n' "${line#drift$'\t'}" | tr '\t' ' ' >&2 ;; esac
    done
  fi
  printf '%s\n' "$out" | while IFS= read -r line; do
    case "$line" in limitation$'\t'*) printf '  limitation: %s\n' "${line#limitation$'\t'}" >&2 ;; esac
  done
  echo "  a relaunch is not a new scope declaration: Vernant's push-time owned_paths gate stays the enforcement point, and a pool slot another task claims refuses the relaunch by name unless that task's record places its copy inside the slot" >&2
}

# The launch contract for a worker started on an adopted slot: continue in place.
fm_slot_contract_adopted() { # <branch>
  cat <<EOF

# Current assigned-copy lifecycle contract
This is a relaunch into the exact assigned copy and branch \`$1\` that this task already holds, with its slot manifest recorded.
This section supersedes earlier branch-creation or clean-base reset instructions: verify isolation and the existing branch, then continue in place; do not create the branch again or reset it, and keep every uncommitted change.
Do not create another worktree inside this copy, delete or edit the lifecycle manifest, or widen the recorded scope.
Paths you changed outside the recorded scope stay your own work and are reported to firstmate, and the push-time owned_paths check decides what may be pushed; a refused push or a wider scope must return to firstmate with the exact refusal, never to a nested-worktree fallback.
EOF
}

# --- The slot move: prove the copy idle, then move it with git, then check what moved ----------
# A pooled slot is advanced only by `git merge --ff-only`, which git itself refuses unless HEAD is an
# ancestor of the target and which stops before it overwrites a tracked or untracked file. Nothing in
# this file or in bin/fm-spawn.sh forces, discards or removes anything in a slot.
# Two steps, kept apart on purpose:
#   fm_slot_prove_idle  reads the copy and writes nothing to it: not a checkout, a ref, a fetch ref or
#                       a temp file. It is the only code that may return FM_SLOT_SKIP_RC. The caller
#                       holds the shared project lock (the fresh-spawn path takes it before it
#                       acquires a copy), so the snapshot and the move see one copy.
#   fm_slot_apply_move  moves a copy the proof passed, with hooks off, re-reads it, and compares.
#                       It compares this copy's own refs exactly: HEAD, the branch it had at the first
#                       snapshot, the branch the move advances, and the anchor this spawn's own
#                       preparation created. Other refs in the namespace the pool shares are recorded
#                       as context in a refusal or skip, never a refusal. A refusal writes no
#                       file, runs no checkout and undoes nothing. A git refusal after the preparation
#                       wrote anything is a failure (return 1), never a skip, and so is any other
#                       difference.
# A copy is proven idle only when ONE snapshot shows: HEAD and its branch readable, the tree clean
# (tracked, staged and untracked), no process with its working directory in it, no git worktree
# lock, no live lease or recent contention row, no ignored file at a path the target tracks, and no index flag
# (assume-unchanged, skip-worktree) on a tracked file or inside any initialized submodule, however deep.
# Every unreadable input is a doubt. A known state skips the copy (FM_SLOT_SKIP_RC); an unknown refuses the spawn (FM_SLOT_REFUSE_RC).
FM_SLOT_SKIP_RC=20
# Returned for a doubt that is an UNKNOWN (could not tell): the whole spawn is refused, nothing is skipped past (rule Q).
FM_SLOT_REFUSE_RC=21
FM_SLOT_SKIP_REASON=
FM_SLOT_PROOF_SNAPSHOT=
FM_SLOT_PROOF_DIR=
FM_SLOT_PREPARE_DETACHED=0

fm_slot_skip() { # <slot> <reason-code> <detail>
  FM_SLOT_SKIP_REASON=$2
  # A check that fails AFTER this spawn prepared the copy (a detach, an anchor ref) is a failure, never a skip: something was
  # written to it. It names what was written and leaves the copy exactly as it is (Main 1925 F1, Main 1939 N-2).
  if [ "${FM_SLOT_PREPARED:-0}" = 1 ]; then
    local written=
    [ -z "${FM_SLOT_EXPECT_REFS:-}" ] || written="the anchor ${FM_SLOT_EXPECT_REFS%%=*} was created; "
    [ "${FM_SLOT_PREPARE_DETACHED:-0}" != 1 ] || written="${written}the copy was detached from its branch; "
    echo "error: pooled copy '$1' failed a check ($2: $3) after this spawn had prepared it (${written}it is $(fm_slot_where "$1")); nothing is switched back, the copy is left exactly as it is, and no worker is admitted" >&2
    return 1
  fi
  echo "skip: pooled copy '$1' was not moved ($2): $3" >&2
  if fm_slot_skip_is_known "$2"; then return "$FM_SLOT_SKIP_RC"; fi
  return "$FM_SLOT_REFUSE_RC"
}

# Rule Q: a copy may be skipped, and another taken, only when the doubt is a KNOWN state a read-only proof established
# (the tree is dirty, a holder is there, an ignored file is in the way, HEAD is not an ancestor, a stale submodule). Any
# reason that means "could not tell" refuses the whole spawn instead: it is never "no holder" and never "clean".
fm_slot_skip_is_known() { # <reason-code>
  case "$1" in
    dirty_tree|live_holder|ignored_collision|not_fast_forward|head_not_target|stale_submodule) return 0 ;;
  esac
  return 1
}

# One embedded program with eight read-only modes. It runs git and lsof through PATH, so a failing
# tool fails closed (exit 3, the reason on stderr).
FM_SLOT_PROBE_PY=$(cat <<'FMPROBEPY'
import datetime, hashlib, json, os, stat as stat_mod, subprocess, sys, time, unicodedata

def fail(text):
    sys.stderr.write(text + "\n")
    sys.exit(3)

def git(slot, *args, allow=(0,)):
    try:
        proc = subprocess.run(["git", "-C", slot] + list(args), capture_output=True, stdin=subprocess.DEVNULL,
                              env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"))
    except OSError as exc:
        fail("git cannot run: %s" % exc)
    if proc.returncode not in allow:
        fail("git %s exit %d: %s" % (" ".join(args[:3]), proc.returncode, proc.stderr.decode("utf-8", "replace").strip()[:200]))
    return proc

def enc(path):
    return path.decode("utf-8", "surrogateescape") if isinstance(path, bytes) else path

# ---- snapshot: HEAD, branch, every ref, the status (submodules counted, hidden index flags checked), and every
# ignored entry git lists (a wholly ignored directory is one entry) by its identity: type, size, mtime and inode, a
# symlink also by its target. Content is read only for an entry at or under a path the target tracks. Anything that
# cannot be read fails the whole snapshot.
def head_and_refs(slot):
    head = git(slot, "rev-parse", "--verify", "HEAD").stdout.decode().strip()
    sym = git(slot, "symbolic-ref", "-q", "HEAD", allow=(0, 1))
    symref = sym.stdout.decode().strip() if sym.returncode == 0 else "detached"
    refs = {}
    # A symbolic ref is recorded with its target name, so a retarget between two refs at the same commit is a difference.
    for line in git(slot, "for-each-ref", "--format=%(refname)%09%(objectname)%09%(symref)").stdout.decode("utf-8", "replace").splitlines():
        name, sha, target = (line.split("\t") + ["", ""])[:3]
        refs[name] = sha + (" -> " + target if target else "")
    return head, symref, refs

def blob_of(slot, rel):
    """The blob id git would store for the worktree file (symlinks by their target text)."""
    path = os.path.join(slot, rel)
    if os.path.islink(path):
        proc = subprocess.run(["git", "-C", slot, "hash-object", "--stdin"], input=os.readlink(path).encode("utf-8", "surrogateescape"),
                              capture_output=True, env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"))
    else:
        proc = subprocess.run(["git", "-C", slot, "hash-object", "--", rel], capture_output=True, stdin=subprocess.DEVNULL,
                              env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"))
    if proc.returncode != 0:
        fail("hash-object %r exit %d" % (rel, proc.returncode))
    return proc.stdout.decode().strip()

def worktree_mode(path):
    """The mode git would record for the worktree file: 120000 a symlink, 100755 an executable, 100644 otherwise."""
    st = os.lstat(path)
    if stat_mod.S_ISLNK(st.st_mode):
        return "120000"
    return "100755" if st.st_mode & 0o100 else "100644"

def hidden_changes(slot):
    """Tracked files that status cannot report (assume-unchanged, skip-worktree) but whose bytes differ from the index."""
    flagged = {}
    for raw in git(slot, "ls-files", "-v", "-z").stdout.split(b"\0"):
        if not raw:
            continue
        tag, path = raw[:1].decode(), raw[2:]
        if tag.islower() or tag == "S":
            flagged[enc(path)] = tag
    if not flagged:
        return []
    staged = {}
    for raw in git(slot, "ls-files", "-s", "-z").stdout.split(b"\0"):
        if not raw:
            continue
        meta, _, path = raw.partition(b"\t")
        mode, sha = meta.split(b" ")[0:2]
        staged[enc(path)] = (mode.decode(), sha.decode())
    out = []
    for rel, tag in sorted(flagged.items()):
        mode, sha = staged.get(rel, ("", ""))
        if mode == "160000":
            out.append(" M %s (submodule entry hidden by an index flag)" % rel)
            continue
        path = os.path.join(slot, rel)
        if not os.path.lexists(path):
            if tag != "S":
                out.append(" D %s (hidden by an index flag)" % rel)
            continue
        if blob_of(slot, rel) != sha:
            out.append(" M %s (hidden by an index flag)" % rel)
        elif worktree_mode(path) != mode:
            out.append(" M %s (hidden by an index flag: mode)" % rel)
    return out

def nested_flags(slot, prefix=""):
    """An index flag (assume-unchanged, skip-worktree) inside any initialized submodule, however deep, is doubt: it
    can hide a tracked edit that no status shows. A submodule whose index cannot be read fails the whole snapshot."""
    found = []
    for raw in git(slot, "ls-files", "-s", "-z").stdout.split(b"\0"):
        if not raw:
            continue
        meta, _, path = raw.partition(b"\t")
        if meta.split(b" ")[0] != b"160000":
            continue
        rel = enc(path)
        sub = os.path.join(slot, rel)
        if not os.path.lexists(os.path.join(sub, ".git")):
            continue
        for entry in git(sub, "ls-files", "-v", "-z").stdout.split(b"\0"):
            if entry and (entry[:1].decode().islower() or entry[:1] == b"S"):
                found.append(" M %s%s/%s (hidden by an index flag inside a submodule)" % (prefix, rel, enc(entry[2:])))
        found += nested_flags(sub, prefix + rel + "/")
    return found

def submodule_heads(slot, prefix=""):
    """The HEAD of every initialized submodule, however deep, keyed by its path from the root of the copy."""
    heads = {}
    for raw in git(slot, "ls-files", "-s", "-z").stdout.split(b"\0"):
        if not raw:
            continue
        meta, _, path = raw.partition(b"\t")
        if meta.split(b" ")[0] != b"160000":
            continue
        rel = enc(path)
        sub = os.path.join(slot, rel)
        if not os.path.lexists(os.path.join(sub, ".git")):
            continue
        heads[prefix + rel] = git(sub, "rev-parse", "--verify", "HEAD").stdout.decode().strip()
        heads.update(submodule_heads(sub, prefix + rel + "/"))
    return heads

def submodule_pin_only(slot, entry, before_heads):
    """A ' M <path>' entry for a gitlink whose own worktree is clean: only the pin differs (a move that changes a pin)."""
    if not entry.startswith(" M "):
        return False
    path = entry[3:]
    stage = git(slot, "ls-files", "-s", "--", path).stdout.decode()
    if not stage.startswith("160000"):
        return False
    # Only the pin changed when the own HEAD of the submodule is still the commit it had when the copy was proven. A commit made
    # in it since then is a change, not the expected pin.
    now = git(os.path.join(slot, path), "rev-parse", "--verify", "HEAD").stdout.decode().strip()
    if before_heads.get(path) != now:
        return False
    inner = subprocess.run(["git", "-C", os.path.join(slot, path), "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none"],
                           capture_output=True, stdin=subprocess.DEVNULL, env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"))
    if inner.returncode != 0:
        fail("submodule %r status exit %d" % (path, inner.returncode))
    return not inner.stdout.strip(b"\0 \n")

# The path-comparison settings and the tracked paths of the target, written by fm_slot_target_paths into one directory.
def path_key(paths):
    settings = ""
    if paths and os.path.exists(os.path.join(paths, "settings")):
        settings = open(os.path.join(paths, "settings"), encoding="utf-8", errors="replace").read()
    cfg = dict(line.split(" ", 1) for line in settings.splitlines() if " " in line)
    ignorecase = cfg.get("core.ignorecase") == "true"
    precompose = cfg.get("core.precomposeunicode") == "true"
    def key(text):
        if precompose:
            text = unicodedata.normalize("NFC", text)
        return text.casefold() if ignorecase else text
    return key

def tracked_paths(paths, key):
    """The tracked paths of the target as compared keys, or None when no target was listed."""
    if not paths or not os.path.exists(os.path.join(paths, "tracked")):
        return None
    return set(key(enc(p)) for p in open(os.path.join(paths, "tracked"), "rb").read().split(b"\0") if p)

def at_or_under(folded, written):
    parts = folded.split("/")
    return folded in written or any("/".join(parts[:i]) in written for i in range(1, len(parts)))

def ignored_entries(slot):
    return [raw for raw in git(slot, "ls-files", "-o", "-i", "--exclude-standard", "--directory", "-z").stdout.split(b"\0") if raw]

def snapshot(slot, out, after_move="0", before="", paths=""):
    head, symref, refs = head_and_refs(slot)
    status = [enc(e) for e in git(slot, "-c", "core.quotePath=false", "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none").stdout.split(b"\0") if e]
    heads = submodule_heads(slot)
    if after_move == "1":
        before_heads = load(before).get("subheads", {})
        status = [e for e in status if not submodule_pin_only(slot, e, before_heads)]
    status += hidden_changes(slot)
    status += nested_flags(slot)
    ignored = {}
    key = path_key(paths)
    written = tracked_paths(paths, key)
    for raw in ignored_entries(slot):
        path = os.path.join(os.fsencode(slot), raw.rstrip(b"/"))
        try:
            st = os.lstat(path)
            if stat_mod.S_ISLNK(st.st_mode):
                kind, extra = "link", os.readlink(path).__repr__()
            elif stat_mod.S_ISDIR(st.st_mode):
                kind, extra = "dir", ""
            elif stat_mod.S_ISREG(st.st_mode):
                kind, extra = "file", ""
                if written is not None and at_or_under(key(enc(raw).rstrip("/")), written):
                    digest = hashlib.sha256()
                    with open(path, "rb") as handle:
                        for chunk in iter(lambda: handle.read(1 << 20), b""):
                            digest.update(chunk)
                    extra = digest.hexdigest()
            else:
                kind, extra = "special", ""
        except OSError as exc:
            fail("ignored entry %r cannot be read: %s" % (enc(raw), exc))
        ignored[enc(raw)] = [kind, st.st_size, st.st_mtime_ns, st.st_ino, extra]
    # The refs are read LAST here, and FIRST in the read after a move, so the window in which another writer's
    # ref change can look like ours is the move itself.
    head, symref, refs = head_and_refs(slot)
    with open(out, "w", encoding="utf-8") as handle:
        json.dump({"head": head, "symref": symref, "refs": refs, "status": status, "ignored": ignored, "subheads": heads}, handle, sort_keys=True)

def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)

# ---- compare two snapshots. same: nothing of this copy differs. moved <target> <attached-ref>: HEAD is the target, the
# attached branch (if any) is the target, the other own refs of this copy are as they were, the status is clean, and every
# ignored entry is exactly as it was. The own refs of this copy are the branch it had at the first snapshot, the branch the
# move advances, and the anchors its preparation creates. Every other ref lives in the namespace the pool shares, where
# other spawns and workers write: a change there is printed as context, never a refusal.
def compare(before, after, mode, target, attached, detached="", expect=""):
    a, b, diffs = load(before), load(after), []
    # expect: "<ref>=<sha>" entries, the exact refs the preparation of this operation creates: absent before, exactly <sha> after.
    made = dict(e.split("=", 1) for e in expect.split() if "=" in e)
    own = a["symref"] if a["symref"].startswith("refs/") else ""
    if detached == "1":
        a["symref"] = "detached"
    watched = set(made) | set(r for r in (own, attached) if r)
    want = dict((r, a["refs"][r]) for r in watched if r in a["refs"])
    if mode != "same" and attached:
        want[attached] = target
    for ref, sha in made.items():
        if ref in a["refs"]:
            # Already there before the proof: it must be exactly as it was.
            continue
        if b["refs"].get(ref) != sha:
            diffs.append("the expected anchor %s was not created at %s (it is %s)" % (ref, sha, b["refs"].get(ref, "missing")))
            watched.discard(ref)
        else:
            want[ref] = sha
    mine = sorted(r for r in watched if want.get(r) != b["refs"].get(r))
    others = sorted(k for k in set(a["refs"]) | set(b["refs"]) if k not in watched and a["refs"].get(k) != b["refs"].get(k))
    if mode == "same":
        for key in ("head", "symref", "status", "ignored"):
            if a[key] != b[key]:
                diffs.append("%s changed" % key)
        if mine:
            diffs.append("refs changed: %s" % ", ".join(mine[:3]))
    else:
        if b["head"] != target:
            diffs.append("HEAD is %s, not %s" % (b["head"], target))
        if b["symref"] != a["symref"]:
            diffs.append("the checked-out branch changed from %s to %s" % (a["symref"], b["symref"]))
        if mine:
            diffs.append("refs changed beyond the move: %s" % ", ".join(mine[:3]))
        if b["status"]:
            diffs.append("the tree is not clean after the move: %s" % "; ".join(b["status"][:3]))
        if a["ignored"] != b["ignored"]:
            changed = sorted(k for k in set(a["ignored"]) | set(b["ignored"]) if a["ignored"].get(k) != b["ignored"].get(k))
            diffs.append("ignored files changed: %s" % ", ".join(changed[:3]))
    context = ""
    if others:
        context = "other refs in the shared namespace changed (context, not a refusal): %s" % ", ".join(others[:5])
    if diffs:
        print("; ".join(diffs + ([context] if context else [])))
        sys.exit(1)
    if context:
        print(context)

# ---- collide: ignored entries at a path the target tracks (the same path, below it, or above it). The entries come from a
# snapshot (the proof) or from a fresh listing of the slot (teardown, before a skipped copy is returned).
def collide(entries, paths):
    key = path_key(paths)
    written = tracked_paths(paths, key)
    if written is None:
        fail("the tracked paths of the target were not listed")
    below = set()
    for path in written:
        parts = path.split("/")
        for i in range(1, len(parts)):
            below.add("/".join(parts[:i]))
    found = []
    for entry in entries:
        folded = key(entry.rstrip("/"))
        if at_or_under(folded, written) or folded in below:
            found.append(entry)
    if found:
        print(", ".join(sorted(found)[:3]).replace("\n", "\\n"))

# ---- processes: parent, name and start time from the kernel, never from ps.
def proc_info(pid):
    try:
        if sys.platform == "darwin":
            import ctypes, ctypes.util, struct
            lib = ctypes.CDLL(ctypes.util.find_library("proc") or "/usr/lib/libproc.dylib")
            buf = ctypes.create_string_buffer(136)
            if lib.proc_pidinfo(pid, 3, 0, buf, 136) != 136:
                return None
            ppid = struct.unpack_from("<I", buf.raw, 16)[0]
            comm = buf.raw[48:64].split(b"\0")[0].decode("utf-8", "replace")
            sec, usec = struct.unpack_from("<QQ", buf.raw, 120)
            return ppid, comm, sec + usec / 1e6
        with open("/proc/%d/stat" % pid) as handle:
            raw = handle.read()
        comm = raw[raw.index("(") + 1:raw.rindex(")")]
        fields = raw.rsplit(")", 1)[1].split()
        with open("/proc/stat") as handle:
            boot = [int(line.split()[1]) for line in handle if line.startswith("btime ")][0]
        return int(fields[1]), comm, boot + int(fields[19]) / os.sysconf("SC_CLK_TCK")
    except Exception:
        return None

def exe_argv0(pid):
    """The full executable path, argv[0] and the whole argv joined by spaces of <pid> from the kernel, or None when any
    of them cannot be read."""
    try:
        if sys.platform == "darwin":
            import ctypes, ctypes.util, struct
            lib = ctypes.CDLL(ctypes.util.find_library("proc") or "/usr/lib/libproc.dylib")
            buf = ctypes.create_string_buffer(4096)
            if lib.proc_pidpath(pid, buf, 4096) <= 0:
                return None
            path = buf.value
            libc = ctypes.CDLL(ctypes.util.find_library("c"))
            mib = (ctypes.c_int * 3)(1, 49, pid)
            size = ctypes.c_size_t(0)
            if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0 or size.value < 4:
                return None
            raw = ctypes.create_string_buffer(size.value)
            if libc.sysctl(mib, 3, raw, ctypes.byref(size), None, 0) != 0:
                return None
            data = raw.raw[:size.value]
            argc = struct.unpack_from("<i", data, 0)[0]
            rest = data[4:]
            rest = rest[rest.index(b"\0"):].lstrip(b"\0")
            argv = rest.split(b"\0")[:argc] if argc > 0 else []
            if len(argv) != max(argc, 0):
                return None
        else:
            path = os.fsencode(os.readlink("/proc/%d/exe" % pid))
            with open("/proc/%d/cmdline" % pid, "rb") as handle:
                argv = handle.read().split(b"\0")
            if argv and argv[-1] == b"":
                argv.pop()
    except Exception:
        return None
    clean = lambda raw: raw.decode("utf-8", "replace").replace("\x1f", " ").replace("\n", " ")
    return clean(path), clean(argv[0] if argv else b""), clean(b" ".join(argv))

def chain(pid):
    out, cur = [], pid
    for _ in range(64):
        info = proc_info(cur)
        if info is None:
            return out, False
        out.append((cur, info))
        if info[0] <= 1 or info[0] == cur:
            return out, True
        cur = info[0]
    return out, True

# A process is the spawn's own acquisition only when it is PROVEN so: its parent chain holds a `treehouse` launcher that
# started after the spawn began and, when the backend names the pane's shell, that launcher runs under that pane. A
# process that merely shares a parent with the pane, started earlier, or has no launcher above it is somebody else's.
def is_own(pid, pane, began):
    launcher = False
    pane_seen = not pane
    cur = pid
    for _ in range(64):
        info = proc_info(cur)
        if info is None:
            return False
        if os.path.basename(info[1]) == "treehouse" and info[2] is not None and info[2] >= began:
            launcher = True
        if cur == pane:
            pane_seen = True
        if launcher and pane_seen:
            return True
        if info[0] <= 1 or info[0] == cur:
            return False
        cur = info[0]
    return False

def holders(slot, real, spawn, common, governed, pane, endpoint="", endpoint_start=""):
    me = os.getpid()
    try:
        spawn = int(spawn)
        pane = int(pane) if pane else 0
        endpoint = int(endpoint) if endpoint else 0
    except ValueError:
        fail("the spawn, pane or endpoint pid is not a number")
    began = (proc_info(spawn) or (0, "", None))[2]
    if began is None:
        fail("the spawn's own start time cannot be read")
    # A relaunch names the root of its own lineage: the pane shell of the recorded endpoint, by pid and start time.
    if endpoint:
        info = proc_info(endpoint)
        try:
            want = float(endpoint_start)
        except ValueError:
            fail("the recorded endpoint (pid %d) has no readable start time" % endpoint)
        if info is None or info[2] is None or abs(info[2] - want) > 0.001:
            fail("the recorded endpoint (pid %d) is not the process that was recorded: its start time does not match" % endpoint)
    try:
        proc = subprocess.run(["lsof", "-n", "-P", "-w", "-d", "cwd", "-F", "pcn"], capture_output=True, text=True, stdin=subprocess.DEVNULL)
    except OSError as exc:
        fail("lsof cannot run: %s" % exc)
    if proc.returncode != 0:
        fail("lsof exit %d: %s" % (proc.returncode, proc.stderr.strip()[:300]))
    rows, cur = {}, None
    for line in proc.stdout.split("\n"):
        if not line:
            continue
        tag, value = line[0], line[1:]
        if tag == "p":
            try:
                cur = int(value)
            except ValueError:
                fail("lsof printed an unreadable process row")
            rows[cur] = {"cmd": "", "cwd": None}
        elif cur is None:
            fail("lsof printed a row before any process")
        elif tag == "c":
            rows[cur]["cmd"] = value
        elif tag == "n":
            rows[cur]["cwd"] = value
    inside = (slot.rstrip("/"), real.rstrip("/"))
    for pid, row in sorted(rows.items()):
        cwd = row["cwd"]
        if cwd == "":
            cwd = None  # an empty working directory names nowhere: unknown, never "outside the slot"
        if pid == me:
            continue
        if cwd is not None and not any(cwd == base or cwd.startswith(base + "/") for base in inside):
            continue
        # Inside the tree rooted at the recorded endpoint: the own lineage of this task. The pid, executable path, argv0
        # and joined argv of each process on the way up are printed (a T row, fields split by 0x1f) so the caller refuses
        # an agent; a chain, path or argv that cannot be read is unknown.
        if cwd is not None and endpoint:
            path, complete = chain(pid)
            pids = [p for p, _ in path]
            if endpoint in pids:
                fields = [str(pid)]
                for member in pids[:pids.index(endpoint) + 1]:
                    found = exe_argv0(member)
                    if found is None:
                        print("U\tthe executable or argv of a process (pid %d) in the recorded endpoint tree cannot be read" % member)
                        return
                    fields += [str(member)] + list(found)
                print("T\t" + "\x1f".join(fields))
                continue
            if not complete:
                print("U\tthe parent chain of a live process (pid %d, %s) in the slot cannot be read" % (pid, row["cmd"]))
                return
        # An lsof row with no working directory proves nothing about where the process is: it is never excused.
        if cwd is not None and is_own(pid, pane, began):
            continue
        if cwd is None:
            print("U\ta live process (pid %d, %s) has no readable working directory in the lsof listing" % (pid, row["cmd"]))
        else:
            print("H\ta live process (pid %d, %s) has its working directory in the slot" % (pid, row["cmd"]))
        return
    if governed != "1":
        return
    store = os.path.join(common, "vernant-worktree-leases")
    now = time.time()
    def epoch(value):
        parsed = datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=datetime.timezone.utc)
        return parsed.timestamp()
    def present(path):
        try:
            os.lstat(path)
        except FileNotFoundError:
            return False
        except OSError as exc:
            fail("%s: %s" % (os.path.basename(path), exc))
        return True
    for path in sorted({slot, real}):
        name = "lease-" + hashlib.sha256(("worktree:" + path).encode()).hexdigest()[:16] + ".json"
        file = os.path.join(store, name)
        if not present(file):
            continue
        try:
            lease = json.loads(open(file, encoding="utf-8").read())
            if not isinstance(lease, dict):
                raise ValueError("not a JSON object")
        except (OSError, ValueError) as exc:
            fail("%s: %s" % (name, exc))
        if lease.get("status") == "released":
            continue
        pid = lease.get("owner_pid")
        if isinstance(pid, int) and not isinstance(pid, bool) and pid > 0:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                continue
            except PermissionError:
                pass
            print("H\ta live lease is held by %s (pid %d)" % (lease.get("owner_id"), pid))
            return
        try:
            expired = epoch(lease["expires_at_iso"]) <= now
        except (KeyError, ValueError):
            fail("%s: the holder cannot be probed and the lease has no readable expiry" % name)
        if not expired:
            fail("%s: the holder cannot be probed and the lease has not expired" % name)
    file = os.path.join(store, "contention.jsonl")
    if present(file):
        try:
            text = open(file, encoding="utf-8", errors="replace").read()
        except OSError as exc:
            fail("contention.jsonl: %s" % exc)
        hits = 0
        for line in text.splitlines():
            if not line.strip():
                continue
            try:
                row = json.loads(line)
                tree, ts = row["worktree_id"], row["ts_iso"]
                if not isinstance(tree, str) or not isinstance(ts, str):
                    raise ValueError("bad field")
                age = max(0.0, now - epoch(ts))
            except (ValueError, KeyError, TypeError):
                print("H\ta contention row cannot be read, so it counts as held")
                return
            if os.path.realpath(tree) not in (real, os.path.realpath(slot)) and tree not in (slot, real):
                continue
            if age <= 24 * 60 * 60:
                hits += 1
        if hits:
            print("H\t%d co-tenant contention row(s) for this slot within 24 hours" % hits)

mode, args = sys.argv[1], sys.argv[2:]
if mode == "snapshot":
    snapshot(*args)
elif mode == "compare":
    compare(*args)
elif mode == "collide":
    collide(list(load(args[0])["ignored"]), args[1])
elif mode == "collide-live":
    collide([enc(raw) for raw in ignored_entries(args[0])], args[1])
elif mode == "holders":
    holders(*args)
elif mode == "hidden":
    # Tracked work hidden by an index flag, at the top level and inside every initialized submodule. One entry per line.
    found = hidden_changes(args[0]) + nested_flags(args[0])
    print("\n".join(found))
elif mode == "start":
    info = proc_info(int(args[0])) if args[0].isdigit() else None
    if info is None or info[2] is None:
        fail("the start time of pid %s cannot be read" % args[0])
    print(repr(info[2]))
elif mode == "field":
    value = load(args[0])[args[1]]
    print(value if isinstance(value, str) else "\n".join(value))
FMPROBEPY
)

fm_slot_probe() { python3 -I -c "$FM_SLOT_PROBE_PY" "$@"; }

# fm_slot_snapshot <slot> <out-file> [<after-move 0|1> <before-file> <paths-dir>]: fails (nonzero) when any read fails.
# <paths-dir> holds what fm_slot_target_paths wrote; an ignored file at or under a path listed there is read for its content.
fm_slot_snapshot() { fm_slot_probe snapshot "$1" "$2" "${3:-0}" "${4:-}" "${5:-}" 2>&1; }

# fm_slot_target_paths <slot> <commit> <dir>: writes <dir>/tracked (the paths <commit> tracks) and <dir>/settings (the
# path-comparison settings of the slot: core.ignorecase, core.precomposeunicode). Nonzero when either cannot be read.
fm_slot_target_paths() {
  local rc=0
  git -C "$1" config --bool --get-regexp '^core\.(ignorecase|precomposeunicode)$' >"$3/settings" 2>/dev/null || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 1 ] || return 1
  git -C "$1" ls-tree -r --name-only -z "$2" -- >"$3/tracked" 2>/dev/null
}

# fm_slot_ignored_collisions <slot> <commit>: prints the ignored entries of the slot that sit at a path <commit> tracks,
# inside one or above one (the same comparison the proof makes). Nonzero when the listing or the comparison cannot run.
fm_slot_ignored_collisions() {
  local dir out rc=0
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-slot-collide.XXXXXX" 2>/dev/null) || return 1
  if fm_slot_target_paths "$1" "$2" "$dir"; then
    out=$(fm_slot_probe collide-live "$1" "$dir" 2>&1) || rc=$?
  else
    rc=1
  fi
  rm -rf -- "$dir"
  [ "$rc" = 0 ] || return 1
  printf '%s' "$out"
}

# fm_slot_hidden_work <slot>: prints tracked work hidden by an index flag (assume-unchanged, skip-worktree), by blob or by
# mode, at the top level and inside every initialized submodule. Returns nonzero when it cannot tell. The same function
# the proof uses; bin/fm-teardown.sh calls it before it releases a skipped copy (Main 1886 N1).
fm_slot_hidden_work() { fm_slot_probe hidden "$1" 2>&1; }

# fm_slot_pool_rows_valid <json>: a pool listing is trusted only when it is an array and EVERY row is an object with a path
# that is a nonempty absolute string with no NUL. One row that fails means the holder of any copy is unknown (Main 1886 N7).
fm_slot_pool_rows_valid() {
  jq -e 'type == "array" and all(.[]; type == "object" and ((.path // null | type) == "string") and (.path | length > 0)
    and (.path | startswith("/")) and ((.path | contains("\u0000")) | not))' <<<"$1" >/dev/null 2>&1
}

# The one holder rule. A process with its working directory in the slot, or an lsof row that names a
# process and no working directory, is a holder unless it runs under this spawn's own pane
# (FM_SLOT_PANE_PID) or, for a backend with no pane pid, under a `treehouse` launcher that started
# after the spawn began (FM_SLOT_SPAWN_PID). On a relaunch, the process tree rooted at the task's own recorded
# endpoint (FM_SLOT_ENDPOINT_PID, the pane shell read from the recorded window, with FM_SLOT_ENDPOINT_START its start
# time) is this task's lineage too, except a process in it that fm_agent_process_classify_name (bin/fm-agent-process-lib.sh,
# which the caller sources) or fm_agent_process_classify names an agent by its executable path, argv0, arguments or pid. A
# start time that does not match, or a chain, path or argv that cannot be read, is unknown.
# There is no age exemption. A live lease, a contention row
# (or one that cannot be read) and a git worktree lock count too. A holder list that cannot be read skips.
fm_slot_holders_or_skip() { # <slot> [<project>]
  local slot=$1 project=${2:-} real common governed=0 out locked path line name tree exe
  real=$(CDPATH='' cd -- "$slot" 2>/dev/null && pwd -P) || { fm_slot_skip "$slot" unknown_holders "the slot directory cannot be entered"; return; }
  common=$(git -C "$slot" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
    { fm_slot_skip "$slot" unknown_holders "the git common directory cannot be read"; return; }
  if [ -n "$project" ] && fm_slot_required "$project" "$slot"; then governed=1; fi
  out=$(fm_slot_probe holders "$slot" "$real" "${FM_SLOT_SPAWN_PID:-$$}" "$common" "$governed" "${FM_SLOT_PANE_PID:-}" \
    "${FM_SLOT_ENDPOINT_PID:-}" "${FM_SLOT_ENDPOINT_START:-}" 2>&1) || {
    fm_slot_skip "$slot" unknown_holders "the holder list cannot be read (${out:-no detail})"
    return
  }
  while IFS= read -r line; do
    case "$line" in
      H$'\t'*) fm_slot_skip "$slot" live_holder "${line#H$'\t'}"; return ;;
      U$'\t'*) fm_slot_skip "$slot" unknown_holders "${line#U$'\t'}"; return ;;
      T$'\t'*)
        IFS=$'\x1f' read -r -a tree <<<"${line#T$'\t'}"
        declare -F fm_agent_process_classify_name fm_agent_process_classify >/dev/null ||
          { fm_slot_skip "$slot" unknown_holders "the agent classifier is not loaded, so the recorded endpoint's tree cannot be judged"; return; }
        for ((name = 1; name < ${#tree[@]}; name += 4)); do
          exe=${tree[name + 1]:-}
          if [ "$(fm_agent_process_classify_name "$exe" "${tree[name + 2]:-}")" = agent ] ||
            [ "$(fm_agent_process_classify "${exe##*/}" "${tree[name + 2]:-}" "${tree[name + 3]:-}" "${tree[name]}")" = agent ]; then
            fm_slot_skip "$slot" live_holder "an agent (pid ${tree[name]}, ${tree[name + 1]:-no path}, args ${tree[name + 3]:-none}) in the recorded endpoint's tree has the slot (holder pid ${tree[0]})"
            return
          fi
        done
        ;;
    esac
  done <<<"$out"
  locked=$(git -C "$slot" worktree list --porcelain 2>/dev/null) || { fm_slot_skip "$slot" unknown_holders "git worktree list failed"; return; }
  path=
  while IFS= read -r line; do
    case "$line" in
      'worktree '*) path=${line#worktree } ;;
      locked|'locked '*) if [ -n "$path" ] && [ "$path" -ef "$slot" ]; then fm_slot_skip "$slot" live_holder "a git worktree lock is set on the slot"; return; fi ;;
    esac
  done <<<"$locked"
  return 0
}

# Release the proof's scratch directory (the snapshot lives there, outside the slot).
fm_slot_proof_drop() {
  [ -z "$FM_SLOT_PROOF_DIR" ] || rm -rf -- "$FM_SLOT_PROOF_DIR"
  FM_SLOT_PROOF_DIR=''
  FM_SLOT_PROOF_SNAPSHOT=''
}

# fm_slot_prove_idle <slot> <target-sha-or-empty> [<project>]: 0 proven (FM_SLOT_PROOF_SNAPSHOT is set),
# FM_SLOT_SKIP_RC doubt. Writes nothing to the slot. An empty target means the spawn moves nothing
# (an origin-less copy): only the clean tree and the holder rule apply.
fm_slot_prove_idle() {
  local slot=$1 target=$2 project=${3:-} snap out head status colliding reason=unknown_git_read
  # A proof is of one copy. The reason of an earlier copy's skip must not survive into a record written for this one
  # (Main 1939 N-1); a skip in this proof sets it again.
  FM_SLOT_SKIP_REASON=
  # The proof never clears what the preparation recorded (FM_SLOT_PREPARED, FM_SLOT_PREPARE_DETACHED): a copy is re-proved
  # after it was prepared on the relaunch and freshen routes, and a refusal after that is still a failure. The state is
  # cleared where a new copy is acquired (spawn_skip_copy) and starts at zero for the process (Main 1925 F1).
  fm_slot_proof_drop
  [ -d "$slot" ] || { fm_slot_skip "$slot" unknown_git_read "the slot directory cannot be read"; return; }
  if [ -n "$target" ] && ! git -C "$slot" rev-parse --verify --quiet "$target^{commit}" >/dev/null 2>&1; then
    fm_slot_skip "$slot" unknown_target "the target commit '$target' cannot be read"
    return
  fi
  FM_SLOT_PROOF_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-slot-proof.XXXXXX" 2>/dev/null) ||
    { FM_SLOT_PROOF_DIR=; fm_slot_skip "$slot" unknown_git_read "a scratch directory for the snapshot cannot be created"; return; }
  snap="$FM_SLOT_PROOF_DIR/before.json"
  if [ -n "$target" ] && ! fm_slot_target_paths "$slot" "$target" "$FM_SLOT_PROOF_DIR"; then
    fm_slot_proof_drop
    fm_slot_skip "$slot" unknown_ignored_inventory "the path-comparison settings of the slot or the tracked paths of the target cannot be read"
    return
  fi
  out=$(fm_slot_snapshot "$slot" "$snap" 0 '' "$FM_SLOT_PROOF_DIR") || {
    case "$out" in *ls-files*|*'ignored entry'*) reason=unknown_ignored_inventory ;; esac
    fm_slot_proof_drop
    fm_slot_skip "$slot" "$reason" "the copy cannot be read in one snapshot (${out:-no detail})"
    return
  }
  status=$(fm_slot_probe field "$snap" status 2>&1) || { fm_slot_proof_drop; fm_slot_skip "$slot" unknown_git_read "the snapshot cannot be read back"; return; }
  if [ -n "$status" ]; then
    out="it is not clean, it holds uncommitted work ($(printf '%s' "$status" | sed -n '1,3p' | tr '\n' ';'))"
    reason=dirty_tree
    # A flag that hides a tracked edit from status is doubt, not a known state: it refuses the spawn (rule Q).
    case "$status" in *'hidden by an index flag'*) reason=index_flag ;; esac
    fm_slot_proof_drop
    fm_slot_skip "$slot" "$reason" "$out"
    return
  fi
  fm_slot_holders_or_skip "$slot" "$project" || { out=$?; fm_slot_proof_drop; return "$out"; }
  if [ -n "$target" ]; then
    colliding=$(fm_slot_probe collide "$snap" "$FM_SLOT_PROOF_DIR" 2>&1) ||
      { out=$colliding; fm_slot_proof_drop; fm_slot_skip "$slot" unknown_ignored_inventory "the ignored entries could not be compared with the target's tracked paths (${out:-no detail})"; return; }
    if [ -n "$colliding" ]; then
      fm_slot_proof_drop
      fm_slot_skip "$slot" ignored_collision "ignored work at a path the target tracks would be overwritten: $colliding"
      return
    fi
    head=$(fm_slot_probe field "$snap" head 2>/dev/null) || { fm_slot_proof_drop; fm_slot_skip "$slot" unknown_git_read "HEAD cannot be read"; return; }
    if [ "$head" != "$target" ]; then
      if git -C "$slot" merge-base --is-ancestor "$head" "$target" 2>/dev/null; then
        :
      else
        out=$?
        fm_slot_proof_drop
        if [ "$out" = 1 ]; then
          if git -C "$slot" merge-base --is-ancestor "$target" "$head" 2>/dev/null; then
            fm_slot_skip "$slot" head_not_target "HEAD $head is ahead of the target $target and keeps its commits"
          else
            fm_slot_skip "$slot" not_fast_forward "HEAD $head is not an ancestor of the target $target (the copy holds commits the target lacks)"
          fi
        else
          fm_slot_skip "$slot" unknown_git_read "the ancestry of HEAD and the target cannot be read"
        fi
        return
      fi
    fi
  fi
  FM_SLOT_PROOF_SNAPSHOT=$snap
}

# fm_slot_apply_move <slot> <target-sha>: move a copy the proof passed. 0 moved (or already there);
# FM_SLOT_SKIP_RC git refused, nothing had been written to the copy by this spawn, and a second read shows it unchanged;
# 1 anything else: the copy is left exactly as it is (HEAD, refs and files), no undo runs, and the caller holds the copy and
# refuses the spawn (Main 1886 CUT, rule Q). The comparison starts at the FIRST snapshot (the proof's), never a later one.
fm_slot_apply_move() {
  local slot=$1 target=$2 snap=$FM_SLOT_PROOF_SNAPSHOT after head attached mode out merge_out detached_flag expect=$FM_SLOT_EXPECT_REFS rc=0 prepared=$FM_SLOT_PREPARED note
  FM_SLOT_EXPECT_REFS=
  [ -n "$snap" ] && [ -f "$snap" ] || { echo "error: pooled copy '$slot' was not proven idle before the move" >&2; return 1; }
  after="$FM_SLOT_PROOF_DIR/after.json"
  head=$(fm_slot_probe field "$snap" head 2>/dev/null) || head=
  attached=$(fm_slot_probe field "$snap" symref 2>/dev/null) || attached=
  [ -n "$attached" ] || { fm_slot_proof_drop; echo "error: pooled copy '$slot' has no readable symbolic HEAD in its proof; it is left exactly as it is and no worker is admitted" >&2; return 1; }
  # A copy this spawn detached while preparing it (fm_slot_prepare_base) moves as a detached HEAD.
  [ "$attached" != detached ] && [ "$FM_SLOT_PREPARE_DETACHED" != 1 ] || attached=''
  detached_flag=$FM_SLOT_PREPARE_DETACHED
  mode=same
  if [ "$head" != "$target" ]; then
    mode=refused
    if merge_out=$(git -C "$slot" -c core.hooksPath=/dev/null merge --ff-only --quiet "$target" 2>&1); then
      mode=moved
    fi
  fi
  if ! out=$(fm_slot_snapshot "$slot" "$after" "$([ "$mode" = moved ] && echo 1 || echo 0)" "$snap" "$FM_SLOT_PROOF_DIR"); then
    fm_slot_proof_drop
    FM_SLOT_SKIP_REASON=unreadable_after_move
    echo "error: pooled copy '$slot' could not be read after the move ($(printf '%s' "$out" | sed -n '1p')); its state is unknown, so it is left exactly as it is and no worker is admitted" >&2
    return 1
  fi
  case "$mode" in
    moved) out=$(fm_slot_probe compare "$snap" "$after" moved "$target" "$attached" "$detached_flag" "$expect" 2>&1) || rc=$? ;;
    *) out=$(fm_slot_probe compare "$snap" "$after" same "" "" "$detached_flag" "$expect" 2>&1) || rc=$? ;;
  esac
  fm_slot_proof_drop
  if [ "$rc" != 0 ]; then
    FM_SLOT_SKIP_REASON=changed_during_move
    echo "error: pooled copy '$slot' differs from the proven state beyond the expected move ($out); it is left exactly as it is and no worker is admitted" >&2
    return 1
  fi
  if [ "$mode" = refused ]; then
    if [ "$prepared" = 1 ]; then
      FM_SLOT_SKIP_REASON=refused_after_preparation
      note=
      [ -z "$expect" ] || note="the anchor ${expect%%=*} was created; "
      [ "$detached_flag" != 1 ] || note="${note}this spawn's preparation detached the copy from its branch; "
      echo "error: git refused the move of pooled copy '$slot' to $target after this spawn had prepared it (${note}it is $(fm_slot_where "$slot")${out:+; $out}); nothing is switched back, the copy is left exactly as it is, and no worker is admitted" >&2
      return 1
    fi
    fm_slot_skip "$slot" not_fast_forward "git refused the move to $target and a second read shows no change to this copy ($(printf '%s' "$merge_out" | sed -n '1p'))${out:+; $out}"
    return
  fi
  return 0
}

# fm_slot_move_forward <slot> <target-sha> [<project>]: prove, then apply. 0 moved, FM_SLOT_SKIP_RC skipped
# (not moved; see fm_slot_apply_move for what was and was not changed), 1 failed (see fm_slot_apply_move).
fm_slot_move_forward() {
  local slot=$1 target=$2 project=${3:-} rc=0
  fm_slot_prove_idle "$slot" "$target" "$project" || return $?
  fm_slot_apply_move "$slot" "$target" || rc=$?
  return "$rc"
}

# fm_slot_attach <slot> <branch> <sha>: attach a copy that is already at <sha> to <branch>, for an explicit retry. The
# branch must hold <sha> and HEAD must already be <sha>; only the symbolic HEAD is set and no file is touched. It never
# checks anything out: from any other state it changes nothing and fails.
fm_slot_attach() {
  local slot=$1 branch=$2 sha=$3 head tip
  [ -n "$branch" ] || { echo "error: no branch to attach '$slot' to; the copy is not switched" >&2; return 1; }
  tip=$(git -C "$slot" rev-parse --verify --quiet "refs/heads/$branch^{commit}" 2>/dev/null) || tip=
  [ "$tip" = "$sha" ] || {
    echo "error: branch $branch is at '${tip:-nothing}', not the $sha this retry expects; the copy is not switched" >&2
    return 1
  }
  head=$(git -C "$slot" rev-parse --verify --quiet HEAD 2>/dev/null) || { echo "error: HEAD of '$slot' cannot be read; the copy is not switched" >&2; return 1; }
  [ "$head" = "$sha" ] || {
    echo "error: HEAD of '$slot' is $head, not the $sha this retry expects; the copy is not switched and every file stays as it is" >&2
    return 1
  }
  git -C "$slot" -c core.hooksPath=/dev/null symbolic-ref HEAD "refs/heads/$branch" || return 1
}
