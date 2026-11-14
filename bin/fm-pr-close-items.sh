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
# owns the closes block: the one block between the exact lines
# `<!-- firstmate-backlog-closes:begin -->` and `<!-- firstmate-backlog-closes:end -->`, whose
# lines are `Closes-backlog-item: <item-id>`, `Train-member: <pull request URL>` or blank.
# Nothing outside that block closes an item, and no Markdown or HTML is read anywhere. A body
# whose block is refused (a second block, a missing end line, marker text inside other text,
# or any other line inside the block, as the library header lists) closes nothing. Each
# `Train-member:` pull request is read the same way (only its own block's
# `Closes-backlog-item:` lines), and every task whose state/<task>.meta records pr= equal to
# that member's full URL is considered too. Bodies are read from GitHub, GitLab and Forgejo, each member by its own
# URL. The proof is always the merged pull request this script was given (the train's own
# URL for a train), because a train's members close unmerged. A body with no directive
# line closes nothing, a train body written before this block existed included; its items
# are closed by hand as before.
# These things are reported, never closed, on stderr behind `actionable:`. The first three
# kinds count as left open, so they add to the summary's left open count and make the exit
# status 3; a `mentioned ...` line changes neither:
#   - a refused body (the merged one or a train member's): `refused to close anything named
#     by the body of <url>: <reason>`, once per body; its directive lines are then reported
#     as outside the block, below;
#   - an old `Closes: <item-id>` line is `not closed <id>`, naming the new form. It is reported
#     only after every body and task record has been read, and only when no directive line or
#     task record named the same id, so that source decides the item. An old line that names
#     the merging task's own id is a stdout line instead, not counted, saying its own teardown
#     closes it;
#   - a column-0 line outside the block that starts with a directive word but does not fit
#     its form, a well-formed directive line outside the block (one per line, then one line
#     per body with the fix), and a `Train-member:` value that is no pull request URL. A
#     `Train-member:` line that names the
#     merged pull request itself is ignored with its own `actionable:` line and is not counted;
#   - in the merged pull request's body and in each train member's body that was read: an
#     active, not-done backlog id that appears as a word in the prose (every line outside the
#     block, read as plain text, with no Markdown) is a `mentioned ...`
#     line that says nothing was closed for it. An id is matched as spelled (a leading or
#     trailing `_` or `-` belongs to it; only leading and trailing `.` and one matched
#     Markdown emphasis pair, `_id_` or `__id__`, are dropped). An id
#     a directive line, task record or old line already named gets no second line, and the
#     merging task's own id is left out, because its teardown owns that item. A member's
#     prose never closes anything. In the same bodies, a link in the prose to a pull
#     request that is neither the merged one nor listed by a `Train-member:` line is also a
#     `mentioned ...` line, once per link, and a `Train-member:` line in a member's own block
#     (a member's members are not read) is a `named ...` line; links are read for GitHub,
#     GitLab and Forgejo alike. The id check
#     reads the backlog once; when the backlog cannot be listed, each body that has prose gets
#     one `actionable:` line that names it, whether or not it holds a directive line.
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
#     scout item, a proof it refuses (a ship item accepts only a GitHub pull request, and
#     no item accepts a GitLab merge request URL) or any other refusal
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
# it could not clear is an `actionable: close-at-merge:` line on stderr.
# Exit 0 when every named item was closed or was already done; exit 3 when any item was
# left open, a body was refused, a malformed or outside directive line or a `Train-member:`
# value that is no pull request URL was ignored, or a train member's body could not be read; exit 1 when the merged pull
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

# report_refusal <body-file> <where>: a refused block closes nothing from that body; say why.
report_refusal() {
  local reason
  reason=$(fm_pr_closes_refusal "$1")
  [ -n "$reason" ] || return 0
  LEFT=$((LEFT + 1))
  printf 'actionable: close-at-merge: refused to close anything named by %s: %s; a body holds exactly one closes block, its lines between a %s line and a %s line, each a Closes-backlog-item: <item-id> line, a Train-member: <pull request URL> line or blank; fix it, then retry: %s %s %s\n' \
    "$2" "$reason" "$FM_PR_CLOSES_BEGIN" "$FM_PR_CLOSES_END" "$0" "$TASK_ID" "$URL" >&2
}
report_refusal "$WORK/body" "the body of $URL"

