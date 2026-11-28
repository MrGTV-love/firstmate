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
#     own runs in it, and no live process outside this teardown's own is its
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
# no process outside this teardown may run in it or be its live lock launcher,
# and no other active record may name it; the driver then verifies the landing
# again and refuses what it cannot prove. An own copy that is not locked is
# removed as before. An own copy the driver keeps (exit 3, the retained reason)
# is not removed either and nothing in it is changed: "Kept own copies" below
# judges it from the driver's recorded answer and closes the task around it
# (bin/fm-teardown.sh's header owns the rule, docs/agent-control.md the detail).
# A copy locked by Vernant's creation lock is released and removed by Vernant's
# own driver (closeout_pr.py --cleanup-worktree <copy> --execute-cleanup, run
# from the slot with FM_TEARDOWN_VERNANT_PYTHON or <slot>/.venv/bin/python). An
# unlocked copy is removed with a plain non-forced git worktree remove. A lock in
# any other format, a driver refusal, or a copy still registered afterwards
# refuses. Removal deletes the copy's checkout and the allow-listed ignored files
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
# the final project-lock wait, so the driver never runs while the lock is held,
# except when teardown keeps project custody through the return.
#
# Requires bin/fm-task-copy-lib.sh, bin/fm-lock-lib.sh and bin/fm-refuse-lib.sh first,
# and runs inside bin/fm-teardown.sh, whose globals (PROJ, ID, DATA, META,
# STATE, WT, TASK_TMP, FORCE, KIND, LEGACY_RECORD_GIVEN, TEARDOWN_NESTED_COPIES,
# TEARDOWN_RETURN_SLOT, TEARDOWN_PEER_SLOT, TEARDOWN_HELD_SLOT) and functions
# (teardown_landed, pids_with_cwd_under, task_process_identity,
# task_process_identity_matches, task_record_process_signal) it uses.
# bin/fm-copy-sweep.sh also calls teardown_preserve_ignored, with DATA set to its
# data directory and ID to a per-release id, for a copy it proved on its own, and
# teardown_run_closeout for such a copy that is locked.

# One entry per proved copy.
TEARDOWN_FOREIGN_COPIES=()
# Own nested copies teardown_own_locked_copies_release has removed already.
TEARDOWN_OWN_RELEASED=()
# Own nested copies Vernant's closeout driver kept (exit 3 with the retained
# reason) that this teardown closes the task around, untouched (see "Kept own
# copies"), and the facts of the last record read or written.
TEARDOWN_RETAINED=()
TEARDOWN_RETAINED_REASON=cleanup_ignored_payload_archived_tree_retained
TEARDOWN_RETAINED_RECORD=
TEARDOWN_RETAINED_ANSWER=
TEARDOWN_RET_HEAD=
TEARDOWN_RET_STATUS=
TEARDOWN_RET_PAYLOAD=
# The preserve directory teardown_own_preserve chose for the own copy being disposed of.
TEARDOWN_PRESERVE_DIR=
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
TEARDOWN_FOREIGN_HOLDER_FILE=
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
    process-cwd-owner)
      if [ -n "$TEARDOWN_FOREIGN_HOLDER_FILE" ]; then
        printf 'Which task or person owns process %s, which holds %s open in %s? Stop it or tell me it is yours.' "${TEARDOWN_FOREIGN_PID:-unknown}" "$TEARDOWN_FOREIGN_HOLDER_FILE" "$2"
      else
        printf 'Which task or person owns process %s, which is running in %s? Stop it or tell me it is yours.' "${TEARDOWN_FOREIGN_PID:-unknown}" "$2"
      fi ;;
    lock-launcher-owner) printf 'Is launcher %s, named in the creation lock on %s, still running, and who owns it?' "${TEARDOWN_FOREIGN_PID:-unknown}" "$2" ;;
    creation-lock-owner) printf 'Who owns the creation lock on %s, and may it be released?' "$2" ;;
    nonforced-removal) printf 'What retained disposition covers the contents Git still protects in %s? Preserve this copy; no forced removal is authorized.' "$2" ;;
    registered-copy-proven) printf 'Which task and home retain the work in %s, or what verified landing covers it? No discard or forced removal is authorized.' "$2" ;;
    ignored-bytes-preserved) printf "This run was forced or used a legacy record, so no completing command is printed. Once readable source and writable preservation storage are restored, which of the owner's own flags apply when the owner re-runs this teardown?" ;;
    *) printf 'What verified landing or retained ownership covers %s (%s)? Keep this copy until that evidence exists; no discard is authorized.' "$2" "$TEARDOWN_FOREIGN_WHY" ;;
  esac
}

# Sets <var> to the absolute form of <path>, byte-exact (printf -v, never a
# captured copy, which would drop a final newline): the path itself when it is
# absolute, otherwise the folder it names relative to the directory this run
# started in (TEARDOWN_START_PWD; a caller that records none uses its current
# directory). Fails when no absolute form can be made.
teardown_absolute_root() {  # <var> <path>
  local base
  case "$2" in
    '') return 1 ;;
    /*) printf -v "$1" '%s' "$2" ;;
    *)
      base=${TEARDOWN_START_PWD:-}
      if [ -z "$base" ]; then
        # The trailing "." keeps a final newline of the directory through the capture.
        base=$(pwd -P 2>/dev/null && printf .) || return 1
        base=${base%.}
        base=${base%$'\n'}
      fi
      case "$base" in /*) ;; *) return 1 ;; esac
      printf -v "$1" '%s/%s' "${base%/}" "${2#./}" ;;
  esac
}

# Sets <var> to the one canonical spelling of absolute <path> that decides
# whether two roots are the same folder: every empty and "." component dropped,
# so a trailing slash, a repeated slash or a "./" part does not make a
# different folder. It reads nothing, so it works for a folder not made yet.
teardown_canonical_root() {  # <var> <absolute path>
  local rest=$2 part out=''
  while [ -n "$rest" ]; do
    part=${rest%%/*}
    if [ "$part" = "$rest" ]; then rest=''; else rest=${rest#*/}; fi
    case "$part" in ''|.) ;; *) out+=/$part ;; esac
  done
  printf -v "$1" '%s' "${out:-/}"
}

# One event per refused copy/predicate, not another event for the registered-copy
# wrapper that repeats it. The command re-enters the existing proof/preservation
# owner without force, so a forced or legacy-record run, which it could not
# complete, gets a human-only exit instead. A new custody/disposition decision is
# asked explicitly. The command names absolute folders only, each quoted with
# printf %q so every byte of it survives on one line: FM_HOME, and each of the
# state, data and config roots the run used that is a different folder from its
# default under FM_HOME (compared in teardown_canonical_root's spelling), each
# relative one taken relative to the directory the run started in. Run as
# printed, from any directory and a shell that sets none of the overrides, it
# reaches the same folders. A run that cannot make a root absolute gets the
# human-only exit instead, naming that root.
teardown_refuse_copy() {  # <rule> <missing> <copy>
  local command kind=human-only exit_text missing=$2 revision=${FM_FRICTION_REVISION_FILE:-$SCRIPT_DIR/fm-teardown-nested-lib.sh} roots='' why='' piece
  local abs_home abs_state abs_data abs_config key_home key_root root value
  # An unavailable inspection is not a policy judgment. The later custody
  # wrapper repeats this diagnostic without manufacturing a policy event.
  if [ "$1" = inspection-unavailable ]; then
    printf 'error: %s\n' "$(fm_refuse_text "$2")" >&2
    TEARDOWN_REFUSED_COPIES+=("$3")
    return 0
  fi
  exit_text=$(teardown_copy_question "$1" "$3")
  if [ "$1" = ignored-bytes-preserved ] && [ "${FORCE:-}" != --force ] && [ "${LEGACY_RECORD_GIVEN:-0}" != 1 ]; then
    teardown_absolute_root abs_home "$FM_HOME" || { printf -v piece 'the home folder (%q)' "$FM_HOME"; why=$piece; }
    for root in state data config; do
      case "$root" in
        state) value=${STATE:-$FM_HOME/state} ;;
        data) value=${DATA:-$FM_HOME/data} ;;
        config) value=${CONFIG:-$FM_HOME/config} ;;
      esac
      teardown_absolute_root "abs_$root" "$value" || { printf -v piece 'the %s folder (%q)' "$root" "$value"; why="${why:+$why, }$piece"; }
    done
    if [ -n "$why" ]; then
      exit_text="No completing command is printed because $why is relative and the directory this run started in cannot be read, so a command naming it could not reach it from another directory. Once readable source and writable preservation storage are restored, re-run this teardown from the directory it started in."
      missing="$missing Restore readable source and writable preservation storage, then re-run this teardown from the directory it started in."
    else
      kind=machine
      teardown_canonical_root key_home "$abs_home"
      for root in state data config; do
        case "$root" in
          state) value=$abs_state ;;
          data) value=$abs_data ;;
          config) value=$abs_config ;;
        esac
        teardown_canonical_root key_root "$value"
        [ "$key_root" = "${key_home%/}/$root" ] && continue
        printf -v piece ' FM_%s_OVERRIDE=%q' "$(printf '%s' "$root" | tr '[:lower:]' '[:upper:]')" "$value"
        roots+=$piece
      done
      if [ "${TEARDOWN_BY_PATH:-}" = 1 ]; then
        printf -v command 'FM_HOME=%q%s bash %q --copy %q --record-id %q' "$abs_home" "$roots" "$SCRIPT_DIR/fm-teardown.sh" "$TEARDOWN_BY_PATH_COPY" "$ID"
      else
        printf -v command 'FM_HOME=%q%s bash %q %q' "$abs_home" "$roots" "$SCRIPT_DIR/fm-teardown.sh" "$ID"
      fi
      exit_text=$command
      missing="$missing Restore readable source and writable preservation storage, then run the completing command."
    fi
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
# pids are recycled. A start time that cannot be read counts as live. Only a read
# that proves the process absent counts as gone: a ps that failed, was refused or
# said anything but "no such process" leaves the launcher possibly alive
# (fm_task_copy_launcher_state). When the read proves nothing,
# TEARDOWN_LOCK_LAUNCHER_UNPROVED holds the next step for the refusal to print.
# Returns 0 when it may be alive, 1 when it is gone or a recycled pid.
TEARDOWN_LOCK_LAUNCHER_UNPROVED=
teardown_lock_launcher_may_be_live() {  # <pid> <lock-file>
  local pid=$1 lock=$2 age mtime now state=0
  TEARDOWN_LOCK_LAUNCHER_UNPROVED=
  fm_task_copy_launcher_state "$pid" || state=$?
  case "$state" in
    0) ;;
    1) return 1 ;;
    *)
      TEARDOWN_LOCK_LAUNCHER_UNPROVED="; ps could not show that it is gone, so the copy is kept: run this teardown again where ps can answer for pid $pid; end that process only after you confirm pid $pid is the launcher named by the lock (a pid can be reused)"
      return 0
      ;;
  esac
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

# Prints each outermost directory at or under <root> whose name is in the class.
# A symlink is never one, and find does not follow one.
teardown_regenerable_dirs() {  # <root>
  local name args=()
  for name in "${TEARDOWN_REGENERABLE_NAMES[@]}"; do
    args+=(-o -name "$name")
  done
  find "$1" -type d \( "${args[@]:1}" \) -print -prune 2>/dev/null
}

# Prints, relative to <copy>, the class's outermost directories inside its ignored
# entries.
teardown_regenerable_ignored() {  # <copy>
  local copy=$1 listing entry found dir rc=0
  listing=$(mktemp "${TMPDIR:-/tmp}/fm-teardown-ignored.XXXXXX") || return 1
  git -C "$copy" ls-files --others --ignored --exclude-standard --directory -z >"$listing" 2>/dev/null || rc=$?
  if [ "$rc" = 0 ]; then
    while IFS= read -r -d '' entry; do
      found=$(teardown_regenerable_dirs "$copy/${entry%/}") || { rc=1; break; }
      while IFS= read -r dir; do
        [ -z "$dir" ] || printf '%s\n' "${dir#"$copy"/}"
      done <<< "$found"
    done <"$listing"
  fi
  rm -f "$listing"
  return "$rc"
}

# The same outermost directories as teardown_regenerable_dirs, NUL-ended into the file <out>
# (a name may hold a newline). Fails when the listing fails.
teardown_regenerable_dirs_z() {  # <root> <out>
  local name args=()
  for name in "${TEARDOWN_REGENERABLE_NAMES[@]}"; do
    args+=(-o -name "$name")
  done
  find "$1" -type d \( "${args[@]:1}" \) -print0 -prune > "$2" 2>/dev/null
}

# Prints ignored <entry> of <copy> without the class, NUL-ended: whole when it holds none
# of those directories, otherwise split only as far as needed to leave them out.
teardown_entry_without_regenerable_z() {  # <copy> <entry>
  local copy=$1 entry=$2 list dir child found=0 whole=0 rc=0
  list=$(mktemp "${TMPDIR:-/tmp}/fm-regenerable.XXXXXX") || return 1
  teardown_regenerable_dirs_z "$copy/$entry" "$list" || rc=1
  if [ "$rc" = 0 ]; then
    while IFS= read -r -d '' dir; do
      found=1
      [ "$dir" != "$copy/$entry" ] || whole=1
    done < "$list"
  fi
  rm -f "$list"
  [ "$rc" = 0 ] || return 1
  if [ "$found" = 0 ]; then
    printf '%s\0' "$entry"
    return 0
  fi
  [ "$whole" = 0 ] || return 0
  for child in "$copy/$entry"/* "$copy/$entry"/.[!.]* "$copy/$entry"/..?*; do
    { [ -e "$child" ] || [ -L "$child" ]; } || continue
    teardown_entry_without_regenerable_z "$copy" "$entry/${child##*/}" || return 1
  done
}

teardown_print_entry_z() {  # <copy> <entry>
  printf '%s\0' "$2"
}

