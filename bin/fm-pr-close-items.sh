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
# What it reads. The merged pull request's body, parsed once by bin/fm-pr-closes-lib.sh's
# fm_pr_closes_parse, which owns the closes block and its one grammar: the block must open the
# body (its begin line `<!-- firstmate-backlog-closes:begin -->` is the first non-empty line),
# end with `<!-- firstmate-backlog-closes:end -->`, hold only exact
# `Closes-backlog-item: <item-id>` lines, exact `Train-member: <url>` lines naming a GitHub,
# GitLab or Forgejo pull request (fm_pr_url_parse), and empty lines, in printable ASCII, with the
# marker text on no other line. Every close, edge change and report comes from that one parse
# result, and the whole body is judged before anything it names is closed. A body that is not
# exactly so is refused: nothing in it closes, a refused train body reads no member, and no
# edge changes. Nothing outside an honored block closes an item, and no Markdown or HTML is
# interpreted. Each `Train-member:` pull request's body is parsed the same way (only its own
# block's `Closes-backlog-item:` lines), and every task whose state/<task>.meta records pr=
# equal to that member's full URL goes through the same completion too, even when that
# member's body is refused (the completion refuses a ship or scout task with a live record).
# Commit messages are never read. Bodies are read from GitHub, GitLab and Forgejo, each member
# by its own URL. The proof is always the merged pull request this script was given (the
# train's own URL for a train), because a train's members close unmerged. A body with no
# marker text closes nothing, a train body written before this block existed included; its
# items are closed by hand as before.
# These things are reported, never closed, on stderr behind `actionable:`. The first three
# kinds count as left open, so they add to the summary's left open count and make the exit
# status 3; a `mentioned ...` line changes neither:
#   - a refused body (the merged one or a train member's): `refused to close anything named
#     by the body of <url>: <reason>; it names item ids: ...; pull request links: ...`, one
#     line per body naming every item id and pull request link the body names; its directive
#     lines are then reported as outside the block, below;
#   - an old `Closes: <item-id>` line is `not closed <id>`, naming the new form. It is reported
#     only after every body and task record has been read, and only when no directive line or
#     task record named the same id, so that source decides the item. An old line that names
#     the merging task's own id is a stdout line instead, not counted, saying its own teardown
#     closes it;
#   - a column-0 line outside the block that starts with a directive word but does not fit
#     its form, a well-formed directive line outside the block (one per line, then one line
#     per body with the fix). Each active id and pull request link on a malformed line is
#     also reported as a mention, below;
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
# error); exit 2 on a bad request. A refused body, a cut read, a NUL byte, a failed parse or an
# unreadable parse result counts as left open. bin/fm-pr-merge.sh reports any status other than
# 0 and 3 with the retry command, and no close outcome ever changes the merge result.
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
  # Main 1785 F1 and F2: the forge's bytes go to files, never through command substitution
  # (which drops NUL bytes), and every step that writes the body file must succeed; any failed
  # step is a failed read, so the caller refuses the whole body and names the reason.
  local url=$1 out=$2 login rc=0 state
  echo false > "$out.merged"
  : > "$out.err"
  fm_pr_url_parse "$url" || { echo "not a pull request URL" > "$out.err"; return 1; }
  case "$FM_PR_PROVIDER" in
    github)
      # The first line is the state; the rest is the body.
      gh pr view "$url" --json body,state --jq 'if type == "object" and has("body") and has("state") then (.state // "") + "\n" + (.body // "") else error("the forge answered with no body field") end' > "$out.raw" 2>"$out.err" || rc=$?
      if [ "$rc" -eq 0 ]; then
        state=$(head -n 1 "$out.raw") || rc=$?
      fi
      if [ "$rc" -eq 0 ]; then
        tail -n +2 "$out.raw" > "$out" 2>>"$out.err" || { rc=$?; echo "the body could not be written from the forge's answer (status $rc)" >> "$out.err"; }
      fi
      [ "$rc" -ne 0 ] || [ "$state" != MERGED ] || echo true > "$out.merged"
      ;;
    gitlab)
      command -v jq >/dev/null 2>&1 || { echo "jq is not installed" > "$out.err"; return 1; }
      GITLAB_HOST="$FM_PR_HOST" glab mr view "$FM_PR_NUMBER" -R "https://$FM_PR_HOST/$FM_PR_PATH" -F json > "$out.raw" 2>"$out.err" || rc=$?
      if [ "$rc" -eq 0 ]; then
        jq -jer 'if type == "object" and has("description") then (.description // "") + "\n" else error("the forge answered with no description field") end' "$out.raw" > "$out" 2>"$out.err" || rc=$?
      fi
      [ "$rc" -ne 0 ] || jq -r 'if type == "object" and .state == "merged" then true else false end' "$out.raw" > "$out.merged" 2>/dev/null || echo false > "$out.merged"
      ;;
    forgejo)
      command -v jq >/dev/null 2>&1 || { echo "jq is not installed" > "$out.err"; return 1; }
      login=$(fm_pr_forgejo_login "$FM_PR_HOST") || { echo "no single tea login for $FM_PR_HOST" > "$out.err"; return 1; }
      # "tea api" exits 0 on an HTTP error and prints the error body, so only a record
      # that has both a merged and a body field counts as a read (Main 1875 F6: a missing field
      # is a read error, never an empty body; a present empty or null body is empty).
      tea api --login "$login" --repo "$FM_PR_OWNER/$FM_PR_REPO" "/repos/{owner}/{repo}/pulls/$FM_PR_NUMBER" > "$out.raw" 2>"$out.err" || rc=$?
      if [ "$rc" -eq 0 ]; then
        jq -jer 'if type == "object" and has("merged") and has("body") then (.body // "") + "\n" else error("the forge answered: " + ((.message // "a record with no merged or no body field") | tostring)) end' "$out.raw" > "$out" 2>"$out.err" || rc=$?
      fi
      [ "$rc" -ne 0 ] || jq -r 'if type == "object" and .merged == true then true else false end' "$out.raw" > "$out.merged" 2>/dev/null || echo false > "$out.merged"
      ;;
    *)
      echo "reading a ${FM_PR_PROVIDER:-unknown} pull request body is not supported" > "$out.err"
      return 1
      ;;
  esac
  [ "$rc" -eq 0 ] || { [ -s "$out.err" ] || echo "the read failed with status $rc" > "$out.err"; echo false > "$out.merged"; return 1; }
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
    sed -n 's/^unblocked: /close-at-merge: unblocked: /p' <<< "$out"
    sed -n 's/^actionable: /actionable: close-at-merge: /p' <<< "$out" >&2
    return 0
  fi
  first=${out%%$'\n'*}
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

