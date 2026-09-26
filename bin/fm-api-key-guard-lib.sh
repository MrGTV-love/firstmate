# shellcheck shell=bash
# Shared Claude API key guard check for firstmate spawns and relaunches.
# Usage: . bin/fm-api-key-guard-lib.sh   (after FM_HOME and CONFIG are set)
#
# This is the one implementation of "refuse to launch a Claude worker when an
# Anthropic API key would reach it" used by every entry point:
#   - bin/fm-spawn.sh runs the full check including the tmux pane environment.
#   - bin/fm-control.sh runs a pre-check before stopping the running agent so
#     the guard does not cost a working worker.
#
# The guard reads the spawning process's own environment and, optionally, the
# tmux pane environment. It does NOT detect pane rc files or direnv exports.
#
# See docs/configuration.md "Claude API key guard" for semantics.

# fm_api_key_guard <harness> <allow_api_key> <worker_account> <launch_env_enabled> <launch_env_names> [backend]
# Returns:
#   0 - guard passes, no refusal needed
#   1 - guard would refuse, error printed to stderr
# When backend is "tmux", also checks the effective session/global environment.
fm_api_key_guard() {
  local harness=$1 allow_api_key=$2 worker_account=$3
  local launch_env_enabled=$4 launch_env_names=$5 backend=${6:-}
  local route_text check_var would_reach tmux_session tmux_env_entry tmux_env_scope

  # Only claude workers are affected.
  [ "$harness" = claude ] && [ "$allow_api_key" -eq 0 ] || return 0

  # A worker-account pin shed strips both ANTHROPIC_API_KEY and
  # ANTHROPIC_AUTH_TOKEN from the launch (fm_worker_account_claude_shed).
  [ -z "$worker_account" ] || return 0

  # Determine route text for the error message.
  if [ "$launch_env_enabled" = 1 ]; then
    route_text=' through config/launch-env-allowlist'
  else
    route_text=' through ambient environment inheritance'
  fi

  # Check each variable in the spawning environment.
  for check_var in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do
    would_reach=1
    if [ "$launch_env_enabled" = 1 ]; then
      case $'\n'"$launch_env_names"$'\n' in
      *$'\n'"$check_var"$'\n'*) ;;
      *) would_reach=0 ;;  # Filtered out by allowlist, no refusal
      esac
    fi
    if [ "$would_reach" -eq 1 ] && [ -n "${!check_var:-}" ]; then
      echo "error: $check_var is set and would reach the claude worker$route_text; unset it or pass --allow-api-key to deliberately bill the API" >&2
      return 1
    fi
  done

  # A new tmux window inherits the session environment over the global
  # environment. A session removal marker suppresses a global value.
  if [ "$backend" = tmux ]; then
    tmux_session=
    if [ -n "${TMUX:-}" ]; then
      tmux_session=$(tmux display-message -p '#S' 2>/dev/null) || tmux_session=
    elif tmux has-session -t firstmate 2>/dev/null; then
      tmux_session=firstmate
    fi
    for check_var in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do
      if [ "$launch_env_enabled" = 1 ]; then
        case $'\n'"$launch_env_names"$'\n' in
        *$'\n'"$check_var"$'\n'*) ;;
        *) continue ;;
        esac
      fi
      tmux_env_scope=
      if [ -n "$tmux_session" ] \
         && tmux_env_entry=$(tmux show-environment -t "$tmux_session" "$check_var" 2>/dev/null); then
        case "$tmux_env_entry" in
        "$check_var"=?*) tmux_env_scope=session ;;
        esac
      elif tmux_env_entry=$(tmux show-environment -g "$check_var" 2>/dev/null); then
        case "$tmux_env_entry" in
        "$check_var"=?*) tmux_env_scope=global ;;
        esac
      fi
      case "$tmux_env_scope" in
      session)
        echo "error: $check_var is set in the tmux session environment and would reach the claude worker; unset it (tmux set-environment -t $tmux_session -u $check_var) or pass --allow-api-key to deliberately bill the API" >&2
        return 1
        ;;
      global)
        echo "error: $check_var is set in the tmux global environment and would reach the claude worker; unset it (tmux set-environment -g -u $check_var) or pass --allow-api-key to deliberately bill the API" >&2
        return 1
        ;;
      esac
    done
  fi

  return 0
}