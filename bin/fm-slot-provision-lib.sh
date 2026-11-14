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
  [ -z "$status" ] || {
    echo 'error: slot provisioning refused: dirty_worktree; preserve and reconcile the scratch state before retrying' >&2
    FM_SLOT_SKIP_REASON=dirty_worktree
    return "$FM_SLOT_SKIP_RC"
  }
  for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply sequencer; do
    git_path=$(git -C "$copy" rev-parse --path-format=absolute --git-path "$marker") || return 1
    [ ! -e "$git_path" ] || {
      echo 'error: slot provisioning refused: operation_in_progress' >&2
      FM_SLOT_SKIP_REASON=operation_in_progress
      return "$FM_SLOT_SKIP_RC"
    }
  done
}

fm_slot_prepare_base() { # <project> <copy> <task-id>
  local project=$1 copy=$2 id=$3 branch
  fm_slot_check_copy "$project" "$copy" || return $?
  branch=$(git -C "$copy" branch --show-current) || return 1
  FM_SLOT_PREVIOUS_BRANCH=$branch
  FM_SLOT_PREVIOUS_HEAD=$(git -C "$copy" rev-parse --verify HEAD) || return 1
  # The ordinary freshness owner moves HEAD. Detach first so it cannot move a
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
  local dest
  [ -n "$FM_SLOT_PREVIOUS_HEAD" ] || return 0
  if [ -n "$FM_SLOT_PREVIOUS_BRANCH" ]; then
    dest=$(git -C "$1" rev-parse --verify --quiet "refs/heads/$FM_SLOT_PREVIOUS_BRANCH^{commit}") || return 1
    fm_slot_checkout "$1" "$dest" "$FM_SLOT_PREVIOUS_BRANCH" --
  else
    fm_slot_checkout "$1" "$FM_SLOT_PREVIOUS_HEAD" --detach "$FM_SLOT_PREVIOUS_HEAD"
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
  fm_slot_checkout "$copy" "$expected" "$branch" -- || return $?
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
        fm_slot_checkout "$copy" "$old_head" "$old_branch" -- || true
      else
        fm_slot_checkout "$copy" "$old_head" --detach "$old_head" || true
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

# --- The slot move: git moves that refuse, and one skip rule -------------------
# A pooled slot is advanced only by a move that git itself refuses when work would be
# lost: `merge --ff-only` to the target commit (it stops unless HEAD is an ancestor of
# the target, and stops before overwriting a tracked or untracked file), or a plain
# `checkout` (it stops before overwriting a tracked change). No command in this file or
# in bin/fm-spawn.sh forces, discards or removes anything in a slot, and a test scans
# for that. Git does overwrite an ignored file without asking, so the move keeps one
# narrow check for ignored work at a path the move writes.
# Any doubt skips the copy: the function returns FM_SLOT_SKIP_RC and leaves the slot
# exactly as found. A fresh spawn then takes another slot (bin/fm-spawn.sh).
# Nothing here proves that work is absent; a copy that is not plainly an idle, clean,
# behind-the-target copy is not used.
FM_SLOT_SKIP_RC=20
FM_SLOT_SKIP_REASON=
FM_SLOT_ARCHIVE_ROOT=
FM_SLOT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_slot_skip() { # <slot> <reason-code> <detail>
  FM_SLOT_SKIP_REASON=$2
  echo "skip: pooled copy '$1' is left untouched ($2): $3" >&2
  return "$FM_SLOT_SKIP_RC"
}

# The tree must show no tracked, staged or untracked change.
fm_slot_clean_or_skip() { # <slot>
  local status
  status=$(git -C "$1" -c core.quotePath=false status --porcelain=v1 --untracked-files=all --ignore-submodules=none 2>/dev/null) ||
    { fm_slot_skip "$1" unknown_git_read "git status failed"; return; }
  [ -z "$status" ] || fm_slot_skip "$1" dirty_tree "it is not clean, it holds uncommitted work ($(printf '%s' "$status" | sed -n '1,3p' | tr '\n' ';'))"
}

FM_SLOT_HOLDER_PY=$(cat <<'FMHOLDERPY'
import datetime, hashlib, json, os, subprocess, sys, time
slot, real, spawn, common, project_governed = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
def fail(text):
    sys.stderr.write(text + "\n")
    sys.exit(3)
# When a process started, in seconds since the epoch, or None when it cannot be read.
def started_at(pid):
    try:
        if sys.platform == "darwin":
            import ctypes, ctypes.util, struct
            lib = ctypes.CDLL(ctypes.util.find_library("proc") or "/usr/lib/libproc.dylib")
            buf = ctypes.create_string_buffer(136)
            if lib.proc_pidinfo(pid, 3, 0, buf, 136) != 136:
                return None
            sec, usec = struct.unpack_from("<QQ", buf.raw, 120)
            return sec + usec / 1e6
        with open("/proc/%d/stat" % pid) as handle:
            fields = handle.read().rsplit(")", 1)[1].split()
        ticks = int(fields[19])
        with open("/proc/stat") as handle:
            boot = [int(line.split()[1]) for line in handle if line.startswith("btime ")][0]
        return boot + ticks / os.sysconf("SC_CLK_TCK")
    except Exception:
        return None
began = started_at(spawn)
if began is None:
    fail("the spawn's own start time cannot be read")
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
    if not cwd or pid == os.getpid():
        continue
    if not any(cwd == base or cwd.startswith(base + "/") for base in inside):
        continue
    # A process that started after this spawn began is this spawn's own acquisition (the
    # shell treehouse opened for it). One that started earlier, or whose start cannot be
    # read, is somebody else's.
    when = started_at(pid)
    if when is not None and when > began:
        continue
    print("H\ta live process (pid %d, %s) has its working directory in the slot" % (pid, row["cmd"]))
    sys.exit(0)
if project_governed == "1":
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
            sys.exit(0)
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
        if hits:
            print("H\t%d co-tenant contention row(s) for this slot within 24 hours" % hits)
FMHOLDERPY
)

# The one holder rule: a live process in the slot (or a live lease, a lock, or recent
# co-tenant contention on it) skips the copy; so does a holder list that cannot be read.
fm_slot_holders_or_skip() { # <slot> [<project>]
  local slot=$1 project=${2:-} real common governed=0 out locked path line
  command -v lsof >/dev/null 2>&1 || { fm_slot_skip "$slot" unknown_holders "lsof is not available, so the holder list cannot be read"; return; }
  real=$(CDPATH='' cd -- "$slot" 2>/dev/null && pwd -P) || { fm_slot_skip "$slot" unknown_holders "the slot directory cannot be entered"; return; }
  common=$(git -C "$slot" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
    { fm_slot_skip "$slot" unknown_holders "the git common directory cannot be read"; return; }
  if [ -n "$project" ] && fm_slot_required "$project" "$slot"; then governed=1; fi
  out=$(python3 -I -c "$FM_SLOT_HOLDER_PY" "$slot" "$real" "${FM_SLOT_SPAWN_PID:-$$}" "$common" "$governed" 2>&1) || {
    fm_slot_skip "$slot" unknown_holders "the holder list cannot be read (${out:-no detail})"
    return
  }
  case "$out" in
    H$'\t'*) fm_slot_skip "$slot" live_holder "${out#H$'\t'}"; return ;;
  esac
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

# One ignored entry is scratch when the existing closeout classifier says so, with
# nothing it would preserve (sourced in a subshell, so no names leak into the spawn).
fm_slot_entry_is_scratch() { # <real-slot> <slot-relative path> <NUL-delimited whole-ignored-directory list file>
  local real=$1 rel=$2 dirs=$3 prefix='' part rest=$2
  (
    set +e
    listed() {
      local listed_dir
      while IFS= read -r -d '' listed_dir; do
        [ "${listed_dir%/}" != "$1" ] || return 0
      done <"$dirs"
      return 1
    }
    # shellcheck source=bin/fm-merge-prune-lib.sh
    . "$FM_SLOT_LIB_DIR/fm-merge-prune-lib.sh" >/dev/null 2>&1 || exit 2
    scratch() {
      FM_MP_PRESERVE=()
      fm_mp_classify_entry "$real" "$1" >/dev/null 2>&1 || return 1
      [ "${#FM_MP_PRESERVE[@]}" -eq 0 ]
    }
    scratch "$rel" && exit 0
    while :; do
      part=${rest%%/*}
      [ "$part" != "$rest" ] || exit 1
      prefix="${prefix:+$prefix/}$part"
      rest=${rest#*/}
      listed "$prefix" || continue
      scratch "$prefix" && exit 0
    done
  )
}

# Whether a verified archive holds the entry with the bytes it has now (the SHA256SUMS
# written by fm_mp_preserve_one under data/<id>/merge-prune-preserved).
fm_slot_entry_archived() { # <real-slot> <slot-relative path>
  local real=$1 rel=$2 file sum sums
  case "$rel" in *$'\n'* | *\\*) return 1 ;; esac
  file="$real/$rel"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ -n "$FM_SLOT_ARCHIVE_ROOT" ] || return 1
  sum=$(shasum -a 256 -- "$file" 2>/dev/null | awk '{print $1}') || return 1
  [ -n "$sum" ] || return 1
  for sums in "$FM_SLOT_ARCHIVE_ROOT"/*/merge-prune-preserved/*/*/SHA256SUMS; do
    [ -f "$sums" ] || continue
    grep -Fxq -- "$sum  $rel" "$sums" 2>/dev/null || continue
    if (cd "$(dirname "$sums")" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1); then
      return 0
    fi
  done
  return 1
}

