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
# Supersedence route. Vernant's no-PR lane cannot release the rebased or squashed
# twin of a merged PR, or a copy whose tip rode into one; only the driver's own
# --pr lane can, and only when an owner attests the copy. The carrier is
# $TEARDOWN_ROUTE_DATA/supersedence-records.tsv in the home that runs the script
# (bin/fm-teardown.sh and bin/fm-copy-sweep.sh set it to their data directory):
# one line per copy of four tab-separated fields - the copy's absolute path, its
# 40-hex tip, the merged PR number (a decimal integer) and the absolute path of a
# Vernant supersedence profile. Blank lines and lines starting with # are ignored.
# No records file is the plain call, exactly as above. A records file that exists but
# cannot be read as a regular file (a directory, a mode that forbids it, a read error)
# says nothing about which copy it names, so every locked copy of that home is held,
# named or not, with the reason naming the file, until it reads again.
# For a copy a line names, teardown_closeout_route uses the route only when all of
# these hold, read afresh at every call (the sweep's plan and execute, teardown's
# entry plan and execute): every line that names the copy speaks for the owner and is judged on its
# own, so a line for another tip of the path (history is not ignored: take the line
# out once it no longer applies), a line with other than four fields, a line that
# leaves the PR or the profile empty or gives a PR that is no decimal integer
# (digits only, no zero and no leading zero, of any length) refuses, and two lines that
# give different PRs or profiles conflict and refuse, whichever comes first; exact
# duplicates of one valid line are one record, and that record binds the copy's full
# live HEAD; the profile is an
# absolute, regular, non-symlink, readable JSON file whose pr is the record's PR
# and whose superseded_tip_sha is the record's tip; and gh, naming the repository
# from the clone's origin URL (GitHub only), shows that PR MERGED with a merge
# commit that the clone has and that is an ancestor of origin/<landing branch>,
# read with git and no fetch; and the copy's own changes are proved landed in that
# merge commit (Content proof, below); and the clone's primary checkout is not on that
# PR's head branch (forge headRefName), where the driver's DONE-state finish would
# switch it to the base branch even on a plan, nor is the clone's own checkout (a linked
# worktree's HEAD) on it, which the pre-entry read refuses (Project lock and checkout,
# below). The landing branch is the remote's own default branch, asked of the remote
# itself (git ls-remote --symref origin HEAD, bounded like the forge read, no fetch)
# and used only when the clone holds refs/remotes/origin/<branch>. The clone's local
# origin/HEAD is never read, because it can be stale, and a local main or master is a
# guess. A recorded base_branch= (TEARDOWN_ROUTE_BASE) must name that same branch or
# the copy is kept. A remote that cannot be read, names no branch, or names one the
# clone has no ref for holds the copy. A forge read that
# fails, times out (FM_TEARDOWN_FORGE_TIMEOUT seconds, 60 when the setting is unset; a
# value that is empty or not a whole number of seconds from 1 to 999999999, written
# without a leading zero, refuses the route with the value named and is never read as
# 60) or cannot be
# parsed is unknown, never merged. The read is bounded by fm_timeout_perl_bound: gh
# runs under a small perl wrapper that leads the bound's process group, waits for gh,
# prints one trailer line with gh's status and kills the whole group, so a descendant
# that outlives gh or holds its output ends with the read and the read never waits for
# one; the bound kills the group at its limit and when the caller goes away, so the
# sweep's plan stop and an interrupted teardown end the read with the caller (it
# needs perl; without perl the read is unknown). The record is read again after the
# forge read and must bind the same PR, profile and tip, and the profile is checked
# again, so a row written while the forge was read holds the copy; the last check and
# the driver's start are not one step. A record that names the copy and fails any of
# these keeps the copy with no driver call and the failed condition named.
#
# Content proof. A copy may carry changes the merge commit M does not hold as the
# same commits (a rebased or squashed twin). The copy's net change is its diff from
# the merge base of its tip T and M, and the route needs exactly one merge base. The
# proof runs no merge machinery: for every path in that diff, M must hold exactly the
# copy's entry (the same mode and the same blob), or no entry where the copy deleted
# the path. The entries are read with git diff-tree --raw and git ls-tree only, which
# run no merge driver, textconv or external diff, so nothing configured in the
# repository (a driver of any name, in any scope) can decide the proof: a copy whose
# change a lying driver would have called landed is kept, and a legitimate twin routes
# under the same configuration. A path that M changed further than the copy is kept
# (Main 1887: so is the separated AUTH_DISABLED twin and a moved file whose blob
# differs; keeping a copy discards nothing), and so is any git command that fails or
# prints output that cannot be parsed. A merge driver found in the configuration is
# reported as a notice, never a refusal. An empty net change is proved; it is not a
# claim that T is an ancestor of M.
#
# Project lock and checkout. The route holds the project lock
# (fm_treehouse_project_lock_path, called on the slot's registered project: the one the
# caller names in TEARDOWN_ROUTE_PROJECT, else the one derived from the slot's git common
# directory; a slot whose own lock key differs from its project's refuses) from its first
# step to the end of the execute, so
# no Firstmate or pipeline code path that takes that lock changes the slot's primary
# checkout meanwhile. The sweep takes it and releases it; teardown borrows its
# caller's hold (TEARDOWN_ROUTE_LOCK_HELD, proved by the lock's pid file naming this
# process), never takes it a second time and never releases it. A claim the pid file
# does not prove, a claim at a path other than the computed lock (there is no fall-through
# to taking that lock), a busy lock or one that cannot be taken keeps the copy before any
# driver call. The checkout is read as its branch, HEAD and its HEAD reflog (one
# read, so the count, the entries and the anchor come from one snapshot) at the
# route's first step (the sweep's plan, teardown's call), immediately before the driver
# is entered, and after each driver call. The first read keeps the newest reflog entry
# as the anchor. Before the driver the route refuses when the pre-entry read shows the
# PR's head branch or any change since the first read; after a call it refuses when the
# branch or HEAD differs, when any reflog entry above the anchor names the PR's head,
# when the anchor no longer stands where it stood (a rewritten or expired log), when
# the anchor is missing, when the reflog cannot be read or is disabled, or when it gained
# any entry at all since the first read (a switch to an unrelated branch and back counts;
# an entry naming the PR's head branch is only named as such). The window is
# published in the route file as soon as it opens, so a plan killed while it is still
# proving leaves it, and a proof that refuses still ends with the same read. In the sweep
# a switch it sees stops the run: the copies still pending are not called or released and
# are reported SKIPPED (teardown_driver_release exits 4). A plan killed at its timeout is
# followed by the parent's own read against that window, in any state, with any new entry
# in the HEAD reflog counting, and by the
# release of the plan's project lock only when its record names the killed plan's pid and
# that pid is gone (teardown_route_lock_reap_killed); otherwise the lock is left for the
# lock library's dead-owner recovery and the reason says so. This detects and does not prevent a switch by an
# actor that does not take the lock (an agent's direct git switch, a person, the
# pipeline's axi sync): a switch after the pre-entry read can reach the driver and is
# reported after the fact, and a switch and restore that wholly precedes the first read
# is not seen. Two narrow kill windows are named residuals (Main 1900), and in both the
# safety property holds and the lock is left for dead-owner recovery: (a) a plan killed
# after it took its project lock and before it published the lock path leaves the lock
# for the lock library's dead-owner recovery, and the parent has no path to record it; (b)
# a plan killed before it published its first file, or before its window opened, leaves
# the parent with no window for that copy, so the parent makes no read after the kill:
# the sweep clears the window before each copy (TEARDOWN_CKO_OPEN=0 in bin/fm-copy-sweep.sh)
# and loads the plan's file only when it exists, and teardown_closeout_route_file_load
# closes the window for an empty copy or a route that is neither pr nor proving, so the
# parent never holds the previous copy's window; and no driver was called, because the
# route enters the driver only after its window opened and was published.
#
# The route's call is closeout_pr.py --cleanup-worktree <copy> [--execute-cleanup]
# --pr <PR> --supersedence-profile <profile> --no-evidence-files, run from the
# slot with the same interpreter and no other option. Its answer has no top-level
# "allowed", so teardown_closeout_route_answer reads the --pr lane's own shape, the
# driver's fifteen-key compact envelope (base_ref, base_strategy, branch_delete,
# branch_reap, cleanup_recovery_reason, cleanup_requested, evidence_digest,
# launch_cwd, next_command, owner, pr, predicates_failed, primary_checkout_repair,
# state, worktree_removed; no other key) whose pr is the called PR: a
# plan allows only on exit 3 with state BLOCKED, predicates_failed exactly
# ["cleanup_not_executed"], cleanup_requested true and worktree_removed false; an
# execute releases only on exit 0 with state DONE or DONE_WITH_SUPERSEDENCE, no
# failed predicate, no recovery reason and worktree_removed true, and the removal
# is proved as for the plain call. Any other exit, shape, silence or parse failure keeps the copy
# with the driver's words and the route and PR named. The driver stays the only
# authority and is not widened. The lane's side effects are the driver's own
# (closeout_pr.py at Vernant origin/main 1cf0e36): git fetch --prune origin in
# the clone, for a plan too; the verification report, one JSON file per copy in
# the clone's ignored directory .claude/bug-evidence/tree-presence/, written only
# when a cleanup target is named, the state is DONE or DONE_WITH_SUPERSEDENCE and
# --verify-only is off, whatever --no-evidence-files says, so a plan can write it
# (closeout_pr.py:2340-2341, verify_worktree.py:281-293); the evidence files, a
# JSON and a markdown file in the clone's ignored directory
# .claude/bug-evidence/pr-closeout/, which --no-evidence-files suppresses and the
# route always passes, so a route call writes none; the closeout-state marker, which the driver
# writes on any call, a plan too, whose state reaches DONE (its --verify-only mode
# refuses --cleanup-worktree and still writes the marker, so no quieter plan
# exists); a repair of the clone's primary checkout, which never runs because the
# route is refused while that checkout is on the PR's head branch
# (--repair-primary-base is never passed); and deletion of the PR's local branch
# after an executed cleanup that removed the worktree (closeout_pr.py:3268-3353).
# The driver keeps the branch and names the reason when the worktree was not
# removed (worktree_not_removed), the branch is protected (protected_branch) or
# absent (local_branch_absent), the PR is not MERGED (pr_not_merged), the tip
# cannot be read (branch_tip_unresolvable), the tip is neither the PR head nor an
# ancestor of it (branch_tip_not_contained_in_pr_head, or branch_ancestry_unproven
# when the probe cannot settle), another worktree has the branch checked out
# (checked_out_in_worktree, or worktree_list_failed), the landing proof fails
# (landing_not_proven), or a remote counterpart has appeared
# (remote_counterpart_alive); a delete that errors is reported as state failed.
# It deletes by compare-and-swap at the exact tip it read just before, in one
# update-ref transaction that also needs refs/remotes/origin/<branch> to be absent,
# so a branch that moved keeps its commits (branch_moved_during_delete).
#
# Requires bin/fm-task-copy-lib.sh, bin/fm-lock-lib.sh, bin/fm-refuse-lib.sh,
# bin/fm-pr-lib.sh and bin/fm-timeout-lib.sh first,
# and runs inside bin/fm-teardown.sh, whose globals (PROJ, ID, DATA, META,
# STATE, WT, TASK_TMP, FORCE, KIND, LEGACY_RECORD_GIVEN, TEARDOWN_NESTED_COPIES,
# TEARDOWN_RETURN_SLOT, TEARDOWN_PEER_SLOT, TEARDOWN_HELD_SLOT) and functions
# (teardown_landed, pids_with_cwd_under, task_process_identity,
# task_process_identity_matches, task_record_process_signal) it uses.
# bin/fm-copy-sweep.sh also calls teardown_preserve_ignored, with DATA set to its
# data directory and ID to a per-release id, for a copy it proved on its own, and
# teardown_run_closeout (with TEARDOWN_ROUTE_DATA set to that directory) for such
# a copy that is locked.

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

