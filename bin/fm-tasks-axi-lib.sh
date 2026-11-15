# shellcheck shell=bash
# Shared tasks-axi backend selection and compatibility probe for bootstrap,
# teardown, and secondmate backlog handoff.
# Usage: . bin/fm-tasks-axi-lib.sh
#
# Compatible means tasks-axi --version reports FM_TASKS_AXI_MIN or newer,
# `tasks-axi update --help` exposes --archive-body for recoverable note rewrites,
# and `tasks-axi mv --help` exposes [<id>...] for atomic multi-ID moves required
# by secondmate handoffs.
# FM_TASKS_AXI_MIN follows the axi-family floor policy owned beside the floor
# constants in bin/fm-bootstrap.sh.
# The feature probes are a separate concern and stay as defense in depth for
# stripped or forked builds that advertise a current version without those flags.
# `config/backlog-backend=manual` opts out of tasks-axi for routine firstmate
# backlog mutations, but validated secondmate handoffs always use `tasks-axi mv`.
# Absent or any other value keeps the default tasks-axi backend path, falling
# back to manual mutation when the tool is not compatible.
# fm_tasks_axi_backend_resolve owns backend precedence: TASKS_AXI_BACKEND when
# set, then a backend in the working root's .tasks.toml, then one in
# $HOME/.tasks-axi/config.toml, then markdown. Lower-priority sources are read
# only when no earlier source supplies a backend; absent files keep that fallback.
# A detected unreadable or nonregular configuration file, including a dangling
# symlink, returns 2 with a path diagnostic on stderr and no backend on stdout.
# fm_tasks_axi_backend delegates to that resolver and preserves its status;
# callers must check it before selecting backend-specific flags or exemptions.
#
# This file is the single owner of FM_TASKS_AXI_MIN. bin/fm-bootstrap.sh turns a
# failing check into the operator-facing MISSING diagnostic.
#
# COMPATIBILITY VERDICT REUSE. fm_tasks_axi_compatible costs three tasks-axi
# subprocesses, and one session start needs the same verdict twice: once in
# bin/fm-session-start.sh's backlog listing and once in the bin/fm-bootstrap.sh
# child it runs. Two reuse layers collapse that to a single probe:
#   - Within a process the first probe's answer is memoised.
#   - Across ONE process hop, a parent that already holds the verdict passes it
#     in FM_TASKS_AXI_COMPATIBLE=0|1. Sourcing this file CONSUMES that variable
#     (it is unset from the environment and kept only as a private shell
#     variable), so the verdict reaches the child that needs it and never leaks
#     onward into a spawned agent's environment, where it could outlive a
#     tasks-axi upgrade. Any value other than exactly 0 or 1 is ignored and the
#     probe runs normally.
# Both layers are bounded by process lifetime, so a tasks-axi install or upgrade
# is picked up by the next process rather than being cached to disk.

FM_TASKS_AXI_MIN=0.2.6

FM_TASKS_AXI_COMPATIBLE_MEMO=${FM_TASKS_AXI_COMPATIBLE:-}
unset FM_TASKS_AXI_COMPATIBLE
case "$FM_TASKS_AXI_COMPATIBLE_MEMO" in
  0|1) ;;
  *) FM_TASKS_AXI_COMPATIBLE_MEMO= ;;
esac

fm_tasks_axi_version_parts() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi --version 2>/dev/null) || return 1
  printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1
}

fm_tasks_axi_compatible() {
  case "$FM_TASKS_AXI_COMPATIBLE_MEMO" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  if fm_tasks_axi_compatible_probe; then
    FM_TASKS_AXI_COMPATIBLE_MEMO=1
    return 0
  fi
  FM_TASKS_AXI_COMPATIBLE_MEMO=0
  return 1
}

fm_tasks_axi_compatible_probe() {
  local parts major minor patch extra
  local min_major min_minor min_patch min_extra
  parts=$(fm_tasks_axi_version_parts) || return 1
  [ -n "$parts" ] || return 1
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_TASKS_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  if [ "$major" -gt "$min_major" ] ||
    { [ "$major" -eq "$min_major" ] && [ "$minor" -gt "$min_minor" ]; } ||
    { [ "$major" -eq "$min_major" ] && [ "$minor" -eq "$min_minor" ] && [ "$patch" -ge "$min_patch" ]; }; then
    fm_tasks_axi_update_has_archive_body && fm_tasks_axi_mv_has_multi_id
    return $?
  fi
  return 1
}

