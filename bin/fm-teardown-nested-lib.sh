#!/usr/bin/env bash
# shellcheck disable=SC2034 # TEARDOWN_FOREIGN_* and TEARDOWN_MERGED_* are output globals for bin/fm-teardown.sh.
# Foreign nested copies in the pool slot a teardown returns.
#
# A foreign copy is a registered worktree strictly inside the slot that no
# record of the retiring task names. Vernant's start_task_worktree.py creates
# one at <slot>/.claude/worktrees/<name> and locks it with
# "vernant-session-active owner=launcher:<pid> launcher=<pid>"; nothing else
# ever releases that lock, so the slot could never be returned. This library
# proves such a copy is nobody's and landed, then releases and removes it.
# bin/fm-teardown.sh's header owns the rule; this file owns the mechanics.
#
# A copy is released only when every proof holds, and each proof fails closed:
#   - it is a clean worktree root and holds no ignored file unique to it;
#   - no other active task record names it, no process runs in it, and no live
#     process is its lock launcher (a pid that started after the lock file was
#     written is recycled and owns nothing);
#   - its work is landed, strongest proof first: HEAD is an ancestor of the
#     merged PR head, its tree equals the merged head or the squash commit, the
#     existing landed-work rule holds, or Vernant's line_proof_for_path holds for
#     every changed path anchored at the squash commit;
#   - work that is none of those is released only when
#     FM_TEARDOWN_DISPOSE_ANCHORED=1 (off by default), after refs/fm/anchor/
#     <task>-<sha> is written and verified.
# A copy locked by Vernant's creation lock is released and removed by Vernant's
# own driver (closeout_pr.py --cleanup-worktree <copy> --execute-cleanup, run
# from the slot; FM_TEARDOWN_CLOSEOUT names another executable and
# FM_TEARDOWN_VERNANT_PYTHON the interpreter). An unlocked copy is removed with a
# plain non-forced git worktree remove. A lock in any other format, a driver
# refusal, or a copy still registered afterwards refuses. Nothing here forces a
# removal or touches an uncommitted or ignored file.
#
# Requires bin/fm-task-copy-lib.sh and bin/fm-lock-lib.sh to be sourced first,
# and runs inside bin/fm-teardown.sh, whose globals (PROJ, ID, META, STATE,
# PR_URL, TEARDOWN_NESTED_COPIES, TEARDOWN_RETURN_SLOT) and functions
# (teardown_landed, pids_with_cwd_under, ensure_commit_object,
# pr_number_from_branch, teardown_record_branch) it uses.

# One entry per proved copy; TEARDOWN_FOREIGN_MODES is "landed" or "anchor".
TEARDOWN_FOREIGN_COPIES=()
TEARDOWN_FOREIGN_MODES=()
TEARDOWN_FOREIGN_MODE=
TEARDOWN_FOREIGN_WHY=
TEARDOWN_FOREIGN_RUNG=
TEARDOWN_FOREIGN_LOCK=
TEARDOWN_FOREIGN_LOCK_FILE=
TEARDOWN_SLOT_COPIES=()
TEARDOWN_MERGED_READ=0
TEARDOWN_MERGED_HEAD=
TEARDOWN_MERGED_COMMIT=
TEARDOWN_CLOSEOUT_OUT=