# Ignored entries no commit holds that must be preserved before removal, NUL-ended so a
# name may hold any byte but NUL (a newline included). Symlinks, caches, virtual
# environments, Firstmate's own hook files, graft's generated output
# (teardown_graft_generated) and regenerable build output are derived machinery and are
# skipped; every other entry is printed for teardown_preserve_ignored to copy. A sweep
# release of a proven copy names a mode, and the sweep's modes leave out the regenerable
# class at any depth: releasable applies that to the list above; all mode starts from every
# ignored entry, so the unlocked sweep can preserve the disposable bytes without widening
# this owner's disposable classification. The retained route names a third mode, retained:
# all mode, except that every ignored entry at or under .claude and .opencode is kept whole,
# a regenerable-looking name (.cache) included, because the driver's archive and the
# acceptance text cover that whole population (the ordinary preservation skips those two
# trees and the retained route preserves and verifies them itself).
teardown_preservable_ignored_z() {  # <copy> [all|releasable|retained]
  local copy=$1 mode=${2:-} listing entry name child rc=0 emit=teardown_entry_without_regenerable_z
  case "$mode" in '') emit=teardown_print_entry_z ;; all|releasable|retained) ;; *) return 1 ;; esac
  listing=$(mktemp "${TMPDIR:-/tmp}/fm-teardown-ignored.XXXXXX") || return 1
  git -C "$copy" ls-files --others --ignored --exclude-standard --directory -z >"$listing" 2>/dev/null || rc=$?
  if [ "$rc" = 0 ]; then
    while IFS= read -r -d '' entry; do
      entry=${entry%/}
      if [ "$mode" = all ] || [ "$mode" = retained ]; then
        if [ "$mode" = retained ]; then
          case "$entry" in
            .claude|.claude/*|.opencode|.opencode/*) teardown_print_entry_z "$copy" "$entry" || { rc=1; break; }; continue ;;
          esac
        fi
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

# The same entries, one per line, for callers that only test whether there are any or
# show them. A name holding a newline shows as two lines: no caller may split it back into
# a path (the preserve, the fingerprint and the retained check read the NUL form).
teardown_preservable_ignored() {  # <copy> [all|releasable]
  local list rc=0
  list=$(mktemp "${TMPDIR:-/tmp}/fm-ignored-lines.XXXXXX") || return 1
  teardown_preservable_ignored_z "$@" > "$list" || rc=$?
  [ "$rc" != 0 ] || tr '\0' '\n' < "$list"
  rm -f "$list"
  return "$rc"
}

# Reads the NUL-ended entries of teardown_preservable_ignored_z <copy> [mode] into the array
# TEARDOWN_IGNORED_LIST, so a path keeps every byte it holds. Fails when the listing fails.
teardown_ignored_list() {  # <copy> [all|releasable]
  local list entry rc=0
  TEARDOWN_IGNORED_LIST=()
  list=$(mktemp "${TMPDIR:-/tmp}/fm-ignored-list.XXXXXX") || return 1
  teardown_preservable_ignored_z "$@" > "$list" || rc=$?
  if [ "$rc" = 0 ]; then
    while IFS= read -r -d '' entry; do
      TEARDOWN_IGNORED_LIST+=("$entry")
    done < "$list"
  fi
  rm -f "$list"
  return "$rc"
}

# Appends "<sha256>  <path>" lines, in sha256sum's form, to <out> for each NUL-ended
# absolute path of <list> (a regular file under <stage>), the path shown relative to
# <stage>. A path holding a backslash or a newline is written as sha256sum writes it: a
# leading backslash on the line and \\ and \n in the name.
teardown_sums_write() {  # <stage> <list> <out>
  perl -e '
    use strict; use warnings; use Digest::SHA;
    my ($stage, $list, $out) = @ARGV; local $/ = "\0";
    open(my $l, "<:raw", $list) or exit 2; my @f = <$l>; chomp @f; close $l;
    open(my $o, ">>:raw", $out) or exit 2;
    for my $f (@f) {
      open(my $fh, "<:raw", $f) or exit 2;
      my $h = Digest::SHA->new(256); $h->addfile($fh); close $fh;
      my $rel = $f; $rel =~ s{^\Q$stage\E/}{};
      my $e = $rel; $e =~ s/\\/\\\\/g; $e =~ s/\n/\\n/g;
      print $o (($e ne $rel ? "\\" : ""), $h->hexdigest, "  ", $e, "\n");
    }
    close $o or exit 2;
  ' "$1" "$2" "$3"
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

# Bundle preservation is separate from delivery, and is deliberately rechecked
# rather than placed in the immutable-HEAD landing cache. fm-teardown.sh's
# header owns the record format and supported creation/recovery commands.
# What a refusal tells the operator to run once the bundle or the captain's call
# exists; the by-path mode names its own command.
TEARDOWN_RETRY_ACTION='retry ordinary teardown'
teardown_bundle_refuse() {  # <predicate> [hint]
  echo "teardown: bundle preservation unavailable: $1." >&2
  [ -z "${2:-}" ] || echo "Create a self-contained external bundle with git -C <copy> bundle create <external-bundle> --all, then record its path, SHA-256 and advertised tips in $DATA/$ID/preservation-bundles.tsv using bin/fm-teardown.sh's header recipe; $TEARDOWN_RETRY_ACTION." >&2
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
  if teardown_removal_root_of "$copy" "$path"; then
    TEARDOWN_BUNDLE_REASON="bundle is inside task $TEARDOWN_REMOVAL_LABEL $TEARDOWN_REMOVAL_ROOT"
    return 1
  fi
}

# Does canonical <path> lie inside a root this teardown of <copy> removes: the
# copy, the task's worktree, its return and enclosing slots, its own nested and
# foreign copies, its tasktmp and launch scratch, or its per-task state folders?
# Sets TEARDOWN_REMOVAL_ROOT and TEARDOWN_REMOVAL_LABEL (copy, scratch or state)
# for the first one found. A copy that is the project itself is not a removal
# target: a missing task copy is proved through its surviving ref store.
TEARDOWN_REMOVAL_ROOT=
TEARDOWN_REMOVAL_LABEL=
teardown_removal_root_of() {  # <copy> <canonical-path>
  local copy=$1 path=$2 root field i
  local roots=() labels=()
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
  if [ -n "${STATE:-}" ]; then
    roots+=("$STATE/$ID.inbox" "$STATE/$ID.git-hooks" "$STATE/.nm-read-cache-$ID" "$STATE/$ID.dsh")
    labels+=(state state state state)
  fi
  for i in "${!roots[@]}"; do
    root=${roots[$i]%/}
    [ -e "$root" ] || continue
    field=$(fm_task_copy_canonical_dir "$root") || field=$root
    case "$path" in "$root"/*|"$field"/*|"$root"|"$field")
      TEARDOWN_REMOVAL_ROOT=$root
      TEARDOWN_REMOVAL_LABEL=${labels[$i]}
      return 0 ;;
    esac
  done
  return 1
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

# The captain's land-or-drop question for commits only a bundle holds. It names
# the copy's unlanded tips apart from the record's advertised tips, since the
# bundle may also advertise tips that are already landed.
teardown_bundle_hold_reason() {  # <bundle> <unlanded-tips> <recorded-tips>
  printf 'Land or drop the unlanded commits of %s, tips %s: they are preserved in bundle %s, whose record lists advertised tips %s; an advertised tip may already be landed.' \
    "$ID" "$2" "$1" "$3"
}

# Prints the id of an open task held for the captain whose hold reason names
# <bundle> and every <tip>. Returns 1 when none does, and 2 when the held rows
# cannot be read completely.
teardown_bundle_captain_call() {  # <bundle> <tip>...
  local listed
  listed=$(fm_backlog_row_list "$DATA" --state held --fields hold_kind,hold_reason 2>/dev/null) || return 2
  printf '%s\n' "$listed" | fm_hold_reason_decode_stream toon | perl -MJSON::PP -e '
    use strict;
    use warnings;
    my ($bundle, @tips) = @ARGV;
    my $json = JSON::PP->new->allow_nonref;
    my (@names, $count, $declared, $match);
    my $parsed = 0;
    while (my $line = <STDIN>) {
      chomp $line;
      if ($line =~ /^count: (\d+)$/) { $count = $1; next; }
      if ($line =~ /^tasks\[(\d+)\]\{([^}]*)\}:$/) { $declared = $1; @names = split /,/, $2; next; }
      if ($line !~ /^  (.*)$/) { @names = (); next; }
      next unless @names;
      my @fields = $1 =~ /("(?:[^"\\]|\\.)*"|[^,]+)/g;
      exit 2 unless @fields == @names;
      $parsed++;
      my %row;
      @row{@names} = map { /^"/ ? $json->decode($_) : $_ } @fields;
      next if ($row{state} // "") eq "done" || ($row{hold_kind} // "") ne "captain";
      my $reason = $row{hold_reason} // "";
      next if index($reason, $bundle) < 0 || grep { index($reason, $_) < 0 } @tips;
      $match //= $row{id};
    }
    exit 2 unless defined $count && $parsed == $count && (!defined $declared || $declared == $parsed);
    exit 1 unless defined $match;
    print "$match\n";
  ' "$@"
}

# The bundle route requires the captain's land-or-drop call to be filed: this
# task's row is held for the captain, and an open captain-held task's reason
# names the bundle and every recorded tip. Teardown never files it. A home whose
# backlog transition does not apply (Orca cleanup recovery or a manual backlog)
# has no row that can hold the call, so the route refuses there, and a closed
# row cannot be held; neither prints a command that could not pass.
teardown_bundle_require_captain_call() {  # <bundle> <unlanded-tips> <recorded-tips>
  local call rc=0 reason held=0 title
  local -a repo=()
  if [ "${TEARDOWN_BACKLOG_APPLIES:-0}" != 1 ]; then
    teardown_bundle_refuse "$1: no backlog row can hold the captain's land-or-drop call in this home"
    return 1
  fi
  [ "${TEARDOWN_BACKLOG_TRANSITION:-close}" != retain ] || held=1
  # shellcheck disable=SC2086 # Recorded tips are full hex object names.
  call=$(teardown_bundle_captain_call "$1" $3) || rc=$?
  if [ "$rc" = 0 ] && [ "$held" = 1 ]; then
    echo "teardown: the captain's land-or-drop call for bundle $1 is held on task $call" >&2
    return 0
  fi
  # A by-path run has no task row of its own, so any open captain-held row that
  # names the bundle and every recorded tip is the call (bin/fm-teardown.sh's
  # header, "By-path teardown"). That is an exception to the held-task rule, so it
  # is granted only after teardown_by_path_exception_clear has judged its harm
  # rows here, at the exception, whatever ran before it.
  if [ "$rc" = 0 ] && [ "${TEARDOWN_BY_PATH:-}" = 1 ]; then
    teardown_by_path_exception_clear "$1" "$2" || return 1
    echo "teardown: the captain's land-or-drop call for bundle $1 is held on task $call" >&2
    return 0
  fi
  if [ "$rc" -ge 2 ]; then
    teardown_bundle_refuse "$1: the captain's held calls cannot be read completely"
    return 1
  fi
  reason=$(teardown_bundle_hold_reason "$1" "$2" "$3")
  title="Land or drop the bundle-preserved commits of $ID"
  if [ "$held" = 1 ]; then
    teardown_bundle_refuse "$1: task $ID is held for the captain on another question, and no open captain-held task's hold reason names the bundle and every recorded tip"
    {
      printf 'File the land-or-drop call as its own task, then %s:' "$TEARDOWN_RETRY_ACTION"
      printf ' %q' bin/fm-captain-hold.sh hold "$ID-bundle" --title "$title" \
        --origin "$ID" --owner captain --reason "$reason" \
        --boundary destructive --if-no 'Keep the copy and bundle; do not discard the commits'
      printf '\n'
    } >&2
  elif fm_backlog_row_probe "$DATA" "$ID"; then
    if [ "${FM_BACKLOG_ROW_STATE%% *}" = "done" ]; then
      teardown_bundle_refuse "$1: task $ID's backlog row is closed, so it cannot hold the captain's land-or-drop call"
      return 1
    fi
    teardown_bundle_refuse "$1: task $ID is not held for the captain's land-or-drop call naming the bundle and every recorded tip"
    {
      printf 'Hold it for the captain, then %s:' "$TEARDOWN_RETRY_ACTION"
      printf ' %q' bin/fm-captain-hold.sh hold "$ID" --owner captain --reason "$reason" \
        --boundary destructive --if-no 'Keep the copy and bundle; do not discard the commits'
      printf '\n'
    } >&2
  elif [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
    [ -z "${PROJ:-}" ] || repo=(--repo "${PROJ##*/}")
    teardown_bundle_refuse "$1: task $ID has no backlog row to hold the captain's land-or-drop call naming the bundle and every recorded tip"
    {
      printf 'File the land-or-drop call as its row, then %s:' "$TEARDOWN_RETRY_ACTION"
      printf ' %q' bin/fm-captain-hold.sh hold "$ID" --title "$title" ${repo[@]+"${repo[@]}"} --owner captain --reason "$reason" \
        --boundary destructive --if-no 'Keep the copy and bundle; do not discard the commits'
      printf '\n'
    } >&2
  else
    teardown_bundle_refuse "$1: task $ID's backlog row cannot be read"
  fi
  return 1
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
  # The stage is made 0600 before the copy, as mktemp makes it, so cp keeps that
  # mode whatever the source's own mode is; the copy is then checked for it.
  if [ -n "${TEARDOWN_RUN_DIR:-}" ]; then
    stage="$TEARDOWN_RUN_DIR/bundle-$hash"
    (umask 077; set -C; : > "$stage") 2>/dev/null || {
      TEARDOWN_BUNDLE_REASON='stored bundle staging file cannot be created'; return 1;
    }
  else
    stage=$(mktemp "$root/.bundle.XXXXXX") || {
      TEARDOWN_BUNDLE_REASON='stored bundle staging file cannot be created'; return 1;
    }
  fi
  if ! cp "$source" "$stage"; then
    TEARDOWN_BUNDLE_REASON='bundle cannot be copied into task data'
  elif ! fm_backlog_file_mode_is_0600 "$stage"; then
    TEARDOWN_BUNDLE_REASON='stored bundle staging file is not mode 0600'
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

