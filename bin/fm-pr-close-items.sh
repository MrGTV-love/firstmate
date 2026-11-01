#!/usr/bin/env bash
# fm-pr-close-items.sh - close the backlog items a merged pull request names.
#
# Usage: fm-pr-close-items.sh <task-id> <merged-pr-url>
#
# bin/fm-pr-merge.sh runs this once it has proved and recorded a merge, so work that
# lands inside a bigger pull request, a merge train, or another home's merge no longer
# leaves its queued items open. Run it by hand to retry after a failure: a repeat is
# idempotent, because an item that is already done is only reported.
#
# What it reads. The merged pull request's body, through bin/fm-pr-closes-lib.sh, which
# owns the `Closes: <item-id>` line syntax and the train member table. When the body
# lists train members, each member pull request is read the same way: its own
# `Closes:` lines, and every task whose state/<task>.meta records pr= equal to that
# member's URL. A member must be a pull request of the same repository as the merged one.
# Only GitHub pull requests are read; a pull request of another forge
# prints one note and closes nothing, because bin/fm-tasks-axi.sh done proves a merge
# only for GitHub.
#
# What it does for each named item. It never closes more than bin/fm-tasks-axi.sh done
# allows, and it never changes what that command requires: the proof is the merged pull
# request's URL (the train's own for an item the train body names, the member's for an
# item a member names). The item is classified first:
#   - unknown id: reported, never created;
#   - already done: reported, nothing run;
#   - an open captain call: not closed, reported (the owner's call is not this merge's);
#   - not a ship item: not closed, reported (only a ship item closes on a merged pull
#     request);
#   - a live task record (state/<id>.meta): not closed here, reported, because
#     bin/fm-tasks-axi.sh done refuses it and bin/fm-teardown.sh owns that proof. The
#     task being merged is one such case: its own teardown closes it;
#   - otherwise `fm-tasks-axi.sh done <id> --pr <url>` runs, and a refusal is reported
#     with its first line. A completed item also clears itself from every other item's
#     blocked-by list (bin/fm-backlog-transition-lib.sh), reported as `unblocked:`.
# A member task found by its meta pr= is a live record too. Its merged pull request is
# proved with the forge, the merge outcome is recorded for it as the merge poll would,
# and its prune is armed with bin/fm-merge-prune.sh, the same hand-off bin/fm-pr-merge.sh
# makes for its own task; teardown, the landing authority, then closes its item.
#
# Output. One `close-at-merge:` line per closed or handed-off item on stdout, one
# `actionable: close-at-merge did not close <id>: <reason>` line per item left open on
# stderr, and a summary line. Exit 0 when every named item was closed, was already done,
# or was handed to teardown; exit 3 when any item was left open (the merge itself is
# never affected: bin/fm-pr-merge.sh ignores this exit status); exit 2 on a bad request.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-merge-outcome-lib.sh
. "$SCRIPT_DIR/fm-merge-outcome-lib.sh"
# shellcheck source=bin/fm-pr-closes-lib.sh
. "$SCRIPT_DIR/fm-pr-closes-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
if [ "$#" -ne 2 ] || ! fm_pr_task_id_valid "$1" || ! fm_pr_url_parse "$2"; then
  echo "usage: fm-pr-close-items.sh <task-id> <merged-pr-url>" >&2
  exit 2
fi
TASK_ID=$1
URL=$FM_PR_URL
REPO_PATH=$FM_PR_PATH
if [ "$FM_PR_PROVIDER" != github ]; then
  printf 'close-at-merge: %s is not a GitHub pull request; no item is closed from its body (bin/fm-tasks-axi.sh done proves a merge only for GitHub)\n' "$URL"
  exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-close-items.XXXXXX") || {
  echo "actionable: close-at-merge could not make a scratch directory, so it closed nothing; retry: $0 $TASK_ID $URL" >&2
  exit 1
}
trap 'rm -rf -- "$WORK"' EXIT

CLOSED=0
HANDED=0
LEFT=0
SEEN=$'\n'
HAND_SEEN=$'\n'

left_open() {  # <id> <reason>
  LEFT=$((LEFT + 1))
  printf 'actionable: close-at-merge did not close %s: %s\n' "$1" "$2" >&2
}

