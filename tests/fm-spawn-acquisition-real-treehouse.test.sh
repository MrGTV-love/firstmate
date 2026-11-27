#!/usr/bin/env bash
# The real-Treehouse case of fm-spawn's acquisition cleanup: a `treehouse get` still in flight when the spawn gives up after
# a pass-over (the spawn passes over a copy it cannot take). Copy A is a real pool slot whose state shows another holder's
# lease, made by the installed treehouse binary; the terminal is the private tmux of tests/fm-spawn-acquisition-helpers.sh.
# The case needs only `get --lease` (and jq), as it did before it moved here; without them the first output line is the
# runner's gate skip and the script exits 0. The acquisition cases that need no Treehouse stay in tests/fm-spawn-acquisition-cleanup.test.sh.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_test_require_real_treehouse get-lease
BACKEND=tmux
command -v "$BACKEND" >/dev/null 2>&1 || { echo "skip: $BACKEND not found"; exit 0; }
# shellcheck source=tests/fm-spawn-acquisition-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-spawn-acquisition-helpers.sh"

# A get still running when the spawn gives up after a pass-over. The first get enters copy A, a real pool slot whose state
# shows another holder's lease, so the spawn passes it over and keeps the pane open; the second get, for copy B, makes no
# progress and the no-progress limit ends the spawn. That get must be interrupted and gone from the process table, B never
# entered, A byte-identical with its lease, and the pane still open with A's shell and the get that opened it alive.
# run_passover_inflight_case <label> <bash-env> [stubborn]: the spawn runs with <bash-env> as BASH_ENV, so the control can
# inject a fault. With stubborn the second get ignores the interrupt: the abort must then say plainly that the pane is not
# settled, record that, and still leave the pane and copy A as they are; the case ends that get by its own pid.
passover_copy_digest() { # <copy> <state-file>
  (
    set -o pipefail
    git -C "$1" rev-parse HEAD || exit 1
    git -C "$1" status --porcelain=v1 --untracked-files=all --ignored || exit 1
    find "$1" -path "$1/.git" -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done || exit 1
    shasum -a 256 "$2" || exit 1
  )
}
run_passover_inflight_case() {
  local label=$1 bash_env=$2 kind=${3:-cancellable} id case th_root a_copy b_copy state before after wid rc get2 row ignore=0
  [ "$kind" != stubborn ] || ignore=1
  id="get-cleanup-$label-$$"
  case="$TMP_ROOT/case-$label"
  th_root="$case/th-root"
  b_copy="$TMP_ROOT/$label-copy-b"
  mkdir -p "$case"
  fm_git_init_commit "$b_copy"
  a_copy=$(cd "$PROJECT" && TREEHOUSE_ROOT="$th_root" "$REAL_TREEHOUSE" get --lease --lease-holder other-holder 2>/dev/null </dev/null | tail -n 1) \
    || fail "$label: the real treehouse made no pool slot"
  a_copy=$(CDPATH='' cd -- "$a_copy" && pwd -P) || fail "$label: the pool slot cannot be resolved"
  state="$(dirname "$(dirname "$a_copy")")/treehouse-state.json"
  [ "$(jq -r --arg p "$a_copy" '[.worktrees[] | select(.path == $p) | .lease_holder] | join(",")' "$state")" = other-holder ] \
    || fail "$label: copy A does not carry the other holder's lease in the pool state"
  before=$(passover_copy_digest "$a_copy" "$state") || fail "$label: copy A could not be read before the spawn"
  : > "$case/ticks"
  printf 'MODE=passover\nLEASE=%q\nPIDFILE=%q\nALLOW=%q\nARRIVED=%q\nDEST=%q\nTICKS=%q\nPASSED=%q\nFIRSTPID=%q\nASHELL=%q\nIGNORE_INT=%q\n' \
    "$case/lease" "$case/pid" "$case/allow" "$case/arrived" "$b_copy" "$case/ticks" "$a_copy" "$case/first-pid" "$case/a-shell" "$ignore" \
    > "$TMP_ROOT/get-config"
  fm_test_spawn_brief "$FM_HOME" "$id" 'A get in flight after a pass-over must not outlive the refused spawn.'
  out=$(FM_ROOT_OVERRIDE='' FM_SPAWN_NO_GUARD=1 CLAUDE_CONFIG_DIR="$case/claude" PATH="$FAKEBIN:$PATH" \
    FM_TEST_TICK_FILE="$case/ticks" FM_TEST_TICK_SECONDS=60 FM_TEST_TICK_GATE="$case/pid" FM_TEST_REAL_CLEANUP_SLEEP=1 \
    BASH_ENV="$bash_env" \
    bash "$ROOT/bin/fm-spawn.sh" "$id" "$PROJECT" --backend tmux --harness codex --allow-api-key --mode no-mistakes --yolo off 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "$label: the spawn launched although its only clean copy never arrived: $out"
  assert_contains "$out" "skipped: copy $a_copy already carries another holder's lease" "$label: copy A was not passed over"
  assert_contains "$out" 'no path or output progress for 600s' "$label: the second get was not ended by the no-progress limit"
  [ -s "$case/pid" ] || fail "$label: the second get never started: $out"
  get2=$(cat "$case/pid")
  if [ "$kind" = stubborn ]; then
    kill -0 "$get2" 2>/dev/null || fail "$label: the second get did not survive the interrupt, so the case is vacuous: $out"
    assert_contains "$out" 'is not settled' "$label: an abort whose get survived was not reported as not settled"
    assert_contains "$out" 'this abort is not clean' "$label: an abort whose get survived was not called unclean"
    assert_not_contains "$out" 'notice: acquisition pane' "$label: an abort whose get survived was reported as settled"
  fi
  wid=$("$REAL_TMUX" list-windows -a -F '#{window_id} #{window_name}' | awk -v n="fm-$id" '$2 == n { print $1 }')
  [ -n "$wid" ] || fail "$label: the spawn closed the acquisition pane while it still held copy A"
  if [ "$kind" = stubborn ]; then
    grep -q "^$wid"$'\t'"get-not-cancelled"$'\t' "$FM_HOME/data/$id/acquisition-pane.tsv" \
      || fail "$label: the surviving get was not recorded against pane $wid: $(cat "$FM_HOME/data/$id/acquisition-pane.tsv" 2>&1)"
    after=$(passover_copy_digest "$a_copy" "$state") || fail "$label: copy A could not be read after the spawn"
    [ "$after" = "$before" ] || fail "$label: copy A or its pool state changed"
    kill -0 "$(cat "$case/a-shell")" 2>/dev/null || fail "$label: copy A's subshell is gone"
    # The case owns this get: end it by its own pid, then let nothing more reach copy B.
    kill -TERM "$get2" 2>/dev/null || true
    for _ in $(seq 1 250); do kill -0 "$get2" 2>/dev/null || break; /bin/sleep 0.02; done
    ! kill -0 "$get2" 2>/dev/null || fail "$label: the case could not end its own surviving get $get2"
    [ ! -e "$case/arrived" ] || fail "$label: the surviving get entered copy B"
    return 0
  fi
  # The process table, not the spawn's exit status, says whether the second get survived the refusal.
  ! kill -0 "$get2" 2>/dev/null || fail "$label: the spawn left the second treehouse get (pid $get2) running after it refused: $out"
  touch "$case/allow"
  for _ in $(seq 1 100); do /bin/sleep 0.02; done
  [ ! -e "$case/lease" ] || fail "$label: the second get still holds its process lease after the refusal"
  [ ! -e "$case/arrived" ] || fail "$label: the second get entered copy B after the spawn refused"
  [ ! -f "$FM_HOME/state/$id.meta" ] || fail "$label: a refused spawn published task metadata"
  after=$(passover_copy_digest "$a_copy" "$state") || fail "$label: copy A could not be read after the spawn"
  [ "$after" = "$before" ] || fail "$label: copy A or its pool state changed"$'\n'"$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -20)"
  kill -0 "$(cat "$case/first-pid")" 2>/dev/null || fail "$label: the get that opened copy A's subshell is gone"
  kill -0 "$(cat "$case/a-shell")" 2>/dev/null || fail "$label: copy A's subshell is gone"
  [ "$(CDPATH='' cd -- "$("$REAL_TMUX" display-message -p -t "$wid" '#{pane_current_path}')" && pwd -P)" = "$a_copy" ] \
    || fail "$label: the pane does not rest in copy A after the interrupt"
  row=$(grep -F "$a_copy"$'\t' "$FM_HOME/data/$id/skipped-copies.tsv") || fail "$label: copy A was not recorded"
  [ "${row##*$'\t'}" = "$wid" ] || fail "$label: the record of copy A does not name the acquisition pane $wid: $row"
  grep -q "^$wid"$'\t'"get-cancelled"$'\t' "$FM_HOME/data/$id/acquisition-pane.tsv" \
    || fail "$label: the acquisition pane was not recorded as settled: $(cat "$FM_HOME/data/$id/acquisition-pane.tsv" 2>&1)"
  assert_not_contains "$out" 'is not settled' "$label: a settled pane was reported as not settled"
}
REAL_TREEHOUSE=$(command -v treehouse 2>/dev/null || true)
run_passover_inflight_case passover "$TMP_ROOT/clock.sh"
pass 'tmux an abort after a pass-over interrupts the in-flight get, keeps the pane in the passed-over copy and leaves that copy untouched'
# The control restores the earlier abort for this case only: at the start of the abort cleanup it forgets the pane
# (no close and no interrupt), so the case must fail on the surviving get.
cat > "$TMP_ROOT/passover-mutant.sh" <<SH
. '$TMP_ROOT/clock.sh'
set -T
__fm_passover_mutant() {
  case "\$BASH_COMMAND" in
    'local status=\$? skill_meta_tmp') SPAWN_PASSED_OVER_PANE= ;;
  esac
  return 0
}
trap '__fm_passover_mutant' DEBUG
SH
rc=0
out=$( (run_passover_inflight_case passover-control "$TMP_ROOT/passover-mutant.sh") 2>&1 ) || rc=$?
[ "$rc" -ne 0 ] || fail 'the pass-over in-flight case passed with a spawn that leaves the second get running'
assert_contains "$out" 'the spawn left the second treehouse get' 'the control failed for another reason than the surviving get'
pass 'tmux the pass-over in-flight case rejects an abort that leaves the second get running'
run_passover_inflight_case passover-stubborn "$TMP_ROOT/clock.sh" stubborn
pass 'tmux an abort after a pass-over whose get survives the interrupt says the pane is not settled and records it'