# The supersedence route's owner. A record in $TEARDOWN_ROUTE_DATA/
# supersedence-records.tsv binds a copy's exact tip to a merged PR and a Vernant
# profile; the header owns the format and the conditions. teardown_closeout_route
# decides, for one call of the driver, between the plain call (no record names
# the copy), the --pr route (a record names it and every condition holds) and a
# non-use (a record names it and one condition fails, so the driver is not
# called and the reason names that condition).
TEARDOWN_ROUTE_DATA=
TEARDOWN_ROUTE_BASE=
TEARDOWN_ROUTE_TIP=
TEARDOWN_CLOSEOUT_ROUTE=
TEARDOWN_CLOSEOUT_ROUTE_PR=
TEARDOWN_CLOSEOUT_ROUTE_PROFILE=
TEARDOWN_CLOSEOUT_ROUTE_WHY=

# 0: one record binds <copy> at its live tip (PR and profile set), 1: no record
# names <copy> (the plain call), 2: a record names it and cannot be used (WHY set).
# No records file at all is the plain call. A records file that exists but cannot
# be read as a regular file is not: whether a row names the copy is then unknown, so
# every copy is held with the reason named until the file reads again. Every row that
# names the copy speaks for the owner, so each is judged on its own before it is
# compared with another: a row for another tip of the same path, a row that leaves
# the PR or the profile empty, a PR that is no decimal integer and two rows that
# give different PRs or profiles all refuse, whichever comes first. Exact duplicates
# of one valid row are one record.
teardown_route_record() {  # <copy>
  local copy=$1 dir=${TEARDOWN_ROUTE_DATA:-} file content line rest first pr='' profile='' count bound=0
  local -a fields named=()
  TEARDOWN_CLOSEOUT_ROUTE_PR=
  TEARDOWN_CLOSEOUT_ROUTE_PROFILE=
  TEARDOWN_ROUTE_TIP=
  [ -n "$dir" ] || return 1
  file=$dir/supersedence-records.tsv
  if [ -d "$dir" ] && [ ! -x "$dir" ]; then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the supersedence records file $file cannot be read (its directory cannot be searched), so whether a record names this copy is unknown"
    return 2
  fi
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    return 1
  fi
  if [ ! -f "$file" ] || ! content=$(cat -- "$file" 2>/dev/null); then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the supersedence records file $file cannot be read as a regular file, so whether a record names this copy is unknown"
    return 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | '#'*) continue ;; esac
    [[ $line =~ ^[[:space:]]*$ ]] && continue
    first=${line%%$'\t'*}
    [ "$first" = "$copy" ] && named+=("$line")
  done <<< "$content"
  [ "${#named[@]}" -gt 0 ] || return 1
  TEARDOWN_ROUTE_TIP=$(git -C "$copy" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || TEARDOWN_ROUTE_TIP=
  if [[ ! $TEARDOWN_ROUTE_TIP =~ ^[0-9a-f]{40}$ ]]; then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the live tip of the copy cannot be read"
    return 2
  fi
  for line in "${named[@]}"; do
    fields=()
    rest=$line
    while :; do
      case "$rest" in
        *$'\t'*) fields+=("${rest%%$'\t'*}"); rest=${rest#*$'\t'} ;;
        *) fields+=("$rest"); break ;;
      esac
    done
    count=${#fields[@]}
    if [ "$count" != 4 ]; then
      TEARDOWN_CLOSEOUT_ROUTE_WHY="a record naming the copy has $count tab-separated fields, not four"
      return 2
    fi
    if [ "${fields[1]}" != "$TEARDOWN_ROUTE_TIP" ]; then
      TEARDOWN_CLOSEOUT_ROUTE_WHY="a record names this copy at tip ${fields[1]:-?} but the copy is at $TEARDOWN_ROUTE_TIP (a row for another tip of the same path holds the copy; take that row out once it no longer applies)"
      return 2
    fi
    if [ -z "${fields[2]}" ] || [ -z "${fields[3]}" ]; then
      TEARDOWN_CLOSEOUT_ROUTE_WHY="a record that binds this copy at its tip leaves the PR or the profile empty"
      return 2
    fi
    if [[ ! ${fields[2]} =~ ^[1-9][0-9]*$ ]]; then
      TEARDOWN_CLOSEOUT_ROUTE_WHY="the record's PR field '${fields[2]}' is not a decimal integer"
      return 2
    fi
    if [ "$bound" = 0 ]; then
      bound=1
      pr=${fields[2]}
      profile=${fields[3]}
    elif [ "$pr" != "${fields[2]}" ] || [ "$profile" != "${fields[3]}" ]; then
      TEARDOWN_CLOSEOUT_ROUTE_WHY="two records bind this copy at its tip to different PRs or profiles"
      return 2
    fi
  done
  TEARDOWN_CLOSEOUT_ROUTE_PR=$pr
  TEARDOWN_CLOSEOUT_ROUTE_PROFILE=$profile
}

