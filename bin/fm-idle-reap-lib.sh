#!/usr/bin/env bash

FM_IDLE_REAP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_IDLE_REAP_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$FM_IDLE_REAP_LIB_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$FM_IDLE_REAP_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$FM_IDLE_REAP_LIB_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$FM_IDLE_REAP_LIB_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_IDLE_REAP_LIB_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-merge-prune-lib.sh
. "$FM_IDLE_REAP_LIB_DIR/fm-merge-prune-lib.sh"

fm_idle_reap_terminal_age() {
  local line=$1 evidence=$2 now=$3 at m newest
  if ! at=$(status_line_at_epoch "$line" 2>/dev/null) || [ -z "$at" ] \
    || ! m=$(fm_path_mtime "$evidence") || [ -z "$m" ]; then
    printf '0'
    return 0
  fi
  newest=$at
  [ "$m" -le "$newest" ] || newest=$m
  if [ "$newest" -le 0 ] || [ "$newest" -gt "$now" ]; then
    printf '0'
  else
    printf '%s' $((now - newest))
  fi
}

fm_idle_reap_refusal_stands() {
  local memo=$1 line=$2 now=$3 version at fingerprint reason
  [ -f "$memo" ] && [ ! -L "$memo" ] || return 1
  { IFS= read -r version && IFS= read -r at && IFS= read -r fingerprint && IFS= read -r reason; } < "$memo" 2>/dev/null || return 1
  [ "$version" = fm-idle-reap-refused-v1 ] || return 1
  case "$at" in ''|*[!0-9]*) return 1 ;; esac
  [ "$fingerprint" = "$line" ] || return 1
  [ $((now - at)) -lt 21600 ] || return 1
  IDLE_REAP_DETAIL=$reason
}

# A closeout-retained copy is held, not retried. When teardown's refusal is
# Vernant's closeout driver exiting 3 with the top-level reason
# cleanup_ignored_payload_archived_tree_retained, every teardown try writes one
# more byte-identical archive of the copy's ignored files and keeps the tree, so
# trying again against the unchanged copy only fills the disk. Both automatic
# cleanup sweeps (bin/fm-idle-session-reap.sh, bin/fm-merge-prune.sh) share one
# record, state/.closeout-retained/<task-id>, owned here: mode 0600, a regular
# file, rewritten atomically, with one line each for the version
# (fm-closeout-retained-v1), the epoch, the refusal class and wake_sent=0|1,
# then one `<HEAD> <digest of git status> <path>` line for the task copy and for
# each copy the refusal names. The record is written after the refusing try, so
# it holds what the driver left behind. It stands while those lines read the
# same again, with no age limit. wake_sent lives in the record, so the one wake
# is not raised again after the queue is drained. A completed teardown clears
# it. Only the printed refusal decides the class (fm_closeout_retained_class),
# never the token elsewhere in the output. A copy that cannot be read as a git
# repository gives no record, so its retry stays as it was.
# Both sweeps take the task's closeout lock (fm_closeout_lock_take, never
# waited for) around the whole of one attempt: the record check, the teardown,
# the record write and the wake. A sweep that finds the lock busy skips the task
# this round, so no second teardown starts before the first refusal is on
# record, and the wake_sent decision, the queue append and the record update
# cannot interleave between the two processes. A record that no longer reads the
# same (fm_closeout_retained_check says "changed") lifts the hold at once; it
# does not wait for the older refusal memo to age out.
FM_CLOSEOUT_RETAINED_CLASS=cleanup_ignored_payload_archived_tree_retained
CLOSEOUT_RETAINED_PATHS=()
CLOSEOUT_RETAINED_ENTRIES=()
CLOSEOUT_RETAINED_WAKE=0

fm_closeout_retained_reason() {
  printf '%s' "the closeout driver retained the copy and archived its ignored files; it is not retried while the copy is unchanged; a human or Main decides the release"
}

