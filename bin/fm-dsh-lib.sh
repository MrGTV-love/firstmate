#!/usr/bin/env bash
# dsh-tui binary admission and process identity. No probes occur on source.
# fm_dsh_executable resolves PATH first, then the pinned nvm installation.
# fm_dsh_launch_check is read-only: it never bootstraps a missing profile.
# fm-dsh.py owns per-launch HOME/profile staging and the durable JSONL fold.

fm_dsh_executable() {
  local executable
  executable=$(type -P dsh-tui 2>/dev/null) || executable=
  [ -n "$executable" ] || executable="$HOME/.nvm/versions/node/v24.4.1/bin/dsh-tui"
  [ -x "$executable" ] || { echo 'error: dsh-tui executable not found; install the verified dsh-tui runtime' >&2; return 1; }
  printf '%s' "$executable"
}

# The launcher spawns the `dsh` CLI through PATH, so a pane without the
# installing nvm bin directory cannot start a session even though the launcher
# itself resolved. Resolve the CLI beside the launcher first, then PATH.
fm_dsh_cli() {  # [executable]
  local executable=${1:-} candidate
  [ -n "$executable" ] || executable=$(fm_dsh_executable) || return 1
  candidate="$(dirname "$executable")/dsh"
  if [ ! -x "$candidate" ]; then
    candidate=$(type -P dsh 2>/dev/null) || candidate=
  fi
  [ -n "$candidate" ] && [ -x "$candidate" ] || {
    echo 'error: dsh CLI not found beside dsh-tui or on PATH; install @deepseek-ai/dsh' >&2
    return 1
  }
  printf '%s' "$candidate"
}

fm_dsh_launch_check() {  # [executable]
  local executable=${1:-} reported cli
  [ -n "$executable" ] || executable=$(fm_dsh_executable) || return 1
  reported=$("$executable" version 2>/dev/null) || return 1
  case "$reported" in
    '@deepseek-harness-tui/dsh-tui 0.16.1 (launcher)'$'\n''profile: 0.16.1  '*) ;;
    *)
      echo 'error: dsh-tui requires live-verified launcher and installed profile 0.16.1; inspect dsh-tui version before dispatch' >&2
      return 1
      ;;
  esac
  cli=$(fm_dsh_cli "$executable") || return 1
  reported=$("$cli" --version 2>/dev/null | head -n 1) || return 1
  [ "$reported" = '0.2.0-rc.2' ] || {
    echo "error: dsh CLI reports '$reported'; this adapter is live-verified only on 0.2.0-rc.2" >&2
    return 1
  }
}

fm_dsh_script_path() {  # <path>
  case "$1" in
    */@deepseek-ai/dsh/lib/bin.js|*/@deepseek-harness-tui/dsh-tui/bin/dsh-tui.js|*/@deepseek-harness-tui/dsh-tui/lib/types/dsh-adapter/host-entry.js) return 0 ;;
  esac
  return 1
}

fm_dsh_args_are_dsh() {  # <flattened-argv>
  local args=$1 executable script
  args=${args#"${args%%[![:space:]]*}"}
  executable=${args%%[[:space:]]*}
  case "${executable##*/}" in node|nodejs|MainThread) ;; *) return 1 ;; esac
  [ "$args" != "$executable" ] || return 1
  args=${args#"$executable"}
  args=${args#"${args%%[![:space:]]*}"}
  script=${args%%[[:space:]]*}
  fm_dsh_script_path "$script"
}

fm_dsh_pid_is_dsh() {  # <pid>
  local args
  args=$(ps -o args= -p "$1" 2>/dev/null) || return 1
  fm_dsh_args_are_dsh "$args"
}
