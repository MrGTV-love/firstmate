#!/usr/bin/env bash
# shellcheck disable=SC2034 # TEARDOWN_FOREIGN_* are output globals for bin/fm-teardown.sh.
# Foreign nested copies in the pool slot a teardown returns, and the task's own
# nested copies that Vernant's creation lock holds.
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
#   - it is a clean worktree root, and each ignored file it holds is either
#     regenerable machinery (listed in teardown_preservable_ignored) or copied
#     with its SHA-256 into $DATA/$ID/nested-copy-preserved before removal;
#   - no other active task record names it, no process outside this teardown's
#     own runs in it, and no live process outside this teardown's own is its
#     lock launcher (a process is this teardown's own when it, or an ancestor by
#     parent chain, has a cwd exactly at a root retire sweeps, and a pid that
#     started after the lock file was written is recycled and owns nothing). The
#     retire phase sends TERM to each such launcher and each such process running
#     in the copy, waits a bounded time, and sends no KILL; one still alive
#     refuses the release, named by its pid. A process that is not this
#     teardown's own is never signalled and refuses at once, named by its pid;
#   - its work is landed by the existing landed-work rule (teardown_landed).
# A copy whose work is not proved landed stays, and teardown names why.
# The task's own nested copies (the record's worktree= and prior_worktree= copies
# inside the slot) were already proved clean and landed or anchored by the
# caller. One of them that Vernant's creation lock holds is released the same
# way, never by forcing the removal: its ignored files are preserved as above,
# no process outside this teardown may run in it or be its live lock launcher,
# and no other active record may name it; the driver then verifies the landing
# again and refuses what it cannot prove. An own copy that is not locked is
# removed as before.
# A copy locked by Vernant's creation lock is released and removed by Vernant's
# own driver (closeout_pr.py --cleanup-worktree <copy> --execute-cleanup, run
# from the slot with FM_TEARDOWN_VERNANT_PYTHON or <slot>/.venv/bin/python). An
# unlocked copy is removed with a plain non-forced git worktree remove. A lock in
# any other format, a driver refusal, or a copy still registered afterwards
# refuses. Removal deletes the copy's checkout and the allow-listed ignored files
# in it (symlinks, virtual environments, node_modules and tool caches,
# .DS_Store, Firstmate's hook files, regenerable build caches, and anything
# ignored under its .claude and .opencode trees); it loses no commit, because
# the work is landed, and no tracked change, because the clean proof refuses one.
# Any other ignored entry is copied to the task's data directory before removal.
# The clean proof skips
# untracked files under .claude only; the ignored-file proof skips ignored files
# under .claude and .opencode; plain git worktree remove still refuses a copy
# that holds an untracked file. On the pool-slot route the release runs before
# the final project-lock wait, so the driver never runs while the lock is held,
# except when teardown keeps project custody through the return.
#
# Requires bin/fm-task-copy-lib.sh, bin/fm-lock-lib.sh and bin/fm-refuse-lib.sh first,
# and runs inside bin/fm-teardown.sh, whose globals (PROJ, ID, DATA, META,
# STATE, WT, TASK_TMP, FORCE, LEGACY_RECORD_GIVEN, TEARDOWN_NESTED_COPIES,
# TEARDOWN_RETURN_SLOT, TEARDOWN_PEER_SLOT) and functions
# (teardown_landed, pids_with_cwd_under, task_process_identity,
# task_process_identity_matches, task_record_process_signal) it uses.

# One entry per proved copy.
TEARDOWN_FOREIGN_COPIES=()
# Own nested copies teardown_own_locked_copies_release has removed already.
TEARDOWN_OWN_RELEASED=()
# One "pid<TAB>birth identity<TAB>cwd" entry per live lock launcher or process
# running in a copy that was proved to be this teardown's own; cwd is that of the
# own process it was chosen through.
TEARDOWN_FOREIGN_PROCS=()
TEARDOWN_OWN_CWD=
TEARDOWN_OWN_SCAN=
TEARDOWN_OWN_SCANNED=0
TEARDOWN_FOREIGN_WHY=
TEARDOWN_FOREIGN_LOCK=
TEARDOWN_FOREIGN_LOCK_FILE=
TEARDOWN_SLOT_COPIES=()
TEARDOWN_CLOSEOUT_OUT=
TEARDOWN_FOREIGN_RULE=
TEARDOWN_REFUSED_COPIES=()
TEARDOWN_FRICTION_GUARD=FM-TEARDOWN-PRESERVATION

