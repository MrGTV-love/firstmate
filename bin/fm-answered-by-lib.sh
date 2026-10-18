#!/usr/bin/env bash
# fm-answered-by-lib.sh - derive who answered a decision, for the records that
# keep it (the fleet ledger's task.answered event and a captain hold's
# "Answered by:" line). Sourcing this library only defines functions.
#
# The value is worked out from what the script already knows, never typed by a
# person, and is always one of these literals:
#   main        a firstmate answer sent from a main home
#   main-afk    the same, while the away posture record state/.afk exists
#   secondmate  a firstmate answer sent from a secondmate home
#   page        the recorded source names a review page, board, or card
#   chat        the recorded source names the chat
#   policy      the recorded source names a standing policy or rule
#   unknown     anything else, including an unreadable home identity
# A hold's source is the text bin/fm-captain-hold.sh records as "Captain
# answered this call through <source>."; a source that says "a firstmate
# answer sent to <task>" is a send, so it takes the sending home's role.

_FM_ANSWERED_BY_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$_FM_ANSWERED_BY_LIB_DIR/fm-parent-channel-lib.sh"

# The role of the home that is sending the answer.
fm_answered_by_home_role() {  # <home> <state>
  local rc=0
  fm_parent_channel_home_id "$1" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) printf 'secondmate' ;;
    1) if [ -e "$2/.afk" ]; then printf 'main-afk'; else printf 'main'; fi ;;
    *) printf 'unknown' ;;
  esac
}

# <via> is send or hold; <source> is read only for hold.
fm_answered_by() {  # <home> <state> <via> [<source>]
  local via=$3 source lower
  [ "$via" != send ] || { fm_answered_by_home_role "$1" "$2"; return 0; }
  source=${4:-}
  lower=$(printf '%s' "$source" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    'a firstmate answer sent to '*) fm_answered_by_home_role "$1" "$2" ;;
    *lavish*|*page*|*board*|*card*|*'captured result'*) printf 'page' ;;
    *chat*|*message*|*conversation*) printf 'chat' ;;
    *policy*|*standing*|*rule*) printf 'policy' ;;
    *) printf 'unknown' ;;
  esac
}
