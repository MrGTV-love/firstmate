#!/usr/bin/env bash
# Register this home's unrecorded ready ship PRs through fm-pr-check.sh.
# Usage: fm-pr-ready-reconcile.sh
# Each pass examines at most eight task records, rotating a durable cursor so
# inactive or refused records cannot starve later ships. Only kind=ship with
# mode=no-mistakes or direct-PR and no pr= is eligible; no other home is walked.
# Read at most the final 64 KiB / 200 lines of each eligible status log. Status
# verbs and readiness use fm-status-event-lib.sh and fm-dod-lib.sh, not a second
# status grammar. The newest ready declaration in that window wins, even when
# subsequent resolution notes follow it. A missing ready declaration is a no-op.
# Refusals are printed once and retained per task, URL, mode and named head,
# using fm-pr-check.sh's authority: the forge's valid GitHub no-mistakes head,
# otherwise the copy's HEAD. Forge-head probes continue after a refusal so a
# pipeline-only publication can retry without moving the copy or changing the
# ready prose. Use fm-pr-check.sh by hand after repairing the same refused head.
# The watcher runs this single-flight pass detached from its housekeeping tick;
# forge delays must not stop supervision. This script never merges, steers, or
# writes a status log, and fm-pr-check.sh remains the only pr= writer.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"

[ "$#" -eq 0 ] || { echo 'usage: fm-pr-ready-reconcile.sh' >&2; exit 2; }
[ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 0
CACHE="$STATE/.pr-ready-reconcile"
[ ! -L "$CACHE" ] || { echo 'pr-ready: unsafe reconciliation directory' >&2; exit 1; }
umask 077
mkdir -p "$CACHE"
LOCK="$CACHE/lock"
fm_lock_try_acquire "$LOCK" || exit 0
SCRATCH=
cleanup() {
  [ -z "$SCRATCH" ] || rm -f -- "$SCRATCH"
  fm_lock_release "$LOCK" || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
SCRATCH=$(mktemp "$CACHE/pass.XXXXXX")
CURSOR=
[ ! -f "$CACHE/cursor" ] || IFS= read -r CURSOR < "$CACHE/cursor" || true

# Metadata is read once, without sourcing worker-controlled bytes.
reconcile_one() {  # <meta> <id>
  local meta=$1 id=$2 line kind='' mode='' pr='' wt='' note url='' token
  local ready='' head fingerprint refusal output
  if [ ! -f "$meta" ] || [ -L "$meta" ] || [ ! -r "$meta" ]; then
    printf 'pr-ready: %s: unreadable task record; skipped\n' "$id"
    return 0
  fi
  if ! output=$(cat -- "$meta" 2>/dev/null); then
    printf 'pr-ready: %s: unreadable task record; skipped\n' "$id"
    return 0
  fi
  while IFS= read -r line; do
    case "$line" in
      kind=*) kind=${line#kind=} ;;
      mode=*) mode=${line#mode=} ;;
      pr=*) pr=${line#pr=} ;;
      worktree=*) wt=${line#worktree=} ;;
    esac
  done <<< "$output"
  [ "$kind" = ship ] && [ -z "$pr" ] || return 0
  case "$mode" in no-mistakes|direct-PR) ;; *) return 0 ;; esac
  [ -e "$STATE/$id.status" ] || [ -L "$STATE/$id.status" ] || return 0
  if [ ! -f "$STATE/$id.status" ] || [ -L "$STATE/$id.status" ] || [ ! -r "$STATE/$id.status" ] \
    || ! tail -c 65536 "$STATE/$id.status" > "$SCRATCH" 2>/dev/null; then
    printf 'pr-ready: %s: unreadable status log; skipped\n' "$id"
    return 0
  fi
  # Tail the snapshot, never ask last_status_line to widen into the real log.
  output=$(tail -n "$FM_CLASSIFY_EVENT_WINDOW_LINES" "$SCRATCH")
  while IFS= read -r line; do
    _fm_status_line_is_event "$line" "^[[:space:]]*(${FM_CLASSIFY_CAPTAIN_RE_DEFAULT})" || continue
    fm_dod_should_gate_ship_done ship "$mode" "$line" || continue
    ready=$line
  done <<< "$output"
  [ -n "$ready" ] || return 0
  status_line_note "$ready" note
  # URL validation stays with the existing forge parser. Ignore punctuation
  # attached by human prose, not arbitrary shell content in a status record.
  line=$note
  while [[ "$line" =~ https?://[^[:space:]]+ ]]; do
    token=${BASH_REMATCH[0]}
    line=${line#*"$token"}
    while [[ "$token" = *[.,\;\)\]] ]]; do token=${token%?}; done
    if fm_pr_url_parse "$token"; then url=$FM_PR_URL; break; fi
  done
  [ -n "$url" ] || return 0
  # Match fm-pr-check.sh's mode-specific authority. GitHub no-mistakes
  # publication can advance only on the forge; polling that head is necessary
  # even after a refusal, while the registrar itself stays deduplicated.
  head=''
  if fm_dod_forge_head_is_named_head "$mode" && [ "$FM_PR_PROVIDER" = github ]; then
    head=$(cd "$wt" 2>/dev/null && gh pr view "$url" --json headRefOid -q .headRefOid 2>/dev/null || true)
  fi
  if ! fm_pr_head_valid "$head"; then
    head=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null || true)
  fi
  printf '%s\n' "$wt" "$url" "$mode" "$head" > "$SCRATCH"
  fingerprint=$(fm_pr_sha256 "$SCRATCH")
  refusal="$CACHE/$id.$fingerprint.refused"
  [ ! -e "$refusal" ] && [ ! -L "$refusal" ] || return 0
  if output=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-pr-check.sh" "$id" "$url" 2>&1); then
    printf 'pr-ready: %s: registered %s\n' "$id" "$url"
  else
    # Publish the refusal before returning, so periodic execution does not
    # hammer the forge or repeatedly surface an unchanged rejected head.
    printf '%s\n' "$output" > "$SCRATCH"
    mv -f -- "$SCRATCH" "$refusal"
    SCRATCH=$(mktemp "$CACHE/pass.XXXXXX")
    printf 'pr-ready: %s: registration refused: %s\n' "$id" "${output//$'\n'/; }"
  fi
}

# Globbing lists names only; at most eight records/log tails are opened. Start
# after the last visited name, wrapping on the next pass if it was the last one.
shopt -s nullglob
metas=("$STATE"/*.meta)
start=0
for ((i=0; i<${#metas[@]}; i++)); do
  if [[ "${metas[$i]##*/}" > "$CURSOR" ]]; then start=$i; break; fi
done
count=0
for ((i=start; i<${#metas[@]} && count<8; i++)); do
  meta=${metas[$i]}
  id=${meta##*/}; id=${id%.meta}
  fm_pr_task_id_valid "$id" || continue
  reconcile_one "$meta" "$id"
  printf '%s\n' "${meta##*/}" > "$SCRATCH"
  mv -f -- "$SCRATCH" "$CACHE/cursor"
  SCRATCH=$(mktemp "$CACHE/pass.XXXXXX")
  count=$((count + 1))
done
