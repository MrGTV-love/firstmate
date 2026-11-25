#!/usr/bin/env bash
# Real Herdr lab: a fresh fm-spawn into a named non-default fm-lab-* session
# whose server (and so every pane shell) carries GIT_CONFIG_COUNT=two. The
# staged launch must refuse in the pane, fm-spawn must fail naming the reason,
# close its own pane, and leave no hooks dir, status line or task record.
# Usage: herdr-lab-refusal-driver.sh <firstmate-root>
set -u
ROOT=$1
LAB="$ROOT/bin/fm-herdr-lab.sh"
. "$ROOT/tests/lib.sh"; . "$ROOT/tests/fixtures.sh"
S=$("$LAB" name carrier) || exit 1
echo "lab session: $S"
T=$(fm_test_tmproot fm-herdr-carrier-lab) || exit 1
teardown() {
  echo "-- teardown"
  "$LAB" teardown "$S" && echo "lab $S torn down"
  rm -rf "/tmp/fm-$id" "/tmp/fm-$id+"* 2>/dev/null
  chmod -R u+w "$T" 2>/dev/null; fm_test_cleanup
}
id=carrier-herdrlab-$$
trap teardown EXIT
"$LAB" prepare "$S" >/dev/null || { echo "prepare failed"; exit 1; }
# The pane environment fault, set only on the lab server.
GIT_CONFIG_COUNT=two "$LAB" provision "$S" || { echo "provision failed"; exit 1; }
home=$T/home proj=$T/project wt=$T/wt
fakebin=$(fm_test_make_spawn_fakebin "$T/fake")
fm_test_spawn_home "$home" codex
fm_test_spawn_brief "$home" "$id"
printf 'off\n' > "$home/config/herdr-presentation-spaces"
fm_git_worktree "$proj" "$wt" fixture-herdrlab
echo "-- panes in lab before spawn:"; "$LAB" run "$S" pane list 2>&1 | jq -c '[.result.panes[]? | {pane_id, cwd: .foreground_cwd}]' 2>/dev/null || "$LAB" run "$S" pane list
out=$(HERDR_SESSION="$S" env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u FM_TEST_SEAM -u FM_GIT_HOOKS_VERDICT_POLLS \
  bash -c '. "$1/tests/lib.sh"; . "$1/tests/fixtures.sh"; unset FM_TEST_SEAM FM_GIT_HOOKS_VERDICT_POLLS; shift; fm_test_run_spawn "$@"' _ "$ROOT" \
  "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off --backend herdr --harness codex)
status=$?
echo "-- fm-spawn exit status: $status"
echo "-- fm-spawn output (refusal lines):"; printf '%s\n' "$out" | grep -iE 'refus|error|spawned|verdict|pane' | sed 's/^/  /'
echo "-- panes in lab after spawn:"; "$LAB" run "$S" pane list 2>&1 | jq -c '[.result.panes[]? | {pane_id, cwd: .foreground_cwd}]' 2>/dev/null || "$LAB" run "$S" pane list
echo "-- task hooks dir left: $([ -e "$home/state/$id.git-hooks" ] && echo yes || echo no)"
echo "-- status line left: $([ -e "$home/state/$id.status" ] && echo yes || echo no)"
echo "-- task record left: $([ -e "$home/state/$id.meta" ] && echo yes || echo no)"
