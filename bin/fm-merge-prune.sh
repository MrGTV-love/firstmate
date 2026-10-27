#!/usr/bin/env bash
# fm-merge-prune.sh - prune a task's pool copy right after its pull request merges.
#
# Usage:
#   fm-merge-prune.sh arm <task-id> [--run]   Record that the task's merge was verified and its copy is due for pruning; with --run also start one detached attempt now.
#   fm-merge-prune.sh run <task-id> [--now]   Make one attempt for the task; without --now only when its record is due.
#   fm-merge-prune.sh sweep                   Make one attempt for every due record (at most 3).
#
# A merged task's pool copy used to stay until an hourly safety net or a human
# removed it. bin/fm-pr-merge.sh arms a record once it has verified a merge, and
# bin/fm-watch.sh arms one for a merge that happened elsewhere (the merge poll).
# A detached sweep then asks the same authority as every other cleanup,
# bin/fm-teardown.sh, never forced, with the automatic-reap admission marker
# (FM_IDLE_REAP_ADMISSION=1) so a worker that is still busy, steered, held for
# the captain or waiting on a decision is never closed. The record is
# state/<id>.merge-prune. Nothing here waits for a human.
#
# Arming needs the task's metadata and the merge poll's
# state/<id>.pr-poll-merge-notified marker for the PR recorded in it: only a
# verified merge arms. Missing metadata or a different PR drops the record.
#
# Before teardown runs, every copy nested in the task's copy gets the commit,
# stash and status proofs of the fallback (below). A teardown that succeeds
# returns the slot with its nested copies in it, which the prune then removes
# (below), or closes the task and holds the slot, so a nested copy with work of
# its own keeps the whole slot with one wake and teardown does not run. Teardown ends a job working at the copy root,
# so a job in the task's terminal pane (not a shell, the worker's agent, what it
# started, or what it runs under) keeps the copy with one wake before teardown
# runs, too.
#
# Transient refusals retry on later sweeps with backoff (60s, doubling to 3600s)
# and stay silent: the task lease or project lock is held by another actor
# (FM_LEASE_REFUSE_EXIT, FM_PROJECT_LOCK_BUSY_EXIT), a teardown that outlasts its
# 600-second limit, an admission refusal (the worker is not finished yet), a
# landing proof that went stale (the copy's HEAD moved while teardown ran), and a
# lifecycle action already running. One wake is raised if a task is still not
# pruned after 24 attempts.
#
# The fallback handles only the two refusal classes that really reach it, which
# may be false positives that `treehouse destroy` will settle: the ship
# deliverable teardown calls "not landed" (a squash-merged copy, which treehouse
# counts merged) and a closeout driver's "exact tree not covered" for a nested
# copy. Only then the fallback of bin/fm-merge-prune-lib.sh runs; every other
# refusal, unknown text included, keeps the copy at once with one wake: a leaked
# process, a launch agent still loaded, a process whose ownership is not proven,
# a live pipeline, a captain call, and an orphan nested copy refused for a HEAD
# that is not proved landed or for ignored files (teardown never prints that
# text; it preserves such files itself, and it prints a second refusal with the
# HEAD one). Every refusal line of the output must be one of the two classes
# (fallback_allowed names each message). A copy whose work is
# pushed but not merged (a follow-up commit after the merge) stays with one wake:
# the fallback proves the copy's HEAD is in the merged PR's head or that the
# default branch carries its content, before it stops anything, because ending
# the pane's idle shell returns the slot to the pool (reset to the default
# branch), after which `treehouse destroy` could no longer see it as unmerged.
# The fallback also runs only
# for a task whose PR URL is https://github.com/<owner>/<repo>/pull/<n>, the
# form teardown can finish the records of once the copy is gone; a PR of any
# other provider keeps the copy with one wake.
#
# The fallback re-proves from the live copy, by the criteria of
# treehouse-reap-clean, that the copy is a Treehouse pool slot of the task's
# project (the repo's one test, fm_treehouse_pool_slot: the pool's
# treehouse-state.json beside it and the project's git directory shared), and
# that it and every nested copy has no changed or untracked file (the untracked
# directory of a nested copy is not counted in the status of the copy that holds
# it: each nested copy is proved on its own), holds no stash
# entry of its own work, has no commit reachable from its HEAD (its own
# checked-out branch) missing from every remote (or from the merged PR's head),
# for the task's own copy leaves out nothing the merged PR omits (its HEAD is in
# the PR's head, or the default branch carries its content),
# holds only scratch or preserved ignored files (the disposable entries of
# teardown's own list, scripts/hooks/_conformance_manifest.json included; under
# .claude and .opencode only
# Firstmate's own hook files, clones and scratch names are scratch, and the
# search for nested copies enters dependency and environment trees), and has no
# process inside. For a
# linked worktree of the project the commit and stash proofs read only that
# copy's work (never the project's other branches or other tasks' stashes); a
# nested copy that is an independent clone, with its own git directory, is proved
# in full: every local branch not on a remote and every stash keeps it. The
# finished worker session is stopped first
# (bin/fm-control.sh exit). That verb keeps the task's terminal pane open, and
# the pane's idle shell, the one the pane entered the copy with, stays inside
# the copy. That one process does not keep the copy, but treehouse refuses to
# destroy a copy with a process working inside it, so it is ended with SIGHUP
# just before the destroy: it must be a shell whose working directory is in the
# copy, with no child process, that is a strict descendant of the pane's shell
# (found by the pane's process id; tmux and herdr, any other backend exempts
# nothing), and the exit verb must have stopped the agent. The pane's own shell is never ended, so a bare pane shell
# inside the copy keeps the copy. SIGKILL is never sent, the pane stays open on
# its outer shell, and a shell that does not go keeps the copy. Any other
# process, such as a build, an editor or a test started in the pane, keeps the
# copy. The Treehouse project lock is held from the worker stop to the destroy,
# and the proof repeated while it and the task control lock are held makes no
# fetch (it reuses the remote refs fetched before the locks), so a hung remote
# never holds either lock. The finished-session check is asked again once the
# project lock is held, right before the worker is stopped: a worker that was
# steered or became busy since the first answer backs off, and nothing is
# stopped, signalled or destroyed. A proof read that fails (the ignored-file
# listing, the stash listing, the search for nested copies, an error from the
# process check) never counts as finding nothing. The preserve-list files of the
# copy and of each nested copy are copied to data/<id>/merge-prune-preserved/
# with SHA-256 checksums before anything is removed. The slot-owner claim is
# read again right before the signal, and a slot claimed by another task, or for
# this task id by another home, is left alone. Then each nested copy whose
# untracked directory shows in the copy's status (the project's .gitignore does
# not cover it) is removed, because treehouse counts that directory as dirt
# (fm_mp_remove_unignored_nested): an independent clone with its directory, a
# linked worktree with a plain `git worktree remove`; one that git refuses to
# remove keeps the copy with one wake. Then
# `treehouse destroy <copy> --include-leased --yes` removes the copy (the same
# call the reaper makes), and teardown runs again to finish the task's records.
# No step uses --force, --include-unlanded or --include-in-use. In this
# mode the admission check of that second teardown (bin/fm-idle-reap-lib.sh)
# accepts the worker the exit verb stopped: its busy record is gone,
# state/<id>.control-exit is present, its terminal pane positively shows no live
# agent (only shells are left in it, and at most the one `treehouse get` that
# opened the slot's subshell) and its last status event is `done`. The same
# holds for a worker stopped that way before the merge, at the first teardown.
# A `treehouse get` that has not exited after its idle shell is ended, or that
# waits at a prompt, still passes; if anything else is then left in the pane,
# that second teardown refuses, the prune backs off and retries it, and only
# when the retries run out does it raise its one wake.
#
# Anything else stays, is never forced or discarded, and raises exactly ONE wake
# naming the copy and the reason (recorded as sent only once the queue took it). A retained copy is retried silently every six
# hours in case the cause cleared. The hourly `treehouse prune --all --yes`
# safety net is not duplicated.
#
# A teardown that succeeds and returns the slot to the pool leaves it reset in
# place, so the copy is still on disk with the task's record gone. The prune
# then removes that copy itself (remove_returned), under the project lock, with
# the same call and the same proofs as the fallback's destroy, and without any
# force. It removes it only when the copy really was returned: a pool slot of
# the project that Treehouse state records as not leased, read again under the
# project lock and again when a retry resumes from the prune record. A copy that
# the read proves teardown kept on purpose (its lease is still held, for another
# task's record or for foreign copies, or no treehouse-state.json lies beside it,
# so it is not a pool slot) is never removed: the outcome is the log line
# "reaped: teardown completed; teardown kept the copy", with no wake and no
# record. A read that cannot tell (the lease state unreadable or ambiguous, the
# pool-slot test unable to run, no project recorded, the project lock path
# unresolved) is a quiet retry that keeps the record and the copy, and raises
# the one wake when the retries run out. Before the removal the slot's owner claim must be
# this task's or absent, nothing may be inside it (a search indexer excepted),
# each nested copy is proved on its own, the copy and each nested copy hold only
# scratch or preserved ignored files, and the preserve-list files are copied to
# data/<id>/merge-prune-preserved/ with SHA-256 checksums, as for the fallback.
# The prune record is cleared only once the copy path is gone. A removal that is
# refused keeps the record and the copy and raises the one wake; the retry needs
# only the record, which keeps the copy and the project.
#
# A proof read that fails never counts as finding nothing, whether it printed
# rows first or not: a process table (ps) or open-file listing (lsof) that exits
# with an error or a message is a probe that failed, and keeps the copy.
#
# Outcomes are one line each in data/<id>/merge-prune.log. A pruned copy raises
# no wake; only a copy that stays raises its one wake ("check: merge-prune kept
# <copy> for <id>: <reason>"). The task's status file is never written.
#
# FM_MERGE_PRUNE=0 turns arming off. Test seams: FM_MERGE_PRUNE_TEARDOWN_BIN and
# FM_MERGE_PRUNE_CONTROL_BIN replace bin/fm-teardown.sh and bin/fm-control.sh;
# FM_MERGE_PRUNE_EXIT_WAIT bounds the seconds to wait for the stopped worker and
# for the pane's idle shell to exit on SIGHUP.
# docs/configuration.md owns the settings; regression coverage:
# tests/fm-merge-prune.test.sh.
set -u
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SWEEP_LOCK="$STATE/.merge-prune-sweep.lock"

