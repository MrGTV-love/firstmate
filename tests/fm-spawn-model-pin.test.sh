#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's stale-model launch gate.
#
# A model that a newer model of its own family and tier has passed in the
# harness's own catalog refuses the launch; only --captain-model-pin naming that
# exact model admits it, and a pin for any other model cannot launder a stale
# one. A batch forwards its one pin to every pair, and a --relaunch or a
# secondmate respawn of the model the task already records is not gated again,
# while any other model on those paths still is.
# The assertions never read bin/fm-spawn.sh: each case drives the real spawn
# against a fake pane and a real isolated git worktree, then checks the exit code
# and the message it printed.
#
# Environment. This suite models an omp worker, so the fakebin shadows `omp`
# with a hermetic stub that serves a fixture `omp models --json` listing, answers
# `--version` and `usage`, and exits 0 for anything else. No real omp binary or
# model catalog is read. tests/lib.sh turns model freshness off globally (so no
# spawn suite reaches a live catalog), so this file turns it back on.
#
# No workspace-specific PATH or TMPDIR shim is required: the harness probes `ps`
# and mktemp normally here. If a sandbox denies `ps`, put a shim that prints
# `shim-<pid>` for `-o lstart=` calls ahead of PATH and point TMPDIR at a
# writable directory; nothing in this file depends on the shim.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-model-pin)

# tests/lib.sh exports FM_MODEL_FRESHNESS=0 for every suite; this file is about
# the launch gate itself, so re-enable the check.
export FM_MODEL_FRESHNESS=1

# One family, four models: NEWER (6.0) has passed STALE (5.6) and OTHER_STALE
# (5.8) in the same luna tier, so both are stale; CURRENT (6.1) is the newest in
# the family, so it is current. A catalog that lists STALE alone has nothing
# newer, so STALE is current there until the catalog gains NEWER.
STALE_MODEL=openai-codex/gpt-5.6-luna
OTHER_STALE_MODEL=openai-codex/gpt-5.8-luna
NEWER_MODEL=openai-codex/gpt-6-luna
CURRENT_MODEL=openai-codex/gpt-6.1-sol
ONLY_STALE_LISTING='{"models":[{"provider":"openai-codex","id":"gpt-5.6-luna","selector":"openai-codex/gpt-5.6-luna"}]}'
FULL_LISTING='{"models":[{"provider":"openai-codex","id":"gpt-5.6-luna","selector":"openai-codex/gpt-5.6-luna"},{"provider":"openai-codex","id":"gpt-5.8-luna","selector":"openai-codex/gpt-5.8-luna"},{"provider":"openai-codex","id":"gpt-6-luna","selector":"openai-codex/gpt-6-luna"},{"provider":"openai-codex","id":"gpt-6.1-sol","selector":"openai-codex/gpt-6.1-sol"}]}'

# install_omp_fake <fakebin> <listing-file>
# `omp models --json` comes from the fixture listing, `--version` reports a
# version above fm-spawn's omp floor, and `usage` reports an unknown quota (the
# spawn's capacity probe accepts that). Anything else exits 0 without output.
install_omp_fake() {
  local fakebin=$1 listing=$2
  cat > "$fakebin/omp" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  --version) printf 'omp/18.1.20\n' ;;
  models) cat '$listing' ;;
  usage) printf '{}\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/omp"
}

