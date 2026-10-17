#!/usr/bin/env bash
# Per-task read cache for the no-mistakes queries bin/fm-crew-state.sh makes.
#
# Why this exists: every supervision watcher, fleet snapshot and sweep calls
# fm-crew-state.sh for each in-flight task, and one read costs two to five
# bounded `no-mistakes` calls. Each `axi status` runs a git scan of the run's
# worktree, so re-reading a finished run (whose answer cannot change) as often
# as a live one was a standing source of kernel load. This cache removes the
# repeats without changing what any read classifies.
#
# Scope: fm-crew-state.sh only. bin/fm-nm-run-lib.sh stays uncached because
# fm-teardown.sh and fm-dod-lib.sh need fresh reads to act on.
#
# Storage: $STATE/.nm-read-cache-<task-id>/<key>, one atomically replaced file
# per call, removed by bin/fm-teardown.sh and safe to delete at any time. Keys:
#   status       the bare `axi status`
#   choice       the `axi` overview plus fm_nm_select_run's verdict, as a pair
#   run-<id>     `axi status --run <id>`
#   ci-<id>      `axi logs --step ci --run <id> --full`
#   daemon       `daemon status`
#   runs-<n>     `runs --limit <n>`
# An entry holds a header (magic, start epoch, exit status, class, finished
# run id, worktree, branch) and then the call's stdout byte for byte. The start
# epoch and the file's mtime both record when the read STARTED, so a status
# append that lands while the read runs still invalidates the entry.
#
# Entry classes, decided from the answer itself by fm_nmc_classify:
#   fin   a finished run (completed, failed, cancelled or aborted, with a
#         recorded outcome). The answer cannot change, so it is kept until the
#         run id changes. An id-addressed entry (run-<id>, ci-<id>) never
#         expires. The id-less entries (status, choice) are served only while
#         the no-mistakes database still names that run as the NEWEST run for
#         the branch and still terminal (fm_nmc_fin_valid), one read-only
#         query instead of the calls it replaces. When the database cannot be
#         read the entry is a miss, never a guess.
#   live  a well-formed answer about a run still in flight, a branch with no
#         run, a daemon that answered, or a plain listing. Kept for
#         FM_CREW_STATE_NM_CACHE_TTL seconds (default 30, 1..300), and dropped
#         the moment the task's state/<id>.status or state/<id>.progress is not
#         older than the entry (fm_nmc_invalidated).
#   fail  anything else: a failed or timed-out call, an empty or malformed
#         answer, an unknown verdict. Kept for FM_CREW_STATE_NM_CACHE_FAIL_TTL
#         seconds (default 3, 0..30; 0 caches none), under the same
#         invalidation. The recorded exit status is replayed with it, so a
#         failure is never served as a success.
# A miss runs the call exactly as before, with the same bound, and a disabled
# cache (FM_CREW_STATE_NM_CACHE=off) runs every call exactly as before.
#
# What a hit returns: the stdout of the most recent fresh read of that call.
# For a finished run that is the text a fresh read returns, with one named
# exception: `axi status` appends a branch_sync block that describes the
# invoking worktree's current git state, which a finished run's replay does not
# refresh. fm-crew-state.sh reads branch_sync only to bind a run that is still
# active (fm_nm_run_is_pipeline_owned_active), never for a finished one, so no
# classification can differ. For a live run a hit can lag a fresh read by up to
# the live TTL, which is the bounded staleness that buys the saving.
#
# Callers: fm_nmc_init once, then fm_nmc_read (prints) or fm_nmc_read_to
# (assigns, no subshell, so the database check is shared), and fm_nmc_lookup,
# fm_nmc_begin, fm_nmc_put, fm_nmc_end for the composite choice entry.
if ! declare -F fm_nm_run_checked >/dev/null 2>&1; then
  # shellcheck source=bin/fm-nm-run-lib.sh
  . "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/fm-nm-run-lib.sh"
fi