# shellcheck source=bin/fm-idle-reap-lib.sh
. "$SCRIPT_DIR/fm-idle-reap-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
# shellcheck source=bin/fm-project-lock-lib.sh
. "$SCRIPT_DIR/fm-project-lock-lib.sh"
# shellcheck source=bin/fm-task-copy-lib.sh
. "$SCRIPT_DIR/fm-task-copy-lib.sh"
# shellcheck source=bin/fm-merge-prune-lib.sh
. "$SCRIPT_DIR/fm-merge-prune-lib.sh"

TEARDOWN_BIN="${FM_MERGE_PRUNE_TEARDOWN_BIN:-$SCRIPT_DIR/fm-teardown.sh}"
CONTROL_BIN="${FM_MERGE_PRUNE_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}"
EXIT_WAIT="${FM_MERGE_PRUNE_EXIT_WAIT:-10}"
case "$EXIT_WAIT" in ''|*[!0-9]*) EXIT_WAIT=10 ;; esac

BACKOFF_START=60
BACKOFF_CAP=3600
RETAINED_RETRY=21600
WAKE_AFTER_ATTEMPTS=24

usage() {
  sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0" | sed '$d'
}

die() {
  printf 'fm-merge-prune: %s\n' "$*" >&2
  exit 2
}

NOW=0
fm_epoch_seconds_to NOW