# make_case <name> <id>: builds an isolated home, project worktree, brief, and
# fakebin for one spawn and records the paths in CASE_* globals.
make_case() {
  local name=$1 id=$2
  CASE_DIR="$TMP_ROOT/$name"
  CASE_ID=$id
  CASE_HOME="$CASE_DIR/home"
  CASE_PROJ="$CASE_DIR/project"
  CASE_WT="$CASE_DIR/wt"
  CASE_LAUNCH_LOG="$CASE_DIR/launch.log"
  mkdir -p "$CASE_DIR"
  CASE_FAKE=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_spawn_home "$CASE_HOME" omp
  fm_git_worktree "$CASE_PROJ" "$CASE_WT" "wt-$name"
  fm_test_spawn_brief "$CASE_HOME" "$id"
  case "$name" in
    current) printf '%s\n' '{"models":[{"provider":"openai-codex","id":"gpt-6.1-sol","selector":"openai-codex/gpt-6.1-sol"},{"provider":"openai-codex","id":"gpt-6-luna","selector":"openai-codex/gpt-6-luna"}]}' > "$CASE_DIR/omp-models.json" ;;
    aging) printf '%s\n' "$ONLY_STALE_LISTING" > "$CASE_DIR/omp-models.json" ;;
    *) printf '%s\n' "$FULL_LISTING" > "$CASE_DIR/omp-models.json" ;;
  esac
  install_omp_fake "$CASE_FAKE" "$CASE_DIR/omp-models.json"
}

# run_case_spawn [fm-spawn args...]: drives the real spawn for the current case.
run_case_spawn() {
  : > "$CASE_LAUNCH_LOG"
  FM_FAKE_LAUNCH_LOG="$CASE_LAUNCH_LOG" \
    fm_test_run_spawn "$CASE_HOME" "$CASE_WT" "$CASE_FAKE" "$CASE_ID" "$CASE_PROJ" \
    --mode no-mistakes --yolo off "$@"
}

