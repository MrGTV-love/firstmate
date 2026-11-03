#!/usr/bin/env bash
# Live driver: runs the real bin/fm-teardown.sh (head, or a base tree given as
# $1) against throwaway worlds built by the suite's fixture builders, and prints
# a transcript of what each run did. Usage:
#   bash drive-nested-teardown.sh <worktree> [<code-tree-to-run>]
set -u
WORKTREE=$1
RUN_TREE=${2:-$1}
. "$WORKTREE/tests/fm-teardown-helpers.sh"
# Run the chosen tree's teardown (the fixture's code-root/bin is linked to ROOT).
ROOT=$RUN_TREE
TEARDOWN="$ROOT/bin/fm-teardown.sh"
gate_409_case() {
  nested_fixture "gate-409-$1" plain mine "$1" .claude/worktrees/task-x1-v2
  configure_flat_herdr_teardown_case "$NESTED_CASE"
  : > "$NESTED_CASE/herdr.log"
  nested_place_leftovers "$NESTED_CASE"
}

show_case() {  # <title> <case> <rc> <before>
  local title=$1 c=$2 rc=$3 before=$4
  echo "=== $title"
  echo "teardown code: $TEARDOWN"
  echo "exit: $rc"
  echo "observed: $(nested_observe "$c" "$rc")"
  echo "--- stderr (last 6 lines)"; tail -6 "$c/stderr"
  echo "--- stdout (last 4 lines)"; tail -4 "$c/stdout"
  echo "--- treehouse.log"; cat "$c/treehouse.log" 2>/dev/null || echo "(none: no treehouse return)"
  echo "--- endpoint close calls"; cat "$c/endpoint.log" 2>/dev/null || echo "(no tmux kill)"
  [ -e "$c/herdr-closed" ] && echo "herdr pane closed: yes" || echo "herdr pane closed: no"
  echo "--- state/ after"; (cd "$c/state" && ls -1A | grep -v '\.lock$' | grep -v '^\.') || true
  [ ! -f "$c/state/task-x1.teardown-return-pending" ] || { echo "--- return-pending content"; cat "$c/state/task-x1.teardown-return-pending"; }
  if [ -n "$before" ]; then
    nested_snapshot "$c" "$c/snapshot.after"
    if diff -u "$before" "$c/snapshot.after" > "$c/snapshot.diff"; then
      echo "--- snapshot before vs after: IDENTICAL ($(wc -l < "$before" | tr -d ' ') entries: record, inbox, status, tasktmp, markers, copy, slot, refs, claim, pool state, endpoint calls)"
    else
      echo "--- snapshot before vs after: CHANGED"; cat "$c/snapshot.diff"
    fi
  fi
  echo
}

# S-A: gate-409 recorded case, landed, --force --drop-file.
gate_409_case landed; c=$NESTED_CASE
echo "--- gate-409 leftovers placed before run:"; cat "$c/state/task-x1.backlog-close"; cat "$c/state/task-x1.teardown-return-pending"; grep -c prior_worktree "$c/state/task-x1.meta" | sed 's/^/prior_worktree lines in record: /'
rc=0; nested_run "$c" --force || rc=$?
show_case "gate-409 recorded case, slot and copy landed, --force --drop-file" "$c" "$rc" ""

# S-B: gate-409 recorded case, slot root unlanded.
gate_409_case slot-unlanded; c=$NESTED_CASE
nested_snapshot "$c" "$c/snapshot.before"; echo "slot root HEAD: $(git -C "$NESTED_SLOT" rev-parse HEAD)"
rc=0; nested_run "$c" --force || rc=$?
show_case "gate-409 recorded case, slot root HEAD unlanded, --force --drop-file" "$c" "$rc" "$c/snapshot.before"

# S-C: plain shape, own claim, landed, plain teardown (no --force).
nested_fixture plain-landed plain mine landed; c=$NESTED_CASE
rc=0; nested_run "$c" || rc=$?
show_case "plain record, own claim, landed, no --force" "$c" "$rc" ""

# S-D: plain shape, copy dirty: entry refusal changes nothing.
nested_fixture plain-dirty plain mine copy-dirty; c=$NESTED_CASE
nested_snapshot "$c" "$c/snapshot.before"
rc=0; nested_run "$c" || rc=$?
show_case "plain record, own claim, nested copy has an uncommitted change" "$c" "$rc" "$c/snapshot.before"

# S-E: plain vs prior shape on claim other / none / own: the slot is touched only for an own claim.
for claim in other none mine; do
  for shape in plain enclosing; do
    nested_fixture "pair-$claim-$shape" "$shape" "$claim" landed; c=$NESTED_CASE
    rc=0; nested_run "$c" || rc=$?
    printf 'claim=%-5s shape=%-9s %s\n' "$claim" "$shape" "$(nested_observe "$c" "$rc")"
  done
done
echo