# tasks_recording_pr <pr-url>: sets RECORDING_TASKS to the task ids whose record holds exactly
# that URL as its last pr= value (fm_meta_get's rule). Main 1875 F7: each record is read whole,
# its status checked; a record that cannot be read is unknown, never "no match", so it is
# reported as an actionable line that counts as left open.
tasks_recording_pr() {
  local meta task text pr
  RECORDING_TASKS=''
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    task=${meta##*/}
    task=${task%.meta}
    fm_pr_task_id_valid "$task" || continue
    if ! text=$(cat -- "$meta" 2>/dev/null) ||
       ! pr=$(LC_ALL=C awk 'index($0, "pr=") == 1 { v = substr($0, 4) } END { print v }' <<< "$text"); then
      LEFT=$((LEFT + 1))
      printf 'actionable: close-at-merge: could not read the task record of %s, so it is not known whether it holds train member %s; nothing was closed for it; retry: %s %s %s\n' \
        "$task" "$1" "$0" "$TASK_ID" "$URL" >&2
      continue
    fi
    [ "$pr" = "$1" ] || continue
    RECORDING_TASKS="$RECORDING_TASKS$task"$'\n'
  done
}

if ! read_body "$URL" "$WORK/body"; then
  body_err=$(sed -n '1p' "$WORK/body.err" 2>/dev/null) || body_err=''
  printf 'actionable: close-at-merge could not read the body of %s (%s), so it closed nothing and the merge result is unchanged; retry: %s %s %s\n' \
    "$URL" "${body_err:-the read failed}" "$0" "$TASK_ID" "$URL" >&2
  exit 1
fi
MERGED=$(cat "$WORK/body.merged" 2>/dev/null) || MERGED=false

# Each body is parsed once (bin/fm-pr-closes-lib.sh fm_pr_closes_parse, the one parse), and its
# whole result is loaded once (fm_pr_closes_load) before anything it names acts: every close,
# edge change and report below comes from that one loaded result (Main 1742, Main 1875 rule P).
# A result that cannot be loaded whole closes nothing, reads no member and changes no edge.
#
# body_unread <where>: the parse result of a body could not be read whole. With no result, the
# items it names are not known (there is no second reader), so one line says so and counts as
# left open.
body_unread() {
  LEFT=$((LEFT + 1))
  printf 'actionable: close-at-merge: could not read the parse result of %s whole, so no item closed, every edge kept, and no member was read from it; the item ids it names are not known without that result; retry: %s %s %s\n' \
    "$1" "$0" "$TASK_ID" "$URL" >&2
}
# load_body <body-file> <where>: Main 1851 F2 and 1875 rule P. Loads the body's parse result
# whole, or reports it unread; a parse that failed is reported with its reason and the ids it
# names. Returns 0 only for a loaded result that did not fail.
load_body() {
  fm_pr_closes_load "$1.parse" || { body_unread "$2"; return 1; }
  [ "$FM_PR_CLOSES_STATUS" = failed ] || return 0
  LEFT=$((LEFT + 1))
  printf 'actionable: close-at-merge: could not parse %s, so nothing named by it was closed and no blocked-by edge changed: %s; it names item ids: %s; retry: %s %s %s\n' \
    "$2" "${FM_PR_CLOSES_REASON:-unknown reason}" "$(joined "$FM_PR_CLOSES_SEENIDS")" "$0" "$TASK_ID" "$URL" >&2
  return 1
}
# loaded_for <body-file> <where>: the loaded result is this body's, or it is loaded now.
loaded_for() {
  [ "$FM_PR_CLOSES_LOADED" = "$1.parse" ] || load_body "$1" "$2"
}
joined() {  # <newline list>: the list on one line, comma separated, or "none"
  local item out=''
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    out="${out:+$out, }$item"
  done <<< "$1"
  printf '%s' "${out:-none}"
}

# report_refusal <body-file> <where>: a refused body closes nothing, reads no member and changes
# no edge. One line names the reason and every item id and pull request link the body names.
# It reads only the loaded result; a body whose result cannot be loaded is reported unread.
report_refusal() {
  loaded_for "$1" "$2" || return 1
  [ "$FM_PR_CLOSES_STATUS" = refused ] || return 0
  LEFT=$((LEFT + 1))
  printf 'actionable: close-at-merge: refused to close anything named by %s: %s; it names item ids: %s; pull request links: %s; none was closed, no member was read from it and no blocked-by edge changed; a body names what it closes only when its first non-empty line is %s, then only exact Closes-backlog-item: <item-id> and Train-member: <GitHub, GitLab or Forgejo pull request URL> lines or empty lines, then %s, with the marker text nowhere else; fix it, then retry: %s %s %s\n' \
    "$2" "$FM_PR_CLOSES_REASON" "$(joined "$FM_PR_CLOSES_SEENIDS")" "$(joined "$FM_PR_CLOSES_SEENPRS")" "$FM_PR_CLOSES_BEGIN" "$FM_PR_CLOSES_END" "$0" "$TASK_ID" "$URL" >&2
}

OLD_FORM=''
report_old_form() {  # <body-file> <where>: queue the old `Closes:` lines, report malformed and outside-block directive lines
  local old line outside=0
  loaded_for "$1" "$2" || return 1
  while IFS= read -r old; do
    [ -z "$old" ] || OLD_FORM="$OLD_FORM$old"$'\t'"$2"$'\n'
  done <<< "$FM_PR_CLOSES_LEGACY"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    LEFT=$((LEFT + 1))
    printf 'actionable: close-at-merge: ignored a malformed directive line in %s: %s; the forms are one Closes-backlog-item: <item-id> or Train-member: <GitHub, GitLab or Forgejo pull request URL> per line, one space after the colon and nothing after the value\n' "$2" "$line" >&2
  done <<< "$FM_PR_CLOSES_MALFORMED"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    LEFT=$((LEFT + 1))
    outside=1
    printf 'actionable: close-at-merge: ignored a directive line outside a directive block in %s: %s\n' "$2" "$line" >&2
  done <<< "$FM_PR_CLOSES_OUTSIDE"
  [ "$outside" = 0 ] || printf 'actionable: close-at-merge: a directive closes only inside the one closes block, which must open the body with a %s line and end with a %s line; fix %s, then retry: %s %s %s\n' \
    "$FM_PR_CLOSES_BEGIN" "$FM_PR_CLOSES_END" "$2" "$0" "$TASK_ID" "$URL" >&2
}

# close_body <body-file> <where> <prose-where> <prose-how> [member]: parse, load whole, report every
# refusal and outside line, then close the block's items; the body's prose, links and (for a
# member) its own Train-member lines are kept for the mention reports. Sets BODY_STATUS and
# BODY_MEMBERS from the one loaded result.
MENTION_WHERE=() MENTION_HOW=() MENTION_WORDS=() MENTION_LINKS=() MENTION_MEMBERS=()
close_body() {
  local id ids
  BODY_STATUS=unread BODY_MEMBERS=''
  fm_pr_closes_parse "$1" "$URL" > "$1.parse" 2>/dev/null || true
  load_body "$1" "$2" || return 0
  BODY_STATUS=$FM_PR_CLOSES_STATUS BODY_MEMBERS=$FM_PR_CLOSES_MEMBERS ids=$FM_PR_CLOSES_IDS
  MENTION_WHERE+=("$3")
  MENTION_HOW+=("$4")
  MENTION_WORDS+=("$FM_PR_CLOSES_WORDS")
  MENTION_LINKS+=("$FM_PR_CLOSES_LINKS")
  # A member's own Train-member lines list nothing (a member's members are not read): kept to
  # be reported.
  if [ "$BODY_STATUS" = block ] && [ "${5:-}" = member ]; then MENTION_MEMBERS+=("$FM_PR_CLOSES_MEMBERS"); else MENTION_MEMBERS+=(''); fi
  report_refusal "$1" "$2"
  report_old_form "$1" "$2"
  [ "$BODY_STATUS" = block ] || return 0
  while IFS= read -r id; do
    [ -z "$id" ] || consider "$id" "$URL" "$2"
  done <<< "$ids"
}

close_body "$WORK/body" "the body of $URL" "the prose of $URL" \
  "add a Closes-backlog-item: <id> line to the body's closes block if this merge finished it"
TRAIN_STATUS=$BODY_STATUS TRAIN_MEMBERS=$BODY_MEMBERS

n=0
MEMBER_SEEN=$'\n'
if [ "$TRAIN_STATUS" = block ]; then
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    # The parse proved each member is a canonical GitHub, GitLab or Forgejo pull request URL of
    # any repository, and not the merged one itself; fm_pr_url_parse only sets the provider
    # fields read_body needs.
    if ! fm_pr_url_parse "$candidate"; then
      LEFT=$((LEFT + 1))
      printf 'actionable: close-at-merge: could not use Train-member %s, so nothing was closed for it; retry: %s %s %s\n' "$candidate" "$0" "$TASK_ID" "$URL" >&2
      continue
    fi
    member=$FM_PR_URL
    case "$MEMBER_SEEN" in *$'\n'"$member"$'\n'*) continue ;; esac
    MEMBER_SEEN="$MEMBER_SEEN$member"$'\n'
    n=$((n + 1))
    if read_body "$member" "$WORK/member-$n"; then
      close_body "$WORK/member-$n" "the body of train member $member" "the prose of train member $member" \
        "add a Closes-backlog-item: <id> line to the train body's closes block or to that member's if it finished the item" member
    else
      member_err=$(sed -n '1p' "$WORK/member-$n.err" 2>/dev/null) || member_err=''
      LEFT=$((LEFT + 1))
      printf 'actionable: close-at-merge: could not read the body of train member %s (%s); retry: %s %s %s\n' \
        "$member" "${member_err:-the read failed}" "$0" "$TASK_ID" "$URL" >&2
    fi
    tasks_recording_pr "$member"
    while IFS= read -r task; do
      [ -n "$task" ] || continue
      consider "$task" "$URL" "the task record that holds train member $member"
    done <<< "$RECORDING_TASKS"
  done <<< "$TRAIN_MEMBERS"