# The narrow ignored-work check. Git overwrites an ignored file silently, so before a
# move that changes the tree: the paths the move writes are those added, copied, renamed
# or type-changed between HEAD and the target. An ignored entry collides when it equals
# one, lies inside one, or is an ancestor of one (an ignored file where a tracked
# directory must be created). A colliding entry is allowed only when the closeout
# classifier calls it scratch or a verified archive holds its bytes. An unreadable
# inventory skips the copy. Ignored entries at paths the move does not write never skip it.
fm_slot_ignored_or_skip() { # <slot> <target-commit>
  local slot=$1 target=$2 real scratch ignored written hits dirs entry bad='' settings
  real=$(CDPATH='' cd -- "$slot" 2>/dev/null && pwd -P) || { fm_slot_skip "$slot" unknown_ignored_inventory "the slot directory cannot be entered"; return; }
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-slot-move.XXXXXX" 2>/dev/null) ||
    { fm_slot_skip "$slot" unknown_ignored_inventory "a scratch file for the ignored-entry inventory cannot be created"; return; }
  ignored="$scratch/ignored" written="$scratch/written" hits="$scratch/hits" dirs="$scratch/dirs"
  if ! git -C "$slot" ls-files -o -i --exclude-standard -z >"$ignored" 2>/dev/null ||
    ! git -C "$slot" ls-files -o -i --exclude-standard --directory -z >"$dirs" 2>/dev/null; then
    rm -rf -- "$scratch"
    fm_slot_skip "$slot" unknown_ignored_inventory "the slot's ignored entries cannot be listed"
    return
  fi
  settings=$(git -C "$slot" config --bool --get-regexp '^core\.(ignorecase|precomposeunicode)$' 2>/dev/null) || {
    [ "$?" = 1 ] || {
      rm -rf -- "$scratch"
      fm_slot_skip "$slot" unknown_ignored_inventory "the slot's path-comparison settings cannot be read"
      return
    }
    settings=
  }
  if ! git -C "$slot" diff --name-only -z --no-renames --diff-filter=ACRT HEAD "$target" -- >"$written" 2>/dev/null; then
    rm -rf -- "$scratch"
    fm_slot_skip "$slot" unknown_ignored_inventory "the paths the move writes cannot be listed"
    return
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
written = set(key(item) for item in names(sys.argv[1]))
below = set()
for path in written:
    parts = path.split("/")
    for i in range(1, len(parts)):
        below.add("/".join(parts[:i]))
found = set()
for entry in names(sys.argv[2]):
    entry = entry.rstrip(b"/")
    folded = key(entry)
    parts = folded.split("/")
    inside = any("/".join(parts[:i]) in written for i in range(1, len(parts)))
    if folded in written or folded in below or inside:
        found.add(entry)
open(sys.argv[3], "wb").write(b"".join(item + b"\0" for item in sorted(found)))
' "$written" "$ignored" "$hits" "$settings" 2>/dev/null; then
    rm -rf -- "$scratch"
    fm_slot_skip "$slot" unknown_ignored_inventory "the ignored entries could not be compared with the paths the move writes"
    return
  fi
  while IFS= read -r -d '' entry; do
    if fm_slot_entry_is_scratch "$real" "$entry" "$dirs"; then
      continue
    elif fm_slot_entry_archived "$real" "$entry"; then
      continue
    fi
    entry=${entry//$'\n'/\\n}
    bad="${bad:+$bad, }$entry"
  done <"$hits"
  rm -rf -- "$scratch"
  [ -z "$bad" ] || fm_slot_skip "$slot" ignored_collision "ignored work at a path the move writes would be overwritten and no verified archive holds it: $bad"
}

# Advance the slot to <target-sha>: clean tree, no holder, no ignored work in the way,
# then `merge --ff-only`, then HEAD must be the target. The fast-forward moves HEAD (or
# its attached branch) only to a commit that contains the old HEAD, so no commit is ever
# dropped; a tracked or untracked change that appears after the checks is refused by git.
# Hooks stay off for the merge: the reset it replaces ran none, and a post-merge hook must not run here.
# Returns 0 moved, FM_SLOT_SKIP_RC skipped (slot untouched), 1 on an unexpected failure.
fm_slot_move_forward() { # <slot> <target-sha> [<project>]
  local slot=$1 target=$2 project=${3:-} head merge_out
  git -C "$slot" rev-parse --verify --quiet "$target^{commit}" >/dev/null 2>&1 ||
    { fm_slot_skip "$slot" unknown_target "the target commit '$target' cannot be read"; return; }
  head=$(git -C "$slot" rev-parse --verify --quiet HEAD 2>/dev/null) ||
    { fm_slot_skip "$slot" unknown_git_read "HEAD cannot be read"; return; }
  [ "$head" != "$target" ] || return 0
  fm_slot_clean_or_skip "$slot" || return $?
  fm_slot_holders_or_skip "$slot" "$project" || return $?
  fm_slot_ignored_or_skip "$slot" "$target" || return $?
  if ! merge_out=$(git -C "$slot" -c core.hooksPath=/dev/null merge --ff-only --quiet "$target" 2>&1); then
    fm_slot_skip "$slot" not_fast_forward "git refused the move to $target ($(printf '%s' "$merge_out" | sed -n '1p'))"
    return
  fi
  head=$(git -C "$slot" rev-parse --verify --quiet HEAD 2>/dev/null) || head=
  [ "$head" = "$target" ] ||
    fm_slot_skip "$slot" head_not_target "HEAD is ${head:-unreadable} after the move, not $target (a copy ahead of the target keeps its commits)"
}

# A tree-changing checkout is a plain `checkout` (git refuses over a tracked change) after
# the same clean-tree and ignored-work look. <target-commit> is the commit it moves HEAD to;
# when that is the commit HEAD already holds, nothing in the tree changes and git runs alone.
fm_slot_checkout() { # <slot> <target-commit> <git-checkout-arg>...
  local slot=$1 target=$2 head
  shift 2
  head=$(git -C "$slot" rev-parse --verify --quiet HEAD 2>/dev/null) ||
    { fm_slot_skip "$slot" unknown_git_read "HEAD cannot be read"; return; }
  if [ "$head" != "$target" ]; then
    fm_slot_clean_or_skip "$slot" || return $?
    fm_slot_ignored_or_skip "$slot" "$target" || return $?
  fi
  git -C "$slot" checkout --quiet "$@"
}