# True when <profile> is an absolute, regular, non-symlink, readable JSON file
# whose pr is <pr> and whose superseded_tip_sha is <tip>. WHY names what failed.
teardown_route_profile_ok() {  # <profile> <pr> <tip>
  local profile=$1 pr=$2 tip=$3 got
  if [ "${profile#/}" = "$profile" ]; then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the profile path '$profile' is not absolute"
  elif [ -L "$profile" ] || [ ! -f "$profile" ]; then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the profile $profile is not a regular file (a symlink or a missing path does not qualify)"
  elif [ ! -r "$profile" ] || ! jq -e 'type == "object"' "$profile" >/dev/null 2>&1; then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the profile $profile cannot be read as a JSON object"
  elif ! got=$(jq -r 'if (.pr | type) == "number" then (.pr | tostring) else "none" end' "$profile" 2>/dev/null) || [ "$got" != "$pr" ]; then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the profile $profile names PR ${got:-none}, not PR $pr"
  elif ! got=$(jq -r 'if (.superseded_tip_sha | type) == "string" then .superseded_tip_sha else "none" end' "$profile" 2>/dev/null) || [ "$got" != "$tip" ]; then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the profile $profile binds superseded_tip_sha ${got:-none}, not the copy's tip $tip"
  else
    return 0
  fi
  return 1
}

# --- the route's lock, checkout observation and content proof ------------------
# The slot's project lock (bin/fm-project-lock-lib.sh) is held for the whole of a
# route call. A caller that already holds it names its path in
# TEARDOWN_ROUTE_LOCK_HELD (bin/fm-teardown.sh does, after teardown_acquire_project_lock);
# the route then borrows that hold once the lock's pid file proves it names this
# process, never takes it again (fm_project_lock_try is not re-entrant) and never
# releases it (fm_project_lock_release releases whatever lock it is given). A caller
# that does not hold it (the sweep) has the route take it and release it on every exit.
# A claimed hold that the pid file does not prove, and a lock that cannot be taken,
# keep the copy before the driver is asked.
TEARDOWN_ROUTE_LOCK_HELD=
TEARDOWN_ROUTE_LOCK_OWN=0
TEARDOWN_ROUTE_LOCK_PATH=
# The lock key comes from the one owner function that every other actor uses
# (fm_treehouse_project_lock_path), called on the slot's registered project: the project
# directory that the caller names in TEARDOWN_ROUTE_PROJECT (teardown does: its own hold
# is keyed the same way), else the project derived from the slot's git common directory
# (a Treehouse slot shares its project's; the sweep's pool slots carry no project path).
# A slot whose own lock key differs from its project's (its origin differs) refuses.
TEARDOWN_ROUTE_PROJECT=
teardown_route_project_of() {  # <slot>: prints the project directory the slot belongs to
  local common top
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  common=$(CDPATH='' cd -- "$common" 2>/dev/null && pwd -P) || return 1
  case "$common" in */.git) top=${common%/.git} ;; *) return 1 ;; esac
  [ -d "$top" ] || return 1
  printf '%s\n' "$top"
}
teardown_route_lock_take() {  # <slot> <copy>
  local slot=$1 lock cur pid keydir slotlock
  TEARDOWN_ROUTE_LOCK_OWN=0
  TEARDOWN_ROUTE_LOCK_PATH=
  keydir=${TEARDOWN_ROUTE_PROJECT:-}
  [ -n "$keydir" ] || keydir=$(teardown_route_project_of "$slot") || keydir=$slot
  if ! lock=$(fm_treehouse_project_lock_path "$keydir" 2>/dev/null); then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the project lock of $keydir cannot be resolved, so the route cannot hold it"
    return 1
  fi
  if [ "$keydir" != "$slot" ]; then
    if ! slotlock=$(fm_treehouse_project_lock_path "$slot" 2>/dev/null) || [ "$slotlock" != "$lock" ]; then
      TEARDOWN_CLOSEOUT_ROUTE_WHY="the slot $slot has its own project lock key ${slotlock:-(unresolved)}, which differs from its project's $keydir ($lock): its origin differs from the registered project's, so the route cannot hold the project's lock for it"
      return 1
    fi
  fi
  if [ -n "${TEARDOWN_ROUTE_LOCK_HELD:-}" ]; then
    # A claimed hold is the one named lock or it is refused: a claim at another path never
    # falls through to taking the computed lock.
    if [ "$TEARDOWN_ROUTE_LOCK_HELD" != "$lock" ]; then
      TEARDOWN_CLOSEOUT_ROUTE_WHY="the caller claims to hold the project lock $TEARDOWN_ROUTE_LOCK_HELD, but the lock of the slot's project is $lock, so the claimed hold is not proved"
      return 1
    fi
    pid=$(cat -- "$lock/pid" 2>/dev/null) || pid=
    if ! fm_current_pid cur || [ -z "$pid" ] || [ "$pid" != "$cur" ]; then
      TEARDOWN_CLOSEOUT_ROUTE_WHY="the caller claims to hold the project lock $lock but its pid file does not name this process (${pid:-no pid}), so the hold is not proved"
      return 1
    fi
    TEARDOWN_ROUTE_LOCK_PATH=$lock
    return 0
  fi
  if ! fm_project_lock_try "$lock" "supersedence route $2" 2>/dev/null; then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the project lock $lock could not be taken (busy or an error), so the route cannot hold the slot's checkout against its other users"
    return 1
  fi
  TEARDOWN_ROUTE_LOCK_OWN=1
  TEARDOWN_ROUTE_LOCK_PATH=$lock
}
# After a plan was killed at its timeout, the parent releases the plan's project lock only
# when the lock's record names the killed plan's pid and that pid is gone. Any other record,
# or a live owner, is left alone for the lock library's own dead-owner recovery. The note
# says what happened and is kept in TEARDOWN_ROUTE_LOCK_NOTE.
TEARDOWN_ROUTE_LOCK_NOTE=
teardown_route_lock_reap_killed() {  # <lock> <killed-pid>
  local lock=$1 pid=$2 recorded
  TEARDOWN_ROUTE_LOCK_NOTE=
  [ -n "$lock" ] && [ -n "$pid" ] || return 0
  [ -e "$lock" ] || [ -L "$lock" ] || return 0
  recorded=$(cat -- "$lock/pid" 2>/dev/null) || recorded=
  if [ "$recorded" != "$pid" ]; then
    TEARDOWN_ROUTE_LOCK_NOTE="the project lock $lock names ${recorded:-no pid}, not the killed plan $pid, so it was left alone"
    return 0
  fi
  if fm_pid_alive "$pid"; then
    TEARDOWN_ROUTE_LOCK_NOTE="the project lock $lock is owned by $pid, which is still alive, so it was left to its owner"
    return 0
  fi
  if fm_lock_reap_dead_link "$lock" >/dev/null 2>&1; then
    TEARDOWN_ROUTE_LOCK_NOTE="the killed plan's project lock $lock was released after its owner $pid was found gone"
    return 0
  fi
  TEARDOWN_ROUTE_LOCK_NOTE="the killed plan's project lock $lock was left for the lock library's dead-owner recovery (its owner $pid is gone, but the reaper did not release it)"
}
teardown_route_lock_release() {
  if [ "$TEARDOWN_ROUTE_LOCK_OWN" = 1 ]; then
    fm_project_lock_release "$TEARDOWN_ROUTE_LOCK_PATH" || true
  fi
  TEARDOWN_ROUTE_LOCK_OWN=0
  TEARDOWN_ROUTE_LOCK_PATH=
}