clean_detail() {  # <text> -> single-line text, capped
  local text=$1
  text=${text//$'\t'/ }
  text=${text//$'\n'/ }
  text=${text//$'\r'/ }
  [ "${#text}" -le 300 ] || text="${text:0:300}..."
  printf '%s' "$text"
}

valid_id() {
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# The record: one key=value per line, rewritten atomically.
R_PR=; R_ATTEMPTS=0; R_NEXT=0; R_STATE=pending; R_REASON=; R_WAKE=0; R_COPY=; R_ARMED=0; R_PROJECT=; R_RETURNED=0

rec_load() {  # <task-id>; 0 when a well-formed record was read
  local file="$STATE/$1.merge-prune" line version=
  R_PR=; R_ATTEMPTS=0; R_NEXT=0; R_STATE=pending; R_REASON=; R_WAKE=0; R_COPY=; R_ARMED=0; R_PROJECT=; R_RETURNED=0
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      version=*) version=${line#version=} ;;
      pr=*) R_PR=${line#pr=} ;;
      attempts=*) R_ATTEMPTS=${line#attempts=} ;;
      next_at=*) R_NEXT=${line#next_at=} ;;
      state=*) R_STATE=${line#state=} ;;
      reason=*) R_REASON=${line#reason=} ;;
      wake_sent=*) R_WAKE=${line#wake_sent=} ;;
      copy=*) R_COPY=${line#copy=} ;;
      armed_at=*) R_ARMED=${line#armed_at=} ;;
      project=*) R_PROJECT=${line#project=} ;;
      returned=*) R_RETURNED=${line#returned=} ;;
    esac
  done < "$file"
  [ "$version" = fm-merge-prune-v1 ] || return 1
  case "$R_ATTEMPTS$R_NEXT$R_WAKE$R_ARMED$R_RETURNED" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$R_PR" ]
}

rec_save() {  # <task-id>
  local file="$STATE/$1.merge-prune" tmp
  tmp=$(mktemp "$STATE/.merge-prune.XXXXXX") || return 1
  if printf 'version=fm-merge-prune-v1\npr=%s\nattempts=%s\nnext_at=%s\nstate=%s\nreason=%s\nwake_sent=%s\ncopy=%s\narmed_at=%s\nproject=%s\nreturned=%s\n' \
    "$R_PR" "$R_ATTEMPTS" "$R_NEXT" "$R_STATE" "$(clean_detail "$R_REASON")" "$R_WAKE" "$(clean_detail "$R_COPY")" "$R_ARMED" "$(clean_detail "$R_PROJECT")" "$R_RETURNED" > "$tmp" \
    && chmod 0600 "$tmp" && mv -f -- "$tmp" "$file"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

ID=
META=
LOCK=

log_line() {  # <text>
  mkdir -p "$DATA/$ID" 2>/dev/null || return 0
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(clean_detail "$1")" >> "$DATA/$ID/merge-prune.log" 2>/dev/null || true
}

first_refusal_line() {  # <teardown-output>
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      REFUSED*|error:*|refused*) printf '%s' "$line"; return 0 ;;
    esac
  done <<EOF
$1
EOF
  line=${1##*$'\n'}
  printf '%s' "$line"
}

# A refusal that only means "not now".
transient_refusal() {  # <teardown-output>
  case "$1" in
    *"another lifecycle action is already running"*) return 0 ;;
    *"liveness check is in progress"*) return 0 ;;
    *"retry for a fresh proof"*) return 0 ;;
    *"automatic reap ineligible:"*) return 0 ;;
  esac
  return 1
}

# The only refusals the fallback may settle are the two classes that really reach
# it, in the words teardown prints them: the ship deliverable reported as not
# landed (bin/fm-teardown.sh validate_worktree_teardown_safety) and a closeout
# driver that did not release a nested copy (bin/fm-teardown-nested-lib.sh).
# Every refusal line of the output must be one of them. Any other text, unknown
# text included, keeps the copy. A foreign nested copy refused for a HEAD that is
# not proved landed does not reach it: teardown always prints a second refusal
# with it (the pool slot contains a registered copy that is not the task's), and
# that line is not on this list.
fallback_allowed() {  # <teardown-output>
  local line seen=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      REFUSED*|error:*|refused*) ;;
      *) continue ;;
    esac
    case "$line" in
      "REFUSED: the ship deliverable is not landed; a pushed branch alone is not completion.") seen=1 ;;
      "REFUSED: Vernant's closeout driver did not release foreign copy "*" (exit "*"): "*"exact tree not covered"*) seen=1 ;;
      "REFUSED: Vernant's closeout driver did not release own nested copy "*" (exit "*"): "*"exact tree not covered"*) seen=1 ;;
      *) return 1 ;;
    esac
  done <<EOF
$1
EOF
  [ "$seen" = 1 ]
}

same_home() {  # <home-from-a-slot-claim>: whether it is this home
  local claimed=$1 mine
  [ -n "$claimed" ] || return 1
  [ "$claimed" != "$FM_HOME" ] || return 0
  mine=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || return 1
  claimed=$(cd "$claimed" 2>/dev/null && pwd -P) || return 1
  [ "$claimed" = "$mine" ]
}

TD_OUT=
TD_RC=0
run_teardown() {
  TD_RC=0
  TD_OUT=$(FM_HOME="$FM_HOME" FM_IDLE_REAP_ADMISSION=1 FM_IDLE_REAP_MERGE_PRUNE=1 \
    fm_run_timed "$(fm_mp_limit merge-prune.teardown 600)" "$TEARDOWN_BIN" "$ID" </dev/null 2>&1) || TD_RC=$?
}