# Succeeds when every refusal line of <teardown-output> is a closeout-driver
# refusal with (exit 3), at least one exists, and the driver's one JSON line
# has the retained class as its top-level reason. Sets CLOSEOUT_RETAINED_PATHS
# to the copies the refusal lines name. The JSON line can be hundreds of KB, so
# it goes to python on stdin.
fm_closeout_retained_class() {  # <teardown-output>
  local paths path
  CLOSEOUT_RETAINED_PATHS=()
  paths=$(printf '%s' "$1" | python3 -I -c '
import json, re, sys
want = sys.argv[1]
line_re = re.compile(r"REFUSED: Vernant'"'"'s closeout driver did not release (?:own nested|foreign) copy (.+?) \(exit 3\): (?:full output: .+|full output could not be saved under .+)")
paths, docs = [], []
for line in sys.stdin.buffer.read().decode("utf-8", "surrogateescape").split("\n"):
    if line.startswith(("REFUSED", "error:", "refused")):
        m = line_re.fullmatch(line)
        if m is None:
            sys.exit(1)
        paths.append(m.group(1))
    elif line[:1] in (" ", "\t") and line.lstrip().startswith("{\"allowed\":"):
        docs.append(line)
if not paths or len(docs) != 1:
    sys.exit(1)
try:
    doc = json.loads(docs[0])
except Exception:
    sys.exit(1)
if not isinstance(doc, dict) or doc.get("reason") != want:
    sys.exit(1)
sys.stdout.buffer.write("\n".join(paths).encode("utf-8", "surrogateescape"))
' "$FM_CLOSEOUT_RETAINED_CLASS" 2>/dev/null) || return 1
  while IFS= read -r path; do
    [ -z "$path" ] || CLOSEOUT_RETAINED_PATHS+=("$path")
  done <<CLOSEOUT_PATHS
$paths
CLOSEOUT_PATHS
  [ "${#CLOSEOUT_RETAINED_PATHS[@]}" -gt 0 ]
}

# One fingerprint line for <path>; fails when it cannot be read as a git
# repository. Untracked files are listed one by one, so a new file inside an
# untracked directory changes the digest too.
fm_closeout_retained_entry() {  # <path>
  local p=$1 head digest
  [ -n "$p" ] && [ -d "$p" ] && [ -e "$p/.git" ] || return 1
  head=$(git --no-optional-locks -C "$p" rev-parse --verify -q HEAD 2>/dev/null) && [ -n "$head" ] || return 1
  digest=$(set -o pipefail; git --no-optional-locks -C "$p" status --porcelain=v1 -z --untracked-files=all 2>/dev/null \
    | git hash-object --stdin 2>/dev/null) && [ -n "$digest" ] || return 1
  printf '%s %s %s' "$head" "$digest" "$p"
}

# Writes the record from CLOSEOUT_RETAINED_ENTRIES, atomically.
fm_closeout_retained_write() {  # <state> <id> <wake-sent>
  local dir="$1/.closeout-retained" tmp now entry
  [ ! -L "$dir" ] || return 1
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp=$(mktemp "$dir/.new.XXXXXX" 2>/dev/null) || return 1
  fm_epoch_seconds_to now
  if {
    printf 'fm-closeout-retained-v1\n%s\n%s\nwake_sent=%s\n' "$now" "$FM_CLOSEOUT_RETAINED_CLASS" "$3"
    for entry in "${CLOSEOUT_RETAINED_ENTRIES[@]}"; do printf '%s\n' "$entry"; done
  } > "$tmp" && chmod 0600 "$tmp" && mv -f -- "$tmp" "$dir/$2"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# Loads the record into CLOSEOUT_RETAINED_ENTRIES and CLOSEOUT_RETAINED_WAKE.
fm_closeout_retained_read() {  # <state> <id>
  local file="$1/.closeout-retained/$2" n=0 line version="" at="" class="" wake=""
  CLOSEOUT_RETAINED_ENTRIES=()
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$n" in
      1) version=$line ;;
      2) at=$line ;;
      3) class=$line ;;
      4) wake=$line ;;
      *) CLOSEOUT_RETAINED_ENTRIES+=("$line") ;;
    esac
  done < "$file"
  [ "$version" = fm-closeout-retained-v1 ] && [ "$class" = "$FM_CLOSEOUT_RETAINED_CLASS" ] || return 1
  case "$at" in ''|*[!0-9]*) return 1 ;; esac
  case "$wake" in
    wake_sent=0) CLOSEOUT_RETAINED_WAKE=0 ;;
    wake_sent=1) CLOSEOUT_RETAINED_WAKE=1 ;;
    *) return 1 ;;
  esac
  [ "${#CLOSEOUT_RETAINED_ENTRIES[@]}" -gt 0 ]
}

# After a refusing teardown try: writes the record when <teardown-output> is
# the retained class and the task copy <worktree> and every copy the refusal
# names can be fingerprinted. A new record starts with its wake unsent.
fm_closeout_retained_record() {  # <state> <id> <worktree> <teardown-output>
  local p e dup entries=()
  fm_closeout_retained_class "$4" || return 1
  e=$(fm_closeout_retained_entry "$3") || return 1
  entries+=("$e")
  for p in "${CLOSEOUT_RETAINED_PATHS[@]}"; do
    dup=0
    for e in "${entries[@]}"; do [ "${e#* * }" != "$p" ] || dup=1; done
    [ "$dup" = 0 ] || continue
    e=$(fm_closeout_retained_entry "$p") || return 1
    entries+=("$e")
  done
  CLOSEOUT_RETAINED_ENTRIES=("${entries[@]}")
  fm_closeout_retained_write "$1" "$2" 0
}