FM_NMC_ENABLED=0
FM_NMC_DIR=''
FM_NMC_WT=''
FM_NMC_BRANCH=''
FM_NMC_TIMEOUT=''
FM_NMC_TTL=30
FM_NMC_FAIL_TTL=3
FM_NMC_STATUS_FILE=''
FM_NMC_PROGRESS_FILE=''
FM_NMC_FIN_ID=''
FM_NMC_FIN_OK=1
FM_NMC_TMP=''
FM_NMC_START=''
FM_NMC_CLASS=fail
FM_NMC_FIN=-
FM_NMC_BODY=''
FM_NMC_RC=0

# An answer is well formed when it carries one of the sections `axi status`
# prints; a run of our own has a top-level `run:` section.
FM_NMC_WELLFORMED_RE=$'(^|\n)(run|other_branch_run|other_branch_active_run|current_branch):'
FM_NMC_OWN_RUN_RE=$'(^|\n)run:'
FM_NMC_FOREIGN_RE=$'(^|\n)other_branch_(active_)?run:'

if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
  fm_nmc_now_to() { printf -v "$1" '%(%s)T' -1; }
else
  fm_nmc_now_to() { printf -v "$1" '%s' "$(date +%s)"; }
fi

# <state-dir> <task-id> <worktree> <branch> <timeout-secs>
# Always records the worktree and bound so an uncached read still runs; enables
# the cache only for a writable state directory and a branch to key on.
fm_nmc_init() {
  local ttl fail_ttl
  FM_NMC_ENABLED=0
  FM_NMC_WT=$3
  FM_NMC_BRANCH=$4
  FM_NMC_TIMEOUT=$5
  case "${FM_CREW_STATE_NM_CACHE:-on}" in off|OFF|0|false|no) return 0 ;; esac
  [ -n "$3" ] && [ -n "$4" ] && [ -d "$1" ] && [ -w "$1" ] || return 0
  case "$2" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  ttl=${FM_CREW_STATE_NM_CACHE_TTL:-30}
  case "$ttl" in ''|*[!0-9]*) ttl=30 ;; esac
  [ "$ttl" -ge 1 ] && [ "$ttl" -le 300 ] || ttl=30
  fail_ttl=${FM_CREW_STATE_NM_CACHE_FAIL_TTL:-3}
  case "$fail_ttl" in ''|*[!0-9]*) fail_ttl=3 ;; esac
  [ "$fail_ttl" -le 30 ] || fail_ttl=3
  FM_NMC_TTL=$ttl
  FM_NMC_FAIL_TTL=$fail_ttl
  FM_NMC_DIR="$1/.nm-read-cache-$2"
  FM_NMC_STATUS_FILE="$1/$2.status"
  FM_NMC_PROGRESS_FILE="$1/$2.progress"
  FM_NMC_FIN_ID=''
  FM_NMC_ENABLED=1
}

fm_nmc_valid_id() {  # <run-id>
  case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
}

# 0 when the task's status log or progress marker is not strictly older than
# entry $1, so a worker event after the read began drops the entry. An equal
# timestamp counts as newer: a coarse clock may only make this cache miss.
fm_nmc_invalidated() {  # <entry-file>
  local f
  for f in "$FM_NMC_STATUS_FILE" "$FM_NMC_PROGRESS_FILE"; do
    [ -e "$f" ] || continue
    [ "$1" -nt "$f" ] || return 0
  done
  return 1
}

# 0 when entry $3, which began at epoch $1, is still inside its $2-second life.
fm_nmc_fresh() {  # <start-epoch> <ttl> <entry-file>
  local now
  fm_nmc_now_to now
  [ "$now" -ge "$1" ] && [ $((now - $1)) -lt "$2" ] || return 1
  fm_nmc_invalidated "$3" && return 1
  return 0
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
      "$1 completed"|"$1 failed"|"$1 cancelled"|"$1 aborted") FM_NMC_FIN_OK=0 ;;
    esac
  fi
  return "$FM_NMC_FIN_OK"
}

