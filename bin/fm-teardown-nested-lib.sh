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
#     with its SHA-256 into $DATA/$ID/nested-copy-preserved before removal; a
#     foreign copy that holds any other ignored file is held, below, instead of
#     released wherever the hold applies (teardown_foreign_copy_hold_applies),
#     and is preserved and released as above wherever it does not;
#   - no other active task record names it, no process outside this teardown's
#     own runs in it, no other process holds a file in it open (a macOS search
#     indexer, which only reads, is exempt), and no live process outside this
#     teardown's own is its
#     lock launcher (a process is this teardown's own when it, or an ancestor by
#     parent chain, has a cwd exactly at a root retire sweeps, and a pid that
#     started after the lock file was written is recycled and owns nothing). The
#     retire phase sends TERM to each such launcher and each such process running
#     in the copy, waits a bounded time, and sends no KILL; one still alive
#     refuses the release, named by its pid. A process that is not this
#     teardown's own is never signalled and refuses at once, named by its pid;
#   - teardown_landed proves delivery or the recorded bundle alternative owned
#     by bin/fm-teardown.sh's header; the closeout driver keeps its own verdict.
# A copy with neither proof stays, and teardown names why.
# One refusal class does not stop the task's own closure. A copy that is clean,
# owned by no record, process or live launcher, and held back only by ignored
# files that exist nowhere else or by a HEAD that is not proved landed is HELD:
# when every refused copy in the slot is of that class and the task's own copy
# already passed the landed-work proof, bin/fm-teardown.sh closes the task and
# reserves the slot under a durable lease, defers its return and leaves every
# foreign copy exactly as it was (teardown_held_copies_record appends each one to
# data/held-foreign-copies.log before anything is removed). Nothing here ever
# removes or alters a held copy, and --force never holds one.
# The task's own nested copies (the record's worktree= and prior_worktree= copies
# inside the slot) were already proved clean and landed or anchored by the
# caller. One of them that Vernant's creation lock holds is released the same
# way, never by forcing the removal: its ignored files are preserved as above,
# no process outside this teardown may run in it, hold a file in it open or be
# its live lock launcher,
# and no other active record may name it; the driver then verifies the landing
# again and refuses what it cannot prove. An own copy that is not locked is
# removed with a plain non-forced git worktree remove after the final removal
# proof (scout, secondmate and operator --force keep the forced removal).
# A copy locked by Vernant's creation lock is released and removed by Vernant's
# own driver (closeout_pr.py --cleanup-worktree <copy> --execute-cleanup, run
# from the slot with FM_TEARDOWN_VERNANT_PYTHON or <slot>/.venv/bin/python) with
# the one credit teardown_closeout_credit proved (--pr or --bundle-record, never
# both), and, for the residue the driver cannot release, by
# teardown_dead_launcher_release. bin/fm-teardown.sh's header owns that rule. An
# unlocked copy is removed with a plain non-forced git worktree remove. A lock in
# any other format, a live launcher, a driver refusal outside that residue, or a
# copy still registered afterwards refuses. Removal deletes the copy's checkout and the allow-listed ignored files
# in it (symlinks, virtual environments, node_modules and tool caches,
# .DS_Store, Firstmate's hook files, regenerable build caches, and anything
# ignored under its .claude and .opencode trees); it loses no commit, because
# the work is landed or held by a recorded bundle, and no tracked change,
# because the clean proof refuses one.
# Any other ignored entry is copied to the task's data directory before removal.
# The clean proof skips
# untracked files under .claude only; the ignored-file proof skips ignored files
# under .claude and .opencode; plain git worktree remove still refuses a copy
# that holds an untracked file. On the pool-slot route the release runs before
# the final project-lock wait, so the driver never runs while the lock is held;
# under project custody kept through the return a locked copy is deferred.
#
# Requires bin/fm-task-copy-lib.sh, bin/fm-lock-lib.sh and bin/fm-refuse-lib.sh first,
# and runs inside bin/fm-teardown.sh, whose globals (PROJ, ID, DATA, META,
# STATE, WT, TASK_TMP, FORCE, KIND, LEGACY_RECORD_GIVEN, TEARDOWN_NESTED_COPIES,
# TEARDOWN_RETURN_SLOT, TEARDOWN_PEER_SLOT, TEARDOWN_HELD_SLOT) and functions
# (teardown_landed, pids_with_cwd_under, pids_with_open_file_under,
# task_process_identity,
# task_process_identity_matches, task_record_process_signal) it uses.
# bin/fm-copy-sweep.sh also calls teardown_preserve_ignored, with DATA set to its
# data directory and ID to a per-release id, for a copy it proved on its own, and
# teardown_run_closeout for such a copy that is locked.

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
# One "copy<TAB>reason" entry per held foreign copy of the last
# teardown_foreign_copies_prove, the hold class of each (ignored or commits) in
# the same order, how many of its refusals were not holdable, and the refusals it
# has not printed yet (see that function), kept as parallel arrays because a copy
# path may hold any character, newlines included.
TEARDOWN_FOREIGN_HELD=()
TEARDOWN_FOREIGN_HELD_KIND=()
TEARDOWN_FOREIGN_REFUSED=0
TEARDOWN_DEF_RULE=()
TEARDOWN_DEF_WHY=()
TEARDOWN_DEF_PID=()
TEARDOWN_DEF_COPY=()
TEARDOWN_DEF_DIAG=()
TEARDOWN_FOREIGN_LOCK=
TEARDOWN_FOREIGN_LOCK_FILE=
TEARDOWN_SLOT_COPIES=()
TEARDOWN_CLOSEOUT_OUT=
TEARDOWN_CLOSEOUT_STDOUT=
TEARDOWN_FOREIGN_RULE=
TEARDOWN_FOREIGN_PID=
# The last record teardown_bundle_record read; empty until a read, so a reader
# on a path that returned before the read sees no record instead of an unset name.
TEARDOWN_BUNDLE_RECORD_PATH=
TEARDOWN_BUNDLE_RECORD_HASH=
TEARDOWN_BUNDLE_RECORD_TIPS=
TEARDOWN_REFUSED_COPIES=()
TEARDOWN_FRICTION_GUARD=FM-TEARDOWN-PRESERVATION

# One operation per teardown process: the environment's when this run is a
# printed completing command, else minted with its first refusal. The outcome
# of a copy is recorded only for an operation a refusal already holds.
teardown_friction_outcome() {  # <outcome> [<copy>]
  FM_HOME="$FM_HOME" fm_friction_outcome "$1" "$TEARDOWN_FRICTION_GUARD" nested-copy "${2:-}" "$ID"
}

# The one human-only question of <rule>, whatever site refuses it. The failed
# proof's TEARDOWN_FOREIGN_WHY and TEARDOWN_FOREIGN_PID complete the rules that
# name them.
teardown_copy_question() {  # <rule> <copy>
  case "$1" in
    copy-worktree-root) printf 'What owner-approved repair, removal or retained ownership applies to %s (%s)? Keep it; no removal or forced cleanup is authorized.' "$2" "$TEARDOWN_FOREIGN_WHY" ;;
    copy-head-resolved) printf 'Which verified commit holds the work in %s (%s)? Keep the copy; no discard is authorized.' "$2" "$TEARDOWN_FOREIGN_WHY" ;;
    copy-ignored-files) printf 'What owner-approved disposition covers the ignored files only %s holds (%s)? Keep the copy; no removal or discard is authorized.' "$2" "$TEARDOWN_FOREIGN_WHY" ;;
    copy-anchor-commit) printf 'Which commit does the existing preservation anchor protect, and does it cover %s (%s)? Keep the copy and the anchor; no overwrite is authorized.' "$2" "$TEARDOWN_FOREIGN_WHY" ;;
    process-cwd-owner) printf 'Which task or person owns process %s, which is running in %s? Stop it or tell me it is yours.' "${TEARDOWN_FOREIGN_PID:-unknown}" "$2" ;;
    process-open-file-owner) printf 'Which task or person owns process %s, which holds a file in %s open? Stop it or tell me it is yours.' "${TEARDOWN_FOREIGN_PID:-unknown}" "$2" ;;
    lock-launcher-owner) printf 'Is launcher %s, named in the creation lock on %s, still running, and who owns it?' "${TEARDOWN_FOREIGN_PID:-unknown}" "$2" ;;
    creation-lock-owner) printf 'Who owns the creation lock on %s, and may it be released?' "$2" ;;
    nonforced-removal) printf 'What retained disposition covers the contents Git still protects in %s? Preserve this copy; no forced removal is authorized.' "$2" ;;
    registered-copy-proven) printf 'Which task and home retain the work in %s, or what verified landing covers it? No discard or forced removal is authorized.' "$2" ;;
    ignored-bytes-preserved) printf "This run was forced or used a legacy record, so no completing command is printed. Once readable source and writable preservation storage are restored, which of the owner's own flags apply when the owner re-runs this teardown?" ;;
    final-removal-proof) printf "This run was forced or used a legacy record, so no completing command is printed. Which of the owner's own flags apply when the owner re-runs this teardown for a fresh proof of %s?" "$2" ;;
    *) printf 'What verified landing or retained ownership covers %s (%s)? Keep this copy until that evidence exists; no discard is authorized.' "$2" "$TEARDOWN_FOREIGN_WHY" ;;
  esac
}

# One event per refused copy/predicate, not another event for the registered-copy
# wrapper that repeats it. The command re-enters the existing proof/preservation
# owner without force, so a forced or legacy-record run, which it could not
# complete, gets a human-only exit instead. A new custody/disposition decision is
# asked explicitly.
teardown_refuse_copy() {  # <rule> <missing> <copy>
  local command kind=human-only exit_text missing=$2 revision=${FM_FRICTION_REVISION_FILE:-$SCRIPT_DIR/fm-teardown-nested-lib.sh}
  # An unavailable inspection is not a policy judgment. The later custody
  # wrapper repeats this diagnostic without manufacturing a policy event.
  if [ "$1" = inspection-unavailable ]; then
    printf 'error: %s\n' "$(fm_refuse_text "$2")" >&2
    TEARDOWN_REFUSED_COPIES+=("$3")
    return 0
  fi
  exit_text=$(teardown_copy_question "$1" "$3")
  if [ "$1" = ignored-bytes-preserved ] && [ "${FORCE:-}" != --force ] && [ "${LEGACY_RECORD_GIVEN:-0}" != 1 ]; then
    kind=machine
    printf -v command 'FM_HOME=%q bash %q %q' "$FM_HOME" "$SCRIPT_DIR/fm-teardown.sh" "$ID"
    exit_text=$command
    missing="$missing Restore readable source and writable preservation storage, then run the completing command."
  elif [ "$1" = final-removal-proof ] && [ "${FORCE:-}" != --force ] && [ "${LEGACY_RECORD_GIVEN:-0}" != 1 ]; then
    # The copy changed after its proof: an ordinary re-run proves it afresh.
    kind=machine
    printf -v command 'FM_HOME=%q bash %q %q' "$FM_HOME" "$SCRIPT_DIR/fm-teardown.sh" "$ID"
    exit_text=$command
    missing="$missing Run the completing command for a fresh proof."
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
TEARDOWN_FOREIGN_LOCK_SHA=
teardown_copy_lock_file() {  # <copy>
  local copy=$1 admin size line
  TEARDOWN_FOREIGN_LOCK=
  TEARDOWN_FOREIGN_LOCK_SHA=
  TEARDOWN_FOREIGN_LOCK_FILE=
  [ -f "$copy/.git" ] && [ ! -L "$copy/.git" ] || return 2
  admin=$(git -C "$copy" rev-parse --absolute-git-dir 2>/dev/null) || return 2
  [ -n "$admin" ] || return 2
  if [ ! -e "$admin/locked" ] && [ ! -L "$admin/locked" ]; then
    return 1
  fi
  [ -f "$admin/locked" ] && [ ! -L "$admin/locked" ] || return 2
  IFS= read -r TEARDOWN_FOREIGN_LOCK < "$admin/locked" || [ -n "$TEARDOWN_FOREIGN_LOCK" ] || true
  TEARDOWN_FOREIGN_LOCK_SHA=$(teardown_ignored_sha256 "$admin/locked") || return 2
  size=$(wc -c < "$admin/locked") || return 2
  size=${size//[!0-9]/}
  line=$(printf '%s' "$TEARDOWN_FOREIGN_LOCK" | wc -c) || return 2
  line=${line//[!0-9]/}
  # Git writes a reason as one line ended by a newline. A lock file holding any
  # other bytes is not that reason, so it never reads as Vernant's lock.
  if [ "${size:-0}" != 0 ] && [ "${size:-0}" != "$((${line:-0} + 1))" ]; then
    TEARDOWN_FOREIGN_LOCK="$TEARDOWN_FOREIGN_LOCK (and further lock file content)"
  fi
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

# When <pid> started, in seconds since the epoch: ps lstart, or, where ps cannot
# run (a confined worker), the confined table's (bin/fm-proc-info.py lstart). An
# absolute start time, so a slow reading never moves it.
teardown_pid_start_epoch() {  # <pid>
  local start
  start=$(LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null) \
    || start=$(python3 "$FM_TASK_COPY_LIB_DIR/fm-proc-info.py" lstart "$1" 2>/dev/null) || return 1
  LC_ALL=C python3 -c 'import sys, time; print(int(time.mktime(time.strptime(" ".join(sys.argv[1].split()), "%a %b %d %H:%M:%S %Y"))))' "$start" 2>/dev/null
}

# Is the pid in a creation lock a launcher that may still be alive? The lock
# records only the launcher's pid, so the lock file's own time is the record of
# when it was written: a process that started later than that (an absolute
# start time, never an age read against the clock) cannot be the one that wrote
# it, because pids are recycled. A start time or lock time that cannot be read,
# or one in the same second, counts as live. Returns 0 when it may be alive, 1
# when it is gone or a recycled pid, and 2 when the process table cannot be
# read (fm_task_copy_launcher_state), which is never taken for absence.
teardown_lock_launcher_may_be_live() {  # <pid> <lock-file>
  local mtime
  mtime=$(fm_lock_path_mtime "$2") || mtime=
  teardown_launcher_live_since "$1" "$mtime"
}
# The same answer against a lock time read earlier (<lock-mtime>, empty when it
# could not be read), for a check made after the lock file is gone.
teardown_launcher_live_since() {  # <pid> <lock-mtime>
  local pid=$1 mtime=$2 started rc=0
  fm_task_copy_launcher_state "$pid" || rc=$?
  case "$rc" in
    0) ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
  started=$(teardown_pid_start_epoch "$pid") || return 0
  case "$started$mtime" in ''|*[!0-9]*) return 0 ;; esac
  [ "$started" -le "$mtime" ]
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

# Graft's generated output at the root of <copy>: the exact .ignore overlay graft
# writes, and a graft/ directory that git lists whole as one ignored entry (so it
# tracks nothing in it) and that holds no .git. Graft rebuilds that index from the
# tracked source and its hook and session files describe only this copy
# (data/fm-merge-prune-graft-scratch/report.md). bin/fm-merge-prune-lib.sh judges
# the same entries with this test.
teardown_graft_generated() {  # <copy> <ignored-entry>
  local nested
  case "$2" in
    .ignore)
      [ -f "$1/.ignore" ] && cmp -s "$1/.ignore" - <<'EOF'
# graft's cards are gitignored but should stay greppable: ripgrep reads
# .ignore before .gitignore, so this re-admits the tree to search only.
!graft/
graft/.cache/
graft/.graph/
EOF
      ;;
    graft)
      [ -d "$1/graft" ] && nested=$(find "$1/graft" -name .git -print -quit 2>/dev/null) && [ -z "$nested" ]
      ;;
    *) return 1 ;;
  esac
}

# The sweep's closed regenerable class: directories rebuilt from tracked lockfiles
# and sources. A release of a proven copy removes them with it unpreserved. This
# list decides only what preservation leaves out: it adds no pattern, and the
# sweep's activity fingerprints still read these directories, so a write inside one
# still holds a copy WAITING.
TEARDOWN_REGENERABLE_NAMES=(node_modules .venv venv __pycache__ .pytest_cache .mypy_cache .ruff_cache .next .turbo .cache)

# Prints each outermost directory at or under <root> whose name is in the class,
# each ended by a NUL byte, and fails when find fails. A symlink is never one,
# and find does not follow one.
teardown_regenerable_dirs() {  # <root>
  local name args=()
  for name in "${TEARDOWN_REGENERABLE_NAMES[@]}"; do
    args+=(-o -name "$name")
  done
  find "$1" -type d \( "${args[@]:1}" \) -print0 -prune 2>/dev/null
}

