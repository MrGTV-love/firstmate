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
# exactly that commit after). The move admits that one creation and no other ref change.
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
  local runner=$1 project=$2 copy=$3 id=$4 branch=$5 report=$6 local_ref=$7 selected=$8
  local base old_branch old_head branch_head rc=0
  shift 8
  FM_SLOT_PROVISIONED=0
  FM_SLOT_MANIFEST=
  FM_SLOT_BASE_SHA=
  FM_SLOT_BASE_REF=
  FM_SLOT_PREPARED_HEAD=
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
#                       It compares every ref exactly: the only change admitted besides the HEAD/branch
#                       move is the anchor this spawn's own preparation created. A refusal writes no
#                       file and runs no checkout; its undo is by ref only, on proof. Any other
#                       difference is a failure (return 1), never a skip.
# A copy is proven idle only when ONE snapshot shows: HEAD and its branch readable, the tree clean
# (tracked, staged and untracked), no process with its working directory in it, no git worktree
# lock, no live lease or recent contention row, no ignored file at a path the target tracks, and no index flag
# (assume-unchanged, skip-worktree) on a tracked file or inside any initialized submodule, however deep.
# Every unreadable input is a doubt, and a doubt skips the copy (return FM_SLOT_SKIP_RC).
FM_SLOT_SKIP_RC=20
# Returned for a doubt that is an UNKNOWN (could not tell): the whole spawn is refused, nothing is skipped past (rule Q).
FM_SLOT_REFUSE_RC=21
FM_SLOT_SKIP_REASON=
FM_SLOT_PROOF_SNAPSHOT=
FM_SLOT_PROOF_DIR=
FM_SLOT_PREPARE_DETACHED=0

fm_slot_skip() { # <slot> <reason-code> <detail>
  FM_SLOT_SKIP_REASON=$2
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

# One embedded program with five read-only modes. It runs git and lsof through PATH, so a failing
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

# ---- snapshot: HEAD, branch, EVERY ref, the status (submodules counted, hidden index flags checked), and every
# ignored file with its size and sha256 (a symlink by its target). Anything that cannot be read fails the whole snapshot.
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

def snapshot(slot, out, after_move="0", before=""):
    head, symref, refs = head_and_refs(slot)
    status = [enc(e) for e in git(slot, "-c", "core.quotePath=false", "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none").stdout.split(b"\0") if e]
    heads = submodule_heads(slot)
    if after_move == "1":
        before_heads = load(before).get("subheads", {})
        status = [e for e in status if not submodule_pin_only(slot, e, before_heads)]
    status += hidden_changes(slot)
    status += nested_flags(slot)
    ignored = {}
    for raw in git(slot, "ls-files", "-o", "-i", "--exclude-standard", "-z").stdout.split(b"\0"):
        if not raw:
            continue
        path = os.path.join(os.fsencode(slot), raw.rstrip(b"/"))
        try:
            st = os.lstat(path)
            if os.path.islink(path):
                entry = ["link", 0, os.readlink(path).__repr__()]
            elif os.path.isdir(path):
                entry = ["dir", 0, ""]
            elif os.path.isfile(path):
                digest = hashlib.sha256()
                with open(path, "rb") as handle:
                    for chunk in iter(lambda: handle.read(1 << 20), b""):
                        digest.update(chunk)
                entry = ["file", st.st_size, digest.hexdigest()]
            else:
                entry = ["special", 0, ""]
        except OSError as exc:
            fail("ignored entry %r cannot be read: %s" % (enc(raw), exc))
        ignored[enc(raw)] = entry
    # The refs are read LAST here, and FIRST in the read after a move, so the window in which another writer's
    # ref change can look like ours is the move itself.
    head, symref, refs = head_and_refs(slot)
    with open(out, "w", encoding="utf-8") as handle:
        json.dump({"head": head, "symref": symref, "refs": refs, "status": status, "ignored": ignored, "subheads": heads}, handle, sort_keys=True)

def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)

# ---- compare two snapshots. same: nothing differs. moved <target> <attached-ref>: HEAD is the target, the attached
# branch (if any) is the target, every other ref is as it was (but for the named exceptions), the status is clean,
# and every ignored entry is exactly as it was.
def compare(before, after, mode, target, attached, detached="", expect=""):
    a, b, diffs = load(before), load(after), []
    # expect: "<ref>=<sha>" entries, the exact refs the preparation of this operation creates: absent before, exactly <sha> after.
    made = dict(e.split("=", 1) for e in expect.split() if "=" in e)
    if detached == "1":
        a["symref"] = "detached"
    def named(want, have):
        return ", ".join(sorted(k for k in set(want) | set(have) if want.get(k) != have.get(k))[:3])
    want = dict(a["refs"])
    if mode != "same" and attached:
        want[attached] = target
    for ref, sha in made.items():
        if ref in a["refs"]:
            # Already there before the proof: it must be exactly as it was (the general comparison covers it).
            continue
        if b["refs"].get(ref) != sha:
            diffs.append("the expected anchor %s was not created at %s (it is %s)" % (ref, sha, b["refs"].get(ref, "missing")))
        else:
            want[ref] = sha
    if mode == "same":
        for key in ("head", "symref", "status", "ignored"):
            if a[key] != b[key]:
                diffs.append("%s changed" % key)
        if want != b["refs"]:
            diffs.append("refs changed: %s" % named(want, b["refs"]))
    else:
        if b["head"] != target:
            diffs.append("HEAD is %s, not %s" % (b["head"], target))
        if b["symref"] != a["symref"]:
            diffs.append("the checked-out branch changed from %s to %s" % (a["symref"], b["symref"]))
        if want != b["refs"]:
            diffs.append("refs changed beyond the move: %s" % named(want, b["refs"]))
        if b["status"]:
            diffs.append("the tree is not clean after the move: %s" % "; ".join(b["status"][:3]))
        if a["ignored"] != b["ignored"]:
            changed = sorted(k for k in set(a["ignored"]) | set(b["ignored"]) if a["ignored"].get(k) != b["ignored"].get(k))
            diffs.append("ignored files changed: %s" % ", ".join(changed[:3]))
    if diffs:
        print("; ".join(diffs))
        sys.exit(1)

