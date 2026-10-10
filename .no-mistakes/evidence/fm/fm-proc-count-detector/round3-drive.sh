#!/usr/bin/env bash
# Round 3 (head 261330f4): sequential, same-host measurement and live drives.
# Usage: round3-drive.sh <head-worktree> <evidence-dir>
set -u
WT=$1; EV=$2
SCR=$(mktemp -d "${TMPDIR:-/tmp}/fm-r3.XXXXXX")
trap 'rm -rf "$SCR"' EXIT
MAIN="$SCR/main"; NOAD="$SCR/noad"; mkdir -p "$MAIN" "$NOAD"
git -C "$WT" archive 924f479ca55e4431c77741473f401a61cb8a16b1 | tar -x -C "$MAIN"
git -C "$WT" archive HEAD | tar -x -C "$NOAD"; rm -f "$NOAD/bin/fm-procevent-proc.sh"
order="$EV/round3-timing-order.log"; : > "$order"
suite() {  # <label> <root> <script>
  local label=$1 root=$2 script=$3 log="$EV/round3-timing-$1-$(basename "$3" .test.sh).log"
  echo "== $label start $(date +%H:%M:%S) $(uptime | sed 's/.*load/load/')" >> "$order"
  (cd "$root" && bin/fm-test-run.sh "$script") > "$log" 2>&1; rc=$?
  wait_s=$(sed -n 's/.*got [0-9]* CPU pass(es) for fm-test-run .* after \([0-9]*\)s.*/\1/p' "$log" | head -1)
  dur=$(sed -n 's/^FM_TEST_END .* duration_ms=\([0-9]*\).*/\1/p' "$log" | head -1)
  echo "== $label exit=$rc end $(date +%H:%M:%S) duration_ms=$dur cpu_pass_wait_s=${wait_s:-0}" >> "$order"
}
suite head-a "$WT" tests/fm-bootstrap.test.sh
suite main-a "$MAIN" tests/fm-bootstrap.test.sh
suite head-b "$WT" tests/fm-bootstrap.test.sh
suite main-b "$MAIN" tests/fm-bootstrap.test.sh
suite head-a "$WT" tests/fm-x-mode.test.sh
suite main-a "$MAIN" tests/fm-x-mode.test.sh
suite head "$WT" tests/fm-proc-guard.test.sh
suite head "$WT" tests/fm-procevent-proc.test.sh
echo "== single-bootstrap A/B start $(date +%H:%M:%S) $(uptime | sed 's/.*load/load/')" >> "$order"
bash "$EV/round2-bootstrap-ab-timing.sh" "$WT" "$MAIN" "$NOAD" 15 > "$EV/round3-bootstrap-ab-timing.log" 2>&1
echo "== flake loop start $(date +%H:%M:%S) $(uptime | sed 's/.*load/load/')" >> "$order"
bash "$EV/round2-bootstrap-arm-flake-loop.sh" "$WT" 120 8 > "$EV/round3-bootstrap-arm-flake-loop.log" 2>&1
echo "== live pile drive start $(date +%H:%M:%S) $(uptime | sed 's/.*load/load/')" >> "$order"
bash "$EV/round3-live-pileup-drive.sh" "$WT" > "$EV/round3-live-pileup-drive.log" 2>&1
echo "== done $(date +%H:%M:%S)" >> "$order"