# Prints, relative to <copy>, the class's outermost directories inside its ignored
# entries.
# One per line, so it fails for a path that holds a newline.
teardown_regenerable_ignored() {  # <copy>
  local copy=$1 listing found entry dir rc=0
  listing=$(mktemp "${TMPDIR:-/tmp}/fm-teardown-ignored.XXXXXX") || return 1
  found=$(mktemp "${TMPDIR:-/tmp}/fm-teardown-ignored.XXXXXX") || { rm -f "$listing"; return 1; }
  git -C "$copy" ls-files --others --ignored --exclude-standard --directory -z >"$listing" 2>/dev/null || rc=$?
  if [ "$rc" = 0 ]; then
    while IFS= read -r -d '' entry; do
      teardown_regenerable_dirs "$copy/${entry%/}" >"$found" || { rc=1; break; }
      while IFS= read -r -d '' dir; do
        case "$dir" in *$'\n'*) rc=1; break 2 ;; esac
        printf '%s\n' "${dir#"$copy"/}"
      done <"$found"
    done <"$listing"
  fi
  rm -f "$listing" "$found"
  return "$rc"
}

# Prints ignored <entry> of <copy> without the class: whole when it holds none of
# those directories, otherwise split only as far as needed to leave them out.
teardown_entry_without_regenerable() {  # <copy> <entry>
  local copy=$1 entry=$2 found first='' rc=0 child
  found=$(mktemp "${TMPDIR:-/tmp}/fm-teardown-ignored.XXXXXX") || return 1
  teardown_regenerable_dirs "$copy/$entry" >"$found" || rc=1
  [ "$rc" != 0 ] || [ ! -s "$found" ] || IFS= read -r -d '' first <"$found" || rc=1
  rm -f "$found"
  [ "$rc" = 0 ] || return 1
  if [ -z "$first" ]; then
    printf '%s\0' "$entry"
    return 0
  fi
  [ "$first" != "$copy/$entry" ] || return 0
  for child in "$copy/$entry"/* "$copy/$entry"/.[!.]* "$copy/$entry"/..?*; do
    { [ -e "$child" ] || [ -L "$child" ]; } || continue
    teardown_entry_without_regenerable "$copy" "$entry/${child##*/}" || return 1
  done
}

teardown_print_entry() {  # <copy> <entry>
  printf '%s\0' "$2"
}

# Ignored entries no commit holds that must be preserved before removal.
# Symlinks, caches, virtual environments, Firstmate's own hook files, graft's
# generated output (teardown_graft_generated) and regenerable build output are
# derived machinery and are skipped; every other entry is printed for
# teardown_preserve_ignored to copy. A sweep release of a proven copy names a mode,
# and both modes leave out the regenerable class at any depth: releasable applies
# that to the list above, and all mode starts from every ignored entry, so the
# unlocked sweep can preserve the disposable bytes without widening this owner's
# disposable classification. Each entry is ended by a NUL byte, so any name Git
# can list keeps its exact bytes; a failed listing or scan fails the call.
teardown_preservable_ignored_z() {  # <copy> [all|releasable]
  local copy=$1 mode=${2:-} listing entry name child rc=0 emit=teardown_entry_without_regenerable
  case "$mode" in '') emit=teardown_print_entry ;; all|releasable) ;; *) return 1 ;; esac
  listing=$(mktemp "${TMPDIR:-/tmp}/fm-teardown-ignored.XXXXXX") || return 1
  git -C "$copy" ls-files --others --ignored --exclude-standard --directory -z >"$listing" 2>/dev/null || rc=$?
  if [ "$rc" = 0 ]; then
    while IFS= read -r -d '' entry; do
      entry=${entry%/}
      if [ "$mode" = all ]; then
        "$emit" "$copy" "$entry" || { rc=1; break; }
        continue
      fi
      [ ! -L "$copy/$entry" ] || continue
      ! teardown_graft_generated "$copy" "$entry" || continue
      name=${entry##*/}
      case "$entry" in .claude|.claude/*|.opencode|.opencode/*) continue ;; esac
      case "$entry" in scripts/hooks/_conformance_manifest.json|.tac/tmp|.tac/tmp/*|.tac/uv-cache|.tac/uv-cache/*) continue ;; esac
      if [ "$entry" = .tac ] && [ -d "$copy/.tac" ]; then
        for child in "$copy/.tac"/* "$copy/.tac"/.[!.]*; do
          { [ -e "$child" ] && [ ! -L "$child" ]; } || continue
          case "${child##*/}" in
            tmp|uv-cache) ;;
            *) "$emit" "$copy" ".tac/${child##*/}" || { rc=1; break 2; } ;;
          esac
        done
        continue
      fi
      case "$name" in
        .venv|venv|node_modules|__pycache__|.pytest_cache|.ruff_cache|.mypy_cache|.DS_Store|.fm-grok-turnend|.fm-kimi-turnend) continue ;;
        .import_linter_cache|.next|graphify-out|*.tsbuildinfo) continue ;;
      esac
      "$emit" "$copy" "$entry" || { rc=1; break; }
    done <"$listing"
  fi
  rm -f "$listing"
  return "$rc"
}

# The same entries one per line, for callers that read lines. A name that holds a
# newline cannot be told apart from two names that way, so the call fails for it
# and its caller keeps the copy; teardown's own preserve, readback and final
# proof read teardown_preservable_ignored_z instead.
teardown_preservable_ignored() {  # <copy> [all|releasable]
  local list entry rc=0
  list=$(mktemp "${TMPDIR:-/tmp}/fm-teardown-ignored.XXXXXX") || return 1
  teardown_preservable_ignored_z "$@" >"$list" || rc=1
  if [ "$rc" = 0 ]; then
    while IFS= read -r -d '' entry; do
      case "$entry" in *$'\n'*) rc=1; break ;; esac
      printf '%s\n' "$entry"
    done <"$list"
  fi
  rm -f "$list"
  return "$rc"
}

# The NUL-ended names in <file> as one line of text, sorted and each named once
# (Git can list a directory and an entry under it, which the .tac expansion then
# names again), a newline in a name shown as \n, for a refusal to print.
teardown_nul_list_text() {  # <file>
  local entry text=
  while IFS= read -r -d '' entry; do
    text+="${text:+ }${entry//$'\n'/\\n}"
  done < <(LC_ALL=C sort -z -u "$1")
  printf '%s' "$text"
}

# One SHA256SUMS line for <sum> and the relative path <rel>, in the escaped form
# sha256sum uses for a name with a newline or a backslash, so every file has
# exactly one line and no line can stand for another file's name.
teardown_manifest_line() {  # <sum> <rel>
  local rel=$2
  case "$rel" in
    *$'\n'*|*\\*)
      rel=${rel//\\/\\\\}
      rel=${rel//$'\n'/\\n}
      printf '\\%s  %s\n' "$1" "$rel"
      ;;
    *) printf '%s  %s\n' "$1" "$rel" ;;
  esac
}

# Prints the SHA-256 of file <path>, or of standard input when no path is given.
# Fails when no hashing tool is available, the file cannot be read, or the tool
# yields no digest. The file is read on standard input, so its name never reaches
# the tool's output (which escapes a name that holds a newline).
teardown_ignored_sha256() {  # [<path>]
  local hash
  if [ "$#" -gt 0 ]; then
    [ -f "$1" ] && [ -r "$1" ] || return 1
    teardown_ignored_sha256 < "$1"
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    hash=$(shasum -a 256 2>/dev/null | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(sha256sum 2>/dev/null | awk '{print $1}')
  else
    return 1
  fi
  case "$hash" in ''|*[!0-9a-f]*) return 1 ;; esac
  printf '%s\n' "$hash"
}

# Bundle preservation is separate from delivery, and is deliberately rechecked
# rather than placed in the immutable-HEAD landing cache. fm-teardown.sh's
# header owns the record format and supported creation/recovery commands.
teardown_bundle_refuse() {  # <predicate> [hint]
  echo "teardown: bundle preservation unavailable: $1." >&2
  [ -z "${2:-}" ] || echo "Create a self-contained external bundle with git -C <copy> bundle create <external-bundle> --all, then record its path, SHA-256 and advertised tips in $DATA/$ID/preservation-bundles.tsv using bin/fm-teardown.sh's header recipe; retry ordinary teardown." >&2
  return 1
}

# Only the stored copy must survive this cleanup. A home can itself be a
# registered worktree or live below a pool; neither makes its data disposable.
# Resolve parents physically so aliases into actual removal roots still refuse.
teardown_bundle_external() {  # <copy> <stored-bundle>
  local copy=$1 bundle=$2 parent path
  case "$bundle" in /*) ;; *) TEARDOWN_BUNDLE_REASON='bundle path is not absolute'; return 1 ;; esac
  if [ ! -f "$bundle" ] || [ -L "$bundle" ]; then
    TEARDOWN_BUNDLE_REASON='bundle is not a regular nonsymlink file'
    return 1
  fi
  parent=${bundle%/*}
  [ -n "$parent" ] || parent=/
  parent=$(fm_task_copy_canonical_dir "$parent") || {
    TEARDOWN_BUNDLE_REASON='bundle parent cannot be resolved'; return 1;
  }
  path="$parent/${bundle##*/}"
  if ! teardown_path_outside_removal_roots "$copy" "$path"; then
    case "$TEARDOWN_ROOT_LABEL" in
      state) TEARDOWN_BUNDLE_REASON="bundle is inside task state $TEARDOWN_ROOT_HIT" ;;
      copy) TEARDOWN_BUNDLE_REASON="bundle is inside task copy $TEARDOWN_ROOT_HIT" ;;
      *) TEARDOWN_BUNDLE_REASON="bundle is inside task scratch $TEARDOWN_ROOT_HIT" ;;
    esac
    return 1
  fi
}

