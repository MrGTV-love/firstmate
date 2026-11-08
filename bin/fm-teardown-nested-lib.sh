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
# is not removed either: teardown_retained_accept judges the harm itself and the
# task closes around the untouched copy, recorded in the copy sweep's receipt
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
# reason) and this teardown closes the task around, untouched (see
# teardown_retained_accept), and the facts of the last record read or written.
TEARDOWN_RETAINED=()
TEARDOWN_RETAINED_REASON=cleanup_ignored_payload_archived_tree_retained
TEARDOWN_RETAINED_RECORD=
TEARDOWN_RETAINED_PRESERVE=
TEARDOWN_RETAINED_DIR=
TEARDOWN_RETAINED_SUFFIX=
TEARDOWN_RETAINED_BUILD=0
TEARDOWN_PRE_SNAPSHOT=
TEARDOWN_RETAINED_UNHELD_REASON="the ignored files are not held byte for byte in a preserve"
TEARDOWN_RETAINED_UNIQUE=
TEARDOWN_RET_HEAD=
TEARDOWN_RET_STATUS=
TEARDOWN_RET_PAYLOAD=
# The facts of the last matching record of a kept own copy that teardown refused
# after the driver answered (see teardown_retained_refused_matches).
TEARDOWN_REFUSED_RECORD=
TEARDOWN_REFUSED_REASON=
TEARDOWN_REFUSED_UNIQUE=
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
    lock-launcher-owner) printf 'Is launcher %s, named in the creation lock on %s, still running, and who owns it?' "${TEARDOWN_FOREIGN_PID:-unknown}" "$2" ;;
    creation-lock-owner) printf 'Who owns the creation lock on %s, and may it be released?' "$2" ;;
    nonforced-removal) printf 'What retained disposition covers the contents Git still protects in %s? Preserve this copy; no forced removal is authorized.' "$2" ;;
    registered-copy-proven) printf 'Which task and home retain the work in %s, or what verified landing covers it? No discard or forced removal is authorized.' "$2" ;;
    ignored-bytes-preserved) printf "This run was forced or used a legacy record, so no completing command is printed. Once readable source and writable preservation storage are restored, which of the owner's own flags apply when the owner re-runs this teardown?" ;;
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

# The process environment as NUL-split lines, read from the kernel, for a ps that
# cannot be used. Prints nothing and fails when the environment cannot be read.
teardown_process_env_lines() {  # <pid>
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$1" <<'PY'
import sys, ctypes, ctypes.util, struct
pid = int(sys.argv[1])
libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
mib = (ctypes.c_int * 3)(1, 49, pid)
size = ctypes.c_size_t(0)
if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0:
    sys.exit(1)
buf = ctypes.create_string_buffer(size.value)
if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0:
    sys.exit(1)
data = buf.raw[:size.value]
argc = struct.unpack("i", data[:4])[0]
parts = data[4:].split(b"\0")
i = 0
while i < len(parts) and parts[i] != b"": i += 1
while i < len(parts) and parts[i] == b"": i += 1
env = [p for p in parts[i + argc:] if p]
if not env:
    sys.exit(1)
sys.stdout.buffer.write(b"\n".join(env) + b"\n")
PY
}

# The marker value bin/fm-spawn.sh exports for this task's worker session:
# FM_TASK_INBOX=<physical state directory>/<task-id>.inbox. Every process the
# worker session starts inherits it.
teardown_owner_marker() {
  local state_real
  state_real=$(cd "$STATE" 2>/dev/null && pwd -P) || return 1
  printf 'FM_TASK_INBOX=%s/%s.inbox\n' "$state_real" "$ID"
}

# Does process <pid>'s own readable environment carry the marker? The environment of
# an Apple platform binary (/bin/sleep, /bin/zsh, /usr/bin/git) is hidden from other
# processes on macOS, so a missing marker proves nothing by itself.
teardown_process_env_marked() {  # <pid>
  local pid=$1 expected out env_file
  expected=$(teardown_owner_marker) || return 1
  out=$(LC_ALL=C ps -ww -E -p "$pid" -o command= 2>/dev/null) || out=
  case "$out" in *" $expected"|*" $expected "*) return 0 ;; esac
  env_file=${FM_PROC_ROOT_OVERRIDE:-/proc}/$pid/environ
  if [ -r "$env_file" ]; then
    out=$(tr '\0' '\n' < "$env_file" 2>/dev/null) || out=
  else
    out=$(teardown_process_env_lines "$pid" 2>/dev/null) || return 1
  fi
  case $'\n'"$out" in *$'\n'"$expected"$'\n'*) return 0 ;; esac
  return 1
}

# The record of the task's own processes, written once at the start of a teardown
# while the worker is alive: one "<pid><TAB><birth identity>" line each.
teardown_owned_record_path() {
  printf '%s/%s.teardown-owned\n' "$STATE" "$ID"
}

# Is <pid> in the owned record with the same birth identity (pid AND start time)? A
# recycled pid has another start time and proves nothing.
teardown_process_recorded() {  # <pid>
  local pid=$1 rec recorded current line
  rec=$(teardown_owned_record_path)
  { [ -f "$rec" ] && [ ! -L "$rec" ] && [ -r "$rec" ]; } || return 1
  # The record is read first: a pid it does not name is never recorded, so the process
  # table is asked for its birth identity only for a pid the record names (fewer ps
  # calls for every other process at a root, same decision).
  recorded=$(awk -F'\t' -v p="$pid" '$1 == p { print substr($0, length($1) + 2) }' "$rec")
  [ -n "$recorded" ] || return 1
  current=$(task_process_identity "$pid" 2>/dev/null) || return 1
  [ -n "$current" ] || return 1
  while IFS= read -r line; do
    [ "$line" != "$current" ] || return 0
  done <<< "$recorded"
  return 1
}

# Is process <pid> proved to be this task's own, without reading an Apple binary's
# environment? Any one of: its readable environment carries the marker; it is in the
# owned record with a matching birth identity; a live parent chain reaches such a
# process. Anything else is not proved: the caller refuses by name and leaves it
# running, and a foreign process is never ended.
teardown_process_proved_own() {  # <pid>
  local cur=$1 hops=0
  while [ -n "$cur" ] && [ "$cur" -gt 1 ] 2>/dev/null && [ "$hops" -lt 64 ]; do
    teardown_process_env_marked "$cur" && return 0
    teardown_process_recorded "$cur" && return 0
    cur=$(LC_ALL=C ps -o ppid= -p "$cur" 2>/dev/null | tr -d '[:space:]') || return 1
    hops=$((hops + 1))
  done
  return 1
}