# Test 1: a stale model with no pin refuses the launch and names the newer one.
test_stale_model_refused_without_pin() {
  local out status
  make_case refuse-stale refuse-stale-a1
  out=$(run_case_spawn --model "$STALE_MODEL" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a stale model must refuse the launch without a pin"$'\n'"$out"
  assert_contains "$out" "refusing to launch a stale model" \
    "the refusal must say it refused a stale model"
  assert_contains "$out" "$NEWER_MODEL" \
    "the refusal must name the newer model that passed it"
  [ ! -s "$CASE_LAUNCH_LOG" ] || fail "a refused stale launch must not reach the pane"
  assert_absent "$CASE_HOME/state/refuse-stale-a1.meta" \
    "a refused stale launch must leave no task record"
  pass "a stale model without a pin is refused and the newer model is named"
}

# Test 2: the same stale model launches when the captain pin names it.
test_captain_pin_admits_that_model() {
  local out status meta
  make_case admit-by-pin admit-by-pin-a1
  out=$(run_case_spawn --model "$STALE_MODEL" --captain-model-pin "$STALE_MODEL" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "a captain pin naming the stale model must admit the launch"$'\n'"$out"
  assert_contains "$out" "warning: stale model admitted by captain pin - $STALE_MODEL on omp is older than $NEWER_MODEL in the omp catalog" \
    "the admitted launch must announce the captain pin and the stale line"
  meta="$CASE_HOME/state/admit-by-pin-a1.meta"
  [ -f "$meta" ] || fail "an admitted stale launch must publish a task record"
  assert_grep 'model_stale=openai-codex/gpt-5.6-luna on omp is older than openai-codex/gpt-6-luna in the omp catalog (admitted by captain pin)' \
    "$meta" "the task record must mark the stale model as captain-authorized"
  pass "a captain pin naming the stale model admits the launch"
}

# Test 3: a pin for a different (current) model cannot admit the stale launch.
test_pin_for_another_model_refused() {
  local out status
  make_case pin-mismatch pin-mismatch-a1
  out=$(run_case_spawn --model "$STALE_MODEL" --captain-model-pin "$CURRENT_MODEL" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a pin for a different model must not admit a stale launch"$'\n'"$out"
  assert_contains "$out" "is not the requested model" \
    "the refusal must say the pin names a different model"
  assert_contains "$out" "refusing to launch a stale model" \
    "the mismatched pin must still refuse the stale model"
  [ ! -s "$CASE_LAUNCH_LOG" ] || fail "a mismatched-pin refusal must not reach the pane"
  pass "a pin naming another model cannot admit a stale launch"
}

# Test 4: a current model launches and never draws the stale warning.
test_current_model_launches_without_pin() {
  local out status
  make_case current current-a1
  out=$(run_case_spawn --model "$CURRENT_MODEL" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "a current model must launch without a pin"$'\n'"$out"
  assert_contains "$out" "spawned current-a1" "the current model must be launched"
  assert_not_contains "$out" "refusing to launch a stale model" \
    "a current model must not be refused"
  assert_not_contains "$out" "admitted by captain pin" \
    "a current model must not need a captain pin"
  assert_no_grep 'model_stale=' "$CASE_HOME/state/current-a1.meta" \
    "a current model must leave no stale record"
  pass "a current model launches without a pin and without a stale warning"
}

# run_case_relaunch [fm-spawn args...]: relaunches the case's published task. The
# recorded window is listed and its pane runs an idle shell, which is the
# positively agent-free endpoint a relaunch requires.
run_case_relaunch() {
  local bin="$CASE_FAKE/relaunch-shell"
  mkdir -p "$bin"
  cat > "$bin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *pane_current_command*) printf 'zsh\\n'; exit 0 ;;
esac
exec "$CASE_FAKE/tmux" "\$@"
SH
  chmod +x "$bin/tmux"
  : > "$CASE_LAUNCH_LOG"
  FM_FAKE_DUPLICATE_WINDOW="$(sed -n 's/^window=[^:]*://p' "$CASE_HOME/state/$CASE_ID.meta")" \
    FM_FAKE_LAUNCH_LOG="$CASE_LAUNCH_LOG" \
    fm_test_run_spawn "$CASE_HOME" "$CASE_WT" "$bin:$CASE_FAKE" "$CASE_ID" --relaunch "$@"
}

# Test 5: a batch forwards its one pin to every pair, so a pinned stale model
# launches for each id instead of every pair refusing and asking for a pin the
# caller already passed.
test_batch_forwards_the_pin_to_every_pair() {
  local out status
  make_case batch-pin batch-pin-a1
  fm_test_spawn_brief "$CASE_HOME" batch-pin-b2
  : > "$CASE_LAUNCH_LOG"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE_LAUNCH_LOG" fm_test_run_spawn "$CASE_HOME" "$CASE_WT" "$CASE_FAKE" \
    batch-pin-a1="$CASE_PROJ" batch-pin-b2="$CASE_PROJ" \
    --mode no-mistakes --yolo off --model "$STALE_MODEL" --captain-model-pin "$STALE_MODEL")
  status=$?
  [ "$status" -eq 0 ] || fail "a batch with a pin naming its stale model must launch every pair"$'\n'"$out"
  assert_not_contains "$out" "refusing to launch a stale model" \
    "a batch pin must reach every pair"
  assert_contains "$(grep '^model_stale=' "$CASE_HOME/state/batch-pin-a1.meta")" "(admitted by captain pin)" \
    "the first pair's record must carry the captain-pin marker"
  assert_contains "$(grep '^model_stale=' "$CASE_HOME/state/batch-pin-b2.meta")" "(admitted by captain pin)" \
    "the second pair's record must carry the captain-pin marker"
  pass "a batch forwards its one captain pin to every pair"
}

# Test 6: a relaunch of the task's recorded stale model does not refuse, and the
# record keeps the captain-pin marker the launch wrote.
test_relaunch_of_a_pinned_stale_task_is_not_refused() {
  local out status meta
  make_case relaunch-pinned relaunch-pinned-a1
  out=$(run_case_spawn --model "$STALE_MODEL" --captain-model-pin "$STALE_MODEL" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "the pinned stale launch must succeed before it is relaunched"$'\n'"$out"
  out=$(run_case_relaunch --model "$STALE_MODEL" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "relaunching the model the task already runs must not refuse"$'\n'"$out"
  assert_not_contains "$out" "refusing to launch a stale model" \
    "a relaunch of the recorded model must not be gated again"
  assert_contains "$out" "stale model kept by relaunch, admitted at launch" \
    "the relaunch must say the stale model was already admitted"
  [ -s "$CASE_LAUNCH_LOG" ] || fail "the relaunch must reach the pane"
  meta="$CASE_HOME/state/relaunch-pinned-a1.meta"
  assert_contains "$(grep '^model_stale=' "$meta")" "(admitted by captain pin)" \
    "the relaunched record must keep the launch's captain-pin marker"
  pass "a relaunch of a captain-pinned stale task is not refused and keeps its pin marker"
}

# Test 7: a task launched on a current model whose catalog has since gained a
# newer one relaunches on that same model, and the record marks the finding.
test_relaunch_of_a_model_that_aged_is_not_refused() {
  local out status
  make_case aging aging-a1
  out=$(run_case_spawn --model "$STALE_MODEL" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "the model is current when the task launches"$'\n'"$out"
  assert_no_grep 'model_stale=' "$CASE_HOME/state/aging-a1.meta" \
    "a current model must leave no stale record at launch"
  printf '%s\n' "$FULL_LISTING" > "$CASE_DIR/omp-models.json"
  out=$(run_case_relaunch --model "$STALE_MODEL" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "relaunching a model that was current at launch must not refuse"$'\n'"$out"
  assert_contains "$out" "stale model kept by relaunch, admitted at launch - $STALE_MODEL on omp is older than $NEWER_MODEL" \
    "the relaunch must report the finding the catalog now holds"
  assert_grep "model_stale=$STALE_MODEL on omp is older than $NEWER_MODEL in the omp catalog (admitted at launch)" \
    "$CASE_HOME/state/aging-a1.meta" "the relaunched record must mark the finding as admitted at launch"
  pass "a relaunch of a model that went stale after launch is not refused and records the finding"
}

# Test 8: only the recorded model is exempt. A relaunch that asks for a different
# stale model is still refused, and the task record is left as it was.
test_relaunch_to_another_stale_model_is_still_refused() {
  local out status meta before
  make_case relaunch-other relaunch-other-a1
  out=$(run_case_spawn --model "$CURRENT_MODEL" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "the current model must launch before it is relaunched"$'\n'"$out"
  meta="$CASE_HOME/state/relaunch-other-a1.meta"
  before=$(cat "$meta")
  out=$(run_case_relaunch --model "$STALE_MODEL" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a relaunch onto a different stale model must still refuse"$'\n'"$out"
  assert_contains "$out" "refusing to launch a stale model" \
    "the relaunch onto a different stale model must say it refused"
  [ ! -s "$CASE_LAUNCH_LOG" ] || fail "a refused relaunch must not reach the pane"
  assert_equals "$before" "$(cat "$meta")" "a refused relaunch must leave the task record unchanged"
  pass "a relaunch onto a different stale model is still refused and leaves the record unchanged"
}

# make_secondmate_case <name> <id>: builds an isolated parent home whose
# config/secondmate-harness names omp and STALE, and a seeded secondmate home,
# and records the paths in CASE_* globals. The secondmate home is also the pane.
make_secondmate_case() {
  local name=$1 id=$2
  CASE_DIR="$TMP_ROOT/$name"
  CASE_ID=$id
  CASE_HOME="$CASE_DIR/home"
  CASE_SM="$CASE_DIR/sm"
  CASE_LAUNCH_LOG="$CASE_DIR/launch.log"
  mkdir -p "$CASE_DIR" "$CASE_SM/bin" "$CASE_SM/data"
  CASE_FAKE=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_spawn_home "$CASE_HOME" omp
  printf 'omp %s\n' "$STALE_MODEL" > "$CASE_HOME/config/secondmate-harness"
  printf '# Firstmate\n' > "$CASE_SM/AGENTS.md"
  printf '%s\n' "$id" > "$CASE_SM/.fm-secondmate-home"
  printf 'charter\n' > "$CASE_SM/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$CASE_SM/.gitignore"
  git -C "$CASE_SM" init -q -b main
  printf '%s\n' "$FULL_LISTING" > "$CASE_DIR/omp-models.json"
  install_omp_fake "$CASE_FAKE" "$CASE_DIR/omp-models.json"
}

# run_secondmate_spawn [fm-spawn args...]: drives the real secondmate spawn for
# the current case. With no home argument it is the respawn the liveness sweep
# runs (`fm-spawn.sh <id> --secondmate`), which reads the home from the record.
run_secondmate_spawn() {
  : > "$CASE_LAUNCH_LOG"
  FM_FAKE_LAUNCH_LOG="$CASE_LAUNCH_LOG" \
    fm_test_run_spawn "$CASE_HOME" "$CASE_SM" "$CASE_FAKE" "$CASE_ID" "$@" --secondmate
}

# Test 9: the automatic respawn of a secondmate on its recorded stale model is
# not refused, so a mate the captain pinned stays recoverable, and the record
# keeps the captain-pin marker.
test_secondmate_respawn_of_its_recorded_model_is_not_refused() {
  local out status meta
  make_secondmate_case sm-respawn sm-respawn-a1
  out=$(run_secondmate_spawn "$CASE_SM" --captain-model-pin "$STALE_MODEL" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "the pinned stale secondmate must launch before it is respawned"$'\n'"$out"
  out=$(run_secondmate_spawn 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "respawning a secondmate on its recorded model must not refuse"$'\n'"$out"
  assert_not_contains "$out" "refusing to launch a stale model" \
    "a secondmate respawn of the recorded model must not be gated again"
  assert_contains "$out" "stale model kept by relaunch, admitted at launch - $STALE_MODEL on omp is older than $NEWER_MODEL" \
    "the respawn must say the stale model was already admitted"
  [ -s "$CASE_LAUNCH_LOG" ] || fail "the respawn must reach the pane"
  meta="$CASE_HOME/state/sm-respawn-a1.meta"
  assert_contains "$(grep '^model_stale=' "$meta")" "(admitted by captain pin)" \
    "the respawned record must keep the launch's captain-pin marker"
  pass "a secondmate respawn on its recorded stale model is not refused and keeps its pin marker"
}

# Test 10: only the recorded model is exempt. A secondmate respawn that asks for
# a different stale model is still refused, and the record is left as it was.
test_secondmate_respawn_onto_another_stale_model_is_refused() {
  local out status meta before
  make_secondmate_case sm-other sm-other-a1
  out=$(run_secondmate_spawn "$CASE_SM" --captain-model-pin "$STALE_MODEL" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "the pinned stale secondmate must launch before it is respawned"$'\n'"$out"
  meta="$CASE_HOME/state/sm-other-a1.meta"
  before=$(cat "$meta")
  out=$(run_secondmate_spawn --model "$OTHER_STALE_MODEL" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate respawn onto a different stale model must refuse"$'\n'"$out"
  assert_contains "$out" "refusing to launch a stale model - $OTHER_STALE_MODEL on omp is older than $NEWER_MODEL" \
    "the respawn onto a different stale model must say it refused"
  [ ! -s "$CASE_LAUNCH_LOG" ] || fail "a refused secondmate respawn must not reach the pane"
  assert_equals "$before" "$(cat "$meta")" "a refused secondmate respawn must leave the record unchanged"
  pass "a secondmate respawn onto a different stale model is still refused and leaves the record unchanged"
}

# --- run --------------------------------------------------------------------

test_stale_model_refused_without_pin
test_captain_pin_admits_that_model
test_pin_for_another_model_refused
test_current_model_launches_without_pin
test_batch_forwards_the_pin_to_every_pair
test_relaunch_of_a_pinned_stale_task_is_not_refused
test_relaunch_of_a_model_that_aged_is_not_refused
test_relaunch_to_another_stale_model_is_still_refused
test_secondmate_respawn_of_its_recorded_model_is_not_refused
test_secondmate_respawn_onto_another_stale_model_is_refused
