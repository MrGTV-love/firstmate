#!/usr/bin/env bash
# fm-pr-close-items.sh - close the backlog items a merged pull request names.
#
# Usage: fm-pr-close-items.sh [--not-recorded] <task-id> <merged-pr-url>
#
# bin/fm-pr-merge.sh runs this once it has proved a merge and recorded its outcome, so
# work that lands inside a bigger pull request or a merge train no longer leaves its
# queued items open. Run it by hand to retry after a failure: a repeat is idempotent,
# because an item that is already done is only reported and no second proof is linked.
#
# What it reads. The merged pull request's body, through bin/fm-pr-closes-lib.sh, which
# owns the `Closes: <item-id>` line syntax and the merge-train member list. A body with a
# member list is a merge train: each member pull request is read the same way (its own
# `Closes:` lines), and every task whose state/<task>.meta records pr= equal to that
# member's full URL is considered too. Bodies are read from GitHub, GitLab and Forgejo,
# each member by its own URL. The proof is always the merged pull request this script was
# given (the train's own URL for a train), because a train's members close unmerged.
# Any other GitHub pull request a train body links outside a fenced code block is not
# read and closes nothing, so it is named on stderr for someone to check; a body with no
# member list gets no such line.
# The same read gives that pull request's merge state: when it is not merged (a hand run
# with a pull request that is still open, or a state it cannot read), nothing is closed
# and every named item in the active backlog that is not done yet is reported as not
# closed because the pull request is not merged.
#
# What it does for each named item. It never closes more than bin/fm-tasks-axi.sh done
# accepts, and it never changes what that command requires: the completion path decides,
# and its refusal text is the reported reason. Before the call the item is classified:
#   - unknown id, or an id not in the active backlog (archived ids included): reported,
#     never created;
#   - already done: reported, nothing run, so a rerun links no second proof;
#   - otherwise `fm-tasks-axi.sh done <id> --pr <url>` runs. That command owns the open
#     owner call check (a captain hold that is not released, an expired but unanswered one
#     included): FM_TASKS_AXI_REFUSE_OPEN_CALL, set only here, makes it refuse one inside
#     the lock it holds while it completes the item, so a hold placed before the close
#     takes effect wins. An open owner call, a live task record of a ship or scout item, a
#     scout item, a proof it cannot verify (a non-GitHub pull request) or any other refusal
#     is reported with its first line. A ship or scout item with a live record stays open:
#     the merged pull request's own task is left for its own teardown to close, and any
#     other stays open until someone acts on the report. A live item of any other kind
#     closes like any other named item.
# A completed item also clears itself from every other item's blocked-by list
# (bin/fm-backlog-transition-lib.sh), reported as `unblocked:`.
#
# --not-recorded is for a merge the forge confirmed but bin/fm-pr-merge.sh could not
# record: nothing is closed, and every item the body names is reported as not closed
# because the merge was not recorded.
#
# Output. One `close-at-merge:` line per closed item on stdout, one line per item left
# open (`close-at-merge: not closed <id>: <reason>`: on stdout only when the merged pull
# request's own ship or scout task still has its live record, which its teardown closes;
# on stderr behind `actionable:` for every other item), and a summary line. A closed
# item's cleared blocked-by edge is a `close-at-merge: unblocked:` line on stdout; an edge
# it could not clear is an `actionable: close-at-merge:` line on stderr. A linked pull request of a
# train that is not a member is an `actionable: close-at-merge: not read <url>:` line on
# stderr; it names no item, so it changes neither the summary counts nor the exit status.
# Exit 0 when every named item was closed or was already done; exit 3 when any item was
# left open or a train member's body could not be read; exit 1 when the merged pull
# request's own body cannot be read (the line names the pull request URL and the read
# error); exit 2 on a bad request. bin/fm-pr-merge.sh ignores the exit status:
# no close outcome ever changes the merge result.
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
# shellcheck source=bin/fm-pr-closes-lib.sh
. "$SCRIPT_DIR/fm-pr-closes-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

NOT_RECORDED=0
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --not-recorded) NOT_RECORDED=1; shift ;;
esac
if [ "$#" -ne 2 ] || ! fm_pr_task_id_valid "$1" || ! fm_pr_url_parse "$2"; then
  echo "usage: fm-pr-close-items.sh [--not-recorded] <task-id> <merged-pr-url>" >&2
  exit 2
fi
TASK_ID=$1
URL=$FM_PR_URL

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-close-items.XXXXXX") || {
  echo "actionable: close-at-merge could not make a scratch directory, so it closed nothing; retry: $0 $TASK_ID $URL" >&2
  exit 1
}
trap 'rm -rf -- "$WORK"' EXIT

