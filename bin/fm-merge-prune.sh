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
# Transient refusals retry on later sweeps with backoff (60s, doubling to 3600s)
# and stay silent: the task lease or project lock is held by another actor
# (FM_LEASE_REFUSE_EXIT, FM_PROJECT_LOCK_BUSY_EXIT), a teardown that outlasts its
# 600-second limit, an admission refusal (the worker is not finished yet), and a
# lifecycle action already running. One wake is raised if a task is still not
# pruned after 24 attempts.
#
# Any other teardown refusal (exit 1) may be a false positive: a closeout
# driver's "exact tree not covered", an orphan nested copy with no task record,
# ignored scratch files. Only then the fallback of bin/fm-merge-prune-lib.sh
# runs. It re-proves from the live copy, by the criteria of treehouse-reap-clean,
# that the copy and every nested copy is a pool copy, has no changed or
# untracked file, has no commit missing from every remote (or from the merged
# PR's head), holds only scratch or preserved ignored files, and has no process
# inside. The finished worker session is stopped first (bin/fm-control.sh exit)
# because it would otherwise always be the process inside. The preserve-list
# files are copied to data/<id>/merge-prune-preserved/ with SHA-256 checksums,
# then `treehouse destroy <copy> --include-leased --yes` removes the copy (the
# same call the reaper makes; --include-unlanded, --include-in-use and --force
# are never used), and teardown runs again to finish the task's records.
#
# Anything else stays, is never forced or discarded, and raises exactly ONE wake
# naming the copy and the reason. A retained copy is retried silently every six
# hours in case the cause cleared. The hourly `treehouse prune --all --yes`
# safety net is not duplicated.
#
# Outcomes are one line each in data/<id>/merge-prune.log. While the task's
# status file exists a `note:` line records the same outcome (reaped, or
# retained with the reason); a successful teardown retires the status file, so
# the log is the lasting record.
#
# FM_MERGE_PRUNE=0 turns arming off. Test seams: FM_MERGE_PRUNE_TEARDOWN_BIN and
# FM_MERGE_PRUNE_CONTROL_BIN replace bin/fm-teardown.sh and bin/fm-control.sh;
# FM_MERGE_PRUNE_EXIT_WAIT bounds the seconds to wait for the stopped worker.
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
NEXT_FILE="$STATE/.merge-prune-next"

# shellcheck source=bin/fm-idle-reap-lib.sh
. "$SCRIPT_DIR/fm-idle-reap-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
# shellcheck source=bin/fm-project-lock-lib.sh
. "$SCRIPT_DIR/fm-project-lock-lib.sh"
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
R_PR=; R_ATTEMPTS=0; R_NEXT=0; R_STATE=pending; R_REASON=; R_WAKE=0; R_COPY=; R_ARMED=0

rec_load() {  # <task-id>; 0 when a well-formed record was read
  local file="$STATE/$1.merge-prune" line version=
  R_PR=; R_ATTEMPTS=0; R_NEXT=0; R_STATE=pending; R_REASON=; R_WAKE=0; R_COPY=; R_ARMED=0
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
    esac
  done < "$file"
  [ "$version" = fm-merge-prune-v1 ] || return 1
  case "$R_ATTEMPTS$R_NEXT$R_WAKE$R_ARMED" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$R_PR" ]
}