# The outcome of a pruned copy: one log line and no wake.
finish_reaped() {  # <detail>
  rm -f -- "$STATE/$ID.merge-prune"
  log_line "reaped: $1"
}

# Teardown completed and kept the copy on purpose: nothing of it is the prune's
# to remove, so the record goes with one log line and no wake.
finish_kept() {  # <detail> <why>
  rm -f -- "$STATE/$ID.merge-prune"
  log_line "reaped: $1; teardown kept the copy: $2"
}

backoff() {  # <detail>: a transient outcome, silent until the attempt limit
  local delay=$BACKOFF_START i=1
  R_ATTEMPTS=$((R_ATTEMPTS + 1))
  while [ "$i" -lt "$R_ATTEMPTS" ] && [ "$delay" -lt "$BACKOFF_CAP" ]; do
    delay=$((delay * 2))
    i=$((i + 1))
  done
  [ "$delay" -le "$BACKOFF_CAP" ] || delay=$BACKOFF_CAP
  R_STATE=pending
  R_REASON=$1
  R_NEXT=$((NOW + delay))
  if [ "$R_ATTEMPTS" -ge "$WAKE_AFTER_ATTEMPTS" ]; then
    raise_wake "check: merge-prune $ID still not pruned after $R_ATTEMPTS attempts: $(clean_detail "$1")"
  fi
  rec_save "$ID" || true
  log_line "retry in ${delay}s (attempt $R_ATTEMPTS): $1"
}

# The one wake of a task. It is recorded as sent only after the queue took it, so
# a failed append is raised again by the next attempt and never lost; a crash
# between the append and the record can repeat it once.
raise_wake() {  # <text>
  [ "$R_WAKE" = 0 ] || return 0
  if fm_wake_append check "merge-prune:$ID" "$1"; then
    R_WAKE=1
  else
    log_line "wake could not be appended; the next attempt raises it again"
  fi
}

# A copy that stays: one wake and one log line per reason, a quiet retry later.
retain() {  # <copy> <reason>
  local copy=$1 reason=$2 changed=1
  [ "$R_STATE" = retained ] && [ "$R_REASON" = "$(clean_detail "$reason")" ] && changed=0
  R_ATTEMPTS=$((R_ATTEMPTS + 1))
  R_STATE=retained
  R_REASON=$reason
  R_COPY=$copy
  R_NEXT=$((NOW + RETAINED_RETRY))
  raise_wake "check: merge-prune kept $copy for $ID: $(clean_detail "$reason")"
  rec_save "$ID" || true
  if [ "$changed" = 1 ]; then
    log_line "retained $copy: $reason"
  fi
}

# The classifier must still call the finished worker reapable. It is asked
# again once the project lock is held, right before the worker is stopped,
# because the first answer is older than the fetches and the lock wait: a
# worker that was steered or became busy since backs off and nothing is
# stopped, signalled or destroyed.
reapable() {
  FM_IDLE_REAP_MERGE_PRUNE=1 fm_idle_reap_classify "$FM_HOME" "$STATE" "$DATA" "$ID"
  [ "$IDLE_REAP_CLASS" != reap ] || return 0
  backoff "automatic reap ineligible: $IDLE_REAP_CLASS: $IDLE_REAP_DETAIL"
  return 1
}