# The merged state exactly as bin/fm-tasks-axi.sh's completion guard proves it.
pr_is_merged() {  # <pr-url>; sets nothing
  local url=$1
  [[ "$url" =~ ^https://github[.]com/([^/]+/[^/]+)/pull/([0-9]+)$ ]] || return 1
  gh-axi api "/repos/${BASH_REMATCH[1]}/pulls/${BASH_REMATCH[2]}" --jq '"merged=" + ((.merged_at != null)|tostring)' --full 2>/dev/null \
    | grep -Eq '^  body: "?merged=true"?$'
}

fetch_body() {  # <pr-url> <out-file>
  gh pr view "$1" --json body --jq '.body // ""' > "$2" 2>"$2.err"
}

close_item() {  # <id> <proof-url> <where it was named>
  local id=$1 proof=$2 source=$3 state kind out rc line first
  case "$SEEN" in *$'\n'"$id $proof"$'\n'*) return 0 ;; esac
  SEEN="$SEEN$id $proof"$'\n'
  if [ "$id" = "$TASK_ID" ]; then
    printf 'close-at-merge: %s is the task just merged; its own teardown closes it (%s)\n' "$id" "$source"
    return 0
  fi
  if ! fm_backlog_row_probe "$DATA" "$id"; then
    if [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
      left_open "$id" "unknown id named by $source; no item with that id exists in this backlog, and none was created"
    else
      left_open "$id" "the backlog could not be read (${FM_BACKLOG_ROW_ERROR:-unknown error}); retry: $0 $TASK_ID $URL"
    fi
    return 0
  fi
  state=${FM_BACKLOG_ROW_STATE%% *}
  kind=$FM_BACKLOG_ROW_KIND
  if [ "$state" = "done" ]; then
    printf 'close-at-merge: %s is already done\n' "$id"
    return 0
  fi
  if [ "$FM_BACKLOG_ROW_HOLD_KIND" = captain ]; then
    left_open "$id" "it is an open owner call; answer it with bin/fm-captain-hold.sh before it can close"
    return 0
  fi
  if [ "$kind" != ship ]; then
    left_open "$id" "it is a ${kind:-unknown-kind} item, and only a ship item closes on a merged pull request"
    return 0
  fi
  if [ -e "$STATE/$id.meta" ]; then
    if [ "$proof" != "$URL" ] && [ "$(fm_meta_get "$STATE/$id.meta" pr)" = "$proof" ]; then
      hand_to_teardown "$id" "$proof"
    else
      left_open "$id" "it has a live task record; bin/fm-teardown.sh $id closes it with the landing proof"
    fi
    return 0
  fi
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-tasks-axi.sh" "done" "$id" --pr "$proof" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    CLOSED=$((CLOSED + 1))
    printf 'close-at-merge: closed %s with %s (named by %s)\n' "$id" "$proof" "$source"
    while IFS= read -r line; do
      case "$line" in unblocked:*|actionable:*) printf 'close-at-merge: %s\n' "$line" ;; esac
    done <<< "$out"
    return 0
  fi
  first=$(printf '%s\n' "$out" | sed -n '1p')
  first=${first#fm-tasks-axi: }
  left_open "$id" "bin/fm-tasks-axi.sh done refused it: ${first:-failed with no output}"
}

# A task whose live record holds the member pull request: prove the merge with the
# forge, record it as the merge poll would, and hand the prune to teardown.
hand_to_teardown() {  # <task-id> <member-url>
  local task=$1 member=$2 prune_state=0
  case "$HAND_SEEN" in *$'\n'"$task $member"$'\n'*) return 0 ;; esac
  HAND_SEEN="$HAND_SEEN$task $member"$'\n'
  if ! pr_is_merged "$member"; then
    left_open "$task" "its pull request $member is not proved merged"
    return 0
  fi
  if ! fm_merge_outcome_report "$FM_HOME" "$STATE" "$task" "$member" poll ""; then
    left_open "$task" "the merge of $member could not be recorded for supervision; retry: $0 $TASK_ID $URL"
    return 0
  fi
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-merge-prune.sh" arm "$task" --run </dev/null >/dev/null 2>&1 || prune_state=$?
  if [ "$prune_state" -ne 0 ]; then
    left_open "$task" "its prune could not be armed for $member; retry: $0 $TASK_ID $URL"
    return 0
  fi
  HANDED=$((HANDED + 1))
  printf 'close-at-merge: handed %s to teardown: its task record is live, so teardown closes its item (%s is merged)\n' "$task" "$member"
}

tasks_recording_pr() {  # <pr-url>; prints task ids
  local meta task
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    task=${meta##*/}
    task=${task%.meta}
    fm_pr_task_id_valid "$task" || continue
    [ "$(fm_meta_get "$meta" pr)" = "$1" ] || continue
    case "$(fm_meta_get "$meta" kind)" in ''|ship) ;; *) continue ;; esac
    printf '%s\n' "$task"
  done
}

if ! fetch_body "$URL" "$WORK/body"; then
  printf 'actionable: close-at-merge could not read the body of %s (%s), so it closed nothing; retry: %s %s %s\n' \
    "$URL" "$(sed -n '1p' "$WORK/body.err")" "$0" "$TASK_ID" "$URL" >&2
  exit 1
fi

while IFS= read -r id; do
  [ -z "$id" ] || close_item "$id" "$URL" "the body of $URL"
done < <(fm_pr_closes_ids "$WORK/body")

n=0
while IFS= read -r member; do
  [ -n "$member" ] || continue
  [ "$member" != "$URL" ] || continue
  case "$member" in "https://github.com/$REPO_PATH/pull/"*) ;; *) continue ;; esac
  n=$((n + 1))
  if fetch_body "$member" "$WORK/member-$n"; then
    while IFS= read -r id; do
      [ -z "$id" ] || close_item "$id" "$member" "the body of train member $member"
    done < <(fm_pr_closes_ids "$WORK/member-$n")
  else
    left_open "(train member $member)" "its body could not be read ($(sed -n '1p' "$WORK/member-$n.err")); retry: $0 $TASK_ID $URL"
  fi
  while IFS= read -r task; do
    [ -n "$task" ] || continue
    [ "$task" != "$TASK_ID" ] || continue
    hand_to_teardown "$task" "$member"
  done < <(tasks_recording_pr "$member")
done < <(fm_pr_closes_train_members "$WORK/body")

if [ "$CLOSED" -gt 0 ] || [ "$HANDED" -gt 0 ] || [ "$LEFT" -gt 0 ]; then
  printf 'close-at-merge: %s closed, %s handed to teardown, %s left open\n' "$CLOSED" "$HANDED" "$LEFT"
fi
[ "$LEFT" -eq 0 ] || exit 3
exit 0