# Sets TEARDOWN_SLOT_COPIES to the canonical paths of the copies <slot> has
# registered strictly inside itself, read from its own ref store.
teardown_slot_registered_copies() {  # <slot>
  local slot=$1 inventory field copy
  TEARDOWN_SLOT_COPIES=()
  slot=$(fm_task_copy_canonical_dir "$slot") || return 1
  inventory=$(mktemp "${TMPDIR:-/tmp}/fm-teardown-worktrees.XXXXXX") || return 1
  if ! git -C "$slot" worktree list --porcelain -z > "$inventory" 2>/dev/null; then
    rm -f "$inventory"
    return 1
  fi
  while IFS= read -r -d '' field; do
    case "$field" in 'worktree '*) copy=${field#worktree } ;; *) continue ;; esac
    copy=$(fm_task_copy_canonical_dir "$copy") || copy=${field#worktree }
    case "$copy" in "$slot"/*) TEARDOWN_SLOT_COPIES+=("$copy") ;; esac
  done < "$inventory"
  rm -f "$inventory"
}

# Reads the lock of linked worktree <copy> into TEARDOWN_FOREIGN_LOCK and sets
# TEARDOWN_FOREIGN_LOCK_FILE to the lock file's path. Returns 0 when locked,
# 1 when not locked, and 2 when the lock state cannot be read (including a copy
# whose .git file is gone).
teardown_copy_lock_file() {  # <copy>
  local copy=$1 admin
  TEARDOWN_FOREIGN_LOCK=
  TEARDOWN_FOREIGN_LOCK_FILE=
  [ -f "$copy/.git" ] && [ ! -L "$copy/.git" ] || return 2
  admin=$(git -C "$copy" rev-parse --absolute-git-dir 2>/dev/null) || return 2
  [ -n "$admin" ] || return 2
  if [ ! -e "$admin/locked" ] && [ ! -L "$admin/locked" ]; then
    return 1
  fi
  [ -f "$admin/locked" ] && [ ! -L "$admin/locked" ] || return 2
  IFS= read -r TEARDOWN_FOREIGN_LOCK < "$admin/locked" || [ -n "$TEARDOWN_FOREIGN_LOCK" ] || true
  TEARDOWN_FOREIGN_LOCK_FILE=$admin/locked
}

# The launcher pid of Vernant's exact creation-lock format, or failure for any
# other reason: a lock this format does not match is someone else's.
teardown_vernant_lock_pid() {  # <reason>
  local marker owner launcher extra pid
  read -r marker owner launcher extra <<< "$1"
  [ -z "$extra" ] && [ "$marker" = vernant-session-active ] || return 1
  case "$owner" in owner=?*) ;; *) return 1 ;; esac
  pid=${launcher#launcher=}
  [ "$pid" != "$launcher" ] || return 1
  case "$pid" in ''|0*|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$pid"
}

# Seconds since <pid> started, from ps etime ([[dd-]hh:]mm:ss).
teardown_pid_age_secs() {  # <pid>
  local etime days=0 a b c hours minutes seconds
  etime=$(LC_ALL=C ps -p "$1" -o etime= 2>/dev/null) || return 1
  etime=${etime//[[:space:]]/}
  [ -n "$etime" ] || return 1
  case "$etime" in *-*) days=${etime%%-*}; etime=${etime#*-} ;; esac
  IFS=: read -r a b c <<< "$etime"
  if [ -n "$c" ]; then hours=$a minutes=$b seconds=$c; else hours=0 minutes=$a seconds=$b; fi
  case "$days$hours$minutes$seconds" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$(( ((10#$days * 24 + 10#$hours) * 60 + 10#$minutes) * 60 + 10#$seconds ))"
}

# Is the pid in a creation lock a launcher that may still be alive? A pid that
# started after the lock file was written cannot be the process that wrote it:
# pids are recycled. A start time that cannot be read counts as live. Returns 0
# when it may be alive, 1 when it is gone or a recycled pid.
teardown_lock_launcher_may_be_live() {  # <pid> <lock-file>
  local pid=$1 lock=$2 age mtime now
  ps -p "$pid" -o pid= >/dev/null 2>&1 || return 1
  age=$(teardown_pid_age_secs "$pid") || return 0
  mtime=$(fm_lock_path_mtime "$lock") || return 0
  case "$mtime" in ''|*[!0-9]*) return 0 ;; esac
  now=$(date +%s)
  # ps etime counts whole seconds, so allow two for rounding.
  [ "$age" -ge $(( now - mtime - 2 )) ]
}

# Reads the merged PR's head and merge commit once per teardown into
# TEARDOWN_MERGED_HEAD and TEARDOWN_MERGED_COMMIT (the latter may stay empty).
# Fails when no merged GitHub PR can be read, a commit cannot be fetched, or
# project custody forbids network work; the ladder then uses the rungs that need
# no forge.
teardown_merged_pr_refs() {
  local target view state head merge
  if [ "$TEARDOWN_MERGED_READ" = 1 ]; then
    [ -n "$TEARDOWN_MERGED_HEAD" ]
    return
  fi
  TEARDOWN_MERGED_READ=1
  if [ "$TREEHOUSE_PROJECT_LOCK_HELD" = 1 ] && [ "$TEARDOWN_SLOT_CUSTODY" != project ]; then
    return 1
  fi
  if [ -n "$PR_URL" ]; then
    target=$PR_URL
  else
    target=$(pr_number_from_branch "$(teardown_record_branch)") || return 1
  fi
  [ -n "$target" ] || return 1
  view=$(cd "$PROJ" && gh pr view "$target" --json state,headRefOid,mergeCommit \
    -q '[.state, .headRefOid, (.mergeCommit.oid // "")] | join("\t")' 2>/dev/null) || return 1
  IFS=$'\t' read -r state head merge <<< "$view"
  [ "$state" = MERGED ] && fm_pr_head_valid "$head" || return 1
  ensure_commit_object "$target" "$head" || return 1
  if [ -n "$merge" ] && fm_pr_head_valid "$merge"; then
    if ! git -C "$PROJ" cat-file -e "$merge^{commit}" 2>/dev/null; then
      git -C "$PROJ" fetch --quiet --no-tags origin "$merge" >/dev/null 2>&1 || true
    fi
    git -C "$PROJ" cat-file -e "$merge^{commit}" 2>/dev/null || merge=
  else
    merge=
  fi
  TEARDOWN_MERGED_HEAD=$head
  TEARDOWN_MERGED_COMMIT=$merge
}

# Vernant's per-line landing proof over every path <copy> changed against the
# squash commit. It needs the project's own interpreter and checkout; without
# them the rung does not apply. An empty path set proves nothing.
teardown_foreign_line_proof() {  # <slot> <copy>
  local slot=$1 copy=$2 py base tip paths_file rc=0
  [ -n "$TEARDOWN_MERGED_COMMIT" ] || return 1
  py=${FM_TEARDOWN_VERNANT_PYTHON:-$slot/.venv/bin/python}
  [ -x "$py" ] && [ -f "$slot/scripts/git_management/branch_landing.py" ] || return 1
  tip=$(git -C "$copy" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || return 1
  base=$(git -C "$copy" merge-base "$tip" "$TEARDOWN_MERGED_COMMIT" 2>/dev/null) || return 1
  paths_file=$(mktemp "${TMPDIR:-/tmp}/fm-teardown-paths.XXXXXX") || return 1
  if ! git -C "$copy" diff --no-ext-diff --no-renames --name-only -z "$base" "$tip" -- > "$paths_file" \
     || [ ! -s "$paths_file" ]; then
    rm -f "$paths_file"
    return 1
  fi
  "$py" -I -c '
import sys
from pathlib import Path
slot, base, tip, anchor = sys.argv[1:5]
sys.path.insert(0, slot)
from scripts.git_management.branch_landing import line_proof_for_path
for raw in (p for p in sys.stdin.buffer.read().split(b"\0") if p):
    path = raw.decode("utf-8", "surrogateescape")
    if line_proof_for_path(Path(slot), path, merge_base=base, tip=tip, anchor=anchor) is not None:
        sys.exit(1)
' "$slot" "$base" "$tip" "$TEARDOWN_MERGED_COMMIT" < "$paths_file" >/dev/null 2>&1 || rc=$?
  rm -f "$paths_file"
  return "$rc"
}

# The landing ladder for <copy>, strongest proof first, each rung failing
# closed. Sets TEARDOWN_FOREIGN_RUNG to the rung that held. The landed-work
# rule gets an empty branch name so it never adopts this copy's PR as the
# task's recorded one.
teardown_foreign_landed() {  # <slot> <copy>
  local slot=$1 copy=$2 tree rev
  TEARDOWN_FOREIGN_RUNG=
  if teardown_merged_pr_refs; then
    if git -C "$copy" merge-base --is-ancestor HEAD "$TEARDOWN_MERGED_HEAD" 2>/dev/null; then
      TEARDOWN_FOREIGN_RUNG="HEAD is an ancestor of the merged PR head"
      return 0
    fi
    tree=$(git -C "$copy" rev-parse --verify --quiet 'HEAD^{tree}' 2>/dev/null) || tree=
    if [ -n "$tree" ]; then
      for rev in "$TEARDOWN_MERGED_HEAD" "$TEARDOWN_MERGED_COMMIT"; do
        [ -n "$rev" ] || continue
        if [ "$(git -C "$copy" rev-parse --verify --quiet "$rev^{tree}" 2>/dev/null)" = "$tree" ]; then
          TEARDOWN_FOREIGN_RUNG="its tree equals the merged PR head or the squash commit"
          return 0
        fi
      done
    fi
  fi
  if teardown_landed "$copy" HEAD ""; then
    TEARDOWN_FOREIGN_RUNG="the landed-work rule holds"
    return 0
  fi
  if teardown_foreign_line_proof "$slot" "$copy"; then
    TEARDOWN_FOREIGN_RUNG="Vernant's line proof holds for every changed path at the squash commit"
    return 0
  fi
  return 1
}

# Ignored files no commit or anchor holds. Symlinks, caches, virtual
# environments and Firstmate's own hook files are derived machinery; anything
# else is the copy's own, dies with it, and so refuses.
teardown_foreign_unique_ignored() {  # <copy>
  local copy=$1 entry name
  while IFS= read -r -d '' entry; do
    entry=${entry%/}
    [ ! -L "$copy/$entry" ] || continue
    name=${entry##*/}
    case "$entry" in .claude|.claude/*|.opencode|.opencode/*) continue ;; esac
    case "$name" in
      .venv|venv|node_modules|__pycache__|.pytest_cache|.ruff_cache|.mypy_cache|.DS_Store|.fm-grok-turnend|.fm-kimi-turnend) continue ;;
    esac
    printf '%s\n' "$entry"
  done < <(git -C "$copy" ls-files --others --ignored --exclude-standard --directory -z 2>/dev/null)
}

# Does an active record, a running process, or a live lock launcher own <copy>?
# Returns 1 with TEARDOWN_FOREIGN_WHY set when so or when that cannot be told.
teardown_foreign_copy_unowned() {  # <copy>
  local copy=$1 rc=0 pids pid
  # shellcheck disable=SC2153 # STATE is bin/fm-teardown.sh's global, not a typo of a local.
  fm_task_copy_other_record "$META" "$STATE" "$copy" || rc=$?
  case "$rc" in
    0)
      TEARDOWN_FOREIGN_WHY="task $FM_TASK_COPY_OTHER_ID's active record names it as its $FM_TASK_COPY_OTHER_FIELD"
      return 1
      ;;
    1) ;;
    *)
      TEARDOWN_FOREIGN_WHY="the active task records could not be read"
      return 1
      ;;
  esac
  if ! pids=$(pids_with_cwd_under "$copy"); then
    TEARDOWN_FOREIGN_WHY="a scan for processes running in it failed"
    return 1
  fi
  if [ -n "$pids" ]; then
    TEARDOWN_FOREIGN_WHY="process ${pids%%$'\t'*} is running in it"
    return 1
  fi
  rc=0
  teardown_copy_lock_file "$copy" || rc=$?
  case "$rc" in
    0)
      if ! pid=$(teardown_vernant_lock_pid "$TEARDOWN_FOREIGN_LOCK"); then
        TEARDOWN_FOREIGN_WHY="it is locked by something other than Vernant's creation lock (${TEARDOWN_FOREIGN_LOCK:-no reason given})"
        return 1
      fi
      if teardown_lock_launcher_may_be_live "$pid" "$TEARDOWN_FOREIGN_LOCK_FILE"; then
        TEARDOWN_FOREIGN_WHY="its creation-lock launcher process $pid may still be running"
        return 1
      fi
      ;;
    1) ;;
    *)
      TEARDOWN_FOREIGN_WHY="its lock state cannot be read"
      return 1
      ;;
  esac
}

# Proves foreign copy <copy>. Sets TEARDOWN_FOREIGN_MODE to landed or anchor, or
# returns 1 with TEARDOWN_FOREIGN_WHY naming what could not be proved. Writes
# nothing. A half-removed or unreadable copy fails the first check.
teardown_foreign_copy_prove() {  # <slot> <copy>
  local slot=$1 copy=$2 rc=0 unique
  TEARDOWN_FOREIGN_MODE=
  TEARDOWN_FOREIGN_WHY=
  fm_task_copy_preserve "$PROJ" "$ID" "$copy" 0 || rc=$?
  if [ "$rc" = 1 ]; then
    TEARDOWN_FOREIGN_WHY="it $FM_TASK_COPY_REASON"
    return 1
  fi
  unique=$(teardown_foreign_unique_ignored "$copy") || unique=
  if [ -n "$unique" ]; then
    TEARDOWN_FOREIGN_WHY="it holds ignored files that exist nowhere else: $(printf '%s' "$unique" | tr '\n' ' ')"
    return 1
  fi
  teardown_foreign_copy_unowned "$copy" || return 1
  if teardown_foreign_landed "$slot" "$copy"; then
    TEARDOWN_FOREIGN_MODE=landed
    return 0
  fi
  if [ "${FM_TEARDOWN_DISPOSE_ANCHORED:-0}" = 1 ]; then
    TEARDOWN_FOREIGN_MODE=anchor
    return 0
  fi
  TEARDOWN_FOREIGN_WHY="its HEAD ${FM_TASK_COPY_HEAD:0:12} is not proved landed (FM_TEARDOWN_DISPOSE_ANCHORED=1 anchors and disposes of such a copy)"
  return 1
}

# Proves every foreign copy in <slot> and records the provable ones in
# TEARDOWN_FOREIGN_COPIES. An unprovable copy is named here and then refused by
# the registered-copy check, which does not list it as allowed.
teardown_foreign_copies_prove() {  # <slot>
  local slot=$1 copy known allowed
  TEARDOWN_FOREIGN_COPIES=()
  TEARDOWN_FOREIGN_MODES=()
  teardown_slot_registered_copies "$slot" || return 0
  slot=$(fm_task_copy_canonical_dir "$slot") || return 0
  for copy in ${TEARDOWN_SLOT_COPIES[@]+"${TEARDOWN_SLOT_COPIES[@]}"}; do
    known=0
    for allowed in ${TEARDOWN_NESTED_COPIES[@]+"${TEARDOWN_NESTED_COPIES[@]}"}; do
      [ "$copy" != "$allowed" ] || known=1
    done
    [ "$known" = 0 ] || continue
    if teardown_foreign_copy_prove "$slot" "$copy"; then
      TEARDOWN_FOREIGN_COPIES+=("$copy")
      TEARDOWN_FOREIGN_MODES+=("$TEARDOWN_FOREIGN_MODE")
    else
      echo "notice: foreign copy $copy stays in pool slot $slot: $TEARDOWN_FOREIGN_WHY." >&2
    fi
  done
}

# Runs Vernant's closeout driver on <copy>: it releases its own creation lock
# and removes the copy with a plain, non-forced git worktree remove. Output lands
# in TEARDOWN_CLOSEOUT_OUT. Exit 0 means the driver allowed and ran the cleanup.
teardown_run_closeout() {  # <slot> <copy>
  local slot=$1 copy=$2 driver py rc=0
  TEARDOWN_CLOSEOUT_OUT=
  if [ -n "${FM_TEARDOWN_CLOSEOUT:-}" ]; then
    TEARDOWN_CLOSEOUT_OUT=$( cd "$slot" && "$FM_TEARDOWN_CLOSEOUT" --cleanup-worktree "$copy" --execute-cleanup 2>&1 ) || rc=$?
    return "$rc"
  fi
  driver=$slot/scripts/git-stability/closeout_pr.py
  py=${FM_TEARDOWN_VERNANT_PYTHON:-$slot/.venv/bin/python}
  if [ ! -f "$driver" ] || [ ! -x "$py" ]; then
    TEARDOWN_CLOSEOUT_OUT="Vernant's closeout driver $driver or its interpreter $py is not available"
    return 127
  fi
  TEARDOWN_CLOSEOUT_OUT=$( cd "$slot" && "$py" "$driver" --cleanup-worktree "$copy" --execute-cleanup 2>&1 ) || rc=$?
  return "$rc"
}

# Is <copy> still on disk or registered in <slot>? Failure to list counts as yes.
teardown_foreign_copy_present() {  # <slot> <copy>
  local slot=$1 copy=$2 registered
  [ ! -e "$copy" ] && [ ! -L "$copy" ] || return 0
  teardown_slot_registered_copies "$slot" || return 0
  for registered in ${TEARDOWN_SLOT_COPIES[@]+"${TEARDOWN_SLOT_COPIES[@]}"}; do
    [ "$registered" != "$copy" ] || return 0
  done
  return 1
}

# Releases and removes one proved foreign copy. In anchor mode its HEAD is
# anchored and the anchor verified first. Returns 1 after printing a refusal.
teardown_foreign_copy_dispose() {  # <slot> <copy> <mode>
  local slot=$1 copy=$2 mode=$3 rc=0
  if [ "$mode" = anchor ]; then
    if ! fm_task_copy_preserve "$PROJ" "$ID" "$copy" 1; then
      echo "REFUSED: foreign copy $copy $FM_TASK_COPY_REASON; it was not removed." >&2
      return 1
    fi
    echo "teardown: anchored foreign copy $copy at $FM_TASK_COPY_ANCHOR before removing it" >&2
  fi
  teardown_copy_lock_file "$copy" || rc=$?
  case "$rc" in
    0)
      if ! teardown_vernant_lock_pid "$TEARDOWN_FOREIGN_LOCK" >/dev/null; then
        echo "REFUSED: foreign copy $copy is locked by something other than Vernant's creation lock; it was not removed." >&2
        return 1
      fi
      rc=0
      teardown_run_closeout "$slot" "$copy" || rc=$?
      if [ "$rc" != 0 ]; then
        echo "REFUSED: Vernant's closeout driver did not release foreign copy $copy (exit $rc): ${TEARDOWN_CLOSEOUT_OUT:0:600}" >&2
        return 1
      fi
      ;;
    1)
      if ! git -C "$slot" worktree remove "$copy" >/dev/null 2>&1; then
        echo "REFUSED: git worktree remove would not remove foreign copy $copy without force; it was not removed." >&2
        return 1
      fi
      ;;
    *)
      echo "REFUSED: the lock state of foreign copy $copy cannot be read; it was not removed." >&2
      return 1
      ;;
  esac
  if teardown_foreign_copy_present "$slot" "$copy"; then
    echo "REFUSED: foreign copy $copy is still present or registered after its release; the pool slot was not returned." >&2
    return 1
  fi
  echo "teardown: removed foreign copy $copy from pool slot $slot (${mode}: ${TEARDOWN_FOREIGN_RUNG:-anchored})" >&2
}

# Releases every proved foreign copy of TEARDOWN_RETURN_SLOT. Each copy is
# proved again first, so a process or edit that appeared since is caught, and all
# are proved before any is changed.
teardown_foreign_copies_release() {
  local slot=$TEARDOWN_RETURN_SLOT copy i
  local -a copies=() modes=()
  [ -n "$slot" ] || return 0
  slot=$(fm_task_copy_canonical_dir "$slot") || return 1
  for i in "${!TEARDOWN_FOREIGN_COPIES[@]}"; do
    copy=${TEARDOWN_FOREIGN_COPIES[$i]}
    if ! teardown_foreign_copy_prove "$slot" "$copy"; then
      echo "REFUSED: foreign copy $copy in pool slot $slot is no longer provable: $TEARDOWN_FOREIGN_WHY; nothing was removed." >&2
      return 1
    fi
    copies+=("$copy")
    modes+=("$TEARDOWN_FOREIGN_MODE")
  done
  for i in "${!copies[@]}"; do
    teardown_foreign_copy_dispose "$slot" "${copies[$i]}" "${modes[$i]}" || return 1
  done
  TEARDOWN_FOREIGN_COPIES=()
  TEARDOWN_FOREIGN_MODES=()
}