# Read the live copy's proofs; on success the copy is destroyed.
# Returns 0 destroyed or already absent, 1 retained or transient (already recorded).
fallback() {
  local wt real pr_number='' project plock rc=0
  wt=$(fm_meta_get "$META" worktree)
  if [ -z "$wt" ]; then
    retain "-" "teardown refused and the task record names no pool copy"
    return 1
  fi
  if [ ! -e "$wt" ]; then
    return 0
  fi
  project=$(fm_meta_get "$META" project)
  if ! real=$(fm_mp_real "$wt") || ! fm_treehouse_pool_slot "$project" "$real"; then
    retain "$wt" "not a Treehouse pool slot of the project ${project:-<no project recorded>}"
    return 1
  fi
  reapable || return 1
  pr_number=${R_PR##*/}
  if ! prove_all "$real" "$pr_number"; then
    return 1
  fi
  # A process lease on the slot lapses when the worker exits, so the project
  # lock, which every slot allocation takes, is held from the stop to the destroy.
  if ! plock=$(fm_treehouse_project_lock_path "$project"); then
    retain "$real" "cannot resolve the Treehouse project lock for ${project:-<no project recorded>}"
    return 1
  fi
  fm_project_lock_try "$plock" "merge-prune $ID" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    backoff "another operation holds or is queued for the task's project lock"
    return 1
  fi
  if ! reapable; then
    fm_project_lock_release "$plock" || true
    return 1
  fi
  rc=0
  fallback_remove "$real" "$pr_number" || rc=$?
  fm_project_lock_release "$plock" || true
  return "$rc"
}

# Stop the finished worker, prove the copy once more, preserve, and destroy it.
# The project lock is held by the caller.
fallback_remove() {  # <real-copy> <pr-number>
  local real=$1 pr_number=$2 dest waited=0 out rc=0 head pane reason
  stop_worker
  # The control lock keeps a teardown, relaunch or spawn from racing the removal.
  if ! fm_lock_try_acquire "$LOCK_CONTROL"; then
    backoff "another lifecycle action is already running for task $ID"
    return 1
  fi
  if ! prove_all "$real" "$pr_number" nofetch; then
    fm_lock_release "$LOCK_CONTROL" || true
    return 1
  fi
  # The stopped worker may need a moment to leave; any other process keeps the
  # copy, except the one idle shell of the task's own pane, which is ended with
  # SIGHUP below, just before the destroy.
  pane=$(fm_mp_pane_pid "$META")
  until fm_mp_prove_unused "$real" "$pane"; do
    case "$FM_MP_REASON" in
      "process(es) inside"*)
        if [ "$FM_MP_VERDICT" = keep ] && [ "$waited" -lt "$EXIT_WAIT" ]; then
          sleep 1
          waited=$((waited + 1))
          continue
        fi
        ;;
    esac
    fm_lock_release "$LOCK_CONTROL" || true
    record_verdict "$real"
    return 1
  done
  dest="$DATA/$ID/merge-prune-preserved/$NOW"
  if ! preserve_all "$real" "$dest"; then
    fm_lock_release "$LOCK_CONTROL" || true
    return 1
  fi
  fm_treehouse_slot_owner_state "$real" "$ID"
  # A claim that names this task id is this task's only when it also names this
  # home: the same id can belong to a task of another home, and a claim with no
  # home proves nothing.
  if [ "$FM_TREEHOUSE_SLOT_OWNER" = mine ] && ! same_home "$FM_TREEHOUSE_SLOT_OWNER_HOME"; then
    fm_lock_release "$LOCK_CONTROL" || true
    retain "$real" "the pool slot is claimed for task $ID by ${FM_TREEHOUSE_SLOT_OWNER_HOME:-no home}, not by this home"
    return 1
  fi
  case "$FM_TREEHOUSE_SLOT_OWNER" in
    mine|absent) ;;
    other)
      fm_lock_release "$LOCK_CONTROL" || true
      retain "$real" "the pool slot was reassigned to task $FM_TREEHOUSE_SLOT_OWNER_ID"
      return 1
      ;;
    *)
      fm_lock_release "$LOCK_CONTROL" || true
      retain "$real" "the pool slot's owner claim cannot be read"
      return 1
      ;;
  esac
  # Before the pane's idle shell ends: its `treehouse get` would stop at a prompt
  # on the untracked directory of a nested copy, and `treehouse destroy` refuses it.
  if ! fm_mp_remove_unignored_nested "$real"; then
    fm_lock_release "$LOCK_CONTROL" || true
    record_verdict "$real"
    return 1
  fi
  if [ -n "$FM_MP_PANE_SHELL" ]; then
    reason=
    if [ "$WORKER_STOPPED" != 1 ]; then
      reason="the worker session is not confirmed stopped, so the idle shell $FM_MP_PANE_SHELL of its terminal pane stays"
    elif ! fm_mp_end_pane_shell "$FM_MP_PANE_SHELL" "$pane" "$real" "$EXIT_WAIT"; then
      reason="the idle shell $FM_MP_PANE_SHELL of the task's terminal pane did not exit on SIGHUP"
    fi
    if [ -n "$reason" ]; then
      fm_lock_release "$LOCK_CONTROL" || true
      retain "$real" "$reason"
      return 1
    fi
  fi
  head=$(git -C "$real" rev-parse --short HEAD 2>/dev/null || true)
  out=$(fm_run_timed "$(fm_mp_limit merge-prune.destroy 300)" treehouse destroy "$real" --include-leased --yes </dev/null 2>&1) || rc=$?
  fm_lock_release "$LOCK_CONTROL" || true
  if [ "$rc" -ne 0 ]; then
    retain "$real" "treehouse destroy refused or failed: $(clean_detail "$out")"
    return 1
  fi
  if [ -e "$real" ]; then
    retain "$real" "treehouse destroy returned success but the copy is still present"
    return 1
  fi
  log_line "fallback destroyed $real (head ${head:-unknown}); preserved records, if any, are in $dest"
  return 0
}