CLOSED=0
LEFT=0
SEEN=$'\n'

left_open() {  # <id> <reason> [teardown]
  LEFT=$((LEFT + 1))
  if [ "${3:-}" = teardown ]; then
    printf 'close-at-merge: not closed %s: %s\n' "$1" "$2"
  else
    printf 'actionable: close-at-merge: not closed %s: %s\n' "$1" "$2" >&2
  fi
}

# read_body <pr-url> <out-file>: the body text of one pull request or merge request,
# through the forge's own tool. <out-file>.merged holds true only when the same record
# says it is merged. On failure the reason is left in <out-file>.err.
read_body() {
  local url=$1 out=$2 json login rc=0
  echo false > "$out.merged"
  fm_pr_url_parse "$url" || { echo "not a pull request URL" > "$out.err"; return 1; }
  case "$FM_PR_PROVIDER" in
    github)
      # The first line is the state; the rest is the body.
      json=$(gh pr view "$url" --json body,state --jq '(.state // "") + "\n" + (.body // "")' 2>"$out.err") || rc=$?
      if [ "$rc" -eq 0 ]; then
        printf '%s\n' "$json" | sed '1d' > "$out"
        [ "$(printf '%s\n' "$json" | sed -n '1p')" != MERGED ] || echo true > "$out.merged"
      fi
      ;;
    gitlab)
      command -v jq >/dev/null 2>&1 || { echo "jq is not installed" > "$out.err"; return 1; }
      json=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$FM_PR_NUMBER" -R "https://$FM_PR_HOST/$FM_PR_PATH" -F json 2>"$out.err") || rc=$?
      if [ "$rc" -eq 0 ]; then
        printf '%s' "$json" | jq -er 'if type == "object" then (.description // "") else error("not a merge request record") end' > "$out" 2>"$out.err" || rc=$?
        printf '%s' "$json" | jq -r 'if type == "object" and .state == "merged" then true else false end' > "$out.merged" 2>/dev/null || echo false > "$out.merged"
      fi
      ;;
    forgejo)
      command -v jq >/dev/null 2>&1 || { echo "jq is not installed" > "$out.err"; return 1; }
      login=$(fm_pr_forgejo_login "$FM_PR_HOST") || { echo "no single tea login for $FM_PR_HOST" > "$out.err"; return 1; }
      # "tea api" exits 0 on an HTTP error and prints the error body, so only a record
      # that has a body field counts as a read.
      json=$(tea api --login "$login" --repo "$FM_PR_OWNER/$FM_PR_REPO" "/repos/{owner}/{repo}/pulls/$FM_PR_NUMBER" 2>"$out.err") || rc=$?
      if [ "$rc" -eq 0 ]; then
        printf '%s' "$json" | jq -er 'if type == "object" and has("merged") then (.body // "") else error("the forge answered: " + ((.message // "no pull request record") | tostring)) end' > "$out" 2>"$out.err" || rc=$?
        printf '%s' "$json" | jq -r 'if type == "object" and .merged == true then true else false end' > "$out.merged" 2>/dev/null || echo false > "$out.merged"
      fi
      ;;
    *)
      echo "reading a ${FM_PR_PROVIDER:-unknown} pull request body is not supported" > "$out.err"
      return 1
      ;;
  esac
  [ "$rc" -eq 0 ] || { [ -s "$out.err" ] || echo "the read failed with status $rc" > "$out.err"; return 1; }
  return 0
}

