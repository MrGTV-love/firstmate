#!/usr/bin/env bash
# Standing Slack poll on the existing custom-check cadence.
# Usage:
#   fm-slack-check.sh [check] [--replay <transcript.json>]   run the check
#   fm-slack-check.sh arm [--replay <transcript.json>]
#   fm-slack-check.sh disarm [--replay <transcript.json>]
#   fm-slack-check.sh retarget [--replay <transcript.json>]   after FM_SLACK_DM_USER changed
# Retarget refuses while the old DM still has pending work, and the poll refuses a changed owner:
# restore the old FM_SLACK_DM_USER, run fm-slack-poll.sh until the pending journal is empty, set the
# new value, then disarm, retarget, arm. A poll can print nothing while work is still pending. The journal
# is empty when, in the home with the old value restored, this prints 0:
#   python3 -c 'import json; print(len(json.load(open("state/slack-watch/state.json"))["pending"]))'
# A retarget that still refuses with dm_user_changed_with_pending_work means: restore the old value, poll again.
#   fm-slack-check.sh --help
set -euo pipefail
# shellcheck source=bin/fm-slack-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-slack-lib.sh"
export FM_SLACK_CHECK_ACTION=check
case "${1:-}" in
  -h|--help)
    printf '%s\n' \
      'Usage: fm-slack-check.sh [arm|check|disarm|retarget] [--replay transcript.json]' \
      'Bind slack-dm with fm-captain-hold.sh before arm; arm proves the DM is readable.' \
      'Retarget stops tracking the old DM after FM_SLACK_DM_USER changed; arm then opens the new one.' \
      'Retarget fails while the old DM has pending work and the poll fails on a changed owner, so: restore the old' \
      'FM_SLACK_DM_USER, run fm-slack-poll.sh until the pending journal is empty, set the new value, then disarm,' \
      'retarget, arm. A poll can print nothing while work is still pending. The journal is empty when, in the home' \
      'with the old value restored, this prints 0:' \
      "  python3 -c 'import json; print(len(json.load(open(\"state/slack-watch/state.json\"))[\"pending\"]))'" \
      'A retarget that still fails with dm_user_changed_with_pending_work means: restore the old value, poll again.' \
      'Disarm is the hard off switch. Unconfigured is silent/off; an explicit arm names the refusal.' \
      'See docs/configuration.md "Slack decision plane".'
    exit 0
    ;;
  arm|check|disarm|retarget)
    export FM_SLACK_CHECK_ACTION=$1
    shift
    ;;
esac
fm_slack_run check "$@"
