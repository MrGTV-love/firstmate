#!/usr/bin/env bash
# The live dsh guard's one cleanup owner. The guarded teardown verifies the
# default-session tripwire AFTER deleting the lab, so any nonzero teardown is
# fatal even when the lab inventory is already gone or unreadable; treating a
# tripwire failure as a warning would hide a changed default session.
fm_dsh_live_cleanup() {  # <result-rc> <session> <helper> <path>
  local rc=$1 session=$2 helper=$3 path=$4
  PATH="$path" "$helper" teardown "$session" || rc=1
  printf 'cleanup_exit=%s\n' "$rc"
  return "$rc"
}