# One operation per teardown process: the environment's when this run is a
# printed completing command, else minted with its first refusal. The outcome
# of a copy is recorded only for an operation a refusal already holds.
teardown_friction_outcome() {  # <outcome> [<copy>]
  FM_HOME="$FM_HOME" fm_friction_outcome "$1" "$TEARDOWN_FRICTION_GUARD" nested-copy "${2:-}" "$ID"
}

# The human-only question for a copy the proof refused; <rule> names the proof.
teardown_copy_question() {  # <rule> <copy> <why>
  case "$1" in
    copy-worktree-root) printf 'What owner-approved repair, removal or retained ownership applies to %s (%s)? Keep it; no removal or forced cleanup is authorized.' "$2" "$3" ;;
    copy-head-resolved) printf 'Which verified commit holds the work in %s (%s)? Keep the copy; no discard is authorized.' "$2" "$3" ;;
    copy-anchor-commit) printf 'Which commit does the existing preservation anchor protect, and does it cover %s (%s)? Keep the copy and the anchor; no overwrite is authorized.' "$2" "$3" ;;
    *) printf 'What verified landing or retained ownership covers %s (%s)? Keep this copy until that evidence exists; no discard is authorized.' "$2" "$3" ;;
  esac
}

# One event per refused copy/predicate, not another event for the registered-copy
# wrapper that repeats it. The command re-enters the existing proof/preservation
# owner without force, so a forced or legacy-record run, which it could not
# complete, gets a human-only exit instead. A new custody/disposition decision is
# asked explicitly.
teardown_refuse_copy() {  # <rule> <missing> <copy> [new-question]
  local command kind=machine exit_text missing=$2 revision=${FM_FRICTION_REVISION_FILE:-$SCRIPT_DIR/fm-teardown-nested-lib.sh}
  # An unavailable inspection is not a policy judgment. The later custody
  # wrapper repeats this diagnostic without manufacturing a policy event.
  if [ "$1" = inspection-unavailable ]; then
    printf 'error: %s\n' "$2" >&2
    TEARDOWN_REFUSED_COPIES+=("$3")
    return 0
  fi
  if [ -n "${4:-}" ]; then
    kind=human-only
    exit_text=$4
  elif [ "${FORCE:-}" = --force ] || [ "${LEGACY_RECORD_GIVEN:-0}" = 1 ]; then
    kind=human-only
    exit_text="This run was forced or used a legacy record, so no completing command is printed. Once readable source and writable preservation storage are restored, which of the owner's own flags apply when the owner re-runs this teardown?"
  else
    printf -v command 'FM_HOME=%q bash %q %q' "$FM_HOME" "$SCRIPT_DIR/fm-teardown.sh" "$ID"
    exit_text=$command
    missing="$missing Restore readable source and writable preservation storage, then run the completing command."
  fi
  FM_HOME="$FM_HOME" FM_FRICTION_REVISION_FILE="$revision" \
    fm_refuse "$TEARDOWN_FRICTION_GUARD" "$1" "$missing" "$kind" "$exit_text" nested-copy "$3" "$ID"
  TEARDOWN_REFUSED_COPIES+=("$3")
}

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

# Reads into TEARDOWN_OWN_SCAN the "pid<TAB>cwd" lines of the processes whose cwd
# is exactly a root the retire phase sweeps (the task's copy, the returned slot,
# a nested copy of the task, its scratch directory). Fails when a scan fails.
teardown_own_scan() {
  local root out owned_pid owned_path
  TEARDOWN_OWN_SCAN=
  TEARDOWN_OWN_SCANNED=0
  for root in "$WT" "$TEARDOWN_RETURN_SLOT" "$TASK_TMP" \
      ${TEARDOWN_NESTED_COPIES[@]+"${TEARDOWN_NESTED_COPIES[@]}"}; do
    [ -n "$root" ] && [ -d "$root" ] || continue
    root=$(cd "$root" && pwd -P) || return 1
    out=$(pids_with_cwd_under "$root") || return 1
    while IFS=$'\t' read -r owned_pid owned_path; do
      [ "$owned_path" != "$root" ] || TEARDOWN_OWN_SCAN+="$owned_pid"$'\t'"$owned_path"$'\n'
    done <<< "$out"
  done
  TEARDOWN_OWN_SCANNED=1
}