# The primary checkout is read at the route's first step (the sweep's plan; a
# teardown's call), once more immediately before the driver is entered, and after
# each call. A read is the checkout's branch, HEAD and its HEAD reflog, taken in one
# git call; the first read keeps the newest reflog entry as the anchor
# (TEARDOWN_CKO_ANCHOR). The route refuses when the branch or HEAD differs from the
# first read, when any reflog entry above the anchor names the PR's head branch, when
# the anchor no longer stands where it stood or is missing, when the branch is the PR's
# head at the pre-entry read, or when the reflog cannot be read or is disabled. The
# window is held in TEARDOWN_CKO_* for one copy; the sweep carries it from its plan to
# its execute through the route file.
TEARDOWN_CKO_OPEN=0
TEARDOWN_CKO_COPY=
TEARDOWN_CKO_BRANCH=
TEARDOWN_CKO_HEAD=
TEARDOWN_CKO_POS=
TEARDOWN_CKO_ANCHOR=
TEARDOWN_CKO_NOW_BRANCH=
TEARDOWN_CKO_NOW_HEAD=
TEARDOWN_CKO_NOW_POS=
TEARDOWN_CKO_NOW_ANCHOR=
TEARDOWN_CKO_NOW_LOG=
TEARDOWN_CLOSEOUT_SWITCHED=0
TEARDOWN_ROUTE_HEADREF=
TEARDOWN_ROUTE_MERGE=
teardown_route_checkout_state() {  # <slot>
  local slot=$1 cfg
  cfg=$(git -C "$slot" config --get core.logAllRefUpdates 2>/dev/null) || cfg=
  case "$cfg" in false | never | 0 | no | off) return 1 ;; esac
  git -C "$slot" reflog exists HEAD >/dev/null 2>&1 || return 1
  TEARDOWN_CKO_NOW_BRANCH=$(git -C "$slot" symbolic-ref --quiet --short HEAD 2>/dev/null) || TEARDOWN_CKO_NOW_BRANCH='(detached)'
  TEARDOWN_CKO_NOW_HEAD=$(git -C "$slot" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || return 1
  # One read: the count, the newest entry (the anchor) and every entry come from the
  # same snapshot, so nothing that lands later can displace an entry, and a failed read
  # is a failed state. A line is the selector (a timestamp), the commit and the subject.
  TEARDOWN_CKO_NOW_LOG=$(git -C "$slot" reflog show --date=raw --format='%gd|%H|%gs' HEAD 2>/dev/null) || return 1
  [ -n "$TEARDOWN_CKO_NOW_LOG" ] || return 1
  TEARDOWN_CKO_NOW_POS=$(printf '%s\n' "$TEARDOWN_CKO_NOW_LOG" | wc -l | tr -d ' ')
  TEARDOWN_CKO_NOW_ANCHOR=${TEARDOWN_CKO_NOW_LOG%%$'\n'*}
}
teardown_route_checkout_open() {  # <slot> <copy>
  if [ "$TEARDOWN_CKO_OPEN" = 1 ] && [ "$TEARDOWN_CKO_COPY" = "$2" ]; then
    return 0
  fi
  if ! teardown_route_checkout_state "$1"; then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the clone's primary checkout or its HEAD reflog cannot be read (or the reflog is disabled), so a later switch of the checkout could not be detected"
    return 1
  fi
  TEARDOWN_CKO_OPEN=1
  TEARDOWN_CKO_COPY=$2
  TEARDOWN_CKO_BRANCH=$TEARDOWN_CKO_NOW_BRANCH
  TEARDOWN_CKO_HEAD=$TEARDOWN_CKO_NOW_HEAD
  TEARDOWN_CKO_POS=$TEARDOWN_CKO_NOW_POS
  TEARDOWN_CKO_ANCHOR=$TEARDOWN_CKO_NOW_ANCHOR
}
teardown_route_checkout_close() {
  TEARDOWN_CKO_OPEN=0
  TEARDOWN_CKO_COPY=
}
# 0 when the checkout is as the first read left it. Otherwise 1 with CKO_WHY naming
# the switch. <prhead> is the PR's head branch (forge headRefName).
TEARDOWN_CKO_WHY=
teardown_route_checkout_check() {  # <slot> <prhead>
  local slot=$1 prhead=$2 delta entries entry subject word at first
  local -a words=()
  TEARDOWN_CKO_WHY=
  if [ "$TEARDOWN_CKO_OPEN" != 1 ] || [ -z "$TEARDOWN_CKO_ANCHOR" ] || ! teardown_route_checkout_state "$slot"; then
    TEARDOWN_CKO_WHY="the clone's primary checkout or its HEAD reflog cannot be read, or the first read left no anchor, so a switch could not be ruled out"
    return 1
  fi
  if [ "$TEARDOWN_CKO_NOW_BRANCH" != "$TEARDOWN_CKO_BRANCH" ] || [ "$TEARDOWN_CKO_NOW_HEAD" != "$TEARDOWN_CKO_HEAD" ]; then
    TEARDOWN_CKO_WHY="the clone's primary checkout moved from $TEARDOWN_CKO_BRANCH at ${TEARDOWN_CKO_HEAD:0:12} to $TEARDOWN_CKO_NOW_BRANCH at ${TEARDOWN_CKO_NOW_HEAD:0:12} during the route"
    return 1
  fi
  delta=$((TEARDOWN_CKO_NOW_POS - TEARDOWN_CKO_POS))
  if [ "$delta" -lt 0 ]; then
    TEARDOWN_CKO_WHY="the HEAD reflog of the clone's primary checkout shrank during the route, so a switch could not be ruled out"
    return 1
  fi
  # The newest entry of the first read must still stand <delta> entries from the top of
  # this one; if it does not, the log was rewritten, expired or reordered and the entries
  # made since cannot be told apart from older ones. The entries since are the lines above it.
  at=$(sed -n "$((delta + 1))p" <<< "$TEARDOWN_CKO_NOW_LOG") || at=
  if [ "$at" != "$TEARDOWN_CKO_ANCHOR" ]; then
    TEARDOWN_CKO_WHY="the newest HEAD reflog entry of the route's first read no longer holds its place in the reflog (it was rewritten, expired or reordered), so the entries made since cannot be told apart from older ones"
    return 1
  fi
  [ "$delta" -gt 0 ] || return 0
  entries=$(sed -n "1,${delta}p" <<< "$TEARDOWN_CKO_NOW_LOG") || {
    TEARDOWN_CKO_WHY="the entries of the clone's HEAD reflog made since the route's first read cannot be read, so a switch could not be ruled out"
    return 1
  }
  # Any new entry in the HEAD reflog is a change in the window (Main 1887, Main 1900): one
  # that names the PR's head branch is named as such; any other, a switch to an unrelated
  # branch and back included, is a change all the same, whether or not the PR's head branch
  # is known yet.
  first=
  while IFS= read -r entry; do
    subject=${entry#*|}
    subject=${subject#*|}
    [ -n "$first" ] || first=$subject
    words=()
    read -r -a words <<< "$subject"
    for word in ${words[@]+"${words[@]}"}; do
      if [ -n "$prhead" ] && [ "$word" = "$prhead" ]; then
        TEARDOWN_CKO_WHY="a HEAD reflog entry of the clone's primary checkout since the route's first read names the PR's head branch $prhead ($subject)"
        return 1
      fi
    done
  done <<< "$entries"
  TEARDOWN_CKO_WHY="the HEAD reflog of the clone's primary checkout gained $delta entries since the route's first read (the newest: $first), a change in the window, so a switch could not be ruled out"
  [ -n "$prhead" ] || TEARDOWN_CKO_WHY="$TEARDOWN_CKO_WHY (the PR's head branch is not known yet)"
  return 1
}
# The read made immediately before the driver is entered: the checkout must not be on
# the PR's head branch, and must still be as the first read left it.
teardown_route_checkout_pre_entry() {  # <slot> <prhead>
  local now
  now=$(git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null) || now=
  if [ -n "$2" ] && [ "$now" = "$2" ]; then
    TEARDOWN_CKO_WHY="the clone's primary checkout is on the PR's head branch $2 at the read made just before the driver was entered"
    return 1
  fi
  teardown_route_checkout_check "$1" "$2"
}

# The content proof: positive proof by read-only git that the merge commit <merge>
# carries what the copy at <tip> adds, judged path by path against the merge base B of
# the two (exactly one). It runs no merge machinery: for every path the copy changed
# against B, the merge commit must hold exactly the copy's entry (the same mode and the
# same blob), or no entry where the copy deleted the path. The entries are read with
# git diff-tree --raw and git ls-tree, which run no merge driver, textconv or external
# diff, so nothing configured in the repository can decide the proof. A path that the
# merge commit changed further, a mode or type change, any git command that fails and any
# git output that cannot be parsed (a record with no path, one cut short, one without the
# raw shape, its leading colon included) prove nothing: only a clean end of the stream is
# the end of the changes. Sets
# WHY naming the first unproven path.
teardown_route_content_prove_in() {  # <tmpdir> <slot> <tip> <merge>
  local tmp=$1 slot=$2 tip=$3 merge=$4 base bases raw meta path om nm osha nsha st
  local mentry mmode msha line unparsable
  unparsable="git printed output for the copy's changes that cannot be parsed, so their content cannot be proved landed"
  bases=$(git -C "$slot" merge-base --all "$tip" "$merge" 2>/dev/null) || bases=
  if [ -z "$bases" ] || [ "$(printf '%s\n' "$bases" | wc -l | tr -d ' ')" != 1 ]; then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the copy's tip and the merge commit $merge of the PR do not have exactly one merge base, so the content of the copy cannot be proved landed"
    return 1
  fi
  base=$bases
  raw=$tmp/raw
  git -C "$slot" diff-tree -r --no-renames --no-ext-diff --no-textconv -z --raw "$base" "$tip" > "$raw" 2>/dev/null || {
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the changes of the copy cannot be read, so their content cannot be proved landed"
    return 1
  }
  exec 3< "$raw"
  while :; do
    # A record is a metadata word and a path, each ended by a NUL. A clean end of the
    # stream is the end of the changes (a genuine empty change included); a record that
    # is cut short, has no path or does not have the raw shape is unknown, never empty.
    meta=
    if ! IFS= read -r -d '' meta <&3; then
      [ -z "$meta" ] && break
      exec 3<&-
      TEARDOWN_CLOSEOUT_ROUTE_WHY=$unparsable
      return 1
    fi
    path=
    if ! IFS= read -r -d '' path <&3 || [ -z "$path" ]; then
      exec 3<&-
      TEARDOWN_CLOSEOUT_ROUTE_WHY=$unparsable
      return 1
    fi
    if [[ ! $meta =~ ^:[0-7]{6}\ [0-7]{6}\ [0-9a-f]{40,64}\ [0-9a-f]{40,64}\ [ADMT]$ ]]; then
      exec 3<&-
      TEARDOWN_CLOSEOUT_ROUTE_WHY=$unparsable
      return 1
    fi
    meta=${meta#:}
    read -r om nm osha nsha st <<< "$meta"
    git -C "$slot" --literal-pathspecs ls-tree -z "$merge" -- "$path" > "$tmp/ls" 2>/dev/null || {
      exec 3<&-
      TEARDOWN_CLOSEOUT_ROUTE_WHY="the merge commit's entry at $path cannot be read, so the content of the copy cannot be proved landed"
      return 1
    }
    mentry=
    exec 4< "$tmp/ls"
    while :; do
      line=
      if ! IFS= read -r -d '' line <&4; then
        [ -z "$line" ] && break
        exec 3<&- 4<&-
        TEARDOWN_CLOSEOUT_ROUTE_WHY=$unparsable
        return 1
      fi
      if [[ ! $line =~ ^[0-7]{6}\ [a-z]+\ [0-9a-f]{40,64}$'\t'.+$ ]]; then
        exec 3<&- 4<&-
        TEARDOWN_CLOSEOUT_ROUTE_WHY=$unparsable
        return 1
      fi
      [ "${line#*$'\t'}" = "$path" ] && mentry=${line%%$'\t'*}
    done
    exec 4<&-
    if [ "$st" = D ]; then
      if [ -n "$mentry" ]; then
        exec 3<&-
        TEARDOWN_CLOSEOUT_ROUTE_WHY="the copy deletes $path but the merge commit still has it, so that change is not proved landed"
        return 1
      fi
      continue
    fi
    read -r mmode _ msha <<< "$mentry"
    if [ -z "$mentry" ] || [ "$mmode" != "$nm" ] || [ "$msha" != "$nsha" ]; then
      exec 3<&-
      TEARDOWN_CLOSEOUT_ROUTE_WHY="the merge commit does not hold the copy's entry at $path (the same mode and the same blob), so that change is not proved landed"
      return 1
    fi
  done
  exec 3<&-
  return 0
}

# A merge driver in the repository's configuration is reported, never a reason to refuse:
# the content proof runs no merge, so a driver plays no part in it. The names are kept in
# TEARDOWN_ROUTE_DRIVER_FACT and one notice line is printed when there are any.
TEARDOWN_ROUTE_DRIVER_FACT=
teardown_route_driver_fact() {  # <slot>
  local out names
  TEARDOWN_ROUTE_DRIVER_FACT=
  out=$(git -C "$1" config --get-regexp '^merge\..*\.driver$' 2>/dev/null) || return 0
  names=$(printf '%s\n' "$out" | awk '{ print $1 }' | sort -u | tr '\n' ' ')
  TEARDOWN_ROUTE_DRIVER_FACT=${names% }
  [ -z "$TEARDOWN_ROUTE_DRIVER_FACT" ] || printf 'note: the repository'"'"'s configuration defines the merge driver %s; the content proof runs no merge, so it plays no part\n' "$TEARDOWN_ROUTE_DRIVER_FACT" >&2
}
teardown_route_content_proven() {  # <slot> <tip> <merge>
  local tmp rc=0
  if ! tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-route-content.XXXXXX"); then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="no temporary directory is available for the content proof, so it cannot run"
    return 1
  fi
  teardown_route_content_prove_in "$tmp" "$@" || rc=$?
  rm -rf -- "$tmp"
  teardown_route_driver_fact "$1"
  return "$rc"
}

# The remote's own default branch, asked of the remote at the time with
# git ls-remote --symref origin HEAD (a read-only ref query that downloads no
# objects, not a fetch), bounded by <seconds>. Sets TEARDOWN_ROUTE_REMOTE_DEFAULT;
# a read that fails, times out or names no branch is unknown. The clone's local
# origin/HEAD is never read: it can be stale.
TEARDOWN_ROUTE_REMOTE_DEFAULT=
teardown_route_remote_default() {  # <slot> <seconds>
  local out rc=0 first
  TEARDOWN_ROUTE_REMOTE_DEFAULT=
  command -v perl >/dev/null 2>&1 || {
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the remote's default branch cannot be read here (perl is not available to bound the read), so the landing branch is unknown"
    return 1
  }
  out=$(fm_timeout_perl_bound "$2" env GIT_TERMINAL_PROMPT=0 git -C "$1" ls-remote --symref origin HEAD 2>/dev/null </dev/null) || rc=$?
  if [ "$rc" != 0 ]; then
    if fm_timed_out "$rc"; then
      TEARDOWN_CLOSEOUT_ROUTE_WHY="the read of the remote's default branch timed out after ${2}s, so the landing branch is unknown"
    else
      TEARDOWN_CLOSEOUT_ROUTE_WHY="the read of the remote's default branch failed (exit $rc), so the landing branch is unknown"
    fi
    return 1
  fi
  first=$(printf '%s\n' "$out" | sed -n 's/^ref:[[:space:]]*refs\/heads\/\(.*\)[[:space:]][[:space:]]*HEAD$/\1/p' | head -n 1)
  if [ -z "$first" ]; then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the remote names no default branch for HEAD, so the landing branch is unknown"
    return 1
  fi
  TEARDOWN_ROUTE_REMOTE_DEFAULT=$first
}

# The forge read of PR <pr> in <owner/repo>, bounded by <seconds> with
# fm_timeout_perl_bound (bin/fm-timeout-lib.sh), not with fm_run_timed. That bound
# runs its command in a process group of its own and kills the whole group at its
# limit, so a descendant of gh ends with the read, and it watches its parent and
# kills the group when the caller goes away, so a sweep plan that is stopped (a kill
# of the plan's own group, which does not reach a group of its own) or a teardown
# that is interrupted ends the read with the caller. fm_run_timed picks `timeout`
# where it exists, which never watches its caller. The bound does nothing for a
# command that exits early while a descendant still holds the output pipe: it stops
# watching when its direct child exits, so the capture would wait for that
# descendant and the descendant would outlive the read. So gh runs under a small
# perl wrapper, the leader of that group, which waits for gh, prints one trailer
# line with gh's status, and then kills the whole group (itself included). The
# trailer is read first: a well-formed trailer is gh's own status; no trailer means
# the bound ended the read. A group that the wrapper does not lead cannot be ended,
# so the read is unknown (126). Sets TEARDOWN_ROUTE_FORGE_OUT to gh's output;
# returns gh's status, 124 when the bound passed, 125 when there is no perl to bound
# it, 126 when the wrapper cannot end its group.
TEARDOWN_ROUTE_FORGE_OUT=
teardown_route_forge_read() {  # <seconds> <pr> <owner/repo>
  local rc=0 raw trailer body
  TEARDOWN_ROUTE_FORGE_OUT=
  command -v perl >/dev/null 2>&1 || return 125
  # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
  raw=$(fm_timeout_perl_bound "$1" perl -e '
    my $pid = fork;
    die "fork failed" unless defined $pid;
    if (!$pid) {
      open(STDIN, "<", "/dev/null");
      open(STDERR, ">", "/dev/null");
      exec @ARGV;
      exit 127;
    }
    waitpid($pid, 0);
    my $st = $?;
    my $code = ($st & 127) ? 128 + ($st & 127) : $st >> 8;
    $| = 1;
    if (getpgrp(0) != $$) { print "\nFM_FORGE_RC=nogroup\n"; exit 0; }
    print "\nFM_FORGE_RC=$code\n";
    kill "KILL", -$$;
    exit 0;
  ' gh pr view "$2" --repo "$3" --json state,mergeCommit,headRefName \
    -q '[.state, (.mergeCommit.oid // ""), .headRefName] | join("\t")' 2>/dev/null </dev/null) || rc=$?
  trailer=${raw##*$'\n'}
  if [[ $raw == *$'\n'* && $trailer == FM_FORGE_RC=* ]]; then
    body=${raw%$'\n'*}
    while [[ $body == *$'\n' ]]; do body=${body%$'\n'}; done
    trailer=${trailer#FM_FORGE_RC=}
    case "$trailer" in
      nogroup) return 126 ;;
      '' | *[!0-9]*) return 1 ;;
    esac
    TEARDOWN_ROUTE_FORGE_OUT=$body
    return $((10#$trailer > 255 ? 1 : 10#$trailer))
  fi
  [ "$rc" != 0 ] || rc=1
  return "$rc"
}

# True when the forge shows PR <pr> MERGED with a merge commit that the clone has
# and that is an ancestor of origin/<landing branch>, read with git and no fetch.
# The landing branch is the task's base_branch= (TEARDOWN_ROUTE_BASE) or the
# remote's own default branch, read from the remote. False too while the clone's
# primary checkout is on the PR's head branch. The forge is read with gh and the repository named from the
# clone's origin URL; a read that fails, times out or cannot be parsed is
# unknown, never merged.
teardown_route_pr_landed() {  # <slot> <pr>
  local slot=$1 pr=$2 url path owner repo out limit rc=0 forge_state merge head current branch ref shown
  # fm_pr_url_parse writes these globals; keep them out of the calling script.
  local FM_PR_PROVIDER FM_PR_URL FM_PR_HOST FM_PR_PATH FM_PR_OWNER FM_PR_REPO FM_PR_NUMBER
  url=$(git -C "$slot" config --get-all remote.origin.url 2>/dev/null) || url=
  case "$url" in
    https://github.com/*) path=${url#https://github.com/} ;;
    ssh://git@github.com/*) path=${url#ssh://git@github.com/} ;;
    git@github.com:*) path=${url#git@github.com:} ;;
    *) path= ;;
  esac
  path=${path%/}
  path=${path%.git}
  owner=${path%%/*}
  repo=${path#*/}
  if [ -z "$path" ] || [ "$owner" = "$path" ] || [[ $repo == */* ]] \
    || ! fm_pr_url_parse "https://github.com/$owner/$repo/pull/$pr"; then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the clone's origin URL does not name a GitHub repository, so PR $pr cannot be read on the forge"
    return 1
  fi
  limit=${FM_TEARDOWN_FORGE_TIMEOUT-60}
  if [[ ! $limit =~ ^[1-9][0-9]{0,8}$ ]]; then
    shown="'$limit'"
    [ -n "$limit" ] || shown="'' (the setting is set but empty)"
    TEARDOWN_CLOSEOUT_ROUTE_WHY="FM_TEARDOWN_FORGE_TIMEOUT is $shown, not a whole number of seconds from 1 to 999999999 written without a leading zero, so the forge read of PR $pr is not made and the copy is kept"
    return 1
  fi
  if ! command -v gh >/dev/null 2>&1; then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="gh is not available, so PR $pr cannot be read on the forge (unknown, not merged)"
    return 1
  fi
  teardown_route_forge_read "$limit" "$pr" "$FM_PR_OWNER/$FM_PR_REPO" || rc=$?
  out=$TEARDOWN_ROUTE_FORGE_OUT
  if [ "$rc" != 0 ]; then
    if fm_timed_out "$rc"; then
      TEARDOWN_CLOSEOUT_ROUTE_WHY="the forge read of PR $pr timed out after ${limit}s (unknown, not merged)"
    elif [ "$rc" = 125 ]; then
      TEARDOWN_CLOSEOUT_ROUTE_WHY="the forge read of PR $pr cannot be bounded here (perl is not available), so it is unknown, not merged"
    elif [ "$rc" = 126 ]; then
      TEARDOWN_CLOSEOUT_ROUTE_WHY="the forge read of PR $pr could not end its own process group, so it is unknown, not merged"
    else
      TEARDOWN_CLOSEOUT_ROUTE_WHY="the forge read of PR $pr failed (exit $rc; unknown, not merged)"
    fi
    return 1
  fi
  if [[ ! $out =~ ^(MERGED|OPEN|CLOSED)$'\t'([0-9a-f]*)$'\t'([^[:space:]]+)$ ]]; then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the forge answer for PR $pr cannot be parsed (unknown, not merged)"
    return 1
  fi
  forge_state=${BASH_REMATCH[1]}
  merge=${BASH_REMATCH[2]}
  head=${BASH_REMATCH[3]}
  if [ "$forge_state" != MERGED ]; then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the forge shows PR $pr as $forge_state, not MERGED"
    return 1
  fi
  if ! fm_pr_head_valid "$merge"; then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the forge shows PR $pr MERGED but reports no merge commit"
    return 1
  fi
  if ! current=$(git -C "$slot" worktree list --porcelain 2>/dev/null); then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the clone's primary checkout cannot be read, so the driver might switch it off PR $pr's head branch"
    return 1
  fi
  current=$(printf '%s\n' "$current" | awk 'NF == 0 { exit } $1 == "branch" { sub(/^refs\/heads\//, "", $2); print $2 }')
  if [ "$current" = "$head" ]; then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the clone's primary checkout is on PR $pr's head branch $head, which the driver would switch to the base branch even on a plan"
    return 1
  fi
  current=$(git -C "$slot" symbolic-ref --quiet --short HEAD 2>/dev/null) || current=
  if [ "$current" = "$head" ]; then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the clone's own checkout (a linked worktree's HEAD) is on PR $pr's head branch $head, which the read made just before the driver is entered refuses"
    return 1
  fi
  TEARDOWN_ROUTE_HEADREF=$head
  TEARDOWN_ROUTE_MERGE=$merge
  # The landing branch is the task's recorded base, else the remote's own default
  # branch, read now from the remote; either way the remote's default is read, and a
  # recorded base that disagrees with it keeps the copy. The local origin/HEAD is
  # never trusted, and a local main or master is only a guess.
  teardown_route_remote_default "$slot" "$limit" || return 1
  branch=${TEARDOWN_ROUTE_BASE:-}
  if [ -z "$branch" ]; then
    branch=$TEARDOWN_ROUTE_REMOTE_DEFAULT
  elif [ "$branch" != "$TEARDOWN_ROUTE_REMOTE_DEFAULT" ]; then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the task's recorded base $branch disagrees with the remote's default branch $TEARDOWN_ROUTE_REMOTE_DEFAULT, so the landing branch of PR $pr is not settled"
    return 1
  fi
  ref=refs/remotes/origin/$branch
  if [ -z "$branch" ] || ! git check-ref-format "$ref" 2>/dev/null \
    || ! git -C "$slot" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1; then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the landing branch ${branch:-?} has no origin/${branch:-?} in the clone, so the merge commit of PR $pr cannot be placed on it"
    return 1
  fi
  if ! git -C "$slot" cat-file -e "$merge^{commit}" 2>/dev/null; then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the merge commit $merge of PR $pr is not in the clone (not landed)"
    return 1
  fi
  rc=0
  git -C "$slot" merge-base --is-ancestor "$merge" "$ref" >/dev/null 2>&1 || rc=$?
  if [ "$rc" != 0 ]; then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the merge commit $merge of PR $pr is not on origin/$branch (not landed)"
    [ "$rc" = 1 ] || TEARDOWN_CLOSEOUT_ROUTE_WHY="the merge commit $merge of PR $pr could not be placed on origin/$branch (unknown, not landed)"
    return 1
  fi
}

# After the forge read, which is the slow step: the record must still bind the same
# PR, profile and tip. A reader that refuses names its own reason; a record that
# vanished or changed is named here.
teardown_route_reread() {  # <copy> <pr> <profile> <tip>
  local rc=0
  teardown_route_record "$1" || rc=$?
  [ "$rc" != 2 ] || return 1
  if [ "$rc" != 0 ] || [ "$TEARDOWN_CLOSEOUT_ROUTE_PR" != "$2" ] \
    || [ "$TEARDOWN_CLOSEOUT_ROUTE_PROFILE" != "$3" ] || [ "$TEARDOWN_ROUTE_TIP" != "$4" ]; then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the records file changed while the route was being proved (it no longer binds PR $2, its profile and tip $4)"
    return 1
  fi
}

# Sets TEARDOWN_CLOSEOUT_ROUTE for <copy>: empty (the plain call), pr (the route,
# with PR and PROFILE) or invalid (return 1, with WHY). It reads the live tip and
# the forge each time it runs, so the plan and the execute each prove the record.
# The record is read again after the forge read and must bind the same PR, profile
# and tip, and the profile is checked again after it, so a row written while the
# forge was read holds the copy. A caller that publishes the route learns the PR
# while the proof still runs (route "proving").
teardown_closeout_route() {  # <slot> <copy>
  local rc=0 pr profile tip
  TEARDOWN_CLOSEOUT_ROUTE=
  TEARDOWN_CLOSEOUT_ROUTE_WHY=
  TEARDOWN_ROUTE_HEADREF=
  teardown_route_record "$2" || rc=$?
  [ "$rc" != 1 ] || return 0
  if [ "$rc" = 0 ]; then
    pr=$TEARDOWN_CLOSEOUT_ROUTE_PR
    profile=$TEARDOWN_CLOSEOUT_ROUTE_PROFILE
    tip=$TEARDOWN_ROUTE_TIP
    TEARDOWN_CLOSEOUT_ROUTE=proving
    teardown_closeout_route_publish
    if teardown_route_lock_take "$1" "$2" \
      && { teardown_closeout_route_publish; true; } \
      && teardown_route_checkout_open "$1" "$2" \
      && { teardown_closeout_route_publish; true; } \
      && teardown_route_profile_ok "$profile" "$pr" "$tip" \
      && teardown_route_pr_landed "$1" "$pr" \
      && teardown_route_content_proven "$1" "$tip" "$TEARDOWN_ROUTE_MERGE" \
      && teardown_route_reread "$2" "$pr" "$profile" "$tip" \
      && teardown_route_profile_ok "$profile" "$pr" "$tip"; then
      TEARDOWN_CLOSEOUT_ROUTE='pr'
      return 0
    fi
    # A proof that refused still ends with a read of the checkout against the window it
    # opened: a switch in that window is reported and stops the sweep, as after a call.
    if [ "$TEARDOWN_CKO_OPEN" = 1 ] && ! teardown_route_checkout_check "$1" "${TEARDOWN_ROUTE_HEADREF:-}"; then
      TEARDOWN_CLOSEOUT_SWITCHED=1
      TEARDOWN_CLOSEOUT_ROUTE_WHY="$TEARDOWN_CLOSEOUT_ROUTE_WHY; the primary checkout of the slot was switched during the proof: $TEARDOWN_CKO_WHY"
    fi
    teardown_route_lock_release
    teardown_route_checkout_close
  fi
  TEARDOWN_CLOSEOUT_ROUTE=invalid
  return 1
}

# A caller that bounds the call from outside (the sweep's plan) names a file in
# TEARDOWN_CLOSEOUT_ROUTE_FILE to learn the route and its reason, even when the
# bound kills the call before it returns. The file also carries the first read of the
# checkout (copy, branch, HEAD, reflog position), the PR's head branch, whether a
# switch was found, the newest reflog entry of the first read (the anchor), and the
# project lock the route took and whether it owns it, twelve lines in all, so the
# sweep's execute keeps the plan's window. The route publishes it again at each step
# (the lock taken, the window opened), so a plan killed while it is still proving
# leaves the window and the lock behind.
teardown_closeout_route_publish() {
  [ -n "${TEARDOWN_CLOSEOUT_ROUTE_FILE:-}" ] || return 0
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$TEARDOWN_CLOSEOUT_ROUTE" "$TEARDOWN_CLOSEOUT_ROUTE_PR" \
    "$(printf '%s' "$TEARDOWN_CLOSEOUT_ROUTE_WHY" | tr '\n\t' '  ')" \
    "$TEARDOWN_CKO_COPY" "$TEARDOWN_CKO_BRANCH" "$TEARDOWN_CKO_HEAD" "$TEARDOWN_CKO_POS" "$TEARDOWN_ROUTE_HEADREF" \
    "$TEARDOWN_CLOSEOUT_SWITCHED" "$TEARDOWN_CKO_ANCHOR" "$TEARDOWN_ROUTE_LOCK_PATH" "$TEARDOWN_ROUTE_LOCK_OWN" \
    > "$TEARDOWN_CLOSEOUT_ROUTE_FILE" 2>/dev/null || true
}
# The reader of that file, for a caller that bounds the call from outside (the sweep): the
# window opens whatever the route's state (a plan killed while proving left it too), and
# the lock the plan took and whether it owned it are known. The file's switch flag is
# TEARDOWN_ROUTE_FILE_SWITCHED.
TEARDOWN_ROUTE_FILE_SWITCHED=0
teardown_closeout_route_file_load() {  # <file>
  { IFS= read -r TEARDOWN_CLOSEOUT_ROUTE; IFS= read -r TEARDOWN_CLOSEOUT_ROUTE_PR; IFS= read -r TEARDOWN_CLOSEOUT_ROUTE_WHY
    IFS= read -r TEARDOWN_CKO_COPY; IFS= read -r TEARDOWN_CKO_BRANCH; IFS= read -r TEARDOWN_CKO_HEAD; IFS= read -r TEARDOWN_CKO_POS
    IFS= read -r TEARDOWN_ROUTE_HEADREF; IFS= read -r TEARDOWN_ROUTE_FILE_SWITCHED; IFS= read -r TEARDOWN_CKO_ANCHOR
    IFS= read -r TEARDOWN_ROUTE_LOCK_PATH; IFS= read -r TEARDOWN_ROUTE_LOCK_OWN; } < "$1" || true
  [ "$TEARDOWN_ROUTE_FILE_SWITCHED" = 1 ] || TEARDOWN_ROUTE_FILE_SWITCHED=0
  [ "$TEARDOWN_ROUTE_LOCK_OWN" = 1 ] || TEARDOWN_ROUTE_LOCK_OWN=0
  case "$TEARDOWN_CLOSEOUT_ROUTE" in
    pr | proving) if [ -n "$TEARDOWN_CKO_COPY" ]; then TEARDOWN_CKO_OPEN=1; else TEARDOWN_CKO_OPEN=0; fi ;;
    *) TEARDOWN_CKO_OPEN=0 ;;
  esac
}
# The read the parent makes when the plan was killed at its timeout and so never made its
# own: against the window it opened, with the PR's head branch if it was known by then.
teardown_route_plan_killed_check() {  # <slot>
  [ "$TEARDOWN_CKO_OPEN" = 1 ] || return 0
  teardown_route_checkout_check "$1" "${TEARDOWN_ROUTE_HEADREF:-}"
}

# TEARDOWN_ROUTE_ENVELOPE_KEYS is the driver's fifteen-key compact envelope, the one
# key set that this reader and the sweep's temporary-refusal classifier both require.
# The one reader of the route's answer, in the shape the driver's --pr lane
# prints (its compact envelope, with no top-level "allowed"). A plan allows only
# on exit 3 with state BLOCKED, predicates_failed exactly ["cleanup_not_executed"],
# cleanup_requested true and worktree_removed false; an execute only on exit 0
# with state DONE or DONE_WITH_SUPERSEDENCE, no failed predicate and
# worktree_removed true. Any other exit, shape, silence or parse failure, and any
# answer that shows the driver keeping a tree for its unique ignored files, does
# not allow. WHY names what the answer lacked.
TEARDOWN_ROUTE_ENVELOPE_KEYS='["base_ref","base_strategy","branch_delete","branch_reap","cleanup_recovery_reason","cleanup_requested","evidence_digest","launch_cwd","next_command","owner","pr","predicates_failed","primary_checkout_repair","state","worktree_removed"]'
teardown_closeout_route_answer() {  # <plan|execute> <driver-exit>
  local stage=$1 rc=$2 want contradiction
  local keys=$TEARDOWN_ROUTE_ENVELOPE_KEYS
  case "$TEARDOWN_CLOSEOUT_STDOUT$TEARDOWN_CLOSEOUT_OUT" in
    *cleanup_ignored_payload_archived_tree_retained* | *archive_then_retain_tree*)
      TEARDOWN_CLOSEOUT_ROUTE_WHY="the driver keeps a tree with unique ignored files after archiving them and never removes it automatically"
      return 1
      ;;
  esac
  # An answer that contradicts the call or itself is refused by name. The call
  # always names --cleanup-worktree, so cleanup_requested false is wrong, and a
  # BLOCKED state that claims a removal is wrong; neither is read as a refusal
  # that released nothing.
  contradiction=$(printf '%s' "$TEARDOWN_CLOSEOUT_STDOUT" | jq -s -r 'if length == 1 and (.[0] | type) == "object" then .[0] | (if .cleanup_requested == false then "cleanup_requested is false although the call asked for cleanup" elif .state == "BLOCKED" and .worktree_removed == true then "it reports worktree_removed true while the state is BLOCKED" elif .state == "BLOCKED" and ((.branch_delete // null) != null or (.branch_reap // null) != null) then "it reports a branch delete or reap decision while the state is BLOCKED" else empty end) else empty end' 2>/dev/null) || contradiction=
  if [ -n "$contradiction" ]; then
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the driver's answer contradicts the call or itself ($contradiction), so it is not read as proof that nothing was released"
    return 1
  fi
  if [ "$stage" = plan ]; then
    want=3
    if [ "$rc" = "$want" ] && printf '%s' "$TEARDOWN_CLOSEOUT_STDOUT" | jq -s -e --argjson keys "$keys" --argjson pr "$TEARDOWN_CLOSEOUT_ROUTE_PR" 'length == 1 and (.[0] | type == "object" and (keys | sort) == $keys and (.pr | type) == "number" and .pr == $pr and .state == "BLOCKED" and .predicates_failed == ["cleanup_not_executed"] and .cleanup_requested == true and .worktree_removed == false)' >/dev/null 2>&1; then
      return 0
    fi
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the plan did not answer with exit 3 and the driver's fifteen-key dry-run envelope (BLOCKED, cleanup_not_executed only, the called PR)"
  else
    want=0
    if [ "$rc" = "$want" ] && printf '%s' "$TEARDOWN_CLOSEOUT_STDOUT" | jq -s -e --argjson keys "$keys" --argjson pr "$TEARDOWN_CLOSEOUT_ROUTE_PR" 'length == 1 and (.[0] | type == "object" and (keys | sort) == $keys and (.pr | type) == "number" and .pr == $pr and (.state == "DONE" or .state == "DONE_WITH_SUPERSEDENCE") and .predicates_failed == [] and .cleanup_requested == true and .worktree_removed == true and .cleanup_recovery_reason == null)' >/dev/null 2>&1; then
      return 0
    fi
    TEARDOWN_CLOSEOUT_ROUTE_WHY="the execute did not answer with exit 0 and the driver's fifteen-key success envelope (DONE or DONE_WITH_SUPERSEDENCE, the called PR, no failed predicate, worktree_removed true, no recovery reason)"
  fi
  return 1
}

# Runs Vernant's closeout driver on <copy>: it releases its own creation lock
# and removes the copy. With "plan" it omits --execute-cleanup, so the driver
# only says whether it would. TEARDOWN_CLOSEOUT_STDOUT is verdict input;
# TEARDOWN_CLOSEOUT_OUT retains stdout and stderr for display and refusal records.
# An optional capture file belongs to the caller (so a killed plan can clean it).
# Exit 0 means the driver allowed and, unless planning, ran the cleanup. A copy
# that a supersedence record names is called through teardown_closeout_route
# and judged by teardown_closeout_route_answer; exit 0 then still means allowed.
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
  local slot=$1 copy=$2 stage=execute driver py rc=0 driver_rc=0 capture=${4:-} own_capture=0
  local -a argv=(--cleanup-worktree "$copy")
  [ "${3:-}" != plan ] || stage=plan
  TEARDOWN_CLOSEOUT_STDOUT=
  TEARDOWN_CLOSEOUT_OUT=
  TEARDOWN_CLOSEOUT_ROUTE=
  TEARDOWN_CLOSEOUT_ROUTE_WHY=
  driver=$slot/scripts/git-stability/closeout_pr.py
  py=${FM_TEARDOWN_VERNANT_PYTHON:-$slot/.venv/bin/python}
  teardown_closeout_available "$slot" || return 127
  TEARDOWN_CLOSEOUT_SWITCHED=0
  teardown_closeout_route "$slot" "$copy" || rc=$?
  teardown_closeout_route_publish
  if [ "$rc" != 0 ]; then
    TEARDOWN_CLOSEOUT_OUT="the supersedence record for $copy cannot be used: $TEARDOWN_CLOSEOUT_ROUTE_WHY; Vernant's closeout driver was not called"
    return 1
  fi
  [ "$stage" = plan ] || argv+=(--execute-cleanup)
  [ "$TEARDOWN_CLOSEOUT_ROUTE" != pr ] \
    || argv+=(--pr "$TEARDOWN_CLOSEOUT_ROUTE_PR" --supersedence-profile "$TEARDOWN_CLOSEOUT_ROUTE_PROFILE" --no-evidence-files)
  if [ -z "$capture" ]; then
    capture=$(mktemp "${TMPDIR:-/tmp}/fm-closeout-stdout.XXXXXX") || {
      TEARDOWN_CLOSEOUT_OUT="Vernant's closeout stdout could not be captured"
      teardown_route_lock_release
      teardown_route_checkout_close
      return 1
    }
    own_capture=1
  fi
  if [ "$TEARDOWN_CLOSEOUT_ROUTE" = pr ] && ! teardown_route_checkout_pre_entry "$slot" "$TEARDOWN_ROUTE_HEADREF"; then
    # The read made just before the driver is entered: refused with no driver call.
    TEARDOWN_CLOSEOUT_SWITCHED=1
    TEARDOWN_CLOSEOUT_ROUTE_WHY=$TEARDOWN_CKO_WHY
    TEARDOWN_CLOSEOUT_OUT="the primary checkout of the slot was switched during the route of $copy: $TEARDOWN_CKO_WHY; Vernant's closeout driver was not called"
    TEARDOWN_CLOSEOUT_STDOUT=
    [ "$own_capture" = 0 ] || rm -f -- "$capture"
    teardown_closeout_route_publish
    teardown_route_lock_release
    teardown_route_checkout_close
    return 1
  fi
  # tee sees only stdout; stderr bypasses it into the display capture. pipefail
  # preserves a driver refusal and treats a failed capture as no permission.
  # Sentinels preserve trailing newlines in both output contracts.
  TEARDOWN_CLOSEOUT_OUT=$(
    set -o pipefail
    local status=0
    { ( cd "$slot" && "$py" "$driver" "${argv[@]}" ) | tee "$capture"; } 2>&1 || status=$?
    printf '.'
    exit "$status"
  ) || rc=$?
  TEARDOWN_CLOSEOUT_OUT=${TEARDOWN_CLOSEOUT_OUT%.}
  TEARDOWN_CLOSEOUT_STDOUT=$(cat "$capture" || exit 1; printf '.') || rc=1
  TEARDOWN_CLOSEOUT_STDOUT=${TEARDOWN_CLOSEOUT_STDOUT%.}
  [ "$own_capture" = 0 ] || rm -f -- "$capture"
  driver_rc=$rc
  if [ "$TEARDOWN_CLOSEOUT_ROUTE" = pr ]; then
    if teardown_closeout_route_answer "$stage" "$rc"; then
      rc=0
    else
      [ "$rc" != 0 ] || rc=1
      TEARDOWN_CLOSEOUT_OUT="supersedence route (--pr $TEARDOWN_CLOSEOUT_ROUTE_PR): $TEARDOWN_CLOSEOUT_ROUTE_WHY"$'\n'"$TEARDOWN_CLOSEOUT_OUT"
    fi
    # The read after the call: a switch is reported whatever the driver answered. The
    # driver's effects are not undone, so a removal it made stays made.
    if ! teardown_route_checkout_check "$slot" "$TEARDOWN_ROUTE_HEADREF"; then
      TEARDOWN_CLOSEOUT_SWITCHED=1
      [ "$rc" != 0 ] || rc=1
      TEARDOWN_CLOSEOUT_OUT="the primary checkout of the slot was switched during the route of $copy: $TEARDOWN_CKO_WHY; Vernant's closeout driver had been called (exit $driver_rc)"$'\n'"$TEARDOWN_CLOSEOUT_OUT"
    fi
    teardown_closeout_route_publish
    teardown_route_lock_release
    teardown_route_checkout_close
  fi
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
  if [ "$rc" != 0 ] || { [ "$TEARDOWN_CLOSEOUT_ROUTE" != pr ] && ! teardown_closeout_plan_verdict_allows "$TEARDOWN_CLOSEOUT_STDOUT"; }; then
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