while IFS= read -r id; do
  [ -z "$id" ] || consider "$id" "$URL" "the body of $URL"
done < <(fm_pr_closes_ids "$WORK/body")

: > "$WORK/old-form"
report_old_form() {  # <body-file> <where>: queue the old `Closes:` lines, report malformed and outside-block directive lines
  local old line
  while IFS= read -r old; do
    [ -z "$old" ] || printf '%s\t%s\n' "$old" "$2" >> "$WORK/old-form"
  done < <(fm_pr_closes_legacy_ids "$1")
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    LEFT=$((LEFT + 1))
    printf 'actionable: close-at-merge: ignored a malformed directive line in %s: %s; the forms are one Closes-backlog-item: <item-id> or Train-member: <pull request URL> per line\n' "$2" "$line" >&2
  done < <(fm_pr_closes_malformed "$1")
  local outside=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    LEFT=$((LEFT + 1))
    outside=1
    printf 'actionable: close-at-merge: ignored a directive line outside a directive block in %s: %s\n' "$2" "$line" >&2
  done < <(fm_pr_closes_outside "$1")
  [ "$outside" = 0 ] || printf 'actionable: close-at-merge: a directive closes only inside the one closes block, between a %s line and a %s line; fix %s, then retry: %s %s %s\n' \
    "$FM_PR_CLOSES_BEGIN" "$FM_PR_CLOSES_END" "$2" "$0" "$TASK_ID" "$URL" >&2
}
report_old_form "$WORK/body" "the body of $URL"

n=0
MEMBER_URLS=()
MEMBER_SEEN=$'\n'
while IFS= read -r candidate; do
  [ -n "$candidate" ] || continue
  if ! fm_pr_url_parse "$candidate"; then
    LEFT=$((LEFT + 1))
    printf 'actionable: close-at-merge: could not use Train-member %s: it is not a GitHub, GitLab or Forgejo pull request URL, so nothing was closed for it\n' "$candidate" >&2
    continue
  fi
  member=$FM_PR_URL
  if [ "$member" = "$URL" ]; then
    printf 'actionable: close-at-merge: ignored Train-member %s: it is the merged pull request itself\n' "$member" >&2
    continue
  fi
  case "$MEMBER_SEEN" in *$'\n'"$member"$'\n'*) continue ;; esac
  MEMBER_SEEN="$MEMBER_SEEN$member"$'\n'
  n=$((n + 1))
  MEMBER_URLS[n]=$member
  if read_body "$member" "$WORK/member-$n"; then
    report_refusal "$WORK/member-$n" "the body of train member $member"
    while IFS= read -r id; do
      [ -z "$id" ] || consider "$id" "$URL" "the body of train member $member"
    done < <(fm_pr_closes_ids "$WORK/member-$n")
    report_old_form "$WORK/member-$n" "the body of train member $member"
  else
    LEFT=$((LEFT + 1))
    printf 'actionable: close-at-merge: could not read the body of train member %s (%s); retry: %s %s %s\n' \
      "$member" "$(sed -n '1p' "$WORK/member-$n.err")" "$0" "$TASK_ID" "$URL" >&2
  fi
  while IFS= read -r task; do
    [ -n "$task" ] || continue
    consider "$task" "$URL" "the task record that holds train member $member"
  done < <(tasks_recording_pr "$member")
done < <(fm_pr_closes_members "$WORK/body")

while IFS=$'\t' read -r old where; do
  [ -n "$old" ] || continue
  case "$SEEN" in *$'\n'"$old"$'\n'*) continue ;; esac
  SEEN="$SEEN$old"$'\n'
  if [ "$old" = "$TASK_ID" ]; then
    printf 'close-at-merge: %s names the merging task %s with a Closes: line, which closes nothing; its own teardown closes it\n' "$where" "$old"
  else
    left_open "$old" "$where names it with a Closes: line, which closes nothing; write 'Closes-backlog-item: $old' in the body's closes block, then retry: $0 $TASK_ID $URL"
  fi
done < "$WORK/old-form"

