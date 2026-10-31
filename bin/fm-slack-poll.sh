#!/usr/bin/env bash
# Poll tracked Slack threads into the existing bound keyed-answer intake.
# Usage: fm-slack-poll.sh [--replay <transcript.json>] [--help]
# Journal, precedence, and authority behavior are owned by fm_slack_watch.py.
set -euo pipefail
# shellcheck source=bin/fm-slack-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-slack-lib.sh"
fm_slack_run poll "$@"
