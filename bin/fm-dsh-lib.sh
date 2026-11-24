#!/usr/bin/env bash
# dsh-tui binary admission and process identity. No probes occur on source.
# fm_dsh_executable and fm_dsh_cli resolve the machine installation from PATH.
# fm_dsh_launch_check is read-only: it never bootstraps a missing profile.
# fm-dsh.py owns per-launch HOME/profile staging and the durable JSONL fold.
# fm_dsh_script_path keeps the legacy dsh-tui identities (fm_dsh_tui_script_path)
# and recognizes the modern @deepseek-ai/dsh CLI entrypoint through absolute
# installed paths (fm_dsh_cli_script_path).
# Relative argv paths need the ancestor's cwd and are not resolved here.
# A script merely named dsh is not evidence of the modern CLI.

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

fm_dsh_launch_check() {  # [executable] [ship|scout|primary|secondmate]
  local executable=${1:-} cli
  case "${2:-}" in
    primary|secondmate)
      command -v perl >/dev/null 2>&1 || { echo 'error: DSH primary requires perl for owner-bound supervision cleanup' >&2; return 1; }
      ;;
  esac
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
  fm_dsh_tui_script_path "$1" || fm_dsh_cli_script_path "$1"
}

fm_dsh_tui_script_path() {  # <path>
  case "$1" in
    */dsh-tui|*/@deepseek-harness-tui/dsh-tui/*) return 0 ;;
  esac
  return 1
}

fm_dsh_cli_script_path() {  # <path>
  local path=$1 dir target link
  local -a dsh_script_links=()
  case "$path" in /*) ;; *) return 1 ;; esac
  # Resolve installed links without executing them or trusting a dsh basename.
  # Repeated physical link paths prove a cycle; finite chains have no hop cap.
  while :; do
    dir=$(CDPATH='' cd -- "$(dirname -- "$path")" 2>/dev/null && pwd -P) || return 1
    path=$dir/${path##*/}
    [ -L "$path" ] || break
    for link in ${dsh_script_links[@]+"${dsh_script_links[@]}"}; do
      [ "$link" != "$path" ] || return 1
    done
    dsh_script_links+=("$path")
    target=$(readlink -- "$path") || return 1
    case "$target" in
      /*) path=$target ;;
      *) path=$dir/$target ;;
    esac
  done
  [ -f "$path" ] || return 1
  case "$path" in
    */@deepseek-ai/dsh/lib/bin.js) return 0 ;;
  esac
  return 1
}

fm_dsh_args_are_dsh() {  # <flattened-argv> [script-predicate]
  local args=$1 predicate=${2:-fm_dsh_script_path} executable script
  args=${args#"${args%%[![:space:]]*}"}
  executable=${args%%[[:space:]]*}
  case "${executable##*/}" in node|nodejs|MainThread) ;; *) return 1 ;; esac
  [ "$args" != "$executable" ] || return 1
  args=${args#"$executable"}
  args=${args#"${args%%[![:space:]]*}"}
  script=${args%%[[:space:]]*}
  "$predicate" "$script"
}

# fm_dsh_launch_alive: 0 when a running, unstopped process is a dsh-tui
# launcher (fm_dsh_args_are_dsh) whose argv carries this launch's own
# `--patch <launch-patch>`. Each launch's patch path is unique to its task and
# generation, so a frame left on screen by a launch that exited, or one parked
# with job control, does not count as this launch's live composer. The patch
# sits inside the pattern's double quotes, so glob characters in it match only
# themselves.
fm_dsh_launch_alive() {  # <launch-patch>
  local patch=$1 line stat args
  [ -n "$patch" ] || return 1
  while IFS= read -r line; do
    line=${line#"${line%%[![:space:]]*}"}
    stat=${line%%[[:space:]]*}
    args=${line#"$stat"}
    case "$stat" in T* | Z* | '') continue ;; esac
    case "$args " in *" --patch $patch "*) ;; *) continue ;; esac
    fm_dsh_args_are_dsh "$args" && return 0
  done <<EOF
$(ps -eww -o stat=,args= 2>/dev/null)
EOF
  return 1
}

fm_dsh_pid_is_dsh() {  # <pid>
  local args
  args=$(ps -o args= -p "$1" 2>/dev/null) || return 1
  fm_dsh_args_are_dsh "$args"
}