# Is the resolved <path> outside every root this teardown may remove for <copy>:
# the copy, the task's worktree, slots, nested and foreign copies, scratch and
# task state? Sets TEARDOWN_ROOT_LABEL (copy, scratch or state) and
# TEARDOWN_ROOT_HIT when it is inside one.
TEARDOWN_ROOT_LABEL=
TEARDOWN_ROOT_HIT=
teardown_path_outside_removal_roots() {  # <copy> <resolved-path>
  local copy=$1 path=$2 root field
  local roots=() labels=() label i
  TEARDOWN_ROOT_LABEL=
  TEARDOWN_ROOT_HIT=
  # A missing task copy is proved through its surviving project ref store.
  # That project is not a removal target, even when it is the active home.
  if [ -z "${PROJ:-}" ] || ! [ "$copy" -ef "$PROJ" ]; then
    roots+=("$copy"); labels+=(copy)
  fi
  for root in "${WT:-}" "${TEARDOWN_RETURN_SLOT:-}" "${TEARDOWN_ENCLOSING_SLOT:-}" \
      ${TEARDOWN_NESTED_COPIES[@]+"${TEARDOWN_NESTED_COPIES[@]}"} \
      ${TEARDOWN_FOREIGN_COPIES[@]+"${TEARDOWN_FOREIGN_COPIES[@]}"}; do
    [ -z "$root" ] || { roots+=("$root"); labels+=(copy); }
  done
  [ -z "${TASK_TMP:-}" ] || { roots+=("$TASK_TMP"); labels+=(scratch); }
  [ -z "${LAUNCH_HOME_TOKEN:-}" ] || { roots+=("/tmp/fm-$ID+$LAUNCH_HOME_TOKEN"); labels+=(scratch); }
  roots+=("$STATE/$ID.inbox" "$STATE/$ID.git-hooks" "$STATE/.nm-read-cache-$ID" "$STATE/$ID.dsh")
  labels+=(state state state state)
  for i in "${!roots[@]}"; do
    root=${roots[$i]%/}
    label=${labels[$i]}
    [ -e "$root" ] || continue
    field=$(fm_task_copy_canonical_dir "$root") || field=$root
    case "$path" in "$root"|"$root"/*|"$field"|"$field"/*)
      TEARDOWN_ROOT_LABEL=$label
      TEARDOWN_ROOT_HIT=$root
      return 1 ;;
    esac
  done
}

# A bundle must restore on its own: fetch every recorded tip into a fresh empty
# repository that holds none of the copy's objects, then require it to pass
# git fsck --strict.
# A success is remembered for this process by bundle digest, object format and
# recorded tips, so the repeated proofs of one teardown restore it once.
TEARDOWN_BUNDLE_RESTORED=
teardown_bundle_restorable() {  # <copy> <bundle> <bundle-sha256> <tips>
  local copy=$1 bundle=$2 digest=$3 tips=$4 scratch format key tip i=0 rc=0
  local -a specs=()
  format=$(git -C "$copy" rev-parse --show-object-format 2>/dev/null) || format=sha1
  key="$digest $format $tips"
  case $'\n'"$TEARDOWN_BUNDLE_RESTORED" in *$'\n'"$key"$'\n'*) return 0 ;; esac
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-teardown-bundle-restore.XXXXXX") || return 1
  for tip in $tips; do
    i=$((i + 1))
    specs+=("$tip:refs/restore/$i")
  done
  git init --quiet --bare --object-format="$format" "$scratch" >/dev/null 2>&1 \
    && git -C "$scratch" fetch --quiet "$bundle" "${specs[@]}" >/dev/null 2>&1 \
    && git -C "$scratch" fsck --strict --no-dangling >/dev/null 2>&1 \
    || rc=1
  rm -rf "$scratch"
  [ "$rc" != 0 ] || TEARDOWN_BUNDLE_RESTORED+="$key"$'\n'
  return "$rc"
}

# HEADs whose checked-out branches teardown deletes, in this ref store only.
# Each nested/foreign copy also receives its own proof. Treehouse return resets
# HEAD, not other branches. The only extra branch deletion is the task's narrowly
# named archive reaper, whose independent merged-lineage proof remains required.
teardown_bundle_removed_refs() {  # <copy>
  local copy=$1 common other root
  local hex8='[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]'
  common=$(git -C "$copy" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  for root in "${WT:-}" "${TEARDOWN_RETURN_SLOT:-}" "${TEARDOWN_ENCLOSING_SLOT:-}"; do
    [ -d "$root" ] || continue
    other=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
    [ "$common" = "$other" ] || continue
    git -C "$root" rev-parse --verify HEAD || return 1
  done
  [ -d "${PROJ:-}" ] || return 0
  other=$(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ "$common" = "$other" ] || return 0
  git -C "$copy" for-each-ref --format='%(refname)' \
    "refs/heads/archive/$ID-submitted-$hex8" "refs/heads/archive/$ID-pipeline-$hex8"
}

# The maximal locally-only tips reachable from the refs on stdin, one per line.
# --children leaves maximal tips as one-field lines.
teardown_bundle_tips() {  # <copy>
  local walk
  walk=$(git -C "$1" rev-list --stdin --children --not --remotes 2>/dev/null) || return 1
  printf '%s\n' "$walk" | awk 'NF == 1 {print $1}'
}

# Automatic cleanup still requires landing, including replays of an attended
# teardown's interrupted return. Never let the mere record authorize it.
teardown_bundle_attended() {
  [ "${FM_IDLE_REAP_ADMISSION:-0}" != 1 ] \
    && [ "${FM_SUPERVISION_ACTOR:-main}" = main ] \
    && [ ! -e "$STATE/.afk" ] && [ ! -L "$STATE/.afk" ] \
    && [ ! -e "$STATE/.afk-contract" ] && [ ! -L "$STATE/.afk-contract" ]
}

# Reads $DATA/$ID/preservation-bundles.tsv into TEARDOWN_BUNDLE_RECORD_PATH,
# TEARDOWN_BUNDLE_RECORD_HASH and TEARDOWN_BUNDLE_RECORD_TIPS (space-separated
# full tips). On failure TEARDOWN_BUNDLE_REASON names the defect.
teardown_bundle_record() {
  local record="$DATA/$ID/preservation-bundles.tsv" line='' extra='' extra_seen='' rest bundle hash tips tip
  local -a recorded=()
  TEARDOWN_BUNDLE_RECORD_PATH=
  TEARDOWN_BUNDLE_RECORD_HASH=
  TEARDOWN_BUNDLE_RECORD_TIPS=
  if [ ! -f "$record" ] || [ -L "$record" ]; then
    TEARDOWN_BUNDLE_REASON="missing preservation record (regular nonsymlink file required): $record"
    return 1
  fi
  {
    IFS= read -r line || true
    if IFS= read -r extra || [ -n "$extra" ]; then extra_seen=1; fi
  } < "$record"
  if [ -n "$extra_seen" ]; then
    TEARDOWN_BUNDLE_REASON="malformed preservation record in $record (exactly one line required)"
    return 1
  fi
  if [ -z "$line" ]; then
    TEARDOWN_BUNDLE_REASON="empty preservation record: $record"
    return 1
  fi
  bundle=${line%%$'\t'*}
  rest=${line#*$'\t'}
  hash=${rest%%$'\t'*}
  tips=${rest#*$'\t'}
  if [ "$line" = "$rest" ] || [ "$rest" = "$tips" ] \
      || [ -z "$bundle" ] || [ -z "$tips" ] \
      || [[ "$tips" = *$'\t'* || "$line" = *$'\r'* ]] \
      || ! [[ "$hash" =~ ^[0-9a-f]{64}$ ]]; then
    TEARDOWN_BUNDLE_REASON="malformed preservation record in $record (expected absolute path, SHA-256 and full tips in three TAB-separated fields)"
    return 1
  fi
  read -r -a recorded <<< "$tips"
  if [ "${#recorded[@]}" = 0 ]; then
    TEARDOWN_BUNDLE_REASON="malformed preservation record in $record (no commit tips)"
    return 1
  fi
  for tip in "${recorded[@]}"; do
    if ! [[ "$tip" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
      TEARDOWN_BUNDLE_REASON="malformed preservation record in $record (invalid full commit tip: $tip)"
      return 1
    fi
  done
  TEARDOWN_BUNDLE_RECORD_PATH=$bundle
  TEARDOWN_BUNDLE_RECORD_HASH=$hash
  TEARDOWN_BUNDLE_RECORD_TIPS="${recorded[*]}"
}

# Admission owns a durable copy, not the lifetime of the operator's source.
# Stage beside the destination and publish only after the copied bytes survive
# every removal root and Git verification. Later proofs reuse the stored copy at
# its fixed path once its digest matches the record. The record's SHA-256 and
# that fixed path, which the close note also names, recover it after the source
# is deleted.
teardown_bundle_store() {  # <copy> <source> <sha256>
  local copy=$1 source=$2 hash=$3 root="$DATA/$ID/preserved-bundles" stage digest
  TEARDOWN_BUNDLE_STORED="$root/$hash.bundle"
  if [ -f "$TEARDOWN_BUNDLE_STORED" ] && [ ! -L "$TEARDOWN_BUNDLE_STORED" ] \
      && digest=$(teardown_ignored_sha256 "$TEARDOWN_BUNDLE_STORED") && [ "$digest" = "$hash" ]; then
    teardown_bundle_external "$copy" "$TEARDOWN_BUNDLE_STORED"
    return
  fi
  mkdir -p "$root" || { TEARDOWN_BUNDLE_REASON='bundle storage directory cannot be created'; return 1; }
  if [ -L "$TEARDOWN_BUNDLE_STORED" ] \
      || { [ -e "$TEARDOWN_BUNDLE_STORED" ] && [ ! -f "$TEARDOWN_BUNDLE_STORED" ]; }; then
    TEARDOWN_BUNDLE_REASON='stored bundle is not a regular nonsymlink file'; return 1
  fi
  stage=$(mktemp "$root/.bundle.XXXXXX") || {
    TEARDOWN_BUNDLE_REASON='stored bundle staging file cannot be created'; return 1;
  }
  if ! cp "$source" "$stage"; then
    TEARDOWN_BUNDLE_REASON='bundle cannot be copied into task data'
  elif ! teardown_bundle_external "$copy" "$stage"; then
    :
  elif ! digest=$(teardown_ignored_sha256 "$stage") || [ "$digest" != "$hash" ]; then
    TEARDOWN_BUNDLE_REASON='stored bundle sha256 does not match record'
  elif ! git -C "$copy" bundle verify "$stage" >/dev/null 2>&1; then
    TEARDOWN_BUNDLE_REASON='stored git bundle verify failed'
  elif ! mv -f "$stage" "$TEARDOWN_BUNDLE_STORED"; then
    TEARDOWN_BUNDLE_REASON='stored bundle cannot be published'
  fi
  rm -f "$stage"
  [ -z "$TEARDOWN_BUNDLE_REASON" ]
}

# The byte checks every bundle read shares: <file> is a regular nonsymlink file
# whose SHA-256 is <sha256> and that git bundle verify accepts in <copy>'s
# repository. Sets TEARDOWN_BUNDLE_REASON on failure.
teardown_bundle_file_ok() {  # <copy> <file> <sha256>
  local digest
  if [ ! -f "$2" ] || [ -L "$2" ]; then
    TEARDOWN_BUNDLE_REASON='bundle is not a regular nonsymlink file'
  elif ! digest=$(teardown_ignored_sha256 "$2"); then
    TEARDOWN_BUNDLE_REASON='bundle sha256 cannot be read'
  elif [ "$digest" != "$3" ]; then
    TEARDOWN_BUNDLE_REASON='bundle sha256 does not match record'
  elif ! git -C "$1" bundle verify "$2" >/dev/null 2>&1; then
    TEARDOWN_BUNDLE_REASON='git bundle verify failed'
  else
    return 0
  fi
  return 1
}

# The coverage rule every bundle read shares: each <required> tip (one per line)
# is advertised by the bundle and listed in the record's <tips>, and each
# recorded tip is advertised. Sets TEARDOWN_BUNDLE_REASON on failure.
teardown_bundle_tips_cover() {  # <required> <tips> <advertised>
  local tip
  while IFS= read -r tip; do
    [ -n "$tip" ] || continue
    case " $3 " in *" $tip "*) ;; *)
      TEARDOWN_BUNDLE_REASON="bundle does not list unlanded tip $tip"; return 1 ;;
    esac
    case " $2 " in *" $tip "*) ;; *)
      TEARDOWN_BUNDLE_REASON="record does not list unlanded tip $tip"; return 1 ;;
    esac
  done <<< "$1"
  for tip in $2; do
    case " $3 " in *" $tip "*) ;; *)
      TEARDOWN_BUNDLE_REASON="recorded tip $tip is not advertised by bundle"; return 1 ;;
    esac
  done
}

# The proofs that admitted each copy's removal in this run, recorded in the
# parent shell when they were taken (canonical copy path, kind, the HEAD the
# proof held, and for a bundle the stored bundle and the SHA-256 of the
# preservation record file it read), as parallel arrays (bash 3.2). Kinds:
# anchor (an own copy's preservation anchor), landed (the landed-work rule) and
# bundle (a verified recorded bundle). The final removal proof rechecks the
# latest admission of every kind recorded for the copy, never a different proof
# in its place.
TEARDOWN_ADMIT_DIRS=()
TEARDOWN_ADMIT_KINDS=()
TEARDOWN_ADMIT_HEADS=()
TEARDOWN_ADMIT_STORED=()
TEARDOWN_ADMIT_RECORD=()
# A landing admission records, in place of a stored bundle, the default-branch
# ref and commit (teardown_default_ref_snapshot) its proof read: <snapshot> when
# the caller took it right after the proof, else read now; an empty one means
# that ref could not be read, and the final proof then refuses.
teardown_admit() {  # <copy> <anchor|landed|bundle> <head> [<stored-bundle>|<snapshot>]
  local copy record='' stored=${4:-}
  copy=$(fm_task_copy_canonical_dir "$1") || copy=$1
  if [ "$2" = bundle ]; then
    record=$(teardown_ignored_sha256 "$DATA/$ID/preservation-bundles.tsv") || record=''
  fi
  if [ "$2" = landed ] && [ "$#" -lt 4 ]; then
    stored=$(teardown_default_ref_snapshot "$1") || stored=''
  fi
  TEARDOWN_ADMIT_DIRS+=("$copy")
  TEARDOWN_ADMIT_KINDS+=("$2")
  TEARDOWN_ADMIT_HEADS+=("$3")
  TEARDOWN_ADMIT_STORED+=("$stored")
  TEARDOWN_ADMIT_RECORD+=("$record")
}

# "<ref> <commit>" of <ref> when given (the ref the landing proof read), else of
# the default branch <copy> reads landed history from: the origin copy when
# <copy> has an origin remote, else the local branch, as
# fm_task_copy_content_in_default and bin/fm-teardown.sh's landed_default_ref
# resolve it, without fetching. Fails when that ref cannot be read.
teardown_default_ref_snapshot() {  # <copy> [<ref>]
  local copy=$1 ref=${2:-} name commit
  if [ -z "$ref" ]; then
    name=${BASE_BRANCH:-}
    [ -n "$name" ] || name=$(fm_task_copy_default_branch "$PROJ") || return 1
    if git -C "$copy" remote get-url origin >/dev/null 2>&1; then
      ref="refs/remotes/origin/$name"
    else
      ref="refs/heads/$name"
    fi
  fi
  commit=$(git -C "$copy" rev-parse --quiet --verify "$ref^{commit}" 2>/dev/null) || return 1
  [ -n "$commit" ] || return 1
  printf '%s %s\n' "$ref" "$commit"
}

# The SHA-256 of the record file the proof read for the bundle that admitted
# this whole cleanup (TEARDOWN_BUNDLE_SWEEP_PROOF, work_is_landed_bundle): every
# copy the cleanup removes rechecks that bundle, whatever else admitted it.
TEARDOWN_SWEEP_RECORD=

# Are the record file, the stored bundle <stored> and any recorded source still
# the ones a proof read (record file SHA-256 <record-sha256>, byte checks)? No
# forge or fetch work. Fails with TEARDOWN_BUNDLE_REASON.
teardown_bundle_bytes_current() {  # <copy> <stored> <record-sha256>
  local copy=$1 stored=$2 record=$3 now source
  now=$(teardown_ignored_sha256 "$DATA/$ID/preservation-bundles.tsv") || now=''
  if [ -z "$record" ] || [ -z "$stored" ] || [ "$now" != "$record" ]; then
    TEARDOWN_BUNDLE_REASON='the preservation record changed after its proof'
    return 1
  fi
  teardown_bundle_record || return 1
  if [ "$DATA/$ID/preserved-bundles/$TEARDOWN_BUNDLE_RECORD_HASH.bundle" != "$stored" ]; then
    TEARDOWN_BUNDLE_REASON='the preservation record names another bundle'
    return 1
  fi
  teardown_bundle_file_ok "$copy" "$stored" "$TEARDOWN_BUNDLE_RECORD_HASH" \
    || { TEARDOWN_BUNDLE_REASON="stored $TEARDOWN_BUNDLE_REASON"; return 1; }
  # Where the stored bundle physically is now, not where it was at the proof: a
  # directory moved into a removal root takes the bundle with it.
  teardown_bundle_external "$copy" "$stored" \
    || { TEARDOWN_BUNDLE_REASON="stored $TEARDOWN_BUNDLE_REASON"; return 1; }
  source=$TEARDOWN_BUNDLE_RECORD_PATH
  if [ -e "$source" ] || [ -L "$source" ]; then
    teardown_bundle_file_ok "$copy" "$source" "$TEARDOWN_BUNDLE_RECORD_HASH" \
      || { TEARDOWN_BUNDLE_REASON="recorded source $TEARDOWN_BUNDLE_REASON"; return 1; }
  fi
}

# Does the bundle admission (<stored>, <record-sha256>) still hold <head> of
# <copy>? Its bytes are current (teardown_bundle_bytes_current) and the record
# and the stored copy cover every unlanded tip of <head> and of the copy's
# removed branches. Fails with TEARDOWN_BUNDLE_REASON.
teardown_bundle_final_current() {  # <copy> <head> <stored> <record-sha256>
  local copy=$1 head=$2 heads required side
  TEARDOWN_BUNDLE_REASON=
  teardown_bundle_bytes_current "$copy" "$3" "$4" || return 1
  heads=$(git -C "$copy" bundle list-heads "$3" 2>/dev/null | awk '{print $1}' | tr '\n' ' ') \
    || { TEARDOWN_BUNDLE_REASON='stored bundle advertised tips cannot be read'; return 1; }
  side=$(teardown_bundle_removed_refs "$copy") \
    || { TEARDOWN_BUNDLE_REASON="copy's branches cannot be inspected: $copy"; return 1; }
  required=$({ printf '%s\n' "$head"; [ -z "$side" ] || printf '%s\n' "$side"; } | teardown_bundle_tips "$copy") \
    || { TEARDOWN_BUNDLE_REASON="copy's unlanded commits cannot be inspected: $copy"; return 1; }
  teardown_bundle_tips_cover "$required" "$TEARDOWN_BUNDLE_RECORD_TIPS" "$heads"
}

# The stored field of the latest admission of <kind> recorded for <copy>: the
# snapshot of a landing proof ("<ref> <commit>" or "pr <url>"), or a bundle's
# stored path. Empty when there is none.
teardown_latest_admission() {  # <copy> <anchor|landed|bundle>
  local canonical i value=''
  canonical=$(fm_task_copy_canonical_dir "$1") || canonical=$1
  for i in ${TEARDOWN_ADMIT_DIRS[@]+"${!TEARDOWN_ADMIT_DIRS[@]}"}; do
    [ "${TEARDOWN_ADMIT_DIRS[$i]}" = "$canonical" ] && [ "${TEARDOWN_ADMIT_KINDS[$i]}" = "$2" ] || continue
    value=${TEARDOWN_ADMIT_STORED[$i]:-$2}
  done
  printf '%s' "$value"
}

# Every bundle admission recorded for <copy> still holds <head>
# (teardown_bundle_final_current). Fails with TEARDOWN_BUNDLE_REASON.
teardown_admitted_bundles_current() {  # <copy> <head>
  local canonical i last=''
  canonical=$(fm_task_copy_canonical_dir "$1") || canonical=$1
  for i in ${TEARDOWN_ADMIT_DIRS[@]+"${!TEARDOWN_ADMIT_DIRS[@]}"}; do
    [ "${TEARDOWN_ADMIT_DIRS[$i]}" = "$canonical" ] && [ "${TEARDOWN_ADMIT_KINDS[$i]}" = bundle ] && last=$i
  done
  [ -n "$last" ] || return 0
  teardown_bundle_final_current "$1" "$2" "${TEARDOWN_ADMIT_STORED[$last]}" "${TEARDOWN_ADMIT_RECORD[$last]}"
}

# The removal dirt rule matches what a plain git worktree remove refuses: every
# status line counts, Firstmate's managed hook files and turn-end markers too
# (bin/fm-spawn.sh excludes them, so they show only where that exclusion is
# missing, and Git would then refuse the copy), except the exact untracked entry
# of each of the task's own <nested-copy> paths inside <copy>, which are proved
# and removed on their own first. Unlike fm_task_copy_dirty_status it never
# exempts any part of the .claude tree.
teardown_removal_dirty_status() {  # <porcelain-status> <copy> [<nested-copy>...]
  local status=$1 copy=$2 line nested
  shift 2
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '') continue ;;
    esac
    for nested in "$@"; do
      case "$nested" in
        "$copy"/*) [ "$line" != "?? ${nested#"$copy"/}/" ] || continue 2 ;;
      esac
    done
    printf '%s\n' "$line"
  done <<< "$status"
}

# The preserve of <copy> holds its ignored files: for each regular file under
# each preservable ignored entry (teardown_preservable_ignored_z, in <mode>), the
# copy's file, the preserved payload file and its one SHA256SUMS line agree by
# SHA-256; the manifest holds exactly as many lines as those files; the preserve
# is a real directory outside every removal root and each payload file's real
# directory lies inside it. Every listing and scan is checked, so one that fails
# refuses. Reads the preserved payload itself, never only the manifest.
teardown_ignored_preserved_current() {  # <copy> [all|releasable]
  local copy=$1 mode=${2:-} list files rc=0
  list=$(mktemp "${TMPDIR:-/tmp}/fm-teardown-ignored.XXXXXX") || { TEARDOWN_PRESERVE_WHY='a scratch file cannot be made'; return 1; }
  files=$(mktemp "${TMPDIR:-/tmp}/fm-teardown-ignored.XXXXXX") || { rm -f "$list"; TEARDOWN_PRESERVE_WHY='a scratch file cannot be made'; return 1; }
  teardown_preserved_payload_check "$copy" "$mode" "$list" "$files" || rc=1
  rm -f "$list" "$files"
  return "$rc"
}
teardown_preserved_payload_check() {  # <copy> <mode> <list-file> <files-file>
  local copy=$1 mode=$2 list=$3 files=$4 dest real entry file rel sum kept dir count=0 lines
  teardown_preservable_ignored_z "$copy" "$mode" >"$list" || { TEARDOWN_PRESERVE_WHY='the ignored files cannot be listed'; return 1; }
  [ -s "$list" ] || return 0
  dest=$(printf '%s' "$copy" | teardown_ignored_sha256) || { TEARDOWN_PRESERVE_WHY='the preserve path cannot be named'; return 1; }
  dest="$DATA/$ID/nested-copy-preserved/$dest"
  teardown_preserve_dest_outside "$copy" "$dest" || return 1
  [ -d "$dest" ] && [ ! -L "$dest" ] || { TEARDOWN_PRESERVE_WHY='the preserve is not a real directory'; return 1; }
  real=$(fm_task_copy_canonical_dir "$dest") || { TEARDOWN_PRESERVE_WHY='the preserve cannot be resolved'; return 1; }
  teardown_path_outside_removal_roots "$copy" "$real" \
    || { TEARDOWN_PRESERVE_WHY="the preserve resolves inside $TEARDOWN_ROOT_LABEL $TEARDOWN_ROOT_HIT"; return 1; }
  [ -f "$dest/SHA256SUMS" ] && [ ! -L "$dest/SHA256SUMS" ] || { TEARDOWN_PRESERVE_WHY='the preserve has no manifest'; return 1; }
  while IFS= read -r -d '' entry; do
    [ -n "$entry" ] || continue
    find "$copy/$entry" -type f -print0 >"$files" 2>/dev/null \
      || { TEARDOWN_PRESERVE_WHY="the files of $(teardown_nul_list_text <(printf '%s\0' "$entry")) cannot be listed"; return 1; }
    while IFS= read -r -d '' file; do
      rel=${file#"$copy/"}
      sum=$(teardown_ignored_sha256 "$file") || { TEARDOWN_PRESERVE_WHY="${rel//$'\n'/\\n} cannot be hashed"; return 1; }
      grep -qxF -- "$(teardown_manifest_line "$sum" "$rel")" "$dest/SHA256SUMS" \
        || { TEARDOWN_PRESERVE_WHY="the manifest does not hold ${rel//$'\n'/\\n} as it is in the copy"; return 1; }
      kept="$dest/$rel"
      [ -f "$kept" ] && [ ! -L "$kept" ] || { TEARDOWN_PRESERVE_WHY="the preserved payload of ${rel//$'\n'/\\n} is missing"; return 1; }
      dir=$(fm_task_copy_canonical_dir "${kept%/*}") \
        || { TEARDOWN_PRESERVE_WHY="the preserved payload of ${rel//$'\n'/\\n} cannot be resolved"; return 1; }
      case "$dir/" in "$real"/*) ;; *) TEARDOWN_PRESERVE_WHY="the preserved payload of ${rel//$'\n'/\\n} resolves outside the preserve"; return 1 ;; esac
      [ "$(teardown_ignored_sha256 "$kept")" = "$sum" ] \
        || { TEARDOWN_PRESERVE_WHY="the preserved payload of ${rel//$'\n'/\\n} does not match the copy"; return 1; }
      count=$((count + 1))
    done <"$files"
  done <"$list"
  lines=$(wc -l < "$dest/SHA256SUMS") || { TEARDOWN_PRESERVE_WHY='the manifest cannot be read'; return 1; }
  lines=${lines//[!0-9]/}
  [ "${lines:-x}" = "$count" ] || { TEARDOWN_PRESERVE_WHY="the manifest holds ${lines:-no} lines for the $count files the copy holds"; return 1; }
}

# Does the preserve directory <dest> resolve outside every removal root of
# <copy> (teardown_path_outside_removal_roots)? Sets TEARDOWN_PRESERVE_WHY.
teardown_preserve_dest_outside() {  # <copy> <dest>
  local parent
  parent=$(fm_task_copy_canonical_dir "${2%/*}") || { TEARDOWN_PRESERVE_WHY='the preserve directory cannot be resolved'; return 1; }
  if ! teardown_path_outside_removal_roots "$1" "$parent/${2##*/}"; then
    TEARDOWN_PRESERVE_WHY="the preserve directory resolves inside $TEARDOWN_ROOT_LABEL $TEARDOWN_ROOT_HIT"
    return 1
  fi
}

