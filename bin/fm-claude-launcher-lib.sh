#!/usr/bin/env bash
# fm-claude-launcher-lib.sh - the single owner of config/claude-launcher: how
# the file is parsed and the TeamClaude proxy check a Claude template launch
# must pass before anything changes.
#
# docs/configuration.md "Claude launcher" owns the operator-facing contract.
# Sourced by bin/fm-spawn.sh, which selects the launch executable before any
# endpoint, worktree, or record exists, and by bin/fm-control.sh, which runs
# the same selection before a relaunch stops the old agent.

FM_CLAUDE_LAUNCHER_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$FM_CLAUDE_LAUNCHER_LIB_DIR/fm-config-inherit-lib.sh"

# fm_claude_launcher_select <config-dir>
# Prints the executable a Claude launch starts: `claude` when
# <config-dir>/claude-launcher is absent, or bin/fm-teamclaude-launch.sh when
# the file holds `teamclaude` and that launcher's --check passes. Any other
# content, an unreadable file, a relative XDG_CONFIG_HOME or TEAMCLAUDE_CONFIG
# (the worker's TeamClaude runs from another directory), or a failed check
# refuses on stderr and returns 1.
fm_claude_launcher_select() {
  local file="$1/claude-launcher" present value var
  local launch_bin="$FM_CLAUDE_LAUNCHER_LIB_DIR/fm-teamclaude-launch.sh"
  present=$(fm_config_source_present "$file") || return 1
  if [ "$present" = 0 ]; then
    printf 'claude\n'
    return 0
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: config/claude-launcher must be a readable regular file holding teamclaude" >&2
    return 1
  fi
  value=$(tr -d '[:space:]' <"$file" || true)
  if [ "$value" != teamclaude ]; then
    echo "error: config/claude-launcher holds '$value'; the only accepted value is teamclaude (remove the file to launch claude directly)" >&2
    return 1
  fi
  for var in XDG_CONFIG_HOME TEAMCLAUDE_CONFIG; do
    case ${!var:-} in
    '' | /*) ;;
    *)
      echo "error: config/claude-launcher=teamclaude requires an absolute $var so the worker reads the TeamClaude configuration this launch checked" >&2
      return 1
      ;;
    esac
  done
  if [ ! -f "$launch_bin" ] || [ ! -x "$launch_bin" ]; then
    echo "error: config/claude-launcher=teamclaude needs the executable launcher $launch_bin; refusing to launch Claude without the proxy" >&2
    return 1
  fi
  "$launch_bin" --check >&2 || return 1
  printf '%s\n' "$launch_bin"
}
