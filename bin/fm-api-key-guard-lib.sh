# shellcheck shell=bash
# Shared Claude API key guard check for firstmate spawns and relaunches.
# Usage: source after bin/fm-config-inherit-lib.sh and bin/fm-worker-account-lib.sh.
#
# This is the shared preflight for refusing a Claude worker when an Anthropic
# credential could be inherited without deliberate API billing:
#   - bin/fm-spawn.sh checks before worker execution, not endpoint acquisition.
#   - bin/fm-control.sh checks before stopping the current worker for relaunch.
#
# On tmux it checks the effective prospective or established destination
# environment; other backends inherit the caller environment. The launch command
# sheds both credential variables when billing has not been opted into.
#
# See docs/configuration.md "Claude API key guard" for semantics.

# fm_api_key_guard_launch_env_config <config-dir>
# Reads the same allowlist used to construct the launch, setting
# FM_API_KEY_LAUNCH_ENV_ENABLED and FM_API_KEY_LAUNCH_ENV_NAMES.
fm_api_key_guard_launch_env_config() {
  local config=$1
  FM_API_KEY_LAUNCH_ENV_ENABLED=$(fm_config_source_present "$config/launch-env-allowlist") || return 1
  FM_API_KEY_LAUNCH_ENV_NAMES=
  if [ "$FM_API_KEY_LAUNCH_ENV_ENABLED" = 1 ]; then
    # shellcheck disable=SC2034 # Output global read by sourcing callers.
    FM_API_KEY_LAUNCH_ENV_NAMES=$(fm_config_launch_env_names "$config") || return 1
  fi
}

# fm_api_key_guard <harness> <allow_api_key> <worker_account> <launch_env_enabled> <launch_env_names> <backend> [destination]
# Returns:
#   0 - guard passes, no refusal needed
#   1 - guard would refuse, error printed to stderr
# The optional destination is a tmux endpoint (session:window.pane) or session.
# Omit it for a fresh launch; pass the recorded target for adoption or relaunch.
# Destination resolution and update-environment imports share the worker-account
# helper used by destination-scoped launch preflights.
fm_api_key_guard() {
  local harness=$1 allow_api_key=$2 worker_account=$3
  local launch_env_enabled=$4 launch_env_names=$5 backend=${6:-} destination=${7:-}
  local route_text check_var would_reach tmux_session tmux_env_scope
  local caller_env_reaches=1

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

  # A running tmux server owns the destination environment, not the caller.
  if [ "$backend" = tmux ] && tmux show-environment -g >/dev/null 2>&1; then
    caller_env_reaches=0
  fi
  for check_var in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do
    would_reach=1
    if [ "$launch_env_enabled" = 1 ]; then
      case $'\n'"$launch_env_names"$'\n' in
      *$'\n'"$check_var"$'\n'*) ;;
      *) would_reach=0 ;;  # Filtered out by allowlist, no refusal
      esac
    fi
    if [ "$caller_env_reaches" -eq 1 ] && [ "$would_reach" -eq 1 ] && [ -n "${!check_var:-}" ]; then
      echo "error: $check_var is set and would reach the claude worker$route_text; unset it or pass --allow-api-key to deliberately bill the API" >&2
      return 1
    fi
  done

  # Session removal markers and prospective update-environment imports are
  # resolved by the same helper as other destination-scoped preflights.
  if [ "$backend" = tmux ] && [ "$caller_env_reaches" -eq 0 ]; then
    tmux_session=${destination%%:*}
    if [ -z "$tmux_session" ]; then
      if [ -n "${TMUX:-}" ]; then
        tmux_session=$(tmux display-message -p '#S' 2>/dev/null) || tmux_session=
      elif tmux has-session -t firstmate 2>/dev/null; then
        tmux_session=firstmate
      fi
    fi
    for check_var in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do
      if [ "$launch_env_enabled" = 1 ]; then
        case $'\n'"$launch_env_names"$'\n' in
        *$'\n'"$check_var"$'\n'*) ;;
        *) continue ;;
        esac
      fi
      tmux_env_scope=$(fm_worker_account_tmux_env "$check_var" "$tmux_session") || {
        echo "error: cannot establish the destination tmux environment for the claude API key guard" >&2
        return 1
      }
      case "$tmux_env_scope" in
      client)
        echo "error: $check_var is set and would reach the claude worker through tmux update-environment; unset it or pass --allow-api-key to deliberately bill the API" >&2
        return 1
        ;;
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