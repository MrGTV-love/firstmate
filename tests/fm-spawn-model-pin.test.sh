#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's stale-model launch gate.
#
# A model that a newer model of its own family has passed in the harness's own
# catalog refuses the launch; only --captain-model-pin naming that exact model
# admits it, and a pin for any other model cannot launder a stale one. The
# assertions never read bin/fm-spawn.sh: each case drives the real spawn against
# a fake pane and a real isolated git worktree, then checks the exit code and the
# message it printed.
#
# Environment. This suite models an omp worker, so the fakebin shadows `omp`
# with a stub that serves a fixture `omp models --json` listing and answers
# `--version` and `usage`; every other omp verb is delegated to the real binary
# resolved before the shadow, so the shadow only controls the catalog. No real
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

# One family, three models: NEWER (6.0) has passed STALE (5.6), so STALE is
# stale; CURRENT (6.1) is the newest in the family, so it is current.
STALE_MODEL=openai-codex/gpt-5.6-luna
NEWER_MODEL=openai-codex/gpt-6-luna
CURRENT_MODEL=openai-codex/gpt-6.1-sol

# Resolved before the fakebin shadows omp. Only the fallback delegation uses it;
# the three omp verbs this spawn path runs are answered by the stub.
REAL_OMP=$(command -v omp 2>/dev/null) || REAL_OMP=

# install_omp_fake <fakebin> <listing-file>
# `omp models --json` comes from the fixture listing, `--version` reports a
# version above fm-spawn's omp floor, and `usage` reports an unknown quota (the
# spawn's capacity probe accepts that). Anything else is handed to the real omp
# binary, whose absolute path is expanded into the stub at generation time: a
# quoted heredoc would leave it literal and the stub would re-run itself.
install_omp_fake() {
  local fakebin=$1 listing=$2
  cat > "$fakebin/omp" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  --version) printf 'omp/18.1.20\n' && exit 0 ;;
  models) cat '$listing' && exit 0 ;;
  usage) printf '{}\n' && exit 0 ;;
esac
if [ -n '$REAL_OMP' ]; then exec '$REAL_OMP' "\$@"; fi
printf 'fake omp: unsupported invocation: %s\n' "\$*" >&2
exit 1
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
    *) printf '%s\n' '{"models":[{"provider":"openai-codex","id":"gpt-5.6-luna","selector":"openai-codex/gpt-5.6-luna"},{"provider":"openai-codex","id":"gpt-6-luna","selector":"openai-codex/gpt-6-luna"},{"provider":"openai-codex","id":"gpt-6.1-sol","selector":"openai-codex/gpt-6.1-sol"}]}' > "$CASE_DIR/omp-models.json" ;;
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
  assert_contains "$out" "stale model admitted by captain pin" \
    "the admitted launch must announce the captain pin"
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

# --- run --------------------------------------------------------------------

test_stale_model_refused_without_pin
test_captain_pin_admits_that_model
test_pin_for_another_model_refused
test_current_model_launches_without_pin
