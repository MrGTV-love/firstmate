#!/usr/bin/env bash
# Mirror every open captain call into the owner DM, one thread per call.
# Usage: fm-slack-mirror.sh [--replay <transcript.json>] [--help]
set -euo pipefail
# shellcheck source=bin/fm-slack-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-slack-lib.sh"
fm_slack_run mirror "$@"