consider() {  # <id> <proof-url> <where it was named>
  local id=$1 proof=$2 source=$3 state out rc first
  case "$SEEN" in *$'\n'"$id"$'\n'*) return 0 ;; esac
  SEEN="$SEEN$id"$'\n'
  if [ "$NOT_RECORDED" = 1 ]; then
    left_open "$id" "the merge of $URL was not recorded, so nothing was closed (named by $source); retry: $0 $TASK_ID $URL"
    return 0
  fi
  if ! fm_backlog_row_probe "$DATA" "$id"; then
    if [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
      left_open "$id" "unknown id named by $source; no item with that id is in the active backlog (an archived item is not read), and none was created"
    else
      left_open "$id" "the item could not be read (${FM_BACKLOG_ROW_ERROR:-unknown error}); it stays open; retry: $0 $TASK_ID $URL"
    fi
    return 0
  fi
  state=${FM_BACKLOG_ROW_STATE%% *}
  if [ "$state" = "done" ]; then
    printf 'close-at-merge: %s is already done\n' "$id"
    return 0
  fi
  if [ "$MERGED" != true ]; then
    left_open "$id" "$URL is not merged, so nothing was closed (named by $source); retry once it has merged: $0 $TASK_ID $URL"
    return 0
  fi
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_TASKS_AXI_REFUSE_OPEN_CALL=1 \
    "$SCRIPT_DIR/fm-tasks-axi.sh" "done" "$id" --pr "$proof" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    CLOSED=$((CLOSED + 1))
    printf 'close-at-merge: closed %s with %s (named by %s)\n' "$id" "$proof" "$source"
    printf '%s\n' "$out" | sed -n 's/^unblocked: /close-at-merge: unblocked: /p'
    printf '%s\n' "$out" | sed -n 's/^actionable: /actionable: close-at-merge: /p' >&2
    return 0
  fi
  first=$(printf '%s\n' "$out" | sed -n '1p')
  first=${first#fm-tasks-axi: }
  case "$first" in
    *"open owner call"*) left_open "$id" "it is an open owner call: $first" ;;
    *"has a live task record"*)
      if [ "$id" = "$TASK_ID" ]; then
        left_open "$id" "bin/fm-tasks-axi.sh done did not close it: $first" teardown
      else
        left_open "$id" "bin/fm-tasks-axi.sh done did not close it: $first"
      fi
      ;;
    *) left_open "$id" "bin/fm-tasks-axi.sh done did not close it: ${first:-failed with no output}" ;;
  esac
}

tasks_recording_pr() {  # <pr-url>; prints task ids whose record holds exactly that URL
  local meta task
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    task=${meta##*/}
    task=${task%.meta}
    fm_pr_task_id_valid "$task" || continue
    [ "$(fm_meta_get "$meta" pr)" = "$1" ] || continue
    printf '%s\n' "$task"
  done
}

if ! read_body "$URL" "$WORK/body"; then
  printf 'actionable: close-at-merge could not read the body of %s (%s), so it closed nothing and the merge result is unchanged; retry: %s %s %s\n' \
    "$URL" "$(sed -n '1p' "$WORK/body.err")" "$0" "$TASK_ID" "$URL" >&2
  exit 1
fi
MERGED=$(cat "$WORK/body.merged" 2>/dev/null) || MERGED=false

while IFS= read -r id; do
  [ -z "$id" ] || consider "$id" "$URL" "the body of $URL"
done < <(fm_pr_closes_ids "$WORK/body")

n=0
MEMBER_SEEN=$'\n'
while IFS= read -r candidate; do
  [ -n "$candidate" ] || continue
  fm_pr_url_parse "$candidate" || continue
  member=$FM_PR_URL
  [ "$member" != "$URL" ] || continue
  case "$MEMBER_SEEN" in *$'\n'"$member"$'\n'*) continue ;; esac
  MEMBER_SEEN="$MEMBER_SEEN$member"$'\n'
  n=$((n + 1))
  if read_body "$member" "$WORK/member-$n"; then
    while IFS= read -r id; do
      [ -z "$id" ] || consider "$id" "$URL" "the body of train member $member"
    done < <(fm_pr_closes_ids "$WORK/member-$n")
  else
    LEFT=$((LEFT + 1))
    printf 'actionable: close-at-merge: could not read the body of train member %s (%s); retry: %s %s %s\n' \
      "$member" "$(sed -n '1p' "$WORK/member-$n.err")" "$0" "$TASK_ID" "$URL" >&2
  fi
  while IFS= read -r task; do
    [ -n "$task" ] || continue
    consider "$task" "$URL" "the task record that holds train member $member"
  done < <(tasks_recording_pr "$member")
done < <(fm_pr_closes_train_members "$WORK/body")

if [ "$n" -gt 0 ]; then
  while IFS= read -r linked; do
    fm_pr_url_parse "$linked" || continue
    [ "$FM_PR_URL" != "$URL" ] || continue
    case "$MEMBER_SEEN" in *$'\n'"$FM_PR_URL"$'\n'*) continue ;; esac
    printf 'actionable: close-at-merge: not read %s: linked from a merge-train body but not in its Component member list, so its items were not closed; list it in the Component table if it landed\n' "$FM_PR_URL" >&2
  done < <(fm_pr_closes_linked_prs "$WORK/body")
fi

if [ "$CLOSED" -gt 0 ] || [ "$LEFT" -gt 0 ]; then
  printf 'close-at-merge: %s closed, %s left open\n' "$CLOSED" "$LEFT"
fi
[ "$LEFT" -eq 0 ] || exit 3
exit 0