# Reads the record against the copy as it is now. Succeeds, with
# CLOSEOUT_RETAINED_STATE=stands, when the record exists, its first line is for
# the task copy <worktree>, and every copy it names still reads the same; the
# record's wake flag is then in CLOSEOUT_RETAINED_WAKE. It fails with "changed"
# when a copy reads differently (HEAD, tracked changes or untracked files) or
# the task copy moved, and with "none" when there is no valid record or a copy
# cannot be read now (that copy's hold then stays as it was).
CLOSEOUT_RETAINED_STATE=none
fm_closeout_retained_check() {  # <state> <id> <worktree>
  local e p first=1 now
  CLOSEOUT_RETAINED_STATE=none
  fm_closeout_retained_read "$1" "$2" || return 1
  for e in "${CLOSEOUT_RETAINED_ENTRIES[@]}"; do
    p=${e#* * }
    if [ "$first" = 1 ]; then
      [ "$p" = "$3" ] || { CLOSEOUT_RETAINED_STATE=changed; return 1; }
      first=0
    fi
    now=$(fm_closeout_retained_entry "$p") || return 1
    [ "$now" = "$e" ] || { CLOSEOUT_RETAINED_STATE=changed; return 1; }
  done
  CLOSEOUT_RETAINED_STATE=stands
}

# The task's closeout lock: one holder at a time across both sweeps, taken
# without waiting and recovered by the shared lock library when its owner is
# gone. Release it with fm_closeout_lock_drop.
fm_closeout_lock_take() {  # <state> <id>
  mkdir -p "$1/.closeout-lock" 2>/dev/null || return 1
  fm_lock_try_acquire "$1/.closeout-lock/$2"
}

fm_closeout_lock_drop() {  # <state> <id>
  fm_lock_release "$1/.closeout-lock/$2" || true
}

# Marks the wake as sent. Call it only after the queue took the wake.
fm_closeout_retained_mark_wake() {  # <state> <id>
  fm_closeout_retained_read "$1" "$2" || return 1
  fm_closeout_retained_write "$1" "$2" 1
}

# The one wake of a record: appended only while wake_sent is 0 and marked only
# after the append succeeded, so a failed append is raised again next time. The
# caller holds the task's closeout lock, so the read, the append and the mark
# are one step across both sweeps.
fm_closeout_retained_wake() {  # <state> <id> <wake-key> <wake-text>
  fm_closeout_retained_read "$1" "$2" || return 1
  [ "$CLOSEOUT_RETAINED_WAKE" = 0 ] || return 0
  fm_wake_append check "$3" "$4" || return 1
  fm_closeout_retained_mark_wake "$1" "$2"
}

fm_closeout_retained_clear() {  # <state> <id>
  rm -f -- "$1/.closeout-retained/$2"
}

# A standing refusal that keeps the task out of the next sweep: a standing
# closeout record (no age limit) or the refusal memo.
fm_idle_reap_refusal_holds() {  # <state> <id> <status-line> <now>
  local wt
  wt=$(fm_meta_get "$1/$2.meta" worktree)
  if [ -n "$wt" ]; then
    if fm_closeout_retained_check "$1" "$2" "$wt"; then
      # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
      IDLE_REAP_HELD=closeout
      IDLE_REAP_DETAIL=$(fm_closeout_retained_reason)
      return 0
    fi
    # The older refusal memo describes the earlier fingerprint of the copy.
    [ "$CLOSEOUT_RETAINED_STATE" != changed ] || return 1
  fi
  fm_idle_reap_refusal_stands "$1/.idle-reap/$2.refused" "$3" "$4"
}

# FM_IDLE_REAP_MERGE_PRUNE=1 is set by bin/fm-merge-prune.sh, which asks about a
# task the moment its merge is verified: the grace period is waived and an old
# refusal memo is ignored (the prune keeps its own backoff). Every other gate
# stands. A worker stopped with `fm-control.sh exit` (by the prune, or before the
# merge) has no busy record and leaves state/<id>.control-exit; in this mode that
# worker reads as stopped, not as unknown, only when its terminal pane positively
# shows no live agent (fm_mp_pane_agent_gone: only shells are left in it, and at
# most the one `treehouse get` that opened the slot's subshell). A pane that
# cannot be read proves nothing. A worker that reads busy is never accepted.
# Its last event must still be `done`, which the checks after the busy gate
# require.
fm_idle_reap_exited_by_control() {  # <state> <id>
  [ "${FM_IDLE_REAP_MERGE_PRUNE:-0}" = 1 ] || return 1
  [ "$(fm_busy_record_read "$1" "$2")" = missing ] || return 1
  [ -f "$1/$2.control-exit" ] && [ ! -L "$1/$2.control-exit" ] || return 1
  fm_mp_pane_agent_gone "$1/$2.meta"
}

# A captain hold that declares this task's project frozen, in this home or in
# any local home above a secondmate home, stops every automatic cleanup of it,
# whether or not the task has a hold of its own. The answer is
# bin/fm-captain-hold.sh frozen; an answer it cannot establish also stops
# cleanup and names its reason. Sets the parked class and its reason and
# returns 0 when the task is frozen or unsure, and returns 1 when nothing
# freezes it.
fm_idle_reap_frozen() {  # <home> <state> <data> <id>
  local out rc=0 project last
  out=$(FM_HOME="$1" FM_STATE_OVERRIDE="$2" FM_DATA_OVERRIDE="$3" \
    "$FM_IDLE_REAP_LIB_DIR/fm-captain-hold.sh" frozen "$4" 2>&1) || rc=$?
  last=${out##*$'\n'}
  case "$rc" in
    0)
      project=$(fm_meta_get "$2/$4.meta" project)
      project=${project%/}
      IDLE_REAP_DETAIL="frozen by captain hold $last: project ${project##*/} is frozen until the captain releases it"
      ;;
    1) return 1 ;;
    *) IDLE_REAP_DETAIL="captain freeze unreadable: ${last#fm-captain-hold: }; cleanup ineligible" ;;
  esac
  IDLE_REAP_CLASS=parked
  return 0
}

