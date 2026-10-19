#!/usr/bin/env bash
# fm-answered-by-lib.sh - derive who answered a decision, for the records that
# keep it (the fleet ledger's task.answered event and a captain hold's
# "Answered by:" line). Sourcing this library only defines functions.
#
# The value is worked out from what the script already knows, never typed by a
# person, and is always one of these literals:
#   main        a firstmate answer sent from a main home
#   main-afk    the same, while an away record (bin/fm-afk-contract.sh) stands
#   secondmate  a firstmate answer sent from a secondmate home
#   page        the answer is a captured result
#   unknown     anything else, including an unreadable home identity
# A hold's source is the text bin/fm-captain-hold.sh records as "Captain
# answered this call through <source>."; it is read for two exact prefixes only.
# "a firstmate answer sent to " is a send and "the captured result " is a
# captured result. A hold answered with no such line was answered directly by
# the home that ran the command, so both of those take the sending home's role.
# Any other recorded source is unknown.

_FM_ANSWERED_BY_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$_FM_ANSWERED_BY_LIB_DIR/fm-parent-channel-lib.sh"

# The role of the home that is sending the answer. The away record's library is
# sourced only when a main home needs it, so the ledger's per-status-line calls
# never pay for it.
fm_answered_by_home_role() {  # <home> <state>
  local rc=0
  fm_parent_channel_home_id "$1" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) printf 'secondmate' ;;
    1)
      if ! declare -F fm_afk_contract_away_present >/dev/null 2>&1; then
        # shellcheck source=bin/fm-afk-contract.sh
        . "$_FM_ANSWERED_BY_LIB_DIR/fm-afk-contract.sh"
      fi
      if fm_afk_contract_away_present "$2"; then printf 'main-afk'; else printf 'main'; fi
      ;;
    *) printf 'unknown' ;;
  esac
}

# <via> is send or hold; <source> is read only for hold.
fm_answered_by() {  # <home> <state> <via> [<source>]
  local via=$3 source=${4:-}
  [ "$via" != send ] || { fm_answered_by_home_role "$1" "$2"; return 0; }
  case "$source" in
    ''|'a firstmate answer sent to '*) fm_answered_by_home_role "$1" "$2" ;;
    'the captured result '*) printf 'page' ;;
    *) printf 'unknown' ;;
  esac
}