# Verifies the recorded bundle (teardown_bundle_record has read the record) against
# <required>, the copy's own unlanded tips one per line: the bundle is a regular
# nonsymlink file whose bytes match the record, passes git bundle verify, advertises
# every required tip and every recorded tip, the record lists every required tip,
# and restores in an isolated repository. Sets TEARDOWN_BUNDLE_SOURCE (the recorded
# path), TEARDOWN_BUNDLE_USE (the file verified: the source, or the stored copy once
# the source is gone), TEARDOWN_BUNDLE_HASH and TEARDOWN_BUNDLE_TIPS from the record,
# and TEARDOWN_BUNDLE_REASON, empty on success and otherwise what failed. Writes
# nothing. The route below and the by-path exception both call it.
teardown_bundle_verify() {  # <copy> <required-tips, one per line>
  local copy=$1 required=$2 bundle hash tips stored heads advertised digest tip
  bundle=$TEARDOWN_BUNDLE_RECORD_PATH
  hash=$TEARDOWN_BUNDLE_RECORD_HASH
  tips=$TEARDOWN_BUNDLE_RECORD_TIPS
  TEARDOWN_BUNDLE_REASON=
  stored="$DATA/$ID/preserved-bundles/$hash.bundle"
  # A completed admission survives deletion of its original source. Never mask
  # changed bytes or a symlink at a source that still exists.
  if [ ! -e "$bundle" ] && [ ! -L "$bundle" ] && [ -f "$stored" ]; then
    bundle=$stored
  fi
  if [[ "$bundle" != /* ]]; then
    TEARDOWN_BUNDLE_REASON='bundle path is not absolute'
  elif [ ! -f "$bundle" ] || [ -L "$bundle" ]; then
    TEARDOWN_BUNDLE_REASON='bundle is not a regular nonsymlink file'
  elif ! digest=$(teardown_ignored_sha256 "$bundle"); then
    TEARDOWN_BUNDLE_REASON='bundle sha256 cannot be read'
  elif [ "$digest" != "$hash" ]; then
    TEARDOWN_BUNDLE_REASON='bundle sha256 does not match record'
  elif ! git -C "$copy" bundle verify "$bundle" >/dev/null 2>&1; then
    TEARDOWN_BUNDLE_REASON='git bundle verify failed'
  elif ! heads=$(git -C "$copy" bundle list-heads "$bundle" 2>/dev/null); then
    TEARDOWN_BUNDLE_REASON='bundle advertised tips cannot be read'
  else
    advertised=$(printf '%s\n' "$heads" | awk '{print $1}' | tr '\n' ' ')
    while IFS= read -r tip; do
      case " $advertised " in *" $tip "*) ;; *)
        TEARDOWN_BUNDLE_REASON="bundle does not list unlanded tip $tip"; break ;;
      esac
      case " $tips " in *" $tip "*) ;; *)
        TEARDOWN_BUNDLE_REASON="record does not list unlanded tip $tip"; break ;;
      esac
    done <<< "$required"
    if [ -z "$TEARDOWN_BUNDLE_REASON" ]; then
      for tip in $tips; do
        case " $advertised " in *" $tip "*) ;; *)
          TEARDOWN_BUNDLE_REASON="recorded tip $tip is not advertised by bundle"; break ;;
        esac
      done
    fi
    if [ -z "$TEARDOWN_BUNDLE_REASON" ] && ! teardown_bundle_restorable "$copy" "$bundle" "$digest" "$tips"; then
      TEARDOWN_BUNDLE_REASON='bundle cannot be restored in an isolated repository'
    fi
  fi
  TEARDOWN_BUNDLE_SOURCE=$TEARDOWN_BUNDLE_RECORD_PATH
  TEARDOWN_BUNDLE_USE=$bundle
  TEARDOWN_BUNDLE_HASH=$hash
  TEARDOWN_BUNDLE_TIPS=$tips
}

# <ref> itself must carry a locally-only commit, or delivery proof is still
# required. Coverage includes only this cleanup's HEADs and deleted branch refs,
# never unrelated unheld branches in the shared repository.
teardown_bundle_preserved() {  # <copy> <ref> [hint]
  local copy=$1 ref=$2 hint=${3:-} record="$DATA/$ID/preservation-bundles.tsv"
  local bundle source hash tips own required side
  TEARDOWN_BUNDLE_ACCEPTED=
  if ! teardown_bundle_attended; then
    if [ -f "$record" ] && [ ! -L "$record" ] \
        && own=$(printf '%s\n' "$ref" | teardown_bundle_tips "$copy") && [ -n "$own" ]; then
      teardown_bundle_refuse 'recorded bundles require attended teardown; unattended cleanup still requires landing'
      echo "From the attended main session, after ending away or quiet mode, $TEARDOWN_RETRY_ACTION; the bundle must pass all preservation proofs there." >&2
    fi
    return 1
  fi
  own=$(printf '%s\n' "$ref" | teardown_bundle_tips "$copy") || {
    teardown_bundle_refuse "copy's unlanded commits cannot be inspected: $copy"; return 1;
  }
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
  teardown_bundle_verify "$copy" "$required"
  bundle=$TEARDOWN_BUNDLE_USE
  source=$TEARDOWN_BUNDLE_SOURCE
  hash=$TEARDOWN_BUNDLE_HASH
  tips=$TEARDOWN_BUNDLE_TIPS
  if [ -z "$TEARDOWN_BUNDLE_REASON" ]; then
    teardown_bundle_require_captain_call "$source" "$(printf '%s' "$required" | paste -sd ' ' -)" "$tips" || return 1
    if teardown_bundle_store "$copy" "$bundle" "$hash"; then
      echo "teardown: preserved unlanded commits in bundle $TEARDOWN_BUNDLE_STORED sha256=$hash tips=$tips (source $source)" >&2
      TEARDOWN_BUNDLE_ACCEPTED=$TEARDOWN_BUNDLE_STORED
      return 0
    fi
  fi
  teardown_bundle_refuse "$bundle: $TEARDOWN_BUNDLE_REASON" "$hint"
}

# The directory teardown_preserve_ignored publishes preserved ignored files in.
teardown_preserve_parent() {
  printf '%s\n' "$DATA/$ID/nested-copy-preserved"
}

# Is the preserve parent safe to publish into for <copy>? It is not a symbolic
# link and not anything but a directory, its physical location (resolved
# through the nearest existing directory, for one mkdir -p will make, so a
# linked data folder is judged where it really is) lies outside every removal
# root of this teardown, and the directory the rename writes into can be
# written. Sets TEARDOWN_PRESERVE_WHY on refusal; writes nothing.
TEARDOWN_PRESERVE_WHY=
teardown_preserve_parent_safe() {  # <copy>
  local root probe rest='' resolved
  root=$(teardown_preserve_parent)
  TEARDOWN_PRESERVE_WHY=
  if [ -L "$root" ] || { [ -e "$root" ] && [ ! -d "$root" ]; }; then
    TEARDOWN_PRESERVE_WHY="preservation directory $root is not a real directory"
    return 1
  fi
  probe=$root
  while [ ! -e "$probe" ] && [ ! -L "$probe" ]; do
    rest="/${probe##*/}$rest"
    probe=${probe%/*}
    [ -n "$probe" ] || probe=/
  done
  if [ ! -d "$probe" ] || [ ! -w "$probe" ] || [ ! -x "$probe" ] \
      || ! resolved=$(fm_task_copy_canonical_dir "$probe" 2>/dev/null); then
    TEARDOWN_PRESERVE_WHY="preservation directory $root cannot be written through $probe"
    return 1
  fi
  if teardown_removal_root_of "$1" "${resolved%/}$rest"; then
    TEARDOWN_PRESERVE_WHY="preservation directory $root resolves inside $TEARDOWN_REMOVAL_LABEL $TEARDOWN_REMOVAL_ROOT, which this teardown removes"
    return 1
  fi
}

# The copies this teardown's release will preserve ignored files from, decided
# at entry so a preserve that would refuse is refused before any protected step:
# every proved foreign copy, and every own nested copy Vernant's creation lock
# holds, when a return or peer slot is released (as teardown_foreign_copy_dispose
# and teardown_own_copy_dispose preserve them, in the same mode). Sets
# TEARDOWN_PRESERVE_COPIES to those that hold ignored files to preserve, and
# requires a safe preserve parent for each (teardown_preserve_parent_safe). A
# clean copy, or one the plain removal takes, adds nothing. Returns 1 with
# TEARDOWN_PRESERVE_WHY set when a listing cannot be made or the parent is not
# safe; writes nothing.
TEARDOWN_PRESERVE_COPIES=()
teardown_preserve_plan() {
  local copy rc entries
  local -a candidates=()
  TEARDOWN_PRESERVE_COPIES=()
  TEARDOWN_PRESERVE_WHY=
  [ -n "${TEARDOWN_RETURN_SLOT:-${TEARDOWN_PEER_SLOT:-}}" ] || return 0
  if [ -n "${TEARDOWN_RETURN_SLOT:-}" ]; then
    candidates+=(${TEARDOWN_FOREIGN_COPIES[@]+"${TEARDOWN_FOREIGN_COPIES[@]}"})
  fi
  for copy in ${TEARDOWN_NESTED_COPIES[@]+"${TEARDOWN_NESTED_COPIES[@]}"}; do
    [ -d "$copy" ] || continue
    rc=0
    teardown_copy_lock_file "$copy" || rc=$?
    [ "$rc" != 0 ] || candidates+=("$copy")
  done
  for copy in ${candidates[@]+"${candidates[@]}"}; do
    if ! entries=$(teardown_preservable_ignored "$copy"); then
      TEARDOWN_PRESERVE_WHY="the ignored files of $copy could not be listed, so what its release must preserve is unknown"
      return 1
    fi
    [ -n "$entries" ] || continue
    teardown_preserve_parent_safe "$copy" || return 1
    TEARDOWN_PRESERVE_COPIES+=("$copy")
  done
}

# Prints, sorted, one line per entry under <dir>: its type, its SHA-256 or link
# target, and its relative path. Two preserved trees are the same exactly when
# these lines are.
teardown_preserve_tree() {  # <dir>
  local entry digest list out
  list=$(mktemp "${TMPDIR:-/tmp}/fm-preserve-tree.XXXXXX") || return 1
  if ! (cd "$1" && find . -mindepth 1 -print0) > "$list"; then
    rm -f "$list"
    return 1
  fi
  out=$(
    while IFS= read -r -d '' entry; do
      if [ -L "$1/$entry" ]; then
        printf 'l %s %s\n' "$(readlink "$1/$entry")" "$entry" || exit 1
      elif [ -d "$1/$entry" ]; then
        printf 'd - %s\n' "$entry"
      elif [ -f "$1/$entry" ]; then
        digest=$(teardown_ignored_sha256 "$1/$entry") || exit 1
        printf 'f %s %s\n' "$digest" "$entry"
      else
        printf 'o - %s\n' "$entry"
      fi
    done < "$list"
  ) || { rm -f "$list"; return 1; }
  rm -f "$list"
  [ -z "$out" ] || printf '%s\n' "$out" | LC_ALL=C sort
}

# Does published preserve <dest> hold exactly what <stage> holds: the same
# copy-path and the same tree of files?
teardown_preserve_same() {  # <stage> <dest>
  local want have
  [ -d "$2" ] && [ ! -L "$2" ] && [ -d "$2/files" ] && [ ! -L "$2/files" ] \
    && [ -f "$2/meta/copy-path" ] && [ ! -L "$2/meta/copy-path" ] || return 1
  cmp -s "$1/meta/copy-path" "$2/meta/copy-path" || return 1
  want=$(teardown_preserve_tree "$1/files") && have=$(teardown_preserve_tree "$2/files") || return 1
  [ "$want" = "$have" ]
}

# Copies every entry teardown_preservable_ignored prints for <copy> in the given
# mode into $DATA/$ID/nested-copy-preserved/<copy-path-sha256>: the bytes under
# files/, and under meta/ the copy's path (copy-path) and each file's SHA-256
# (SHA256SUMS), so a preserved file of any name never meets the metadata. The
# copy is built in a staging directory and published by one rename. An earlier
# preserve is never removed or overwritten: one that already holds the same
# copy-path and files is kept as the preserve, and any other is kept beside a new
# one published under <copy-path-sha256>.<unique suffix>. Returns 1 when
# anything cannot be listed, copied, hashed or published, after removing the one
# staging directory it built, or when the preserve parent is not safe
# (teardown_preserve_parent_safe); the caller then refuses the copy rather than
# removing unpreserved content.
teardown_preserve_ignored() {  # <copy> [all|releasable]
  local copy=$1 root dest stage entries suffix hash entry file digest
  entries=$(teardown_preservable_ignored "$copy" "${2:-}") || return 1
  [ -n "$entries" ] || return 0
  if ! teardown_preserve_parent_safe "$copy"; then
    printf 'error: %s\n' "$(fm_refuse_text "$TEARDOWN_PRESERVE_WHY")" >&2
    return 1
  fi
  hash=$(printf '%s' "$copy" | teardown_ignored_sha256) || return 1
  root=$(teardown_preserve_parent)
  dest="$root/$hash"
  # A teardown stages in its private run directory (bin/fm-teardown.sh's
  # teardown_run_dir_prepare); other callers, such as bin/fm-copy-sweep.sh,
  # stage beside the preserved copies as before.
  if [ -n "${TEARDOWN_RUN_DIR:-}" ]; then
    stage="$TEARDOWN_RUN_DIR/ignored-$hash"
    suffix=${TEARDOWN_RUN_DIR##*.}
  else
    stage="$root/.staging-$hash"
    suffix=$(date -u +%Y%m%dT%H%M%SZ).$$
  fi
  rm -rf "$stage" || return 1
  (
    mkdir -p "$stage/files" "$stage/meta" || exit 1
    printf '%s\n' "$copy" > "$stage/meta/copy-path" || exit 1
    : > "$stage/meta/SHA256SUMS" || exit 1
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      case "$entry" in /*|..|../*|*/..|*/../*) exit 1 ;; esac
      rm -rf "${stage:?}/files/$entry" || exit 1
      mkdir -p "$(dirname "$stage/files/$entry")" || exit 1
      cp -RPp "$copy/$entry" "$stage/files/$entry" || exit 1
    done <<< "$entries"
    while IFS= read -r -d '' file; do
      digest=$(teardown_ignored_sha256 "$file") || exit 1
      printf '%s  %s\n' "$digest" "${file#"$stage/files/"}" >> "$stage/meta/SHA256SUMS" || exit 1
    done < <(find "$stage/files" -type f -print0)
    mkdir -p "$root" || exit 1
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      if teardown_preserve_same "$stage" "$dest"; then
        rm -rf "${stage:?}" || exit 1
        echo "teardown: the ignored files of $(fm_refuse_text "$copy") are already preserved in $dest" >&2
        exit 0
      fi
      dest="$dest.$suffix"
      { [ ! -e "$dest" ] && [ ! -L "$dest" ]; } || exit 1
    fi
    mv "$stage" "$dest" || exit 1
    echo "teardown: preserved ignored files from $(fm_refuse_text "$copy") in $dest" >&2
  ) || {
    rm -rf "$stage"
    return 1
  }
}

# The seconds a read-only walk of the task records may run while this teardown holds the
# shared Treehouse project lock, written to the variable named by <var>:
# FM_TEARDOWN_SCAN_DEADLINE_SECS, read each time, and 600 when it is empty, not a number or 0
# (leading zeros are decimal, not octal). bin/fm-teardown.sh's copy-clearance scan and the
# ownership walk below share it.
teardown_scan_limit_to() {  # <var>
  local _tl_value=${FM_TEARDOWN_SCAN_DEADLINE_SECS:-600}
  case "$_tl_value" in
    ''|*[!0-9]*) _tl_value=600 ;;
    *) _tl_value=$((10#$_tl_value)); [ "$_tl_value" -gt 0 ] || _tl_value=600 ;;
  esac
  printf -v "$1" '%s' "$_tl_value"
}

# Whether this process holds ANY Treehouse project lock. This is the one fact every scan bound keys
# on, and it is derived from the records the lock acquire and release code keeps, not from a
# per-window flag: TREEHOUSE_PROJECT_LOCK_HELD (the teardown's own lock: set by
# teardown_acquire_project_lock, cleared by teardown_release_project_lock and the EXIT trap) and
# DESCENDANT_TREEHOUSE_LOCK_PATHS (the child project locks a forced secondmate teardown takes: each
# is appended right after fm_project_lock_try / teardown_project_lock_wait succeeds, and the array
# is emptied by teardown_release_descendant_project_locks and the EXIT trap). A forced secondmate
# teardown holds only the second kind, with TREEHOUSE_PROJECT_LOCK_HELD still 0. A script that
# sources this library and takes neither record (bin/fm-copy-sweep.sh, bin/fm-merge-prune.sh) holds
# no lock in this sense, so its walks stay unbounded, as before.
teardown_project_lock_held() {
  [ "${TREEHOUSE_PROJECT_LOCK_HELD:-0}" = 1 ] || [ -n "${DESCENDANT_TREEHOUSE_LOCK_PATHS[*]+held}" ]
}

# Bounds a read-only walk of the task records. Every such walk of bin/fm-teardown.sh that can run
# while a Treehouse project lock is held asks teardown_scan_window_to once, before its first record,
# and teardown_scan_deadline_check before each record. While a lock is held (teardown_project_lock_held)
# <end-var> is the SECONDS value the walk must end by; otherwise it is 0 and the walk is unbounded,
# as before.
teardown_scan_window_to() {  # <limit-var> <end-var>
  local _tw_limit=0 _tw_end=0
  if teardown_project_lock_held; then
    teardown_scan_limit_to _tw_limit
    _tw_end=$((SECONDS + _tw_limit))
  fi
  printf -v "$1" '%s' "$_tw_limit"
  printf -v "$2" '%s' "$_tw_end"
}
# Past the end, prints the refusal and ends the teardown with status 1 at once, through the EXIT
# trap that releases the lock, so no later step removes, returns or re-leases anything. The walk
# only reads and signals nothing; steps that ran earlier in the teardown are not undone, and a retry
# is safe.
teardown_scan_deadline_refuse() {  # <limit> <what>
  echo "REFUSED: $2 ran past its ${1}s scan deadline (FM_TEARDOWN_SCAN_DEADLINE_SECS) while holding the project lock, so it stopped before the next step and released the lock; nothing more was changed; retry the teardown" >&2
  exit 1
}
teardown_scan_deadline_check() {  # <end> <limit> <what>
  [ "$1" -le 0 ] || [ "$SECONDS" -lt "$1" ] || teardown_scan_deadline_refuse "$2" "$3"
}

# Does an active record, a running process, or a live lock launcher outside this
# teardown own <copy>? Returns 1 with TEARDOWN_FOREIGN_WHY set when so or when
# that cannot be told.
#
# The walk of the task records is bounded while this teardown holds any project lock (the
# caller's own fact, teardown_project_lock_held, handed to the library as a limit): past
# the deadline, checked before each record, it prints a refusal and ends the teardown with
# status 1 at once, through the EXIT trap that releases the lock, so no later step of the
# window removes, returns or re-leases anything. The walk only reads and signals nothing;
# steps that ran earlier in the teardown are not undone, and a retry is safe. Without the
# lock the walk is unbounded, as before.
teardown_foreign_copy_unowned() {  # <copy>
  local copy=$1 rc=0 pids pid scan_limit=0
  TEARDOWN_OWN_SCANNED=0
  TEARDOWN_FOREIGN_PID=
  TEARDOWN_FOREIGN_HOLDER_FILE=
  ! teardown_project_lock_held || teardown_scan_limit_to scan_limit
  FM_TASK_COPY_SCAN_LIMIT_SECS=$scan_limit
  # shellcheck disable=SC2153 # STATE is bin/fm-teardown.sh's global, not a typo of a local.
  fm_task_copy_other_record "$META" "$STATE" "$copy" || rc=$?
  FM_TASK_COPY_SCAN_LIMIT_SECS=0
  case "$rc" in
    3) teardown_scan_deadline_refuse "$scan_limit" "the ownership walk for foreign copy $(fm_refuse_text "$copy") in task $ID's pool slot" ;;
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
          TEARDOWN_FOREIGN_PID=$pid
          TEARDOWN_FOREIGN_WHY="its creation-lock launcher process $pid may still be running$TEARDOWN_LOCK_LAUNCHER_UNPROVED"
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
  if ! unique=$(teardown_preservable_ignored "$copy"); then
    TEARDOWN_FOREIGN_RULE=inspection-unavailable
    TEARDOWN_FOREIGN_WHY="its ignored files could not be listed"
    return 1
  fi
  if [ -n "$unique" ] && teardown_foreign_copy_hold_applies "$copy"; then
    TEARDOWN_FOREIGN_RULE='copy-ignored-files'
    unique=$(printf '%s\n' "$unique" | LC_ALL=C sort -u | tr '\n' ' ')
    TEARDOWN_FOREIGN_WHY="it holds ignored files that exist nowhere else: $(fm_refuse_text "${unique% }")"
    ! teardown_foreign_copy_holdable "$copy" || TEARDOWN_FOREIGN_HOLDABLE=ignored
    return 1
  fi
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

# Can the release teardown_foreign_copy_dispose runs for each proved foreign copy
# start? teardown_foreign_copy_prove already refuses a lock that is not
# Vernant's and an unreadable lock state; this adds that a Vernant-locked copy's
# closeout driver and interpreter are there and that the driver, asked in plan
# mode, would release it (teardown_closeout_plan_allows). Called at entry only once the route
# will release the foreign copies (not for a held close, which releases none),
# so a release that would refuse on that is refused before any protected step.
# Prints the refusal and returns 1.
teardown_foreign_copies_release_ready() {
  local slot copy rc
  [ -n "${TEARDOWN_RETURN_SLOT:-}" ] && [ "${#TEARDOWN_FOREIGN_COPIES[@]}" -gt 0 ] || return 0
  slot=$(fm_task_copy_canonical_dir "$TEARDOWN_RETURN_SLOT") || return 1
  for copy in "${TEARDOWN_FOREIGN_COPIES[@]}"; do
    rc=0
    teardown_copy_lock_file "$copy" || rc=$?
    [ "$rc" = 0 ] || continue
    if teardown_closeout_ready_in "$slot"; then
      teardown_closeout_plan_allows "$slot" "$copy" && continue
      TEARDOWN_FOREIGN_WHY=$TEARDOWN_CLOSEOUT_PLAN_WHY
    else
      TEARDOWN_FOREIGN_WHY="$TEARDOWN_CLOSEOUT_OUT, so it cannot be released"
    fi
    teardown_refuse_copy inspection-unavailable "foreign copy $copy stays in pool slot $slot: $TEARDOWN_FOREIGN_WHY." "$copy"
    echo "REFUSED: foreign copy $(fm_refuse_text "$copy") in pool slot $(fm_refuse_text "$slot") cannot be released; nothing was removed." >&2
    return 1
  done
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

# Is <bare>, a bare repository found inside <copy>, landed content of the copy's own
# repository? Only when git proves it: at least one file under it is tracked, no
# tracked file under it carries an index flag that hides an edit from git status
# (`git ls-files -v` tags every one H: not assume-unchanged, a lowercase tag, and
# not skip-worktree, S), and git status for that directory (untracked files listed
# one by one, ignored ones too) prints nothing, so every file under it is tracked
# and unmodified. An untracked, ignored, modified or deleted file under it, a
# flagged file, a flag read or status that fails, and a directory git cannot read
# are all "not proved": it counts as another repository.
teardown_copy_bare_repo_landed() {  # <copy> <bare>
  local own=$1 bare=$2 rel tracked flags entry changes
  case "$bare" in "$own"/?*) rel=${bare#"$own"/} ;; *) return 1 ;; esac
  tracked=$(git -C "$own" ls-files -z -- ":(literal)$rel" 2>/dev/null) || return 1
  [ -n "$tracked" ] || return 1
  flags=$(git -C "$own" ls-files -v -- ":(literal)$rel" 2>/dev/null) || return 1
  [ -n "$flags" ] || return 1
  while IFS= read -r entry; do
    case "$entry" in 'H '*) ;; *) return 1 ;; esac
  done <<< "$flags"
  changes=$(git -C "$own" status --porcelain=v1 -z -uall --ignored=traditional -- ":(literal)$rel" 2>/dev/null) || return 1
  [ -z "$changes" ]
}

# Prints, one per line, every Git repository inside <copy> that is not the copy's
# own: a nested clone or a linked worktree of another repository (a .git entry
# whose common directory is not the copy's), and a bare repository (HEAD, objects
# and refs together, which carries no .git entry), under ignored folders such as
# .claude and .opencode too. Not counted: submodules of the copy's own repository,
# linked worktrees of the same repository (registered copies, proved on their own)
# and a bare repository whose every file the copy's own repository tracks and holds
# unmodified, with no index flag hiding an edit (teardown_copy_bare_repo_landed),
# which is landed content. Prints
# nothing else and changes nothing. Returns 0
# when the whole copy was searched, 2 when the copy's own Git directory cannot be
# read, and the failing find's status when a directory could not be searched; the
# repositories found before a failed search are printed anyway. The one scan the
# held close of a task's own nested copies and teardown --copy both use.
teardown_copy_other_repo_dirs() {  # <copy>
  local own=$1 listing hit dir common own_common bare rc status=0
  own_common=$(git -C "$own" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 2
  listing=$(find -P "$own" -mindepth 2 -name .git ! -path "$own/.git/*" -print 2>/dev/null) || status=$?
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    dir=$(dirname "$hit")
    rc=0
    common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || rc=$?
    case "$rc:$common" in
      0:"$own_common"|0:"$own_common"/modules/*|0:"$own_common"/worktrees/*/modules/*) continue ;;
    esac
    printf '%s\n' "$dir"
  done <<< "$listing"
  listing=$(find -P "$own" -mindepth 2 -type d -name objects ! -path "$own/.git/*" -print 2>/dev/null) || status=$?
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    bare=${hit%/objects}
    [ "${bare##*/}" != .git ] || continue
    { [ -f "$bare/HEAD" ] && [ -d "$bare/refs" ]; } || continue
    ! teardown_copy_bare_repo_landed "$own" "$bare" || continue
    printf '%s\n' "$bare"
  done <<< "$listing"
  return "$status"
}

# Does one of the task's own nested copies hold a Git repository that is not the
# task's own, such as a separate clone, a worktree of another project or a bare
# repository that is not landed content? The held close removes that own copy
# with its contents, and no registered-copy list sees such a repository, so its
# commits would be lost with no ref left behind. teardown_copy_other_repo_dirs
# owns what counts. Prints a refusal and returns 1 for the first repository
# found, or when the scan cannot be completed; changes nothing.
teardown_own_nested_other_repos() {
  local own hit dir status
  for own in ${TEARDOWN_NESTED_COPIES[@]+"${TEARDOWN_NESTED_COPIES[@]}"}; do
    [ -d "$own" ] || continue
    if ! git -C "$own" rev-parse --path-format=absolute --git-common-dir >/dev/null 2>&1; then
      teardown_refuse_copy inspection-unavailable "the Git directory of task $ID's nested copy $own cannot be read, so what it holds cannot be proved; nothing was removed." "$own"
      return 1
    fi
    status=0
    hit=$(teardown_copy_other_repo_dirs "$own") || status=$?
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      dir=$hit
      teardown_refuse_copy registered-copy-proven "pool slot ${TEARDOWN_RETURN_SLOT:-$own} would lose Git repository $dir inside task $ID's nested copy $own, which holds work no task record proves landed; its commits would have no ref left; nothing was removed." "$dir"
      return 1
    done <<< "$hit"
    if [ "$status" != 0 ]; then
      teardown_refuse_copy inspection-unavailable "task $ID's nested copy $own could not be scanned for other Git repositories, so what it holds cannot be proved; nothing was removed." "$own"
      return 1
    fi
  done
}

# Whether the record already holds a line for this task, the slot, <copy> and
# <reason> (both as fm_refuse_text renders them): the one test that decides a
# held copy needs no append, shared by the write and by the entry check.
teardown_held_copy_recorded() {  # <slot> <copy> <reason>
  [ -f "$DATA/held-foreign-copies.log" ] && FM_HELD_ID=$ID FM_HELD_SLOT=$1 FM_HELD_COPY=$2 FM_HELD_WHY=$3 awk -F'\t' \
    '$2 == ENVIRON["FM_HELD_ID"] && $3 == ENVIRON["FM_HELD_SLOT"] && $4 == ENVIRON["FM_HELD_COPY"] && $5 == ENVIRON["FM_HELD_WHY"] { f = 1 } END { exit !f }' "$DATA/held-foreign-copies.log" 2>/dev/null
}

# The record rule the write and the entry check share: the record is acceptable
# when it is an existing regular writable file, reached directly or through a
# symlink to an existing regular writable file, or when it does not exist and its
# directory is writable. A dangling symlink is refused, because appending through
# it would create a file at the link target; a directory or another kind of file
# is refused too. This test decides the shape part of that rule; each caller
# decides whether its needed append is writable.
teardown_held_copies_record_shape_ok() {  # <record>
  [ -e "$1" ] || [ -L "$1" ] || return 0
  [ -f "$1" ]
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
  teardown_held_copies_record_shape_ok "$record" || return 1
  for entry in "${TEARDOWN_FOREIGN_HELD[@]}"; do
    copy=$(fm_refuse_text "${entry%%$'\t'*}")
    why=$(fm_refuse_text "${entry#*$'\t'}")
    if teardown_held_copy_recorded "$slot" "$copy" "$why"; then
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

# Runs Vernant's closeout driver on <copy>: it releases its own creation lock
# and removes the copy. With "plan" it omits --execute-cleanup, so the driver
# only says whether it would. TEARDOWN_CLOSEOUT_STDOUT is verdict input;
# TEARDOWN_CLOSEOUT_OUT retains stdout and stderr for display and refusal records.
# An optional capture file belongs to the caller (so a killed plan can clean it).
# Exit 0 means the driver allowed and, unless planning, ran the cleanup.
# Is Vernant's closeout driver for <slot> there, with an interpreter that can
# run it? The one owner of that rule: teardown proves it at entry for every copy
# its release will hand to the driver, and teardown_run_closeout asks it again.
# Sets TEARDOWN_CLOSEOUT_OUT to what is missing.
teardown_closeout_available() {  # <slot>
  local driver=$1/scripts/git-stability/closeout_pr.py py=${FM_TEARDOWN_VERNANT_PYTHON:-$1/.venv/bin/python}
  [ -f "$driver" ] && [ -x "$py" ] && return 0
  TEARDOWN_CLOSEOUT_OUT="Vernant's closeout driver $driver or its interpreter $py is not available"
  return 1
}

# teardown_closeout_available for the canonical path of <slot>, which is the
# directory the release runs the driver from; a slot that cannot be resolved
# is doubt and fails.
teardown_closeout_ready_in() {  # <slot>
  local slot
  if ! slot=$(fm_task_copy_canonical_dir "$1" 2>/dev/null); then
    TEARDOWN_CLOSEOUT_OUT="pool slot $1 cannot be resolved to run Vernant's closeout driver"
    return 1
  fi
  teardown_closeout_available "$slot"
}

teardown_run_closeout() {  # <slot> <copy> [plan] [stdout-capture-file]
  local slot=$1 copy=$2 execute=--execute-cleanup driver py rc=0 capture=${4:-} own_capture=0
  [ "${3:-}" != plan ] || execute=
  TEARDOWN_CLOSEOUT_STDOUT=
  TEARDOWN_CLOSEOUT_OUT=
  driver=$slot/scripts/git-stability/closeout_pr.py
  py=${FM_TEARDOWN_VERNANT_PYTHON:-$slot/.venv/bin/python}
  teardown_closeout_available "$slot" || return 127
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
    { ( cd "$slot" && "$py" "$driver" --cleanup-worktree "$copy" ${execute:+"$execute"} ) | tee "$capture"; } 2>&1 || status=$?
    printf '.'
    exit "$status"
  ) || rc=$?
  TEARDOWN_CLOSEOUT_OUT=${TEARDOWN_CLOSEOUT_OUT%.}
  TEARDOWN_CLOSEOUT_STDOUT=$(cat "$capture" || exit 1; printf '.') || rc=1
  TEARDOWN_CLOSEOUT_STDOUT=${TEARDOWN_CLOSEOUT_STDOUT%.}
  [ "$own_capture" = 0 ] || rm -f -- "$capture"
  return "$rc"
}

# True only when <driver output> carries a real positive verdict: it is exactly
# one JSON document whose top-level "allowed" key is the boolean true. Text that
# merely mentions allowed=true, a bare allowed=true, a false or non-boolean
# value, no verdict, an empty or malformed answer, and more than one document
# are not permission.
teardown_closeout_plan_verdict_allows() {  # <driver output>
  printf '%s' "$1" | jq -s -e 'length == 1 and (.[0] | type == "object" and .allowed == true)' >/dev/null 2>&1
}

# True when the plan's one JSON document reports the driver's retain rule for a
# tree that holds unique ignored files: the driver archives them and then keeps
# the tree, so a release of it can never succeed.
teardown_closeout_plan_verdict_retains_tree() {  # <driver output>
  printf '%s' "$1" | jq -s -e 'length == 1 and (.[0] | type == "object" and .ignored_payload_disposition == "archive_then_retain_tree")' >/dev/null 2>&1
}

# Asks Vernant's closeout driver, in plan mode and at entry, whether it would
# release <copy> from <slot>, so a release it would decline is refused before any
# protected step. A non-zero exit, no answer, an answer that is not one JSON
# document with "allowed": true (teardown_closeout_plan_verdict_allows), and the
# driver's archive-then-retain rule all refuse, with TEARDOWN_CLOSEOUT_PLAN_WHY
# saying why. The release asks the driver again and keeps its own refusal as the
# recheck, since its answer can change during the run. Like the release call it
# has no time bound of its own.
TEARDOWN_CLOSEOUT_PLAN_WHY=
TEARDOWN_CLOSEOUT_PLAN_RC=
teardown_closeout_plan_allows() {  # <slot> <copy>
  local rc=0 said
  TEARDOWN_CLOSEOUT_PLAN_WHY=
  TEARDOWN_CLOSEOUT_PLAN_RC=
  teardown_run_closeout "$1" "$2" plan || rc=$?
  TEARDOWN_CLOSEOUT_PLAN_RC=$rc
  said=$(printf '%s' "$TEARDOWN_CLOSEOUT_OUT" | tr '\n\t' '  ')
  said=${said:0:600}
  if [ "$rc" != 0 ] || ! teardown_closeout_plan_verdict_allows "$TEARDOWN_CLOSEOUT_STDOUT"; then
    TEARDOWN_CLOSEOUT_PLAN_WHY="Vernant's closeout driver would not release it (plan exit $rc): ${said:-no answer}"
    return 1
  fi
  if teardown_closeout_plan_verdict_retains_tree "$TEARDOWN_CLOSEOUT_STDOUT"; then
    TEARDOWN_CLOSEOUT_PLAN_WHY="Vernant's closeout driver would archive its ignored files and keep the tree (ignored_payload_disposition=archive_then_retain_tree): $said"
    return 1
  fi
}

# The entry plan check for an own nested copy Vernant's creation lock holds (Main 2056): as
# teardown_closeout_plan_allows, except that an allowed plan (exit 0, allowed=true) whose
# disposition is archive_then_retain_tree is not a refusal. That answer means the driver will
# archive the copy's unique ignored files and keep the tree: the kept route ("Kept own copies")
# then judges it after the execute, landed and clean, every unique ignored file saved, one
# record, and closes or refuses by name, touching nothing in the copy. Every other plan refusal
# (not allowed, a non-zero exit, no verdict) still refuses at entry, and foreign copies and the
# sweep keep refusing on archive_then_retain_tree.
teardown_own_closeout_plan_allows() {  # <slot> <copy>
  teardown_closeout_plan_allows "$1" "$2" && return 0
  [ "${TEARDOWN_CLOSEOUT_PLAN_RC:-}" = 0 ] \
    && teardown_closeout_plan_verdict_allows "$TEARDOWN_CLOSEOUT_STDOUT" \
    && teardown_closeout_plan_verdict_retains_tree "$TEARDOWN_CLOSEOUT_STDOUT" || return 1
  TEARDOWN_CLOSEOUT_PLAN_WHY=
}

# Saves a refused driver's full output privately, then shows its last 20 lines.
# Prefix and sanitize each line so driver text cannot forge refusal directives.
# Successful closeouts never call this helper and create no durable output file.
teardown_closeout_refusal() {  # <foreign|own nested> <copy> <driver-exit>
  local kind=$1 copy=$2 rc=$3 output_file line
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
}

# The inode and birth time of the copy's own .git file, "<inode>:<birth>", or
# failure when either cannot be read.
copy_identity() {  # <copy>
  local identity
  if [ "$(uname)" = Darwin ]; then
    identity=$(/usr/bin/stat -f %i:%B "$1/.git" 2>/dev/null) || return 1
  else
    identity=$(stat -c %i:%W "$1/.git" 2>/dev/null) || return 1
  fi
  [[ $identity =~ ^[0-9]+:[0-9]+$ ]] || return 1
  printf '%s\n' "$identity"
}

# Is <path> positively gone? Only the kernel's answer ENOENT or ENOTDIR counts. A path that
# exists, or that cannot be looked up (a parent it cannot search, any other error), is not
# gone: an unknown is never answered as absent. Exit 0 gone, 1 present, 2 unknown.
path_positively_gone() {  # <path>
  perl -e 'exit(lstat($ARGV[0]) ? 1 : (($!{ENOENT} || $!{ENOTDIR}) ? 0 : 2))' -- "$1"
}

# Kept own copies. When Vernant's closeout driver keeps an own nested copy (exit 3 with
# cleanup_ignored_payload_archived_tree_retained: it writes one more archive of the copy's
# unique ignored files and keeps the tree on every --execute-cleanup call), teardown runs no
# destructive step on that copy: no removal, reset, checkout, signal or lock release. It only
# (a) proves the copy landed and clean (teardown_retained_copy_proved), (b) proves every
# unique ignored file saved (teardown_retained_saved), (c) writes one record naming the kept
# copy, the driver's answer and why (teardown_retained_write), and (d) closes the task when
# (a) and (b) hold, refusing with the named reason otherwise (teardown_retained_judge).
# Before the driver is asked, every own locked copy's selected ignored files are preserved in
# the task's data folder (teardown_own_preserve, never over an earlier preserve), and the
# preserve must still hold the copy's bytes right before the call and, on a release, right
# after it; once the driver keeps the copy, the rest of its payload and every path the driver
# names are copied in (teardown_own_preserve_widen). A refusal because
# the copy's record cannot be written leaves a refusal record (teardown_retained_refused_write),
# and a completed close marks the record (teardown_retained_mark_closed), so a retry of the
# closed task is told so (teardown_retained_closed_note).

# The one record of a copy the closeout driver kept: data/copy-sweep/retained/
# <sha256 of the copy path>. bin/fm-copy-sweep.sh writes its own receipt there before an
# execute and holds the copy while one applies; teardown_retained_write writes the
# complete form (the same first four lines, then key=value lines) as soon as the driver
# keeps an own copy, and teardown_retained_matches reads it.
teardown_retained_receipt() {  # <data-dir> <copy>
  local hash
  hash=$(printf '%s' "$2" | teardown_ignored_sha256) || return 1
  printf '%s/copy-sweep/retained/%s\n' "$1" "$hash"
}

# Prints every value of key=<value> lines after the record's first three lines.
teardown_retained_fields() {  # <record> <key>
  awk -v k="$2" 'NR > 3 && index($0, k "=") == 1 { print substr($0, length(k) + 2) }' "$1"
}

# Writes to <list> the NUL-separated "./<path>" of every file, symlink and FIFO
# under the given <entry>... of <root> (a socket holds no bytes and is skipped).
# Fails when any cannot be listed.
teardown_retained_files() {  # <root> <list> <entry>...
  local root=$1 list=$2 entry
  shift 2
  : > "$list" || return 1
  for entry in "$@"; do
    if [ -d "$root/$entry" ] && [ ! -L "$root/$entry" ]; then
      (cd "$root" && find -P "./$entry" ! -type d ! -type s -print0) >> "$list" 2>/dev/null || return 1
    else
      printf './%s\0' "$entry" >> "$list" || return 1
    fi
  done
}

# teardown_retained_digest <root>: reads the NUL-separated "./<path>" list on stdin and
# prints one SHA-256 over, for each path in byte order, its type (F file, L symlink, P
# FIFO), the length and bytes of the path, and the file's own SHA-256 or the length and
# bytes of the link target. Paths and link targets keep every byte (tabs, newlines).
teardown_retained_digest() {  # <root>
  perl -e '
    use strict; use warnings; use Digest::SHA;
    my $root = shift; local $/ = "\0";
    my @p = <STDIN>; chomp @p;
    my $d = Digest::SHA->new(256);
    for my $p (sort @p) {
      my $rel = $p; $rel =~ s{^\./}{};
      my $f = "$root/$rel";
      if (-l $f) { my $t = readlink $f; defined $t or exit 2; $d->add("L", length($rel), ":", $rel, "\0", length($t), ":", $t, "\0"); }
      elsif (-f $f) { open(my $fh, "<:raw", $f) or exit 2; my $h = Digest::SHA->new(256); $h->addfile($fh); close $fh; $d->add("F", length($rel), ":", $rel, "\0", $h->hexdigest, "\0"); }
      elsif (-p $f) { $d->add("P", length($rel), ":", $rel, "\0"); }
      else { exit 2 }
    }
    print $d->hexdigest, "\n";
  ' "$1"
}

# One SHA-256 over every file, symlink and FIFO in <copy>'s ignored entries other
# than the regenerable class (retained mode of teardown_preservable_ignored), through
# teardown_retained_digest. Fails when any cannot be listed or read.
teardown_retained_payload() {  # <copy>
  local copy=$1 work rc=0
  local -a named=()
  teardown_ignored_list "$copy" retained || return 1
  named=(${TEARDOWN_IGNORED_LIST[@]+"${TEARDOWN_IGNORED_LIST[@]}"})
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-retained-payload.XXXXXX") || return 1
  if [ "${#named[@]}" -gt 0 ]; then
    teardown_retained_files "$copy" "$work/all" "${named[@]}" || rc=1
  else
    : > "$work/all"
  fi
  if [ "$rc" = 0 ]; then
    teardown_retained_digest "$copy" < "$work/all" || rc=1
  fi
  rm -rf "$work"
  return "$rc"
}

# Sets TEARDOWN_RET_HEAD, TEARDOWN_RET_STATUS (the SHA-256 of the copy's complete
# porcelain status) and TEARDOWN_RET_PAYLOAD: what a record must still match for the
# driver's recorded answer to apply. Fails when any cannot be read.
teardown_retained_snapshot() {  # <copy>
  local copy=$1 status
  TEARDOWN_RET_HEAD=
  TEARDOWN_RET_STATUS=
  TEARDOWN_RET_PAYLOAD=
  TEARDOWN_RET_HEAD=$(git -C "$copy" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || return 1
  status=$(git -C "$copy" status --porcelain=v1 --untracked-files=all --ignore-submodules=none 2>/dev/null) || return 1
  TEARDOWN_RET_STATUS=$(printf '%s\n' "$status" | teardown_ignored_sha256) || return 1
  TEARDOWN_RET_PAYLOAD=$(teardown_retained_payload "$copy") || return 1
}

# The preserve of an own copy Vernant's creation lock holds (teardown_own_preserve), in
# data/<task>/nested-copy-preserved/. Before the driver is asked, on every route, it holds what
# teardown_preserve_ignored's own selection holds, copied the same way. Once the driver keeps
# the copy, every other ignored entry of the payload fingerprint's population (all but the
# regenerable class, the .claude and .opencode trees whole, symlinks included) and every path
# the driver names are copied in too (teardown_own_preserve_widen), never over a byte the
# preserve holds. teardown_own_preserve_list writes the selected or the wide population to
# <out> as the sorted, unique, NUL-separated "./<path>" of every file, symlink and FIFO in it
# (a socket and an empty directory hold no bytes). Fails when any cannot be listed.
teardown_own_preserve_list() {  # <copy> <out> <selected|wide> [named entry...]
  local copy=$1 out=$2 mode=$3 rc=0
  local -a entries=()
  shift 3
  teardown_ignored_list "$copy" || return 1
  entries=(${TEARDOWN_IGNORED_LIST[@]+"${TEARDOWN_IGNORED_LIST[@]}"})
  if [ "$mode" = wide ]; then
    teardown_ignored_list "$copy" retained || return 1
    entries+=(${TEARDOWN_IGNORED_LIST[@]+"${TEARDOWN_IGNORED_LIST[@]}"} "$@")
  fi
  if [ "${#entries[@]}" = 0 ]; then
    : > "$out"
    return
  fi
  teardown_retained_files "$copy" "$out.all" "${entries[@]}" || { rm -f "$out.all"; return 1; }
  LC_ALL=C sort -z -u "$out.all" > "$out" || rc=1
  rm -f "$out.all"
  return "$rc"
}

# The folder of preserve <dir> that holds the preserved files: <dir>/files, laid out as
# teardown_preserve_ignored lays it out. The preserve's own two files are <dir>/meta/copy-path
# and <dir>/meta/SHA256SUMS, so a preserved file of any name never meets them.
teardown_own_preserve_root() {  # <dir> [copy]
  printf '%s/files\n' "$1"
}

# Does preserve <dir> hold every file, symlink and FIFO of <list> as <copy> has it now: a
# regular file with the same SHA-256, a symlink with the same target bytes (trailing newlines
# included), a FIFO as a FIFO, each reached through real directories of the preserve (a
# symlink above it would let bytes elsewhere stand for the preserve)? Exit 0 held, 1 not held
# (a path the copy no longer has included), 2 when the copy could not be read.
teardown_own_preserve_holds() {  # <copy> <dir> <list>
  local root
  root=$(teardown_own_preserve_root "$2" "$1") || return 2
  { [ -d "$root" ] && [ ! -L "$root" ]; } || return 1
  perl -e '
    use strict; use warnings; use Digest::SHA;
    my ($copy, $root) = @ARGV; local $/ = "\0";
    sub sum { my $f = shift; open(my $fh, "<:raw", $f) or return undef; my $h = Digest::SHA->new(256); $h->addfile($fh); close $fh; return $h->hexdigest }
    sub real_dirs { my ($r, $rel) = @_; my @c = split m{/}, $rel; pop @c; my $q = $r; for my $x (@c) { $q .= "/$x"; return 0 if -l $q || !-d _ } return 1 }
    my @p = <STDIN>; chomp @p;
    for my $p (@p) {
      my $rel = $p; $rel =~ s{^\./}{};
      my ($s, $d) = ("$copy/$rel", "$root/$rel");
      real_dirs($root, $rel) or exit 1;
      if (-l $s) { my $t = readlink $s; defined $t or exit 2; -l $d or exit 1; my $u = readlink $d; (defined $u && $u eq $t) or exit 1 }
      elsif (-f $s) { my $a = sum($s); defined $a or exit 2; (!-l $d && -f $d) or exit 1; my $b = sum($d); (defined $b && $a eq $b) or exit 1 }
      elsif (-p $s) { (!-l $d && -p $d) or exit 1 }
      elsif (!lstat($s)) { exit 1 }
      else { exit 2 }
    }
    exit 0;
  ' "$1" "$root" < "$3"
}

# Writes to <out> the sorted, unique, NUL-separated "./<path>" list that preserve <dir> must hold
# for <copy> now: the selected population, and every file, symlink and FIFO <dir> already holds
# that the copy still has (what an earlier run copied in), so an earlier preserve is kept only
# when it still agrees with the copy byte for byte. Fails when any cannot be listed.
teardown_own_preserve_current() {  # <copy> <dir> <out>
  local copy=$1 dir=$2 out=$3 root rc=0
  teardown_own_preserve_list "$copy" "$out.sel" selected || return 1
  root=$(teardown_own_preserve_root "$dir" "$copy") || { rm -f "$out.sel"; return 1; }
  if [ -d "$root" ] && [ ! -L "$root" ]; then
    (cd "$root" && find -P . ! -type d -print0) 2>/dev/null > "$out.held" || rc=1
  else
    : > "$out.held"
  fi
  if [ "$rc" = 0 ]; then
    perl -e '
      my ($copy) = @ARGV; local $/ = "\0";
      while (<STDIN>) { chomp; my $rel = $_; $rel =~ s{^\./}{}; print "$_\0" if lstat("$copy/$rel") }
    ' "$copy" < "$out.held" | cat "$out.sel" - | LC_ALL=C sort -z -u > "$out" || rc=1
  fi
  rm -f "$out.sel" "$out.held"
  return "$rc"
}

# Writes <dir>/meta/SHA256SUMS anew in sha256sum's form for every regular file under
# <dir>/files, each path relative to <dir>/files. Only a preserve being built, before it is
# renamed into place, is written this way.
teardown_own_preserve_sums() {  # <copy> <dir>
  local copy=$1 dir=$2 root rc=0
  root=$(teardown_own_preserve_root "$dir" "$copy") || return 1
  find "$root" -type f -print0 > "$dir.files" || rc=1
  if [ "$rc" = 0 ]; then
    : > "$dir/meta/SHA256SUMS" && teardown_sums_write "$root" "$dir.files" "$dir/meta/SHA256SUMS" || rc=1
  fi
  rm -f "$dir.files"
  return "$rc"
}

# Builds the preserve <dir> (which must not exist) of <copy>'s selected entries, copied as
# teardown_preserve_ignored copies them, with meta/copy-path and meta/SHA256SUMS, in a staging
# directory (the teardown's private run directory when it is on the same filesystem, otherwise
# beside it); checks
# it byte for byte against the copy and only then renames it into place.
# Returns 1, leaving nothing at <dir>, when anything cannot be copied, hashed or checked (a copy
# that changed meanwhile included).
teardown_own_preserve_build() {  # <copy> <dir>
  local copy=$1 dir=$2 stage root entry device rc=0
  # A teardown stages in its private run directory (bin/fm-teardown.sh's
  # teardown_run_dir_prepare) when that is on the preserve parent's filesystem, so the
  # rename stays on one filesystem; otherwise it stages beside the preserve.
  if [ -n "${TEARDOWN_RUN_DIR:-}" ] && [ -n "${TEARDOWN_RUN_DEVICE:-}" ] \
      && device=$(teardown_device_of "${dir%/*}") && [ "$device" = "$TEARDOWN_RUN_DEVICE" ]; then
    stage="$TEARDOWN_RUN_DIR/ignored-own-${dir##*/}"
  else
    stage="${dir%/*}/.staging-own-${dir##*/}"
  fi
  rm -rf "$stage" || return 1
  teardown_ignored_list "$copy" || return 1
  root=$(teardown_own_preserve_root "$stage" "$copy") || return 1
  (
    mkdir -p "$root" "$stage/meta" || exit 1
    printf '%s\n' "$copy" > "$stage/meta/copy-path" || exit 1
    for entry in ${TEARDOWN_IGNORED_LIST[@]+"${TEARDOWN_IGNORED_LIST[@]}"}; do
      case "$entry" in /*|..|../*|*/..|*/../*) exit 1 ;; esac
      case "$entry" in */*) mkdir -p "$root/${entry%/*}" || exit 1 ;; esac
      cp -RPp "$copy/$entry" "$root/$entry" || exit 1
    done
    teardown_own_preserve_sums "$copy" "$stage" || exit 1
    teardown_own_preserve_list "$copy" "$stage.list" selected || exit 1
  ) || rc=1
  if [ "$rc" = 0 ] && teardown_own_preserve_holds "$copy" "$stage" "$stage.list" \
      && perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' -- "$stage" "$dir"; then
    rm -f "$stage.list"
    return 0
  fi
  rm -rf "$stage" "$stage.list"
  return 1
}

# Copies into preserve <dir> every file, symlink and FIFO of <list> that it does not have,
# never over anything it has, and appends a SHA256SUMS line for each regular file it copied in;
# no earlier line of SHA256SUMS changes. Fails when one cannot be copied.
teardown_own_preserve_adopt() {  # <copy> <dir> <list>
  local copy=$1 dir=$2 list=$3 root rc=0
  root=$(teardown_own_preserve_root "$dir" "$copy") || return 1
  { [ -d "$root" ] && [ ! -L "$root" ]; } || mkdir "$root" || return 1
  perl -e 'my $r = shift; local $/ = "\0"; while (<STDIN>) { chomp; my $rel = $_; $rel =~ s{^\./}{}; print "$_\0" unless lstat("$r/$rel") }' "$root" < "$list" > "$list.missing" || rc=1
  if [ "$rc" = 0 ] && [ -s "$list.missing" ]; then
    (set -o pipefail; cd "$copy" && COPYFILE_DISABLE=1 tar -cf - --null -T "$list.missing" | tar -xpkf - -C "$root") || rc=1
    if [ "$rc" = 0 ]; then
      perl -e 'my $r = shift; local $/ = "\0"; while (<STDIN>) { chomp; my $rel = $_; $rel =~ s{^\./}{}; my $f = "$r/$rel"; print "$f\0" if -f $f && !-l $f }' "$root" < "$list.missing" > "$list.abs" \
        && teardown_sums_write "$root" "$list.abs" "$dir/meta/SHA256SUMS" || rc=1
    fi
  fi
  rm -f "$list.missing" "$list.abs"
  return "$rc"
}

# Preserves the selected ignored files of own nested <copy> before the driver is asked and sets
# TEARDOWN_PRESERVE_DIR to the directory that holds them. An earlier preserve is never rebuilt,
# overwritten or removed: the first directory, or one beside it, that still agrees with the copy
# (teardown_own_preserve_current) is kept as it is; otherwise the copy is preserved in the next
# free name (teardown_own_preserve_dir_new). Leaves TEARDOWN_PRESERVE_DIR empty when the copy
# has no selected file and no earlier preserve agrees with it. Returns 1 when the copy cannot be listed, copied or checked, or a
# preserve cannot be made to hold it.
teardown_own_preserve() {  # <copy>
  local copy=$1 hash base cand dir payload work rc=0
  TEARDOWN_PRESERVE_DIR=
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-own-preserve.XXXXXX") || return 1
  teardown_own_preserve_list "$copy" "$work/list" selected || { rm -rf "$work"; return 1; }
  hash=$(printf '%s' "$copy" | teardown_ignored_sha256) || { rm -rf "$work"; return 1; }
  base="$(teardown_preserve_parent)/$hash"
  # The preserve parent must be a real directory outside what this teardown removes
  # (teardown_preserve_parent_safe), before anything is read from or written into it.
  if [ -s "$work/list" ] && ! teardown_preserve_parent_safe "$copy"; then
    rm -rf "$work"
    printf 'error: %s\n' "$(fm_refuse_text "$TEARDOWN_PRESERVE_WHY")" >&2
    return 1
  fi
  for cand in "$base" "$base".*; do
    { [ -d "$cand" ] && [ ! -L "$cand" ]; } || continue
    if teardown_own_preserve_current "$copy" "$cand" "$work/current" \
        && teardown_own_preserve_holds "$copy" "$cand" "$work/current"; then
      rm -rf "$work"
      TEARDOWN_PRESERVE_DIR=$cand
      echo "teardown: preserved ignored files from $(fm_refuse_text "$copy") in $cand (an earlier preserve that already holds them; nothing in it was rebuilt)" >&2
      return 0
    fi
  done
  # Nothing selected and no earlier preserve that agrees with the copy: none is made yet (a kept
  # copy gets one when its payload is copied in, teardown_own_preserve_widen).
  if [ ! -s "$work/list" ]; then
    rm -rf "$work"
    return 0
  fi
  teardown_own_preserve_dir_new "$copy" || { rm -rf "$work"; return 1; }
  dir=$TEARDOWN_PRESERVE_DIR
  TEARDOWN_PRESERVE_DIR=
  { mkdir -p "${dir%/*}" && teardown_own_preserve_build "$copy" "$dir"; } || rc=1
  rm -rf "$work"
  [ "$rc" = 0 ] || return 1
  TEARDOWN_PRESERVE_DIR=$dir
  echo "teardown: preserved ignored files from $(fm_refuse_text "$copy") in $dir" >&2
}

# Sets TEARDOWN_PRESERVE_DIR to the first free name of a new preserve of <copy>, in the order
# <sha256 of the copy path>, <sha256>.<first 16 characters of the copy's payload fingerprint>,
# then <sha256>.<those 16 characters>.<n> for n = 2, 3, ...; an existing name is never reused.
teardown_own_preserve_dir_new() {  # <copy>
  local base payload n=2
  base="$(teardown_preserve_parent)/$(printf '%s' "$1" | teardown_ignored_sha256)" || return 1
  if [ ! -e "$base" ] && [ ! -L "$base" ]; then
    TEARDOWN_PRESERVE_DIR=$base
    return 0
  fi
  payload=$(teardown_retained_payload "$1") || return 1
  TEARDOWN_PRESERVE_DIR=$base.${payload:0:16}
  while [ -e "$TEARDOWN_PRESERVE_DIR" ] || [ -L "$TEARDOWN_PRESERVE_DIR" ]; do
    TEARDOWN_PRESERVE_DIR=$base.${payload:0:16}.$n
    n=$((n + 1))
  done
}

# The kept route's part of (b): the preserve chosen before the driver was asked must still agree
# with the copy byte for byte (teardown_own_preserve_current); then every ignored file of the
# wide population and every <named> path is copied in where the preserve lacks it, never over a
# byte it holds, and the preserve must then hold the whole of it. A copy with no selected file
# gets its preserve here. Returns 1 when any of it fails.
teardown_own_preserve_widen() {  # <copy> [named entry...]
  local copy=$1 dir work rc=0
  shift
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-own-widen.XXXXXX") || return 1
  dir=${TEARDOWN_PRESERVE_DIR:-}
  if [ -n "$dir" ]; then
    { teardown_own_preserve_current "$copy" "$dir" "$work/current" \
        && teardown_own_preserve_holds "$copy" "$dir" "$work/current"; } || rc=1
  fi
  [ "$rc" != 0 ] || teardown_own_preserve_list "$copy" "$work/wide" wide "$@" || rc=1
  if [ "$rc" = 0 ] && [ -s "$work/wide" ] && ! teardown_preserve_parent_safe "$copy"; then
    printf 'error: %s\n' "$(fm_refuse_text "$TEARDOWN_PRESERVE_WHY")" >&2
    rc=1
  fi
  if [ "$rc" = 0 ] && [ -s "$work/wide" ] && [ -z "$dir" ]; then
    { teardown_own_preserve_dir_new "$copy" && dir=$TEARDOWN_PRESERVE_DIR \
        && mkdir -p "${dir%/*}" && teardown_own_preserve_build "$copy" "$dir"; } || rc=1
    [ "$rc" = 0 ] && TEARDOWN_PRESERVE_DIR=$dir || TEARDOWN_PRESERVE_DIR=
  fi
  if [ "$rc" = 0 ] && [ -s "$work/wide" ]; then
    { teardown_own_preserve_adopt "$copy" "$dir" "$work/wide" && teardown_own_preserve_holds "$copy" "$dir" "$work/wide"; } || rc=1
  fi
  rm -rf "$work"
  return "$rc"
}

# Can the record of <copy> be written? Asked before the driver, so an answer that could not
# be recorded is never asked for (each ask writes one more archive).
teardown_retained_record_writable() {  # <copy>
  local rec tmp
  rec=$(teardown_retained_receipt "$DATA" "$1") || return 1
  mkdir -p "${rec%/*}" 2>/dev/null || return 1
  tmp=$(mktemp "${rec%/*}/.probe.XXXXXX" 2>/dev/null) || return 1
  rm -f "$tmp"
}

# The refusal record of own nested <copy>: data/<task>/closeout-refused/<sha256 of the copy
# path>. It is written when the close refuses because the copy's one record
# (teardown_retained_receipt) cannot be written: before the driver, when its folder does not
# take a new file (the driver is then not asked), and after the driver kept the copy, when
# writing it failed (the record then also holds the driver's answer). It names the copy, its
# identity, creation-lock hash, HEAD, status and payload fingerprints, the cause and the time,
# so the refusal is durable; a run that writes the copy's one record, or releases the copy,
# deletes it. While the record still cannot be written, every retry refuses before the driver
# (teardown_retained_record_writable), so no further archive is written.
teardown_retained_refused_path() {  # <copy>
  local hash
  hash=$(printf '%s' "$1" | teardown_ignored_sha256) || return 1
  printf '%s/%s/closeout-refused/%s\n' "$DATA" "$ID" "$hash"
}

# Can the refusal record of <copy> be written? Asked before the driver with the record's own
# probe: an answer neither record can hold is never asked for.
teardown_retained_refused_writable() {  # <copy>
  local rec tmp
  rec=$(teardown_retained_refused_path "$1") || return 1
  mkdir -p "${rec%/*}" 2>/dev/null || return 1
  tmp=$(mktemp "${rec%/*}/.probe.XXXXXX" 2>/dev/null) || return 1
  rm -f "$tmp"
}

# Writes the refusal record of <copy> atomically, from the last teardown_retained_snapshot,
# naming <cause> and, when given, the driver's <answer> (base64, so any byte survives). A later
# refusal of the same unchanged copy (the same lock, identity, HEAD, status and payload) keeps
# the answer an earlier refusal recorded.
teardown_retained_refused_write() {  # <copy> <lock-sha256> <identity> <cause> [answer]
  local rec tmp answer=
  rec=$(teardown_retained_refused_path "$1") || return 1
  if [ -n "${5:-}" ]; then
    answer=$(printf '%s' "$5" | perl -MMIME::Base64 -0777 -ne 'print encode_base64($_, "")') || return 1
  elif [ -f "$rec" ] && [ ! -L "$rec" ] \
      && [ "$(sed -n 1,3p "$rec" 2>/dev/null)" = "$(printf 'lock-sha256=%s\ncopy=%s\nidentity=%s' "$2" "$1" "$3")" ] \
      && [ "$(teardown_retained_fields "$rec" head) $(teardown_retained_fields "$rec" status-sha256) $(teardown_retained_fields "$rec" payload-sha256)" \
           = "$TEARDOWN_RET_HEAD $TEARDOWN_RET_STATUS $TEARDOWN_RET_PAYLOAD" ]; then
    answer=$(teardown_retained_fields "$rec" answer-base64)
  fi
  mkdir -p "${rec%/*}" || return 1
  tmp=$(mktemp "${rec%/*}/.refused.XXXXXX") || return 1
  {
    printf 'lock-sha256=%s\ncopy=%s\nidentity=%s\n' "$2" "$1" "$3"
    printf 'teardown of task %s refused to close around this own nested copy because %s; the copy is not changed, and Vernant'"'"'s closeout driver is not asked again while the cause holds\n' "$ID" "$4"
    printf 'task=%s\ncause=%s\nrefused-at=%s\nhead=%s\nstatus-sha256=%s\npayload-sha256=%s\n' \
      "$ID" "$4" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TEARDOWN_RET_HEAD" "$TEARDOWN_RET_STATUS" "$TEARDOWN_RET_PAYLOAD"
    [ -z "$answer" ] || printf 'answer-base64=%s\n' "$answer"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -- "$tmp" "$rec" || { rm -f "$tmp"; return 1; }
}

# Deletes the refusal record of <copy>, once its cause has gone.
teardown_retained_refused_clear() {  # <copy>
  local rec
  rec=$(teardown_retained_refused_path "$1") || return 0
  rm -f -- "$rec"
}

# Rewrites the preserve= line of <record> to <dir>, atomically: a later run that preserved
# the unchanged copy in a new directory beside an earlier one (which no longer held its bytes)
# names the directory that holds them.
teardown_retained_preserve_note() {  # <record> <dir>
  local rec=$1 tmp
  [ "$(teardown_retained_fields "$rec" preserve)" != "$2" ] || return 0
  tmp=$(mktemp "${rec%/*}/.retained.XXXXXX") || return 1
  awk -v dir="$2" 'NR > 3 && index($0, "preserve=") == 1 { print "preserve=" dir; next } { print }' "$rec" > "$tmp" \
    || { rm -f "$tmp"; return 1; }
  mv -- "$tmp" "$rec" || { rm -f "$tmp"; return 1; }
}

# Marks the record of every copy this teardown kept with task-closed=<id>, once the close is
# complete (bin/fm-teardown.sh calls it after the task record and the backlog item have their
# final state), so a retry of the closed task is told so (teardown_retained_closed_note). A mark
# that cannot be written leaves the close complete; the retry then reports the missing record.
teardown_retained_mark_closed() {
  local copy rec tmp
  for copy in ${TEARDOWN_RETAINED[@]+"${TEARDOWN_RETAINED[@]}"}; do
    tmp=
    rec=$(teardown_retained_receipt "$DATA" "$copy") || continue
    { [ -f "$rec" ] && [ "$(teardown_retained_fields "$rec" task)" = "$ID" ]; } || continue
    if ! { tmp=$(mktemp "${rec%/*}/.retained.XXXXXX") \
        && awk -v id="$ID" 'NR > 3 && index($0, "task-closed=") == 1 { next } { print } END { print "task-closed=" id }' "$rec" > "$tmp" \
        && mv -- "$tmp" "$rec"; }; then
      rm -f "${tmp:-}"
      echo "warning: the record $(fm_refuse_text "$rec") of kept own nested copy $(fm_refuse_text "$copy") could not be marked closed; a retry of task $ID reports its record missing." >&2
    fi
  done
}

# Prints the first record that the completed close of task <id> marked (task-closed=<id>) and
# succeeds; fails when none does. A record that only names the task was written for an answer
# whose close may have refused afterwards, so it proves no close.
teardown_retained_closed_by() {  # <data-dir> <task-id>
  local rec
  for rec in "$1"/copy-sweep/retained/*; do
    { [ -f "$rec" ] && [ ! -L "$rec" ] && [ -r "$rec" ]; } || continue
    [ "$(teardown_retained_fields "$rec" task)" = "$2" ] || continue
    [ "$(teardown_retained_fields "$rec" task-closed)" = "$2" ] || continue
    printf '%s\n' "$rec"
    return 0
  done
  return 1
}

# A retry of a task that closed around a kept own copy: its task record <meta> is positively
# gone (not merely unreadable or not a regular file), no pending backlog close is left for it
# in <state> (an interrupted close is not a completed one), and a record of a kept copy carries
# the mark of its completed close. Prints that the task is already closed, naming that record,
# and succeeds; fails otherwise, having printed nothing. Runs before any copy is looked up.
teardown_retained_closed_note() {  # <meta> <state>
  local closed_by marker
  path_positively_gone "$1" || return 1
  marker=$(fm_backlog_close_marker_path "$2" "$ID") || return 1
  path_positively_gone "$marker" || return 1
  closed_by=$(teardown_retained_closed_by "$DATA" "$ID") || return 1
  echo "teardown $ID: already closed; its own nested copy was kept by Vernant's closeout driver and stays recorded in $closed_by; nothing was changed and the driver was not asked."
}

# Did the driver's last answer (TEARDOWN_CLOSEOUT_STDOUT) keep the copy? True for exactly
# one JSON object whose reason is the retained reason; whether the rest of the answer is
# valid is judged later, from the record (teardown_retained_saved).
teardown_closeout_kept() {
  command -v jq >/dev/null 2>&1 || return 1
  printf '%s' "$TEARDOWN_CLOSEOUT_STDOUT" | jq -s -e --arg reason "$TEARDOWN_RETAINED_REASON" \
    'length == 1 and (.[0] | type == "object") and (.[0].reason == $reason)' >/dev/null 2>&1
}

# Writes the record of kept <copy>: the sweep receipt's first four lines, then the task, the
# slot, the task's preserve directory, the reason, the time, the state the driver answered for (TEARDOWN_RET_HEAD,
# TEARDOWN_RET_STATUS, TEARDOWN_RET_PAYLOAD, read before the driver was asked) and the
# driver's whole answer, base64 so any byte survives. Sets TEARDOWN_RETAINED_RECORD.
teardown_retained_write() {  # <slot> <copy> <lock-sha256> <identity>
  local rec tmp answer
  rec=$(teardown_retained_receipt "$DATA" "$2") || return 1
  answer=$(printf '%s' "$TEARDOWN_CLOSEOUT_STDOUT" | perl -MMIME::Base64 -0777 -ne 'print encode_base64($_, "")') || return 1
  [ -n "$answer" ] || return 1
  mkdir -p "${rec%/*}" || return 1
  tmp=$(mktemp "${rec%/*}/.retained.XXXXXX") || return 1
  {
    printf 'lock-sha256=%s\ncopy=%s\nidentity=%s\n' "$3" "$2" "$4"
    printf "the closeout driver kept this copy (exit 3, %s) for task %s; teardown changes nothing in it and closes the task only when the copy is landed and clean and the driver's verified archive and the task's preserve hold its unique ignored files; the driver's --execute-cleanup keeps the tree and writes another archive, so it is not run again for an unchanged copy; removing the copy depends on Vernant's driver\n" \
      "$TEARDOWN_RETAINED_REASON" "$ID"
    printf 'task=%s\nslot=%s\npreserve=%s\nreason=%s\nrecorded-at=%s\nhead=%s\nstatus-sha256=%s\npayload-sha256=%s\nanswer-base64=%s\n' \
      "$ID" "$1" "${TEARDOWN_PRESERVE_DIR:-$DATA/$ID/nested-copy-preserved/$(printf '%s' "$2" | teardown_ignored_sha256)}" \
      "$TEARDOWN_RETAINED_REASON" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$TEARDOWN_RET_HEAD" "$TEARDOWN_RET_STATUS" "$TEARDOWN_RET_PAYLOAD" "$answer"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -- "$tmp" "$rec" || { rm -f "$tmp"; return 1; }
  TEARDOWN_RETAINED_RECORD=$rec
}

# Does this task's record of <copy> still apply: the same copy (identity), the same creation
# lock bytes, and the same HEAD, status and ignored payload as when the driver answered?
# Sets TEARDOWN_RETAINED_RECORD and TEARDOWN_RETAINED_ANSWER (the decoded answer) when so.
teardown_retained_matches() {  # <copy>
  local copy=$1 rec hash='' rcopy='' identity='' actual rc=0 answer
  TEARDOWN_RETAINED_RECORD=
  TEARDOWN_RETAINED_ANSWER=
  rec=$(teardown_retained_receipt "$DATA" "$copy") || return 1
  { [ -f "$rec" ] && [ ! -L "$rec" ] && [ -r "$rec" ]; } || return 1
  { IFS= read -r hash && IFS= read -r rcopy && IFS= read -r identity; } < "$rec" || true
  [ "$rcopy" = "copy=$copy" ] || return 1
  actual=$(copy_identity "$copy") || return 1
  [ "$actual" = "${identity#identity=}" ] || return 1
  teardown_copy_lock_file "$copy" || rc=$?
  [ "$rc" = 0 ] || return 1
  actual=$(teardown_ignored_sha256 "$TEARDOWN_FOREIGN_LOCK_FILE") || return 1
  [ "$actual" = "${hash#lock-sha256=}" ] || return 1
  [ "$(teardown_retained_fields "$rec" task)" = "$ID" ] || return 1
  [ "$(teardown_retained_fields "$rec" reason)" = "$TEARDOWN_RETAINED_REASON" ] || return 1
  answer=$(teardown_retained_fields "$rec" answer-base64)
  [ -n "$answer" ] || return 1
  teardown_retained_snapshot "$copy" || return 1
  [ "$(teardown_retained_fields "$rec" head)" = "$TEARDOWN_RET_HEAD" ] || return 1
  [ "$(teardown_retained_fields "$rec" status-sha256)" = "$TEARDOWN_RET_STATUS" ] || return 1
  [ "$(teardown_retained_fields "$rec" payload-sha256)" = "$TEARDOWN_RET_PAYLOAD" ] || return 1
  TEARDOWN_RETAINED_ANSWER=$(printf '%s' "$answer" | perl -MMIME::Base64 -0777 -ne 'print decode_base64($_)'; printf '.') || return 1
  TEARDOWN_RETAINED_ANSWER=${TEARDOWN_RETAINED_ANSWER%.}
  TEARDOWN_RETAINED_RECORD=$rec
}

# (a) The kept route's clean and landed proof, never the anchor shortcut of
# teardown_own_copy_disposable (an anchor lets a pool return sweep a copy away; here the
# task closes, and closing it over unlanded or uncommitted work is the harm): every line
# of the copy's full porcelain status counts, with only Firstmate's two turn-end hook
# files and the task's own nested copies left out, and HEAD must pass teardown_landed
# (a landed commit, or the recorded verified bundle that bin/fm-teardown.sh's header
# allows for an attended teardown). --force does not waive it. Prints the cause and
# returns 1 when either fails.
teardown_retained_copy_proved() {  # <copy>
  local copy=$1 status line nested dirty="" head
  status=$(git -C "$copy" status --porcelain=v1 --untracked-files=all --ignore-submodules=none 2>/dev/null) || {
    echo "REFUSED: the state of own nested copy $(fm_refuse_text "$copy") could not be read, so it is not proved clean; the task was not closed." >&2
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'?? .fm-grok-turnend'|'?? .fm-kimi-turnend') continue ;; esac
    for nested in ${TEARDOWN_NESTED_COPIES[@]+"${TEARDOWN_NESTED_COPIES[@]}"}; do
      case "$nested" in
        "$copy"/*) [ "$line" != "?? ${nested#"$copy"/}/" ] || continue 2 ;;
      esac
    done
    dirty+=$line$'\n'
  done <<< "$status"
  if [ -n "$dirty" ]; then
    echo "REFUSED: own nested copy $(fm_refuse_text "$copy") has uncommitted or untracked changes, so it is not clean and its work is not landed; the task was not closed." >&2
    report_worktree_dirt "${dirty%$'\n'}"
    return 1
  fi
  head=$(git -C "$copy" rev-parse --verify --quiet 'HEAD^{commit}') || {
    echo "REFUSED: the HEAD of own nested copy $(fm_refuse_text "$copy") cannot be resolved, so it is not proved landed; the task was not closed." >&2
    return 1
  }
  TEARDOWN_BUNDLE_ACCEPTED=
  if ! teardown_landed "$copy" HEAD ""; then
    echo "REFUSED: own nested copy $(fm_refuse_text "$copy") has HEAD $head, which is not landed (a refs/fm/anchor ref alone does not land it) and is held by no recorded verified bundle; the task was not closed." >&2
    return 1
  fi
}

# Is the driver's own string <raw> a name of an object inside <copy>? Judged as the driver wrote
# it, before any trimming: not empty, not absolute, no empty, "." or ".." component (one
# trailing slash is allowed and marks a real directory), no symlink in a directory component,
# and the object exists. A final component that is a symlink is accepted only without a
# trailing slash and only when it resolves to something that exists inside the copy, the
# copy's root included; one that resolves outside it, or nowhere, is refused.
teardown_retained_named_ok() {  # <copy> <raw>
  local copy=$1 raw=$2 body slash=0 rest part prefix="" copy_real real
  case "$raw" in ''|/*) return 1 ;; esac
  body=$raw
  case "$raw" in */) body=${raw%/}; slash=1 ;; esac
  case "$body" in ''|*/|*//*) return 1 ;; esac
  rest=$body
  while :; do
    part=${rest%%/*}
    case "$part" in ''|.|..) return 1 ;; esac
    prefix=${prefix:+$prefix/}$part
    [ "$prefix" = "$body" ] || [ ! -L "$copy/$prefix" ] || return 1
    [ "$part" != "$rest" ] || break
    rest=${rest#*/}
  done
  if [ -L "$copy/$body" ]; then
    [ "$slash" = 0 ] || return 1
    [ -e "$copy/$body" ] || return 1
    copy_real=$(cd "$copy" 2>/dev/null && pwd -P) || return 1
    real=$(perl -MCwd=realpath -e 'my $r = realpath($ARGV[0]); print $r if defined $r' -- "$copy/$body") || return 1
    case "$real" in "$copy_real"|"$copy_real"/*) return 0 ;; esac
    return 1
  fi
  [ -e "$copy/$body" ] || return 1
  [ "$slash" = 0 ] || [ -d "$copy/$body" ]
}

# (b) Is every unique ignored file of kept <copy> saved? The driver's <answer> must be the
# kept answer in full (one object; not allowed; the retained reason; disposition
# archive_then_retain_tree; no uncovered path of any kind; a non-empty list of non-empty
# unique paths; this copy as the retained tree), and its last preservation entry must name
# a restore-verified archive of exactly that many paths, at an absolute path outside the
# copy, that is a regular file whose SHA-256 is the one the driver recorded. The driver
# verified that archive's members against the live files before it answered
# (closeout_pr.py _archive_and_verify_ignored_payload, _confirm_ignored_payload_custody).
# Then every path the driver names must be an object inside the copy, judged as the driver
# wrote it (teardown_retained_named_ok), and the task's own preserve (teardown_own_preserve,
# written before the driver was asked) must still hold the copy's ignored files byte for byte
# (teardown_own_preserve_holds); a driver-named path it lacks is copied in first, never over a
# byte it holds. Every run that judges the answer, a replay from the record included, runs the
# same checks. Prints the named cause and returns 1 when any of it fails.
teardown_retained_saved() {  # <copy> <answer>
  local copy=$1 answer=$2 archive sha copy_real archive_real preserve work raw rc=0
  local -a named=()
  if ! command -v jq >/dev/null 2>&1 || ! printf '%s' "$answer" | jq -s -e \
      --arg reason "$TEARDOWN_RETAINED_REASON" '
    length == 1 and (.[0] | type == "object")
    and (.[0].allowed == false) and (.[0].reason == $reason)
    and (.[0].ignored_payload_disposition == "archive_then_retain_tree")
    and (.[0].tracked_uncovered_paths == []) and (.[0].uncovered_paths == [])
    and ((.[0].untracked_uncovered_paths // []) == [])
    and ((.[0].unique_ignored_paths | type) == "array") and ((.[0].unique_ignored_paths | length) > 0)
    and (.[0].unique_ignored_paths | all(type == "string" and length > 0 and (contains("\u0000") | not)))
    and ((.[0].retained_worktree_path | type) == "string")
    and ((.[0].ignored_payload_preservation | type) == "array")
    and ((.[0].ignored_payload_preservation | length) > 0)
    and (.[0].ignored_payload_preservation[-1] | type == "object"
         and .restore_verified == true
         and ((.archive_path | type) == "string") and (.archive_path | startswith("/"))
         and ((.archive_sha256 | type) == "string") and (.archive_sha256 | test("^[0-9a-f]{64}$")))
    and (.[0].ignored_payload_preservation[-1].path_count == (.[0].unique_ignored_paths | length))
  ' >/dev/null 2>&1; then
    echo "REFUSED: Vernant's closeout driver kept own nested copy $(fm_refuse_text "$copy"), but its recorded answer does not name a restore-verified archive of every unique ignored file it lists (or lists an empty, uncovered or non-string path); its unique ignored files are not proved saved, and the task was not closed." >&2
    return 1
  fi
  copy_real=$(cd "$copy" 2>/dev/null && pwd -P) || copy_real=
  if [ -z "$copy_real" ] \
      || [ "$(fm_task_copy_canonical_dir "$(printf '%s' "$answer" | jq -r '.retained_worktree_path')" 2>/dev/null)" != "$(fm_task_copy_canonical_dir "$copy" 2>/dev/null)" ]; then
    echo "REFUSED: Vernant's closeout driver's recorded answer keeps a tree other than own nested copy $(fm_refuse_text "$copy"); its unique ignored files are not proved saved, and the task was not closed." >&2
    return 1
  fi
  archive=$(printf '%s' "$answer" | jq -r '.ignored_payload_preservation[-1].archive_path')
  sha=$(printf '%s' "$answer" | jq -r '.ignored_payload_preservation[-1].archive_sha256')
  archive_real=$(cd "$(dirname "$archive")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "${archive##*/}") || archive_real=
  if [ -z "$archive_real" ] || [ ! -f "$archive" ] || [ -L "$archive" ]; then
    echo "REFUSED: the archive $(fm_refuse_text "$archive") that Vernant's closeout driver recorded for own nested copy $(fm_refuse_text "$copy") is not a regular file; its unique ignored files are not proved saved, and the task was not closed." >&2
    return 1
  fi
  case "$archive_real" in
    "$copy_real"/*)
      echo "REFUSED: the archive $(fm_refuse_text "$archive") that Vernant's closeout driver recorded for own nested copy $(fm_refuse_text "$copy") is inside the copy; its unique ignored files are not proved saved apart from it, and the task was not closed." >&2
      return 1
      ;;
  esac
  if [ "$(teardown_ignored_sha256 "$archive" 2>/dev/null)" != "$sha" ]; then
    echo "REFUSED: the archive $(fm_refuse_text "$archive") that Vernant's closeout driver recorded for own nested copy $(fm_refuse_text "$copy") does not have the SHA-256 it recorded ($sha); its unique ignored files are not proved saved, and the task was not closed." >&2
    return 1
  fi
  # Every name the driver lists is judged as it wrote it, before any trimming: one that is not
  # an object inside the copy cannot be checked against it.
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-retained-saved.XXXXXX") || return 1
  if ! printf '%s' "$answer" | jq -j '.unique_ignored_paths[] | ., "\u0000"' > "$work/named" 2>/dev/null; then
    rm -rf "$work"
    echo "REFUSED: the unique ignored paths in the recorded answer of Vernant's closeout driver for own nested copy $(fm_refuse_text "$copy") could not be read; the task was not closed." >&2
    return 1
  fi
  while IFS= read -r -d '' raw; do
    if ! teardown_retained_named_ok "$copy" "$raw"; then
      rm -rf "$work"
      echo "REFUSED: Vernant's closeout driver names ignored path $(fm_refuse_text "$raw") of own nested copy $(fm_refuse_text "$copy"), which is not a plain path inside the copy, resolves outside it or nowhere, or no longer exists, so its bytes cannot be checked against the copy; the task was not closed, and a retry asks the driver nothing while the copy is unchanged." >&2
      return 1
    fi
    named+=("${raw%/}")
  done < "$work/named"
  # Then the task's own preserve, written before the driver was asked, must still agree with
  # the copy byte for byte, and every ignored file of the copy's payload and every driver-named
  # path is copied in where it lacks it (never over a byte it holds) and must then be held too.
  teardown_own_preserve_widen "$copy" ${named[@]+"${named[@]}"} || rc=1
  preserve=${TEARDOWN_PRESERVE_DIR:-}
  rm -rf "$work"
  if [ "$rc" != 0 ]; then
    echo "REFUSED: the preserve $(fm_refuse_text "${preserve:-$DATA/$ID/nested-copy-preserved}") does not hold every ignored file of own nested copy $(fm_refuse_text "$copy") that preservation selects, that its payload holds or that the driver names, byte for byte (or one could not be read or copied in); the task was not closed, and a retry asks the driver nothing, keeps an earlier preserve that agrees with the unchanged copy and otherwise preserves it in the next free name beside it, never over an earlier preserve." >&2
    return 1
  fi
}

# (a), (b) and (d) for kept <copy>, from the driver's recorded answer: closes around the
# copy (adds it to TEARDOWN_RETAINED) when (a) and (b) hold, otherwise returns 1 after the
# named refusal. Nothing in the copy is changed either way, and the driver is not asked:
# the next run judges the same record again while it still matches the copy.
teardown_retained_judge() {  # <copy> <answer>
  local copy=$1
  if ! teardown_own_nested_other_repos; then
    echo "REFUSED: own nested copy $(fm_refuse_text "$copy") was kept by Vernant's closeout driver (record $(fm_refuse_text "$TEARDOWN_RETAINED_RECORD")), but the task's nested copies hold another Git repository or could not be scanned for one; the task was not closed, and a retry asks the driver nothing." >&2
    return 1
  fi
  teardown_retained_copy_proved "$copy" || return 1
  teardown_retained_saved "$copy" "$2" || return 1
  if [ -n "$TEARDOWN_PRESERVE_DIR" ] && ! teardown_retained_preserve_note "$TEARDOWN_RETAINED_RECORD" "$TEARDOWN_PRESERVE_DIR"; then
    echo "REFUSED: the record $(fm_refuse_text "$TEARDOWN_RETAINED_RECORD") of own nested copy $(fm_refuse_text "$copy") could not be updated to name its preserve $(fm_refuse_text "$TEARDOWN_PRESERVE_DIR"); the task was not closed, and a retry asks the driver nothing." >&2
    return 1
  fi
  # A pool-slot close releases own copies twice (main, then the slot return): report once.
  ! teardown_copy_retained "$copy" || return 0
  TEARDOWN_RETAINED+=("$copy")
  echo "teardown: Vernant's closeout driver kept own nested copy $(fm_refuse_text "$copy"); it is landed and clean, its unique ignored files are in the driver's verified archive and in the task's preserve $(fm_refuse_text "${TEARDOWN_PRESERVE_DIR:-(no ignored file to preserve)}"), and the copy is untouched (record $(fm_refuse_text "$TEARDOWN_RETAINED_RECORD"))" >&2
}

# Is <copy> one this teardown keeps because the driver kept it?
teardown_copy_retained() {  # <copy>
  local kept
  for kept in ${TEARDOWN_RETAINED[@]+"${TEARDOWN_RETAINED[@]}"}; do
    [ "$kept" != "$1" ] || return 0
  done
  return 1
}

# Does own nested <copy> hold Vernant's creation lock and a record of this task that still
# applies to it? Such a copy is kept: the retire step leaves it out of its swept roots and
# drops what the copy's proof queued, so no signal reaches it.
teardown_retained_copy_held() {  # <copy>
  local rc=0
  [ -d "$1" ] || return 1
  teardown_copy_lock_file "$1" || rc=$?
  [ "$rc" = 0 ] || return 1
  teardown_retained_matches "$1"
}

# Does any own nested copy of the task have a record that still applies?
teardown_retained_own_present() {
  local copy
  for copy in ${TEARDOWN_NESTED_COPIES[@]+"${TEARDOWN_NESTED_COPIES[@]}"}; do
    ! teardown_retained_copy_held "$copy" || return 0
  done
  return 1
}

# A task that keeps a retained own nested copy never returns its pool slot: the
# slot must stay under a durable lease (a later treehouse get could reset it over
# the copy), and the held-close route then applies to it. A slot another live
# task still works in is not this task's to hold, so a kept copy there refuses.
teardown_retained_hold() {
  [ "${#TEARDOWN_RETAINED[@]}" -gt 0 ] || return 0
  if [ -z "${TEARDOWN_RETURN_SLOT:-}" ]; then
    echo "REFUSED: own nested copy $(fm_refuse_text "${TEARDOWN_RETAINED[0]}") was kept by Vernant's closeout driver (record $(fm_refuse_text "$(teardown_retained_receipt "$DATA" "${TEARDOWN_RETAINED[0]}")")) in pool slot $(fm_refuse_text "${TEARDOWN_PEER_SLOT:-}"), which another live task still works in, so this task cannot hold the slot under its lease; the copy, the slot and the record stay as they are, the task was not closed, and a retry asks the driver nothing." >&2
    return 1
  fi
  if [ "${TEARDOWN_SLOT_CUSTODY:-}" != lease ]; then
    echo "REFUSED: pool slot $(fm_refuse_text "$TEARDOWN_RETURN_SLOT") could not be durably leased, and a close that keeps own nested copy $(fm_refuse_text "${TEARDOWN_RETAINED[0]}") never leaves its slot without a durable lease, since a later treehouse get could reset it over the copy; the copy, the slot and the record stay as they are, and a retry asks the driver nothing." >&2
    return 1
  fi
  TEARDOWN_HELD_SLOT=$TEARDOWN_RETURN_SLOT
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
teardown_foreign_copy_dispose() {  # <slot> <copy> [ignored-mode]
  local slot=$1 copy=$2 rc=0 remove_rc remove_err protected
  teardown_preserve_ignored "$copy" "${3:-}" || {
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
      teardown_run_closeout "$slot" "$copy" || rc=$?
      if [ "$rc" != 0 ]; then
        teardown_closeout_refusal foreign "$copy" "$rc"
        return 1
      fi
      ;;
    1)
      remove_rc=0
      teardown_copy_git_protects "$copy" && protected=1 || protected=0
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
# A copy this task's record says the driver kept, unchanged since, gets the same proof,
# but nothing it would queue for the retire signal is kept: no signal reaches a kept copy.
teardown_own_locked_copies_prove() {
  local copy rc queued slot held
  slot=${TEARDOWN_RETURN_SLOT:-${TEARDOWN_PEER_SLOT:-}}
  for copy in ${TEARDOWN_NESTED_COPIES[@]+"${TEARDOWN_NESTED_COPIES[@]}"}; do
    [ -d "$copy" ] || continue
    rc=0
    teardown_copy_lock_file "$copy" || rc=$?
    [ "$rc" = 0 ] || continue
    TEARDOWN_FOREIGN_WHY=
    TEARDOWN_FOREIGN_RULE=creation-lock-owner
    queued=${#TEARDOWN_FOREIGN_PROCS[@]}
    if ! teardown_vernant_lock_pid "$TEARDOWN_FOREIGN_LOCK" >/dev/null; then
      TEARDOWN_FOREIGN_WHY="it is locked by something other than Vernant's creation lock (${TEARDOWN_FOREIGN_LOCK:-no reason given})"
    else
      # A peer reassociated off this slot into its own copy is not another
      # record naming the copy through the root it left.
      FM_TASK_COPY_RELEASED_PRIOR_RETIRING=$META
      teardown_foreign_copy_unowned "$copy" || true
      FM_TASK_COPY_RELEASED_PRIOR_RETIRING=
    fi
    # A copy whose record still matches is judged from that record and asks the
    # driver nothing, in plan mode too (Main 2056).
    held=0
    [ -n "$TEARDOWN_FOREIGN_WHY" ] || ! teardown_retained_copy_held "$copy" || held=1
    # The release hands this copy to Vernant's closeout driver, run from the
    # slot; one that cannot start, or that the driver in plan mode would not
    # release, refuses here, before any protected step. A plan that keeps the
    # tree goes to the kept route (teardown_own_closeout_plan_allows).
    if [ "$held" = 0 ] && [ -z "$TEARDOWN_FOREIGN_WHY" ] && ! teardown_closeout_ready_in "$slot"; then
      TEARDOWN_FOREIGN_RULE=inspection-unavailable
      TEARDOWN_FOREIGN_WHY="$TEARDOWN_CLOSEOUT_OUT, so it cannot be released"
    fi
    # The driver's own answer, asked in plan mode now; the release asks again.
    if [ "$held" = 0 ] && [ -z "$TEARDOWN_FOREIGN_WHY" ] \
        && ! teardown_own_closeout_plan_allows "$(fm_task_copy_canonical_dir "$slot")" "$copy"; then
      TEARDOWN_FOREIGN_RULE=inspection-unavailable
      TEARDOWN_FOREIGN_WHY=$TEARDOWN_CLOSEOUT_PLAN_WHY
    fi
    if [ -n "$TEARDOWN_FOREIGN_WHY" ]; then
      teardown_refuse_copy "${TEARDOWN_FOREIGN_RULE:-creation-lock-owner}" "own nested copy $copy stays in pool slot ${TEARDOWN_RETURN_SLOT:-${TEARDOWN_PEER_SLOT:-}}: $TEARDOWN_FOREIGN_WHY." "$copy"
      return 1
    fi
    if [ "${#TEARDOWN_FOREIGN_PROCS[@]}" -gt "$queued" ] && [ "$held" = 1 ]; then
      TEARDOWN_FOREIGN_PROCS=("${TEARDOWN_FOREIGN_PROCS[@]:0:$queued}")
    fi
  done
}

# Preserves the ignored files of one proved own nested copy that Vernant's
# creation lock holds, then releases and removes it through Vernant's driver, or,
# when the driver keeps it, closes around it (see "Kept own copies" above).
# Returns 1 after printing a refusal.
teardown_own_copy_dispose() {  # <slot> <copy>
  local work rc=0
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-own-dispose.XXXXXX") || return 1
  teardown_own_copy_dispose_in "$1" "$2" "$work" || rc=$?
  rm -rf "$work"
  return "$rc"
}

teardown_own_copy_dispose_in() {  # <slot> <copy> <work-dir>
  local slot=$1 copy=$2 work=$3 rc=0 lock_hash='' identity='' record refused before at_driver='' proot='' after=
  teardown_copy_lock_file "$copy" || rc=$?
  if [ "$rc" != 0 ] || ! teardown_vernant_lock_pid "$TEARDOWN_FOREIGN_LOCK" >/dev/null; then
    echo "REFUSED: own nested copy $(fm_refuse_text "$copy") is not locked by Vernant's creation lock any more; it was not removed." >&2
    return 1
  fi
  # The copy is preserved before anything else; an earlier preserve is kept as it is.
  teardown_own_preserve "$copy" || {
    teardown_refuse_copy ignored-bytes-preserved "the ignored files of own nested copy $copy could not be preserved in $DATA/$ID/nested-copy-preserved; it was not removed." "$copy"
    return 1
  }
  # The driver already kept this unchanged copy: judge its recorded answer, never ask again.
  if teardown_retained_matches "$copy"; then
    teardown_retained_judge "$copy" "$TEARDOWN_RETAINED_ANSWER"
    return
  fi
  # A record that exists but cannot be read, or whose folder cannot be searched, may hold
  # an answer the driver already gave: the driver is not asked while it is unknown.
  record=$(teardown_retained_receipt "$DATA" "$copy") || record=
  rc=0
  [ -z "$record" ] || path_positively_gone "$record" || rc=$?
  if [ -z "$record" ] || [ "$rc" = 2 ] \
      || { [ "$rc" = 1 ] && ! { [ -f "$record" ] && [ ! -L "$record" ] && [ -r "$record" ]; }; }; then
    echo "REFUSED: the record $(fm_refuse_text "${record:-of own nested copy}") of own nested copy $(fm_refuse_text "$copy") cannot be read, so what Vernant's closeout driver already answered is unknown; the driver was not asked, and the task was not closed." >&2
    return 1
  fi
  # Every ask of the driver can write one more archive, so it is asked only when its answer
  # can be recorded against the copy's identity, its creation lock and its state.
  lock_hash=$(teardown_ignored_sha256 "$TEARDOWN_FOREIGN_LOCK_FILE") || lock_hash=
  identity=$(copy_identity "$copy") || identity=
  if [ -z "$lock_hash" ] || [ -z "$identity" ] || ! teardown_retained_snapshot "$copy"; then
    echo "REFUSED: the identity, creation lock or state of own nested copy $(fm_refuse_text "$copy") cannot be read, so an answer of Vernant's closeout driver could not be recorded against it; the driver was not asked, and the task was not closed." >&2
    return 1
  fi
  refused=$(teardown_retained_refused_path "$copy") || refused=
  if [ -z "$refused" ] || ! teardown_retained_refused_writable "$copy"; then
    echo "REFUSED: neither the record $(fm_refuse_text "$record") nor the refusal record $(fm_refuse_text "${refused:-of own nested copy}") of own nested copy $(fm_refuse_text "$copy") is proved writable, so an answer of Vernant's closeout driver could not be recorded; the driver was not asked, and the task was not closed." >&2
    return 1
  fi
  if ! teardown_retained_record_writable "$copy"; then
    teardown_retained_refused_write "$copy" "$lock_hash" "$identity" "its record $record cannot be written (its folder does not take a new file)" \
      || echo "warning: the refusal record $(fm_refuse_text "$refused") of own nested copy $(fm_refuse_text "$copy") could not be written." >&2
    echo "REFUSED: the record $(fm_refuse_text "$record") of own nested copy $(fm_refuse_text "$copy") cannot be written, so an answer of Vernant's closeout driver could not be recorded; the driver was not asked, the refusal is recorded in $(fm_refuse_text "$refused"), and the task was not closed." >&2
    return 1
  fi
  # The preserve must hold the copy's bytes at the last moment before the driver is asked: a
  # file changed after it was preserved would be lost if the driver released the copy.
  rc=0
  if [ -n "$TEARDOWN_PRESERVE_DIR" ]; then
    { teardown_own_preserve_current "$copy" "$TEARDOWN_PRESERVE_DIR" "$work/list" \
        && teardown_own_preserve_holds "$copy" "$TEARDOWN_PRESERVE_DIR" "$work/list" \
        && at_driver=$(teardown_retained_digest "$copy" < "$work/list") \
        && proot=$(teardown_own_preserve_root "$TEARDOWN_PRESERVE_DIR" "$copy"); } || rc=1
  else
    # Nothing was selected when the copy was preserved: anything selected now appeared since.
    teardown_own_preserve_list "$copy" "$work/list" selected || rc=1
    [ "$rc" != 0 ] || [ ! -s "$work/list" ] || rc=1
  fi
  if [ "$rc" != 0 ]; then
    echo "REFUSED: the ignored files of own nested copy $(fm_refuse_text "$copy") changed after they were preserved in $(fm_refuse_text "${TEARDOWN_PRESERVE_DIR:-$DATA/$ID/nested-copy-preserved}") (or could not be read again); the driver was not asked, the copy was not removed, and a retry keeps an earlier preserve that agrees with the copy and otherwise preserves it in the next free name beside it, never over an earlier preserve." >&2
    return 1
  fi
  before="$TEARDOWN_RET_HEAD $TEARDOWN_RET_STATUS $TEARDOWN_RET_PAYLOAD"
  rc=0
  teardown_run_closeout "$slot" "$copy" || rc=$?
  if [ "$rc" != 0 ]; then
    if [ "$rc" = 3 ] && teardown_closeout_kept; then
      if ! teardown_retained_write "$slot" "$copy" "$lock_hash" "$identity"; then
        teardown_retained_refused_write "$copy" "$lock_hash" "$identity" "Vernant's closeout driver kept it, but its record $record could not be written" "$TEARDOWN_CLOSEOUT_STDOUT" \
          || echo "warning: the refusal record $(fm_refuse_text "$refused") of own nested copy $(fm_refuse_text "$copy") could not be written." >&2
        echo "REFUSED: Vernant's closeout driver kept own nested copy $(fm_refuse_text "$copy"), but its record $(fm_refuse_text "$record") could not be written; the refusal and the driver's answer are recorded in $(fm_refuse_text "$refused"), the task was not closed, and a retry asks the driver nothing while the record cannot be written." >&2
        return 1
      fi
      teardown_retained_refused_clear "$copy"
      echo "teardown: Vernant's closeout driver kept own nested copy $(fm_refuse_text "$copy"); its answer is recorded in $(fm_refuse_text "$TEARDOWN_RETAINED_RECORD"), and the copy is not changed" >&2
      # The answer is for the state read before the driver was asked: a copy that changed
      # meanwhile (a file written during the call may be in no archive) is not closed over,
      # and the next run, whose record no longer matches, assesses it afresh.
      if ! teardown_retained_snapshot "$copy" \
          || [ "$before" != "$TEARDOWN_RET_HEAD $TEARDOWN_RET_STATUS $TEARDOWN_RET_PAYLOAD" ]; then
        echo "REFUSED: own nested copy $(fm_refuse_text "$copy") changed while Vernant's closeout driver ran (or its state could not be read again); the task was not closed, and a retry assesses the changed copy afresh." >&2
        return 1
      fi
      teardown_retained_judge "$copy" "$TEARDOWN_CLOSEOUT_STDOUT"
      return
    fi
    teardown_closeout_refusal 'own nested' "$copy" "$rc"
    return 1
  fi
  if teardown_foreign_copy_present "$slot" "$copy"; then
    echo "REFUSED: own nested copy $(fm_refuse_text "$copy") is still present or registered after its release; the pool slot was not returned." >&2
    return 1
  fi
  # After the release, the preserve must still hold what the copy held when the driver was asked.
  if [ -s "$work/list" ]; then
    after=$(teardown_retained_digest "$proot" < "$work/list" 2>/dev/null) || after=
  fi
  if [ -s "$work/list" ] && { [ -z "$proot" ] || [ "$after" != "$at_driver" ]; }; then
    echo "REFUSED: Vernant's closeout driver released own nested copy $(fm_refuse_text "$copy"), but its preserve $(fm_refuse_text "$TEARDOWN_PRESERVE_DIR") no longer holds the bytes the copy held when the driver was asked; the task was not closed." >&2
    return 1
  fi
  teardown_retained_refused_clear "$copy"
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
  while IFS= read -r copy; do
    ordered+=("$copy")
  done < <(printf '%s\n' "${TEARDOWN_NESTED_COPIES[@]}" | LC_ALL=C sort -r)
  for copy in "${ordered[@]}"; do
    [ -d "$copy" ] || continue
    rc=0
    teardown_copy_lock_file "$copy" || rc=$?
    [ "$rc" = 0 ] || continue
    teardown_own_copy_dispose "$slot" "$copy" || return 1
    if ! teardown_copy_retained "$copy"; then
      TEARDOWN_OWN_RELEASED+=("$copy")
    fi
  done
  teardown_retained_hold
}

# By-path teardown (bin/fm-teardown.sh --copy <path> [--record-id <id>]).
#
# Removes one nested worktree no task record names. bin/fm-teardown.sh's header
# ("By-path teardown") owns the contract and docs/agent-control.md the operator
# rule; this section owns the mechanics. Every landed-work, ignored-file, process,
# lock and removal step is the foreign-copy code above, called unchanged
# (teardown_foreign_copy_prove twice, then teardown_foreign_copy_dispose); this
# section adds only what a copy with no record lacks: finding the clone that
# registers it, the open-handle scan, the claim and inner-copy checks, the bundle
# record id, the lock on the path and the audit record. It never signals a process,
# because no scan root is set (TEARDOWN_RETURN_SLOT, WT and TASK_TMP stay empty)
# and teardown_pid_is_task_own is therefore false for every pid.
TEARDOWN_BY_PATH_CLONE=
TEARDOWN_BY_PATH_HASH=
TEARDOWN_BY_PATH_HOLDER=
TEARDOWN_BY_PATH_WHY=
TEARDOWN_BY_PATH_WHY_RULE=
TEARDOWN_BY_PATH_LOG='record-less-copy-removals.log'

# The one place a by-path run prints a refusal of its own. The checks below record
# why they stop with teardown_by_path_why and return 1; teardown_by_path_main
# prints that reason once.
teardown_by_path_refuse() {  # <reason>
  echo "REFUSED: $1; nothing was removed." >&2
  return 1
}
teardown_by_path_why() {  # <reason>
  TEARDOWN_BY_PATH_WHY=$1
  TEARDOWN_BY_PATH_WHY_RULE=
  return 1
}
# A refusal whose only cause is an input that could not be read: the exception
# gives it rule inspection-unavailable, never a policy row.
teardown_by_path_unread() {  # <reason>
  TEARDOWN_BY_PATH_WHY=$1
  TEARDOWN_BY_PATH_WHY_RULE=inspection-unavailable
  return 1
}

# Settles the copy's canonical path and the bundle record id before anything
# else uses ID: the request id is a placeholder until here. A copy that is gone
# keeps the path as given, resolved through its nearest existing parent. Returns
# 2 for a request that is not valid and 1 for a refusal.
teardown_by_path_prepare() {
  local raw=$TEARDOWN_BY_PATH_COPY parent canon hash
  case "$raw" in
    /*) ;;
    *) echo "error: teardown --copy needs an absolute path, not $(fm_refuse_text "$raw")" >&2; return 2 ;;
  esac
  case "$raw" in
    *$'\t'*|*$'\n'*|*$'\r'*) echo "error: teardown --copy path $(fm_refuse_text "$raw") holds a tab or line break, which its audit record cannot hold" >&2; return 2 ;;
  esac
  while [ "${#raw}" -gt 1 ] && [ "${raw%/}" != "$raw" ]; do raw=${raw%/}; done
  if [ -L "$raw" ]; then
    echo "error: teardown --copy takes the copy's own path, and $(fm_refuse_text "$raw") is a symbolic link" >&2
    return 2
  fi
  if [ -d "$raw" ]; then
    canon=$(fm_task_copy_canonical_dir "$raw") || canon=$raw
  else
    parent=${raw%/*}
    [ -n "$parent" ] || parent=/
    canon=$(fm_task_copy_canonical_dir "$parent") || canon=${raw%/*}
    canon="${canon%/}/${raw##*/}"
  fi
  hash=$(printf '%s' "$canon" | teardown_ignored_sha256) || {
    echo "error: teardown --copy cannot hash the copy's path: no SHA-256 tool is available" >&2
    return 1
  }
  TEARDOWN_BY_PATH_COPY=$canon
  TEARDOWN_BY_PATH_HASH=${hash:0:16}
  [ -n "$TEARDOWN_BY_PATH_RECORD_ID" ] || TEARDOWN_BY_PATH_RECORD_ID="copy-$TEARDOWN_BY_PATH_HASH"
  ID=$TEARDOWN_BY_PATH_RECORD_ID
  if [ -e "$STATE/$ID.meta" ] || [ -L "$STATE/$ID.meta" ]; then
    echo "error: record id $ID names a live task record in $STATE, so teardown --copy never takes it as a bundle record id; give --record-id another id, or run bin/fm-teardown.sh $ID for that task" >&2
    return 2
  fi
  TEARDOWN_RETRY_ACTION="run the same teardown --copy command again"
}