# The ignored files of <real-copy> and of each nested copy (FM_MP_NESTED) must be
# scratch or on the preserve list, and the preserve-list files of each are copied
# to <dest> with checksums. Records the outcome and returns 1 when the copy stays.
preserve_all() {  # <real-copy> <dest>
  local real=$1 dest=$2 n label copies=("$1") tags=(root) i
  for n in ${FM_MP_NESTED[@]+"${FM_MP_NESTED[@]}"}; do
    label=${n#"$real"/}
    copies+=("$n")
    tags+=("nested-${label//\//__}")
  done
  for i in "${!copies[@]}"; do
    fm_mp_prove_ignored "${copies[$i]}" || { record_verdict "$real"; return 1; }
    for n in ${FM_MP_PRESERVE[@]+"${FM_MP_PRESERVE[@]}"}; do
      if ! fm_mp_preserve_one "${copies[$i]}" "$n" "$dest/${tags[$i]}"; then
        retain "$real" "could not copy and checksum preserved record $n from ${copies[$i]}"
        return 1
      fi
    done
  done
  return 0
}

# A copy that shares the project's git directory (a linked worktree, which is
# what the repo's one test, fm_task_copy_same_repository, asks) shares its
# branches and stash list, so only its own work is read. Any other copy, an
# independent clone or one whose git directory cannot be resolved, is proved in
# full.
proof_scope() {  # <copy> <project>
  if fm_task_copy_same_repository "$1" "$2"; then
    printf 'own'
  else
    printf 'all'
  fi
}

# Prove one copy and everything nested in it; sets FM_MP_VERDICT/REASON on failure.
# The nested copies are found first: each is proved on its own, so the status of
# the copy that holds it does not count its untracked directory (fm_mp_prove_git).
# The nofetch mode reuses what the earlier fetching pass left (fm_mp_prove_git).
prove_all() {  # <real-copy> <pr-number> [nofetch]
  local real=$1 pr=$2 mode=${3:-fetch} n project
  project=$(fm_meta_get "$META" project)
  fm_mp_find_nested "$real" || { record_verdict "$real"; return 1; }
  fm_mp_prove_git "$real" "$pr" "$mode" "$(proof_scope "$real" "$project")" || { record_verdict "$real"; return 1; }
  fm_mp_prove_ignored "$real" || { record_verdict "$real"; return 1; }
  prove_nested_git "$mode" || { record_verdict "$real"; return 1; }
  if [ "${#FM_MP_NESTED[@]}" -gt 0 ]; then
    for n in "${FM_MP_NESTED[@]}"; do
      fm_mp_prove_ignored "$n" || { record_verdict "$real"; return 1; }
    done
  fi
  return 0
}

# The commit, stash and status proofs of each nested copy that fm_mp_find_nested
# found (FM_MP_NESTED); sets FM_MP_VERDICT/REASON on failure.
prove_nested_git() {  # <fetch|nofetch>
  local n project
  project=$(fm_meta_get "$META" project)
  [ -n "$project" ] || project=$R_PROJECT
  for n in ${FM_MP_NESTED[@]+"${FM_MP_NESTED[@]}"}; do
    fm_mp_prove_git "$n" "" "$1" "$(proof_scope "$n" "$project")" || return 1
  done
  return 0
}

# Record a failed proof: transient goes to backoff, anything else is retained.
record_verdict() {  # <root-copy>
  if [ "$FM_MP_VERDICT" = transient ]; then
    backoff "$FM_MP_REASON"
  else
    retain "$1" "$FM_MP_REASON"
  fi
}

# The finished worker's own session is a process inside the copy; stop it the
# way teardown would. It is idle and its work has landed (classified reap).
WORKER_STOPPED=0
stop_worker() {
  WORKER_STOPPED=0
  FM_HOME="$FM_HOME" fm_run_timed "$(fm_mp_limit merge-prune.control-exit 120)" "$CONTROL_BIN" "$ID" exit </dev/null >/dev/null 2>&1 && WORKER_STOPPED=1
}

# A teardown that succeeds returns the slot with its nested copies in it, or
# closes the task and holds the slot, so the commit, stash and status proofs of
# every nested copy run before teardown: a nested copy with work of its own keeps
# the whole slot with one wake, and teardown does not run. Teardown also ends a
# job working at the copy root, so a job in the task's terminal pane keeps the
# copy the same way (fm_mp_prove_pane_idle).
prove_nested_first() {
  local wt real
  wt=$(fm_meta_get "$META" worktree)
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  if ! real=$(fm_mp_real "$wt"); then
    retain "$wt" "cannot resolve the pool copy $wt"
    return 1
  fi
  fm_mp_find_nested "$real" || { record_verdict "$real"; return 1; }
  prove_nested_git fetch || { record_verdict "$real"; return 1; }
  fm_mp_prove_pane_idle "$real" "$(fm_mp_pane_pid "$META")" || { record_verdict "$real"; return 1; }
}

# Whether teardown returned <copy> to the pool: a pool slot of <project> that
# Treehouse state records as not leased, read fresh. Teardown keeps a slot that
# another task's record still names, or that holds foreign copies, under a
# durable lease, and a copy that is not a pool slot is never returned. Sets
# RETURNED_REAL to the physical path; when it was not returned, RETURNED_WHY,
# and RETURNED_STATE to kept only when the read proved teardown kept it (the
# lease is held, or no treehouse-state.json lies beside it), else to unread.
RETURNED_REAL=
RETURNED_WHY=
RETURNED_STATE=
returned_slot() {  # <copy> <project>
  local state
  RETURNED_WHY=
  RETURNED_STATE=unread
  if ! RETURNED_REAL=$(fm_mp_real "$1"); then
    RETURNED_WHY="$1 cannot be resolved"
    return 1
  fi
  state="${RETURNED_REAL%/*/*}/treehouse-state.json"
  if [ ! -e "$state" ] && [ ! -L "$state" ]; then
    RETURNED_STATE=kept
    RETURNED_WHY="$RETURNED_REAL is not a Treehouse pool slot: no $state beside it"
    return 1
  fi
  if ! fm_treehouse_pool_slot "$2" "$RETURNED_REAL"; then
    RETURNED_WHY="$RETURNED_REAL cannot be proved a Treehouse pool slot of the project ${2:-<no project recorded>}"
    return 1
  fi
  FM_TASK_COPY_POOL_STATE_FILE=
  FM_TASK_COPY_POOL_STATE_ENTRIES=
  fm_task_copy_pool_slot_held "$RETURNED_REAL" || true
  case "$FM_TASK_COPY_SLOT_STATE" in
    unleased) return 0 ;;
    held)
      RETURNED_STATE=kept
      RETURNED_WHY="the pool slot $RETURNED_REAL is still leased in Treehouse state"
      ;;
    *) RETURNED_WHY="the lease of the pool slot $RETURNED_REAL cannot be read ($FM_TASK_COPY_SLOT_STATE${FM_TASK_COPY_SLOT_REASON:+: $FM_TASK_COPY_SLOT_REASON})" ;;
  esac
  return 1
}

# A copy teardown positively kept ends silently. A read that could not tell is a
# quiet retry from the prune record, which keeps the copy and the project; it
# raises the one wake when the retries run out.
not_returned() {  # <copy> <detail>
  if [ "$RETURNED_STATE" = kept ]; then
    finish_kept "$2" "$RETURNED_WHY"
  else
    backoff "cannot tell whether teardown returned $1: $RETURNED_WHY"
  fi
}

# Teardown succeeded. A slot it returned to the pool is reset in place and stays
# on disk with the task's record gone, so it is removed here with the reaper's
# call (remove_returned). The prune record is cleared only once the copy path is
# gone; the record keeps the copy and the project, so a retry needs no task
# record. A copy teardown kept is left as it is.
settle_copy() {  # <copy> <project> <detail>
  local copy=$1 project=$2 detail=$3
  if [ -z "$copy" ] || [ ! -e "$copy" ]; then
    finish_reaped "$detail"
    return 0
  fi
  R_RETURNED=1
  R_COPY=$copy
  R_PROJECT=$project
  if ! returned_slot "$copy" "$project"; then
    not_returned "$copy" "$detail"
    return 0
  fi
  R_COPY=$RETURNED_REAL
  rec_save "$ID" || log_line "cannot record the returned copy $RETURNED_REAL; removing it now"
  remove_returned "$RETURNED_REAL" "$project" "$detail" || true
}