# Is <pid> a process this teardown ends itself: one in TEARDOWN_OWN_SCAN, or a
# descendant of one by parent chain? Sets TEARDOWN_OWN_CWD to the cwd of the
# process it was found through. A scan that fails says no, so the process then
# counts as foreign. Callers reset TEARDOWN_OWN_SCANNED to read the process table
# afresh.
teardown_pid_is_task_own() {  # <pid>
  local pid=$1 owned_pid owned_path hops=0
  TEARDOWN_OWN_CWD=
  [ "$TEARDOWN_OWN_SCANNED" = 1 ] || teardown_own_scan || return 1
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] && [ "$hops" -lt 64 ]; do
    while IFS=$'\t' read -r owned_pid owned_path; do
      [ "$owned_pid" != "$pid" ] || { TEARDOWN_OWN_CWD=$owned_path; return 0; }
    done <<< "$TEARDOWN_OWN_SCAN"
    pid=$(LC_ALL=C ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]') || return 1
    hops=$((hops + 1))
  done
  return 1
}

# Records live own process <pid>, just found by teardown_pid_is_task_own, for the
# retire phase to signal.
teardown_foreign_proc_record() {  # <pid>
  local identity
  if identity=$(task_process_identity "$1"); then
    TEARDOWN_FOREIGN_PROCS+=("$1"$'\t'"$identity"$'\t'"$TEARDOWN_OWN_CWD")
  fi
}

# Ignored entries no commit holds that must be preserved before removal.
# Symlinks, caches, virtual environments, Firstmate's own hook files, and
# regenerable build output are derived machinery and are skipped; every other
# entry is printed for teardown_preserve_ignored to copy.
teardown_preservable_ignored() {  # <copy>
  local copy=$1 listing entry name child rc=0
  listing=$(mktemp "${TMPDIR:-/tmp}/fm-teardown-ignored.XXXXXX") || return 1
  git -C "$copy" ls-files --others --ignored --exclude-standard --directory -z >"$listing" 2>/dev/null || rc=$?
  if [ "$rc" = 0 ]; then
    while IFS= read -r -d '' entry; do
      entry=${entry%/}
      [ ! -L "$copy/$entry" ] || continue
      name=${entry##*/}
      case "$entry" in .claude|.claude/*|.opencode|.opencode/*) continue ;; esac
      case "$entry" in scripts/hooks/_conformance_manifest.json|.tac/tmp|.tac/tmp/*|.tac/uv-cache|.tac/uv-cache/*) continue ;; esac
      if [ "$entry" = .tac ] && [ -d "$copy/.tac" ]; then
        for child in "$copy/.tac"/* "$copy/.tac"/.[!.]*; do
          { [ -e "$child" ] && [ ! -L "$child" ]; } || continue
          case "${child##*/}" in tmp|uv-cache) ;; *) printf '%s\n' ".tac/${child##*/}" ;; esac
        done
        continue
      fi
      case "$name" in
        .venv|venv|node_modules|__pycache__|.pytest_cache|.ruff_cache|.mypy_cache|.DS_Store|.fm-grok-turnend|.fm-kimi-turnend) continue ;;
        .import_linter_cache|.next|graphify-out|*.tsbuildinfo) continue ;;
      esac
      printf '%s\n' "$entry"
    done <"$listing"
  fi
  rm -f "$listing"
  return "$rc"
}

# Prints the SHA-256 of file <path>, or of standard input when no path is given.
# Fails when no hashing tool is available or it yields no digest.
teardown_ignored_sha256() {  # [<path>]
  local hash
  if command -v shasum >/dev/null 2>&1; then
    hash=$(shasum -a 256 ${1:+"$1"} 2>/dev/null | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(sha256sum ${1:+"$1"} 2>/dev/null | awk '{print $1}')
  else
    return 1
  fi
  case "$hash" in ''|*[!0-9a-f]*) return 1 ;; esac
  printf '%s\n' "$hash"
}

