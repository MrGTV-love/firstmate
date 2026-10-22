#!/usr/bin/env bash
# dsh-tui binary admission and process identity. No probes occur on source.
# fm_dsh_executable and fm_dsh_cli resolve the machine installation from PATH.
# fm_dsh_launch_check is read-only: it never bootstraps a missing profile.
# fm-dsh.py owns per-launch HOME/profile staging and the durable JSONL fold.
# fm_dsh_script_path names dsh-tui by its launcher name or by any script in a
# @deepseek-harness-tui/dsh-tui package directory, installed or launch-staged.

fm_dsh_executable() {
  local executable
  executable=$(type -P dsh-tui 2>/dev/null) || executable=
  [ -n "$executable" ] && [ -x "$executable" ] || { echo 'error: dsh-tui executable not found on PATH; install dsh-tui' >&2; return 1; }
  printf '%s' "$executable"
}

# The launcher spawns the `dsh` CLI through PATH. Probe that same command,
# independently of the directory that contains dsh-tui.
fm_dsh_cli() {
  local candidate
  candidate=$(type -P dsh 2>/dev/null) || candidate=
  [ -n "$candidate" ] && [ -x "$candidate" ] || {
    echo 'error: dsh CLI not found on PATH; install @deepseek-ai/dsh' >&2
    return 1
  }
  printf '%s' "$candidate"
}

fm_dsh_launch_check() {  # [executable]
  local executable=${1:-} cli
  [ -n "$executable" ] || executable=$(fm_dsh_executable) || return 1
  "$executable" version >/dev/null 2>&1 || {
    echo 'error: dsh-tui version failed; inspect the launcher and installed profile' >&2
    return 1
  }
  cli=$(fm_dsh_cli) || return 1
  "$cli" --version >/dev/null 2>&1 || {
    echo 'error: dsh --version failed; inspect the installed CLI' >&2
    return 1
  }
}

fm_dsh_script_path() {  # <path>
  case "$1" in
    */dsh-tui|*/@deepseek-harness-tui/dsh-tui/*) return 0 ;;
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
