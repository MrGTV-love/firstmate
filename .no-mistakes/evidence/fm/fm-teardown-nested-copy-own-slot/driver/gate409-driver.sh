#!/usr/bin/env bash
# Drives the real bin/fm-teardown.sh against disposable worlds built by the
# suite's own fixture helpers (fake treehouse/tmux/herdr, temp git repos).
# Usage: bash gate409-driver.sh <worktree-root> <label>
set -u
WT_ROOT=$1 LABEL=$2
cd "$WT_ROOT" || exit 2
. tests/fm-teardown-helpers.sh

listing() {  # <case-dir>
  local c=$1
  echo "  state/:"; (cd "$c/state" && ls -1A | sed 's/^/    /')
  echo "  nested copy present: $([ -e "$NESTED_COPY" ] && echo yes || echo no)"
  echo "  slot claim present:  $([ -e "$c/pool/1/.fm-slot-owner" ] && echo yes || echo no)"
  echo "  tasktmp present:     $([ -e "$c/tasktmp" ] && echo yes || echo no)"
  echo "  treehouse calls:     $(cat "$c/treehouse.log" 2>/dev/null | tr '\n' ';' || true)"
  echo "  herdr pane closed:   $([ -e "$c/herdr-closed" ] && echo yes || echo no)"
}

show_case() {  # <title> <case-dir> <force|normal>
  local title=$1 c=$2 mode=$3 rc=0
  echo "=================================================================="
  echo "[$LABEL] $title"
  echo "------------------------------------------------------------------"
  echo "record (state/task-x1.meta):"; sed 's/^/    /' "$c/state/task-x1.meta"
  [ ! -e "$c/state/task-x1.teardown-return-pending" ] || { echo "leftover teardown-return-pending:"; sed 's/^/    /' "$c/state/task-x1.teardown-return-pending"; }
  echo "BEFORE:"; listing "$c"
  nested_snapshot "$c" "$c/snap.before"
  if [ "$mode" = force ]; then
    echo "\$ fm-teardown.sh task-x1 --force --drop-file <captain-words>"
    nested_run "$c" --force || rc=$?
  else
    echo "\$ fm-teardown.sh task-x1"
    nested_run "$c" || rc=$?
  fi
  echo "exit=$rc"
  echo "stderr (REFUSED/teardown lines):"; grep -E 'REFUSED|refus|slot|lease' "$c/stderr" | head -8 | sed 's/^/    /'
  echo "stdout (last 4 lines):"; tail -4 "$c/stdout" | sed 's/^/    /'
  echo "AFTER:"; listing "$c"
  nested_snapshot "$c" "$c/snap.after"
  if cmp -s "$c/snap.before" "$c/snap.after"; then echo "snapshot: UNCHANGED (sha256 of record, inbox, status, tasktmp, markers, copy, slot, claim, pool state, endpoint logs)"; else echo "snapshot: CHANGED"; fi
  echo "observe: $(nested_observe "$c" "$rc")"
}

# Scenario A/B: the recorded gate-409 shape (herdr, plain record, own claim,
# leftover backlog-close + teardown-return-pending with empty slot=).
for variant in landed slot-unlanded; do
  nested_fixture "drv-gate409-$variant" plain mine "$variant"
  configure_flat_herdr_teardown_case "$NESTED_CASE"
  : > "$NESTED_CASE/herdr.log"
  nested_place_leftovers "$NESTED_CASE"
  show_case "gate-409 recorded shape, $variant, --force --drop-file" "$NESTED_CASE" force
done

# Scenario C: plain vs prior shape, claim names another task / no claim.
for claim in other none; do
  for shape in enclosing plain; do
    nested_fixture "drv-claim-$claim-$shape" "$shape" "$claim" landed
    show_case "claim=$claim shape=$shape (enclosing=prior_worktree line, plain=none), landed" "$NESTED_CASE" normal
  done
done