fm_tasks_axi_update_has_archive_body() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi update --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '--archive-body' >/dev/null
}

fm_tasks_axi_mv_has_multi_id() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi mv --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '[<id>...]' >/dev/null
}

fm_tasks_axi_backend_from_toml() {  # <toml-path>
  local toml=$1
  [ -f "$toml" ] || return 1
  LC_ALL=C awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    BEGIN { root=1; found=0; single=sprintf("%c", 39) }
    {
      line=$0
      sub(/[[:space:]]*#.*/, "", line)
      line=trim(line)
      if (line ~ /^\[[^]]+\]$/) {
        root=0
        next
      }
      if (root && line ~ /^backend[[:space:]]*=/) {
        sub(/^backend[[:space:]]*=[[:space:]]*/, "", line)
        line=trim(line)
        if ((substr(line, 1, 1) == "\"" && substr(line, length(line), 1) == "\"") ||
            (substr(line, 1, 1) == single && substr(line, length(line), 1) == single)) {
          print substr(line, 2, length(line) - 2)
          found=1
          exit
        }
      }
    }
    END { if (!found) exit 1 }
  ' "$toml"
}

# Resolve the active tasks-axi backend with the same precedence as tasks-axi.
fm_tasks_axi_backend_resolve() {  # <tasks-axi-working-directory>
  local root=$1 backend
  if [ "${TASKS_AXI_BACKEND+x}" = x ]; then
    printf '%s\n' "$TASKS_AXI_BACKEND"
    return 0
  fi
  local config="$root/.tasks.toml"
  if { [ -d "${config%/*}" ] && [ ! -x "${config%/*}" ]; } ||
    { { [ -e "$config" ] || [ -L "$config" ]; } && { [ ! -f "$config" ] || [ ! -r "$config" ]; }; }; then
    printf 'tasks-axi backend configuration cannot be read at %s\n' "$config" >&2
    return 2
  fi
  if backend=$(fm_tasks_axi_backend_from_toml "$config"); then
    printf '%s\n' "$backend"
    return 0
  fi
  if [ -n "${HOME:-}" ]; then
    config="$HOME/.tasks-axi/config.toml"
    if { [ -d "${config%/*}" ] && [ ! -x "${config%/*}" ]; } ||
      { { [ -e "$config" ] || [ -L "$config" ]; } && { [ ! -f "$config" ] || [ ! -r "$config" ]; }; }; then
      printf 'tasks-axi backend configuration cannot be read at %s\n' "$config" >&2
      return 2
    fi
    if backend=$(fm_tasks_axi_backend_from_toml "$config"); then
      printf '%s\n' "$backend"
      return 0
    fi
  fi
  printf '%s\n' markdown
}

fm_tasks_axi_backend() {  # <tasks-axi-working-directory>
  fm_tasks_axi_backend_resolve "$1"
}

fm_backlog_backend_value() {
  local config_dir=$1 backend_file value
  backend_file="$config_dir/backlog-backend"
  if [ -f "$backend_file" ]; then
    value=$(tr -d '[:space:]' < "$backend_file" 2>/dev/null || true)
    [ -n "$value" ] || value=tasks-axi
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' tasks-axi
}

fm_backlog_backend_manual() {
  local config_dir=$1
  [ "$(fm_backlog_backend_value "$config_dir")" = manual ]
}

fm_tasks_axi_backend_available() {
  local config_dir=$1
  fm_backlog_backend_manual "$config_dir" && return 1
  fm_tasks_axi_compatible
}

