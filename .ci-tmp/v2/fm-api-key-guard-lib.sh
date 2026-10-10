# shellcheck shell=bash
# Shared Claude API key guard check for firstmate spawns and relaunches.
# Usage: source after bin/fm-config-inherit-lib.sh is available.
#
# This is the shared preflight for refusing a Claude worker when an Anthropic
# credential could be inherited without deliberate API billing:
#   - bin/fm-spawn.sh checks before creating a worker.
#   - bin/fm-control.sh checks before stopping the current worker for relaunch.
#
# It reads the invoking environment and, on tmux, the effective session/global
# environment. Existing panes can hold older values; the launch command sheds
# both credential variables when billing has not been opted into.
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
    if [ ! -f "$config/launch-env-allowlist" ] || [ ! -r "$config/launch-env-allowlist" ]; then
      echo "error: config/launch-env-allowlist must be a readable regular file" >&2
      return 1
    fi
    # Output is consumed by fm-spawn and fm-control after sourcing this library.
    # shellcheck disable=SC2034
    if ! FM_API_KEY_LAUNCH_ENV_NAMES=$(jq -Rrs '
      split("\n") | map(select(. != "" and (startswith("#") | not))) |
      if all(.[]; test("^[A-Za-z_][A-Za-z0-9_]*$")) then .[]
      else error("expected environment names only") end
    ' "$config/launch-env-allowlist" 2>/dev/null); then
      echo "error: config/launch-env-allowlist must contain one environment name per line, blank lines, or # comments" >&2
      return 1
    fi
  fi
}

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