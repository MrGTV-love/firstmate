#!/usr/bin/env bash
# Round 4 (head 0b8cb40d): targeted suites, same-host interleaved timing against
# base 51c679cf, single-bootstrap A/B, and the arming flake loop.
# Usage: round4-drive.sh <head-worktree> <evidence-dir>
set -u
WT=$1; EV=$2
OLD=/Users/charlesabrooker/.no-mistakes/evidence/01M4H9S3T5T9P3M93GK7BGK4TC
SCR=$(mktemp -d "${TMPDIR:-/tmp}/fm-r4.XXXXXX")
trap 'rm -rf "$SCR"' EXIT
MAIN="$SCR/main"; NOAD="$SCR/noad"; mkdir -p "$MAIN" "$NOAD"
git -C "$WT" archive 51c679cf9d76e3b40799aa758e86eaee071b0dce | tar -x -C "$MAIN"
git -C "$WT" archive HEAD | tar -x -C "$NOAD"; rm -f "$NOAD/bin/fm-procevent-proc.sh"
order="$EV/round4-timing-order.log"; : > "$order"
suite() {  # <label> <root> <script>
  local label=$1 root=$2 script=$3 log="$EV/round4-suite-$1-$(basename "$3" .test.sh).log"
  echo "== $label $(basename "$script") start $(date +%H:%M:%S) $(uptime | sed 's/.*load/load/')" >> "$order"
  (cd "$root" && bin/fm-test-run.sh "$script") > "$log" 2>&1; rc=$?
  dur=$(sed -n 's/^FM_TEST_END .* duration_ms=\([0-9]*\).*/\1/p' "$log" | head -1)
  echo "== $label $(basename "$script") exit=$rc end $(date +%H:%M:%S) duration_ms=$dur" >> "$order"
}
suite head "$WT" tests/fm-proc-guard.test.sh
suite head "$WT" tests/fm-procevent-proc.test.sh
suite head "$WT" tests/fm-extension-binding.test.sh
suite head-a "$WT" tests/fm-bootstrap.test.sh
suite main-a "$MAIN" tests/fm-bootstrap.test.sh
suite head-b "$WT" tests/fm-bootstrap.test.sh
suite main-b "$MAIN" tests/fm-bootstrap.test.sh
suite head "$WT" tests/fm-x-mode.test.sh
suite main "$MAIN" tests/fm-x-mode.test.sh
echo "== single-bootstrap A/B start $(date +%H:%M:%S) $(uptime | sed 's/.*load/load/')" >> "$order"
bash "$OLD/round2-bootstrap-ab-timing.sh" "$WT" "$MAIN" "$NOAD" 15 > "$EV/round4-bootstrap-ab-timing.log" 2>&1
echo "== flake loop start $(date +%H:%M:%S) $(uptime | sed 's/.*load/load/')" >> "$order"
bash "$OLD/round2-bootstrap-arm-flake-loop.sh" "$WT" 120 4 > "$EV/round4-bootstrap-arm-flake-loop.log" 2>&1
echo "== done $(date +%H:%M:%S)" >> "$order"