# Typed public-followup completions (Main 1851 F4, Main 1875 F3). bin/fm-tasks-axi.sh clears a
# finished obligation's blocked-by edges after `public-followup waive` or `record-delivery`, so
# it must name the same id tasks-axi completed, in every form tasks-axi 0.2.6 accepts.
#
# fm_typed_completion_resolve <tasks-axi args...>: reads the arguments with tasks-axi's own
# grammar: an optional leading `task` noun (dist/src/cli.js:82-83); the command
# `public-followup`; then, in everything after the command, the global `--backend` and `--file`
# flags are taken out wherever they stand, each as `--flag value` (a value may not start with
# `--` and may not be empty) or `--flag=value` (non-empty), the way cli.js parseGlobalFlags does
# (dist/src/cli.js:102-140, args.js:7-15); what is left starts with the subcommand. Then for the
# handler, takeBoolFlag --json, then takeFlag for each value flag in the handler's order (waive:
# --reason, --approved-by; record-delivery: --receipt-file), each as `--flag value` or
# `--flag=value` (dist/src/args.js:52-80; commands/public-followup.js:589-594, 709-718); then
# exactly one positional, the id. Sets FM_TYPED_COMPLETION (waive or record-delivery) and
# FM_TYPED_COMPLETION_ID. Returns 0 for a resolved id, 1 when the arguments are not a typed
# completion, 2 when they may be one but no single valid id can be resolved (the caller runs
# it with the capture guard, clears nothing and warns), and 3 for a help call.
fm_typed_completion_resolve() {
  local -a a rest vflags
  local flag i n tok found positional='' count=0 help=0 bad=0
  FM_TYPED_COMPLETION=
  FM_TYPED_COMPLETION_ID=
  a=("$@")
  [ "${a[0]:-}" != task ] || a=("${a[@]:1}")
  [ "${a[0]:-}" = public-followup ] || return 1
  a=("${a[@]:1}")
  # Help: the runner prints a command's help and runs nothing when any argument after the command
  # is exactly `--help` (axi-sdk-js 0.1.12 dist/cli.js:77-82; tasks-axi dist/src/cli.js:84), even
  # where a flag would take it as a value. `-h` is no help flag there.
  for tok in ${a[@]+"${a[@]}"}; do
    [ "$tok" != --help ] || help=1
  done
  # parseGlobalFlags: take out every --backend and --file, in either form, wherever it stands.
  rest=()
  n=${#a[@]}
  for ((i = 0; i < n; i++)); do
    tok=${a[i]}
    case "$tok" in
      --backend|--file)
        if [ $((i + 1)) -lt "$n" ] && [ "${a[i+1]#--}" = "${a[i+1]}" ] && [ -n "${a[i+1]//[[:space:]]/}" ]; then
          i=$((i + 1))
        else
          bad=1
        fi
        continue
        ;;
      --backend=*|--file=*)
        [ -n "${tok#*=}" ] || bad=1
        continue
        ;;
    esac
    rest+=("$tok")
  done
  a=(${rest[@]+"${rest[@]}"})
  case "${a[0]:-}" in
    waive) vflags=(--reason --approved-by) ;;
    record-delivery) vflags=(--receipt-file) ;;
    *) [ "$bad" = 0 ] && return 1; [ "$help" = 0 ] || return 3; return 2 ;;
  esac
  # shellcheck disable=SC2034  # bin/fm-tasks-axi.sh reads it.
  FM_TYPED_COMPLETION=${a[0]}
  [ "$help" = 0 ] || return 3
  [ "$bad" = 0 ] || return 2
  a=("${a[@]:1}")
  # takeBoolFlag: remove the first --json.
  rest=() found=0
  for tok in ${a[@]+"${a[@]}"}; do
    if [ "$found" = 0 ] && [ "$tok" = --json ]; then found=1; continue; fi
    rest+=("$tok")
  done
  a=(${rest[@]+"${rest[@]}"})
  # takeFlag, in the handler's order: the first `--flag value` or `--flag=value`.
  for flag in "${vflags[@]}"; do
    n=${#a[@]}
    for ((i = 0; i < n; i++)); do
      if [ "${a[i]}" = "$flag" ]; then
        [ $((i + 1)) -lt "$n" ] && [ "${a[i+1]#--}" = "${a[i+1]}" ] || return 2
        a=("${a[@]:0:i}" "${a[@]:i+2}")
        break
      fi
      case "${a[i]}" in
        "$flag="*) a=("${a[@]:0:i}" "${a[@]:i+1}"); break ;;
      esac
    done
  done
  for tok in ${a[@]+"${a[@]}"}; do
    case "$tok" in
      -*) return 2 ;;
      *) positional=$tok; count=$((count + 1)) ;;
    esac
  done
  [ "$count" -eq 1 ] && [[ "$positional" =~ ^[A-Za-z0-9._][A-Za-z0-9._-]*$ ]] || return 2
  # shellcheck disable=SC2034  # bin/fm-tasks-axi.sh reads it.
  FM_TYPED_COMPLETION_ID=$positional
  return 0
}

