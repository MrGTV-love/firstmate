#!/usr/bin/env bash
# Standing Slack poll on the existing custom-check cadence.
# Usage:
#   fm-slack-check.sh [check] [--replay <transcript.json>]   run the check
#   fm-slack-check.sh arm [--replay <transcript.json>]
#   fm-slack-check.sh disarm [--replay <transcript.json>]
#   fm-slack-check.sh retarget [--replay <transcript.json>]   after FM_SLACK_DM_USER changed
#   fm-slack-check.sh resolve <request-ts>   close one failed owner request that Main has dealt with
# A request whose acknowledgement failed in its own thread on 3 polls is woken once as not acknowledged and stays
# in the journal as failed, owner Main; every poll and check lists it until resolve removes it. Resolve makes no
# Slack call and refuses an unknown ts or a request that is not failed.
# Retarget refuses while the old DM still has pending work or unread owner requests, and the poll refuses a
# changed owner: restore the old FM_SLACK_DM_USER and run fm-slack-poll.sh with it, then set the new value,
# then disarm, retarget, arm. A poll can print nothing while work is still pending, and an empty journal
# does not prove the old DM is drained: a poll takes in at most the per-poll cap.
# A retarget that still refuses with dm_user_changed_with_pending_work or dm_user_changed_with_unread_requests means: restore the old value, poll again.
# Last resort, when a pending row can never drain because its thread or channel is gone: run disarm, check the
# pending rows by hand, then remove state/slack-watch/ to start a fresh DM. This can re-read replies that were
# already answered, so do it only after that check. The same last resort covers an old thread retarget can never
# read or judge (a hold id that can never be probed, a tapper whose users.info lookup keeps failing, a deleted card):
# first read that thread in Slack by hand and record any answer with fm-captain-hold.sh answer, then disarm and
# remove state/slack-watch/. The reset abandons that thread's unread reply.
#   fm-slack-check.sh --help
set -euo pipefail
# shellcheck source=bin/fm-slack-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-slack-lib.sh"
export FM_SLACK_CHECK_ACTION=check
case "${1:-}" in
  -h|--help)
    printf '%s\n' \
      'Usage: fm-slack-check.sh [arm|check|disarm|retarget] [--replay transcript.json]' \
      '       fm-slack-check.sh resolve <request-ts>' \
      'Bind slack-dm with fm-captain-hold.sh before arm; arm proves the DM is readable.' \
      'Retarget stops tracking the old DM after FM_SLACK_DM_USER changed; arm then opens the new one.' \
      'Retarget refuses while the old DM has pending work or unread owner requests and the poll refuses a changed' \
      'owner, so: restore the old FM_SLACK_DM_USER and run fm-slack-poll.sh with it, then set the new value,' \
      'then disarm, retarget, arm. A poll can print nothing while work is still pending, and an empty journal does' \
      'not prove the old DM is drained: a poll takes in at most the per-poll cap.' \
      'A retarget that still refuses with dm_user_changed_with_pending_work or dm_user_changed_with_unread_requests' \
      'means: restore the old value, poll again.' \
      'Last resort, when a pending row can never drain because its thread or channel is gone: run disarm, check the' \
      'pending rows by hand, then remove state/slack-watch/ to start a fresh DM. This can re-read replies that were' \
      'already answered, so do it only after that check. The same last resort covers an old thread retarget can never' \
      'read or judge (a hold id that can never be probed, a tapper whose users.info lookup keeps failing, a deleted' \
      'card): first read that thread in Slack by hand and record any answer with fm-captain-hold.sh answer, then' \
      'disarm and remove state/slack-watch/. The reset abandons that thread'"'"'s unread reply.' \
      'Resolve closes one failed owner request (woken once as not acknowledged after 3 tries and listed on every' \
      'poll and check until then) after Main has dealt with it; it makes no Slack call and refuses an unknown ts or' \
      'a request that is not failed.' \
      'Disarm is the hard off switch. Unconfigured is silent/off; an explicit arm names the refusal.' \
      'See docs/configuration.md "Slack decision plane".'
    exit 0
    ;;
  arm|check|disarm|retarget|resolve)
    export FM_SLACK_CHECK_ACTION=$1
    shift
    ;;
esac
fm_slack_run check "$@"
