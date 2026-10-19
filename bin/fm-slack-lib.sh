#!/usr/bin/env bash
# Slack environment and Python entry point, sourced by the Slack commands.
# Usage: . bin/fm-slack-lib.sh; fm_slack_run <command> [--replay PATH]
# An explicitly supplied environment value wins, including an empty value.
# FM_SLACK_FAULT (test-only crash injection) is read from the process environment only.
FM_SLACK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$FM_SLACK_SCRIPT_DIR/.." && pwd)}}"
# shellcheck source=bin/fm-env-lib.sh
. "$FM_SLACK_SCRIPT_DIR/fm-env-lib.sh"
for fm_slack_key in SLACK_BOT_TOKEN FM_SLACK_DM_USER FM_SLACK_ALLOWED_AUTHORS \
  FM_SLACK_POLL_MAX_ANSWERS; do
  if ! declare -p "$fm_slack_key" >/dev/null 2>&1; then
    printf -v "$fm_slack_key" '%s' "$(fmx_env_get "$fm_slack_key" "$FM_HOME/.env")"
  fi
  export "${fm_slack_key?}"
done
unset fm_slack_key
export PYTHONDONTWRITEBYTECODE=1
fm_slack_run() {
  exec python3 "$FM_SLACK_SCRIPT_DIR/fm_slack_watch.py" "$@"
}