# The globals the reused proofs read that the record-driven flow sets from a task
# record. A by-path run has no record, so each takes the strictest value: the
# plain no-mistakes landing rule (no local-only shortcut), no recorded PR, no task
# scratch, no returned slot and no nested copies of its own.
teardown_by_path_init() {
  WT=
  PROJ=
  MODE=no-mistakes
  BASE_BRANCH=
  PR_URL=
  KIND=ship
  TASK_TMP=
  LAUNCH_HOME_TOKEN=
  TEARDOWN_RETURN_SLOT=
  TEARDOWN_ENCLOSING_SLOT=
  TEARDOWN_PEER_SLOT=
  TEARDOWN_NESTED_COPIES=()
  TEARDOWN_BACKLOG_TRANSITION=close
  TEARDOWN_BACKLOG_APPLIES=0
  if fm_backlog_transition_applies "$CONFIG" "$DATA" ship; then
    TEARDOWN_BACKLOG_APPLIES=1
  elif [ "$?" -eq 2 ]; then
    teardown_by_path_why "the backlog data directory is inaccessible: $DATA ($FM_BACKLOG_TRANSITION_ERROR)"
    return 1
  fi
}

# Finds the clone that registers <copy> strictly inside itself: a project clone
# under this home's projects/, or a Treehouse slot of one. A path that is the
# clone or slot itself, an unregistered directory or a path elsewhere finds none.
# Sets TEARDOWN_BY_PATH_CLONE and PROJ (the project clone, whose ref store the
# landing proof reads). Works for a copy whose directory is gone, so a rerun can
# tell a stale registration from a finished removal.
# Returns 0 when a clone registers it, 1 when every clone it could be in was read
# and none does, and 2 when none registers it but something it needed could not be
# read (TEARDOWN_BY_PATH_UNREADABLE names the first such thing), so "not
# registered" is never concluded from an unreadable list. An entry that is not a
# directory, not a Git repository at all, or a subdirectory of another repository
# is no clone and is skipped; a Git repository that cannot be read, a clone or slot
# whose registration list cannot be read, and a projects folder that cannot be
# listed, are not.
TEARDOWN_BY_PATH_UNREADABLE=
teardown_by_path_locate() {  # <canonical-copy>
  local copy=$1 project proj top clone slot registered
  TEARDOWN_BY_PATH_CLONE=
  TEARDOWN_BY_PATH_UNREADABLE=
  # An absent projects folder holds no clone; one that is there but cannot be listed
  # (or a link to nothing) is not an empty one.
  if [ -e "$FM_HOME/projects" ] || [ -L "$FM_HOME/projects" ]; then
    if [ ! -d "$FM_HOME/projects" ] || ! ls -A -- "$FM_HOME/projects" >/dev/null 2>&1; then
      TEARDOWN_BY_PATH_UNREADABLE="the project folder $(fm_refuse_text "$FM_HOME/projects") could not be read"
    fi
  fi
  for project in "$FM_HOME"/projects/*; do
    [ -d "$project" ] || continue
    proj=$(fm_task_copy_canonical_dir "$project") || {
      [ -n "$TEARDOWN_BY_PATH_UNREADABLE" ] || TEARDOWN_BY_PATH_UNREADABLE="the project directory $(fm_refuse_text "$project") could not be read"
      continue
    }
    if ! top=$(git -C "$proj" rev-parse --show-toplevel 2>/dev/null); then
      if [ -e "$proj/.git" ] || [ -L "$proj/.git" ]; then
        [ -n "$TEARDOWN_BY_PATH_UNREADABLE" ] || TEARDOWN_BY_PATH_UNREADABLE="the Git repository $(fm_refuse_text "$proj") could not be read"
      fi
      continue
    fi
    [ "$(fm_task_copy_canonical_dir "$top")" = "$proj" ] || continue
    clone=
    case "$copy" in "$proj"/*) clone=$proj ;; esac
    if [ -z "$clone" ] && slot=$(fm_task_copy_enclosing_pool_slot "$proj" "$copy"); then
      clone=$slot
    fi
    [ -n "$clone" ] || continue
    fm_task_copy_read_registered_nested "$clone" || {
      [ -n "$TEARDOWN_BY_PATH_UNREADABLE" ] || TEARDOWN_BY_PATH_UNREADABLE=$(fm_task_copy_unreadable_list_text "the clone $(fm_refuse_text "$clone")'s")
      continue
    }
    registered=$FM_TASK_COPY_NESTED
    if printf '%s\n' "$registered" | grep -Fxq -- "$copy"; then
      TEARDOWN_BY_PATH_CLONE=$clone
      PROJ=$proj
      return 0
    fi
  done
  [ -z "$TEARDOWN_BY_PATH_UNREADABLE" ] || return 2
  return 1
}

# Refuses while any process has <copy> as its cwd or holds a file open inside it.
# One scan of every open file: a failed scan, or no lsof, refuses, because a copy
# whose holders are unknown is not proved idle. Nothing is ever signalled.
teardown_by_path_holders() {  # <copy>
  local copy=$1 out line pid='' command='' fd='' name hits='' held=''
  if ! command -v lsof >/dev/null 2>&1; then
    teardown_by_path_unread "$(fm_refuse_text "$copy") cannot be proved idle: lsof is not installed to list the processes holding it"
    return 1
  fi
  out=$(lsof -nP -w -Fpcfn 2>/dev/null) || {
    teardown_by_path_unread "$(fm_refuse_text "$copy") cannot be proved idle: the process scan failed"
    return 1
  }
  while IFS= read -r line; do
    case "$line" in
      p*) pid=${line#p}; command=; fd= ;;
      c*) command=${line#c} ;;
      f*) fd=${line#f} ;;
      n*)
        name=${line#n}
        case "$name" in
          "$copy"|"$copy"/*)
            [ "$pid" = "$$" ] || case " $hits " in
              *" $pid "*) ;;
              *)
                if [ -z "$hits" ]; then
                  TEARDOWN_BY_PATH_HOLDER="process $pid ($(fm_refuse_text "$command")) holds $(fm_refuse_text "$name") through ${fd:-an open file}"
                  [ "$fd" = cwd ] || held=$name
                fi
                hits+="${hits:+ }$pid"
                ;;
            esac
            ;;
        esac
        ;;
    esac
  done <<< "$out"
  [ -z "$hits" ] || {
    TEARDOWN_FOREIGN_PID=${hits%% *}
    TEARDOWN_FOREIGN_HOLDER_FILE=$held
    teardown_by_path_why "$(fm_refuse_text "$copy") is in use: $TEARDOWN_BY_PATH_HOLDER (processes holding it: $hits)"
    return 1
  }
}

# Does <copy> hold a Git repository or linked worktree that its own clone does not
# register, a bare repository included? teardown_copy_other_repo_dirs is the scan,
# the one the held close of a task's own nested copies uses too. Returns 1 with the
# first repository found in TEARDOWN_BY_PATH_OTHER_REPO, 2 when the scan cannot be
# completed, and 0 when there is none.
TEARDOWN_BY_PATH_OTHER_REPO=
teardown_by_path_other_repos() {  # <copy>
  local hits rc=0
  hits=$(teardown_copy_other_repo_dirs "$1") || rc=$?
  TEARDOWN_BY_PATH_OTHER_REPO=${hits%%$'\n'*}
  [ -z "$TEARDOWN_BY_PATH_OTHER_REPO" ] || return 1
  [ "$rc" = 0 ] || return 2
}

# Refuses a copy that has another registered worktree inside it, which git worktree
# remove would delete with it, and a copy that holds a Git repository or worktree
# no clone registers (a separate clone, or a worktree of another project), whose
# commits would go with it and which no registration list shows. git status cannot
# see either when .claude is ignored, and the clean proof skips untracked files
# under .claude. The second scan is teardown_by_path_other_repos; every repository
# it finds is refused, because nothing here proves its commits landed.
teardown_by_path_inner() {  # <copy>
  local copy=$1 inner rc=0
  fm_task_copy_read_registered_nested "$copy" || {
    teardown_by_path_unread "$(fm_task_copy_unreadable_list_text "the copy $(fm_refuse_text "$copy")'s"), so the worktrees registered inside it cannot be listed"
    return 1
  }
  inner=$FM_TASK_COPY_NESTED
  while IFS= read -r inner; do
    [ -n "$inner" ] && [ -d "$inner" ] || continue
    teardown_by_path_why "$(fm_refuse_text "$copy") holds registered worktree $(fm_refuse_text "$inner"), which removing it would delete; remove or prove that worktree first"
    return 1
  done <<< "$inner"
  teardown_by_path_other_repos "$copy" || rc=$?
  case "$rc" in
    0) ;;
    1)
      teardown_by_path_why "$(fm_refuse_text "$copy") holds Git repository $(fm_refuse_text "$TEARDOWN_BY_PATH_OTHER_REPO") that no clone registers, which removing it would delete with its commits; remove it or land its commits first"
      return 1
      ;;
    *)
      teardown_by_path_unread "$(fm_refuse_text "$copy") could not be scanned for other Git repositories, so what removing it would delete cannot be proved"
      return 1
      ;;
  esac
}

# A Treehouse slot's owner claim that names a task with a live record in any local
# home keeps its nested copies out of this mode, as it keeps the slot out of
# another task's cleanup. A claim naming a task no home has a record for is stale;
# a claim that cannot be read proves nothing and refuses. A by-path run is no task,
# and its record id is operator-chosen, so a claim naming that very id is not
# "mine": it is resolved against the live records like any other claim.
teardown_by_path_claim() {
  local task state_dir
  fm_treehouse_pool_slot "$PROJ" "$TEARDOWN_BY_PATH_CLONE" || return 0
  fm_treehouse_slot_owner_state "$TEARDOWN_BY_PATH_CLONE" "$ID"
  case "$FM_TREEHOUSE_SLOT_OWNER" in
    absent) return 0 ;;
    unsafe)
      teardown_by_path_unread "the owner claim of pool slot $(fm_refuse_text "$TEARDOWN_BY_PATH_CLONE") cannot be read, so who the slot belongs to is unknown; inspect the claim file beside the slot"
      return 1
      ;;
  esac
  task=$FM_TREEHOUSE_SLOT_OWNER_ID
  fm_task_id_path_safe "$task" || {
    teardown_by_path_why "the owner claim of pool slot $(fm_refuse_text "$TEARDOWN_BY_PATH_CLONE") names an id that is not a task id"
    return 1
  }
  fm_local_firstmate_state_dirs "$STATE" || {
    teardown_by_path_unread "$FM_LOCAL_FIRSTMATE_ERROR"
    return 1
  }
  for state_dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    if [ -f "$state_dir/$task.meta" ] && [ ! -L "$state_dir/$task.meta" ]; then
      teardown_by_path_why "pool slot $(fm_refuse_text "$TEARDOWN_BY_PATH_CLONE") is claimed by task $task, whose record is live in $(fm_refuse_text "$state_dir"); tear that task down with bin/fm-teardown.sh $task"
      return 1
    fi
  done
}

# The audit record, data/record-less-copy-removals.log: UTC time, bundle record id,
# clone, copy, HEAD and the proof (landed, or the stored bundle), tab separated.
# Written once every proof has passed and before anything is removed, so a removal
# that began always has its line; a line for the same id, copy and HEAD is not
# written twice. It records that the removal was authorized and never stands in
# for a proof: a rerun proves everything again.
teardown_by_path_audit() {  # <copy> <head> <proof>
  local record="$DATA/$TEARDOWN_BY_PATH_LOG" clone
  clone=$(fm_refuse_text "$TEARDOWN_BY_PATH_CLONE")
  mkdir -p "$DATA" 2>/dev/null || return 1
  teardown_held_copies_record_shape_ok "$record" || return 1
  if [ -f "$record" ] && FM_BP_ID=$ID FM_BP_COPY=$1 FM_BP_HEAD=$2 awk -F'\t' \
      '$2 == ENVIRON["FM_BP_ID"] && $4 == ENVIRON["FM_BP_COPY"] && $5 == ENVIRON["FM_BP_HEAD"] { f = 1 } END { exit !f }' "$record" 2>/dev/null; then
    echo "teardown: the audit record for this copy and HEAD is already in $record" >&2
    return 0
  fi
  { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ID" "$clone" "$1" "$2" "$3" >> "$record"; } 2>/dev/null
}

# The by-path exception to the held-task rule (teardown_bundle_require_captain_call)
# replaces "a task owns this copy and no captain decision is pending". Its harm is
# losing an owner's work or unlanded work, so it is judged here, at the exception,
# row by row, whatever ran before it, each row by the owner of that proof (none is
# written twice):
#   H1 a live task record in any local home names the copy; H5 a process runs in
#      it; H6 a Vernant creation lock's launcher may be alive
#      (teardown_foreign_copy_unowned)
#   H2 a live task's claim on the copy's pool slot, a claim naming this run's own
#      record id included (teardown_by_path_claim)
#   H3 another registered worktree, or a Git repository no clone registers, a bare
#      one included, under ignored folders such as .claude too
#      (teardown_by_path_inner)
#   H4 the copy's own unlanded commits are not all in the verified bundle
#      (teardown_bundle_record and teardown_bundle_verify, the route's own
#      verification), or the open captain call does not name every recorded tip
#      (teardown_bundle_captain_call)
#   H5 a process holds a file open in it (teardown_by_path_holders)
#   H7 the tree is not clean and stable, or holds an ignored file that exists
#      nowhere else outside .claude and .opencode, which the removal preserves
#      whole (fm_task_copy_preserve, teardown_preservable_ignored)
# Locating the copy, the audit record, the path lock and the lack of any --force
# are the route's mechanics, not the widened harm, and stay where they are. Any row
# that holds, or cannot be read, refuses; the refusal names it (a row whose input
# cannot be read as rule inspection-unavailable, never a policy row), and
# TEARDOWN_BY_PATH_EXCEPTION_WHY, _RULE, _PID and _HELD keep that reason, and the
# process it names, for the final refusal.
TEARDOWN_BY_PATH_EXCEPTION_WHY=
TEARDOWN_BY_PATH_EXCEPTION_RULE=
TEARDOWN_BY_PATH_EXCEPTION_PID=
TEARDOWN_BY_PATH_EXCEPTION_HELD=
teardown_by_path_exception_clear() {  # <bundle> <required-tips, space separated>
  local copy=$TEARDOWN_BY_PATH_COPY rc=0 why='' why_rule='' unique reason_before=${TEARDOWN_BUNDLE_REASON:-}
  TEARDOWN_BY_PATH_EXCEPTION_WHY=
  TEARDOWN_BY_PATH_EXCEPTION_RULE=
  fm_task_copy_preserve "$PROJ" "$ID" "$copy" 0 || rc=$?
  if [ "$rc" = 1 ]; then
    why_rule=${FM_TASK_COPY_STABLE:-inspection-unavailable}
    [ -z "$FM_TASK_COPY_DIRTY" ] || why_rule='copy-preserved'
    why="it $FM_TASK_COPY_REASON"
  elif ! unique=$(teardown_preservable_ignored "$copy"); then
    why_rule='inspection-unavailable'
    why="its ignored files could not be listed"
  elif [ -n "$unique" ]; then
    why_rule='copy-ignored-files'
    why="it holds ignored files that exist nowhere else: $(fm_refuse_text "$(printf '%s\n' "$unique" | LC_ALL=C sort -u | tr '\n' ' ')")"
  elif ! teardown_foreign_copy_unowned "$copy"; then
    why_rule=$TEARDOWN_FOREIGN_RULE
    why=$TEARDOWN_FOREIGN_WHY
  elif ! teardown_by_path_holders "$copy"; then
    why_rule=${TEARDOWN_BY_PATH_WHY_RULE:-process-cwd-owner}
    why=$TEARDOWN_BY_PATH_WHY
  elif ! teardown_by_path_claim; then
    why_rule=${TEARDOWN_BY_PATH_WHY_RULE:-active-record-owner}
    why=$TEARDOWN_BY_PATH_WHY
  elif ! teardown_by_path_inner "$copy"; then
    why_rule=${TEARDOWN_BY_PATH_WHY_RULE:-registered-copy-proven}
    why=$TEARDOWN_BY_PATH_WHY
  elif ! teardown_bundle_record; then
    why_rule='inspection-unavailable'
    why=$TEARDOWN_BUNDLE_REASON
  else
    # shellcheck disable=SC2086 # Tips are full hex object names, one word each.
    teardown_bundle_verify "$copy" "$(printf '%s\n' $2)"
    if [ -n "$TEARDOWN_BUNDLE_REASON" ]; then
      why_rule='copy-preserved'
      why="the bundle no longer proves the copy's commits: $TEARDOWN_BUNDLE_REASON"
    else
      # shellcheck disable=SC2086 # Recorded tips are full hex object names.
      if ! teardown_bundle_captain_call "$1" $TEARDOWN_BUNDLE_TIPS >/dev/null; then
        why_rule='copy-preserved'
        why="no open captain-held call names the bundle and every recorded tip"
      fi
    fi
  fi
  TEARDOWN_BUNDLE_REASON=$reason_before
  TEARDOWN_BY_PATH_WHY=
  TEARDOWN_BY_PATH_WHY_RULE=
  [ -n "$why" ] || return 0
  TEARDOWN_BY_PATH_EXCEPTION_WHY=$why
  TEARDOWN_BY_PATH_EXCEPTION_RULE=$why_rule
  TEARDOWN_BY_PATH_EXCEPTION_PID=$TEARDOWN_FOREIGN_PID
  TEARDOWN_BY_PATH_EXCEPTION_HELD=$TEARDOWN_FOREIGN_HOLDER_FILE
  teardown_bundle_refuse "$1: the by-path exception to the held-task rule does not apply: $why"
}

# A copy whose directory is gone. Never removes anything; says what it found.
teardown_by_path_missing() {
  local copy=$TEARDOWN_BY_PATH_COPY record="$DATA/$TEARDOWN_BY_PATH_LOG" line='' stamp head proof rc=0
  teardown_by_path_locate "$copy" || rc=$?
  case "$rc" in
    0)
      teardown_by_path_why "$(fm_refuse_text "$copy") is gone but $(fm_refuse_text "$TEARDOWN_BY_PATH_CLONE") still registers it; this mode never prunes a registration - once it is checked, git -C $(fm_refuse_text "$TEARDOWN_BY_PATH_CLONE") worktree prune clears it"
      return 1
      ;;
    1) ;;
    *)
      teardown_by_path_why "$(fm_refuse_text "$copy") is gone, but $TEARDOWN_BY_PATH_UNREADABLE, so whether a clone still registers it is unknown"
      return 1
      ;;
  esac
  if [ -f "$record" ]; then
    line=$(FM_BP_COPY=$copy awk -F'\t' '$4 == ENVIRON["FM_BP_COPY"] { l = $0 } END { print l }' "$record" 2>/dev/null) || line=
  fi
  if [ -z "$line" ]; then
    teardown_by_path_why "there is no copy at $(fm_refuse_text "$copy"), and no audit record in $(fm_refuse_text "$record") names it"
    return 1
  fi
  IFS=$'\t' read -r stamp _ _ _ head proof <<< "$line"
  echo "teardown: $(fm_refuse_text "$copy") is already gone, and this run removed nothing: the audit record in $(fm_refuse_text "$record") shows its removal was authorized at $stamp for HEAD $head (proof: $proof)." >&2
}

# A copy Vernant's creation lock holds goes through Vernant's closeout driver, never
# a plain removal. The driver and its plan are asked here, before the audit line, so
# a release the driver would decline is refused before any protected step.
teardown_by_path_driver_ready() {  # <clone> <copy>
  local rc=0
  teardown_copy_lock_file "$2" || rc=$?
  [ "$rc" = 0 ] || return 0
  if ! teardown_closeout_ready_in "$1"; then
    teardown_by_path_why "Vernant's creation lock holds $(fm_refuse_text "$2"), and $TEARDOWN_CLOSEOUT_OUT, so it cannot be released"
    return 1
  fi
  teardown_closeout_plan_allows "$1" "$2" && return 0
  teardown_by_path_why "Vernant's creation lock holds $(fm_refuse_text "$2"), and $TEARDOWN_CLOSEOUT_PLAN_WHY"
  return 1
}

teardown_by_path_run() {
  local copy=$TEARDOWN_BY_PATH_COPY head proof rc
  teardown_by_path_init || return 1
  fm_refuse_if_gate_agent
  CONTROL_LOCK="$STATE/.teardown-copy-$TEARDOWN_BY_PATH_HASH.lock"
  trap teardown_release_locks EXIT
  fm_lock_try_acquire "$CONTROL_LOCK" || {
    teardown_by_path_why "another teardown --copy run holds $(fm_refuse_text "$copy") ($(fm_refuse_text "$CONTROL_LOCK"))"
    return 1
  }
  CONTROL_LOCK_HELD=1
  fm_lease_guard "$ID" "teardown (fm-teardown --copy)"
  if [ ! -e "$copy" ] && [ ! -L "$copy" ]; then
    teardown_by_path_missing
    return
  fi
  rc=0
  teardown_by_path_locate "$copy" || rc=$?
  case "$rc" in
    0) ;;
    1)
      teardown_by_path_why "$(fm_refuse_text "$copy") is not a worktree registered strictly inside a project clone of this home ($(fm_refuse_text "$FM_HOME")/projects) or a Treehouse slot of one; a slot, a clone, an unregistered directory and a path elsewhere are never removed here"
      return 1
      ;;
    *)
      teardown_by_path_why "$TEARDOWN_BY_PATH_UNREADABLE, so whether it registers $(fm_refuse_text "$copy") is unknown"
      return 1
      ;;
  esac
  teardown_by_path_holders "$copy" || return 1
  teardown_by_path_inner "$copy" || return 1
  teardown_by_path_claim || return 1
  TEARDOWN_FOREIGN_COPIES=("$copy")
  teardown_by_path_prove "$copy" || return 1
  teardown_by_path_driver_ready "$TEARDOWN_BY_PATH_CLONE" "$copy" || return 1
  # Proved again, as the ordinary release does, and the holder scan repeated, as the last
  # steps before the audit line and the removal. The reused proof re-reads only working
  # directories (pids_with_cwd_under), so a process that began holding a file open in the
  # copy after the first scan is seen only by this scan. TEARDOWN_RETURN_SLOT stays empty:
  # the clone is neither returned nor swept, so it adds no scan root, no removal root and no
  # HEAD the bundle must also hold.
  teardown_by_path_prove "$copy" || return 1
  teardown_by_path_holders "$copy" || return 1
  head=$FM_TASK_COPY_HEAD
  proof=landed
  [ -z "$TEARDOWN_BUNDLE_SWEEP_PROOF" ] || proof="bundle $(fm_refuse_text "$TEARDOWN_BUNDLE_SWEEP_PROOF")"
  teardown_by_path_audit "$copy" "$head" "$proof" || {
    teardown_by_path_why "the audit record $(fm_refuse_text "$DATA/$TEARDOWN_BY_PATH_LOG") cannot be written, and nothing is removed without it"
    return 1
  }
  # retained: .claude and .opencode are kept whole, so nothing unique there is lost and a
  # Claude-made copy is not refused for its settings files.
  teardown_foreign_copy_dispose "$TEARDOWN_BY_PATH_CLONE" "$copy" retained || return 1
  echo "teardown: removed record-less copy $(fm_refuse_text "$copy") (HEAD $head, proof: $proof); audit record: $(fm_refuse_text "$DATA/$TEARDOWN_BY_PATH_LOG")" >&2
}

# The foreign-copy proof, with its typed refusal. Returns 1 after recording why.
teardown_by_path_prove() {  # <copy>
  local copy=$1
  TEARDOWN_BUNDLE_SWEEP_PROOF=
  TEARDOWN_BY_PATH_EXCEPTION_WHY=
  teardown_foreign_copy_prove "$copy" && return 0
  [ -z "$TEARDOWN_FOREIGN_DIAG" ] || printf '%s\n' "$TEARDOWN_FOREIGN_DIAG" >&2
  # A refusal by the by-path exception names its own row, not the generic landing
  # envelope the proof sets after it.
  if [ -n "$TEARDOWN_BY_PATH_EXCEPTION_WHY" ]; then
    TEARDOWN_FOREIGN_RULE=$TEARDOWN_BY_PATH_EXCEPTION_RULE
    TEARDOWN_FOREIGN_WHY=$TEARDOWN_BY_PATH_EXCEPTION_WHY
    TEARDOWN_FOREIGN_PID=$TEARDOWN_BY_PATH_EXCEPTION_PID
    TEARDOWN_FOREIGN_HOLDER_FILE=$TEARDOWN_BY_PATH_EXCEPTION_HELD
  fi
  teardown_refuse_copy "$TEARDOWN_FOREIGN_RULE" "copy $copy is not removed: $TEARDOWN_FOREIGN_WHY." "$copy"
  teardown_by_path_why "$(fm_refuse_text "$copy did not pass every proof (rule=$TEARDOWN_FOREIGN_RULE)${TEARDOWN_FOREIGN_WHY:+: $TEARDOWN_FOREIGN_WHY}")"
  return 1
}

teardown_by_path_main() {
  local rc=0
  TEARDOWN_BY_PATH_WHY=
  teardown_by_path_run || rc=$?
  if [ "$rc" != 0 ] && [ -n "$TEARDOWN_BY_PATH_WHY" ]; then
    teardown_by_path_refuse "$TEARDOWN_BY_PATH_WHY" || true
  fi
  return "$rc"
}
