#!/usr/bin/env bash
# Launch Claude only through a live local TeamClaude proxy.
#
# Usage:
#   fm-teamclaude-launch.sh --check
#   fm-teamclaude-launch.sh <claude-argument>...
#
# config/claude-launcher=teamclaude makes fm-spawn's Claude launch command run
# this wrapper in place of `claude`, so every path that builds that command -
# fresh spawn, --relaunch, fm-control relaunch, the session-end auto-relaunch,
# and secondmate launch and restart - reaches Claude through the proxy on every
# runtime backend, with no dependence on a shell alias in the pane.
#
# The wrapper resolves TeamClaude on each host, requires its status endpoint to
# answer, takes the client environment from `teamclaude env` (TeamClaude's own
# eval-safe export lines for a tool that starts Claude itself, which must set
# HTTPS_PROXY), and then replaces itself with `claude`, so the pane's process is
# Claude exactly as in a direct launch.
# `teamclaude run` is not used because it keeps a Node parent process between
# the pane and Claude.
# Any failure exits non-zero before Claude starts; it never launches unproxied.
# --check performs every step except starting Claude, and fm-spawn runs it
# before any task state exists.
#
# TeamClaude's own configuration owns the port and proxy credentials.
# FM_TC_XDG_CONFIG_HOME and FM_TC_TEAMCLAUDE_CONFIG, when fm-spawn sets them,
# become XDG_CONFIG_HOME and TEAMCLAUDE_CONFIG for the teamclaude calls only and
# never reach claude.
# This wrapper never prints the environment it applies.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

FM_TEAMCLAUDE_TIMEOUT=10

fail() {
  printf 'error: TeamClaude %s; refusing to launch Claude without it\n' "$1" >&2
  exit 1
}

teamclaude_bin() {
  local candidate
  candidate=$(type -P teamclaude || true)
  if [ -n "$candidate" ] && [ -f "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  local found='' count=0
  for candidate in "$HOME"/.nvm/versions/node/*/bin/teamclaude; do
    if [ -f "$candidate" ] && [ -x "$candidate" ]; then
      found=$candidate
      count=$((count + 1))
    fi
  done
  case $count in
    1) printf '%s\n' "$found" ;;
    0) fail 'is not installed: install an executable teamclaude on PATH or under one Node version in ~/.nvm/versions/node' ;;
    *) fail 'is ambiguous: expose one teamclaude executable on PATH' ;;
  esac
}

# An nvm-installed teamclaude is a `#!/usr/bin/env node` script whose node lives
# beside it, and a pane PATH need not include that directory.
run_teamclaude() (
  [ -z "${FM_TC_XDG_CONFIG_HOME:-}" ] || export XDG_CONFIG_HOME="$FM_TC_XDG_CONFIG_HOME"
  [ -z "${FM_TC_TEAMCLAUDE_CONFIG:-}" ] || export TEAMCLAUDE_CONFIG="$FM_TC_TEAMCLAUDE_CONFIG"
  PATH="$TC_DIR:$PATH" fm_run_timed "$FM_TEAMCLAUDE_TIMEOUT" "$TC_BIN" "$@"
)

apply_proxy_env() {
  local status=0 lines
  TC_BIN=$(teamclaude_bin)
  TC_DIR=$(dirname "$TC_BIN")

  run_teamclaude status >/dev/null 2>&1 || status=$?
  if [ "$status" -ne 0 ]; then
    fm_timed_out "$status" && fail 'proxy status check timed out'
    fail 'proxy is not running or did not answer its status check (start it with: teamclaude server)'
  fi

  status=0
  lines=$(run_teamclaude env 2>/dev/null) || status=$?
  if [ "$status" -ne 0 ]; then
    fm_timed_out "$status" && fail 'client environment export timed out'
    fail 'could not export its client environment (teamclaude env failed)'
  fi
  unset HTTPS_PROXY
  eval "$lines"
  [ -n "${HTTPS_PROXY:-}" ] || fail 'client environment did not set HTTPS_PROXY'
}

if [ "${1:-}" = --check ]; then
  [ "$#" -eq 1 ] || fail '--check accepts no Claude arguments'
  apply_proxy_env
  exit 0
fi

apply_proxy_env
unset FM_TC_XDG_CONFIG_HOME FM_TC_TEAMCLAUDE_CONFIG
exec claude "$@"
