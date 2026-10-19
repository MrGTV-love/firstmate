#!/usr/bin/env bash
# Standing Slack poll on the existing custom-check cadence.
# Usage:
#   fm-slack-check.sh [check] [--replay <transcript.json>]   run the check
#   fm-slack-check.sh arm [--replay <transcript.json>]
#   fm-slack-check.sh disarm [--replay <transcript.json>]
#   fm-slack-check.sh --help
set -euo pipefail
# shellcheck source=bin/fm-slack-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-slack-lib.sh"
case "${1:-}" in
  -h|--help)
    printf '%s\n' \
      'Usage: fm-slack-check.sh [arm|check|disarm] [--replay transcript.json]' \
      'Bind slack-dm with fm-captain-hold.sh before arm; arm proves the DM is readable.' \
      'Disarm is the hard off switch. Unconfigured is silent/off.' \
      'See docs/configuration.md "Slack decision plane".'
    exit 0
    ;;
  arm|check|disarm)
    export FM_SLACK_CHECK_ACTION=$1
    shift
    ;;
esac
fm_slack_run check "$@"
