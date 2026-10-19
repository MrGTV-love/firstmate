#!/usr/bin/env bash
# S15: the stale-copy sweep must not remove a copy a held close left.
# Sourced by live-driver.sh, or run alone: bash live-s15.sh
if ! declare -F ck >/dev/null; then
  set -u
  export WT_ROOT=${WT_ROOT:-/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M59XQK2HPSW2PNZ9N2PEKW85}
  export EVID=${EVID:-/Users/charlesabrooker/.no-mistakes/evidence/01M59XQK2HPSW2PNZ9N2PEKW85}
  cd "$WT_ROOT" || exit 1
  . "$EVID/live-lib.sh"
  FAILS=0
  ck() { local label=$1; shift; if "$@" >/dev/null 2>&1; then echo "  PASS  $label"; else echo "  FAIL  $label"; FAILS=$((FAILS + 1)); fi; }
  has() { grep -Fq -- "$2" "$1"; }
  hasnt() { ! grep -Fq -- "$2" "$1"; }
  eq() { [ "$1" = "$2" ]; }
  S15_STANDALONE=1
fi

for shape in unlanded-only unlanded-and-ignored; do
  echo; echo "=== S15 ($shape) ADVERSARIAL: after a held close, the nested-copy sweep (--apply, pointed only at this lab's pool) must not remove the held copy ==="
  lab_new s15 || exit 1
  lab_slot leased && lab_task_work && lab_record
  if [ "$shape" = unlanded-only ]; then lab_foreign x unlanded; else lab_foreign x unlanded ignored; fi
  lab_snapshot "$FOREIGN"
  lab_teardown "$WT_ROOT/bin"
  ck "held close completed (exit 0)" eq "$LAB_RC" 0
  SWEEP_RC=0
  (cd "$WT_ROOT" && env -u FM_GATE_REFUSE_BYPASS -u TMUX FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" \
      FM_COPY_SWEEP_TREEHOUSE_ROOT="$POOL/.treehouse" PATH="$LAB/shim:$PATH" \
      "$WT_ROOT/bin/fm-copy-sweep.sh" --apply > "$LAB/sweep.out" 2>&1) || SWEEP_RC=$?
  printf '\n----- fm-copy-sweep.sh --apply on the lab (exit %s) -----\n' "$SWEEP_RC"; cut -c1-300 "$LAB/sweep.out"
  ck "sweep exit code is 0" eq "$SWEEP_RC" 0
  ck "sweep lists the held copy under a HELD-* class" grep -Eq "^HELD-(DIRTY|UNPUSHED)	.*	$FOREIGN	" "$LAB/sweep.out"
  ck "sweep does not list the held copy as REAPABLE-PROVEN" hasnt "$LAB/sweep.out" "REAPABLE-PROVEN	"
  ck "held copy byte-identical after the sweep" lab_unchanged "$FOREIGN"
  ck "held copy still registered after the sweep" has <(git -C "$PROJECT" worktree list --porcelain) "worktree $FOREIGN"
  ck "sweep removal log has no line for the held copy" hasnt <(cat "$LAB/data/copy-sweep.log" 2>/dev/null) "$FOREIGN"
  lab_destroy
done

if [ "${S15_STANDALONE:-}" = 1 ]; then
  lab_sweep
  echo; echo "TOTAL FAILS: $FAILS"
  exit "$FAILS"
fi
