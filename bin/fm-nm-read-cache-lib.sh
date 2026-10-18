#!/usr/bin/env bash
# Per-task read cache for the no-mistakes queries bin/fm-crew-state.sh makes.
#
# Why this exists: every supervision watcher, fleet snapshot and sweep calls
# fm-crew-state.sh for each in-flight task, and one read costs two to five
# bounded `no-mistakes` calls. Each `axi status` runs a git scan of the run's
# worktree, so re-reading a finished run (whose answer cannot change) as often
# as a live one was a standing source of kernel load. This cache removes those
# repeats without changing what any read classifies.
#
# Contract: only a finished run is ever stored or served. Every other read - a
# run still in flight, a branch with no run, a failed or timed-out call, an
# empty, malformed or unknown answer, the daemon probe, the runs listing - is
# made fresh on every call exactly as it was before this cache, and is never
# stored. A live run therefore always gets a fresh read, and a failure is never
# replayed. A disabled cache (FM_CREW_STATE_NM_CACHE=off) runs every call fresh.
#
# Scope: fm-crew-state.sh only. bin/fm-nm-run-lib.sh stays uncached because
# fm-teardown.sh and fm-dod-lib.sh need fresh reads to act on.
#
# Storage: $STATE/.nm-read-cache-<task-id>/<key>, one atomically replaced file
# per entry, removed by bin/fm-teardown.sh and safe to delete at any time. Keys:
#   status       the bare `axi status`
#   choice       fm_nm_select_run's verdict on the `axi` overview
#   run-<id>     `axi status --run <id>`
#   ci-<id>      `axi logs --step ci --run <id> --full`
# An entry holds a header (magic, finished run id, worktree, branch) and then
# the call's stdout byte for byte. Only a successful call is stored.
#
# What counts as finished: a run of this branch that is completed, failed or
# cancelled. A status or id-addressed read must also carry a settled outcome
# (passed, passed-with-override, passed-with-skips, failed or cancelled),
# because an outcome that can still change (checks-passed becomes passed at the
# merge) keeps the run live; the ci log is kept only for the run
# its caller names as finished; the choice entry only for a completed, failed or
# cancelled selection. A finished run's answer cannot change, so it is kept
# until the run id changes:
#   - An id-addressed entry (run-<id>, ci-<id>) never expires.
#   - The id-less entries (status, choice) are served only while the
#     no-mistakes database still names that run as the NEWEST run for the
#     branch and still terminal (fm_nmc_fin_valid), one read-only query instead
#     of the calls it replaces. When the database cannot be read the entry is a
#     miss, never a guess.
#
# What a hit returns: the stdout of the most recent fresh read of that call.
# `axi status` appends a branch_sync block that describes the invoking
# worktree's current git state, which a finished run's replay does not refresh.
# fm-crew-state.sh reads branch_sync only to bind a run that is still active
# (fm_nm_run_is_pipeline_owned_active), never for a finished one, so no
# classification can differ.
#
# Callers: fm_nmc_init once, then fm_nmc_read (prints) or fm_nmc_read_to
# (assigns, no subshell, so the database check is shared), and fm_nmc_lookup,
# fm_nmc_classify_choice, fm_nmc_put for the composite choice entry.
if ! declare -F fm_nm_run_checked >/dev/null 2>&1; then
  # shellcheck source=bin/fm-nm-run-lib.sh
  . "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/fm-nm-run-lib.sh"
fi

FM_NMC_ENABLED=0
FM_NMC_DIR=''
FM_NMC_WT=''
FM_NMC_BRANCH=''
FM_NMC_TIMEOUT=''
FM_NMC_FIN_ID=''
FM_NMC_FIN_OK=1
FM_NMC_FIN=-
FM_NMC_BODY=''
FM_NMC_RC=0

FM_NMC_OWN_RUN_RE=$'(^|\n)run:'
FM_NMC_FOREIGN_RE=$'(^|\n)other_branch_(active_)?run:'

# <state-dir> <task-id> <worktree> <branch> <timeout-secs>
# Always records the worktree and bound so an uncached read still runs; enables
# the cache only for a writable state directory and a branch to key on.
fm_nmc_init() {
  FM_NMC_ENABLED=0
  FM_NMC_WT=$3
  FM_NMC_BRANCH=$4
  FM_NMC_TIMEOUT=$5
  case "${FM_CREW_STATE_NM_CACHE:-on}" in off) return 0 ;; esac
  [ -n "$3" ] && [ -n "$4" ] && [ -d "$1" ] && [ -w "$1" ] || return 0
  case "$2" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  FM_NMC_DIR="$1/.nm-read-cache-$2"
  FM_NMC_FIN_ID=''
  FM_NMC_ENABLED=1
}

