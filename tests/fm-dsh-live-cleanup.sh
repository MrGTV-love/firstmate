#!/usr/bin/env bash
# The live dsh guard's one cleanup owner. The guarded teardown verifies the
# default-session tripwire AFTER deleting the lab, so any nonzero teardown is
# fatal even when the lab inventory is already gone or unreadable; treating a
# tripwire failure as a warning would hide a changed default session.
# Afterwards it scrubs the DSH credential copies each prepared launch staged in
# the named task-created homes, without reading them or following any link.
fm_dsh_live_cleanup() {  # <result-rc> <session> <helper> <path> [task-home...]
  local rc=$1 session=$2 helper=$3 path=$4
  shift 4
  PATH="$path" "$helper" teardown "$session" || rc=1
  fm_dsh_live_scrub_credentials "$@" || rc=1
  printf 'cleanup_exit=%s\n' "$rc"
  return "$rc"
}
fm_dsh_live_scrub_credentials() {  # <task-home>...
  local home rc=0
  for home in "$@"; do
    [ -n "$home" ] && [ -d "$home/state" ] || continue
    find "$home/state" -path '*.dsh/*/dsh/.credentials.yaml' \( -type f -o -type l \) -exec rm -f {} + || rc=1
  done
  return "$rc"
}
