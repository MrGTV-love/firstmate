#!/usr/bin/env bash
# extract-case.sh <worktree> <out.sh> <case-first-line> <case-last-line>
# Builds a one-case copy of tests/fm-procevent.test.sh: its own header/helpers
# (through runner_pid), QUIET_STUB, PROOF_*, orphan_pe, wait_gone, then the case.
set -eu
wt=$1 out=$2 first=$3 last=$4
src=$wt/tests/fm-procevent.test.sh
{
  sed -n '1,170p' "$src" | sed \
    -e "s#^\. \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh\"#. \"$wt/tests/lib.sh\"#" \
    -e "s#^ROOT=.*#ROOT=$wt#"
  sed -n '5395,5454p' "$src"
  sed -n "${first},${last}p" "$src"
} > "$out"