# fm_tasks_axi_package_dir: the installed tasks-axi package directory, found from each tasks-axi
# on PATH by its real path (symlinks followed), so a fixture shim named tasks-axi that sits first
# on PATH is passed over, not trusted. Prints the directory, or returns 1.
fm_tasks_axi_package_dir() {
  local bin real link dir
  while IFS= read -r bin; do
    [ -n "$bin" ] || continue
    real=$bin
    while [ -L "$real" ]; do
      link=$(readlink "$real") || continue 2
      case "$link" in /*) real=$link ;; *) real=${real%/*}/$link ;; esac
    done
    dir=$(cd "${real%/*}/../.." 2>/dev/null && pwd -P) || continue
    [ -f "$dir/package.json" ] && [ -f "$dir/dist/src/context.js" ] && [ -f "$dir/dist/src/backends/lock.js" ] || continue
    grep -Eq '"name"[[:space:]]*:[[:space:]]*"tasks-axi"' "$dir/package.json" || continue
    printf '%s\n' "$dir"
    return 0
  done <<< "$(type -ap tasks-axi 2>/dev/null)"
  return 1
}

FM_TASKS_AXI_LOCKED_UNBLOCK="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/fm-tasks-axi-locked-unblock.mjs"

# fm_typed_completion_locked_clear <data-dir> <id>: Main 1873 and 1882. The finished-blocker
# clear after a typed completion, decided and written under tasks-axi's own store lock by
# bin/fm-tasks-axi-locked-unblock.mjs (its header names the tasks-axi APIs): an item with <id>
# that is in the active backlog and not done keeps every edge and hold; otherwise every
# blocked-by edge on <id> is removed in the same locked write. Prints an `unblocked:` line per
# cleared dependent, in the same words as fm_backlog_unblock_dependents. Returns 0 when it
# cleared (or there was nothing to clear), 3 when it kept the edges (FM_TYPED_COMPLETION_KEPT
# holds the state it read), and 1 when it could not run or read (FM_TYPED_COMPLETION_CLEAR_ERROR
# holds why); a failure changes nothing.
# shellcheck disable=SC2034  # FM_TYPED_COMPLETION_KEPT and _CLEAR_ERROR are read by bin/fm-tasks-axi.sh.
fm_typed_completion_locked_clear() {  # <data-dir> <id>
  local id=$2 pkg out status first line dep left
  FM_TYPED_COMPLETION_KEPT='' FM_TYPED_COMPLETION_CLEAR_ERROR=''
  if ! fm_backlog_tasks_axi_addressing "$1"; then
    FM_TYPED_COMPLETION_CLEAR_ERROR="the backlog could not be addressed${FM_BACKLOG_TRANSITION_ERROR:+: $FM_BACKLOG_TRANSITION_ERROR}"
    return 1
  fi
  if ! pkg=$(fm_tasks_axi_package_dir); then
    FM_TYPED_COMPLETION_CLEAR_ERROR="the installed tasks-axi package could not be found"
    return 1
  fi
  if ! command -v node >/dev/null 2>&1; then
    FM_TYPED_COMPLETION_CLEAR_ERROR="node is not on PATH"
    return 1
  fi
  out=$(cd "$FM_BACKLOG_AXI_ROOT" 2>/dev/null && node "$FM_TASKS_AXI_LOCKED_UNBLOCK" "$pkg" "$FM_BACKLOG_AXI_ROOT" "$FM_BACKLOG_AXI_FILE" "$id" 2>&1)
  status=$?
  first=${out%%$'\n'*}
  if [ "$status" -ne 0 ]; then
    FM_TYPED_COMPLETION_CLEAR_ERROR=${first:-the locked clear failed with status $status}
    return 1
  fi
  case "$first" in
    'keep '*) FM_TYPED_COMPLETION_KEPT=${first#keep }; return 3 ;;
    clear) ;;
    *) FM_TYPED_COMPLETION_CLEAR_ERROR="the locked clear answered '$first'"; return 1 ;;
  esac
  while IFS= read -r line; do
    case "$line" in 'unblocked '*) ;; *) continue ;; esac
    line=${line#unblocked }
    dep=${line%% *}
    left=${line#* }
    if [ "$left" = - ]; then
      printf 'unblocked: %s no longer waits on %s; no stored blocked-by edge remains\n' "$dep" "$id"
    else
      printf 'unblocked: %s no longer waits on %s; it still waits on %s\n' "$dep" "$id" "$left"
    fi
  done <<< "$out"
  return 0
}