# The one final proof every removal route takes immediately before its remove
# call (Main 010, 011, 1681). It refuses on any input it cannot prove; there is
# no fast path and no proof stands in for another:
#   - HEAD and status: the HEAD resolves and the status is clean under the
#     removal dirt rule (teardown_removal_dirty_status);
#   - admission: at least one proof admitted this copy in this run, and the
#     latest admission of each kind recorded for it still holds the same HEAD (an anchor still points
#     at it; a landing proof held that HEAD; a bundle's record file, stored and
#     source bytes are unchanged and still cover HEAD's unlanded tips);
#   - the bundle that admitted the whole cleanup, when one did, is unchanged;
#   - ignored files: none outside the preserve allow-list (refuse), or all of
#     them preserved again outside every removal root and the preserved payload
#     matched by SHA-256 to the manifest and to the copy (preserve);
#   - locked: the launcher <pid> is gone by pid and start time against the lock
#     time read before the unlock; an empty or non-numeric pid or time refuses.
# Returns 1 with TEARDOWN_FINAL_WHY and TEARDOWN_FINAL_STABLE (1 when the fact
# stays until someone acts, such as dirt or unpreserved ignored files, so a
# re-run cannot help; empty when a re-run for a fresh proof can).
TEARDOWN_FINAL_WHY=
TEARDOWN_FINAL_STABLE=
teardown_removal_final_proof() {  # <copy> <preserve|refuse> <locked|unlocked> [<launcher-pid> <lock-mtime>]
  local copy=$1 ignored=$2 locked=$3 pid=${4:-} mtime=${5:-} head status unique canonical i latest found=0 rc=0 snap ref now
  TEARDOWN_FINAL_WHY=
  TEARDOWN_FINAL_STABLE=
  head=$(git -C "$copy" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) \
    || { TEARDOWN_FINAL_WHY='its HEAD cannot be resolved at the removal'; return 1; }
  status=$(git -C "$copy" status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null) \
    || { TEARDOWN_FINAL_WHY='its status cannot be read at the removal'; return 1; }
  status=$(teardown_removal_dirty_status "$status" "$copy" ${TEARDOWN_NESTED_COPIES[@]+"${TEARDOWN_NESTED_COPIES[@]}"})
  if [ -n "$status" ]; then
    TEARDOWN_FINAL_STABLE=1
    TEARDOWN_FINAL_WHY="it holds uncommitted or untracked content nothing holds: $(printf '%s' "$status" | head -n 3 | paste -sd ' ' -)"
    return 1
  fi
  canonical=$(fm_task_copy_canonical_dir "$copy") || canonical=$copy
  # The latest admission of each kind is the one in force: a later proof of the
  # same kind (a re-proof after a change) supersedes an earlier one.
  latest=' '
  for i in ${TEARDOWN_ADMIT_DIRS[@]+"${!TEARDOWN_ADMIT_DIRS[@]}"}; do
    [ "${TEARDOWN_ADMIT_DIRS[$i]}" = "$canonical" ] || continue
    latest=$(printf '%s' "$latest" | sed "s/ ${TEARDOWN_ADMIT_KINDS[$i]}:[0-9]* / /")"${TEARDOWN_ADMIT_KINDS[$i]}:$i "
  done
  for i in ${TEARDOWN_ADMIT_DIRS[@]+"${!TEARDOWN_ADMIT_DIRS[@]}"}; do
    case "$latest" in *" ${TEARDOWN_ADMIT_KINDS[$i]}:$i "*) ;; *) continue ;; esac
    found=1
    if [ "${TEARDOWN_ADMIT_HEADS[$i]}" != "$head" ]; then
      TEARDOWN_FINAL_WHY="its HEAD ${head:0:12} is not the ${TEARDOWN_ADMIT_HEADS[$i]:0:12} its ${TEARDOWN_ADMIT_KINDS[$i]} proof admitted"
      return 1
    fi
    case "${TEARDOWN_ADMIT_KINDS[$i]}" in
      anchor)
        if ! fm_task_copy_preserve "$PROJ" "$ID" "$copy" 0 ${TEARDOWN_NESTED_COPIES[@]+"${TEARDOWN_NESTED_COPIES[@]}"} \
            || [ "$FM_TASK_COPY_HEAD" != "$head" ]; then
          TEARDOWN_FINAL_WHY="the preservation anchor that admitted it no longer holds HEAD ${head:0:12}"
          return 1
        fi
        ;;
      landed)
        # A merged pull request rests on the forge's answer, not on a local ref.
        # Any other landing rests on the default-branch commit its proof read,
        # which must still be where that ref points.
        snap=${TEARDOWN_ADMIT_STORED[$i]}
        case "$snap" in 'pr '?*) continue ;; esac
        ref=${snap%% *}
        now=''
        [ -z "$snap" ] || now=$(git -C "$copy" rev-parse --quiet --verify "$ref^{commit}" 2>/dev/null) || now=''
        if [ -z "$snap" ] || [ -z "$now" ]; then
          TEARDOWN_FINAL_WHY="the default branch its landing proof read${ref:+ ($ref)} cannot be read at the removal; re-run teardown for a fresh landing proof"
          return 1
        fi
        if [ "$now" != "${snap##* }" ]; then
          TEARDOWN_FINAL_WHY="the default branch its landing proof read moved ($ref ${snap##* }; now $now); re-run teardown for a fresh landing proof"
          return 1
        fi
        ;;
      bundle)
        if ! teardown_bundle_final_current "$copy" "$head" "${TEARDOWN_ADMIT_STORED[$i]}" "${TEARDOWN_ADMIT_RECORD[$i]}"; then
          TEARDOWN_FINAL_WHY="the recorded bundle that admitted it no longer holds HEAD ${head:0:12} ($TEARDOWN_BUNDLE_REASON)"
          return 1
        fi
        ;;
      *) TEARDOWN_FINAL_WHY='it was admitted by an unknown proof'; return 1 ;;
    esac
  done
  [ "$found" = 1 ] || { TEARDOWN_FINAL_WHY="no proof in this run admitted its removal at HEAD ${head:0:12}"; return 1; }
  if [ -n "${TEARDOWN_BUNDLE_SWEEP_PROOF:-}" ] \
      && ! teardown_bundle_bytes_current "$copy" "$TEARDOWN_BUNDLE_SWEEP_PROOF" "$TEARDOWN_SWEEP_RECORD"; then
    TEARDOWN_FINAL_WHY="the recorded bundle that admitted this cleanup changed ($TEARDOWN_BUNDLE_REASON)"
    return 1
  fi
  case "$ignored" in
    refuse)
      unique=$(mktemp "${TMPDIR:-/tmp}/fm-teardown-ignored.XXXXXX") || { TEARDOWN_FINAL_WHY='a scratch file cannot be made at the removal'; return 1; }
      if ! teardown_preservable_ignored_z "$copy" >"$unique"; then
        rm -f "$unique"
        TEARDOWN_FINAL_WHY='its ignored files cannot be listed at the removal'
        return 1
      fi
      if [ -s "$unique" ]; then
        TEARDOWN_FINAL_STABLE=1
        TEARDOWN_FINAL_WHY="it holds ignored files no hash record preserves: $(teardown_nul_list_text "$unique")"
        rm -f "$unique"
        return 1
      fi
      rm -f "$unique"
      ;;
    preserve)
      if ! teardown_preserve_ignored "$copy" || ! teardown_ignored_preserved_current "$copy"; then
        TEARDOWN_FINAL_WHY="its ignored files could not be preserved and verified outside every removal root (${TEARDOWN_PRESERVE_WHY:-preservation failed})"
        return 1
      fi
      ;;
    *) TEARDOWN_FINAL_WHY="unknown ignored-file mode $ignored"; return 1 ;;
  esac
  case "$locked" in
    unlocked) ;;
    locked)
      case "$pid" in ''|*[!0-9]*) TEARDOWN_FINAL_WHY='its lock launcher could not be read for the final launcher check'; return 1 ;; esac
      case "$mtime" in ''|*[!0-9]*) TEARDOWN_FINAL_WHY='its lock time could not be read for the final launcher check'; return 1 ;; esac
      teardown_launcher_live_since "$pid" "$mtime" || rc=$?
      case "$rc" in
        1) ;;
        0) TEARDOWN_FINAL_WHY="its creation-lock launcher process $pid may still be running"; return 1 ;;
        *) TEARDOWN_FINAL_WHY="the process table cannot be read, so launcher $pid is not proved gone"; return 1 ;;
      esac
      ;;
    *) TEARDOWN_FINAL_WHY="unknown lock mode $locked"; return 1 ;;
  esac
}