# ---- collide: ignored entries at a path the target tracks (the same path, below it, or above it).
def collide(snap, tracked, settings):
    cfg = dict(line.split(" ", 1) for line in settings.splitlines() if " " in line)
    ignorecase = cfg.get("core.ignorecase") == "true"
    precompose = cfg.get("core.precomposeunicode") == "true"
    def key(text):
        if precompose:
            text = unicodedata.normalize("NFC", text)
        return text.casefold() if ignorecase else text
    written = set(key(enc(p)) for p in open(tracked, "rb").read().split(b"\0") if p)
    below = set()
    for path in written:
        parts = path.split("/")
        for i in range(1, len(parts)):
            below.add("/".join(parts[:i]))
    found = []
    for entry in load(snap)["ignored"]:
        folded = key(entry.rstrip("/"))
        parts = folded.split("/")
        inside = any("/".join(parts[:i]) in written for i in range(1, len(parts)))
        if folded in written or folded in below or inside:
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

def holders(slot, real, spawn, common, governed, pane):
    me = os.getpid()
    try:
        spawn = int(spawn)
        pane = int(pane) if pane else 0
    except ValueError:
        fail("the spawn or pane pid is not a number")
    began = (proc_info(spawn) or (0, "", None))[2]
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
        if cwd == "":
            cwd = None  # an empty working directory names nowhere: unknown, never "outside the slot"
        if pid == me:
            continue
        if cwd is not None and not any(cwd == base or cwd.startswith(base + "/") for base in inside):
            continue
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
    collide(*args)
elif mode == "holders":
    holders(*args)
elif mode == "hidden":
    # Tracked work hidden by an index flag, at the top level and inside every initialized submodule. One entry per line.
    found = hidden_changes(args[0]) + nested_flags(args[0])
    print("\n".join(found))
elif mode == "field":
    value = load(args[0])[args[1]]
    print(value if isinstance(value, str) else "\n".join(value))
FMPROBEPY
)

fm_slot_probe() { python3 -I -c "$FM_SLOT_PROBE_PY" "$@"; }

# fm_slot_snapshot <slot> <out-file>: fails (nonzero) when any read fails.
fm_slot_snapshot() { fm_slot_probe snapshot "$1" "$2" "${3:-0}" "${4:-}" 2>&1; }

# fm_slot_hidden_work <slot>: prints tracked work hidden by an index flag (assume-unchanged, skip-worktree), by blob or by
# mode, at the top level and inside every initialized submodule. Returns nonzero when it cannot tell. The same function
# the proof uses; bin/fm-teardown.sh calls it before it releases a skipped copy (Main 1886 N1).
fm_slot_hidden_work() { fm_slot_probe hidden "$1" 2>&1; }

# fm_slot_pool_rows_valid <json>: a pool listing is trusted only when it is an array and EVERY row is an object with a path
# that is a nonempty absolute string with no NUL. One row that fails means the holder of any copy is unknown (Main 1886 N7).
fm_slot_pool_rows_valid() {
  jq -e 'type == "array" and all(.[]; type == "object" and ((.path // null | type) == "string") and (.path | length > 0)
    and (.path | startswith("/")) and ((.path | contains(" ")) | not))' <<<"$1" >/dev/null 2>&1
}