# Writes the owned record from the live processes: every descendant (by live
# parent chain) of a process whose environment carries the marker, the marker
# bearers included, except this teardown's own process and its ancestors. Run once
# at the start of a teardown, before anything is reaped or any endpoint is closed.
# Entries already recorded stay; nothing is added when no bearer is alive, so the
# record is never extended after the worker is gone. Failure to read the process
# table records nothing and is not an error (unrecorded processes stay unproved).
teardown_owned_record_write() {
  local rec expected table ancestors cur pids line pid identity tmp
  rec=$(teardown_owned_record_path)
  expected=$(teardown_owner_marker) || return 0
  table=$(LC_ALL=C ps -A -ww -E -o pid=,ppid=,command= 2>/dev/null) || return 0
  [ -n "$table" ] || return 0
  ancestors=" $$ "
  cur=$$
  while [ -n "$cur" ] && [ "$cur" -gt 1 ] 2>/dev/null; do
    cur=$(LC_ALL=C ps -o ppid= -p "$cur" 2>/dev/null | tr -d '[:space:]') || break
    [ -z "$cur" ] || ancestors="$ancestors$cur "
  done
  pids=$(printf '%s\n' "$table" | awk -v mk="$expected" -v anc="$ancestors" '
    { parent[$1] = $2; if (index(" " $0 " ", " " mk " ") > 0) mark[$1] = 1 }
    END {
      changed = 1
      while (changed) {
        changed = 0
        for (p in parent) if (!(p in mark) && (parent[p] in mark)) { mark[p] = 1; changed = 1 }
      }
      for (p in mark) if (index(anc, " " p " ") == 0) print p
    }') || return 0
  [ -n "$pids" ] || return 0
  tmp=$(mktemp "${rec}.XXXXXX" 2>/dev/null) || return 0
  { [ -f "$rec" ] && [ ! -L "$rec" ] && cat "$rec"; } > "$tmp" 2>/dev/null || true
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    identity=$(task_process_identity "$pid" 2>/dev/null) || continue
    [ -n "$identity" ] || continue
    printf '%s\t%s\n' "$pid" "$identity" >> "$tmp"
  done <<< "$pids"
  LC_ALL=C sort -u "$tmp" > "$tmp.sorted" 2>/dev/null && mv -- "$tmp.sorted" "$rec" || true
  rm -f -- "$tmp" "$tmp.sorted"
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
      [ "$owned_path" != "$root" ] || ! teardown_process_proved_own "$owned_pid" || TEARDOWN_OWN_SCAN+="$owned_pid"$'\t'"$owned_path"$'\n'
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

# Prints ignored <entry> of <copy> without the class: whole when it holds none of
# those directories, otherwise split only as far as needed to leave them out.
teardown_entry_without_regenerable() {  # <copy> <entry>
  local copy=$1 entry=$2 found child
  found=$(teardown_regenerable_dirs "$copy/$entry") || return 1
  if [ -z "$found" ]; then
    printf '%s\n' "$entry"
    return 0
  fi
  [ "$found" != "$copy/$entry" ] || return 0
  for child in "$copy/$entry"/* "$copy/$entry"/.[!.]* "$copy/$entry"/..?*; do
    { [ -e "$child" ] || [ -L "$child" ]; } || continue
    teardown_entry_without_regenerable "$copy" "$entry/${child##*/}" || return 1
  done
}

teardown_print_entry() {  # <copy> <entry>
  printf '%s\n' "$2"
}

# Ignored entries no commit holds that must be preserved before removal.
# Symlinks, caches, virtual environments, Firstmate's own hook files, graft's
# generated output (teardown_graft_generated) and regenerable build output are
# derived machinery and are skipped; every other entry is printed for
# teardown_preserve_ignored to copy. A sweep release of a proven copy names a mode,
# and both modes leave out the regenerable class at any depth: releasable applies
# that to the list above, and all mode starts from every ignored entry, so the
# unlocked sweep can preserve the disposable bytes without widening this owner's
# disposable classification.
teardown_preservable_ignored() {  # <copy> [all|releasable]
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
teardown_bundle_refuse() {  # <predicate> [hint]
  echo "teardown: bundle preservation unavailable: $1." >&2
  [ -z "${2:-}" ] || echo "Create a self-contained external bundle with git -C <copy> bundle create <external-bundle> --all, then record its path, SHA-256 and advertised tips in $DATA/$ID/preservation-bundles.tsv using bin/fm-teardown.sh's header recipe; retry ordinary teardown." >&2
  return 1
}

# Only the stored copy must survive this cleanup. A home can itself be a
# registered worktree or live below a pool; neither makes its data disposable.
# Resolve parents physically so aliases into actual removal roots still refuse.
teardown_bundle_external() {  # <copy> <stored-bundle>
  local copy=$1 bundle=$2 parent path field root
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
  local roots=() labels=() label i
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
    case "$path" in "$root"/*|"$field"/*)
      case "$label" in
        state) TEARDOWN_BUNDLE_REASON="bundle is inside task state $root" ;;
        copy) TEARDOWN_BUNDLE_REASON="bundle is inside task copy $root" ;;
        *) TEARDOWN_BUNDLE_REASON="bundle is inside task scratch $root" ;;
      esac
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
  if [ "$rc" -ge 2 ]; then
    teardown_bundle_refuse "$1: the captain's held calls cannot be read completely"
    return 1
  fi
  reason=$(teardown_bundle_hold_reason "$1" "$2" "$3")
  title="Land or drop the bundle-preserved commits of $ID"
  if [ "$held" = 1 ]; then
    teardown_bundle_refuse "$1: task $ID is held for the captain on another question, and no open captain-held task's hold reason names the bundle and every recorded tip"
    {
      printf 'File the land-or-drop call as its own task, then retry ordinary teardown:'
      printf ' %q' bin/fm-captain-hold.sh hold "$ID-bundle" --title "$title" \
        --origin "$ID" --owner captain --reason "$reason"
      printf '\n'
    } >&2
  elif fm_backlog_row_probe "$DATA" "$ID"; then
    if [ "${FM_BACKLOG_ROW_STATE%% *}" = "done" ]; then
      teardown_bundle_refuse "$1: task $ID's backlog row is closed, so it cannot hold the captain's land-or-drop call"
      return 1
    fi
    teardown_bundle_refuse "$1: task $ID is not held for the captain's land-or-drop call naming the bundle and every recorded tip"
    {
      printf 'Hold it for the captain, then retry ordinary teardown:'
      printf ' %q' bin/fm-captain-hold.sh hold "$ID" --owner captain --reason "$reason"
      printf '\n'
    } >&2
  elif [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
    [ -z "${PROJ:-}" ] || repo=(--repo "${PROJ##*/}")
    teardown_bundle_refuse "$1: task $ID has no backlog row to hold the captain's land-or-drop call naming the bundle and every recorded tip"
    {
      printf 'File the land-or-drop call as its row, then retry ordinary teardown:'
      printf ' %q' bin/fm-captain-hold.sh hold "$ID" --title "$title" ${repo[@]+"${repo[@]}"} --owner captain --reason "$reason"
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

# <ref> itself must carry a locally-only commit, or delivery proof is still
# required. Coverage includes only this cleanup's HEADs and deleted branch refs,
# never unrelated unheld branches in the shared repository.
teardown_bundle_preserved() {  # <copy> <ref> [hint]
  local copy=$1 ref=$2 hint=${3:-} record="$DATA/$ID/preservation-bundles.tsv"
  local bundle source hash tips tip own required side heads advertised digest stored
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

# Copies every entry teardown_preservable_ignored prints for <copy> in the given
# mode into $DATA/$ID/nested-copy-preserved/<copy-path-sha256> and records each file's
# SHA-256 in its SHA256SUMS. The new copy is built in a staging directory and
# replaces an earlier preserve of the same copy only after every entry is copied
# and hashed, so a failed run never costs the earlier one. Returns 1 when
# anything cannot be listed, copied or hashed, after removing the one staging
# directory it built, and the caller then refuses the copy rather than removing
# unpreserved content.
teardown_preserve_ignored() {  # <copy> [all|releasable] [<directory suffix>] [no-replace]
  local copy=$1 root dest stage entries entry file hash suffix=${3:-} keep=${4:-}
  entries=$(teardown_preservable_ignored "$copy" "${2:-}") || return 1
  [ -n "$entries" ] || return 0
  hash=$(printf '%s' "$copy" | teardown_ignored_sha256) || return 1
  root="$DATA/$ID/nested-copy-preserved"
  dest="$root/$hash$suffix"
  stage="$root/.staging-$hash$suffix"
  rm -rf "$stage" || return 1
  (
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
    if [ "$keep" = no-replace ]; then
      # An existing preserve is never removed or replaced: the new one is written
      # beside it, and a name already taken is a failure, not an overwrite.
      [ ! -e "$dest" ] && [ ! -L "$dest" ] || return 1
    else
      rm -rf "$dest" || return 1
    fi
    mv "$stage" "$dest" || return 1
  ) || {
    rm -rf "$stage"
    return 1
  }
  echo "teardown: preserved ignored files from $(fm_refuse_text "$copy") in $dest" >&2
}

# Does an active record, a running process, or a live lock launcher outside this
# teardown own <copy>? Returns 1 with TEARDOWN_FOREIGN_WHY set when so or when
# that cannot be told.
teardown_foreign_copy_unowned() {  # <copy>
  local copy=$1 rc=0 pids pid
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
  local own hit dir common own_common rc status
  for own in ${TEARDOWN_NESTED_COPIES[@]+"${TEARDOWN_NESTED_COPIES[@]}"}; do
    [ -d "$own" ] || continue
    if ! own_common=$(git -C "$own" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
      teardown_refuse_copy inspection-unavailable "the Git directory of task $ID's nested copy $own cannot be read, so what it holds cannot be proved; nothing was removed." "$own"
      return 1
    fi
    status=0
    hit=$(find -P "$own" -mindepth 2 -name .git ! -path "$own/.git/*" -print 2>/dev/null) || status=$?
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      dir=$(dirname "$hit")
      rc=0
      common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || rc=$?
      case "$rc:$common" in
        0:"$own_common"|0:"$own_common"/modules/*|0:"$own_common"/worktrees/*/modules/*) continue ;;
      esac
      teardown_refuse_copy registered-copy-proven "pool slot ${TEARDOWN_RETURN_SLOT:-$own} would lose Git repository $dir inside task $ID's nested copy $own, which holds work no task record proves landed; its commits would have no ref left; nothing was removed." "$dir"
      return 1
    done <<< "$hit"
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

# The one record of a copy the closeout driver kept: data/copy-sweep/retained/
# <sha256 of the copy path>. bin/fm-copy-sweep.sh writes it before an execute and
# reads it to never run that copy again; teardown_retained_accept writes the
# complete form (the same first four lines, then key=value lines) and
# teardown_retained_matches reads it. Both readers treat a record that no longer
# describes the copy as absent, and a rewrite replaces it in place.
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

# Prints "<sha256><TAB><path>" for every regular file in the NUL-separated "./<path>"
# <list> under <root>, hashing in batches. Fails when a path holds a newline, a
# file cannot be read, or the hasher answers anything else.
teardown_retained_sums() {  # <root> <list>
  local root=$1 list=$2 out line
  local -a hasher=(shasum -a 256)
  command -v shasum >/dev/null 2>&1 || hasher=(sha256sum)
  [ -s "$list" ] || return 0
  [ "$(tr -d '\0' < "$list" | wc -l | tr -d ' ')" = 0 ] || return 1
  out=$(cd "$root" && xargs -0 "${hasher[@]}" < "$list") || return 1
  while IFS= read -r line; do
    [[ $line =~ ^[0-9a-f]{64}\ \ \./ ]] || return 1
    printf '%s\t%s\n' "${line:0:64}" "${line:68}"
  done <<< "$out"
}

# The fingerprint and the preserve comparison are built from NUL-delimited paths
# and from records with an explicit type and explicit lengths, never from command
# substitution or tab or newline framing: a link target keeps its trailing
# newlines and a path keeps its tabs. A path holding a newline cannot be framed by
# the lists around it, so it fails closed (exit 3).
# teardown_retained_digest <root>: reads the NUL-separated "./<path>" list on stdin
# and prints one SHA-256 over, for each path in byte order, its type (F file, L
# symlink, P FIFO), the length and bytes of the path, and the file's own SHA-256
# or the length and bytes of the link target.
teardown_retained_digest() {  # <root>
  perl -e '
    use strict; use warnings; use Digest::SHA;
    my $root = shift; local $/ = "\0";
    my @p = <STDIN>; chomp @p;
    my $d = Digest::SHA->new(256);
    for my $p (sort @p) {
      my $rel = $p; $rel =~ s{^\./}{}; exit 3 if $rel =~ /\n/;
      my $f = "$root/$rel";
      if (-l $f) { my $t = readlink $f; defined $t or exit 2; $d->add("L", length($rel), ":", $rel, "\0", length($t), ":", $t, "\0"); }
      elsif (-f $f) { open(my $fh, "<:raw", $f) or exit 2; my $h = Digest::SHA->new(256); $h->addfile($fh); close $fh; $d->add("F", length($rel), ":", $rel, "\0", $h->hexdigest, "\0"); }
      elsif (-p $f) { $d->add("P", length($rel), ":", $rel, "\0"); }
      else { exit 2 }
    }
    print $d->hexdigest, "\n";
  ' "$1"
}

# teardown_retained_compare <strict|adopt> <copy> <dir>: reads the NUL-separated
# "./<path>" list on stdin and checks that each object of <copy> is held in <dir>
# as the same object: a regular file with the same SHA-256 and a line "<sha256>  <path>"
# in <dir>/SHA256SUMS (adopt mode appends a missing line, never changes a file), a
# symlink with byte-identical target bytes (trailing newlines included), a FIFO.
# Exit 0 when all are held, 1 when one differs or is missing, 2 when none could be
# compared (a path with a newline, an unreadable file).
teardown_retained_compare() {  # <strict|adopt> <copy> <dir>
  perl -e '
    use strict; use warnings; use Digest::SHA;
    my ($mode, $copy, $dir) = @ARGV; local $/ = "\0";
    my @p = <STDIN>; chomp @p;
    my $sumsf = "$dir/SHA256SUMS"; my %have;
    if (open(my $s, "<:raw", $sumsf)) { local $/ = "\n"; while (<$s>) { chomp; $have{$_} = 1 } close $s }
    my @add;
    sub fsha { my $f = shift; open(my $fh, "<:raw", $f) or return undef; my $h = Digest::SHA->new(256); $h->addfile($fh); close $fh; return $h->hexdigest }
    for my $p (@p) {
      my $rel = $p; $rel =~ s{^\./}{}; exit 2 if $rel =~ /\n/;
      my ($c, $d) = ("$copy/$rel", "$dir/$rel");
      if (-l $c) { my $t = readlink $c; defined $t or exit 2; -l $d or exit 1; my $u = readlink $d; defined $u or exit 1; $t eq $u or exit 1 }
      elsif (-f $c) {
        (!-l $d && -f $d) or exit 1;
        my $a = fsha($c); my $b = fsha($d); defined $a && defined $b or exit 2;
        $a eq $b or exit 1;
        my $line = "$a  $rel"; push @add, $line unless $have{$line};
      }
      elsif (-p $c) { (!-l $d && -p $d) or exit 1 }
      else { exit 1 }
    }
    if (@add) { exit 1 if $mode ne "adopt"; open(my $o, ">>:raw", $sumsf) or exit 2; print $o "$_\n" for @add; close $o or exit 2 }
    exit 0;
  ' "$1" "$2" "$3"
}

# One SHA-256 over every file, symlink and FIFO in <copy>'s ignored entries other
# than the regenerable class (all mode of teardown_preservable_ignored), through
# teardown_retained_digest. Fails when any cannot be listed or read.
teardown_retained_payload() {  # <copy>
  local copy=$1 entries entry work rc=0
  local -a named=()
  entries=$(teardown_preservable_ignored "$copy" all) || return 1
  while IFS= read -r entry; do
    [ -z "$entry" ] || named+=("$entry")
  done <<< "$entries"
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
# porcelain status) and TEARDOWN_RET_PAYLOAD: what a retained record must still
# match for the copy to count as unchanged. Fails when any cannot be read.
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

# The directory teardown_preserve_ignored keeps <copy>'s ignored files in. The
# first payload of a copy goes to <sha256 of the copy path>; a later payload that
# the first directory does not hold goes to its own directory beside it, named by
# the first 16 characters of that payload's fingerprint, so no preserved byte is
# ever overwritten or removed.
teardown_retained_preserve_dir() {  # <copy> [payload-sha256]
  local hash
  hash=$(printf '%s' "$1" | teardown_ignored_sha256) || return 1
  printf '%s/%s/nested-copy-preserved/%s%s\n' "$DATA" "$ID" "$hash" "${2:+.${2:0:16}}"
}

# The preserve directory a retained record of <copy> names, or the first
# directory when there is no record.
teardown_retained_preserve_of() {  # <copy>
  local rec preserve=
  rec=$(teardown_retained_receipt "$DATA" "$1") && [ -f "$rec" ] && preserve=$(teardown_retained_fields "$rec" preserve) || true
  [ -n "$preserve" ] || preserve=$(teardown_retained_preserve_dir "$1") || return 1
  printf '%s\n' "$preserve"
}

# Is <entry> a plain path inside <copy> that exists and is reached through no
# symlink? Driver-named paths are never trusted to stay inside the copy.
teardown_retained_entry_ok() {  # <copy> <entry>
  local copy=$1 entry=$2 rest part prefix=
  case "$entry" in ''|/*|*$'\n'*) return 1 ;; esac
  rest=$entry
  while :; do
    part=${rest%%/*}
    case "$part" in ''|.|..) return 1 ;; esac
    prefix=${prefix:+$prefix/}$part
    [ "$prefix" = "$entry" ] || [ ! -L "$copy/$prefix" ] || return 1
    [ "$part" != "$rest" ] || break
    rest=${rest#*/}
  done
  [ -e "$copy/$entry" ] || [ -L "$copy/$entry" ]
}

# Is the driver's own string <raw> a name of an object inside <copy>? Judged as the
# driver wrote it, before any trimming: not empty, not absolute, no empty, "." or
# ".." component (one trailing slash is allowed and marks a directory), no symlink
# in any directory component, and the object exists. A final component that is a
# symlink is accepted only without a trailing slash and only when it resolves to
# a place inside the copy (a name written with a trailing slash must be a real
# directory); one that resolves outside the copy, or nowhere, is refused.
teardown_retained_named_ok() {  # <copy> <raw-name>
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
    copy_real=$(cd "$copy" 2>/dev/null && pwd -P) || return 1
    real=$(perl -MCwd=realpath -e 'my $r = realpath($ARGV[0]); print $r if defined $r' -- "$copy/$body") || return 1
    case "$real" in "$copy_real"/*) ;; *) return 1 ;; esac
    return 0
  fi
  [ -e "$copy/$body" ] || return 1
  [ "$slash" = 0 ] || [ -d "$copy/$body" ]
}

# Byte-checks every file, symlink and FIFO under <entry>... of <copy> against the
# preserve in <dir>: a regular file needs a preserved file with the same SHA-256
# and a line for it in SHA256SUMS, a symlink the same target. In strict mode a
# missing or different preserved entry returns 1. In adopt mode an entry the
# preserve lacks is copied in and hashed (the preserve skips the .claude tree that
# the driver may still call unique); a different one still returns 1, so a
# preserved byte is never overwritten. Returns 2 when anything cannot be listed,
# copied, hashed or written, so no comparison was made.
teardown_retained_cover() {  # <strict|adopt> <copy> <dir> <entry>...
  local mode=$1 copy=$2 dir=$3 p rel work rc=0
  shift 3
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-retained-cover.XXXXXX") || return 2
  teardown_retained_files "$copy" "$work/all" "$@" || rc=2
  : > "$work/reg"
  : > "$work/missing"
  if [ "$rc" = 0 ]; then
    while IFS= read -r -d '' p; do
      rel=${p#./}
      if [ ! -e "$dir/$rel" ] && [ ! -L "$dir/$rel" ]; then
        [ "$mode" = adopt ] || { rc=1; break; }
        printf '%s\0' "$rel" >> "$work/missing" || { rc=2; break; }
      fi
    done < "$work/all"
  fi
  # Adopted entries are copied in one pass, only where the preserve has nothing.
  if [ "$rc" = 0 ] && [ -s "$work/missing" ]; then
    (set -o pipefail; cd "$copy" && tar -cf - --null -T "$work/missing" | tar -xpf - -C "$dir") || rc=2
  fi
  if [ "$rc" = 0 ]; then
    teardown_retained_compare "$mode" "$copy" "$dir" < "$work/all" || rc=$?
  fi
  rm -rf "$work"
  return "$rc"
}

# True when the closeout just run answered as the recorded retained case: exit 3
# is the caller's, and its stdout is one JSON document that refuses with the
# retained reason, names no uncovered path of any kind and, when it names the
# tree it kept, names this copy. Anything else is an ordinary driver refusal. Prints the driver-named
# unique ignored paths, one per line, and sets nothing else.
teardown_closeout_retained_paths() {  # <copy>
  local copy=$1 kept
  command -v jq >/dev/null 2>&1 || return 1
  printf '%s' "$TEARDOWN_CLOSEOUT_STDOUT" | jq -s -e --arg reason "$TEARDOWN_RETAINED_REASON" '
    length == 1 and (.[0] | type == "object")
    and (.[0].allowed == false) and (.[0].reason == $reason)
    and (.[0].ignored_payload_disposition == "archive_then_retain_tree")
    and (.[0].tracked_uncovered_paths == []) and (.[0].uncovered_paths == [])
    and ((.[0].untracked_uncovered_paths // []) == [])
    and ((.[0].unique_ignored_paths | type) == "array")
    and (.[0].unique_ignored_paths | all(type == "string" and length > 0 and (contains("\n") | not)))
  ' >/dev/null 2>&1 || return 1
  kept=$(printf '%s' "$TEARDOWN_CLOSEOUT_STDOUT" | jq -s -r '.[0].retained_worktree_path // empty' 2>/dev/null) || return 1
  if [ -n "$kept" ] && [ "$(fm_task_copy_canonical_dir "$kept" 2>/dev/null)" != "$(fm_task_copy_canonical_dir "$copy" 2>/dev/null)" ]; then
    return 1
  fi
  printf '%s' "$TEARDOWN_CLOSEOUT_STDOUT" | jq -s -r '.[0].unique_ignored_paths[]' 2>/dev/null
}

# Can the retained record of <copy> be written now? (A scratch file in its folder.)
teardown_retained_record_writable() {  # <copy>
  local rec tmp
  rec=$(teardown_retained_receipt "$DATA" "$1") || return 1
  mkdir -p "${rec%/*}" 2>/dev/null || return 1
  tmp=$(mktemp "${rec%/*}/.probe.XXXXXX" 2>/dev/null) || return 1
  rm -f "$tmp"
}

# Prints the first retained record that names task <id> as the one that closed
# around the kept copy, and succeeds; fails when none does.
teardown_retained_closed_by() {  # <data-dir> <task-id>
  local rec
  for rec in "$1"/copy-sweep/retained/*; do
    { [ -f "$rec" ] && [ ! -L "$rec" ] && [ -r "$rec" ]; } || continue
    [ "$(teardown_retained_fields "$rec" task)" = "$2" ] || continue
    printf '%s\n' "$rec"
    return 0
  done
  return 1
}

# Writes the complete retained record for <copy> (see teardown_retained_receipt),
# atomically, from the last teardown_retained_snapshot. The first four lines keep
# the form bin/fm-copy-sweep.sh reads.
teardown_retained_write() {  # <slot> <copy> <lock-sha256> <identity> <preserve-dir>   (unique paths on stdin)
  local rec tmp path
  rec=$(teardown_retained_receipt "$DATA" "$2") || return 1
  mkdir -p "${rec%/*}" || return 1
  tmp=$(mktemp "${rec%/*}/.retained.XXXXXX") || return 1
  {
    printf 'lock-sha256=%s\ncopy=%s\nidentity=%s\n' "$3" "$2" "$4"
    printf "the closeout driver kept this copy (exit 3, %s); task %s verified its ignored payload byte for byte in %s; the copy and its pool slot stay untouched and leased; the driver's --execute-cleanup keeps the tree and writes another archive, so it must not be run again for an unchanged copy; this record adds no disposal, unlock or force route, and removing the copy depends on Vernant's driver\n" \
      "$TEARDOWN_RETAINED_REASON" "$ID" "$5"
    printf 'task=%s\nslot=%s\npreserve=%s\nreason=%s\nclosed-at=%s\nhead=%s\nstatus-sha256=%s\npayload-sha256=%s\n' \
      "$ID" "$1" "$5" "$TEARDOWN_RETAINED_REASON" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$TEARDOWN_RET_HEAD" "$TEARDOWN_RET_STATUS" "$TEARDOWN_RET_PAYLOAD"
    while IFS= read -r path; do
      [ -z "$path" ] || printf 'unique=%s\n' "$path"
    done
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -- "$tmp" "$rec" || { rm -f "$tmp"; return 1; }
  TEARDOWN_RETAINED_RECORD=$rec
}

# The kept route's own clean and landed proof, never the anchor shortcut of
# teardown_own_copy_disposable (an anchor lets a pool return sweep a copy away; here
# nothing is swept, and closing the task over unlanded or uncommitted work is the
# harm): every line of the copy's full porcelain status counts, with only
# Firstmate's two turn-end hook files and the task's own nested copies left out,
# and HEAD must pass teardown_landed (a landed commit, or the recorded verified
# bundle that bin/fm-teardown.sh's header allows for an attended teardown). --force
# does not waive it. Prints the cause and returns 1 when either fails.
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

# True when <copy> has a complete retained record that still describes it: the
# same copy (path and identity), the same creation lock, written by this task,
# and the HEAD, status and ignored payload it recorded. Anything else - no
# record, an older sweep-form record, a different or changed copy, an unreadable
# part - is a record that does not apply, and the copy is assessed afresh. Sets
# TEARDOWN_RETAINED_RECORD, _PRESERVE and _UNIQUE for a record that applies.
teardown_retained_matches() {  # <copy>
  local copy=$1 rec hash='' rcopy='' identity='' actual rc=0 preserve
  TEARDOWN_RETAINED_RECORD=
  TEARDOWN_RETAINED_PRESERVE=
  TEARDOWN_RETAINED_UNIQUE=
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
  teardown_retained_snapshot "$copy" || return 1
  [ "$(teardown_retained_fields "$rec" head)" = "$TEARDOWN_RET_HEAD" ] || return 1
  [ "$(teardown_retained_fields "$rec" status-sha256)" = "$TEARDOWN_RET_STATUS" ] || return 1
  [ "$(teardown_retained_fields "$rec" payload-sha256)" = "$TEARDOWN_RET_PAYLOAD" ] || return 1
  preserve=$(teardown_retained_fields "$rec" preserve)
  [ "$preserve" = "$(teardown_retained_preserve_dir "$copy")" ] || [ "$preserve" = "$(teardown_retained_preserve_dir "$copy" "$TEARDOWN_RET_PAYLOAD")" ] || return 1
  { [ -d "$preserve" ] && [ ! -L "$preserve" ]; } || return 1
  TEARDOWN_RETAINED_RECORD=$rec
  TEARDOWN_RETAINED_PRESERVE=$preserve
  TEARDOWN_RETAINED_UNIQUE=$(teardown_retained_fields "$rec" unique)
}

# Is <copy> one this teardown keeps because the driver kept it?
teardown_copy_retained() {  # <copy>
  local kept
  for kept in ${TEARDOWN_RETAINED[@]+"${TEARDOWN_RETAINED[@]}"}; do
    [ "$kept" != "$1" ] || return 0
  done
  return 1
}

# Is <copy>'s preserve complete? Every entry teardown_preserve_ignored selects and
# every driver-named path (given on stdin) must be there byte for byte; in adopt
# mode the driver-named ones the preserve lacks are copied in first. Returns 3
# when a driver-named path is not a plain path inside the copy, 1 otherwise.
teardown_retained_preserve_check() {  # <strict|adopt> <copy> <dir>   (driver-named paths on stdin)
  local mode=$1 copy=$2 dir=$3 entry paths selected
  local -a named=() chosen=()
  paths=$(cat)
  while IFS= read -r entry; do
    [ -z "$entry" ] || named+=("$entry")
  done <<< "$paths"
  for entry in ${named[@]+"${named[@]}"}; do
    if ! teardown_retained_entry_ok "$copy" "$entry"; then
      echo "REFUSED: Vernant's closeout driver names ignored path $(fm_refuse_text "$entry") of own nested copy $(fm_refuse_text "$copy"), which is not a plain path inside the copy or no longer exists; the task was not closed." >&2
      return 3
    fi
  done
  selected=$(teardown_preservable_ignored "$copy") || return 1
  while IFS= read -r entry; do
    [ -z "$entry" ] || chosen+=("$entry")
  done <<< "$selected"
  teardown_retained_cover strict "$copy" "$dir" ${chosen[@]+"${chosen[@]}"} || return 1
  # Every ignored entry under .claude or .opencode is payload too, named by the
  # driver or not (the ordinary preservation skips those trees): a newly appearing
  # one is copied into this preserve, never over a different preserved byte.
  selected=$(teardown_preservable_ignored "$copy" all | grep -E '^\.(claude|opencode)(/|$)' || true)
  while IFS= read -r entry; do
    [ -z "$entry" ] || named+=("$entry")
  done <<< "$selected"
  [ "${#named[@]}" -gt 0 ] || return 0
  teardown_retained_cover "$mode" "$copy" "$dir" "${named[@]}"
}

# Does the preserve in <dir> hold <copy>'s current bytes: every entry
# teardown_preserve_ignored selects, and every entry an earlier run adopted into
# it (one under no selected entry), wherever the copy still has that entry?
# Returns 1 when one is missing or differs and 2 when the check could not be made.
teardown_retained_preserve_current() {  # <copy> <dir>
  local copy=$1 dir=$2 p rel entry selected
  local -a adopted_paths=() chosen=()
  [ -d "$dir" ] || return 0
  selected=$(teardown_preservable_ignored "$copy") || return 2
  while IFS= read -r entry; do
    [ -z "$entry" ] || chosen+=("$entry")
  done <<< "$selected"
  while IFS= read -r -d '' p; do
    rel=${p#"$dir/"}
    case "$rel" in copy-path|SHA256SUMS) continue ;; esac
    for entry in ${chosen[@]+"${chosen[@]}"}; do
      case "$rel" in "$entry"|"$entry"/*) continue 2 ;; esac
    done
    [ -e "$copy/$rel" ] || [ -L "$copy/$rel" ] || continue
    adopted_paths+=("$rel")
  done < <(find -P "$dir" ! -type d -print0)
  if [ "${#chosen[@]}" -gt 0 ]; then
    teardown_retained_cover strict "$copy" "$dir" "${chosen[@]}" || return $?
  fi
  [ "${#adopted_paths[@]}" -gt 0 ] || return 0
  teardown_retained_cover strict "$copy" "$dir" "${adopted_paths[@]}"
}

# Chooses where the ignored files of <copy> are preserved for this assessment and
# sets TEARDOWN_RETAINED_DIR to it, and TEARDOWN_RETAINED_BUILD to 1 when that
# directory does not exist yet and teardown_preserve_ignored must build it, else
# 0. An existing preserve is never rebuilt, overwritten or removed: the first directory is kept when it already holds the
# copy's current bytes, and a copy whose payload changed since is preserved in its
# own directory beside it.
# Returns 2 when the copy or a preserve could not be read.
teardown_retained_preserve_choose() {  # <copy>
  local copy=$1 base rc=0
  TEARDOWN_RETAINED_DIR=
  TEARDOWN_RETAINED_SUFFIX=
  TEARDOWN_RETAINED_BUILD=0
  base=$(teardown_retained_preserve_dir "$copy") || return 2
  if [ ! -e "$base" ] && [ ! -L "$base" ]; then
    TEARDOWN_RETAINED_DIR=$base
    TEARDOWN_RETAINED_BUILD=1
    return 0
  fi
  [ -d "$base" ] && [ ! -L "$base" ] || return 2
  teardown_retained_preserve_current "$copy" "$base" || rc=$?
  if [ "$rc" = 0 ]; then
    TEARDOWN_RETAINED_DIR=$base
    return 0
  fi
  [ "$rc" = 1 ] || return 2
  teardown_retained_snapshot "$copy" || return 2
  TEARDOWN_RETAINED_DIR=$(teardown_retained_preserve_dir "$copy" "$TEARDOWN_RET_PAYLOAD") || return 2
  TEARDOWN_RETAINED_SUFFIX=.${TEARDOWN_RET_PAYLOAD:0:16}
  if [ ! -e "$TEARDOWN_RETAINED_DIR" ] && [ ! -L "$TEARDOWN_RETAINED_DIR" ]; then
    TEARDOWN_RETAINED_BUILD=1
    return 0
  fi
  [ -d "$TEARDOWN_RETAINED_DIR" ] && [ ! -L "$TEARDOWN_RETAINED_DIR" ] || return 2
}

# Does any own nested copy of the task have a retained record that still applies?
teardown_retained_own_present() {
  local copy rc
  for copy in ${TEARDOWN_NESTED_COPIES[@]+"${TEARDOWN_NESTED_COPIES[@]}"}; do
    [ -d "$copy" ] || continue
    rc=0
    teardown_copy_lock_file "$copy" || rc=$?
    [ "$rc" = 0 ] || continue
    ! teardown_retained_matches "$copy" || return 0
  done
  return 1
}

# The route of a retry for a copy whose retained record still applies: it asks
# the driver nothing, so the driver writes no further archive, and it proves
# again that the preserve holds the copy's current bytes before the task closes.
teardown_retained_confirm() {  # <slot> <copy>
  local copy=$2
  if ! teardown_retained_preserve_check strict "$copy" "$TEARDOWN_RETAINED_PRESERVE" <<< "$TEARDOWN_RETAINED_UNIQUE"; then
    echo "REFUSED: own nested copy $(fm_refuse_text "$copy") is kept by Vernant's closeout driver (record $(fm_refuse_text "$TEARDOWN_RETAINED_RECORD")), but its ignored files are not held byte for byte in $(fm_refuse_text "$TEARDOWN_RETAINED_PRESERVE"); the task was not closed, and the driver was not asked again." >&2
    return 1
  fi
  ! teardown_copy_retained "$copy" || return 0
  TEARDOWN_RETAINED+=("$copy")
  echo "teardown: own nested copy $(fm_refuse_text "$copy") is unchanged since the driver kept it (record $(fm_refuse_text "$TEARDOWN_RETAINED_RECORD")); the driver was not asked again" >&2
}

# The record of a kept own copy that teardown refused after the driver answered
# for it: data/<task>/closeout-refused/<sha256 of the copy path>. Its first three
# lines take the retained record's form (lock hash, copy, identity); key=value
# lines add task, head, status-sha256, payload-sha256, named-sha256, reason,
# refused-at and one unique line per driver-named path. A retry of the copy while
# it still matches asks the driver nothing; any run that asks the driver first
# deletes it.
teardown_retained_refused_path() {  # <copy>
  local hash
  hash=$(printf '%s' "$1" | teardown_ignored_sha256) || return 1
  printf '%s/%s/closeout-refused/%s\n' "$DATA" "$ID" "$hash"
}

# One SHA-256 over each driver-named path (on stdin) and whether it is still a
# plain path inside <copy>.
teardown_retained_named_state() {  # <copy>
  local entry
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if teardown_retained_entry_ok "$1" "$entry"; then
      printf '%s\tok\n' "$entry"
    else
      printf '%s\tbad\n' "$entry"
    fi
  done | teardown_ignored_sha256
}

# Writes the refusal record of <copy> atomically, from a fresh
# teardown_retained_snapshot, naming <reason>.
teardown_retained_refused_write() {  # <copy> <lock-sha256> <identity> <paths> <reason>
  local copy=$1 rec tmp named path
  teardown_retained_snapshot "$copy" || return 1
  named=$(printf '%s\n' "$4" | teardown_retained_named_state "$copy") || return 1
  rec=$(teardown_retained_refused_path "$copy") || return 1
  mkdir -p "${rec%/*}" || return 1
  tmp=$(mktemp "${rec%/*}/.refused.XXXXXX") || return 1
  {
    printf 'lock-sha256=%s\ncopy=%s\nidentity=%s\n' "$2" "$copy" "$3"
    printf 'task=%s\nhead=%s\nstatus-sha256=%s\npayload-sha256=%s\nnamed-sha256=%s\nreason=%s\nrefused-at=%s\n' \
      "$ID" "$TEARDOWN_RET_HEAD" "$TEARDOWN_RET_STATUS" "$TEARDOWN_RET_PAYLOAD" "$named" "$5" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    while IFS= read -r path; do
      [ -z "$path" ] || printf 'unique=%s\n' "$path"
    done <<< "$4"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -- "$tmp" "$rec" || { rm -f "$tmp"; return 1; }
}

teardown_retained_refused_note() {  # <copy> <lock-sha256> <identity> <paths> <reason>
  teardown_retained_refused_write "$@" \
    || echo "warning: the refusal record of own nested copy $(fm_refuse_text "$1") could not be written, so a retry asks Vernant's closeout driver again." >&2
}

# True when <copy> has a refusal record that still describes it: the same copy
# (path and identity), the same creation lock, this task, the HEAD, status and
# ignored payload it recorded, and the same state of each driver-named path.
# Sets TEARDOWN_REFUSED_RECORD, _REASON and _UNIQUE for a record that applies.
teardown_retained_refused_matches() {  # <copy>
  local copy=$1 rec hash='' rcopy='' identity='' actual unique
  TEARDOWN_REFUSED_RECORD=
  TEARDOWN_REFUSED_REASON=
  TEARDOWN_REFUSED_UNIQUE=
  rec=$(teardown_retained_refused_path "$copy") || return 1
  { [ -f "$rec" ] && [ ! -L "$rec" ] && [ -r "$rec" ]; } || return 1
  { IFS= read -r hash && IFS= read -r rcopy && IFS= read -r identity; } < "$rec" || true
  [ "$rcopy" = "copy=$copy" ] || return 1
  actual=$(copy_identity "$copy") || return 1
  [ "$actual" = "${identity#identity=}" ] || return 1
  actual=$(teardown_ignored_sha256 "$TEARDOWN_FOREIGN_LOCK_FILE") || return 1
  [ "$actual" = "${hash#lock-sha256=}" ] || return 1
  [ "$(teardown_retained_fields "$rec" task)" = "$ID" ] || return 1
  teardown_retained_snapshot "$copy" || return 1
  [ "$(teardown_retained_fields "$rec" head)" = "$TEARDOWN_RET_HEAD" ] || return 1
  [ "$(teardown_retained_fields "$rec" status-sha256)" = "$TEARDOWN_RET_STATUS" ] || return 1
  [ "$(teardown_retained_fields "$rec" payload-sha256)" = "$TEARDOWN_RET_PAYLOAD" ] || return 1
  unique=$(teardown_retained_fields "$rec" unique)
  actual=$(printf '%s\n' "$unique" | teardown_retained_named_state "$copy") || return 1
  [ "$(teardown_retained_fields "$rec" named-sha256)" = "$actual" ] || return 1
  TEARDOWN_REFUSED_RECORD=$rec
  TEARDOWN_REFUSED_REASON=$(teardown_retained_fields "$rec" reason)
  TEARDOWN_REFUSED_UNIQUE=$unique
}

# Does the cause of a matching refusal record still hold? The driver-free proofs
# of teardown_retained_accept run again, each printing its cause, so a copy whose
# work has landed since is not refused on the record alone; only the driver's
# answer is taken from the record.
teardown_retained_refused_holds() {  # <copy>
  local copy=$1 entry
  teardown_own_nested_other_repos || return 0
  teardown_retained_copy_proved "$copy" || return 0
  while IFS= read -r entry; do
    [ -z "$entry" ] || teardown_retained_named_ok "$copy" "$entry" || return 0
  done <<< "$TEARDOWN_REFUSED_UNIQUE"
  # A refusal for an unwritable retained record holds while the record still
  # cannot be written; once it can, the answer is asked for again.
  case "$TEARDOWN_REFUSED_REASON" in
    "the retained record could not be written"*) teardown_retained_record_writable "$copy" || return 0; return 1 ;;
  esac
  return 1
}

# The driver kept own nested copy <copy> (teardown_closeout_retained_paths held;
# <paths> are the ignored paths it names unique). Judges the harm directly
# instead of taking the refusal for unique work: the ordinary clean and landed
# proof again now, no other repository inside the nested copies, every ignored
# file byte for byte in the preserve (driver-named paths the preserve skips are
# copied in, never over a different byte), and the copy unchanged while that was
# checked. Only then does it write the retained record and return 0, leaving the
# copy exactly as it was. Returns 1 after printing the cause; nothing is removed.
teardown_retained_accept() {  # <slot> <copy> <lock-sha256> <identity> <paths>
  local slot=$1 copy=$2 lock_hash=$3 identity=$4 paths=$5 dir before rc raw
  # Each named path is judged as the driver wrote it, before the trailing-slash
  # trim below can turn it into a different object.
  while IFS= read -r raw; do
    [ -z "$raw" ] || teardown_retained_named_ok "$copy" "$raw" || {
      teardown_retained_refused_note "$copy" "$lock_hash" "$identity" "$paths" \
        "the driver names an ignored path that is not a plain path inside the copy or no longer exists"
      echo "REFUSED: Vernant's closeout driver names ignored path $(fm_refuse_text "$raw") of own nested copy $(fm_refuse_text "$copy"), which is not a plain path inside the copy, resolves outside it, or no longer exists; the task was not closed." >&2
      return 1
    }
  done <<< "$paths"
  paths=$(printf '%s\n' "$paths" | sed 's#/*$##')
  if ! [[ $lock_hash =~ ^[0-9a-f]{64}$ ]] || ! [[ $identity =~ ^[0-9]+:[0-9]+$ ]]; then
    echo "REFUSED: the creation lock and identity of own nested copy $(fm_refuse_text "$copy") could not be read, so its retained state cannot be recorded; the task was not closed." >&2
    return 1
  fi
  if [ "$(copy_identity "$copy" 2>/dev/null)" != "$identity" ]; then
    echo "REFUSED: own nested copy $(fm_refuse_text "$copy") is not the copy the driver was asked about any more; the task was not closed." >&2
    return 1
  fi
  if ! teardown_own_nested_other_repos; then
    teardown_retained_refused_note "$copy" "$lock_hash" "$identity" "$paths" \
      "the task's nested copies hold another Git repository, or could not be scanned for one"
    return 1
  fi
  if ! teardown_retained_copy_proved "$copy"; then
    teardown_retained_refused_note "$copy" "$lock_hash" "$identity" "$paths" \
      "the copy is not proved landed and clean"
    return 1
  fi
  dir=${TEARDOWN_RETAINED_DIR:-$(teardown_retained_preserve_dir "$copy")} || return 1
  if ! teardown_retained_snapshot "$copy"; then
    echo "REFUSED: the state of own nested copy $(fm_refuse_text "$copy") could not be read, so its retained state cannot be recorded; the task was not closed." >&2
    return 1
  fi
  before="$TEARDOWN_RET_HEAD $TEARDOWN_RET_STATUS $TEARDOWN_RET_PAYLOAD"
  # The state read before the driver was asked is the state the driver answered
  # for: a change during its call (an ignored file the driver may not have
  # archived) is a changed payload, assessed again, and records nothing.
  if [ -n "${TEARDOWN_PRE_SNAPSHOT:-}" ] && [ "$before" != "$TEARDOWN_PRE_SNAPSHOT" ]; then
    echo "REFUSED: own nested copy $(fm_refuse_text "$copy") changed while Vernant's closeout driver ran; the task was not closed, and a retry assesses the changed copy again." >&2
    return 1
  fi
  if [ ! -d "$dir" ]; then
    { mkdir -p "$dir" && printf '%s\n' "$copy" > "$dir/copy-path" && : > "$dir/SHA256SUMS"; } || {
      echo "REFUSED: the preserve directory $(fm_refuse_text "$dir") could not be created; the task was not closed." >&2
      return 1
    }
  fi
  rc=0
  teardown_retained_preserve_check adopt "$copy" "$dir" <<< "$paths" || rc=$?
  if [ "$rc" = 3 ]; then
    teardown_retained_refused_note "$copy" "$lock_hash" "$identity" "$paths" \
      "the driver names an ignored path that is not a plain path inside the copy or no longer exists"
    return 1
  fi
  if [ "$rc" != 0 ]; then
    teardown_retained_refused_note "$copy" "$lock_hash" "$identity" "$paths" \
      "$TEARDOWN_RETAINED_UNHELD_REASON"
    echo "REFUSED: the ignored files of own nested copy $(fm_refuse_text "$copy") that the driver names unique, or that preservation selects, are not held byte for byte in $(fm_refuse_text "$dir"); the task was not closed and the copy was not touched." >&2
    return 1
  fi
  if ! teardown_retained_snapshot "$copy" || [ "$before" != "$TEARDOWN_RET_HEAD $TEARDOWN_RET_STATUS $TEARDOWN_RET_PAYLOAD" ]; then
    echo "REFUSED: own nested copy $(fm_refuse_text "$copy") changed while its ignored files were verified; the task was not closed." >&2
    return 1
  fi
  if ! teardown_retained_write "$slot" "$copy" "$lock_hash" "$identity" "$dir" <<< "$paths"; then
    teardown_retained_refused_note "$copy" "$lock_hash" "$identity" "$paths" \
      "the retained record could not be written"
    echo "REFUSED: the retained record for own nested copy $(fm_refuse_text "$copy") could not be written; the task was not closed, and a retry asks the driver nothing while it still cannot be written." >&2
    return 1
  fi
  rm -f -- "$(teardown_retained_refused_path "$copy")"
  TEARDOWN_RETAINED+=("$copy")
  echo "teardown: Vernant's closeout driver kept own nested copy $(fm_refuse_text "$copy"); its ignored files are verified byte for byte in $(fm_refuse_text "$dir") and the copy is untouched (record $(fm_refuse_text "$TEARDOWN_RETAINED_RECORD"))" >&2
}

# A task that keeps a retained own nested copy never returns its pool slot: the
# slot must stay under a durable lease (a later treehouse get could reset it over
# the copy), and the held-close route then applies to it. A slot another live
# task still works in is not this task's to hold, so a kept copy there refuses.
teardown_retained_hold() {
  [ "${#TEARDOWN_RETAINED[@]}" -gt 0 ] || return 0
  if [ -z "${TEARDOWN_RETURN_SLOT:-}" ]; then
    echo "REFUSED: own nested copy $(fm_refuse_text "${TEARDOWN_RETAINED[0]}") was kept by Vernant's closeout driver (record $(fm_refuse_text "$(teardown_retained_receipt "$DATA" "${TEARDOWN_RETAINED[0]}")")) in pool slot $(fm_refuse_text "${TEARDOWN_PEER_SLOT:-}"), which another live task still works in, so this task cannot hold the slot under its lease; the copy, the slot and the retained record stay as they are, the task was not closed, and a retry asks the driver nothing." >&2
    return 1
  fi
  if [ "${TEARDOWN_SLOT_CUSTODY:-}" != lease ]; then
    echo "REFUSED: pool slot $(fm_refuse_text "$TEARDOWN_RETURN_SLOT") could not be durably leased, and a close that keeps own nested copy $(fm_refuse_text "${TEARDOWN_RETAINED[0]}") never leaves its slot without a durable lease, since a later treehouse get could reset it over the copy; the copy, the slot and the retained record stay as they are, and a retry asks the driver nothing." >&2
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
  local slot=$1 copy=$2 rc=0 lock_hash='' identity='' paths
  teardown_copy_lock_file "$copy" || rc=$?
  if [ "$rc" != 0 ] || ! teardown_vernant_lock_pid "$TEARDOWN_FOREIGN_LOCK" >/dev/null; then
    echo "REFUSED: own nested copy $(fm_refuse_text "$copy") is not locked by Vernant's creation lock any more; it was not removed." >&2
    return 1
  fi
  if teardown_retained_matches "$copy"; then
    teardown_retained_confirm "$slot" "$copy"
    return
  fi
  lock_hash=$(teardown_ignored_sha256 "$TEARDOWN_FOREIGN_LOCK_FILE") || lock_hash=
  identity=$(copy_identity "$copy") || identity=
  if teardown_retained_refused_matches "$copy"; then
    if [ "$TEARDOWN_REFUSED_REASON" = "$TEARDOWN_RETAINED_UNHELD_REASON" ]; then
      # The driver already answered for this unchanged copy; only the preserve did
      # not hold. A new preserve is written beside the others and the recorded
      # answer is accepted again: no driver call, no further tar.
      paths=$TEARDOWN_REFUSED_UNIQUE
      teardown_retained_prepare_preserve "$copy" || return 1
      teardown_retained_accept "$slot" "$copy" "$lock_hash" "$identity" "$paths" && return 0
      return 1
    fi
    if teardown_retained_refused_holds "$copy"; then
      echo "REFUSED: own nested copy $(fm_refuse_text "$copy") is unchanged since Vernant's closeout driver last kept it and teardown refused it: $(fm_refuse_text "$TEARDOWN_REFUSED_REASON") (record $(fm_refuse_text "$TEARDOWN_REFUSED_RECORD")); the driver was not asked again, and the task was not closed." >&2
      return 1
    fi
  fi
  teardown_retained_prepare_preserve "$copy" || return 1
  rm -f -- "$(teardown_retained_refused_path "$copy")"
  rc=0
  teardown_run_closeout "$slot" "$copy" || rc=$?
  if [ "$rc" != 0 ]; then
    if [ "$rc" = 3 ] && paths=$(teardown_closeout_retained_paths "$copy"); then
      teardown_retained_accept "$slot" "$copy" "$lock_hash" "$identity" "$paths" && return 0
    fi
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

# Before the driver is asked (or an answer is accepted again): chooses the preserve
# directory, builds it beside any other (never over one), and takes the snapshot
# the driver's answer will be compared with. Returns 1 after printing a refusal.
teardown_retained_prepare_preserve() {  # <copy>
  local copy=$1 rc=0
  teardown_retained_preserve_choose "$copy" || rc=$?
  if [ "$rc" != 0 ]; then
    echo "REFUSED: the ignored files already preserved for own nested copy $(fm_refuse_text "$copy") in $(fm_refuse_text "$DATA/$ID/nested-copy-preserved") could not be read or checked against the copy; Vernant's closeout driver was not asked, and the task was not closed." >&2
    return 1
  fi
  if [ "$TEARDOWN_RETAINED_BUILD" = 1 ]; then
    teardown_preserve_ignored "$copy" "" "$TEARDOWN_RETAINED_SUFFIX" no-replace || {
      teardown_refuse_copy ignored-bytes-preserved "the ignored files of own nested copy $copy could not be preserved in $DATA/$ID/nested-copy-preserved; it was not removed." "$copy"
      return 1
    }
  fi
  TEARDOWN_PRE_SNAPSHOT=
  if ! teardown_retained_snapshot "$copy"; then
    echo "REFUSED: the state of own nested copy $(fm_refuse_text "$copy") could not be read before the driver was asked; the task was not closed." >&2
    return 1
  fi
  TEARDOWN_PRE_SNAPSHOT="$TEARDOWN_RET_HEAD $TEARDOWN_RET_STATUS $TEARDOWN_RET_PAYLOAD"
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