fm_idle_reap_classify() {
  local home=$1 state=$2 data=$3 id=$4 meta="$2/$4.meta" pr remote busy verb note status declared msg evidence open age now hold_rc=0
  local grace=1800 memo_applies=1
  if [ "${FM_IDLE_REAP_MERGE_PRUNE:-0}" = 1 ]; then
    grace=0
    memo_applies=0
  fi
  IDLE_REAP_CLASS=active
  IDLE_REAP_KIND=-
  IDLE_REAP_AGE=-
  IDLE_REAP_DETAIL="missing or unreadable metadata"
  IDLE_REAP_LAST=
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  IDLE_REAP_HELD=
  [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || return 0
  IDLE_REAP_KIND=$(fm_meta_get "$meta" kind)
  [ -n "$IDLE_REAP_KIND" ] || IDLE_REAP_KIND=ship
  pr=$(fm_meta_get "$meta" pr)
  remote=$(fm_meta_get "$meta" remote_host)
  if [ "$IDLE_REAP_KIND" = secondmate ]; then
    IDLE_REAP_CLASS=secondmate
    IDLE_REAP_DETAIL="persistent; never reaped here"
    return 0
  fi
  if [ -n "$remote" ]; then
    IDLE_REAP_CLASS=remote
    IDLE_REAP_DETAIL="remote task on $remote; its host owns cleanup"
    return 0
  fi
  case "$IDLE_REAP_KIND" in
    ship|scout) ;;
    *) IDLE_REAP_CLASS=parked; IDLE_REAP_DETAIL="not an ordinary ship or scout"; return 0 ;;
  esac
  status="$state/$id.status"
  IDLE_REAP_LAST=$(last_status_line "$status")
  # A teardown admitted this task, reserved its slot and was interrupted; it
  # may already have retired the busy state and status read below. Only a
  # worker that reads busy again keeps it from the next sweep.
  if fm_teardown_return_pending "$state" "$id"; then
    busy=$(fm_busy_classify_meta "$meta" "$id" "$state")
    if [ "${busy%% *}" = busy ]; then
      IDLE_REAP_DETAIL="busy state $busy"
      return 0
    fi
    fm_epoch_seconds_to now
    if [ "$memo_applies" = 1 ] \
      && fm_idle_reap_refusal_holds "$state" "$id" "$IDLE_REAP_LAST" "$now"; then
      IDLE_REAP_CLASS=refused
      return 0
    fi
    if fm_idle_reap_frozen "$home" "$state" "$data" "$id"; then
      return 0
    fi
    IDLE_REAP_CLASS=reap
    IDLE_REAP_DETAIL="closed by teardown; its pool slot return is pending"
    return 0
  fi
  declared=$(status_declared_wait_line "$status")
  if status_is_paused_or_captain_held "$declared"; then
    status_line_verb "$declared" verb
    IDLE_REAP_CLASS=parked
    IDLE_REAP_DETAIL="$verb: $(status_line_note "$declared")"
    return 0
  fi
  status_line_verb "$IDLE_REAP_LAST" verb
  note=$(status_line_note "$IDLE_REAP_LAST")
  case "$verb" in
    blocked|needs-decision|failed)
      IDLE_REAP_CLASS=parked; IDLE_REAP_DETAIL="$verb: $note"; return 0 ;;
  esac
  busy=$(fm_busy_classify_meta "$meta" "$id" "$state")
  if [ "${busy%% *}" != idle ] \
    && { [ "${busy%% *}" = busy ] || ! fm_idle_reap_exited_by_control "$state" "$id"; }; then
    IDLE_REAP_DETAIL="busy state $busy"
    return 0
  fi
  for msg in "$state/$id.inbox"/*.msg; do
    if [ -e "$msg" ]; then
      IDLE_REAP_CLASS=steer-pending
      IDLE_REAP_DETAIL="unhandled instruction ${msg##*/}"
      return 0
    fi
  done
  if [ -z "$IDLE_REAP_LAST" ]; then
    IDLE_REAP_CLASS=idle-unreported
    IDLE_REAP_DETAIL="idle with no status event"
    return 0
  fi
  case "$verb" in
    done) ;;
    *) IDLE_REAP_CLASS=idle-unreported; IDLE_REAP_DETAIL="idle after $verb: $note"; return 0 ;;
  esac
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    "$FM_IDLE_REAP_LIB_DIR/fm-captain-hold.sh" open "$id" >/dev/null 2>&1 || hold_rc=$?
  if [ "$hold_rc" != 1 ]; then
    IDLE_REAP_CLASS=parked
    if [ "$hold_rc" = 0 ]; then
      IDLE_REAP_DETAIL="captain-held: waiting for captain answer"
    else
      IDLE_REAP_DETAIL="captain hold unreadable; cleanup ineligible"
    fi
    return 0
  fi
  if ! open=$(status_open_decisions "$status" "$IDLE_REAP_KIND"); then
    IDLE_REAP_CLASS=parked
    IDLE_REAP_DETAIL="status log unreadable past the read limits; cleanup ineligible"
    return 0
  fi
  if [ -n "$open" ]; then
    IDLE_REAP_CLASS=parked
    IDLE_REAP_DETAIL="open decision: ${open%%$'\n'*}"
    return 0
  fi
  if [ "$IDLE_REAP_KIND" = scout ]; then
    evidence="$data/$id/report.md"
    if [ ! -f "$evidence" ] || [ -L "$evidence" ] || [ ! -s "$evidence" ]; then
      IDLE_REAP_CLASS=scout-noreport
      IDLE_REAP_DETAIL="done without a nonempty data/$id/report.md"
      return 0
    fi
  else
    if [ -z "$pr" ]; then
      IDLE_REAP_CLASS=awaiting-pipeline
      IDLE_REAP_DETAIL="done; no pull request recorded yet"
      return 0
    fi
    evidence="$state/$id.pr-poll-merge-notified"
    if ! fm_pr_url_parse "$pr" || ! fm_pr_poll_merge_already_notified "$state" "$id" \
      "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"; then
      IDLE_REAP_CLASS=awaiting-merge
      IDLE_REAP_DETAIL="done; $pr not recorded merged"
      return 0
    fi
  fi
  fm_epoch_seconds_to now
  age=$(fm_idle_reap_terminal_age "$IDLE_REAP_LAST" "$evidence" "$now")
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  IDLE_REAP_AGE=$age
  if [ "$age" -lt "$grace" ]; then
    IDLE_REAP_CLASS=wait-grace
    IDLE_REAP_DETAIL="finished ${age}s ago; grace is ${grace}s"
    return 0
  fi
  if [ "$memo_applies" = 1 ] \
    && fm_idle_reap_refusal_holds "$state" "$id" "$IDLE_REAP_LAST" "$now"; then
    IDLE_REAP_CLASS=refused
    return 0
  fi
  if fm_idle_reap_frozen "$home" "$state" "$data" "$id"; then
    return 0
  fi
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  IDLE_REAP_CLASS=reap
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  IDLE_REAP_DETAIL="finished and idle"
}
