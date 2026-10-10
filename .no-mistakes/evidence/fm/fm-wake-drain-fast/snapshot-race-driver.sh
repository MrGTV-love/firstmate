#!/bin/bash
# snapshot-race-driver.sh <code-root>
# Live, in a disposable marked lab home, with the REAL drain:
#  1. Prime: drain once so the bootstrap note is presented.
#  2. Append note A, then run the real drain with a timing seam that appends
#     note B right after the presentation snapshot is taken (same seam as
#     tests/fm-wake-drain-unread-status.test.sh test_snapshot_does_not_ack_a_later_append).
#     Expect: drain 1 shows A, not B.
#  3. Run the plain real drain again. Expect: B shown exactly once, A not replayed.
#  4. Run again. Expect: nothing replayed.
#  5. Call the retained helpers scan_unread_surface_lines / scan_unread_surface_snapshot
#     (de-batched by HEAD) on the same home to show they still return rows.
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux"
trap 'rm -rf "$LAB"' EXIT
ENVV=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX -u TMUX_PANE
  FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux")
S="$LAB/state/race.status"
step() { printf '\n=== %s ===\n' "$1"; }
fail=0
expect_has() { case "$1" in *"$2"*) echo "CHECK ok: contains '$2'";; *) echo "CHECK FAIL: missing '$2'"; fail=1;; esac; }
expect_not() { case "$1" in *"$2"*) echo "CHECK FAIL: unexpected '$2'"; fail=1;; *) echo "CHECK ok: does not contain '$2'";; esac; }

step "prime: present bootstrap note"
printf 'note: bootstrap line\n' > "$S"
out=$("${ENVV[@]}" /bin/bash "$ROOT/bin/fm-wake-drain.sh" 2>&1); echo "$out"
expect_has "$out" "bootstrap line"

step "drain 1: note A present; note B appended after the presentation snapshot (inside the drain)"
printf 'note: A included in presentation snapshot\n' >> "$S"
out=$("${ENVV[@]}" FM_RACE_STATUS="$S" /bin/bash -c '
  read() {
    local __f
    if [ ! -e "$FM_RACE_STATUS.appended" ] && [ "${FUNCNAME[1]:-}" = _fm_status_stat_raw ]; then
      for __f in "${FUNCNAME[@]}"; do
        if [ "$__f" = status_presentation_snapshot ]; then
          printf "note: B appended after presentation snapshot\n" >> "$FM_RACE_STATUS"
          : > "$FM_RACE_STATUS.appended"; break
        fi
      done
    fi
    builtin read "$@"
  }
  drain=$1; shift
  . "$drain"
' _ "$ROOT/bin/fm-wake-drain.sh" 2>&1); echo "$out"
[ -e "$S.appended" ] && echo "CHECK ok: B was appended inside the drain, after the snapshot" || { echo "CHECK FAIL: seam not reached"; fail=1; }
rm -f "$S.appended"
expect_has "$out" "A included in presentation snapshot"
expect_not "$out" "B appended after presentation snapshot"

step "drain 2: plain real drain"
out=$("${ENVV[@]}" /bin/bash "$ROOT/bin/fm-wake-drain.sh" 2>&1); echo "$out"
expect_has "$out" "B appended after presentation snapshot"
expect_not "$out" "A included in presentation snapshot"
[ "$(printf '%s\n' "$out" | grep -c 'B appended')" = 1 ] && echo "CHECK ok: B shown exactly once" || { echo "CHECK FAIL: B count"; fail=1; }

step "drain 3: nothing replayed"
out=$("${ENVV[@]}" /bin/bash "$ROOT/bin/fm-wake-drain.sh" 2>&1); echo "[$out]"
expect_not "$out" "B appended"
expect_not "$out" "A included"

step "retained helpers still work after de-batching"
printf 'note: C for helper check\n' >> "$S"
out=$("${ENVV[@]}" /bin/bash -c '
  . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-classify-lib.sh"
  state="$FM_HOME/state"
  echo "lines:"; scan_unread_surface_lines "$state"
  snap=$(status_presentation_snapshot "$state")
  echo "snapshot:"; scan_unread_surface_snapshot "$state" "$snap"
' _ "$ROOT" 2>&1); echo "$out"
[ "$(printf '%s\n' "$out" | grep -c 'C for helper check')" = 2 ] && echo "CHECK ok: both helpers return the unread row" || { echo "CHECK FAIL: helper rows"; fail=1; }

step "result"
[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
