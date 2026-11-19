#!/usr/bin/env bash
# fm-disk-floor-lib.sh - the single owner of the free-disk floor: how many whole
# GiB are free on the volume that holds a path, and whether a heavy step may
# start.
#
# A nearly full volume makes every new worker, pipeline run and stack worse, so
# a NEW heavy step starts only while the volume holds at least the floor.
# docs/configuration.md "Disk free floor" is the operator reference.
#
# Sourced or executed:
#   fm-disk-floor-lib.sh free <path>
#       Prints the whole GiB free on the volume holding <path>. Exits 1 with no
#       output when the meter cannot be read.
#   fm-disk-floor-lib.sh floor [<config-dir>]
#       Prints the floor in GiB. Exits 2 when config/disk-free-floor is malformed.
#   fm-disk-floor-lib.sh admit <step> <path> [<config-dir>] [<task-id>]
#       Decides one start. <step> names what starts (spawn, pipeline or stack),
#       <path> is where its bytes will land, and <config-dir> defaults to
#       FM_CONFIG_OVERRIDE, else $FM_HOME/config (FM_HOME defaults to the checkout
#       holding this script). The exit status is 0 when the
#       step is admitted, 75 when it is deferred, and 2 when the floor file is
#       malformed.
#
# Measurement: `df -Pk <path>` on the nearest existing ancestor of <path>, so a
# copy that does not exist yet is measured on the volume it will be created on.
# The available kilobytes are divided by 1048576 in integer arithmetic, which is
# the 1,024-based whole-GiB figure `df -g` prints on macOS, rounded down; the
# POSIX flags also work on Linux, where GNU df has no -g and rounds up. df reads
# the volume of <path> itself, so on macOS that is the Data volume and on Linux
# the filesystem holding <path>.
#
# Floor: 20 GiB. config/disk-free-floor overrides it with one line holding a
# positive whole number of GiB of at most six digits, surrounding blanks allowed.
# An absent file means 20. Any other content refuses the start (exit 2) and names
# the file; a malformed floor is never guessed and never defers, because retrying
# a deferral cannot repair it.
#
# Deferral: below the floor `admit` prints one `deferred:` line naming the free
# GiB, the floor, the path measured and the config file, and returns 75. The
# caller's task stays queued and is dispatched again; 75 is never a failure.
#
# Unreadable meter: when df fails or prints nothing usable, `admit` admits the
# step, prints one `warning:` line, and records a warn event. An unreadable
# meter must not stop recovery.
#
# Every decision is recorded through bin/fm-guard-event.sh as guard
# `disk-free-floor` (deny below the floor, warn on an unreadable meter, allow
# otherwise); that writer is best effort and never changes the verdict.
#
# Exempt by construction, because this library is called only where NEW work
# starts: a relaunch of an existing worker (same copy, nothing allocated) and
# every teardown or cleanup path never call it, because recovering a dead worker
# and freeing space are what a full disk needs.
#
# No side effects on source.

FM_DISK_FLOOR_DEFAULT_GIB=20
# shellcheck disable=SC2034 # read by callers after sourcing.
FM_DISK_FLOOR_DEFER_EXIT=75