# The one holder rule. A process with its working directory in the slot, or an lsof row that names a
# process and no working directory, is a holder unless it runs under this spawn's own pane
# (FM_SLOT_PANE_PID) or, for a backend with no pane pid, under a `treehouse` launcher that started
# after the spawn began (FM_SLOT_SPAWN_PID). There is no age exemption. A live lease, a contention row
# (or one that cannot be read) and a git worktree lock count too. A holder list that cannot be read skips.
fm_slot_holders_or_skip() { # <slot> [<project>]
  local slot=$1 project=${2:-} real common governed=0 out locked path line
  real=$(CDPATH='' cd -- "$slot" 2>/dev/null && pwd -P) || { fm_slot_skip "$slot" unknown_holders "the slot directory cannot be entered"; return; }
  common=$(git -C "$slot" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
    { fm_slot_skip "$slot" unknown_holders "the git common directory cannot be read"; return; }
  if [ -n "$project" ] && fm_slot_required "$project" "$slot"; then governed=1; fi
  out=$(fm_slot_probe holders "$slot" "$real" "${FM_SLOT_SPAWN_PID:-$$}" "$common" "$governed" "${FM_SLOT_PANE_PID:-}" 2>&1) || {
    fm_slot_skip "$slot" unknown_holders "the holder list cannot be read (${out:-no detail})"
    return
  }
  case "$out" in
    H$'\t'*) fm_slot_skip "$slot" live_holder "${out#H$'\t'}"; return ;;
    U$'\t'*) fm_slot_skip "$slot" unknown_holders "${out#U$'\t'}"; return ;;
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
  local slot=$1 target=$2 project=${3:-} no_ancestry=${4:-} snap out head status settings tracked colliding reason=unknown_git_read
  # A new proof starts a new copy: nothing has been written to it by this spawn yet.
  FM_SLOT_PREPARED=0
  FM_SLOT_PREPARE_DETACHED=0
  fm_slot_proof_drop
  [ -d "$slot" ] || { fm_slot_skip "$slot" unknown_git_read "the slot directory cannot be read"; return; }
  if [ -n "$target" ] && ! git -C "$slot" rev-parse --verify --quiet "$target^{commit}" >/dev/null 2>&1; then
    fm_slot_skip "$slot" unknown_target "the target commit '$target' cannot be read"
    return
  fi
  FM_SLOT_PROOF_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-slot-proof.XXXXXX" 2>/dev/null) ||
    { FM_SLOT_PROOF_DIR=; fm_slot_skip "$slot" unknown_git_read "a scratch directory for the snapshot cannot be created"; return; }
  snap="$FM_SLOT_PROOF_DIR/before.json"
  out=$(fm_slot_snapshot "$slot" "$snap") || {
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
    settings=$(git -C "$slot" config --bool --get-regexp '^core\.(ignorecase|precomposeunicode)$' 2>/dev/null) || {
      [ "$?" = 1 ] || { fm_slot_proof_drop; fm_slot_skip "$slot" unknown_ignored_inventory "the slot's path-comparison settings cannot be read"; return; }
      settings=
    }
    tracked="$FM_SLOT_PROOF_DIR/tracked"
    git -C "$slot" ls-tree -r --name-only -z "$target" -- >"$tracked" 2>/dev/null ||
      { fm_slot_proof_drop; fm_slot_skip "$slot" unknown_ignored_inventory "the target's tracked paths cannot be listed"; return; }
    colliding=$(fm_slot_probe collide "$snap" "$tracked" "$settings" 2>&1) ||
      { out=$colliding; fm_slot_proof_drop; fm_slot_skip "$slot" unknown_ignored_inventory "the ignored entries could not be compared with the target's tracked paths (${out:-no detail})"; return; }
    if [ -n "$colliding" ]; then
      fm_slot_proof_drop
      fm_slot_skip "$slot" ignored_collision "ignored work at a path the target tracks would be overwritten: $colliding"
      return
    fi
    head=$(fm_slot_probe field "$snap" head 2>/dev/null) || { fm_slot_proof_drop; fm_slot_skip "$slot" unknown_git_read "HEAD cannot be read"; return; }
    if [ "$head" != "$target" ] && [ "$no_ancestry" != noancestry ]; then
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
  if ! out=$(fm_slot_snapshot "$slot" "$after" "$([ "$mode" = moved ] && echo 1 || echo 0)" "$snap"); then
    fm_slot_proof_drop
    echo "error: pooled copy '$slot' could not be read after the move ($(printf '%s' "$out" | sed -n '1p')); its state is unknown, so it is left exactly as it is and no worker is admitted" >&2
    return 1
  fi
  case "$mode" in
    moved) out=$(fm_slot_probe compare "$snap" "$after" moved "$target" "$attached" "$detached_flag" "$expect" 2>&1) || rc=$? ;;
    *) out=$(fm_slot_probe compare "$snap" "$after" same "" "" "$detached_flag" "$expect" 2>&1) || rc=$? ;;
  esac
  fm_slot_proof_drop
  if [ "$rc" != 0 ]; then
    echo "error: pooled copy '$slot' differs from the proven state beyond the expected move ($out); it is left exactly as it is and no worker is admitted" >&2
    return 1
  fi
  if [ "$mode" = refused ]; then
    if [ "$prepared" = 1 ]; then
      note=
      [ -z "$expect" ] || note="the anchor ${expect%%=*} was created; "
      [ "$detached_flag" != 1 ] || note="${note}this spawn's preparation detached the copy from its branch; "
      echo "error: git refused the move of pooled copy '$slot' to $target after this spawn had prepared it (${note}it is $(fm_slot_where "$slot")); nothing is switched back, the copy is left exactly as it is, and no worker is admitted" >&2
      return 1
    fi
    fm_slot_skip "$slot" not_fast_forward "git refused the move to $target and a second read shows no change ($(printf '%s' "$merge_out" | sed -n '1p'))"
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
