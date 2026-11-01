#!/usr/bin/env bash
# Mirror every open captain call into the owner DM, one thread per call.
# Usage: fm-slack-mirror.sh [--replay <transcript.json>] [--help]
set -euo pipefail
# Internal discovery uses the registry owner, without loading Slack credentials.
if [ "${1:-}" = --registered-homes ]; then
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  home=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$script_dir/.." && pwd)}}
  registry="${FM_DATA_OVERRIDE:-$home/data}/secondmates.md"
  [ -e "$registry" ] || [ -L "$registry" ] || exit 0
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$script_dir/fm-secondmate-registry-lib.sh"
  if ! secondmate_registry_validate_bindings "$registry" secondmate_registry_path_key; then
    printf '%s\n' "$SECONDMATE_REGISTRY_ERROR" >&2
    exit 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line"
    printf '%s\0%s\0%s\0' "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_HOME" "$SECONDMATE_REGISTRY_HOST"
  done < "$registry"
  exit 0
fi
# shellcheck source=bin/fm-slack-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-slack-lib.sh"
fm_slack_run mirror "$@"