fi

while IFS=$'\t' read -r old where; do
  [ -n "$old" ] || continue
  case "$SEEN" in *$'\n'"$old"$'\n'*) continue ;; esac
  SEEN="$SEEN$old"$'\n'
  if [ "$old" = "$TASK_ID" ]; then
    printf 'close-at-merge: %s names the merging task %s with a Closes: line, which closes nothing; its own teardown closes it\n' "$where" "$old"
  else
    left_open "$old" "$where names it with a Closes: line, which closes nothing; write 'Closes-backlog-item: $old' in the body's closes block, then retry: $0 $TASK_ID $URL"
  fi
done <<< "$OLD_FORM"

# Mentions outside the block: reported, never closed. The merged body and every train member
# body that was loaded are checked, against one read of the backlog.
PROSE_AT=()
k=0
while [ "$k" -lt "${#MENTION_WORDS[@]}" ]; do
  [ -z "${MENTION_WORDS[$k]}" ] || PROSE_AT+=("$k")
  k=$((k + 1))
done
if [ "${#PROSE_AT[@]}" -gt 0 ]; then
  active_ids=''
  if states=$(fm_backlog_row_states "$DATA" 2>/dev/null); then
    while IFS= read -r row; do
      [ -n "$row" ] && [ "${row#*:}" != "done" ] || continue
      active_ids="$active_ids${row%%:*}"$'\n'
    done <<< "$states"
    if printf '%s' "$active_ids" > "$WORK/active-ids"; then
      SEEN="$SEEN$TASK_ID"$'\n'
      for k in "${PROSE_AT[@]}"; do
        match_rc=0
        matches=$(grep -Fxf "$WORK/active-ids" <<< "${MENTION_WORDS[$k]}") || match_rc=$?
        if [ "$match_rc" -gt 1 ]; then
          LEFT=$((LEFT + 1))
          printf 'actionable: close-at-merge: could not check which ids %s mentions, so none were checked; nothing was closed for them\n' "${MENTION_WHERE[$k]}" >&2
          continue
        fi
        while IFS= read -r word; do
          [ -n "$word" ] || continue
          case "$SEEN" in *$'\n'"$word"$'\n'*) continue ;; esac
          SEEN="$SEEN$word"$'\n'
          printf 'actionable: close-at-merge: mentioned %s in %s: nothing was closed for it; %s\n' \
            "$word" "${MENTION_WHERE[$k]}" "${MENTION_HOW[$k]//<id>/$word}" >&2
        done <<< "$matches"
      done
    else
      for k in "${PROSE_AT[@]}"; do
        LEFT=$((LEFT + 1))
        printf 'actionable: close-at-merge: could not write the backlog ids to check which ids %s mentions, so none were checked\n' "${MENTION_WHERE[$k]}" >&2
      done
    fi
  else
    for k in "${PROSE_AT[@]}"; do
      printf 'actionable: close-at-merge: could not list the backlog to check which ids %s mentions, so none were checked\n' "${MENTION_WHERE[$k]}" >&2
    done
  fi
