#!/usr/bin/env bash
# Hand driver for the live test step: builds a throwaway world (git project,
# pool slot, claim file, task record, inbox, status, tasktmp, fake treehouse,
# tmux and herdr stand-ins) with the suite's own fixture builders, then runs the
# real <code>/bin/fm-teardown.sh against it and prints what changed.
# Usage: drive-gate-409.sh <code-root> <label> <shape plain|enclosing> <claim mine|other|none> <variant> [--force]
set -u
code=$1 label=$2 shape=$3 claim=$4 variant=$5 force=${6:-}
cd "$code" || exit 2
# shellcheck disable=SC1091
. "$code/tests/fm-teardown-helpers.sh"
nested_fixture "$label" "$shape" "$claim" "$variant" .claude/worktrees/task-x1-v2
configure_flat_herdr_teardown_case "$NESTED_CASE"
: > "$NESTED_CASE/herdr.log"
nested_place_leftovers "$NESTED_CASE"
c=$NESTED_CASE
show() {
  echo "  record (task-x1.meta):  $([ -e "$c/state/task-x1.meta" ] && echo present || echo ABSENT)"
  echo "  inbox dir:              $([ -e "$c/state/task-x1.inbox" ] && echo present || echo ABSENT)"
  echo "  status file:            $([ -e "$c/state/task-x1.status" ] && echo present || echo ABSENT)"
  echo "  tasktmp dir:            $([ -e "$c/tasktmp" ] && echo present || echo ABSENT)"
  echo "  nested copy:            $([ -e "$NESTED_COPY" ] && echo present || echo ABSENT)"
  echo "  slot claim file:        $([ -e "$c/pool/1/.fm-slot-owner" ] && sed 's/^/ /' "$c/pool/1/.fm-slot-owner" | tr '\n' ' ' || echo ABSENT)"
  echo "  backlog-close marker:   $([ -e "$c/state/task-x1.backlog-close" ] && echo "present sha=$(shasum -a 256 < "$c/state/task-x1.backlog-close" | cut -c1-12)" || echo ABSENT)"
  echo "  return-pending marker:  $([ -e "$c/state/task-x1.teardown-return-pending" ] && echo "present: $(tr '\n' ' ' < "$c/state/task-x1.teardown-return-pending")" || echo ABSENT)"
  echo "  treehouse calls:        $(if [ -s "$c/treehouse.log" ]; then tr '\n' ';' < "$c/treehouse.log"; else echo none; fi)"
  echo "  herdr pane closed:      $([ -e "$c/herdr-closed" ] && echo yes || echo no)"
}
echo "### $label  code=$(git -C "$code" rev-parse --short HEAD 2>/dev/null)  shape=$shape claim=$claim variant=$variant ${force:+args=--force --drop-file}"
echo "record lines:"; sed 's/^/  /' "$c/state/task-x1.meta"
echo "slot root HEAD: $(git -C "$NESTED_SLOT" rev-parse HEAD)"
echo "BEFORE:"; show
rc=0
if [ "$force" = --force ]; then nested_run "$c" --force || rc=$?; else nested_run "$c" || rc=$?; fi
echo "RUN: fm-teardown.sh task-x1 ${force:+--force --drop-file <words>}  -> exit $rc"
echo "stderr (REFUSED/error lines):"; grep -E 'REFUSED|error:' "$c/stderr" | sed 's/^/  /' | cut -c1-400
echo "stdout (last 3 lines):"; tail -3 "$c/stdout" | sed 's/^/  /' | cut -c1-300
echo "AFTER:"; show
echo
