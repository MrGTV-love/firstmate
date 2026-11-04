#!/usr/bin/env bash
# Hand driver: a plain nested copy in its own claimed slot (landed) whose old
# backlog-close marker is a directory, so the moved pending-close clear fails.
# Runs the real <code>/bin/fm-teardown.sh, shows the state after the refusal,
# then replaces the bad marker and reruns.
# Usage: drive-backlog-clear-fail.sh <code-root> <label> <shape plain|enclosing>
set -u
code=$1 label=$2 shape=$3
cd "$code" || exit 2
# shellcheck disable=SC1091
. "$code/tests/fm-teardown-helpers.sh"
nested_fixture "$label" "$shape" mine landed .claude/worktrees/task-x1-v2
c=$NESTED_CASE
mkdir "$c/state/task-x1.backlog-close"
state() {
  echo "  record: $([ -e "$c/state/task-x1.meta" ] && echo present || echo ABSENT)  inbox: $([ -e "$c/state/task-x1.inbox" ] && echo present || echo ABSENT)  status: $([ -e "$c/state/task-x1.status" ] && echo present || echo ABSENT)  tasktmp: $([ -e "$c/tasktmp" ] && echo present || echo ABSENT)  copy: $([ -e "$NESTED_COPY" ] && echo present || echo ABSENT)  claim: $([ -e "$c/pool/1/.fm-slot-owner" ] && echo present || echo ABSENT)"
  echo "  backlog-close: $([ -d "$c/state/task-x1.backlog-close" ] && echo directory || { [ -e "$c/state/task-x1.backlog-close" ] && echo file || echo ABSENT; })"
  echo "  return-pending: $([ -e "$c/state/task-x1.teardown-return-pending" ] && tr '\n' ' ' < "$c/state/task-x1.teardown-return-pending" | sed "s#$c/##g" || echo ABSENT)"
  echo "  pool lease holder: $(sed -n 's/.*"lease_holder":"\([^"]*\)".*/\1/p' "$c/pool/treehouse-state.json")"
  echo "  treehouse calls: $(if [ -s "$c/treehouse.log" ]; then tr '\n' ';' < "$c/treehouse.log" | sed "s#$c/##g"; else echo none; fi)"
  echo "  tmux kill calls: $(if [ -s "$c/endpoint.log" ]; then wc -l < "$c/endpoint.log" | tr -d ' '; else echo 0; fi)"
}
echo "### $label code=$(git -C "$code" rev-parse --short HEAD) shape=$shape (backlog-close marker is a directory)"
echo "BEFORE:"; state
rc=0; nested_run "$c" || rc=$?
echo "RUN 1 -> exit $rc"; grep -E 'REFUSED|error:' "$c/stderr" | sed "s#$c/##g; s/^/  /" | cut -c1-300
echo "AFTER RUN 1:"; state
rmdir "$c/state/task-x1.backlog-close"
rc=0; nested_run "$c" || rc=$?
echo "RUN 2 (bad marker removed) -> exit $rc"; grep -E 'REFUSED|error:' "$c/stderr" | sed "s#$c/##g; s/^/  /" | cut -c1-300
echo "AFTER RUN 2:"; state
echo
