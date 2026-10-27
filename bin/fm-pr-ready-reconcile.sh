#!/usr/bin/env bash
# Register this home's unrecorded ready ship PRs through fm-pr-check.sh.
# Usage: fm-pr-ready-reconcile.sh
# Every pass admits at most eight task records, rotating after the last admitted
# record. Only kind=ship with mode=no-mistakes or direct-PR and no pr= is eligible.
# Read at most the final 64 KiB / 200 lines of each eligible status log. The
# window comes from fm-status-event-lib.sh and the ready gate from fm-dod-lib.sh,
# not a second status grammar, and the PR is the one the ready note declares as
# `PR <url>`.
# The newest ready declaration in that window wins, even when subsequent
# resolution notes follow it. A missing ready declaration is a no-op.
# A refusal is printed and retained per task for ten minutes, during which the
# task is skipped before any forge call; after that it is retried, so a repaired
# draft, restored tool, transient forge failure or finished pipeline registers
# without manual action. fm-pr-check.sh keeps its own authority for the named
# head. fm-teardown.sh removes the task's marker.
# The watcher runs this single-flight pass detached under a hard time limit.
# Persist the cursor before each admission, so even a permanently hung forge
# call cannot keep later records behind it on the next pass. This script never
# merges, steers, or writes a status log; fm-pr-check.sh is the only pr= writer.
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
# Ten minutes is a Firstmate policy choice, not a measurement.
# measured: value=600 date=2026-10-20 host=Mac-Studio.local margin=170.9 (basis: 600 s / 3.51 s, the measured cost of one registration attempt in the cited run; real-time live run at a 1-second tick: refusal at +1s, zero forge reads through +600s, retry registered at +603s, 3 forge reads in total)
REFUSAL_RETRY_SECS=600

# Metadata is read once, without sourcing worker-controlled bytes.
reconcile_one() {  # <meta> <id>
  local meta=$1 id=$2 line kind='' mode='' pr='' note url=''
  local ready='' refusal="$CACHE/$2.refused" refused_at output age
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
    esac
  done <<< "$output"
  [ "$kind" = ship ] && [ -z "$pr" ] || return 0
  case "$mode" in no-mistakes|direct-PR) ;; *) return 0 ;; esac
  if [ -e "$refusal" ] || [ -L "$refusal" ]; then
    refused_at=$(_fm_status_file_mtime "$refusal") || refused_at=0
    age=$(($(date +%s) - ${refused_at:-0}))
    [ "$age" -lt 0 ] || [ "$age" -ge "$REFUSAL_RETRY_SECS" ] || return 0
  fi
  [ -e "$STATE/$id.status" ] || [ -L "$STATE/$id.status" ] || return 0
  if [ ! -f "$STATE/$id.status" ] || [ -L "$STATE/$id.status" ] || [ ! -r "$STATE/$id.status" ] \
    || ! tail -c 65536 "$STATE/$id.status" > "$SCRATCH" 2>/dev/null; then
    printf 'pr-ready: %s: unreadable status log; skipped\n' "$id"
    return 0
  fi
  # Tail the snapshot, never ask last_status_line to widen into the real log.
  # Pipe it: uutils 0.10.0 (Ubuntu 26.04) tail -n prints nothing for a seekable
  # file of exactly 64 KiB, which is every snapshot of a large log.
  output=$(cat -- "$SCRATCH" | tail -n "$FM_CLASSIFY_EVENT_WINDOW_LINES")
  while IFS= read -r line; do
    fm_dod_should_gate_ship_done ship "$mode" "$line" || continue
    ready=$line
  done <<< "$output"
  [ -n "$ready" ] || return 0
  status_line_note "$ready" note
  url=$(fm_dod_pr_url_from_done_note "$note") && fm_pr_url_parse "$url" || return 0
  url=$FM_PR_URL
  rm -f -- "$refusal"
  if output=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-pr-check.sh" "$id" "$url" 2>&1); then
    printf 'pr-ready: %s: registered %s\n' "$id" "$url"
  else
    printf '%s\n' "$output" > "$SCRATCH"
    mv -f -- "$SCRATCH" "$refusal"
    SCRATCH=$(mktemp "$CACHE/pass.XXXXXX")
    printf 'pr-ready: %s: registration refused: %s\n' "$id" "${output//$'\n'/; }"
  fi
}

# The record cap bounds local reads and forge attempts; the watcher deadline
# bounds their duration. Advance before calling the registrar, not after it:
# a timeout must preserve progress even when no refusal can be recorded.
CURSOR="$CACHE/cursor"
cursor=
if [ -f "$CURSOR" ] && [ ! -L "$CURSOR" ]; then
  IFS= read -r cursor < "$CURSOR" || cursor=
  fm_pr_task_id_valid "$cursor" || cursor=
fi
count=0
shopt -s nullglob
for half in after before; do
  for meta in "$STATE"/*.meta; do
    id=${meta##*/}; id=${id%.meta}
    fm_pr_task_id_valid "$id" || continue
    if [ "$half" = after ]; then
      [[ "$id" > "$cursor" ]] || continue
    else
      [[ "$id" > "$cursor" ]] && continue
    fi
    [ "$count" -lt 8 ] || break 2
    printf '%s\n' "$id" > "$SCRATCH"
    mv -f -- "$SCRATCH" "$CURSOR"
    SCRATCH=$(mktemp "$CACHE/pass.XXXXXX")
    count=$((count + 1))
    reconcile_one "$meta" "$id"
  done
done