fm_nmc_valid_id() {  # <run-id>
  case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
}

# Newest run for the branch within the repository of run $1, as "<id> <status>",
# straight from the state database fm_nm_state_db locates. Read only, bounded
# like every other call, and silent on any failure.
fm_nmc_db_newest_run() {  # <run-id>
  fm_nm_bounded "$FM_NMC_WT" "$FM_NMC_TIMEOUT" python3 - "$1" "$FM_NMC_BRANCH" "$(fm_nm_state_db "$FM_NMC_WT")" "$FM_NMC_TIMEOUT" 2>/dev/null <<'PY'
import sqlite3
import sys
from contextlib import closing
from pathlib import Path

run_id, branch, database, bound = sys.argv[1:]
try:
    with closing(sqlite3.connect(Path(database).as_uri() + "?mode=ro", uri=True, timeout=float(bound))) as db:
        row = db.execute(
            "SELECT id, status FROM runs WHERE repo_id = (SELECT repo_id FROM runs WHERE id = ?) "
            "AND branch = ? ORDER BY created_at DESC, id DESC LIMIT 1", (run_id, branch)
        ).fetchone()
except sqlite3.Error:
    sys.exit(1)
if row and all(isinstance(value, str) for value in row):
    print(row[0], row[1])
PY
}

# 0 when finished run $1 is still the newest run for the branch and still
# terminal. Asked once per process and run, so the entries that depend on it
# share one query; callers keep it out of command substitutions to share it.
fm_nmc_fin_valid() {  # <run-id>
  local out
  fm_nmc_valid_id "$1" || return 1
  if [ "$FM_NMC_FIN_ID" != "$1" ]; then
    FM_NMC_FIN_ID=$1
    FM_NMC_FIN_OK=1
    out=$(fm_nmc_db_newest_run "$1") || out=''
    case "$out" in
      "$1 completed"|"$1 failed"|"$1 cancelled") FM_NMC_FIN_OK=0 ;;
    esac
  fi
  return "$FM_NMC_FIN_OK"
}

# Sets FM_NMC_BODY and FM_NMC_RC (0) and returns 0 for a finished-run entry
# under <key> that is still in force.
fm_nmc_lookup() {  # <key>
  local key=$1 file magic fin wt branch body=''
  [ "$FM_NMC_ENABLED" = 1 ] || return 1
  file="$FM_NMC_DIR/$key"
  [ -f "$file" ] || return 1
  {
    IFS= read -r magic && IFS= read -r fin && IFS= read -r wt && IFS= read -r branch || return 1
    IFS= read -r -d '' body || :
  } < "$file" 2>/dev/null || return 1
  [ "$magic" = fmnm1 ] && [ "$wt" = "$FM_NMC_WT" ] && [ "$branch" = "$FM_NMC_BRANCH" ] || return 1
  case "$key" in
    status|choice) fm_nmc_fin_valid "$fin" || return 1 ;;
    run-*|ci-*) [ "$key" = "${key%%-*}-$fin" ] || return 1 ;;
    *) return 1 ;;
  esac
  FM_NMC_BODY=$body
  FM_NMC_RC=0
}

# Keeps one id-addressed entry per prefix: a newer run replaces the older ones.
fm_nmc_prune_ids() {  # <key>
  local prefix f
  case "$1" in run-*) prefix=run- ;; ci-*) prefix=ci- ;; *) return 0 ;; esac
  for f in "$FM_NMC_DIR/$prefix"*; do
    [ -e "$f" ] || continue
    [ "$f" = "$FM_NMC_DIR/$1" ] || rm -f "$f"
  done
}

# Stores <stdout> under <key> for finished run <finished-run-id>. Callers store
# only after fm_nmc_classify or fm_nmc_classify_choice returned 0.
fm_nmc_put() {  # <key> <finished-run-id> <stdout>
  local entry f
  [ "$FM_NMC_ENABLED" = 1 ] || return 0
  [ -d "$FM_NMC_DIR" ] || mkdir -p "$FM_NMC_DIR" 2>/dev/null || return 0
  for f in "$FM_NMC_DIR"/.tmp.*; do
    [ -e "$f" ] || continue
    find "$FM_NMC_DIR" -maxdepth 1 -name '.tmp.*' -mmin +10 -exec rm -f {} + 2>/dev/null || :
    break
  done
  entry="$FM_NMC_DIR/.tmp.${BASHPID:-$$}"
  {
    printf 'fmnm1\n%s\n%s\n%s\n' "$2" "$FM_NMC_WT" "$FM_NMC_BRANCH"
    printf '%s' "$3"
  } > "$entry" 2>/dev/null || { rm -f "$entry"; return 0; }
  mv -f "$entry" "$FM_NMC_DIR/$1" 2>/dev/null || { rm -f "$entry"; return 0; }
  fm_nmc_prune_ids "$1"
}