# <ref> itself must carry a locally-only commit, or delivery proof is still
# required. Coverage includes only this cleanup's HEADs and deleted branch refs,
# never unrelated unheld branches in the shared repository.
teardown_bundle_preserved() {  # <copy> <ref> [hint]
  local copy=$1 ref=$2 hint=${3:-} record="$DATA/$ID/preservation-bundles.tsv"
  local bundle source hash tips tip own required side heads advertised stored
  TEARDOWN_BUNDLE_ACCEPTED=
  if ! teardown_bundle_attended; then
    if [ -f "$record" ] && [ ! -L "$record" ] \
        && own=$(printf '%s\n' "$ref" | teardown_bundle_tips "$copy") && [ -n "$own" ]; then
      teardown_bundle_refuse 'recorded bundles require attended teardown; unattended cleanup still requires landing'
      echo 'Retry ordinary teardown from the attended main session after ending away or quiet mode; the bundle must pass all preservation proofs there.' >&2
    fi
    return 1
  fi
  own=$(printf '%s\n' "$ref" | teardown_bundle_tips "$copy") || {
    teardown_bundle_refuse "copy's unlanded commits cannot be inspected: $copy"; return 1;
  }
  # Main 1843: an Orca-backed task keeps base behaviour; the bundle route without
  # a captain hold that this change adds is not admitted for it.
  if [ "${BACKEND:-}" = orca ] && [ -n "$own" ]; then
    teardown_bundle_refuse "the bundle route without a captain hold is not admitted for an Orca-backed task (Main 1843); land the commits or hold the task for the captain"
    return 1
  fi
  if [ -z "$own" ]; then
    teardown_bundle_refuse "copy has no unlanded tips of its own; existing delivery proof is still required"
    return 1
  fi
  side=$(teardown_bundle_removed_refs "$copy") || {
    teardown_bundle_refuse "copy's branches cannot be inspected: $copy"; return 1;
  }
  required=$({ printf '%s\n' "$ref"; [ -z "$side" ] || printf '%s\n' "$side"; } | teardown_bundle_tips "$copy") || {
    teardown_bundle_refuse "copy's unlanded commits cannot be inspected: $copy"; return 1;
  }
  if ! teardown_bundle_record; then
    teardown_bundle_refuse "$TEARDOWN_BUNDLE_REASON" "$hint"
    return 1
  fi
  bundle=$TEARDOWN_BUNDLE_RECORD_PATH
  hash=$TEARDOWN_BUNDLE_RECORD_HASH
  tips=$TEARDOWN_BUNDLE_RECORD_TIPS
  TEARDOWN_BUNDLE_REASON=
  source=$bundle
  stored="$DATA/$ID/preserved-bundles/$hash.bundle"
  # A completed admission survives deletion of its original source. Never mask
  # changed bytes or a symlink at a source that still exists.
  if [ ! -e "$bundle" ] && [ ! -L "$bundle" ] && [ -f "$stored" ]; then
    bundle=$stored
  fi
  if [[ "$bundle" != /* ]]; then
    TEARDOWN_BUNDLE_REASON='bundle path is not absolute'
  elif ! teardown_bundle_file_ok "$copy" "$bundle" "$hash"; then
    :
  elif ! heads=$(git -C "$copy" bundle list-heads "$bundle" 2>/dev/null); then
    TEARDOWN_BUNDLE_REASON='bundle advertised tips cannot be read'
  else
    advertised=$(printf '%s\n' "$heads" | awk '{print $1}' | tr '\n' ' ')
    teardown_bundle_tips_cover "$required" "$tips" "$advertised" || :
    if [ -z "$TEARDOWN_BUNDLE_REASON" ] && ! teardown_bundle_restorable "$copy" "$bundle" "$hash" "$tips"; then
      TEARDOWN_BUNDLE_REASON='bundle cannot be restored in an isolated repository'
    fi
  fi
  if [ -z "$TEARDOWN_BUNDLE_REASON" ]; then
    if teardown_bundle_store "$copy" "$bundle" "$hash"; then
      echo "teardown: preserved unlanded commits in bundle $TEARDOWN_BUNDLE_STORED sha256=$hash tips=$tips (source $source)" >&2
      TEARDOWN_BUNDLE_ACCEPTED=$TEARDOWN_BUNDLE_STORED
      return 0
    fi
  fi
  teardown_bundle_refuse "$bundle: $TEARDOWN_BUNDLE_REASON" "$hint"
}

# Copies every entry teardown_preservable_ignored_z prints for <copy> in the given
# mode into $DATA/$ID/nested-copy-preserved/<copy-path-sha256> and records each
# file's SHA-256 in its SHA256SUMS (teardown_manifest_line). The new preserve is
# built in a staging directory, every listing and scan checked; it is published
# by renaming the earlier preserve aside and the new one into place, and the
# earlier one is deleted only after the published one verifies against its own
# manifest (teardown_preserve_self_check). A failed publication or verification
# puts the earlier preserve back (a failed new preserve is deleted: the copy
# still holds its bytes), and an earlier preserve an interrupted run left set
# aside is put back before anything else, so no failure, interruption or retry
# costs an earlier preserve. Returns 1 with TEARDOWN_PRESERVE_WHY when anything
# cannot be listed, copied, hashed, published or verified, and the caller then
# refuses the copy rather than removing unpreserved content.
TEARDOWN_PRESERVE_WHY=
teardown_preserve_ignored() {  # <copy> [all|releasable]
  local copy=$1 mode=${2:-} root dest stage aside='' failed list hash why
  TEARDOWN_PRESERVE_WHY=
  list=$(mktemp "${TMPDIR:-/tmp}/fm-teardown-ignored.XXXXXX") || { TEARDOWN_PRESERVE_WHY='a scratch file cannot be made'; return 1; }
  if ! teardown_preservable_ignored_z "$copy" "$mode" >"$list"; then
    rm -f "$list"
    TEARDOWN_PRESERVE_WHY='the ignored files cannot be listed'
    return 1
  fi
  if [ ! -s "$list" ]; then
    rm -f "$list"
    return 0
  fi
  hash=$(printf '%s' "$copy" | teardown_ignored_sha256) || { rm -f "$list"; TEARDOWN_PRESERVE_WHY='the preserve path cannot be named'; return 1; }
  root="$DATA/$ID/nested-copy-preserved"
  dest="$root/$hash"
  stage="$root/.staging-$hash"
  mkdir -p "$root" || { rm -f "$list"; TEARDOWN_PRESERVE_WHY='the preserve directory cannot be created'; return 1; }
  teardown_preserve_dest_outside "$copy" "$dest" || { rm -f "$list"; return 1; }
  teardown_preserve_recover_aside "$root" "$hash" || { rm -f "$list"; return 1; }
  rm -rf "$stage" || { rm -f "$list"; TEARDOWN_PRESERVE_WHY='an earlier staging directory cannot be removed'; return 1; }
  if ! teardown_preserve_stage "$copy" "$stage" "$list"; then
    rm -rf "$stage"
    rm -f "$list"
    TEARDOWN_PRESERVE_WHY='the preserve could not be copied, scanned or hashed'
    return 1
  fi
  rm -f "$list"
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    if ! aside=$(teardown_preserve_aside_name "$root" "$hash") || ! mv "$dest" "$aside"; then
      rm -rf "$stage"
      TEARDOWN_PRESERVE_WHY='the earlier preserve cannot be set aside'
      return 1
    fi
  fi
  if ! mv "$stage" "$dest"; then
    [ -z "$aside" ] || mv "$aside" "$dest" || true
    rm -rf "$stage"
    TEARDOWN_PRESERVE_WHY='the new preserve could not be published'
    return 1
  fi
  if ! teardown_preserve_self_check "$copy" "$dest"; then
    why=$TEARDOWN_PRESERVE_WHY
    # The failed preserve holds nothing the copy does not still hold, so it goes,
    # and the earlier preserve, when there is one, goes back into place.
    if [ -n "$aside" ]; then
      if failed=$(teardown_preserve_aside_name "$root" "$hash" failed) && mv "$dest" "$failed"; then
        mv "$aside" "$dest" && rm -rf "$failed"
      fi
    else
      rm -rf "$dest"
    fi
    TEARDOWN_PRESERVE_WHY="the published preserve does not verify ($why)"
    return 1
  fi
  # The new preserve is proved: every earlier one of this copy may go.
  teardown_preserve_drop_asides "$root" "$hash" || true
  echo "teardown: preserved ignored files from $(fm_refuse_text "$copy") in $dest" >&2
}

# Is published preserve <dest> of <copy> whole by its own manifest? It is a real
# directory outside every removal root naming <copy>, its manifest is a regular
# file, every regular payload file lies inside it and has its one manifest line,
# and the manifest holds no line more. A copy that changed meanwhile is the
# caller's comparison (teardown_ignored_preserved_current), not this check's.
teardown_preserve_self_check() {  # <copy> <dest>
  local copy=$1 dest=$2 real files file rel sum dir count=0 lines rc=0
  teardown_preserve_dest_outside "$copy" "$dest" || return 1
  [ -d "$dest" ] && [ ! -L "$dest" ] || { TEARDOWN_PRESERVE_WHY='the preserve is not a real directory'; return 1; }
  real=$(fm_task_copy_canonical_dir "$dest") || { TEARDOWN_PRESERVE_WHY='the preserve cannot be resolved'; return 1; }
  teardown_path_outside_removal_roots "$copy" "$real" \
    || { TEARDOWN_PRESERVE_WHY="the preserve resolves inside $TEARDOWN_ROOT_LABEL $TEARDOWN_ROOT_HIT"; return 1; }
  [ -f "$dest/SHA256SUMS" ] && [ ! -L "$dest/SHA256SUMS" ] || { TEARDOWN_PRESERVE_WHY='the preserve has no manifest'; return 1; }
  [ "$(cat "$dest/copy-path" 2>/dev/null)" = "$copy" ] || { TEARDOWN_PRESERVE_WHY='the preserve does not name this copy'; return 1; }
  files=$(mktemp "${TMPDIR:-/tmp}/fm-teardown-ignored.XXXXXX") || { TEARDOWN_PRESERVE_WHY='a scratch file cannot be made'; return 1; }
  if ! find "$dest" -type f ! -path "$dest/copy-path" ! -path "$dest/SHA256SUMS" -print0 >"$files" 2>/dev/null; then
    rm -f "$files"
    TEARDOWN_PRESERVE_WHY='the preserve cannot be scanned'
    return 1
  fi
  while IFS= read -r -d '' file; do
    rel=${file#"$dest/"}
    dir=$(fm_task_copy_canonical_dir "${file%/*}") || { TEARDOWN_PRESERVE_WHY="the preserved ${rel//$'\n'/\\n} cannot be resolved"; rc=1; break; }
    case "$dir/" in "$real"/*) ;; *) TEARDOWN_PRESERVE_WHY="the preserved ${rel//$'\n'/\\n} resolves outside the preserve"; rc=1; break ;; esac
    sum=$(teardown_ignored_sha256 "$file") || { TEARDOWN_PRESERVE_WHY="the preserved ${rel//$'\n'/\\n} cannot be hashed"; rc=1; break; }
    grep -qxF -- "$(teardown_manifest_line "$sum" "$rel")" "$dest/SHA256SUMS" \
      || { TEARDOWN_PRESERVE_WHY="the preserved ${rel//$'\n'/\\n} does not match its manifest line"; rc=1; break; }
    count=$((count + 1))
  done <"$files"
  rm -f "$files"
  [ "$rc" = 0 ] || return 1
  lines=$(wc -l < "$dest/SHA256SUMS") || { TEARDOWN_PRESERVE_WHY='the manifest cannot be read'; return 1; }
  lines=${lines//[!0-9]/}
  [ "${lines:-x}" = "$count" ] || { TEARDOWN_PRESERVE_WHY="the manifest holds ${lines:-no} lines for the $count preserved files"; return 1; }
}

# Builds staging directory <stage> from the NUL-ended entry list <list> of
# <copy>: its copy-path, every entry copied, and SHA256SUMS over every regular
# file. Fails when any entry, copy, scan or hash fails.
teardown_preserve_stage() {  # <copy> <stage> <list>
  local copy=$1 stage=$2 list=$3 files entry file sum rc=0
  files=$(mktemp "${TMPDIR:-/tmp}/fm-teardown-ignored.XXXXXX") || return 1
  (
    mkdir -p "$stage" || exit 1
    printf '%s\n' "$copy" > "$stage/copy-path" || exit 1
    : > "$stage/SHA256SUMS" || exit 1
    while IFS= read -r -d '' entry; do
      [ -n "$entry" ] || continue
      case "$entry" in /*|..|../*|*/..|*/../*) exit 1 ;; esac
      rm -rf "${stage:?}/$entry" || exit 1
      mkdir -p "$(dirname "$stage/$entry")" || exit 1
      cp -RPp "$copy/$entry" "$stage/$entry" || exit 1
    done <"$list"
    find "$stage" -type f ! -path "$stage/copy-path" ! -path "$stage/SHA256SUMS" -print0 >"$files" 2>/dev/null || exit 1
    while IFS= read -r -d '' file; do
      sum=$(teardown_ignored_sha256 "$file") || exit 1
      teardown_manifest_line "$sum" "${file#"$stage/"}" >> "$stage/SHA256SUMS" || exit 1
    done <"$files"
  ) || rc=1
  rm -f "$files"
  return "$rc"
}

# A fresh name beside the preserves in <root> for an earlier (or a failed)
# preserve of copy hash <hash>, ordered by time so the newest sorts last.
teardown_preserve_aside_name() {  # <root> <hash> [failed]
  local stamp name
  stamp=$(date +%s) || return 1
  name="$1/.${3:-aside}-$2.$stamp.$$"
  while [ -e "$name" ] || [ -L "$name" ]; do
    name="$name.1"
  done
  printf '%s\n' "$name"
}

# The earlier preserves of copy hash <hash> set aside in <root>, newest last:
# the one an earlier run named .aside-<hash> and every timed one.
teardown_preserve_asides() {  # <root> <hash>
  local entry
  for entry in "$1/.aside-$2" "$1/.aside-$2".*; do
    { [ -e "$entry" ] || [ -L "$entry" ]; } && printf '%s\n' "$entry"
  done | LC_ALL=C sort
}

# With no preserve of copy hash <hash> in place in <root>, an interrupted run left
# the earlier one set aside: the newest set-aside one goes back into place.
teardown_preserve_recover_aside() {  # <root> <hash>
  local newest
  [ ! -e "$1/$2" ] && [ ! -L "$1/$2" ] || return 0
  newest=$(teardown_preserve_asides "$1" "$2" | tail -n 1)
  [ -n "$newest" ] || return 0
  mv "$newest" "$1/$2" || { TEARDOWN_PRESERVE_WHY="the earlier preserve set aside at $newest cannot be put back"; return 1; }
}

# Deletes an earlier preserve of copy hash <hash> set aside in <root> only when
# the newer preserve in <root>/<hash>, already verified, holds every regular file
# the earlier one holds, at the same path with the same bytes
# (teardown_preserve_covers). An earlier preserve with any file the newer one
# lacks or holds differently, or one that cannot be read, stays where it is.
teardown_preserve_drop_asides() {  # <root> <hash>
  local entry rc=0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if teardown_preserve_covers "$1/$2" "$entry"; then
      rm -rf "$entry" || rc=1
    else
      echo "teardown: kept earlier preserve $entry: it holds a file the new preserve $1/$2 does not hold with the same bytes" >&2
    fi
  done < <(teardown_preserve_asides "$1" "$2")
  return "$rc"
}

# Does preserve <new> hold every regular file of preserve <old> (its copy-path and
# manifest aside) at the same relative path with the same SHA-256? A symlink or
# other non-regular entry in <old>, or a scan that fails, answers no.
teardown_preserve_covers() {  # <new> <old>
  local new=$1 old=$2 list file rel sum rc=0
  [ -d "$old" ] && [ ! -L "$old" ] || return 1
  list=$(mktemp "${TMPDIR:-/tmp}/fm-teardown-ignored.XXXXXX") || return 1
  if ! find "$old" ! -type d ! -path "$old/copy-path" ! -path "$old/SHA256SUMS" -print0 >"$list" 2>/dev/null; then
    rm -f "$list"
    return 1
  fi
  while IFS= read -r -d '' file; do
    rel=${file#"$old/"}
    if [ -L "$file" ] || [ ! -f "$file" ] || [ -L "$new/$rel" ] || [ ! -f "$new/$rel" ]; then rc=1; break; fi
    sum=$(teardown_ignored_sha256 "$file") || { rc=1; break; }
    [ "$(teardown_ignored_sha256 "$new/$rel")" = "$sum" ] || { rc=1; break; }
  done <"$list"
  rm -f "$list"
  return "$rc"
}

# The lock first read for each copy in this run (canonical path): its reason and
# the SHA-256 of the whole lock file (TEARDOWN_FOREIGN_LOCK_SHA of the read that
# gave <lock-reason>), so a later read can tell any changed lock byte from the
# lock that was proved.
TEARDOWN_LOCK_SEEN_DIRS=()
TEARDOWN_LOCK_SEEN_TEXT=()
teardown_lock_seen() {  # <copy> <lock-reason>
  local copy i
  copy=$(fm_task_copy_canonical_dir "$1") || copy=$1
  for i in ${TEARDOWN_LOCK_SEEN_DIRS[@]+"${!TEARDOWN_LOCK_SEEN_DIRS[@]}"}; do
    [ "${TEARDOWN_LOCK_SEEN_DIRS[$i]}" != "$copy" ] || return 0
  done
  TEARDOWN_LOCK_SEEN_DIRS+=("$copy")
  TEARDOWN_LOCK_SEEN_TEXT+=("$2"$'\n'"${TEARDOWN_FOREIGN_LOCK_SHA:-}")
}
# Was a lock read on <copy> earlier in this run (teardown_lock_seen)? A copy whose
# lock was proved is a locked copy for the rest of the run: a later read that
# finds no lock, or cannot read one, refuses; it never selects the unlocked route.
teardown_lock_was_seen() {  # <copy>
  local copy i
  copy=$(fm_task_copy_canonical_dir "$1") || copy=$1
  for i in ${TEARDOWN_LOCK_SEEN_DIRS[@]+"${!TEARDOWN_LOCK_SEEN_DIRS[@]}"}; do
    [ "${TEARDOWN_LOCK_SEEN_DIRS[$i]}" != "$copy" ] || return 0
  done
  return 1
}
teardown_lock_is_first_seen() {  # <copy> <lock-reason>
  local copy i
  copy=$(fm_task_copy_canonical_dir "$1") || copy=$1
  [ -n "${TEARDOWN_FOREIGN_LOCK_SHA:-}" ] || return 1
  for i in ${TEARDOWN_LOCK_SEEN_DIRS[@]+"${!TEARDOWN_LOCK_SEEN_DIRS[@]}"}; do
    [ "${TEARDOWN_LOCK_SEEN_DIRS[$i]}" = "$copy" ] || continue
    [ "${TEARDOWN_LOCK_SEEN_TEXT[$i]}" = "$2"$'\n'"$TEARDOWN_FOREIGN_LOCK_SHA" ]
    return
  done
  return 1
}

# Does an active record, a process running in it or holding a file in it open,
# or a live lock launcher outside this teardown own <copy>? Returns 1 with
# TEARDOWN_FOREIGN_WHY set when so or when that cannot be told.
teardown_foreign_copy_unowned() {  # <copy>
  local copy=$1 rc=0 pids pid held path
  TEARDOWN_OWN_SCANNED=0
  TEARDOWN_FOREIGN_PID=
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
      TEARDOWN_FOREIGN_PID=$pid
      TEARDOWN_FOREIGN_WHY="process $pid is running in it"
      return 1
    fi
    teardown_foreign_proc_record "$pid"
  done <<< "$pids"
  if ! held=$(pids_with_open_file_under "$copy"); then
    TEARDOWN_FOREIGN_RULE=inspection-unavailable
    TEARDOWN_FOREIGN_WHY="a scan for processes holding its files open failed"
    return 1
  fi
  while IFS=$'\t' read -r pid path; do
    [ -n "$pid" ] || continue
    case $'\n'"$pids" in *$'\n'"$pid"$'\t'*) continue ;; esac
    TEARDOWN_FOREIGN_RULE=process-open-file-owner
    TEARDOWN_FOREIGN_PID=$pid
    TEARDOWN_FOREIGN_WHY="process $pid holds $(fm_refuse_text "$path") open"
    return 1
  done <<< "$held"
  rc=0
  teardown_copy_lock_file "$copy" || rc=$?
  case "$rc" in
    0)
      teardown_lock_seen "$copy" "$TEARDOWN_FOREIGN_LOCK"
      if ! pid=$(teardown_vernant_lock_pid "$TEARDOWN_FOREIGN_LOCK"); then
        TEARDOWN_FOREIGN_RULE=creation-lock-owner
        TEARDOWN_FOREIGN_WHY="it is locked by something other than Vernant's creation lock (${TEARDOWN_FOREIGN_LOCK:-no reason given})"
        return 1
      fi
      rc=0
      teardown_lock_launcher_may_be_live "$pid" "$TEARDOWN_FOREIGN_LOCK_FILE" || rc=$?
      case "$rc" in
        0)
          if ! teardown_pid_is_task_own "$pid"; then
            TEARDOWN_FOREIGN_RULE='lock-launcher-owner'
            TEARDOWN_FOREIGN_PID=$pid
            TEARDOWN_FOREIGN_WHY="its creation-lock launcher process $pid may still be running"
            return 1
          fi
          teardown_foreign_proc_record "$pid"
          ;;
        1) ;;
        *)
          TEARDOWN_FOREIGN_RULE=inspection-unavailable
          TEARDOWN_FOREIGN_WHY="the process table cannot be read, so its creation-lock launcher process $pid is not proved gone"
          return 1
          ;;
      esac
      rc=0
      ;;
    1) ;;
    *)
      TEARDOWN_FOREIGN_RULE=inspection-unavailable
      TEARDOWN_FOREIGN_WHY="its lock state cannot be read"
      return 1
      ;;
  esac
}

# Does <copy> lie strictly inside one of the task's own nested copies? Removing
# that own copy then takes <copy> with it, so a held close never leaves it behind.
teardown_copy_inside_own_nested() {  # <copy>
  local copy=$1 own
  for own in ${TEARDOWN_NESTED_COPIES[@]+"${TEARDOWN_NESTED_COPIES[@]}"}; do
    case "$copy" in "$own"/*) return 0 ;; esac
  done
  return 1
}

# Does the held-copy rule apply to <copy> at all? Not for a forced close or the
# retirement of a secondmate home, not for a copy inside an own nested copy, which
# the close removes with it, and not for a path that would break the one-line
# record. Such a copy is proved, preserved and released as any other.
teardown_foreign_copy_hold_applies() {  # <copy>
  local copy=$1
  # shellcheck disable=SC2153 # KIND is bin/fm-teardown.sh's global, not a typo of a local.
  case "${FORCE:-}:$KIND" in --force:*|*:secondmate) return 1 ;; esac
  ! teardown_copy_inside_own_nested "$copy" || return 1
  case "$copy$ID$TEARDOWN_RETURN_SLOT" in *$'\t'*|*$'\n'*) return 1 ;; esac
}

# May foreign copy <copy>, refused for TEARDOWN_FOREIGN_WHY, be left standing
# while the task closes? Only when the hold applies to it and
# teardown_foreign_copy_prove found it a clean worktree root and no record, no
# process outside this teardown and no live launcher owns it, so the one reason it
# stays is work only it holds. The ownership proof runs again here, so a process
# of this teardown found in the copy is seen as the refusal it is. A copy any
# process runs in is never held, so retire never signals a process inside a copy
# that stays; when the only such process is one of this teardown, the refusal
# names its pid.
teardown_foreign_copy_holdable() {  # <copy>
  local copy=$1 procs=$TEARDOWN_FOREIGN_PROCS_BASE rc=0 entry pid own=
  teardown_foreign_copy_hold_applies "$copy" || return 1
  teardown_foreign_copy_unowned "$copy" || rc=1
  if [ "${#TEARDOWN_FOREIGN_PROCS[@]}" -gt "$procs" ]; then
    if [ "$rc" = 0 ]; then
      for entry in "${TEARDOWN_FOREIGN_PROCS[@]:$procs}"; do
        pid=${entry%%$'\t'*}
        case " $own " in *" $pid "*) ;; *) own+="${own:+ }$pid" ;; esac
      done
      TEARDOWN_FOREIGN_RULE=process-cwd-owner
      TEARDOWN_FOREIGN_PID=${own%% *}
      TEARDOWN_FOREIGN_WHY="process ${own// /, } of this teardown runs in it or launched its creation lock"
    fi
    TEARDOWN_FOREIGN_PROCS=(${TEARDOWN_FOREIGN_PROCS[@]+"${TEARDOWN_FOREIGN_PROCS[@]:0:$procs}"})
    return 1
  fi
  [ "$rc" = 0 ]
}

# Proves foreign copy <copy>, or returns 1 with TEARDOWN_FOREIGN_WHY naming what
# could not be proved, TEARDOWN_FOREIGN_RULE the predicate that failed
# (inspection-unavailable when a read, not a policy, failed) and
# TEARDOWN_FOREIGN_HOLDABLE set to the hold class, ignored or commits, when the
# copy may stay held (teardown_foreign_copy_holdable). Writes nothing. A
# half-removed or unreadable
# copy fails the first check. A landing check or an ignored-file listing that
# could not run never leaves the copy holdable. The landed-work rule gets an
# empty branch name so it never adopts this copy's PR as the task's recorded one.
# Its own explanation goes to TEARDOWN_FOREIGN_DIAG for the caller to print with
# the refusal, so a copy that stays held leaves no REFUSED text in the output of a
# close that succeeds.
TEARDOWN_FOREIGN_HOLDABLE=0
TEARDOWN_FOREIGN_PROCS_BASE=0
TEARDOWN_FOREIGN_DIAG=
# One "copy<TAB>HEAD" entry per foreign copy the landed-work rule answered "not
# landed" for, kept so the proof repeated under the project lock reuses it.
TEARDOWN_UNLANDED_COPIES=()
teardown_foreign_unlanded_cached() {  # <copy> <head>
  local entry
  for entry in ${TEARDOWN_UNLANDED_COPIES[@]+"${TEARDOWN_UNLANDED_COPIES[@]}"}; do
    [ "$entry" != "$1"$'\t'"$2" ] || return 0
  done
  return 1
}
teardown_foreign_copy_prove() {  # <copy>
  local copy=$1 rc=0 unique diag head
  TEARDOWN_FOREIGN_WHY=
  TEARDOWN_FOREIGN_RULE='copy-unowned'
  TEARDOWN_FOREIGN_DIAG=
  TEARDOWN_FOREIGN_HOLDABLE=0
  TEARDOWN_FOREIGN_PROCS_BASE=${#TEARDOWN_FOREIGN_PROCS[@]}
  fm_task_copy_preserve "$PROJ" "$ID" "$copy" 0 || rc=$?
  if [ "$rc" = 1 ]; then
    TEARDOWN_FOREIGN_RULE=${FM_TASK_COPY_STABLE:-inspection-unavailable}
    [ -z "$FM_TASK_COPY_DIRTY" ] || TEARDOWN_FOREIGN_RULE='copy-preserved'
    TEARDOWN_FOREIGN_WHY="it $FM_TASK_COPY_REASON"
    return 1
  fi
  teardown_foreign_copy_unowned "$copy" || return 1
  unique=$(mktemp "${TMPDIR:-/tmp}/fm-teardown-ignored.XXXXXX") || {
    TEARDOWN_FOREIGN_RULE=inspection-unavailable
    TEARDOWN_FOREIGN_WHY="its ignored files could not be listed"
    return 1
  }
  if ! teardown_preservable_ignored_z "$copy" >"$unique"; then
    rm -f "$unique"
    TEARDOWN_FOREIGN_RULE=inspection-unavailable
    TEARDOWN_FOREIGN_WHY="its ignored files could not be listed"
    return 1
  fi
  if [ -s "$unique" ] && teardown_foreign_copy_hold_applies "$copy"; then
    TEARDOWN_FOREIGN_RULE='copy-ignored-files'
    TEARDOWN_FOREIGN_WHY="it holds ignored files that exist nowhere else: $(fm_refuse_text "$(teardown_nul_list_text "$unique")")"
    rm -f "$unique"
    ! teardown_foreign_copy_holdable "$copy" || TEARDOWN_FOREIGN_HOLDABLE=ignored
    return 1
  fi
  rm -f "$unique"
  # Under the project lock the landed-work rule asks no forge and fetches nothing,
  # and refuses a proof it has not cached. A copy it answered "not landed" for is
  # cached here by path and HEAD: an unchanged copy keeps that verdict, and one
  # whose HEAD moved is proved again by the landed-work rule, which refuses.
  head=$(git -C "$copy" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || head=
  if [ -n "$head" ] && [ "${TREEHOUSE_PROJECT_LOCK_HELD:-0}" = 1 ] && [ "${TEARDOWN_SLOT_CUSTODY:-}" != project ] \
      && teardown_foreign_unlanded_cached "$copy" "$head"; then
    TEARDOWN_FOREIGN_RULE='copy-landed'
    TEARDOWN_FOREIGN_WHY="its HEAD ${head:0:12} is not proved landed"
    ! teardown_foreign_copy_holdable "$copy" || TEARDOWN_FOREIGN_HOLDABLE=commits
    return 1
  fi
  diag=$(mktemp "${TMPDIR:-/tmp}/fm-teardown-landed.XXXXXX") || diag=
  if ! teardown_landed "$copy" HEAD "" 2> "${diag:-/dev/null}"; then
    [ -z "$diag" ] || TEARDOWN_FOREIGN_DIAG=$(cat "$diag")
    [ -z "$diag" ] || rm -f "$diag"
    if [ -n "$TEARDOWN_LANDED_UNASKED" ]; then
      TEARDOWN_FOREIGN_RULE=inspection-unavailable
      TEARDOWN_FOREIGN_WHY="its landing could not be checked ($TEARDOWN_LANDED_UNASKED)"
    else
      TEARDOWN_FOREIGN_RULE='copy-landed'
      TEARDOWN_FOREIGN_WHY="its HEAD ${FM_TASK_COPY_HEAD:0:12} is not proved landed"
      [ -z "$head" ] || { TEARDOWN_UNLANDED_COPIES+=("$copy"$'\t'"$head"); }
      ! teardown_foreign_copy_holdable "$copy" || TEARDOWN_FOREIGN_HOLDABLE=commits
    fi
    return 1
  fi
  [ -z "$diag" ] || { [ ! -s "$diag" ] || cat "$diag" >&2; rm -f "$diag"; }
}

# Prints the refusals teardown_foreign_copies_prove kept back, each with the
# landed-work explanation that came with it, in the order the copies were proved.
teardown_foreign_refusals_print() {
  local i
  for i in "${!TEARDOWN_DEF_COPY[@]}"; do
    [ -z "${TEARDOWN_DEF_DIAG[$i]}" ] || printf '%s\n' "${TEARDOWN_DEF_DIAG[$i]}" >&2
    TEARDOWN_FOREIGN_RULE=${TEARDOWN_DEF_RULE[$i]}
    TEARDOWN_FOREIGN_WHY=${TEARDOWN_DEF_WHY[$i]}
    TEARDOWN_FOREIGN_PID=${TEARDOWN_DEF_PID[$i]}
    teardown_refuse_copy "$TEARDOWN_FOREIGN_RULE" "foreign copy ${TEARDOWN_DEF_COPY[$i]} stays in pool slot $TEARDOWN_FOREIGN_SLOT_LABEL: $TEARDOWN_FOREIGN_WHY." "${TEARDOWN_DEF_COPY[$i]}"
  done
  TEARDOWN_DEF_RULE=() TEARDOWN_DEF_WHY=() TEARDOWN_DEF_PID=() TEARDOWN_DEF_COPY=() TEARDOWN_DEF_DIAG=()
}

# Proves every foreign copy in <slot> and records the provable ones in
# TEARDOWN_FOREIGN_COPIES and the held ones in TEARDOWN_FOREIGN_HELD. An
# unprovable copy is refused with its typed envelope, and the registered-copy
# check then repeats the refusal without a second event because it does not list
# the copy as allowed. When every refused copy is held, nothing is refused here:
# bin/fm-teardown.sh then closes the task and names the held copies, so no
# REFUSED line is printed for a close that succeeds. A provable copy inside an
# own nested copy would be swept away by a held close, so it makes the held
# copies refuse instead and the close takes the ordinary route.
TEARDOWN_FOREIGN_SLOT_LABEL=
teardown_foreign_copies_prove() {  # <slot>
  local slot=$1 copy known allowed swept=0
  TEARDOWN_FOREIGN_COPIES=()
  TEARDOWN_FOREIGN_PROCS=()
  TEARDOWN_FOREIGN_HELD=()
  TEARDOWN_FOREIGN_HELD_KIND=()
  TEARDOWN_FOREIGN_REFUSED=0
  TEARDOWN_DEF_RULE=() TEARDOWN_DEF_WHY=() TEARDOWN_DEF_PID=() TEARDOWN_DEF_COPY=() TEARDOWN_DEF_DIAG=()
  teardown_slot_registered_copies "$slot" || return 0
  slot=$(fm_task_copy_canonical_dir "$slot") || return 0
  TEARDOWN_FOREIGN_SLOT_LABEL=$slot
  for copy in ${TEARDOWN_SLOT_COPIES[@]+"${TEARDOWN_SLOT_COPIES[@]}"}; do
    known=0
    for allowed in ${TEARDOWN_NESTED_COPIES[@]+"${TEARDOWN_NESTED_COPIES[@]}"}; do
      [ "$copy" != "$allowed" ] || known=1
    done
    [ "$known" = 0 ] || continue
    if teardown_foreign_copy_prove "$copy"; then
      TEARDOWN_FOREIGN_COPIES+=("$copy")
      ! teardown_copy_inside_own_nested "$copy" || swept=1
    else
      TEARDOWN_DEF_RULE+=("$TEARDOWN_FOREIGN_RULE")
      TEARDOWN_DEF_WHY+=("$TEARDOWN_FOREIGN_WHY")
      TEARDOWN_DEF_PID+=("${TEARDOWN_FOREIGN_PID:-}")
      TEARDOWN_DEF_COPY+=("$copy")
      TEARDOWN_DEF_DIAG+=("$TEARDOWN_FOREIGN_DIAG")
      if [ "$TEARDOWN_FOREIGN_HOLDABLE" != 0 ]; then
        TEARDOWN_FOREIGN_HELD+=("$copy"$'\t'"$TEARDOWN_FOREIGN_WHY")
        TEARDOWN_FOREIGN_HELD_KIND+=("$TEARDOWN_FOREIGN_HOLDABLE")
      else
        TEARDOWN_FOREIGN_REFUSED=$((TEARDOWN_FOREIGN_REFUSED + 1))
      fi
    fi
  done
  [ "$swept" = 0 ] || [ "${#TEARDOWN_FOREIGN_HELD[@]}" -eq 0 ] || TEARDOWN_FOREIGN_REFUSED=$((TEARDOWN_FOREIGN_REFUSED + 1))
  [ "$TEARDOWN_FOREIGN_REFUSED" -gt 0 ] || [ "${#TEARDOWN_FOREIGN_HELD[@]}" -eq 0 ] || return 0
  teardown_foreign_refusals_print
}

# Does one of the task's own nested copies hold a Git repository or linked
# worktree that is not the task's own, such as a separate clone or a worktree of
# another project? The held close removes that own copy with its contents, and
# no registered-copy list sees such a repository, so its commits would be lost
# with no ref left behind. Submodules of the own repository and linked worktrees
# of the same repository are not counted: the latter are foreign copies and are
# proved on their own. Prints a refusal and returns 1 for the first repository
# found, or when the scan cannot be completed; changes nothing.
teardown_own_nested_other_repos() {
  local own hit hits found dir common own_common rc status
  for own in ${TEARDOWN_NESTED_COPIES[@]+"${TEARDOWN_NESTED_COPIES[@]}"}; do
    [ -d "$own" ] || continue
    if ! own_common=$(git -C "$own" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
      teardown_refuse_copy inspection-unavailable "the Git directory of task $ID's nested copy $own cannot be read, so what it holds cannot be proved; nothing was removed." "$own"
      return 1
    fi
    status=0
    found=
    # NUL-framed, so a path that holds a newline stays one path.
    if hits=$(mktemp "${TMPDIR:-/tmp}/fm-teardown-repos.XXXXXX"); then
      find -P "$own" -mindepth 2 -name .git ! -path "$own/.git/*" -print0 >"$hits" 2>/dev/null || status=$?
      while IFS= read -r -d '' hit; do
        [ -n "$hit" ] || continue
        dir=${hit%/.git}
        rc=0
        common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || rc=$?
        case "$rc:$common" in
          0:"$own_common"|0:"$own_common"/modules/*|0:"$own_common"/worktrees/*/modules/*) continue ;;
        esac
        found=1
        break
      done <"$hits"
      rm -f "$hits"
    else
      status=1
    fi
    if [ -n "$found" ]; then
      teardown_refuse_copy registered-copy-proven "pool slot ${TEARDOWN_RETURN_SLOT:-$own} would lose Git repository $dir inside task $ID's nested copy $own, which holds work no task record proves landed; its commits would have no ref left; nothing was removed." "$dir"
      return 1
    fi
    if [ "$status" != 0 ]; then
      teardown_refuse_copy inspection-unavailable "task $ID's nested copy $own could not be scanned for other Git repositories, so what it holds cannot be proved; nothing was removed." "$own"
      return 1
    fi
  done
}

# Appends each held foreign copy of the last proof to the record
# data/held-foreign-copies.log: UTC time, closing task id, slot path, copy path
# and the exact reason, tab separated. bin/fm-teardown.sh calls it once every
# proof has passed and before anything is removed, and refuses the close when it
# returns 1, so the inventory is never missing for a close that happened. A line
# that is already there for the same task, slot, copy and reason is not written
# again, so a rerun after a later refusal adds nothing. The record is only ever
# appended to here; nothing returns the slot or removes a held copy on its own,
# and a held copy goes only on the owner's word naming it.
teardown_held_copies_record() {
  local record="$DATA/held-foreign-copies.log" entry copy why slot stamp rc=0
  [ "${#TEARDOWN_FOREIGN_HELD[@]}" -gt 0 ] || return 0
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  slot=$(fm_refuse_text "$TEARDOWN_HELD_SLOT")
  mkdir -p "$DATA" 2>/dev/null || return 1
  [ ! -e "$record" ] || [ -f "$record" ] || return 1
  for entry in "${TEARDOWN_FOREIGN_HELD[@]}"; do
    copy=$(fm_refuse_text "${entry%%$'\t'*}")
    why=$(fm_refuse_text "${entry#*$'\t'}")
    if [ -f "$record" ] && FM_HELD_ID=$ID FM_HELD_SLOT=$slot FM_HELD_COPY=$copy FM_HELD_WHY=$why awk -F'\t' \
        '$2 == ENVIRON["FM_HELD_ID"] && $3 == ENVIRON["FM_HELD_SLOT"] && $4 == ENVIRON["FM_HELD_COPY"] && $5 == ENVIRON["FM_HELD_WHY"] { f = 1 } END { exit !f }' "$record" 2>/dev/null; then
      continue
    fi
    { printf '%s\t%s\t%s\t%s\t%s\n' "$stamp" "$ID" "$slot" "$copy" "$why" >> "$record"; } 2>/dev/null || rc=1
  done
  return "$rc"
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

# The one credit the driver is passed for the next teardown_run_closeout, chosen
# by teardown_closeout_credit from teardown's own proofs: empty, "--pr <N>" or
# "--bundle-record <file>", never both (the driver rejects the pair). Callers
# that prove nothing (bin/fm-copy-sweep.sh) leave it empty.
TEARDOWN_CLOSEOUT_CREDIT=()
TEARDOWN_CLOSEOUT_CREDIT_FILE=

# Runs Vernant's closeout driver on <copy>: it releases its own creation lock
# and removes the copy. With "plan" it omits --execute-cleanup, so the driver
# only says whether it would. TEARDOWN_CLOSEOUT_STDOUT is verdict input;
# TEARDOWN_CLOSEOUT_OUT retains stdout and stderr for display and refusal records.
# An optional capture file belongs to the caller (so a killed plan can clean it).
# Exit 0 means the driver allowed and, unless planning, ran the cleanup.
teardown_run_closeout() {  # <slot> <copy> [plan] [stdout-capture-file]
  local slot=$1 copy=$2 execute=--execute-cleanup driver py rc=0 capture=${4:-} own_capture=0
  [ "${3:-}" != plan ] || execute=
  TEARDOWN_CLOSEOUT_STDOUT=
  TEARDOWN_CLOSEOUT_OUT=
  driver=$slot/scripts/git-stability/closeout_pr.py
  py=${FM_TEARDOWN_VERNANT_PYTHON:-$slot/.venv/bin/python}
  if [ ! -f "$driver" ] || [ ! -x "$py" ]; then
    TEARDOWN_CLOSEOUT_OUT="Vernant's closeout driver $driver or its interpreter $py is not available"
    return 127
  fi
  if [ -z "$capture" ]; then
    capture=$(mktemp "${TMPDIR:-/tmp}/fm-closeout-stdout.XXXXXX") || {
      TEARDOWN_CLOSEOUT_OUT="Vernant's closeout stdout could not be captured"
      return 1
    }
    own_capture=1
  fi
  # tee sees only stdout; stderr bypasses it into the display capture. pipefail
  # preserves a driver refusal and treats a failed capture as no permission.
  # Sentinels preserve trailing newlines in both output contracts.
  TEARDOWN_CLOSEOUT_OUT=$(
    set -o pipefail
    local status=0
    { ( cd "$slot" && "$py" "$driver" --cleanup-worktree "$copy" ${TEARDOWN_CLOSEOUT_CREDIT[@]+"${TEARDOWN_CLOSEOUT_CREDIT[@]}"} ${execute:+"$execute"} ) | tee "$capture"; } 2>&1 || status=$?
    printf '.'
    exit "$status"
  ) || rc=$?
  TEARDOWN_CLOSEOUT_OUT=${TEARDOWN_CLOSEOUT_OUT%.}
  TEARDOWN_CLOSEOUT_STDOUT=$(cat "$capture" || exit 1; printf '.') || rc=1
  TEARDOWN_CLOSEOUT_STDOUT=${TEARDOWN_CLOSEOUT_STDOUT%.}
  [ "$own_capture" = 0 ] || rm -f -- "$capture"
  return "$rc"
}

# Saves a refused driver's full output privately, then shows its last 20 lines.
# Prefix and sanitize each line so driver text cannot forge refusal directives.
# Successful closeouts never call this helper and create no durable output file.
teardown_closeout_refusal() {  # <foreign|own nested> <copy> <driver-exit>
  local kind=$1 copy=$2 rc=$3 output_file line
  if [ -n "${TEARDOWN_CLOSEOUT_NOT_RUN:-}" ]; then
    printf "REFUSED: teardown did not run Vernant's closeout driver for %s copy %s, which keeps its lock: %s.\n" \
      "$kind" "$(fm_refuse_text "$copy")" "$(fm_refuse_text "$TEARDOWN_CLOSEOUT_NOT_RUN")" >&2
    return 0
  fi
  if output_file=$(umask 077; mkdir -p "$DATA/$ID" && mktemp "$DATA/$ID/vernant-closeout.XXXXXX") \
      && printf '%s' "$TEARDOWN_CLOSEOUT_OUT" > "$output_file"; then
    printf "REFUSED: Vernant's closeout driver did not release %s copy %s (exit %s): full output: %s\n" \
      "$kind" "$(fm_refuse_text "$copy")" "$rc" "$(fm_refuse_text "$output_file")" >&2
  else
    printf "REFUSED: Vernant's closeout driver did not release %s copy %s (exit %s): full output could not be saved under %s\n" \
      "$kind" "$(fm_refuse_text "$copy")" "$rc" "$(fm_refuse_text "$DATA/$ID")" >&2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    printf '  %s\n' "$(fm_refuse_text "$line")" >&2
  done < <(printf '%s' "$TEARDOWN_CLOSEOUT_OUT" | tail -n 20)
  [ -z "${TEARDOWN_RELEASE_WHY:-}" ] || printf '  The copy was not released directly: %s.\n' "$(fm_refuse_text "$TEARDOWN_RELEASE_WHY")" >&2
}

# The merged-PR number whose merged head holds the whole HEAD of <copy>, or
# failure. bin/fm-teardown.sh's merged-PR proof runs in a subshell, so the task's
# own PR_URL is never overwritten by a lookup made for another copy. The closeout
# driver reads --pr with gh pr view (Vernant scripts/git-stability/closeout_pr.py
# load_pr_info), so only a GitHub pull request can be its credit: for a merged
# pull request on another forge this prints its URL and returns 2.
teardown_credit_pr() {  # <copy> <head>
  local copy=$1 head=$2 branch url
  declare -F pr_is_merged >/dev/null 2>&1 || return 1
  branch=$(git -C "$copy" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=
  url=$(
    TEARDOWN_LANDED_DIR=$copy TEARDOWN_LANDED_REF=$head
    pr_is_merged "$branch" >/dev/null 2>&1 && printf '%s' "$PR_URL"
  ) || return 1
  if ! [[ "$url" =~ ^https://github[.]com/[^/]+/[^/]+/pull/([0-9]+)$ ]]; then
    [ -z "$url" ] || { printf '%s' "$url"; return 2; }
    return 1
  fi
  printf '%s' "${BASH_REMATCH[1]}"
}

# Teardown's own bundle proof for <copy>, then the driver's narrower claim rule:
# it credits a bundle only when every commit of git rev-list HEAD --not --remotes
# is both recorded and advertised as a head of the bundle, while teardown's proof
# only needs every maximal tip. Sets TEARDOWN_CREDIT_RECORD to a private record
# file in the schema the driver reads, built from teardown's proved record and its stored bundle, or
# fails with TEARDOWN_CREDIT_WHY naming the unmet fact. TEARDOWN_CREDIT_BUNDLE
# names the stored bundle whenever teardown's own proof holds.
TEARDOWN_CREDIT_WHY=
TEARDOWN_CREDIT_BUNDLE=
TEARDOWN_CREDIT_RECORD=
teardown_credit_bundle() {  # <copy> <head>
  local copy=$1 head=$2 saved_accepted=${TEARDOWN_BUNDLE_ACCEPTED:-} saved_reason=${TEARDOWN_BUNDLE_REASON:-}
  local stored hash tips unpushed advertised commit record rc=0
  TEARDOWN_CREDIT_BUNDLE=
  TEARDOWN_CREDIT_RECORD=
  teardown_bundle_attended || { TEARDOWN_CREDIT_WHY='unattended teardown has no bundle route'; return 1; }
  [ -f "$DATA/$ID/preservation-bundles.tsv" ] || { TEARDOWN_CREDIT_WHY='no preservation record'; return 1; }
  teardown_bundle_preserved "$copy" "$head" >/dev/null 2>&1 || rc=$?
  stored=$TEARDOWN_BUNDLE_ACCEPTED
  hash=$TEARDOWN_BUNDLE_RECORD_HASH
  tips=$TEARDOWN_BUNDLE_RECORD_TIPS
  TEARDOWN_BUNDLE_ACCEPTED=$saved_accepted
  TEARDOWN_BUNDLE_REASON=$saved_reason
  if [ "$rc" != 0 ] || [ -z "$stored" ]; then
    TEARDOWN_CREDIT_WHY='no verified bundle holds this copy'
    return 1
  fi
  TEARDOWN_CREDIT_BUNDLE=$stored
  unpushed=$(git -C "$copy" rev-list "$head" --not --remotes 2>/dev/null) || { TEARDOWN_CREDIT_WHY='locally-only commits cannot be listed'; return 1; }
  advertised=$(git -C "$copy" bundle list-heads "$stored" 2>/dev/null | awk '{print $1}') || advertised=
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    case " $tips " in *" $commit "*) ;; *) TEARDOWN_CREDIT_WHY="commit $commit is not a recorded and advertised head of the bundle"; return 1 ;; esac
    case $'\n'"$advertised"$'\n' in *$'\n'"$commit"$'\n'*) ;; *) TEARDOWN_CREDIT_WHY="commit $commit is not a recorded and advertised head of the bundle"; return 1 ;; esac
  done <<< "$unpushed"
  [ -n "$unpushed" ] || { TEARDOWN_CREDIT_WHY='the copy has no locally-only commit'; return 1; }
  case "/$DATA/$ID/" in */data/*) ;; *) TEARDOWN_CREDIT_WHY='the task data directory is not under a data directory'; return 1 ;; esac
  record=$(umask 077; mktemp "$DATA/$ID/closeout-bundle-record.XXXXXX") || { TEARDOWN_CREDIT_WHY='the bundle record cannot be written'; return 1; }
  if ! jq -n --arg bundle "$stored" --arg sha "$hash" --arg tips "$tips" \
      '{bundle_path: $bundle, sha256: $sha, unpushed_commit_tips: ($tips | split(" "))}' > "$record" 2>/dev/null; then
    rm -f -- "$record"
    TEARDOWN_CREDIT_WHY='the bundle record cannot be written'
    return 1
  fi
  TEARDOWN_CREDIT_RECORD=$record
  # The credit is a proof the driver acts on, so the final proof before the
  # driver rechecks it like any other bundle admission.
  teardown_admit "$copy" bundle "$head" "$stored"
}

# Chooses the one credit for the driver from teardown's own proofs, once per
# call, and prints it: --pr <N> when a merged pull request holds the whole copy
# head, else --bundle-record <file> when a verified bundle does and meets the
# driver's claim rule, else none. Never both: the driver rejects the pair.
TEARDOWN_CLOSEOUT_PROOF=
teardown_closeout_credit() {  # <copy>
  local copy=$1 head pr pr_rc=0 note=
  TEARDOWN_CLOSEOUT_CREDIT=()
  TEARDOWN_CLOSEOUT_CREDIT_FILE=
  TEARDOWN_CREDIT_WHY=
  TEARDOWN_CREDIT_BUNDLE=
  TEARDOWN_CLOSEOUT_PROOF='the landed-work rule'
  head=$(git -C "$copy" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || head=
  [ -z "$head" ] || pr=$(teardown_credit_pr "$copy" "$head") || pr_rc=$?
  if [ -n "$head" ] && [ "$pr_rc" = 2 ]; then
    note="merged pull request $pr holds HEAD ${head:0:12}, but the closeout driver reads --pr from GitHub only (gh pr view)"
  fi
  if [ -z "$head" ]; then
    echo "teardown: closeout credit for $copy: none (HEAD cannot be resolved)" >&2
  elif [ "$pr_rc" = 0 ]; then
    TEARDOWN_CLOSEOUT_CREDIT=(--pr "$pr")
    TEARDOWN_CLOSEOUT_PROOF="merged pull request $pr"
    echo "teardown: closeout credit for $copy: --pr $pr (the merged pull request holds HEAD ${head:0:12})" >&2
  elif teardown_credit_bundle "$copy" "$head"; then
    TEARDOWN_CLOSEOUT_CREDIT=(--bundle-record "$TEARDOWN_CREDIT_RECORD")
    TEARDOWN_CLOSEOUT_CREDIT_FILE=$TEARDOWN_CREDIT_RECORD
    TEARDOWN_CLOSEOUT_PROOF="recorded bundle $TEARDOWN_CREDIT_BUNDLE"
    echo "teardown: closeout credit for $copy: --bundle-record $TEARDOWN_CREDIT_RECORD (bundle $TEARDOWN_CREDIT_BUNDLE holds every locally-only commit${note:+; $note})" >&2
  else
    [ -z "$TEARDOWN_CREDIT_BUNDLE" ] || TEARDOWN_CLOSEOUT_PROOF="recorded bundle $TEARDOWN_CREDIT_BUNDLE"
    [ -z "$note" ] || TEARDOWN_CREDIT_WHY="$note${TEARDOWN_CREDIT_WHY:+; $TEARDOWN_CREDIT_WHY}"
    echo "teardown: closeout credit for $copy: none${TEARDOWN_CREDIT_WHY:+ ($TEARDOWN_CREDIT_WHY)}" >&2
  fi
}

teardown_closeout_credit_discard() {
  [ -z "$TEARDOWN_CLOSEOUT_CREDIT_FILE" ] || rm -f -- "$TEARDOWN_CLOSEOUT_CREDIT_FILE"
  TEARDOWN_CLOSEOUT_CREDIT=()
  TEARDOWN_CLOSEOUT_CREDIT_FILE=
}

# Is the driver's refusal one that leaves a dead launcher's lock as the only
# thing between a proved copy and its removal? Only the driver or its interpreter
# being unavailable, or its named verdict that tracked content is uncredited
# (verification_stale_or_uncovered_paths), qualifies; a live tenant, a lease
# conflict, an occupied directory or any other verdict keeps the copy.
teardown_driver_gap() {  # <driver-exit>
  [ "$1" != 127 ] || return 0
  printf '%s' "$TEARDOWN_CLOSEOUT_STDOUT" | jq -e -s \
    'length >= 1 and (.[-1] | type == "object" and .allowed == false and .reason == "verification_stale_or_uncovered_paths")' >/dev/null 2>&1
}

# Is the creation-lock launcher <pid> gone? Returns 0 when it is absent from a
# complete process table or started after the lock was written (a recycled pid),
# 1 when it may still be running, and 2 when the process table cannot be read.
# An unreadable table is never taken for absence.
teardown_launcher_gone() {  # <pid> <lock-file>
  local rc=0
  teardown_lock_launcher_may_be_live "$1" "$2" || rc=$?
  case "$rc" in
    0) return 1 ;;
    1) return 0 ;;
    *) return 2 ;;
  esac
}

# Releases and removes a proved copy whose Vernant creation lock names a launcher
# that is gone, when the driver could not (teardown_driver_gap). Every one of
# teardown's own proofs is made again first and the lock is read a second time
# immediately before the unlock: the copy keeps its HEAD, no active record names
# it, no process runs in it or holds a file in it open, the launcher is not running
# (or started after the lock was written), its landed or bundle proof holds, and
# Git itself would remove it without force. The release is a non-forced
# git worktree unlock followed by a non-forced git worktree remove, never a
# forced removal; a removal that fails after the unlock puts the lock back.
# Returns 1 with TEARDOWN_RELEASE_WHY naming the fact that kept the copy.
TEARDOWN_RELEASE_WHY=
teardown_dead_launcher_release() {  # <slot> <copy> <head> <foreign|own nested>
  local slot=$1 copy=$2 head=$3 kind=$4 lock pid lock_file rc=0 now gone procs mtime landed_snap
  TEARDOWN_RELEASE_WHY=
  # Main 1843: an Orca-backed task keeps base behaviour, which has no direct release.
  if [ "${BACKEND:-}" = orca ]; then
    TEARDOWN_RELEASE_WHY='the direct release of a dead launcher'"'"'s lock is not admitted for an Orca-backed task (Main 1843)'
    return 1
  fi
  teardown_copy_lock_file "$copy" || { TEARDOWN_RELEASE_WHY='its lock state cannot be read'; return 1; }
  lock=$TEARDOWN_FOREIGN_LOCK
  lock_file=$TEARDOWN_FOREIGN_LOCK_FILE
  pid=$(teardown_vernant_lock_pid "$lock") || { TEARDOWN_RELEASE_WHY="its lock is not Vernant's creation lock (${lock:-no reason given})"; return 1; }
  gone=0
  teardown_launcher_gone "$pid" "$lock_file" || gone=$?
  case "$gone" in
    0) ;;
    1) TEARDOWN_RELEASE_WHY="its creation-lock launcher process $pid may still be running"; return 1 ;;
    *) TEARDOWN_RELEASE_WHY="the process table cannot be read, so launcher $pid is not proved gone"; return 1 ;;
  esac
  now=$(git -C "$copy" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || now=
  [ -n "$now" ] && [ "$now" = "$head" ] || { TEARDOWN_RELEASE_WHY='its HEAD changed after the landing proof'; return 1; }
  if [ "$kind" = 'own nested' ]; then
    FM_TASK_COPY_RELEASED_PRIOR_RETIRING=$META
    teardown_foreign_copy_unowned "$copy" || rc=1
    FM_TASK_COPY_RELEASED_PRIOR_RETIRING=
  else
    teardown_foreign_copy_unowned "$copy" || rc=1
  fi
  if [ "$rc" != 0 ]; then
    TEARDOWN_RELEASE_WHY=${TEARDOWN_FOREIGN_WHY:-its ownership cannot be proved}
    return 1
  fi
  teardown_landed "$copy" HEAD "" >/dev/null 2>&1 || { TEARDOWN_RELEASE_WHY='its landed-work proof no longer holds'; return 1; }
  # Main 1843: a merged pull request on a forge the driver cannot read (Forgejo)
  # is no credit, so a copy that only such a pull request admits, with no content
  # proof and no bundle, is held rather than released here.
  landed_snap=$(teardown_latest_admission "$copy" landed)
  case "$landed_snap" in
    'pr https://'*)
      if ! [[ "${landed_snap#pr }" =~ ^https://github[.]com/[^/]+/[^/]+/pull/[0-9]+$ ]] \
          && [ -z "$(teardown_latest_admission "$copy" bundle)" ]; then
        TEARDOWN_RELEASE_WHY="only merged pull request ${landed_snap#pr } admits it, which the closeout driver cannot credit (it reads --pr from GitHub only), and no content proof or bundle holds it (Main 1843)"
        return 1
      fi
      ;;
  esac
  if teardown_copy_git_protects "$copy"; then
    TEARDOWN_RELEASE_WHY='it holds content Git would not remove without force'
    return 1
  fi
  # The retire phase has already ended this teardown's own processes, so any
  # process found running in the copy or holding a file in it open now, even one
  # of this teardown's own, appeared since: none may be there at the unlock, so
  # this scan, of working directories and open files alike, runs after the landed
  # and Git proofs, next to the unlock (teardown_copy_holder_free).
  if ! teardown_copy_holder_free "$copy"; then
    TEARDOWN_RELEASE_WHY=$TEARDOWN_HOLDER_WHY
    return 1
  fi
  now=$(git -C "$copy" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || now=
  [ -n "$now" ] && [ "$now" = "$head" ] || { TEARDOWN_RELEASE_WHY='its HEAD changed after the landing proof'; return 1; }
  # A changed admitting bundle refuses here, before any unlock; the final proof
  # after the unlock checks it again.
  if ! teardown_admitted_bundles_current "$copy" "$head"; then
    TEARDOWN_RELEASE_WHY="its recorded bundle no longer holds it ($TEARDOWN_BUNDLE_REASON)"
    return 1
  fi
  # The lock and the launcher are read once more, immediately before the unlock;
  # the lock must be the one first proved for this copy.
  if ! teardown_copy_lock_file "$copy" || [ "$TEARDOWN_FOREIGN_LOCK" != "$lock" ] || ! teardown_lock_is_first_seen "$copy" "$lock"; then
    TEARDOWN_RELEASE_WHY='its lock changed before the release'
    return 1
  fi
  gone=0
  teardown_launcher_gone "$pid" "$TEARDOWN_FOREIGN_LOCK_FILE" || gone=$?
  [ "$gone" = 0 ] || { TEARDOWN_RELEASE_WHY="its creation-lock launcher process $pid appeared, or could not be read, before the release"; return 1; }
  mtime=$(fm_lock_path_mtime "$TEARDOWN_FOREIGN_LOCK_FILE") || mtime=
  git -C "$slot" worktree unlock "$copy" >/dev/null 2>&1 || { TEARDOWN_RELEASE_WHY='git worktree unlock failed'; return 1; }
  # The final proof runs after the last unlock and the remove is the very next
  # action; a failed proof puts the lock back and refuses.
  if ! teardown_removal_final_proof "$copy" preserve locked "$pid" "$mtime"; then
    git -C "$slot" worktree lock --reason "$lock" "$copy" >/dev/null 2>&1 || true
    if teardown_copy_lock_file "$copy" && [ "$TEARDOWN_FOREIGN_LOCK" = "$lock" ]; then
      TEARDOWN_RELEASE_WHY="$TEARDOWN_FINAL_WHY; its lock was restored"
    else
      TEARDOWN_RELEASE_WHY="$TEARDOWN_FINAL_WHY, and its lock could not be restored, so the copy is now unlocked; lock it again with its old reason ($lock) before anything else runs in it"
    fi
    return 1
  fi
  if ! git -C "$slot" worktree remove "$copy" >/dev/null 2>&1; then
    git -C "$slot" worktree lock --reason "$lock" "$copy" >/dev/null 2>&1 || true
    if teardown_copy_lock_file "$copy" && [ "$TEARDOWN_FOREIGN_LOCK" = "$lock" ]; then
      TEARDOWN_RELEASE_WHY='git worktree remove (without force) failed; its lock was restored'
    else
      TEARDOWN_RELEASE_WHY="git worktree remove (without force) failed, and its lock could not be restored, so the copy is now unlocked; lock it again with its old reason ($lock) before anything else runs in it"
    fi
    return 1
  fi
  echo "teardown: released creation lock '$lock' on $kind copy $copy (launcher $pid is gone; proof: $TEARDOWN_CLOSEOUT_PROOF) and removed it without force" >&2
}

# The credit, the driver, and, only for the residue the driver cannot release, the
# direct release of a dead launcher's lock. Returns the driver's exit code when
# nothing released the copy; TEARDOWN_RELEASE_WHY then names why the direct
# release did not apply.
TEARDOWN_CLOSEOUT_NOT_RUN=
teardown_closeout_release() {  # <slot> <copy> <foreign|own nested>
  local slot=$1 copy=$2 kind=$3 rc=0 head pid='' mtime='' lock_rc=0
  TEARDOWN_RELEASE_WHY=
  TEARDOWN_CLOSEOUT_NOT_RUN=
  # The driver never runs under the project lock (Main 011). When teardown keeps
  # project custody because the slot's state cannot be proved, a locked copy is
  # not released in this pass: it is deferred and named (Main 1681).
  if [ "${TREEHOUSE_PROJECT_LOCK_HELD:-0}" = 1 ]; then
    TEARDOWN_CLOSEOUT_NOT_RUN="deferred: teardown keeps project custody for this pass (the pool slot's state cannot be proved), and Vernant's closeout driver never runs under the project lock, so this locked copy is not released now"
    TEARDOWN_CLOSEOUT_OUT=$TEARDOWN_CLOSEOUT_NOT_RUN
    return 1
  fi
  head=$(git -C "$copy" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || head=
  teardown_closeout_credit "$copy"
  # The lock is read again just before the driver: an absent, unreadable,
  # unrecognized or changed lock (against the one first proved) refuses here.
  teardown_copy_lock_file "$copy" || lock_rc=$?
  case "$lock_rc" in
    0)
      if ! pid=$(teardown_vernant_lock_pid "$TEARDOWN_FOREIGN_LOCK"); then
        TEARDOWN_CLOSEOUT_NOT_RUN="its lock is no longer Vernant's creation lock (${TEARDOWN_FOREIGN_LOCK:-no reason given})"
      elif ! teardown_lock_is_first_seen "$copy" "$TEARDOWN_FOREIGN_LOCK"; then
        TEARDOWN_CLOSEOUT_NOT_RUN="its lock changed since it was proved (now: $TEARDOWN_FOREIGN_LOCK)"
      else
        mtime=$(fm_lock_path_mtime "$TEARDOWN_FOREIGN_LOCK_FILE") || mtime=''
      fi
      ;;
    1) TEARDOWN_CLOSEOUT_NOT_RUN='its lock is gone since it was proved' ;;
    *) TEARDOWN_CLOSEOUT_NOT_RUN='its lock state cannot be read' ;;
  esac
  # The retire phase has run, so no process may be in the copy or hold a file in
  # it open now, this teardown's own included: one found here is never queued
  # for a retire that will not run again, and nothing is signalled.
  [ -n "$TEARDOWN_CLOSEOUT_NOT_RUN" ] || teardown_copy_holder_free "$copy" \
    || TEARDOWN_CLOSEOUT_NOT_RUN=$TEARDOWN_HOLDER_WHY
  # The same final proof as every removal, just before the driver's execute call
  # (the driver then removes the copy itself).
  if [ -z "$TEARDOWN_CLOSEOUT_NOT_RUN" ] && ! teardown_removal_final_proof "$copy" preserve locked "$pid" "$mtime"; then
    TEARDOWN_CLOSEOUT_NOT_RUN="the final proof before the driver failed: $TEARDOWN_FINAL_WHY"
  fi
  if [ -n "$TEARDOWN_CLOSEOUT_NOT_RUN" ]; then
    teardown_closeout_credit_discard
    TEARDOWN_CLOSEOUT_OUT="teardown did not run the driver: $TEARDOWN_CLOSEOUT_NOT_RUN"
    return 1
  fi
  teardown_run_closeout "$slot" "$copy" || rc=$?
  teardown_closeout_credit_discard
  [ "$rc" != 0 ] || return 0
  if teardown_driver_gap "$rc"; then
    if teardown_dead_launcher_release "$slot" "$copy" "$head" "$kind"; then
      return 0
    fi
  else
    TEARDOWN_RELEASE_WHY="the driver's verdict is not one a direct release may take over"
  fi
  return "$rc"
}

# The last holder check before a locked copy is unlocked or handed to the driver:
# does no process run in <copy>, whatever its name, and does no process hold a
# file in it open? A search indexer (fm_task_copy_indexer_pid) that only holds a
# file open is exempt, unless this teardown recorded that process as its own
# (TEARDOWN_FOREIGN_PROCS), which nothing exempts. Returns 1 with
# TEARDOWN_HOLDER_WHY naming the first holder, or the scan that failed.
TEARDOWN_HOLDER_WHY=
teardown_copy_holder_free() {  # <copy>
  local copy=$1 procs pid path
  TEARDOWN_HOLDER_WHY=
  procs=$(pids_with_cwd_under "$copy") || { TEARDOWN_HOLDER_WHY='a scan for processes running in it failed'; return 1; }
  if [ -n "$procs" ]; then
    procs=${procs%%$'\n'*}
    TEARDOWN_HOLDER_WHY="process ${procs%%$'\t'*} runs in it after the retire phase"
    return 1
  fi
  procs=$(pids_with_open_file_under_all "$copy") || { TEARDOWN_HOLDER_WHY='a scan for processes holding its files open failed'; return 1; }
  while IFS=$'\t' read -r pid path; do
    [ -n "$pid" ] || continue
    if ! teardown_pid_recorded_own "$pid" && fm_task_copy_indexer_pid "$pid"; then
      continue
    fi
    TEARDOWN_HOLDER_WHY="process $pid holds $(fm_refuse_text "$path") open after the retire phase"
    return 1
  done <<< "$procs"
}

# Did this teardown record <pid> as one of its own processes (TEARDOWN_FOREIGN_PROCS)?
teardown_pid_recorded_own() {  # <pid>
  local record
  for record in ${TEARDOWN_FOREIGN_PROCS[@]+"${TEARDOWN_FOREIGN_PROCS[@]}"}; do
    [ "${record%%$'\t'*}" != "$1" ] || return 0
  done
  return 1
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

# Would a plain git worktree remove refuse <copy>? Git's own conditions, read
# from the copy itself and taken before the attempt, since a failed removal can
# leave files missing: modified or untracked files, a modules directory in the
# copy's git directory (even after a submodule deinit), or an initialized
# submodule. A copy that cannot be read is not proved protected.
teardown_copy_git_protects() {  # <copy>
  local status entry gitdir
  status=$(git -C "$1" status --porcelain --ignore-submodules=none 2>/dev/null) || return 1
  [ -z "$status" ] || return 0
  gitdir=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  [ ! -d "$gitdir/modules" ] || return 0
  while IFS= read -r -d '' entry; do
    case "$entry" in
      '160000 '*) [ ! -e "$1/${entry#*$'\t'}/.git" ] || return 0 ;;
    esac
  done < <(git -C "$1" ls-files --stage -z 2>/dev/null)
  return 1
}

# Preserves the ignored files of one proved foreign copy, then releases and
# removes it. Returns 1 after printing a refusal, or a plain error where Git's
# removal failed for a reason other than protecting the copy's contents.
teardown_foreign_copy_dispose() {  # <slot> <copy>
  local slot=$1 copy=$2 rc=0 remove_rc remove_err protected
  teardown_preserve_ignored "$copy" || {
    teardown_refuse_copy ignored-bytes-preserved "the ignored files of foreign copy $copy could not be preserved in $DATA/$ID/nested-copy-preserved; it was not removed." "$copy"
    return 1
  }
  teardown_copy_lock_file "$copy" || rc=$?
  case "$rc" in
    0)
      if ! teardown_vernant_lock_pid "$TEARDOWN_FOREIGN_LOCK" >/dev/null; then
        teardown_refuse_copy creation-lock-owner "foreign copy $copy is locked by something other than Vernant's creation lock; it was not removed." "$copy"
        return 1
      fi
      rc=0
      teardown_closeout_release "$slot" "$copy" foreign || rc=$?
      if [ "$rc" != 0 ]; then
        teardown_closeout_refusal foreign "$copy" "$rc"
        return 1
      fi
      ;;
    1)
      if teardown_lock_was_seen "$copy"; then
        teardown_refuse_copy creation-lock-owner "foreign copy $copy was locked when it was proved and now reads unlocked; a lock that vanishes is not proof the copy is free, so it was not removed." "$copy"
        return 1
      fi
      remove_rc=0
      teardown_copy_git_protects "$copy" && protected=1 || protected=0
      if ! teardown_removal_final_proof "$copy" preserve unlocked; then
        if [ -n "$TEARDOWN_FINAL_STABLE" ]; then
          teardown_refuse_copy nonforced-removal "foreign copy $copy was not removed: $TEARDOWN_FINAL_WHY." "$copy"
        else
          teardown_refuse_copy final-removal-proof "foreign copy $copy was not removed: the final proof before its removal failed: $TEARDOWN_FINAL_WHY." "$copy"
        fi
        return 1
      fi
      remove_err=$(git -C "$slot" worktree remove "$copy" 2>&1 >/dev/null) || remove_rc=$?
      if [ "$remove_rc" != 0 ]; then
        if [ "$protected" = 1 ] && [ "$remove_rc" = 128 ]; then
          teardown_refuse_copy nonforced-removal "git worktree remove would not remove foreign copy $copy without force; it was not removed." "$copy"
        else
          teardown_refuse_copy inspection-unavailable "git worktree remove failed for foreign copy $copy (exit $remove_rc): $remove_err; it was not removed." "$copy"
        fi
        return 1
      fi
      ;;
    *)
      echo "REFUSED: the lock state of foreign copy $(fm_refuse_text "$copy") cannot be read; it was not removed." >&2
      return 1
      ;;
  esac
  if teardown_foreign_copy_present "$slot" "$copy"; then
    echo "REFUSED: foreign copy $(fm_refuse_text "$copy") is still present or registered after its release; the pool slot was not returned." >&2
    return 1
  fi
  echo "teardown: removed landed foreign copy $(fm_refuse_text "$copy") from pool slot $slot" >&2
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
      [ -z "$TEARDOWN_FOREIGN_DIAG" ] || printf '%s\n' "$TEARDOWN_FOREIGN_DIAG" >&2
      teardown_refuse_copy "$TEARDOWN_FOREIGN_RULE" "foreign copy $copy in pool slot $slot is no longer provable: $TEARDOWN_FOREIGN_WHY; nothing was removed." "$copy"
      return 1
    fi
  done
  # NUL-framed, so a path that holds a newline stays one path.
  while IFS= read -r -d '' copy; do
    ordered+=("$copy")
  done < <(printf '%s\0' "${TEARDOWN_FOREIGN_COPIES[@]}" | LC_ALL=C sort -z -r)
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
      teardown_refuse_copy "${TEARDOWN_FOREIGN_RULE:-creation-lock-owner}" "own nested copy $copy stays in pool slot ${TEARDOWN_RETURN_SLOT:-${TEARDOWN_PEER_SLOT:-}}: $TEARDOWN_FOREIGN_WHY." "$copy"
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
    echo "REFUSED: own nested copy $(fm_refuse_text "$copy") is not locked by Vernant's creation lock any more; it was not removed." >&2
    return 1
  fi
  teardown_preserve_ignored "$copy" || {
    teardown_refuse_copy ignored-bytes-preserved "the ignored files of own nested copy $copy could not be preserved in $DATA/$ID/nested-copy-preserved; it was not removed." "$copy"
    return 1
  }
  rc=0
  teardown_closeout_release "$slot" "$copy" 'own nested' || rc=$?
  if [ "$rc" != 0 ]; then
    teardown_closeout_refusal 'own nested' "$copy" "$rc"
    return 1
  fi
  if teardown_foreign_copy_present "$slot" "$copy"; then
    echo "REFUSED: own nested copy $(fm_refuse_text "$copy") is still present or registered after its release; the pool slot was not returned." >&2
    return 1
  fi
  echo "teardown: removed landed own nested copy $(fm_refuse_text "$copy") from pool slot $slot" >&2
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
  # NUL-framed, so a path that holds a newline stays one path.
  while IFS= read -r -d '' copy; do
    ordered+=("$copy")
  done < <(printf '%s\0' "${TEARDOWN_NESTED_COPIES[@]}" | LC_ALL=C sort -z -r)
  for copy in "${ordered[@]}"; do
    [ -d "$copy" ] || continue
    rc=0
    teardown_copy_lock_file "$copy" || rc=$?
    case "$rc" in
      0) ;;
      1)
        # Unlocked: left to the plain removal, unless it was locked when proved.
        if teardown_lock_was_seen "$copy"; then
          teardown_refuse_copy creation-lock-owner "own nested copy $copy was locked when it was proved and now reads unlocked; a lock that vanishes is not proof the copy is free, so it was not removed." "$copy"
          return 1
        fi
        continue
        ;;
      *)
        teardown_refuse_copy inspection-unavailable "the lock state of own nested copy $copy cannot be read; it was not removed." "$copy"
        return 1
        ;;
    esac
    teardown_own_copy_dispose "$slot" "$copy" || return 1
    TEARDOWN_OWN_RELEASED+=("$copy")
  done
}