fi
# Pull request links in the merged body and in every train member body that was loaded: each
# link that is neither the merged pull request nor a listed member is reported once.
LINKED_SEEN=$MEMBER_SEEN
k=0
while [ "$k" -lt "${#MENTION_LINKS[@]}" ]; do
  while IFS= read -r linked; do
    fm_pr_url_parse "$linked" || continue
    [ "$FM_PR_URL" != "$URL" ] || continue
    case "$LINKED_SEEN" in *$'\n'"$FM_PR_URL"$'\n'*) continue ;; esac
    LINKED_SEEN="$LINKED_SEEN$FM_PR_URL"$'\n'
    printf 'actionable: close-at-merge: mentioned %s in %s: no item was closed for it; list it as a Train-member: line if it landed with this merge\n' "$FM_PR_URL" "${MENTION_WHERE[$k]}" >&2
  done <<< "${MENTION_LINKS[$k]}"
  # A member's own Train-member lines (in its block) list nothing: a member's members are not read.
  while IFS= read -r linked; do
    [ -n "$linked" ] || continue
    case "$LINKED_SEEN" in *$'\n'"$linked"$'\n'*) continue ;; esac
    LINKED_SEEN="$LINKED_SEEN$linked"$'\n'
    printf 'actionable: close-at-merge: named %s with a Train-member: line in the body of %s: a member body lists no members, so no item was closed for it; list it as a Train-member: line in the train body if it landed with this merge\n' \
      "$linked" "${MENTION_WHERE[$k]#the prose of }" >&2
  done <<< "${MENTION_MEMBERS[$k]}"
  k=$((k + 1))
done

if [ "$CLOSED" -gt 0 ] || [ "$LEFT" -gt 0 ]; then
  printf 'close-at-merge: %s closed, %s left open\n' "$CLOSED" "$LEFT"
fi
[ "$LEFT" -eq 0 ] || exit 3
exit 0