# Returns 0 and sets FM_NMC_FIN to the run id when one answer shows a finished
# run. <kind> is status (the bare `axi status`), status-run (an id-addressed
# read, <hint> its run id) or logs (<hint> names the run when the caller knows
# it is finished). Anything else, and any failed call, returns 1.
fm_nmc_classify() {  # <kind> <exit-status> <stdout> [hint]
  local kind=$1 rc=$2 body=$3 hint=${4:-} id='' branch='' status='' outcome=''
  FM_NMC_FIN=-
  [ "$rc" = 0 ] && [ -n "$body" ] || return 1
  case "$kind" in
    logs)
      fm_nmc_valid_id "$hint" || return 1
      FM_NMC_FIN=$hint
      return 0
      ;;
    status|status-run) ;;
    *) return 1 ;;
  esac
  [[ $body =~ $FM_NMC_OWN_RUN_RE ]] && ! [[ $body =~ $FM_NMC_FOREIGN_RE ]] || return 1
  fm_nm_field_to id "$body" id || return 1
  fm_nm_strip_quotes_to id "$id"
  fm_nm_field_to branch "$body" branch || return 1
  fm_nm_strip_quotes_to branch "$branch"
  [ "$branch" = "$FM_NMC_BRANCH" ] || return 1
  [ "$kind" != status-run ] || [ "$id" = "$hint" ] || return 1
  fm_nm_field_to status "$body" status || return 1
  fm_nm_strip_quotes_to status "$status"
  fm_nm_field_to outcome "$body" outcome || return 1
  fm_nm_strip_quotes_to outcome "$outcome"
  case "$status" in completed|failed|cancelled) ;; *) return 1 ;; esac
  case "$outcome" in
    passed|passed-with-override|passed-with-skips|failed|cancelled) ;;
    *) return 1 ;;
  esac
  fm_nmc_valid_id "$id" || return 1
  FM_NMC_FIN=$id
}

# Returns 0 and sets FM_NMC_FIN when the composite overview verdict <choice>, as
# fm_nm_select_run prints it, selects a finished run. <overview-ok> and
# <overview-present> are the 0/1 flags of that read.
fm_nmc_classify_choice() {  # <choice> <overview-ok> <overview-present>
  local id='' status=''
  FM_NMC_FIN=-
  [ "$2" = 1 ] && [ "$3" = 1 ] || return 1
  case "$1" in selected\|*) ;; *) return 1 ;; esac
  IFS='|' read -r _ id status _ <<< "$1"
  case "$status" in completed|failed|cancelled) ;; *) return 1 ;; esac
  fm_nmc_valid_id "$id" || return 1
  FM_NMC_FIN=$id
}

# The bounded call with the cache in front of it. Sets FM_NMC_BODY (stdout,
# byte for byte) and FM_NMC_RC (exit status).
fm_nmc_read_core() {  # <key> <kind> <hint> <no-mistakes args...>
  local key=$1 kind=$2 hint=$3 out
  shift 3
  if fm_nmc_valid_id "$key" && fm_nmc_lookup "$key"; then
    return 0
  fi
  out=$(fm_nm_run_checked "$FM_NMC_WT" "$FM_NMC_TIMEOUT" "$@"; printf '\037%s' "$?")
  FM_NMC_RC=${out##*$'\037'}
  FM_NMC_BODY=${out%$'\037'*}
  if [ "$FM_NMC_ENABLED" = 1 ] && fm_nmc_valid_id "$key" \
    && fm_nmc_classify "$kind" "$FM_NMC_RC" "$FM_NMC_BODY" "$hint"; then
    fm_nmc_put "$key" "$FM_NMC_FIN" "$FM_NMC_BODY"
  fi
  return 0
}

fm_nmc_read() {  # <key> <kind> <hint> <args...>
  fm_nmc_read_core "$@"
  printf '%s' "$FM_NMC_BODY"
  return "$FM_NMC_RC"
}

# Assigns <out-var> what `$(fm_nmc_read ...)` would print, without a subshell.
fm_nmc_read_to() {  # <out-var> <key> <kind> <hint> <args...>
  local _fm_nmc_out=$1 _fm_nmc_text
  shift
  fm_nmc_read_core "$@"
  _fm_nmc_text=$FM_NMC_BODY
  _fm_nmc_text=${_fm_nmc_text%"${_fm_nmc_text##*[!$'\n']}"}
  printf -v "$_fm_nmc_out" '%s' "$_fm_nmc_text"
  return "$FM_NMC_RC"
}