# Remove the slot that teardown returned, under the project lock that every slot
# allocation takes, once the lease read under that lock still shows it returned.
# Nothing is forced: `treehouse destroy <copy> --include-leased --yes` is the
# call of the fallback and the reaper. A copy that cannot be removed stays with
# the prune record and one wake; the retry resumes from the record alone
# (cmd_run).
remove_returned() {  # <copy> <project> <detail>
  local copy=$1 project=$2 detail=$3 plock rc=0
  if ! plock=$(fm_treehouse_project_lock_path "$project"); then
    backoff "cannot resolve the Treehouse project lock for ${project:-<no project recorded>}"
    return 1
  fi
  if ! fm_project_lock_try "$plock" "merge-prune $ID" >/dev/null 2>&1; then
    backoff "another operation holds or is queued for the task's project lock"
    return 1
  fi
  if returned_slot "$copy" "$project"; then
    remove_returned_locked "$RETURNED_REAL" "$detail" || rc=$?
  else
    not_returned "$copy" "$detail"
  fi
  fm_project_lock_release "$plock" || true
  return "$rc"
}

remove_returned_locked() {  # <real-copy> <detail>
  local real=$1 detail=$2 out rc=0 waited=0 head dest
  fm_treehouse_slot_owner_state "$real" "$ID"
  case "$FM_TREEHOUSE_SLOT_OWNER" in
    mine)
      if ! same_home "$FM_TREEHOUSE_SLOT_OWNER_HOME"; then
        retain "$real" "the pool slot is claimed for task $ID by ${FM_TREEHOUSE_SLOT_OWNER_HOME:-no home}, not by this home"
        return 1
      fi
      ;;
    absent) ;;
    other)
      # The returned slot went to another task's launch: it is theirs, not ours to remove.
      finish_reaped "$detail; the returned slot was taken by task $FM_TREEHOUSE_SLOT_OWNER_ID and was left alone"
      return 0
      ;;
    *)
      retain "$real" "the pool slot's owner claim cannot be read"
      return 1
      ;;
  esac
  fm_mp_find_nested "$real" || { record_verdict "$real"; return 1; }
  prove_nested_git nofetch || { record_verdict "$real"; return 1; }
  until fm_mp_prove_unused "$real" ""; do
    case "$FM_MP_REASON" in
      "process(es) inside"*)
        if [ "$FM_MP_VERDICT" = keep ] && [ "$waited" -lt "$EXIT_WAIT" ]; then
          sleep 1
          waited=$((waited + 1))
          continue
        fi
        ;;
    esac
    record_verdict "$real"
    return 1
  done
  dest="$DATA/$ID/merge-prune-preserved/$NOW"
  preserve_all "$real" "$dest" || return 1
  fm_mp_remove_unignored_nested "$real" || { record_verdict "$real"; return 1; }
  head=$(git -C "$real" rev-parse --short HEAD 2>/dev/null || true)
  out=$(fm_run_timed "$(fm_mp_limit merge-prune.destroy 300)" treehouse destroy "$real" --include-leased --yes </dev/null 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    retain "$real" "treehouse destroy refused or failed: $(clean_detail "$out")"
    return 1
  fi
  if [ -e "$real" ]; then
    retain "$real" "treehouse destroy returned success but the copy is still present"
    return 1
  fi
  log_line "removed the returned copy $real (head ${head:-unknown}); preserved records, if any, are in $dest"
  finish_reaped "$detail; removed the returned copy"
  return 0
}

