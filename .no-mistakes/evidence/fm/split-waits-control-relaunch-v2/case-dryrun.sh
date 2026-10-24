#!/usr/bin/env bash
# Usage: CASE_LOG=<file> case-dryrun.sh <suite.test.sh>
# Sources the real suite with an extdebug DEBUG trap. Each case the suite's own
# dispatch reaches (a top-level test_* call, or control_relaunch_run's
# "$test_case" call) is logged and skipped, so the run lists what would execute.
shopt -s extdebug
set -T
__case_dryrun() {
  local cmd=$BASH_COMMAND caller=${FUNCNAME[1]-}
  if [[ $caller == control_relaunch_run && $cmd == '"$test_case"' ]]; then
    printf '%s\t%s:%s\n' "$test_case" loop "$((++__case_n))" >>"$CASE_LOG"; return 1
  fi
  if [[ $caller == source || $caller == main || -z $caller ]] && [[ $cmd =~ ^test_[A-Za-z0-9_]+$ ]]; then
    printf '%s\t%s:%s\n' "$cmd" "${BASH_SOURCE[1]##*/}" "${BASH_LINENO[0]}" >>"$CASE_LOG"; return 1
  fi
  return 0
}
__case_n=0
trap __case_dryrun DEBUG
suite=$1; shift; . "$suite"