rec_save() {  # <task-id>
  local file="$STATE/$1.merge-prune" tmp
  tmp=$(mktemp "$STATE/.merge-prune.XXXXXX") || return 1
  if printf 'version=fm-merge-prune-v1\npr=%s\nattempts=%s\nnext_at=%s\nstate=%s\nreason=%s\nwake_sent=%s\ncopy=%s\narmed_at=%s\n' \
    "$R_PR" "$R_ATTEMPTS" "$R_NEXT" "$R_STATE" "$(clean_detail "$R_REASON")" "$R_WAKE" "$(clean_detail "$R_COPY")" "$R_ARMED" > "$tmp" \
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

# A status note never raises a wake of its own: the one wake is the explicit
# check below. Skipped when teardown has already retired the status file.
status_note() {  # <text>
  local file="$STATE/$ID.status"
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  fm_wake_status_append_self_announced "$STATE" "$file" "note: $(clean_detail "$1")" >/dev/null 2>&1 || true
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

# A refusal about live work or a captain call is never a scratch false positive.
fallback_barred() {  # <teardown-output>
  case "$1" in
    *"no-mistakes run"*|*"held for the captain"*|*"leaked process"*) return 0 ;;
  esac
  return 1
}

TD_OUT=
TD_RC=0
run_teardown() {
  TD_RC=0
  TD_OUT=$(FM_HOME="$FM_HOME" FM_IDLE_REAP_ADMISSION=1 FM_IDLE_REAP_MERGE_PRUNE=1 \
    fm_run_timed "$(fm_mp_limit merge-prune.teardown 600)" "$TEARDOWN_BIN" "$ID" </dev/null 2>&1) || TD_RC=$?
}

finish_reaped() {  # <detail>
  rm -f -- "$STATE/$ID.merge-prune"
  log_line "reaped: $1"
  status_note "merge-prune reaped: $1"
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
  rec_save "$ID" || true
  log_line "retry in ${delay}s (attempt $R_ATTEMPTS): $1"
  if [ "$R_ATTEMPTS" -ge "$WAKE_AFTER_ATTEMPTS" ] && [ "$R_WAKE" = 0 ]; then
    R_WAKE=1
    rec_save "$ID" || true
    fm_wake_append check "merge-prune:$ID" "check: merge-prune $ID still not pruned after $R_ATTEMPTS attempts: $(clean_detail "$1")" || true
  fi
}

# A copy that stays: one wake and one status note per reason, a quiet retry later.
retain() {  # <copy> <reason>
  local copy=$1 reason=$2 changed=1
  [ "$R_STATE" = retained ] && [ "$R_REASON" = "$reason" ] && changed=0
  R_ATTEMPTS=$((R_ATTEMPTS + 1))
  R_STATE=retained
  R_REASON=$reason
  R_COPY=$copy
  R_NEXT=$((NOW + RETAINED_RETRY))
  if [ "$R_WAKE" = 0 ]; then
    R_WAKE=1
    rec_save "$ID" || true
    fm_wake_append check "merge-prune:$ID" "check: merge-prune kept $copy for $ID: $(clean_detail "$reason")" || true
  else
    rec_save "$ID" || true
  fi
  if [ "$changed" = 1 ]; then
    log_line "retained $copy: $reason"
    status_note "merge-prune retained $copy: $reason"
  fi
}

# Read the live copy's proofs; on success the copy is destroyed.
# Returns 0 destroyed or already absent, 1 retained or transient (already recorded).
fallback() {
  local wt real n label copies=() tags=() i dest waited=0 out rc=0 pr_number='' head
  wt=$(fm_meta_get "$META" worktree)
  if [ -z "$wt" ]; then
    retain "-" "teardown refused and the task record names no pool copy"
    return 1
  fi
  if [ ! -e "$wt" ]; then
    return 0
  fi
  if ! real=$(fm_mp_real "$wt") || ! fm_mp_in_pool "$real"; then
    retain "$wt" "not a pool copy under ${TREEHOUSE_ROOT:-\$HOME/.treehouse}/<pool>/<slot>/<repo>"
    return 1
  fi
  # The classifier must still call the finished worker reapable.
  FM_IDLE_REAP_MERGE_PRUNE=1 fm_idle_reap_classify "$FM_HOME" "$STATE" "$DATA" "$ID"
  if [ "$IDLE_REAP_CLASS" != reap ]; then
    backoff "automatic reap ineligible: $IDLE_REAP_CLASS: $IDLE_REAP_DETAIL"
    return 1
  fi
  if fm_pr_url_parse "$R_PR" && [ "$FM_PR_PROVIDER" = github ]; then
    pr_number=$FM_PR_NUMBER
  fi
  if ! prove_all "$real" "$pr_number"; then
    return 1
  fi
  stop_worker
  # The control lock keeps a teardown, relaunch or spawn from racing the removal.
  if ! fm_lock_try_acquire "$LOCK_CONTROL"; then
    backoff "another lifecycle action is already running for task $ID"
    return 1
  fi
  if ! prove_all "$real" "$pr_number"; then
    fm_lock_release "$LOCK_CONTROL" || true
    return 1
  fi
  # The stopped worker may need a moment to leave; any other process keeps the copy.
  until fm_mp_prove_unused "$real"; do
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
  copies=("$real")
  tags=(root)
  if [ "${#FM_MP_NESTED[@]}" -gt 0 ]; then
    for n in "${FM_MP_NESTED[@]}"; do
      label=${n#"$real"/}
      copies+=("$n")
      tags+=("nested-${label//\//__}")
    done
  fi
  for i in "${!copies[@]}"; do
    fm_mp_prove_ignored "${copies[$i]}" || { fm_lock_release "$LOCK_CONTROL" || true; record_verdict "$real"; return 1; }
    for n in ${FM_MP_PRESERVE[@]+"${FM_MP_PRESERVE[@]}"}; do
      if ! fm_mp_preserve_one "${copies[$i]}" "$n" "$dest/${tags[$i]}"; then
        fm_lock_release "$LOCK_CONTROL" || true
        retain "$real" "could not copy and checksum preserved record $n from ${copies[$i]}"
        return 1
      fi
    done
  done
  head=$(git -C "$real" rev-parse --short HEAD 2>/dev/null || true)
  out=$(fm_run_timed "$(fm_mp_limit merge-prune.destroy 300)" treehouse destroy "$real" --include-leased --yes </dev/null 2>&1) || rc=$?
  fm_lock_release "$LOCK_CONTROL" || true
  if [ "$rc" -ne 0 ]; then
    retain "$real" "treehouse destroy refused or failed: $(clean_detail "$(first_refusal_line "$out")")"
    return 1
  fi
  if [ -e "$real" ]; then
    retain "$real" "treehouse destroy returned success but the copy is still present"
    return 1
  fi
  log_line "fallback destroyed $real (head ${head:-unknown}); preserved records, if any, are in $dest"
  status_note "merge-prune reaped copy $real (clean, pushed, unused, head ${head:-unknown}); finishing teardown"
  return 0
}

# Prove one copy and everything nested in it; sets FM_MP_VERDICT/REASON on failure.
prove_all() {  # <real-copy> <pr-number>
  local real=$1 pr=$2 n
  fm_mp_prove_git "$real" "$pr" || { record_verdict "$real"; return 1; }
  fm_mp_prove_ignored "$real" || { record_verdict "$real"; return 1; }
  fm_mp_find_nested "$real"
  if [ "${#FM_MP_NESTED[@]}" -gt 0 ]; then
    for n in "${FM_MP_NESTED[@]}"; do
      fm_mp_prove_git "$n" "" || { record_verdict "$real"; return 1; }
      fm_mp_prove_ignored "$n" || { record_verdict "$real"; return 1; }
    done
  fi
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
stop_worker() {
  FM_HOME="$FM_HOME" fm_run_timed "$(fm_mp_limit merge-prune.control-exit 120)" "$CONTROL_BIN" "$ID" exit </dev/null >/dev/null 2>&1 || true
}

attempt() {
  local reason
  run_teardown
  if [ "$TD_RC" -eq 0 ]; then
    finish_reaped "teardown completed"
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
  if fallback_barred "$TD_OUT"; then
    retain "$(fm_meta_get "$META" worktree)" "$reason"
    return 0
  fi
  # Teardown refused for a reason that may be a false positive: prove the copy
  # is scratch ourselves, and only then let teardown finish the records.
  if ! fallback; then
    return 0
  fi
  run_teardown
  if [ "$TD_RC" -eq 0 ]; then
    finish_reaped "removed by fallback, teardown completed"
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
  rm -f -- "$NEXT_FILE"
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

next_due() {  # -> the soonest next_at over all records, capped at five minutes
  local rec id soonest=$((NOW + 300))
  for rec in "$STATE"/*.merge-prune; do
    [ -e "$rec" ] || continue
    id=${rec##*/}
    id=${id%.merge-prune}
    valid_id "$id" || continue
    rec_load "$id" || continue
    [ "$R_NEXT" -ge "$soonest" ] || soonest=$R_NEXT
  done
  printf '%s' "$soonest"
}

cmd_sweep() {
  local rec id started=0 tmp due
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
  fm_epoch_seconds_to NOW
  due=$(next_due)
  tmp=$(mktemp "$STATE/.merge-prune-next.XXXXXX" 2>/dev/null) || exit 0
  if printf '%s\n' "$due" > "$tmp" && mv -f -- "$tmp" "$NEXT_FILE"; then
    :
  else
    rm -f -- "$tmp"
  fi
  exit 0
}

case "${1:-}" in
  arm) { [ "$#" -eq 2 ] || { [ "$#" -eq 3 ] && [ "$3" = --run ]; }; } || die "usage: fm-merge-prune.sh arm <task-id> [--run]"; shift; cmd_arm "$@" ;;
  run) { [ "$#" -eq 2 ] || { [ "$#" -eq 3 ] && [ "$3" = --now ]; }; } || die "usage: fm-merge-prune.sh run <task-id> [--now]"; shift; cmd_run "$@" ;;
  sweep) [ "$#" -eq 1 ] || die "usage: fm-merge-prune.sh sweep"; cmd_sweep ;;
  -h|--help) usage ;;
  *) die "usage: fm-merge-prune.sh arm|run|sweep" ;;
esac