attempt() {
  local reason wt project
  wt=$(fm_meta_get "$META" worktree)
  project=$(fm_meta_get "$META" project)
  R_PROJECT=$project
  prove_nested_first || return 0
  run_teardown
  if [ "$TD_RC" -eq 0 ]; then
    settle_copy "$wt" "$project" "teardown completed"
    return 0
  fi
  if [ "$TD_RC" -eq "$FM_LEASE_REFUSE_EXIT" ]; then
    backoff "another supervision actor holds the task lease"
    return 0
  fi
  if [ "$TD_RC" -eq "$FM_PROJECT_LOCK_BUSY_EXIT" ]; then
    backoff "another operation holds or is queued for the task's project lock"
    return 0
  fi
  if [ "$TD_RC" -eq 124 ] || [ "$TD_RC" -eq 137 ]; then
    backoff "teardown exceeded 600s"
    return 0
  fi
  reason=$(first_refusal_line "$TD_OUT")
  [ -n "$reason" ] || reason="exit status $TD_RC"
  if [ "$TD_RC" -ne 1 ]; then
    retain "$(fm_meta_get "$META" worktree)" "teardown exit $TD_RC: $reason"
    return 0
  fi
  if transient_refusal "$TD_OUT"; then
    backoff "$reason"
    return 0
  fi
  if ! fallback_allowed "$TD_OUT"; then
    retain "$(fm_meta_get "$META" worktree)" "$reason"
    return 0
  fi
  if [[ ! "$R_PR" =~ ^https://github[.]com/[^/]+/[^/]+/pull/[0-9]+$ ]]; then
    retain "$(fm_meta_get "$META" worktree)" "teardown can finish the records of a removed copy only for a https://github.com/<owner>/<repo>/pull/<n> pull request, and this task records $R_PR"
    return 0
  fi
  # Teardown refused for a reason that may be a false positive: prove the copy
  # is scratch ourselves, and only then let teardown finish the records.
  if ! fallback; then
    return 0
  fi
  run_teardown
  if [ "$TD_RC" -eq 0 ]; then
    settle_copy "$wt" "$project" "removed by fallback, teardown completed"
    return 0
  fi
  reason=$(first_refusal_line "$TD_OUT")
  [ -n "$reason" ] || reason="exit status $TD_RC"
  if [ "$TD_RC" -eq "$FM_LEASE_REFUSE_EXIT" ] || [ "$TD_RC" -eq "$FM_PROJECT_LOCK_BUSY_EXIT" ] \
    || [ "$TD_RC" -eq 124 ] || [ "$TD_RC" -eq 137 ] || transient_refusal "$TD_OUT"; then
    backoff "copy removed; teardown could not finish its records yet: $reason"
    return 0
  fi
  retain "$(fm_meta_get "$META" worktree)" "copy removed but teardown could not finish its records: $reason"
}

cmd_arm() {  # <task-id> [--run]
  local id=${1:-} pr
  [ "${FM_MERGE_PRUNE:-1}" != 0 ] || exit 0
  valid_id "$id" || die "invalid task id"
  [ -d "$STATE" ] || die "state directory not found: $STATE"
  ID=$id
  META="$STATE/$ID.meta"
  [ -f "$META" ] && [ ! -L "$META" ] || exit 0
  case "$(fm_meta_get "$META" kind)" in ''|ship) ;; *) exit 0 ;; esac
  [ -z "$(fm_meta_get "$META" remote_host)" ] || exit 0
  pr=$(fm_meta_get "$META" pr)
  [ -n "$pr" ] || exit 0
  fm_pr_url_parse "$pr" || exit 0
  fm_pr_poll_merge_already_notified "$STATE" "$ID" "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" || exit 0
  LOCK="$STATE/.merge-prune-$ID.lock"
  fm_lock_try_acquire "$LOCK" || exit 0
  if rec_load "$ID" && [ "$R_PR" = "$pr" ]; then
    fm_lock_release "$LOCK" || true
  else
    R_PR=$pr; R_ATTEMPTS=0; R_NEXT=$NOW; R_STATE=pending; R_REASON=; R_WAKE=0; R_COPY=; R_ARMED=$NOW
    rec_save "$ID" || { fm_lock_release "$LOCK" || true; die "cannot write the prune record"; }
    fm_lock_release "$LOCK" || true
    log_line "armed for $pr"
  fi
  if [ "${2:-}" = --run ]; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-merge-prune.sh" run "$ID" --now </dev/null >/dev/null 2>&1 &
  fi
  exit 0
}

cmd_run() {  # <task-id> [--now]
  local id=${1:-} force=0 pr
  [ "${2:-}" != --now ] || force=1
  valid_id "$id" || die "invalid task id"
  [ -d "$STATE" ] || die "state directory not found: $STATE"
  ID=$id
  META="$STATE/$ID.meta"
  LOCK="$STATE/.merge-prune-$ID.lock"
  LOCK_CONTROL="$STATE/.control-$ID.lock"
  [ -e "$STATE/$ID.merge-prune" ] || exit 0
  fm_lock_try_acquire "$LOCK" || exit 0
  trap 'fm_lock_release "$LOCK"' EXIT
  if ! rec_load "$ID"; then
    log_line "dropped an unreadable prune record"
    rm -f -- "$STATE/$ID.merge-prune"
    exit 0
  fi
  if [ "$R_RETURNED" = 1 ] && [ -n "$R_COPY" ] && { [ ! -f "$META" ] || [ -L "$META" ]; }; then
    # Teardown finished and returned the slot; only the removal of its copy is left.
    [ "$force" = 1 ] || [ "$NOW" -ge "$R_NEXT" ] || exit 0
    if [ -e "$R_COPY" ]; then
      remove_returned "$R_COPY" "$R_PROJECT" "teardown completed"
    else
      finish_reaped "teardown completed; the returned copy is gone"
    fi
    exit 0
  fi
  if [ ! -f "$META" ] || [ -L "$META" ]; then
    log_line "task record is gone; nothing left to prune"
    rm -f -- "$STATE/$ID.merge-prune"
    exit 0
  fi
  pr=$(fm_meta_get "$META" pr)
  if [ "$pr" != "$R_PR" ]; then
    log_line "task now records a different PR; dropped the prune record"
    rm -f -- "$STATE/$ID.merge-prune"
    exit 0
  fi
  [ "$force" = 1 ] || [ "$NOW" -ge "$R_NEXT" ] || exit 0
  attempt
  exit 0
}

cmd_sweep() {
  local rec id started=0
  [ -d "$STATE" ] || die "state directory not found: $STATE"
  fm_lock_try_acquire "$SWEEP_LOCK" || exit 0
  trap 'fm_lock_release "$SWEEP_LOCK"' EXIT
  for rec in "$STATE"/*.merge-prune; do
    [ -e "$rec" ] || continue
    id=${rec##*/}
    id=${id%.merge-prune}
    valid_id "$id" || continue
    [ "$started" -lt 3 ] || break
    rec_load "$id" || { rm -f -- "$rec"; continue; }
    [ "$NOW" -ge "$R_NEXT" ] || continue
    started=$((started + 1))
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-merge-prune.sh" run "$id" </dev/null >/dev/null 2>&1 || true
  done
  exit 0
}

case "${1:-}" in
  arm) { [ "$#" -eq 2 ] || { [ "$#" -eq 3 ] && [ "$3" = --run ]; }; } || die "usage: fm-merge-prune.sh arm <task-id> [--run]"; shift; cmd_arm "$@" ;;
  run) { [ "$#" -eq 2 ] || { [ "$#" -eq 3 ] && [ "$3" = --now ]; }; } || die "usage: fm-merge-prune.sh run <task-id> [--now]"; shift; cmd_run "$@" ;;
  sweep) [ "$#" -eq 1 ] || die "usage: fm-merge-prune.sh sweep"; cmd_sweep ;;
  -h|--help) usage ;;
  *) die "usage: fm-merge-prune.sh arm|run|sweep" ;;
esac
