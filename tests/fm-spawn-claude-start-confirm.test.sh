#!/usr/bin/env bash
# tests/fm-spawn-claude-start-confirm.test.sh - a claude worker stopped on one
# of Claude's own startup dialogs never reads its brief, and the key plane
# cannot answer any of them, so the spawn must say so instead of leaving the
# launch silent.
#
# The assertions drive the real spawn against a fake pane whose screen the
# suite controls, then read the spawn's exit code, stderr, and the task's
# status events. They never read bin/fm-spawn.sh's source.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-claude-start-confirm)
unset LAVISH_AXI_HOST

# Screens captured from the installed Claude Code 2.1.294 in a scratch config
# (tests/fm-launch-prompt-signals-live-e2e.test.sh refreshes them live).
IMPORTS_SCREEN='  Allow external CLAUDE.md file imports?

  This project'"'"'s CLAUDE.md or .claude/rules imports files outside the current working directory.

  External imports:
    /home/fm/AGENTS.md

  ❯ No, disable external imports
    Yes, allow external imports

  Enter to confirm · Esc to cancel'
TRUST_SCREEN='  Quick safety check: Is this a project you created or one you trust?

  ❯ 1. Yes, I trust this folder
    2. No, exit

  Enter to confirm · Esc to cancel'
BYPASS_SCREEN='  WARNING: Claude Code running in Bypass Permissions mode

  ❯ No, exit
    Yes, I accept

  Enter to confirm · Esc to cancel'
APIKEY_SCREEN='  Detected a custom API key in your environment

  Do you want to use this API key?

    Yes
  ❯ No (recommended)

  Enter to confirm · Esc to cancel'
COMPOSER_SCREEN=' ▐▛███▛█   Claude Code v2.1.294
▝▜██████▀  Opus 5.5 · API Usage Billing

────────────────────────────────────────
❯
────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle)'

# make_case <name> <id> -> sets CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR.
make_case() {
  local name=$1 id=$2
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_spawn_home "$HOME_DIR" claude
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_test_spawn_brief "$HOME_DIR" "$id"
}

# spawn_ship <id> -> runs the spawn; sets SPAWN_OUT and SPAWN_RC.
spawn_ship() {
  SPAWN_OUT=$(FM_CLAUDE_START_POLLS="${FM_CLAUDE_START_POLLS:-6}" \
    FM_FAKE_CAPTURE_FILE="$CASE_DIR/screen" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$1" "$PROJ_DIR" --mode no-mistakes --yolo off)
  SPAWN_RC=$?
}

status_lines() { cat "$HOME_DIR/state/$1.status" 2>/dev/null || true; }

test_a_worker_parked_on_a_startup_dialog_is_reported() {
  local pair name screen id out
  for pair in "imports|$IMPORTS_SCREEN|Allow external CLAUDE.md file imports?" \
    "trust|$TRUST_SCREEN|workspace trust" \
    "bypass|$BYPASS_SCREEN|bypass-permissions confirmation" \
    "apikey|$APIKEY_SCREEN|custom API key choice"; do
    name=${pair%%|*}
    pair=${pair#*|}
    screen=${pair%|*}
    id="parked-$name-z1"
    make_case "parked-$name" "$id"
    printf '%s\n' "$screen" > "$CASE_DIR/screen"
    spawn_ship "$id"
    expect_code 0 "$SPAWN_RC" "a parked launch is reported, not failed: $SPAWN_OUT"
    assert_contains "$SPAWN_OUT" "warning: claude worker $id is stopped on its startup dialog" \
      "the spawn stayed silent about the $name dialog"
    assert_contains "$SPAWN_OUT" "${pair##*|}" "the report does not name the $name dialog"
    out=$(status_lines "$id")
    assert_contains "$out" "blocked [at=" "no blocked status event for the $name dialog: $out"
    assert_contains "$out" "has not begun its instructions" "the status event does not say the brief was not begun"
    assert_contains "$SPAWN_OUT" "spawned $id harness=claude" "a reported worker is still a recorded spawn"
  done
  pass "a claude worker parked on any of its startup dialogs is reported loudly and stays recorded"
}

test_a_worker_with_proof_of_a_started_turn_is_not_reported() {
  local id=started-z1 out
  make_case started "$id"
  printf '%s\n' "$COMPOSER_SCREEN" > "$CASE_DIR/screen"
  # The hook a real worker's UserPromptSubmit fires once its prompt is in.
  FM_FAKE_CAPTURE_HOOK="'$ROOT/bin/fm-busy-event.sh' apply '$HOME_DIR/state' '$id' busy --current-gen --source claude-hook --event UserPromptSubmit" \
    spawn_ship "$id"
  expect_code 0 "$SPAWN_RC" "a started worker spawns cleanly: $SPAWN_OUT"
  case "$SPAWN_OUT" in *"startup dialog"*) fail "a started worker was reported as parked: $SPAWN_OUT" ;; esac
  out=$(status_lines "$id")
  case "$out" in *blocked*) fail "a started worker got a blocked event: $out" ;; esac
  pass "a worker whose turn demonstrably started gets no report"
}