# Mentions outside the block: reported, never closed. The merged body and every train member
# body that was read are checked, against one read of the backlog.
MENTION_BODIES=("$WORK/body")
MENTION_WHERE=("the prose of $URL")
MENTION_HOW=("add a Closes-backlog-item: <id> line to the body's closes block if this merge finished it")
m=1
while [ "$m" -le "$n" ]; do
  if [ -f "$WORK/member-$m" ]; then
    MENTION_BODIES+=("$WORK/member-$m")
    MENTION_WHERE+=("the prose of train member ${MEMBER_URLS[$m]}")
    MENTION_HOW+=("add a Closes-backlog-item: <id> line to the train body's closes block or to that member's if it finished the item")
  fi
  m=$((m + 1))
done
PROSE_AT=()
k=0
while [ "$k" -lt "${#MENTION_BODIES[@]}" ]; do
  [ -z "$(fm_pr_closes_prose_words "${MENTION_BODIES[$k]}" | sed -n '1p')" ] || PROSE_AT+=("$k")
  k=$((k + 1))
done
if [ "${#PROSE_AT[@]}" -gt 0 ]; then
  if states=$(fm_backlog_row_states "$DATA" 2>/dev/null); then
    : > "$WORK/active-ids"
    while IFS= read -r row; do
      [ -n "$row" ] && [ "${row#*:}" != "done" ] || continue
      printf '%s\n' "${row%%:*}" >> "$WORK/active-ids"
    done <<ROWS
$states
ROWS
    SEEN="$SEEN$TASK_ID"$'\n'
    for k in "${PROSE_AT[@]}"; do
      while IFS= read -r word; do
        [ -n "$word" ] || continue
        case "$SEEN" in *$'\n'"$word"$'\n'*) continue ;; esac
        SEEN="$SEEN$word"$'\n'
        printf 'actionable: close-at-merge: mentioned %s in %s: nothing was closed for it; %s\n' \
          "$word" "${MENTION_WHERE[$k]}" "${MENTION_HOW[$k]//<id>/$word}" >&2
      done < <(fm_pr_closes_prose_words "${MENTION_BODIES[$k]}" | grep -Fxf "$WORK/active-ids")
    done
  else
    for k in "${PROSE_AT[@]}"; do
      printf 'actionable: close-at-merge: could not list the backlog to check which ids %s mentions, so none were checked\n' "${MENTION_WHERE[$k]}" >&2
    done
  fi
fi
# Pull request links in the merged body and in every train member body that was read: each
# link that is neither the merged pull request nor a listed member is reported once.
LINKED_SEEN=$MEMBER_SEEN
k=0
while [ "$k" -lt "${#MENTION_BODIES[@]}" ]; do
  while IFS= read -r linked; do
    fm_pr_url_parse "$linked" || continue
    [ "$FM_PR_URL" != "$URL" ] || continue
    case "$LINKED_SEEN" in *$'\n'"$FM_PR_URL"$'\n'*) continue ;; esac
    LINKED_SEEN="$LINKED_SEEN$FM_PR_URL"$'\n'
    printf 'actionable: close-at-merge: mentioned %s in %s: no item was closed for it; list it as a Train-member: line if it landed with this merge\n' "$FM_PR_URL" "${MENTION_WHERE[$k]}" >&2
  done < <(fm_pr_closes_prose_prs "${MENTION_BODIES[$k]}")
  # A member's own Train-member lines (in its block) list nothing: a member's members are not read.
  if [ "$k" -gt 0 ]; then
    while IFS= read -r linked; do
      fm_pr_url_parse "$linked" || continue
      [ "$FM_PR_URL" != "$URL" ] || continue
      case "$LINKED_SEEN" in *$'\n'"$FM_PR_URL"$'\n'*) continue ;; esac
      LINKED_SEEN="$LINKED_SEEN$FM_PR_URL"$'\n'
      printf 'actionable: close-at-merge: named %s with a Train-member: line in the body of %s: a member body lists no members, so no item was closed for it; list it as a Train-member: line in the train body if it landed with this merge\n' \
        "$FM_PR_URL" "${MENTION_WHERE[$k]#the prose of }" >&2
    done < <(fm_pr_closes_members "${MENTION_BODIES[$k]}")
  fi
  k=$((k + 1))
done

if [ "$CLOSED" -gt 0 ] || [ "$LEFT" -gt 0 ]; then
  printf 'close-at-merge: %s closed, %s left open\n' "$CLOSED" "$LEFT"
fi
[ "$LEFT" -eq 0 ] || exit 3
exit 0