# Sets FM_NMC_BODY and FM_NMC_RC and returns 0 for a live entry under <key>.
fm_nmc_lookup() {  # <key>
  local key=$1 file magic start rc class fin wt branch body=''
  [ "$FM_NMC_ENABLED" = 1 ] || return 1
  file="$FM_NMC_DIR/$key"
  [ -f "$file" ] || return 1
  {
    IFS= read -r magic && IFS= read -r start && IFS= read -r rc && IFS= read -r class \
      && IFS= read -r fin && IFS= read -r wt && IFS= read -r branch || return 1
    IFS= read -r -d '' body || :
  } < "$file" 2>/dev/null || return 1
  [ "$magic" = fmnm1 ] && [ "$wt" = "$FM_NMC_WT" ] && [ "$branch" = "$FM_NMC_BRANCH" ] || return 1
  case "$start" in ''|*[!0-9]*) return 1 ;; esac
  case "$rc" in ''|*[!0-9]*) return 1 ;; esac
  case "$class" in
    fin)
      case "$key" in
        status|choice) fm_nmc_fin_valid "$fin" || return 1 ;;
        run-*|ci-*) [ "$key" = "${key%%-*}-$fin" ] || return 1 ;;
        *) return 1 ;;
      esac
      ;;
    live) fm_nmc_fresh "$start" "$FM_NMC_TTL" "$file" || return 1 ;;
    fail) fm_nmc_fresh "$start" "$FM_NMC_FAIL_TTL" "$file" || return 1 ;;
    *) return 1 ;;
  esac
  FM_NMC_BODY=$body
  FM_NMC_RC=$rc
}

# Starts a read: a marker whose mtime is the read's start. Returns 1 (read
# uncached) when the cache is off or its directory cannot be prepared.
fm_nmc_begin() {
  local f
  [ "$FM_NMC_ENABLED" = 1 ] || return 1
  [ -d "$FM_NMC_DIR" ] || mkdir -p "$FM_NMC_DIR" 2>/dev/null || return 1
  for f in "$FM_NMC_DIR"/.tmp.*; do
    [ -e "$f" ] || continue
    find "$FM_NMC_DIR" -maxdepth 1 -name '.tmp.*' -mmin +10 -exec rm -f {} + 2>/dev/null || :
    break
  done
  FM_NMC_TMP="$FM_NMC_DIR/.tmp.${BASHPID:-$$}"
  fm_nmc_now_to FM_NMC_START
  : > "$FM_NMC_TMP.mark" 2>/dev/null || { FM_NMC_TMP=''; return 1; }
}

fm_nmc_end() {
  [ -z "$FM_NMC_TMP" ] || rm -f "$FM_NMC_TMP.mark" "$FM_NMC_TMP.out" "$FM_NMC_TMP.entry"
  FM_NMC_TMP=''
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

# <key> <class> <finished-run-id|-> <exit-status> <stdout>
fm_nmc_put() {
  local entry="$FM_NMC_TMP.entry"
  [ -n "$FM_NMC_TMP" ] || return 0
  [ "$2" = fail ] && [ "$FM_NMC_FAIL_TTL" -eq 0 ] && return 0
  {
    printf 'fmnm1\n%s\n%s\n%s\n%s\n%s\n%s\n' "$FM_NMC_START" "$4" "$2" "$3" "$FM_NMC_WT" "$FM_NMC_BRANCH"
    printf '%s' "$5"
  } > "$entry" 2>/dev/null || { rm -f "$entry"; return 0; }
  touch -r "$FM_NMC_TMP.mark" "$entry" 2>/dev/null || { rm -f "$entry"; return 0; }
  mv -f "$entry" "$FM_NMC_DIR/$1" 2>/dev/null || { rm -f "$entry"; return 0; }
  fm_nmc_prune_ids "$1"
}

# Sets FM_NMC_CLASS and FM_NMC_FIN from one answer. <kind> is status (the bare
# `axi status`), status-run (an id-addressed read, <hint> its run id), logs
# (<hint> names the run when it is finished), daemon or runs. Only a
# well-formed answer ever earns the live class, and only a finished run of this
# branch with a recorded outcome earns the fin class.
fm_nmc_classify() {  # <kind> <exit-status> <stdout> [hint]
  local kind=$1 rc=$2 body=$3 hint=${4:-} id='' branch='' status='' outcome='' own=0
  FM_NMC_CLASS=fail
  FM_NMC_FIN=-
  case "$kind" in
    daemon) [ "$rc" = 0 ] && FM_NMC_CLASS=live; return 0 ;;
    runs) [ "$rc" = 0 ] && [ -n "$body" ] && FM_NMC_CLASS=live; return 0 ;;
    logs)
      [ "$rc" = 0 ] && [ -n "$body" ] || return 0
      FM_NMC_CLASS=live
      if fm_nmc_valid_id "$hint"; then FM_NMC_CLASS=fin; FM_NMC_FIN=$hint; fi
      return 0
      ;;
    status|status-run) ;;
    *) return 0 ;;
  esac
  [ "$rc" = 0 ] && [ -n "$body" ] || return 0
  [[ $body =~ $FM_NMC_WELLFORMED_RE ]] || return 0
  if [[ $body =~ $FM_NMC_OWN_RUN_RE ]] && ! [[ $body =~ $FM_NMC_FOREIGN_RE ]]; then own=1; fi
  [ "$kind" != status-run ] || [ "$own" = 1 ] || return 0
  FM_NMC_CLASS=live
  [ "$own" = 1 ] || return 0
  fm_nm_field_to id "$body" id || return 0
  fm_nm_strip_quotes_to id "$id"
  fm_nm_field_to branch "$body" branch || return 0
  fm_nm_strip_quotes_to branch "$branch"
  if [ "$branch" != "$FM_NMC_BRANCH" ] || { [ "$kind" = status-run ] && [ "$id" != "$hint" ]; }; then
    [ "$kind" != status-run ] || FM_NMC_CLASS=fail
    return 0
  fi
  fm_nm_field_to status "$body" status || return 0
  fm_nm_strip_quotes_to status "$status"
  fm_nm_field_to outcome "$body" outcome || return 0
  fm_nm_strip_quotes_to outcome "$outcome"
  case "$status" in completed|failed|cancelled|aborted) ;; *) return 0 ;; esac
  # An outcome that can still change (checks-passed becomes passed at the merge)
  # keeps the run live, so only a settled outcome earns the fin class.
  case "$outcome" in
    passed|passed-with-override|passed-with-skips|failed|cancelled|aborted) ;;
    *) return 0 ;;
  esac
  fm_nmc_valid_id "$id" || return 0
  FM_NMC_CLASS=fin
  FM_NMC_FIN=$id
}