# Copies every preservable ignored entry of <copy> into
# $DATA/$ID/nested-copy-preserved/<copy-path-sha256> and records each file's
# SHA-256 in its SHA256SUMS. The new copy is built in a staging directory and
# replaces an earlier preserve of the same copy only after every entry is copied
# and hashed, so a failed run never costs the earlier one. Returns 1 when
# anything cannot be listed, copied or hashed, and the caller then refuses the
# copy rather than removing unpreserved content.
teardown_preserve_ignored() {  # <copy>
  local copy=$1 root dest stage entries entry file hash
  entries=$(teardown_preservable_ignored "$copy") || return 1
  [ -n "$entries" ] || return 0
  hash=$(printf '%s' "$copy" | teardown_ignored_sha256) || return 1
  root="$DATA/$ID/nested-copy-preserved"
  dest="$root/$hash"
  stage="$root/.staging-$hash"
  rm -rf "$stage" || return 1
  mkdir -p "$stage" || return 1
  printf '%s\n' "$copy" > "$stage/copy-path" || return 1
  : > "$stage/SHA256SUMS" || return 1
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in /*|..|../*|*/..|*/../*) return 1 ;; esac
    rm -rf "${stage:?}/$entry" || return 1
    mkdir -p "$(dirname "$stage/$entry")" || return 1
    cp -RPp "$copy/$entry" "$stage/$entry" || return 1
  done <<< "$entries"
  while IFS= read -r -d '' file; do
    hash=$(teardown_ignored_sha256 "$file") || return 1
    printf '%s  %s\n' "$hash" "${file#"$stage/"}" >> "$stage/SHA256SUMS" || return 1
  done < <(find "$stage" -type f ! -path "$stage/copy-path" ! -path "$stage/SHA256SUMS" -print0)
  rm -rf "$dest" || return 1
  mv "$stage" "$dest" || return 1
  echo "teardown: preserved ignored files from $copy in $dest" >&2
}

# Does an active record, a running process, or a live lock launcher outside this
# teardown own <copy>? Returns 1 with TEARDOWN_FOREIGN_WHY set when so or when
# that cannot be told.
teardown_foreign_copy_unowned() {  # <copy>
  local copy=$1 rc=0 pids pid
  TEARDOWN_OWN_SCANNED=0
  # shellcheck disable=SC2153 # STATE is bin/fm-teardown.sh's global, not a typo of a local.
  fm_task_copy_other_record "$META" "$STATE" "$copy" || rc=$?
  case "$rc" in
    0)
      TEARDOWN_FOREIGN_RULE=active-record-owner
      TEARDOWN_FOREIGN_WHY="task $FM_TASK_COPY_OTHER_ID's active record names it as its $FM_TASK_COPY_OTHER_FIELD"
      return 1
      ;;
    1) ;;
    *)
      TEARDOWN_FOREIGN_RULE=inspection-unavailable
      TEARDOWN_FOREIGN_WHY="the active task records could not be read"
      return 1
      ;;
  esac
  if ! pids=$(pids_with_cwd_under "$copy"); then
    TEARDOWN_FOREIGN_RULE=inspection-unavailable
    TEARDOWN_FOREIGN_WHY="a scan for processes running in it failed"
    return 1
  fi
  while IFS=$'\t' read -r pid _; do
    [ -n "$pid" ] || continue
    if ! teardown_pid_is_task_own "$pid"; then
      TEARDOWN_FOREIGN_RULE=process-cwd-owner
      TEARDOWN_FOREIGN_WHY="process $pid is running in it"
      return 1
    fi
    teardown_foreign_proc_record "$pid"
  done <<< "$pids"
  rc=0
  teardown_copy_lock_file "$copy" || rc=$?
  case "$rc" in
    0)
      if ! pid=$(teardown_vernant_lock_pid "$TEARDOWN_FOREIGN_LOCK"); then
        TEARDOWN_FOREIGN_RULE=creation-lock-owner
        TEARDOWN_FOREIGN_WHY="it is locked by something other than Vernant's creation lock (${TEARDOWN_FOREIGN_LOCK:-no reason given})"
        return 1
      fi
      if teardown_lock_launcher_may_be_live "$pid" "$TEARDOWN_FOREIGN_LOCK_FILE"; then
        if ! teardown_pid_is_task_own "$pid"; then
          TEARDOWN_FOREIGN_RULE='lock-launcher-owner'
          TEARDOWN_FOREIGN_WHY="its creation-lock launcher process $pid may still be running"
          return 1
        fi
        teardown_foreign_proc_record "$pid"
      fi
      ;;
    1) ;;
    *)
      TEARDOWN_FOREIGN_RULE=inspection-unavailable
      TEARDOWN_FOREIGN_WHY="its lock state cannot be read"
      return 1
      ;;
  esac
}

# Proves foreign copy <copy>, or returns 1 with TEARDOWN_FOREIGN_WHY naming what
# could not be proved. Writes nothing. A half-removed or unreadable copy fails
# the first check. The landed-work rule gets an empty branch name so it never
# adopts this copy's PR as the task's recorded one.
teardown_foreign_copy_prove() {  # <copy>
  local copy=$1 rc=0
  TEARDOWN_FOREIGN_WHY=
  TEARDOWN_FOREIGN_RULE='copy-unowned'
  fm_task_copy_preserve "$PROJ" "$ID" "$copy" 0 || rc=$?
  if [ "$rc" = 1 ]; then
    TEARDOWN_FOREIGN_RULE=${FM_TASK_COPY_STABLE:-inspection-unavailable}
    [ -z "$FM_TASK_COPY_DIRTY" ] || TEARDOWN_FOREIGN_RULE='copy-preserved'
    TEARDOWN_FOREIGN_WHY="it $FM_TASK_COPY_REASON"
    return 1
  fi
  teardown_foreign_copy_unowned "$copy" || return 1
  if ! teardown_landed "$copy" HEAD ""; then
    TEARDOWN_FOREIGN_RULE='copy-landed'
    TEARDOWN_FOREIGN_WHY="its HEAD ${FM_TASK_COPY_HEAD:0:12} is not proved landed"
    return 1
  fi
}

# Proves every foreign copy in <slot> and records the provable ones in
# TEARDOWN_FOREIGN_COPIES. An unprovable copy is named here and then refused by
# the registered-copy check, which does not list it as allowed.
teardown_foreign_copies_prove() {  # <slot>
  local slot=$1 copy known allowed
  TEARDOWN_FOREIGN_COPIES=()
  TEARDOWN_FOREIGN_PROCS=()
  teardown_slot_registered_copies "$slot" || return 0
  slot=$(fm_task_copy_canonical_dir "$slot") || return 0
  for copy in ${TEARDOWN_SLOT_COPIES[@]+"${TEARDOWN_SLOT_COPIES[@]}"}; do
    known=0
    for allowed in ${TEARDOWN_NESTED_COPIES[@]+"${TEARDOWN_NESTED_COPIES[@]}"}; do
      [ "$copy" != "$allowed" ] || known=1
    done
    [ "$known" = 0 ] || continue
    if teardown_foreign_copy_prove "$copy"; then
      TEARDOWN_FOREIGN_COPIES+=("$copy")
    else
      teardown_refuse_copy "$TEARDOWN_FOREIGN_RULE" "foreign copy $copy stays in pool slot $slot: $TEARDOWN_FOREIGN_WHY." "$copy" \
        "$(teardown_copy_question "$TEARDOWN_FOREIGN_RULE" "$copy" "$TEARDOWN_FOREIGN_WHY")"
    fi
  done
}

# Sends TERM, once and whatever its cwd, to each live lock launcher and each
# process running in a copy that teardown_pid_is_task_own proved to be this
# teardown's own, and waits briefly for them to exit. It runs before the cwd
# sweep, which refuses a process inside a nested copy and does not reach a
# descendant whose cwd lies outside its roots. Each signal is audited first, as
# the sweep's are; a recorded process that has gone or no longer has its recorded
# birth identity is skipped. No KILL is sent: a process still alive after the
# wait is refused by pid, by the sweep when it is in the copy and by the release
# proof otherwise.
teardown_foreign_procs_retire() {
  local record pid identity cwd i
  local -a signalled_pids=() signalled_identities=()
  for record in ${TEARDOWN_FOREIGN_PROCS[@]+"${TEARDOWN_FOREIGN_PROCS[@]}"}; do
    IFS=$'\t' read -r pid identity cwd <<< "$record"
    case " ${signalled_pids[*]-} " in *" $pid "*) continue ;; esac
    task_process_identity_matches "$pid" "$identity" || continue
    TASK_SCAN_PIDS=("$pid")
    TASK_PID_CWDS=("$cwd")
    if task_record_process_signal "$pid" "$identity" TERM; then
      :
    else
      [ "$?" -ne 2 ] || continue
      echo "REFUSED: cannot durably record process $pid identity for $ID; preserving the worktree without signalling it." >&2
      return 1
    fi
    task_process_identity_matches "$pid" "$identity" || continue
    kill -TERM "$pid" 2>/dev/null || true
    signalled_pids+=("$pid")
    signalled_identities+=("$identity")
  done
  [ "${#signalled_pids[@]}" -gt 0 ] || return 0
  for _ in $(seq 1 30); do
    for i in "${!signalled_pids[@]}"; do
      if task_process_identity_matches "${signalled_pids[$i]}" "${signalled_identities[$i]}"; then
        sleep 0.1
        continue 2
      fi
    done
    return 0
  done
}

# Runs Vernant's closeout driver on <copy>: it releases its own creation lock
# and removes the copy. Output lands in TEARDOWN_CLOSEOUT_OUT. Exit 0 means the
# driver allowed and ran the cleanup.
teardown_run_closeout() {  # <slot> <copy>
  local slot=$1 copy=$2 driver py rc=0
  TEARDOWN_CLOSEOUT_OUT=
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

# Preserves the ignored files of one proved foreign copy, then releases and
# removes it. Returns 1 after printing a refusal.
teardown_foreign_copy_dispose() {  # <slot> <copy>
  local slot=$1 copy=$2 rc=0
  teardown_preserve_ignored "$copy" || {
    teardown_refuse_copy ignored-bytes-preserved "the ignored files of foreign copy $copy could not be preserved in $DATA/$ID/nested-copy-preserved; it was not removed." "$copy"
    return 1
  }
  teardown_copy_lock_file "$copy" || rc=$?
  case "$rc" in
    0)
      if ! teardown_vernant_lock_pid "$TEARDOWN_FOREIGN_LOCK" >/dev/null; then
        teardown_refuse_copy creation-lock-owner "foreign copy $copy is locked by something other than Vernant's creation lock; it was not removed." "$copy" \
          "Who owns the lock on $copy, and what owner-approved release is supported? No lock removal or forced cleanup is authorized."

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
        teardown_refuse_copy nonforced-removal "git worktree remove would not remove foreign copy $copy without force; it was not removed." "$copy" \
          "What retained disposition covers the contents Git still protects in $copy? Preserve this copy; no forced removal is authorized."
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
  echo "teardown: removed landed foreign copy $copy from pool slot $slot" >&2
  teardown_friction_outcome retry-succeeded "$copy"
}

# Releases every proved foreign copy of TEARDOWN_RETURN_SLOT. Each copy is
# proved again first, so a process or edit that appeared since is caught, and all
# are proved before any is changed. A copy nested in another is removed first,
# which reverse path order guarantees: an enclosing path is a prefix of the
# paths inside it.
teardown_foreign_copies_release() {
  local slot=$TEARDOWN_RETURN_SLOT copy
  local -a ordered=()
  [ -n "$slot" ] && [ "${#TEARDOWN_FOREIGN_COPIES[@]}" -gt 0 ] || return 0
  slot=$(fm_task_copy_canonical_dir "$slot") || return 1
  for copy in "${TEARDOWN_FOREIGN_COPIES[@]}"; do
    if ! teardown_foreign_copy_prove "$copy"; then
      teardown_refuse_copy "$TEARDOWN_FOREIGN_RULE" "foreign copy $copy in pool slot $slot is no longer provable: $TEARDOWN_FOREIGN_WHY; nothing was removed." "$copy" \
        "$(teardown_copy_question "$TEARDOWN_FOREIGN_RULE" "$copy" "$TEARDOWN_FOREIGN_WHY")"
      return 1
    fi
  done
  while IFS= read -r copy; do
    ordered+=("$copy")
  done < <(printf '%s\n' "${TEARDOWN_FOREIGN_COPIES[@]}" | LC_ALL=C sort -r)
  for copy in "${ordered[@]}"; do
    teardown_foreign_copy_dispose "$slot" "$copy" || return 1
  done
  TEARDOWN_FOREIGN_COPIES=()
}

# Proves the task's own nested copies that Vernant's creation lock holds, or
# returns 1 after printing a refusal naming the copy and what could not be
# proved. Changes no copy contents; a policy refusal records optional telemetry.
# The caller has already proved each own copy clean and
# landed or anchored; this adds what a lock-releasing removal needs. A copy that
# is not locked, or whose lock state cannot be read, is left to the plain removal.
# Run it after teardown_foreign_copies_prove, which resets
# TEARDOWN_FOREIGN_PROCS, so the live launchers it records reach the retire phase.
teardown_own_locked_copies_prove() {
  local copy rc
  for copy in ${TEARDOWN_NESTED_COPIES[@]+"${TEARDOWN_NESTED_COPIES[@]}"}; do
    [ -d "$copy" ] || continue
    rc=0
    teardown_copy_lock_file "$copy" || rc=$?
    [ "$rc" = 0 ] || continue
    TEARDOWN_FOREIGN_WHY=
    TEARDOWN_FOREIGN_RULE=creation-lock-owner
    if ! teardown_vernant_lock_pid "$TEARDOWN_FOREIGN_LOCK" >/dev/null; then
      TEARDOWN_FOREIGN_WHY="it is locked by something other than Vernant's creation lock (${TEARDOWN_FOREIGN_LOCK:-no reason given})"
    else
      # A peer reassociated off this slot into its own copy is not another
      # record naming the copy through the root it left.
      FM_TASK_COPY_RELEASED_PRIOR_RETIRING=$META
      teardown_foreign_copy_unowned "$copy" || true
      FM_TASK_COPY_RELEASED_PRIOR_RETIRING=
    fi
    if [ -n "$TEARDOWN_FOREIGN_WHY" ]; then
      teardown_refuse_copy "${TEARDOWN_FOREIGN_RULE:-creation-lock-owner}" "own nested copy $copy stays in pool slot ${TEARDOWN_RETURN_SLOT:-${TEARDOWN_PEER_SLOT:-}}: $TEARDOWN_FOREIGN_WHY." "$copy" \
        "Who owns the remaining lock or active use of $copy, and what owner-approved release is supported? No forced cleanup is authorized."
      return 1
    fi
  done
}

# Preserves the ignored files of one proved own nested copy that Vernant's
# creation lock holds, then releases and removes it. Returns 1 after printing a
# refusal.
teardown_own_copy_dispose() {  # <slot> <copy>
  local slot=$1 copy=$2 rc=0
  teardown_copy_lock_file "$copy" || rc=$?
  if [ "$rc" != 0 ] || ! teardown_vernant_lock_pid "$TEARDOWN_FOREIGN_LOCK" >/dev/null; then
    echo "REFUSED: own nested copy $copy is not locked by Vernant's creation lock any more; it was not removed." >&2
    return 1
  fi
  teardown_preserve_ignored "$copy" || {
    teardown_refuse_copy ignored-bytes-preserved "the ignored files of own nested copy $copy could not be preserved in $DATA/$ID/nested-copy-preserved; it was not removed." "$copy"
    return 1
  }
  rc=0
  teardown_run_closeout "$slot" "$copy" || rc=$?
  if [ "$rc" != 0 ]; then
    echo "REFUSED: Vernant's closeout driver did not release own nested copy $copy (exit $rc): ${TEARDOWN_CLOSEOUT_OUT:0:600}" >&2
    return 1
  fi
  if teardown_foreign_copy_present "$slot" "$copy"; then
    echo "REFUSED: own nested copy $copy is still present or registered after its release; the pool slot was not returned." >&2
    return 1
  fi
  echo "teardown: removed landed own nested copy $copy from pool slot $slot" >&2
  teardown_friction_outcome retry-succeeded "$copy"
}

# Releases every own nested copy of the task that Vernant's creation lock holds.
# All are proved again first, so nothing is removed when one is no longer
# provable, and a copy nested in another goes first (reverse path order). An own
# copy that is not locked is left to the plain removal in bin/fm-teardown.sh.
# Like the foreign copies, it runs before the final project-lock wait.
teardown_own_locked_copies_release() {
  local slot=${TEARDOWN_RETURN_SLOT:-${TEARDOWN_PEER_SLOT:-}} copy rc
  local -a ordered=()
  [ -n "$slot" ] && [ "${#TEARDOWN_NESTED_COPIES[@]}" -gt 0 ] || return 0
  slot=$(fm_task_copy_canonical_dir "$slot") || return 1
  teardown_own_locked_copies_prove || {
    echo "REFUSED: an own nested copy in pool slot $slot is no longer provable; nothing was removed." >&2
    return 1
  }
  while IFS= read -r copy; do
    ordered+=("$copy")
  done < <(printf '%s\n' "${TEARDOWN_NESTED_COPIES[@]}" | LC_ALL=C sort -r)
  for copy in "${ordered[@]}"; do
    [ -d "$copy" ] || continue
    rc=0
    teardown_copy_lock_file "$copy" || rc=$?
    [ "$rc" = 0 ] || continue
    teardown_own_copy_dispose "$slot" "$copy" || return 1
    TEARDOWN_OWN_RELEASED+=("$copy")
  done
}