test_a_pane_with_no_dialog_and_no_proof_is_not_reported() {
  local id=quiet-z1 out
  make_case quiet "$id"
  printf '%s\n' "$COMPOSER_SCREEN" > "$CASE_DIR/screen"
  spawn_ship "$id"
  expect_code 0 "$SPAWN_RC" "a quiet pane spawns cleanly: $SPAWN_OUT"
  case "$SPAWN_OUT" in *"startup dialog"*) fail "a dialog-free pane was reported as parked: $SPAWN_OUT" ;; esac
  out=$(status_lines "$id")
  case "$out" in *blocked*) fail "a dialog-free pane got a blocked event: $out" ;; esac
  pass "absence of proof without a dialog is not a fault"
}

# A person who answers the dialog during the window leaves nothing to report.
test_a_dialog_answered_during_the_window_is_not_reported() {
  local id=answered-z1 out counter
  make_case answered "$id"
  printf '%s\n' "$IMPORTS_SCREEN" > "$CASE_DIR/screen"
  printf '%s\n' "$COMPOSER_SCREEN" > "$CASE_DIR/composer"
  counter="$CASE_DIR/captures"
  : > "$counter"
  # The third capture finds the composer where the dialog was.
  FM_FAKE_CAPTURE_HOOK="echo x >> '$counter'; [ \$(wc -l < '$counter') -lt 3 ] || cp '$CASE_DIR/composer' '$CASE_DIR/screen'" \
    FM_CLAUDE_START_POLLS=10 spawn_ship "$id"
  expect_code 0 "$SPAWN_RC" "spawn survives the answered dialog: $SPAWN_OUT"
  case "$SPAWN_OUT" in *"startup dialog"*) fail "an answered dialog was still reported: $SPAWN_OUT" ;; esac
  out=$(status_lines "$id")
  case "$out" in *blocked*) fail "an answered dialog left a blocked event: $out" ;; esac
  pass "a dialog that clears inside the window is not reported"
}

# A pane the spawn cannot read must end the wait at once rather than burn the
# whole window on a screen it can never judge.
test_an_unreadable_pane_does_not_stall_the_spawn() {
  local id=blank-z1 started
  make_case blank "$id"
  rm -f "$CASE_DIR/screen"
  started=$SECONDS
  FM_CLAUDE_START_POLLS=8 FM_CLAUDE_START_POLL_INTERVAL=5 spawn_ship "$id"
  expect_code 0 "$SPAWN_RC" "a blank pane spawns cleanly: $SPAWN_OUT"
  [ $((SECONDS - started)) -lt 20 ] || fail "an unreadable pane stalled the spawn for $((SECONDS - started))s"
  pass "an unreadable pane ends the start wait immediately"
}

test_a_worker_parked_on_a_startup_dialog_is_reported
test_a_worker_with_proof_of_a_started_turn_is_not_reported
test_a_pane_with_no_dialog_and_no_proof_is_not_reported
test_a_dialog_answered_during_the_window_is_not_reported
test_an_unreadable_pane_does_not_stall_the_spawn

echo "# all fm-spawn-claude-start-confirm tests passed"