# Class of the composite overview verdict <choice> as fm_nm_select_run prints
# it. <overview-ok> and <overview-present> are the 0/1 flags of that read.
fm_nmc_classify_choice() {  # <choice> <overview-ok> <overview-present>
  local id='' status=''
  FM_NMC_CLASS=fail
  FM_NMC_FIN=-
  [ "$2" = 1 ] && [ "$3" = 1 ] || return 0
  case "$1" in
    selected\|*)
      IFS='|' read -r _ id status _ <<< "$1"
      case "$status" in
        completed|failed|cancelled)
          fm_nmc_valid_id "$id" || return 0
          FM_NMC_CLASS=fin
          FM_NMC_FIN=$id
          ;;
        pending|running) FM_NMC_CLASS=live ;;
      esac
      ;;
    absent) FM_NMC_CLASS=live ;;
  esac
}

# The bounded call with the cache in front of it. Sets FM_NMC_BODY (stdout,
# byte for byte) and FM_NMC_RC (exit status).
fm_nmc_read_core() {  # <key> <kind> <hint> <no-mistakes args...>
  local key=$1 kind=$2 hint=$3 body='' rc out
  shift 3
  if fm_nmc_valid_id "$key" && fm_nmc_lookup "$key"; then
    return 0
  fi
  if fm_nmc_valid_id "$key" && fm_nmc_begin; then
    fm_nm_run_checked "$FM_NMC_WT" "$FM_NMC_TIMEOUT" "$@" > "$FM_NMC_TMP.out"
    rc=$?
    IFS= read -r -d '' body < "$FM_NMC_TMP.out" || :
    fm_nmc_classify "$kind" "$rc" "$body" "$hint"
    fm_nmc_put "$key" "$FM_NMC_CLASS" "$FM_NMC_FIN" "$rc" "$body"
    fm_nmc_end
  else
    out=$(fm_nm_run_checked "$FM_NMC_WT" "$FM_NMC_TIMEOUT" "$@"; printf '\037%s' "$?")
    rc=${out##*$'\037'}
    body=${out%$'\037'*}
  fi
  FM_NMC_BODY=$body
  FM_NMC_RC=$rc
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