# Whole GiB free on the volume holding <path>; empty and nonzero when unreadable.
fm_disk_floor_free_gib() { # <path>
  local path=$1 probe line avail
  [ -n "$path" ] || return 1
  probe=$path
  while [ ! -e "$probe" ] && [ "$probe" != "/" ] && [ "$probe" != "." ]; do
    case "$probe" in
      */*) probe=${probe%/*}; [ -n "$probe" ] || probe=/ ;;
      *) probe=. ;;
    esac
  done
  line=$(df -Pk "$probe" 2>/dev/null | tail -n 1) || return 1
  # shellcheck disable=SC2086 # split the df columns on purpose.
  set -- $line
  [ "$#" -ge 4 ] || return 1
  avail=$4
  case "$avail" in
    '' | *[!0-9]*) return 1 ;;
  esac
  # Strip leading zeros so bash does not read the count as octal.
  while [ "${#avail}" -gt 1 ] && [ "${avail#0}" != "$avail" ]; do avail=${avail#0}; done
  printf '%s\n' $((avail / 1048576))
}

# Sets FM_DISK_FLOOR_GIB and FM_DISK_FLOOR_FILE; on a malformed file returns 2
# with FM_DISK_FLOOR_ERROR set.
fm_disk_floor_read() { # [<config-dir>]
  local config=${1:-} line value home
  if [ -z "$config" ]; then
    home=${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}
    config=${FM_CONFIG_OVERRIDE:-$home/config}
  fi
  FM_DISK_FLOOR_FILE="$config/disk-free-floor"
  FM_DISK_FLOOR_GIB=$FM_DISK_FLOOR_DEFAULT_GIB
  FM_DISK_FLOOR_ERROR=
  if [ ! -e "$FM_DISK_FLOOR_FILE" ] && [ ! -L "$FM_DISK_FLOOR_FILE" ]; then
    return 0
  fi
  if [ ! -f "$FM_DISK_FLOOR_FILE" ] || [ ! -r "$FM_DISK_FLOOR_FILE" ]; then
    FM_DISK_FLOOR_ERROR="$FM_DISK_FLOOR_FILE is not a readable regular file"
    return 2
  fi
  value=
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    if [ -n "$value" ]; then
      FM_DISK_FLOOR_ERROR="$FM_DISK_FLOOR_FILE holds more than one line; it must hold one positive whole number of GiB"
      return 2
    fi
    value=$line
  done <"$FM_DISK_FLOOR_FILE"
  case "$value" in
    '' | *[!0-9]* | 0* | ???????*)
      FM_DISK_FLOOR_ERROR="$FM_DISK_FLOOR_FILE must hold one positive whole number of GiB of at most six digits, with no leading zero (got '${value:-nothing}')"
      return 2
      ;;
  esac
  FM_DISK_FLOOR_GIB=$value
}

fm_disk_floor_event() { # <deny|warn|allow> <task-id>
  local script_dir
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 0
  [ -x "$script_dir/fm-guard-event.sh" ] || return 0
  "$script_dir/fm-guard-event.sh" disk-free-floor "$1" ${2:+--task "$2"} \
    ${3:+--source-ok "$3"} >/dev/null 2>&1 || true
}

# Decide one start; see the header.
fm_disk_floor_admit() { # <step> <path> [<config-dir>] [<task-id>]
  local step=$1 path=$2 config=${3:-} task=${4:-} free
  fm_disk_floor_read "$config" || {
    printf 'error: disk free floor refused %s: %s; fix or remove that file and start again\n' \
      "$step" "$FM_DISK_FLOOR_ERROR" >&2
    return 2
  }
  if ! free=$(fm_disk_floor_free_gib "$path") || [ -z "$free" ]; then
    printf 'warning: disk free floor not enforced for %s: cannot read the free space of %s; admitted\n' \
      "$step" "$path" >&2
    fm_disk_floor_event warn "$task" false
    return 0
  fi
  if [ "$free" -lt "$FM_DISK_FLOOR_GIB" ]; then
    printf 'deferred: disk free floor refused %s: %s GiB free on the volume holding %s, below the floor of %s GiB (%s); nothing was started and its backlog item stays queued - free space on that volume, or lower the floor in that file, and start it again\n' \
      "$step" "$free" "$path" "$FM_DISK_FLOOR_GIB" "$FM_DISK_FLOOR_FILE" >&2
    fm_disk_floor_event deny "$task"
    return "$FM_DISK_FLOOR_DEFER_EXIT"
  fi
  fm_disk_floor_event allow "$task"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  case "${1:-}" in
    free)
      [ "$#" -eq 2 ] || { echo 'usage: fm-disk-floor-lib.sh free <path>' >&2; exit 64; }
      fm_disk_floor_free_gib "$2"
      ;;
    floor)
      [ "$#" -le 2 ] || { echo 'usage: fm-disk-floor-lib.sh floor [<config-dir>]' >&2; exit 64; }
      fm_disk_floor_read "${2:-}" || { printf 'error: %s\n' "$FM_DISK_FLOOR_ERROR" >&2; exit 2; }
      printf '%s\n' "$FM_DISK_FLOOR_GIB"
      ;;
    admit)
      [ "$#" -ge 3 ] && [ "$#" -le 5 ] || {
        echo 'usage: fm-disk-floor-lib.sh admit <step> <path> [<config-dir>] [<task-id>]' >&2
        exit 64
      }
      fm_disk_floor_admit "$2" "$3" "${4:-}" "${5:-}"
      ;;
    -h | --help)
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      ;;
    *)
      echo 'usage: fm-disk-floor-lib.sh free|floor|admit ... (--help for the contract)' >&2
      exit 64
      ;;
  esac
fi
