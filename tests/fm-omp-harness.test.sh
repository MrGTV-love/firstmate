#!/usr/bin/env bash
# tests/fm-omp-harness.test.sh - the portable regression for the omp (Oh My Pi)
# adapter: detection, session-lock identity, tmux liveness classification, the
# spawn launch line and worker posture overlay, pre-launch model validation, the
# per-task busy-state extension, the extension supervision model and ownership
# proof, and the two tracked primary extensions driven over a fake omp API.
#
# omp's identity, launch, and lifecycle checks are HARNESS-DEPENDENT: their
# verdicts come from what the vendor emits (a process name, a settings schema,
# an extension event). This suite pins the LOGIC with real processes, a fake
# omp binary, and a plain Node host, so CI enforces it with no omp installed;
# FM_OMP_LIVE_E2E=1 tests/fm-omp-primary-live-e2e.test.sh is the live guard that
# catches vendor drift against a real omp. Neither replaces the other.
#
# The load-bearing contracts:
#   1. omp publishes no marker; the anchored process name `omp` is the ancestry
#      evidence, and ompd/comp never identify.
#   2. FM_OMP_HARNESS=omp is a precedence override that needs a real omp
#      ancestor: it beats an inherited CLAUDECODE under omp and is inert when it
#      leaks into a worker whose ancestry holds no omp.
#   3. Every omp launch clears foreign markers, carries the tracked posture
#      overlay, --auto-approve, --cwd, and (for a crewmate) one -e pointing at
#      state/<id>.omp-ext.ts; a secondmate launch names no -e at all.
#   4. A <provider>/<id> model is validated only when `omp models --json` lists
#      that provider; an unlisted provider passes through with a notice.
#   5. Busy state: agent_start is busy, agent_end with willContinue stays busy,
#      a plain agent_end is idle, turn_end is a notification only.
#   6. The turn-end guard extension compels one continuation on exit 2 and
#      stands down when the payload already carries stop_hook_active.
#   7. The watch extension arms through fm_watch_arm_omp and delivers an
#      actionable close as one follow-up.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-omp-harness)
export NODE_NO_WARNINGS=1
export PI_CODING_AGENT_DIR=
export OMP_PROFILE= PI_PROFILE=

# A process whose kernel-recorded identity is the bare name `omp`: a SYMLINK to
# the system shell, never a copy (a copied platform binary fails macOS code
# signing). macOS reports the symlink name through `ps -o comm=`, which is the
# exact signal under test. Every `-c` body below ends in a no-op so bash does
# not exec-optimize the single command away and replace the named process.
make_named_shells() {  # <dir> -> echoes <bindir>
  local dir=$1 name
  mkdir -p "$dir"
  for name in omp ompd comp; do
    ln -sf /bin/bash "$dir/$name"
  done
  printf '%s' "$dir"
}

# --- 1. Detection --------------------------------------------------------------

test_detection_anchored_name_and_marker_precedence() {
  local bin out
  bin=$(make_named_shells "$TMP_ROOT/named")
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u CLAUDECODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    "$bin/omp" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = omp ] || fail "a process named omp must detect as omp, got '$out'"
  for decoy in ompd comp; do
    # shellcheck disable=SC2016 # the quoted body expands inside the named shell
    out=$(env -u CLAUDECODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      "$bin/$decoy" -c '"$1"; :' _ "$HARNESS")
    [ "$out" != omp ] || fail "'$decoy' merely contains omp and must not detect as omp"
  done
  # The marker beats an inherited CLAUDECODE only under a real omp ancestor.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDECODE=1 FM_OMP_HARNESS=omp \
    "$bin/omp" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = omp ] || fail "FM_OMP_HARNESS under an omp ancestor must outrank an inherited CLAUDECODE, got '$out'"
  # ...and is inert when it leaks into a worker with no omp ancestor.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDECODE=1 FM_OMP_HARNESS=omp \
    bash -c '"$1"; :' _ "$HARNESS")
  [ "$out" = claude ] || fail "a leaked FM_OMP_HARNESS without an omp ancestor must not relabel a claude worker, got '$out'"
  pass "fm-harness: omp detects by its anchored name; the marker is a precedence override that needs real omp ancestry"
}

test_lock_identity_and_liveness_classification() {
  fm_harness_process_matches omp '' || fail "session-lock identity must accept the exact omp name"
  fm_harness_process_matches /usr/local/bin/omp 'omp --cwd /x' || fail "session-lock identity must accept an omp path"
  ! fm_harness_process_matches ompd '' || fail "session-lock identity must not accept ompd"
  ! fm_harness_process_matches comp '' || fail "session-lock identity must not accept comp"
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source tmux || fail "fm_backend_source tmux failed"
  [ "$(fm_agent_process_classify_name omp)" = agent ] || fail "tmux liveness must classify omp as an agent"
  [ "$(fm_agent_process_classify_name /opt/omp/bin/omp)" = agent ] || fail "tmux liveness must classify an omp path as an agent"
  [ "$(fm_agent_process_classify_name ompd)" != agent ] || fail "tmux liveness must not classify ompd as an agent"
  [ "$(fm_agent_process_classify_name comp)" != agent ] || fail "tmux liveness must not classify comp as an agent"
  pass "session lock and tmux liveness: omp is anchored, decoys stay out"
}

# --- 2. Launch ---------------------------------------------------------------

# A fake omp that answers `models --json` with a two-provider catalog and exits
# 0 for everything else (the launch itself is only recorded by the fake tmux).
make_fake_omp() {  # <fakebin>
  cat > "$1/omp" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_OMP_ENV_LOG:-}" ]; then
  printf '%s:%s\n' "${1:-launch}" "${PI_CODING_AGENT_DIR:-}" >> "$FM_FAKE_OMP_ENV_LOG"
fi
case "$1" in
  models)
    if [ -f "${PI_CODING_AGENT_DIR:-}/catalog.json" ]; then
      cat "$PI_CODING_AGENT_DIR/catalog.json"
      exit 0
    fi
    printf '%s\n' '{"models":[{"provider":"openai-codex","id":"gpt-6-astra","selector":"openai-codex/gpt-6-astra"},{"provider":"ollama","id":"qwen3:8b","selector":"ollama/qwen3:8b"}]}'
    ;;
esac
exit 0
SH
  chmod +x "$1/omp"
}

make_spawn_case() {  # <name> <harness> <id>
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  make_fake_omp "$fakebin"
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  : > "$case_dir/launch.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$case_dir/launch.log"
}

read_case_record() {
  # shellcheck disable=SC2034 # CASE_DIR is part of the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
  GLOBAL_CONFIG="$HOME_DIR/user-home/.omp/agent/config.yml"
  mkdir -p "$(dirname "$GLOBAL_CONFIG")"
}

run_scout_spawn() {  # <home> <wt> <fakebin> <launch-log> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --scout
}

test_spawn_launch_line_and_worker_wiring() {
  local rec id=omp-launch-q1 out status launch state
  rec=$(make_spawn_case launch omp "$id")
  read_case_record "$rec"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-6-astra --effort medium)
  status=$?
  expect_code 0 "$status" "omp scout spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=omp" "spawn did not report the omp harness"
  state="$HOME_DIR/state"
  assert_grep "harness=omp" "$state/$id.meta" "meta missing harness=omp"
  assert_grep "model=openai-codex/gpt-6-astra" "$state/$id.meta" "meta missing the pinned model"
  assert_grep "effort=medium" "$state/$id.meta" "meta missing the pinned effort"
  assert_present "$state/$id.omp-ext.ts" "omp spawn did not write the per-task extension"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_AGENT -u CURSOR_INVOKED_AS FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 '$FAKEBIN_DIR/omp'" \
    "omp launch did not clear foreign markers and establish its own at the launch boundary"
  assert_contains "$launch" "--config '$ROOT/.omp/fm-session-overlay.yml' --auto-approve --cwd '$WT_DIR' --config '$ROOT/.omp/fm-worker-overlay.yml'" \
    "omp scout launch did not carry shared posture and worker-only memory overlays"
  assert_contains "$launch" "--model 'openai-codex/gpt-6-astra' --thinking 'medium' -e '$state/$id.omp-ext.ts'" \
    "omp launch did not pass the model, thinking level, and the state-resident worker extension"
  assert_contains "$launch" "encode launch-brief < '$HOME_DIR/data/$id/launch-brief.md'" "omp launch lost the canonical typed launch-brief envelope"
  case "$launch" in
    *"-e '$state/$id.omp-ext.ts' \"\$("*) ;;
    *) fail "omp launch must keep exactly one positional brief after the extension flag: $launch" ;;
  esac
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy fm-spawn" ] \
    || fail "omp spawn must seed the busy-state contract"
  pass "fm-spawn: the omp launch line clears markers, pins posture, and wires the state-resident extension"
}

test_spawn_model_validation_scoped_to_listed_providers() {
  local rec id out status
  rec=$(make_spawn_case model-refused omp omp-model-refused-q2)
  read_case_record "$rec"
  id=omp-model-refused-q2
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-nope)
  status=$?
  expect_code 1 "$status" "a model absent from a listed provider must refuse"
  assert_contains "$out" "is not listed by 'omp models --json' although provider 'openai-codex' is" "refusal did not name the listing evidence"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must publish no record"

  rec=$(make_spawn_case model-bridge omp omp-model-bridge-q3)
  read_case_record "$rec"
  id=omp-model-bridge-q3
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model claude-bridge/claude-opus-4-8)
  status=$?
  expect_code 0 "$status" "an extension-registered provider must pass through: $out"
  assert_contains "$out" "notice: omp provider 'claude-bridge' is not in 'omp models --json'" "pass-through did not state its reason"
  assert_contains "$(cat "$LAUNCH_LOG")" "--model 'claude-bridge/claude-opus-4-8'" "pass-through model did not reach the launch line"

  rec=$(make_spawn_case model-fuzzy omp omp-model-fuzzy-q4)
  read_case_record "$rec"
  id=omp-model-fuzzy-q4
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model astra)
  status=$?
  expect_code 0 "$status" "a bare fuzzy pattern is omp's own matcher's job: $out"
  pass "fm-spawn: omp model validation is scoped to providers the listing can prove"
}

# omp's default role lives in one global file that every interactive omp session
# can rewrite. A launch with no --model reads it, and a missing or unlisted role
# makes omp silently pick the first credentialed model (a free-tier model that
# answers HTTP 429). The launch must refuse with the remedy instead.
test_spawn_refuses_a_missing_or_unlisted_default_role() {
  local rec id out status
  rec=$(make_spawn_case role-missing omp omp-role-missing-q5)
  read_case_record "$rec"
  id=omp-role-missing-q5
  printf 'modelRoles:\n  advisor: openai-codex/gpt-6-astra:high\n' > "$GLOBAL_CONFIG"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 1 "$status" "an omp launch with no model and no default role must refuse: $out"
  assert_contains "$out" "omp modelRoles.default is not set in the shared omp config" "refusal did not name the missing role"
  assert_contains "$out" "pass --model <provider>/<id>" "refusal did not carry the remedy"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must publish no record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused spawn must record no launch: $(cat "$LAUNCH_LOG")"

  rec=$(make_spawn_case role-unlisted omp omp-role-unlisted-q6)
  read_case_record "$rec"
  id=omp-role-unlisted-q6
  printf 'modelRoles:\n  default: openai-codex/gpt-gone:high\n' > "$GLOBAL_CONFIG"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 1 "$status" "a default role naming an unlisted id must refuse: $out"
  assert_contains "$out" "omp modelRoles.default 'openai-codex/gpt-gone:high' is not listed by 'omp models --json' although provider 'openai-codex' is" "refusal did not name the unresolvable role"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must publish no record"

  rec=$(make_spawn_case role-listed omp omp-role-listed-q7)
  read_case_record "$rec"
  id=omp-role-listed-q7
  printf 'modelRoles:\n  default: openai-codex/gpt-6-astra:high\n' > "$GLOBAL_CONFIG"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 0 "$status" "a listed default role (thinking suffix included) must launch: $out"

  rec=$(make_spawn_case role-pinned omp omp-role-pinned-q8)
  read_case_record "$rec"
  id=omp-role-pinned-q8
  printf 'modelRoles: {}\n' > "$GLOBAL_CONFIG"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-6-astra)
  status=$?
  expect_code 0 "$status" "a launch that passes --model never reads the default role: $out"

  rec=$(make_spawn_case role-bridge omp omp-role-bridge-q10)
  read_case_record "$rec"
  id=omp-role-bridge-q10
  printf 'modelRoles:\n  default: claude-bridge/claude-opus-4-8:high\n' > "$GLOBAL_CONFIG"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 0 "$status" "an unknown default-role provider must pass through: $out"
  assert_contains "$out" "notice: omp provider 'claude-bridge' is not in 'omp models --json'" "default-role pass-through did not state its reason"
  assert_contains "$out" "launching 'claude-bridge/claude-opus-4-8:high' unvalidated" "notice did not identify the default role"
  assert_present "$HOME_DIR/state/$id.meta" "default-role pass-through must publish the task"

  rec=$(make_spawn_case role-unreadable omp omp-role-unreadable-q9)
  read_case_record "$rec"
  id=omp-role-unreadable-q9
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 0 "$status" "an unreadable roles config establishes nothing and must launch: $out"
  pass "fm-spawn: an omp launch with no model refuses a missing or unlisted default role and names the remedy"
}

test_spawn_global_config_is_read_only_and_unlayered() {
  local rec id out status agent_dir
  id=omp-role-project-q11
  rec=$(make_spawn_case role-project omp "$id")
  read_case_record "$rec"
  printf 'modelRoles: {}\n' > "$GLOBAL_CONFIG"
  mkdir -p "$PROJ_DIR/.omp"
  printf 'modelRoles:\n  default: openai-codex/gpt-6-astra:high\n' > "$PROJ_DIR/.omp/config.yml"
  out=$(cd "$PROJ_DIR" && run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 1 "$status" "a project-layer default must not mask a missing global default: $out"
  assert_contains "$out" "omp modelRoles.default is not set in the shared omp config" "project-layer refusal did not identify the missing global role"
  assert_contains "$out" "pass --model <provider>/<id> (or a dispatch profile) so this launch stops depending on the shared default, or restore the Default role in omp with /model" "project-layer refusal lost the exact remedy"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused project-layer spawn must publish no record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused project-layer spawn must record no launch"

  id=omp-role-malformed-q12
  rec=$(make_spawn_case role-malformed omp "$id")
  read_case_record "$rec"
  printf 'modelRoles:\n  default: [unterminated\n' > "$GLOBAL_CONFIG"
  cp "$GLOBAL_CONFIG" "$CASE_DIR/original-config.yml"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 0 "$status" "a malformed global config establishes nothing and must pass through: $out"
  cmp -s "$CASE_DIR/original-config.yml" "$GLOBAL_CONFIG" || fail "the malformed global config must remain byte-identical"
  for out in "$GLOBAL_CONFIG".broken-*; do
    assert_absent "$out" "the global config must not be quarantined"
  done
  assert_present "$HOME_DIR/state/$id.meta" "malformed-config pass-through must publish the task"
  assert_contains "$(cat "$LAUNCH_LOG")" "'$FAKEBIN_DIR/omp'" "malformed-config pass-through must reach the launch"

  id=omp-role-agent-dir-q13
  rec=$(make_spawn_case role-agent-dir omp "$id")
  read_case_record "$rec"
  printf 'modelRoles: {}\n' > "$GLOBAL_CONFIG"
  agent_dir="$CASE_DIR/custom-agent"
  mkdir -p "$agent_dir"
  printf 'modelRoles:\n  default: ollama/qwen3:8b:max\n' > "$agent_dir/config.yml"
  printf 'FM_FAKE_OMP_ENV_LOG\n' > "$HOME_DIR/config/launch-env-allowlist"
  out=$(PI_CODING_AGENT_DIR="$agent_dir" FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log" \
    run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 0 "$status" "the selected agent dir must supply the global default, preserving model-id colons: $out"
  assert_present "$HOME_DIR/state/$id.meta" "a listed agent-dir default must publish the task"
  HOME="$HOME_DIR/user-home" PI_CODING_AGENT_DIR="$CASE_DIR/pane-agent" \
    PATH="$FAKEBIN_DIR:$PATH" FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log" \
    bash "$LAUNCH_LOG" > "$CASE_DIR/pane-output.log" 2>&1
  status=$?
  expect_code 0 "$status" "the canonical launch must execute in a pane with a different agent directory"
  assert_grep "models:$agent_dir" "$CASE_DIR/omp-env.log" "catalog inspection must use the canonical launch directory"
  assert_grep "--config:$agent_dir" "$CASE_DIR/omp-env.log" "the launched omp must receive the checked directory despite pane inheritance and filtering"

  id=omp-role-agent-dir-missing-q14
  rec=$(make_spawn_case role-agent-dir-missing omp "$id")
  read_case_record "$rec"
  printf 'modelRoles:\n  default: openai-codex/gpt-6-astra:high\n' > "$GLOBAL_CONFIG"
  agent_dir="$CASE_DIR/custom-agent"
  mkdir -p "$agent_dir"
  printf '{}\n' > "$agent_dir/config.yml"
  out=$(PI_CODING_AGENT_DIR="$agent_dir" run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 1 "$status" "the HOME default must not mask a missing default in the selected agent dir: $out"
  assert_contains "$out" "omp modelRoles.default is not set" "agent-dir refusal did not identify the missing role"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused agent-dir spawn must publish no record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused agent-dir spawn must record no launch"
  pass "fm-spawn: global role inspection is read-only, unlayered, and honors PI_CODING_AGENT_DIR"
}

test_spawn_raw_omp_guard_uses_the_launch_agent_dir() {
  local rec id out status caller_dir launch_dir mode command
  for mode in missing listed unlisted uncertain stderr stdin append descriptor; do
    id="omp-raw-agent-$mode"
    rec=$(make_spawn_case "raw-agent-$mode" omp "$id")
    read_case_record "$rec"
    caller_dir="$CASE_DIR/caller-agent"
    launch_dir="$CASE_DIR/launch-agent"
    mkdir -p "$caller_dir" "$launch_dir"
    printf 'modelRoles:\n  default: openai-codex/gpt-6-astra\n' > "$caller_dir/config.yml"
    printf 'modelRoles: {}\n' > "$launch_dir/config.yml"
    case "$mode" in
      listed)
        printf 'modelRoles: {}\n' > "$caller_dir/config.yml"
        printf 'modelRoles:\n  default: openai-codex/gpt-6-astra\n' > "$launch_dir/config.yml"
        ;;
      unlisted)
        printf 'modelRoles:\n  default: openai-codex/gpt-6-astra\n' > "$launch_dir/config.yml"
        printf '%s\n' '{"models":[{"provider":"openai-codex","id":"other","selector":"openai-codex/other"}]}' > "$launch_dir/catalog.json"
        ;;
      uncertain)
        printf 'modelRoles: {}\n' > "$caller_dir/config.yml"
        ;;
    esac
    command="PI_CODING_AGENT_DIR='$launch_dir' omp --auto-approve"
    [ "$mode" != uncertain ] || command='PI_CODING_AGENT_DIR="$PANE_AGENT_DIR" omp --auto-approve'
    case "$mode" in
      stderr) command="$command 2>'$CASE_DIR/errors.log'" ;;
      stdin) command="$command <'$launch_dir/config.yml'" ;;
      append) command="$command >>'$CASE_DIR/output.log'" ;;
      descriptor) command="$command 2>&1" ;;
    esac
    out=$(PI_CODING_AGENT_DIR="$caller_dir" FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log" \
      run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" "$command")
    status=$?
    case "$mode" in
      missing | unlisted | stderr | stdin | append | descriptor)
        expect_code 1 "$status" "raw omp must refuse the launch directory's invalid role ($mode): $out"
        assert_absent "$HOME_DIR/state/$id.meta" "a refused raw-directory launch must publish no record"
        [ ! -s "$LAUNCH_LOG" ] || fail "a refused raw-directory launch must record no launch"
        if [ "$mode" != unlisted ]; then
          assert_contains "$out" "omp modelRoles.default is not set" "raw assignment must not read the caller's listed role"
        else
          assert_contains "$out" "is not listed by 'omp models --json'" "raw catalog must use the launch directory"
          assert_grep "models:$launch_dir" "$CASE_DIR/omp-env.log" "raw catalog must receive the launch directory"
        fi
        ;;
      listed | uncertain)
        expect_code 0 "$status" "raw omp must launch with a listed or uncertain directory ($mode): $out"
        HOME="$HOME_DIR/user-home" PI_CODING_AGENT_DIR="$caller_dir" PANE_AGENT_DIR="$launch_dir" \
          PATH="$FAKEBIN_DIR:$PATH" FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log" \
          bash "$LAUNCH_LOG" > "$CASE_DIR/pane-output.log" 2>&1
        status=$?
        expect_code 0 "$status" "the raw command must execute unchanged"
        assert_grep "--auto-approve:$launch_dir" "$CASE_DIR/omp-env.log" "raw omp must receive its assignment rather than the caller directory"
        if [ "$mode" = listed ]; then
          assert_grep "models:$launch_dir" "$CASE_DIR/omp-env.log" "the role and catalog must inspect the same directory"
        else
          ! grep -q '^models:' "$CASE_DIR/omp-env.log" || fail "uncertain directory must establish no catalog evidence"
        fi
        ;;
    esac
  done
  pass "fm-spawn: raw role and catalog inspection honor the actual launch directory and uncertain evidence passes through"
}

test_spawn_omp_profiles_leave_directory_evidence_unreadable() {
  local rec id out status mode role command first_arg omp_profile pi_profile launch_dir
  local spawn_args=()
  for mode in flag flag-equals assignment-omp assignment-pi env-omp env-pi raw-env-omp raw-env-pi; do
    for role in missing unlisted; do
      id="omp-profile-$mode-$role"
      rec=$(make_spawn_case "profile-$mode-$role" omp "$id")
      read_case_record "$rec"
      launch_dir="$CASE_DIR/launch-agent"
      mkdir -p "$launch_dir"
      if [ "$role" = missing ]; then
        printf 'modelRoles: {}\n' > "$launch_dir/config.yml"
      else
        printf 'modelRoles:\n  default: openai-codex/gpt-gone\n' > "$launch_dir/config.yml"
      fi
      omp_profile= pi_profile=
      command="PI_CODING_AGENT_DIR='$launch_dir' omp --auto-approve"
      first_arg=--auto-approve
      case "$mode" in
        flag) command="$command --profile work" ;;
        flag-equals) command="$command --profile=work" ;;
        assignment-omp) command="OMP_PROFILE=work $command" ;;
        assignment-pi) command="PI_PROFILE=work $command" ;;
        env-omp | raw-env-omp) omp_profile=work ;;
        env-pi | raw-env-pi) pi_profile=work ;;
      esac
      spawn_args=("$command")
      case "$mode" in
        env-omp | env-pi)
          spawn_args=(--harness omp)
          first_arg=--config
          ;;
      esac
      out=$(OMP_PROFILE="$omp_profile" PI_PROFILE="$pi_profile" PI_CODING_AGENT_DIR="$launch_dir" \
        FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log" \
        run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" "${spawn_args[@]}")
      status=$?
      expect_code 0 "$status" "profile selection must pass through an unrelated $role default ($mode): $out"
      assert_present "$HOME_DIR/state/$id.meta" "a profile-selecting launch must publish the task"
      assert_absent "$CASE_DIR/omp-env.log" "profile selection must establish no catalog evidence"
      case "$mode" in
        env-omp | env-pi) ;;
        *) assert_contains "$(cat "$LAUNCH_LOG")" "$command" "the raw profile-selecting command must reach the launch unchanged" ;;
      esac
      HOME="$HOME_DIR/user-home" PI_CODING_AGENT_DIR="$launch_dir" \
        OMP_PROFILE="$omp_profile" PI_PROFILE="$pi_profile" \
        PATH="$FAKEBIN_DIR:$PATH" FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log" \
        bash "$LAUNCH_LOG" > "$CASE_DIR/pane-output.log" 2>&1
      status=$?
      expect_code 0 "$status" "the profile-selecting launch must execute ($mode)"
      assert_grep "$first_arg:$launch_dir" "$CASE_DIR/omp-env.log" "profile selection must still launch omp ($mode)"
    done
  done
  pass "fm-spawn: omp profile flags, assignments, and invoking environment pass through without default-role catalog probes"
}

test_spawn_raw_omp_guard_uses_the_launch_model() {
  local rec id out status command expected index=0
  local model_args=()
  while IFS='|' read -r command expected; do
    index=$((index + 1))
    id="omp-raw-role-$index"
    rec=$(make_spawn_case "raw-role-$index" omp "$id")
    read_case_record "$rec"
    printf 'modelRoles: {}\n' > "$GLOBAL_CONFIG"
    model_args=()
    case "$command" in
      *'__MODELFLAG__'* | 'omp --auto-approve') model_args=(--model openai-codex/gpt-6-astra) ;;
    esac
    command="PI_CODING_AGENT_DIR='$(dirname "$GLOBAL_CONFIG")' $command"
    out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" "$command" ${model_args[@]+"${model_args[@]}"})
    status=$?
    expect_code "$expected" "$status" "raw omp guard must follow the effective model in '$command': $out"
    if [ "$expected" = 0 ]; then
      assert_present "$HOME_DIR/state/$id.meta" "a pinned raw launch must publish the task"
      assert_contains "$(cat "$LAUNCH_LOG")" "${command//__MODELFLAG__/--model 'openai-codex/gpt-6-astra' }" "raw model selection did not reach the launch"
    else
      assert_contains "$out" "omp modelRoles.default is not set" "an unpinned raw launch must refuse the missing role"
      assert_absent "$HOME_DIR/state/$id.meta" "a refused raw launch must publish no record"
      [ ! -s "$LAUNCH_LOG" ] || fail "a refused raw launch must record no launch"
    fi
  done <<'CASES'
omp --model openai-codex/gpt-6-astra|0
omp --model='openai-codex/gpt-6-astra'|0
omp -m 'openai-codex/gpt-6-astra'|0
omp __MODELFLAG__|0
omp --model default|0
omp --auto-approve|1
omp -- '--model' 'openai-codex/gpt-6-astra'|1
omp '--model openai-codex/gpt-6-astra'|1
CASES
  pass "fm-spawn: raw omp launches validate the default only without an effective model override"
}

test_secondmate_launch_relies_on_discovery() {
  # A seeded secondmate home, launched for real through fm-spawn on omp: the
  # launch must carry the posture overlay and pin --cwd to the home, and must
  # name NO -e, because omp auto-discovers the home's tracked .omp/extensions
  # and a file named both ways loads twice.
  local world home fakebin launchlog out status launch
  world="$TMP_ROOT/secondmate"
  home="$world/sm"
  mkdir -p "$world/home/state" "$world/home/data" "$world/home/config" "$home/bin" "$home/data"
  mkdir -p "$world/user-home/.omp/agent"
  printf 'modelRoles:\n  default: openai-codex/gpt-6-astra:high\n' > "$world/user-home/.omp/agent/config.yml"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'sm\n' > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$home/.gitignore"
  git -C "$home" init -q -b main
  fakebin=$(make_spawn_fakebin "$world/fake" claude)
  make_fake_omp "$fakebin"
  launchlog="$world/launch.log"
  : > "$launchlog"
  # FM_BACKEND=tmux pins the fake tmux even where the developer shell carries a
  # live Herdr environment; without it auto-detection would spawn a real pane.
  out=$(PATH="$fakebin:$PATH" TMUX='fake,1,0' FM_BACKEND=tmux CLAUDECODE=1 \
    FM_ROOT_OVERRIDE='' FM_HOME="$world/home" HOME="$world/user-home" \
    FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
    FM_PROJECTS_OVERRIDE="$world/home/projects" FM_CONFIG_OVERRIDE="$world/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_LAUNCH_LOG="$launchlog" \
    "$ROOT/bin/fm-spawn.sh" sm "$home" omp --secondmate 2>&1)
  status=$?
  expect_code 0 "$status" "omp secondmate spawn should succeed: $out"
  assert_grep "harness=omp" "$world/home/state/sm.meta" "secondmate meta missing harness=omp"
  launch=$(cat "$launchlog")
  case "$launch" in
    *" -e "*) fail "an omp secondmate launch must name no -e: omp auto-discovers .omp/extensions and a file named both ways loads twice: $launch" ;;
  esac
  assert_contains "$launch" "--config '$ROOT/.omp/fm-session-overlay.yml' --auto-approve --cwd '$home'" "secondmate launch lost the posture overlay or the pinned home directory: $launch"
  assert_not_contains "$launch" "fm-worker-overlay.yml" "secondmate launch must preserve the lane's memory settings"
  assert_contains "$launch" "FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 '$fakebin/omp'" "secondmate launch lost the omp marker or executable"
  assert_contains "$launch" "FM_SUPERVISION_MODEL=extension" "an omp secondmate must run the extension supervision model"
  assert_absent "$world/home/state/sm.omp-ext.ts" "a secondmate must not receive a per-task worker extension"
  pass "fm-spawn: a real omp secondmate launch relies on auto-discovery while crewmates load one -e"
}

test_secondmate_config_pinned_model_is_validated() {
  # The same seeded secondmate home, but the harness and model come from the
  # primary's config/secondmate-harness rather than the command line: the
  # durable pin lands on MODEL after the harness case arm, so an unlisted id
  # under a listed provider must still be refused before endpoint creation.
  local world home fakebin launchlog out status
  world="$TMP_ROOT/secondmate-config-model"
  home="$world/sm"
  mkdir -p "$world/home/state" "$world/home/data" "$world/home/config" "$home/bin" "$home/data"
  mkdir -p "$world/user-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'sm\n' > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$home/.gitignore"
  git -C "$home" init -q -b main
  printf 'omp openai-codex/gpt-nope\n' > "$world/home/config/secondmate-harness"
  fakebin=$(make_spawn_fakebin "$world/fake" claude)
  make_fake_omp "$fakebin"
  launchlog="$world/launch.log"
  : > "$launchlog"
  out=$(PATH="$fakebin:$PATH" TMUX='fake,1,0' FM_BACKEND=tmux CLAUDECODE=1 \
    FM_ROOT_OVERRIDE='' FM_HOME="$world/home" HOME="$world/user-home" \
    FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
    FM_PROJECTS_OVERRIDE="$world/home/projects" FM_CONFIG_OVERRIDE="$world/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_LAUNCH_LOG="$launchlog" \
    "$ROOT/bin/fm-spawn.sh" sm "$home" --secondmate 2>&1)
  status=$?
  expect_code 1 "$status" "a config-pinned unlisted omp model must refuse the secondmate spawn: $out"
  assert_contains "$out" "omp model 'openai-codex/gpt-nope' is not listed by 'omp models --json' although provider 'openai-codex' is" \
    "the refusal did not name the config-pinned model under its listed provider: $out"
  assert_absent "$world/home/state/sm.meta" "a refused secondmate spawn must publish no sm.meta"
  [ ! -s "$launchlog" ] || fail "a refused secondmate spawn must record no launch: $(cat "$launchlog")"
  pass "fm-spawn: the config/secondmate-harness model pin is validated against the omp catalog before launch"
}

# --- 3. Busy state -------------------------------------------------------------

drive_omp_ext() {  # <ext-path> <mode>
  EXT_PATH="$1" MODE="$2" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; } });
// ctx.isIdle() reads false at a natural TUI agent_end on omp; the extension
// must go idle on a plain agent_end regardless of it.
const ctx = { isIdle: () => false };
switch (process.env.MODE) {
  case "handlers": console.log(Object.keys(handlers).sort().join(" ")); break;
  case "agent-start": await handlers["agent_start"]({ type: "agent_start" }, ctx); break;
  case "end-continuing": await handlers["agent_end"]({ type: "agent_end", willContinue: true }, ctx); break;
  case "end-final": await handlers["agent_end"]({ type: "agent_end" }, ctx); break;
  case "turn-end": await handlers["turn_end"]({ type: "turn_end", turnIndex: 0 }, ctx); break;
  default: throw new Error("unknown mode " + process.env.MODE);
}
if (process.env.MODE === "turn-end") {
  await new Promise((resolve) => setTimeout(resolve, 200));
}
EOF
}

test_busy_extension_lifecycle() {
  local rec id=omp-busy-q5 out state ext
  rec=$(make_spawn_case busy omp "$id")
  read_case_record "$rec"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  expect_code 0 $? "omp spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  assert_present "$ext" "omp spawn did not write the per-task extension"
  out=$(drive_omp_ext "$ext" handlers) || fail "handler listing failed: $out"
  case " $out " in
    *" agent_settled "*) fail "the omp extension must not listen for agent_settled (omp has no such event)" ;;
  esac
  for handler in agent_start agent_end turn_end; do
    case " $out " in
      *" $handler "*) ;;
      *) fail "the omp extension must register $handler, got '$out'" ;;
    esac
  done

  rm -f "$state/$id.turn-ended"
  out=$(drive_omp_ext "$ext" turn-end) || fail "turn_end drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "turn_end no longer touches the notification marker"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy fm-spawn" ] || fail "turn_end must stay a notification, not a state edge"

  out=$(drive_omp_ext "$ext" agent-start) || fail "agent_start drive failed: $out"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy omp-ext" ] || fail "agent_start must classify 'busy omp-ext'"

  out=$(drive_omp_ext "$ext" end-continuing) || fail "continuing agent_end drive failed: $out"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy omp-ext" ] || fail "agent_end with willContinue must stay busy (a session_stop continuation is coming)"

  out=$(drive_omp_ext "$ext" end-final) || fail "final agent_end drive failed: $out"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "idle omp-ext" ] || fail "a plain agent_end must classify 'idle omp-ext'"

  # A record from another harness's writer is never trusted for omp.
  fm_busy_source_trusted omp pi-ext && fail "omp must not trust the Pi extension's records"
  fm_busy_source_trusted omp omp-ext || fail "omp must trust its own extension's records"
  pass "omp extension: agent_start busy, willContinue stays busy, plain agent_end idle, turn_end a notification"
}

# --- 4. Control, composer, supervision model -----------------------------------

test_control_composer_and_model_tables() {
  [ "$(fm_control_exit_command omp)" = /quit ] || fail "omp exit command must be /quit"
  [ "$(fm_control_interrupt_key omp)" = Escape ] || fail "omp interrupt key must be Escape"
  [ "$(fm_control_interrupt_repeat omp)" = 1 ] || fail "omp interrupts on a single press"
  [ -z "$(fm_control_interrupt_clear_key omp)" ] || fail "omp leaves its composer empty and needs no clear key"
  [ "$(fm_control_harness_wiring_paths omp /wt /st id1)" = "/st/id1.omp-ext.ts" ] || fail "omp wiring path must be the state-resident extension"
  printf 'Working…\n' | fm_busy_lines_match omp || fail "omp busy regex must match the TUI ellipsis form"
  printf 'Working...\n' | fm_busy_lines_match omp && fail "omp busy regex must not match the three-dot form no supervised pane renders"
  printf ' ⠧ 11s  · gpt-6-astra\n' | fm_busy_lines_match omp || fail "omp busy regex must match the braille spinner plus elapsed cell"
  printf ' ⣾ 3s  · gpt-6-astra\n' | fm_busy_lines_match omp || fail "omp busy regex must match the status-set spinner frames, not only the activity set"
  printf ' 󰵗  · gpt-6-astra · 36.7%%/41K\n' | fm_busy_lines_match omp && fail "an idle omp status row must not read busy"
  printf 'esc to interrupt\n' | fm_busy_lines_match omp && fail "omp must not borrow Claude's footer"
  local bin out
  bin=$(make_named_shells "$TMP_ROOT/named-model")
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u CLAUDECODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u FM_SUPERVISION_MODEL \
    "$bin/omp" -c '. "$1"; fm_supervision_model' _ "$ROOT/bin/fm-wake-lib.sh")
  [ "$out" = extension ] || fail "an omp primary must run the extension supervision model, got '$out'"
  pass "control, composer, and supervision-model tables carry omp's verified values"
}

# --- 5. Ownership proof --------------------------------------------------------

# Stand up the durable evidence a live omp session leaves behind: both tracked
# extensions under the case root and one marker per extension recording that
# build plus the session pid in state/.lock.
record_omp_session() {  # <root> <home> <session-pid> [omit] [drift]
  local root=$1 home=$2 session_pid=$3 omit=${4:-} drift=${5:-} pair source marker version
  mkdir -p "$root/.omp/extensions" "$home/state"
  for pair in \
    "fm-primary-omp-watch.ts:.omp-watch-extension-loaded:watch" \
    "fm-primary-turnend-guard.ts:.omp-turnend-extension-loaded:turnend"; do
    source=${pair%%:*}
    marker=${pair#*:}; marker=${marker%%:*}
    printf '// %s\n' "${pair##*:}" > "$root/.omp/extensions/$source"
    [ "$omit" = "${pair##*:}" ] && continue
    if [ "$drift" = "${pair##*:}" ]; then
      version="sha256:0000000000000000000000000000000000000000000000000000000000000000"
    else
      version=$(bash -c '. "$1"; fm_pi_extension_version "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$root/.omp/extensions/$source") || return 1
    fi
    printf '%s\n%s\n' "$version" "$session_pid" > "$home/state/$marker"
  done
  printf '%s\n' "$session_pid" > "$home/state/.lock"
}

owns() {  # <root> <home>
  bash -c '. "$1"; fm_omp_extension_owns_supervision "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$2/state" "$1"
}

test_ownership_proof_is_omp_keyed() {
  local root home pid
  sleep 60 &
  pid=$!
  root="$TMP_ROOT/own/root"; home="$TMP_ROOT/own/home"
  record_omp_session "$root" "$home" "$pid" || fail "could not record the omp session"
  owns "$root" "$home" || fail "a live session that loaded both omp extensions must own supervision"
  bash -c '. "$1"; fm_pi_extension_owns_supervision "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root" \
    && fail "omp markers must never satisfy the Pi proof"
  bash -c '. "$1"; fm_extension_owns_supervision "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root" \
    || fail "the shared extension proof must accept the omp pair"

  root="$TMP_ROOT/own-drift/root"; home="$TMP_ROOT/own-drift/home"
  record_omp_session "$root" "$home" "$pid" "" watch || fail "could not record the drifted session"
  owns "$root" "$home" && fail "a session that loaded an older watch build must not own supervision"
  root="$TMP_ROOT/own-omit/root"; home="$TMP_ROOT/own-omit/home"
  record_omp_session "$root" "$home" "$pid" turnend || fail "could not record the partial session"
  owns "$root" "$home" && fail "a session missing the turn-end guard extension must not own supervision"
  root="$TMP_ROOT/own-dead/root"; home="$TMP_ROOT/own-dead/home"
  record_omp_session "$root" "$home" "$pid" || fail "could not record the dead session"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  owns "$root" "$home" && fail "a dead session must not own supervision"

  # The pull-guard verdict tolerates the extension's own hand-off only with the proof.
  sleep 60 &
  pid=$!
  root="$TMP_ROOT/own-verdict/root"; home="$TMP_ROOT/own-verdict/home"
  record_omp_session "$root" "$home" "$pid" || fail "could not record the verdict session"
  touch "$home/state/.last-watcher-beat"
  local verdict
  verdict=$(FM_SUPERVISION_MODEL=extension FM_HOME="$home" bash -c '
    . "$1"; fm_watcher_supervision_verdict "$2" "$3" 999 "$4" "$5"; printf "%s %s" "$FM_WATCHER_VERDICT_OK" "$FM_WATCHER_VERDICT_REASON"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root/bin/fm-watch.sh" "$home" "$root")
  [ "${verdict%% *}" = true ] || fail "an unheld lock with a fresh beacon and the omp proof must be healthy, got '$verdict'"
  rm -f "$home/state/.omp-turnend-extension-loaded"
  verdict=$(FM_SUPERVISION_MODEL=extension FM_HOME="$home" bash -c '
    . "$1"; fm_watcher_supervision_verdict "$2" "$3" 999 "$4" "$5"; printf "%s %s" "$FM_WATCHER_VERDICT_OK" "$FM_WATCHER_VERDICT_REASON"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root/bin/fm-watch.sh" "$home" "$root")
  [ "$verdict" = "false no-watcher" ] || fail "without the proof the same hand-off must alarm as no-watcher, got '$verdict'"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "fm-wake-lib: the omp ownership proof is keyed on its own extensions and gates the hand-off tolerance"
}

# --- 6. The tracked primary extensions over a fake omp API ----------------------

install_omp_extension_fixture() {  # <repo>
  local repo=$1
  mkdir -p "$repo/.omp/extensions" "$repo/.pi/extensions/lib" "$repo/bin" "$repo/node_modules/typebox"
  cp "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts" "$ROOT/.omp/extensions/fm-primary-omp-watch.ts" "$repo/.omp/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$ROOT/.pi/extensions/lib/fm-sessionstart-supervisor.mjs" "$repo/.pi/extensions/lib/"
  cp "$ROOT/bin/fm-operational-input.sh" "$ROOT/bin/fm-supervision-engine-lib.sh" "$repo/bin/"
  chmod +x "$repo/bin/fm-operational-input.sh"
  printf '{"name":"typebox","type":"module","exports":"./index.js"}\n' > "$repo/node_modules/typebox/package.json"
  printf 'export const Type = { Object(p) { return { type: "object", properties: p }; } };\n' > "$repo/node_modules/typebox/index.js"
}

test_turnend_guard_extension_compels_one_continuation() {
  local repo home out status
  repo="$TMP_ROOT/guard/repo"; home="$TMP_ROOT/guard/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
payload=$(cat); printf '%s\n' "$payload" >> "${FM_GUARD_LOG:?}"
case "$payload" in *'"stop_hook_active":true'*) exit 0 ;; esac
printf 'guard says: repair with fm_watch_arm_omp\n' >&2; exit 2
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
case "$*" in *fm-watch-arm.sh*'&'*) printf 'fm watcher-arm seatbelt: blocked\n' >&2; exit 2 ;; esac; exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/bin/fm-cd-pretool-check.sh"
  # shellcheck disable=SC2016 # $2 expands in the generated script
  printf '#!/usr/bin/env bash\nprintf "OMP DIGEST source=%%s\\n" "$2"\n' > "$repo/bin/fm-sessionstart-run.sh"
  chmod +x "$repo/bin/"*.sh
  out=$(FM_GUARD_LOG="$TMP_ROOT/guard/guard.log" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" EXT="$repo/.omp/extensions/fm-primary-turnend-guard.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { readFileSync, existsSync } from "node:fs";
const handlers = new Map();
const pi = { on(e, h) { handlers.set(e, h); }, sendMessage() {} };
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
for (const name of ["session_start", "before_agent_start", "session_compact", "session_shutdown", "tool_call", "session_stop"]) {
  if (!handlers.has(name)) throw new Error(`${name} handler was not registered`);
}
if (handlers.has("agent_settled")) throw new Error("omp guard must not listen for agent_settled");
const ctx = { sessionManager: { getSessionId: () => "s1" } };
handlers.get("session_start")({ type: "session_start" }, ctx);
const first = await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "hi" }, ctx);
if (!first?.message?.content?.includes("FIRSTMATE_OP: v1 session-start: OMP DIGEST source=startup")) throw new Error(`first start did not deliver a startup digest: ${JSON.stringify(first)}`);
if (first.message.display !== false || first.message.customType !== "firstmate-sessionstart-nudge") throw new Error("digest message lost its persistent shape");
// A later in-process session_start is a replacement and maps to clear.
handlers.get("session_start")({ type: "session_start" }, ctx);
const second = await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "hi" }, ctx);
if (!second?.message?.content?.includes("source=clear")) throw new Error(`in-process replacement did not map to clear: ${JSON.stringify(second)}`);
const allowed = await handlers.get("tool_call")({ type: "tool_call", toolName: "bash", input: { command: "ls" } }, {});
if (allowed.block) throw new Error("an ordinary command was blocked");
const blocked = await handlers.get("tool_call")({ type: "tool_call", toolName: "bash", input: { command: "bin/fm-watch-arm.sh &" } }, {});
if (blocked.block !== true || !blocked.reason.includes("seatbelt")) throw new Error(`backgrounded arm was not blocked: ${JSON.stringify(blocked)}`);
const r1 = await handlers.get("session_stop")({ type: "session_stop", stop_hook_active: false }, {});
if (r1?.continue !== true) throw new Error(`guard exit 2 did not compel a continuation: ${JSON.stringify(r1)}`);
if (!r1.additionalContext.startsWith("⁣FIRSTMATE_OP: v1 turn-end-guard: ")) throw new Error(`continuation context is not typed operational input: ${r1.additionalContext}`);
if (!r1.additionalContext.includes("TURN WOULD END BLIND") || !r1.additionalContext.includes("repair with fm_watch_arm_omp")) throw new Error("continuation dropped the guard text");
const r2 = await handlers.get("session_stop")({ type: "session_stop", stop_hook_active: true }, {});
if (r2 !== undefined) throw new Error(`the flagged second stop must stand down, got ${JSON.stringify(r2)}`);
const payloads = readFileSync(process.env.FM_GUARD_LOG, "utf8").trim().split("\n");
if (payloads.join("|") !== '{"stop_hook_active":false}|{"stop_hook_active":true}') throw new Error(`guard payloads were ${payloads.join("|")}`);
if (!existsSync(`${process.env.FM_HOME}/state/.omp-turnend-extension-loaded`)) throw new Error("loaded marker was not written");
await handlers.get("session_shutdown")({}, {});
EOF
)
  status=$?
  expect_code 0 "$status" "omp turn-end guard extension contract: $out"
  [ -z "$out" ] || fail "omp guard extension test printed output: $out"
  pass ".omp turn-end guard: digest delivery, seatbelt block, one compelled continuation, flagged stop stands down"
}

test_watch_extension_arms_and_delivers() {
  local repo home out status
  repo="$TMP_ROOT/watch/repo"; home="$TMP_ROOT/watch/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  # The first arm child closes with one actionable reason; every successor
  # stays up, so exactly one wake exists to consume.
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-1\n' "$$"
if [ ! -e "${FM_HOME:?}/state/.e2e-fired" ]; then
  : > "$FM_HOME/state/.e2e-fired"
  sleep 1
  printf 'signal: omp-e2e done\n'
  exit 0
fi
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_OMP_ARM_READY_TIMEOUT_MS=3000 FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, existsSync, readFileSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null; let command = null; const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand(n, o) { if (n === "fm-watch-arm-omp") command = o.handler; },
  registerTool(t) { tool = t; },
  // omp sendUserMessage returns synchronously, not a promise.
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
if (!tool || tool.name !== "fm_watch_arm_omp") throw new Error("fm_watch_arm_omp was not registered");
if (!command) throw new Error("/fm-watch-arm-omp was not registered");
if (tool.parameters?.type !== "object") throw new Error("tool parameters must be an empty object schema");
const result = await tool.execute();
if (!/^watcher: started omp extension arm child 1;/.test(result.content[0].text)) throw new Error(`unexpected arm result: ${result.content[0].text}`);
const marker = readFileSync(`${process.env.FM_HOME}/state/.omp-watch-extension-loaded`, "utf8").split("\n");
if (marker[1] !== String(process.pid)) throw new Error("loaded marker must record the session pid");
const again = await tool.execute();
if (!/^watcher: unchanged - omp extension already owns an arm child/.test(again.content[0].text)) throw new Error(`redundant arm was not an ownership no-op: ${again.content[0].text}`);
await new Promise((r) => setTimeout(r, 2500));
if (sent.length !== 1) throw new Error(`expected one follow-up wake, saw ${sent.length}: ${JSON.stringify(sent)}`);
if (!sent[0].m.startsWith("⁣FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: signal: omp-e2e done")) throw new Error(`unexpected wake text: ${sent[0].m}`);
if (sent[0].o?.deliverAs !== "followUp") throw new Error("wake must be delivered as a follow-up");
await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: sent[0].m }, {});
await handlers.get("message_start")({ message: { role: "user", content: sent[0].m } }, {});
await handlers.get("session_shutdown")({}, {});
if (existsSync(`${process.env.FM_HOME}/state/extensions/omp-primary-watch/session-replacement-actionable.json`)) throw new Error("a consumed wake must not ride the replacement handoff");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension contract: $out"
  [ -z "$out" ] || fail "omp watch extension test printed output: $out"
  pass ".omp watch extension: fm_watch_arm_omp arms once, repeats as a no-op, and delivers an actionable close as one follow-up"
}

# An opted-in home spawns the supervision host in the arm's place; its streamed
# status line drives readiness and the handling handoff, and a handed-back
# wake is delivered with every host line and the away note.
test_watch_extension_runs_the_supervision_host() {  # [away|quiet]
  local kind=${1:-away} repo home log out status f
  repo="$TMP_ROOT/watch-host-$kind/repo"; home="$TMP_ROOT/watch-host-$kind/home"; log="$TMP_ROOT/watch-host-$kind/arm.log"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  if [ "$kind" = quiet ]; then
    # Quiet mode's record is a present captain (bin/fm-afk-contract.sh AWAY OR
    # QUIET): the extension asks the record owner, so the same handback carries
    # no away note.
    for f in fm-afk-contract.sh fm-classify-lib.sh fm-timeout-lib.sh; do cp "$ROOT/bin/$f" "$repo/bin/$f"; done
    FM_HOME="$home" FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter --words 'keep routine wakes off my main' >/dev/null 2>&1 \
      || fail "fixture: could not record quiet mode"
  else
    : > "$home/state/.afk-contract"
  fi
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 0
fi
printf 'plain-arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
exit 1
SH
  cat > "$repo/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'host=%s args=%s primary=%s predecessor=%s\n' "$$" "$*" "${FM_SUPERVISION_HOST_PRIMARY:-}" \
  "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
if [ "$(grep -c '^host=' "$FM_ARM_LOG")" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  sleep 1
  printf 'signal: omp-host done\nsupervision-host: the away session could not take this wake: fixture; this wake is yours\nsupervision-host: outcome 1 for demo [captain]: fixture\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-2\n' "$$"
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-supervision-host.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    RECORD_KIND="$kind" EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null; const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await tool.execute();
for (let i = 0; i < 60 && sent.length < 1; i += 1) await new Promise((r) => setTimeout(r, 100));
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.some((row) => row.startsWith("plain-arm="))) throw new Error(`an opted-in home ran the plain arm: ${rows.join(" | ")}`);
const hosts = rows.filter((row) => row.startsWith("host="));
if (hosts.length !== 2) throw new Error(`expected the host and one successor host, got: ${rows.join(" | ")}`);
if (!hosts.every((row) => / args=park --restart primary=omp /.test(row))) throw new Error(`the host must run as 'park --restart' with the omp pin: ${hosts.join(" | ")}`);
if (!/predecessor=[0-9]+$/.test(hosts[1])) throw new Error(`the successor host did not receive the closed host as its predecessor: ${hosts[1]}`);
if (!rows.includes(`confirmed generation=gen-2 watcher=${hosts[1].replace(/^host=([0-9]+).*/, "$1")}`)) {
  throw new Error(`the handling handoff was not confirmed against the successor host's cycle: ${rows.join(" | ")}`);
}
if (sent.length !== 1) throw new Error(`expected one follow-up wake, saw ${sent.length}: ${JSON.stringify(sent)}`);
for (const needle of [
  "signal: omp-host done",
  "supervision-host: the away session could not take this wake: fixture; this wake is yours",
  "supervision-host: outcome 1 for demo [captain]: fixture",
]) {
  if (!sent[0].m.includes(needle)) throw new Error(`the follow-up lacks '${needle}': ${sent[0].m}`);
}
const awayNote = sent[0].m.includes("not from the captain: it is not a return");
if (process.env.RECORD_KIND === "quiet" ? awayNote : !awayNote) {
  throw new Error(`the away note must appear exactly under an away record (${process.env.RECORD_KIND}): ${sent[0].m}`);
}
await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: sent[0].m }, {});
await handlers.get("message_start")({ message: { role: "user", content: sent[0].m } }, {});
await handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension host mode ($kind record): $out"
  [ -z "$out" ] || fail "omp watch extension host test printed output: $out"
  pass ".omp watch extension: an opted-in home runs the supervision host and relays every host line ($kind record)"
}

# The omp owner stays file-gated: a home without config/supervision-host, or
# one opted out by config/supervision-host-off, spawns the plain arm and never the host.
test_watch_extension_keeps_the_arm_without_the_file_or_with_off() {
  local line label repo home log out status
  for line in - off; do
    label=${line#-}; label=${label:-absent}
    repo="$TMP_ROOT/watch-host-gate-$label/repo"; home="$TMP_ROOT/watch-host-gate-$label/home"; log="$TMP_ROOT/watch-host-gate-$label/arm.log"
    install_omp_extension_fixture "$repo"
    mkdir -p "$home/state" "$home/config"
    [ "$line" = - ] || : > "$home/config/supervision-host-off"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'plain-arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
sleep 30
SH
    cat > "$repo/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'host=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
sleep 30
SH
    chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-supervision-host.sh"
    out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" \
      EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { existsSync, writeFileSync, readFileSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null;
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  sendUserMessage() { return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await tool.execute();
for (let i = 0; i < 60 && !existsSync(process.env.FM_ARM_LOG); i += 1) await new Promise((r) => setTimeout(r, 100));
const rows = existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n") : [];
if (rows.length === 0 || !rows.every((row) => row.startsWith("plain-arm="))) {
  throw new Error(`a home that does not run the host must spawn only the plain arm: ${rows.join(" | ")}`);
}
await handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
    status=$?
    expect_code 0 "$status" "omp watch extension gate ($label): $out"
    [ -z "$out" ] || fail "omp watch extension gate test printed output ($label): $out"
  done
  pass ".omp watch extension: a home without config/supervision-host or with an off file keeps the plain arm"
}

# A host cycle boundary can close with only a "supervision-host:" line; left
# unconsumed across a session replacement it rides the persisted handoff and
# the successor session loads and replays it.
test_watch_extension_replays_a_host_only_boundary_across_replacement() {
  local repo home log out status
  repo="$TMP_ROOT/watch-host-handoff/repo"; home="$TMP_ROOT/watch-host-handoff/home"; log="$TMP_ROOT/watch-host-handoff/arm.log"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
exit 1
SH
  cat > "$repo/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'host=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$$"
if [ "$(grep -c '^host=' "$FM_ARM_LOG")" -eq 1 ]; then
  sleep 1
  printf 'supervision-host: outcome 1 for demo [captain]: fixture boundary\n'
  exit 0
fi
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-supervision-host.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handoff = `${process.env.FM_HOME}/state/extensions/omp-primary-watch/session-replacement-actionable.json`;
const handlers = new Map(); let tool = null; const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await tool.execute();
for (let i = 0; i < 60 && sent.length < 1; i += 1) await new Promise((r) => setTimeout(r, 100));
if (sent.length !== 1) throw new Error(`expected one boundary follow-up, saw ${sent.length}: ${JSON.stringify(sent)}`);
const boundary = "supervision-host: outcome 1 for demo [captain]: fixture boundary";
if (!sent[0].m.includes(boundary)) throw new Error(`the follow-up lacks the boundary line: ${sent[0].m}`);
// The session is replaced before omp consumes the boundary follow-up.
await handlers.get("session_shutdown")({}, {});
const stored = JSON.parse(readFileSync(handoff, "utf8"));
if (stored.pending.length !== 1 || !stored.pending[0].message.includes(boundary)) {
  throw new Error(`the unconsumed boundary did not ride the handoff: ${JSON.stringify(stored)}`);
}
await handlers.get("session_start")({ type: "session_start" }, {});
for (let i = 0; i < 60 && sent.length < 2; i += 1) await new Promise((r) => setTimeout(r, 100));
const replays = sent.slice(1);
if (replays.some((item) => item.m.includes("watcher: FAILED"))) throw new Error(`the successor failed to load the handoff: ${JSON.stringify(replays)}`);
if (replays.length !== 1 || !replays[0].m.includes(boundary)) throw new Error(`the successor did not replay the boundary: ${JSON.stringify(replays)}`);
await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: replays[0].m }, {});
await handlers.get("message_start")({ message: { role: "user", content: replays[0].m } }, {});
await handlers.get("session_shutdown")({}, {});
if (existsSync(handoff)) throw new Error("a consumed replay must not ride the replacement handoff again");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension host-only handoff: $out"
  [ -z "$out" ] || fail "omp watch extension host-only handoff test printed output: $out"
  pass ".omp watch extension: a host-only boundary rides the replacement handoff and replays in the successor session"
}

# A host whose exit reaches the extension in separate stream chunks is
# delivered once at its close: a successor host whose status and signal lines
# land while the previous wake is still being delivered, with its outcome lines
# after a pause, reaches main as one follow-up carrying both.
test_watch_extension_delivers_a_split_host_close_whole() {
  local repo home log out status
  repo="$TMP_ROOT/watch-host-split/repo"; home="$TMP_ROOT/watch-host-split/home"; log="$TMP_ROOT/watch-host-split/arm.log"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
exit 1
SH
  cat > "$repo/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'host=%s\n' "$$" >> "${FM_ARM_LOG:?}"
started="watcher: started pid=$$ (beacon fresh) recovery-generation=gen-$$"
case "$(grep -c '^host=' "$FM_ARM_LOG")" in
  1)
    printf '%s\n' "$started"
    sleep 1
    printf 'signal: omp-host first\n'
    exit 0
    ;;
  2)
    printf '%s\nsignal: omp-host second\n' "$started"
    sleep 1
    printf 'supervision-host: outcome 2 for demo [captain]: fixture split\n'
    exit 0
    ;;
esac
printf '%s\n' "$started"
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-supervision-host.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null; const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await tool.execute();
for (let i = 0; i < 80 && sent.length < 2; i += 1) await new Promise((r) => setTimeout(r, 100));
const second = sent.filter((item) => item.m.includes("signal: omp-host second"));
if (second.length !== 1) throw new Error(`expected one follow-up for the split close, saw ${second.length}: ${JSON.stringify(sent)}`);
if (!second[0].m.includes("supervision-host: outcome 2 for demo [captain]: fixture split")) {
  throw new Error(`the split close was delivered without its outcome line: ${second[0].m}`);
}
await handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension split host close: $out"
  [ -z "$out" ] || fail "omp watch extension split host close test printed output: $out"
  pass ".omp watch extension: a host close split across stream chunks reaches main as one whole follow-up"
}

# omp puts a queued user follow-up back into the composer when a run is
# interrupted (Esc, including fm-control interrupt) or dequeued (Alt+Up), which
# leaves a delivered watcher wake unsubmitted. The watch extension must find that
# wake, remove only its own text, and submit it again, while never touching an
# operator's draft or a wake a run already consumed. The idle-* scenarios pin
# the other stall: a wake arriving at an idle lane whose context ends in an
# advisor note must start its own turn instead of waiting as a follow-up.
# Each scenario runs in its own process because the arm fixture fires exactly
# one actionable close.
run_watch_restore_scenario() {  # <scenario>
  local scenario=$1 repo home
  repo="$TMP_ROOT/watch-restore-$scenario/repo"; home="$TMP_ROOT/watch-restore-$scenario/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
# The extension confirms a handling handoff through this same script; answering
# at once keeps its synchronous call from blocking the whole run.
[ "${1:-}" != --handling-delivered ] || exit 0
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-1\n' "$$"
if [ ! -e "${FM_HOME:?}/state/.e2e-fired" ] || { [[ "${SCENARIO:-}" = duplicates* ]] && [ ! -e "$FM_HOME/state/.e2e-fired-again" ]; }; then
  if [ -e "$FM_HOME/state/.e2e-fired" ]; then
    : > "$FM_HOME/state/.e2e-fired-again"
  else
    : > "$FM_HOME/state/.e2e-fired"
  fi
  sleep 1
  case "${SCENARIO:-}" in
    editor-normalized*) printf 'signal: omp-restore ready\tdetail\rcarriage\001control\013vertical\037unit done\n' ;;
    *) printf 'signal: omp-restore done\n' ;;
  esac
  exit 0
fi
exec sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  # Output goes to a file, not a pipe: the fixture's long-lived arm child would
  # otherwise hold a command substitution open for its whole sleep.
  FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" FM_OMP_ARM_READY_TIMEOUT_MS=3000 \
    FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    SCENARIO="$scenario" EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module >"$home/scenario.out" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, mkdirSync, readFileSync, existsSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null; const sent = []; const turns = [];
const transcript = [{ role: "assistant" }];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  sendUserMessage(m, o) {
    sent.push({ m, o });
    if (process.env.SCENARIO === "sync-consumed") {
      handlers.get("before_agent_start")({ prompt: m }, ctx);
      handlers.get("message_start")({ message: { role: "user", content: m } }, ctx);
    }
    if (process.env.SCENARIO === "failed-send") throw new Error("fixture send rejected");
    // omp's idle auto-continue refuses an explicit follow-up behind an advisor tail.
    if (process.env.SCENARIO === "custom-tail" || process.env.SCENARIO.startsWith("idle-")) {
      if (o?.deliverAs) { queued = true; return undefined; }
      if (idle) {
        turns.push({ prompt: m, tail: transcript.at(-1) });
        transcript.push({ role: "user", content: m });
        idle = false;
        handlers.get("before_agent_start")({ prompt: m }, ctx);
        handlers.get("message_start")({ message: { role: "user", content: m } }, ctx);
      } else {
        queued = true;
      }
    }
    return undefined;
  },
};
// The composer omp would show, with the editor calls the extension may use.
let editorText = "";
const composer = {
  get text() { return editorText; },
  set text(t) { editorText = t.replace(/\r\n?/g, "\n").replaceAll("\t", "   ").replace(/[\x00-\x09\x0b-\x1f]/g, ""); },
  sets: [],
};
// Restored-wake scenarios deliver behind a running turn; idle-* scenarios
// deliver to a lane that already went idle.
let idle = process.env.SCENARIO.startsWith("idle-"); let queued = false;
const ctx = {
  hasUI: true,
  isIdle: () => { if (process.env.SCENARIO === "idle-stale-context") throw new Error("stale context"); return idle; },
  hasPendingMessages: () => queued,
  ui: { getEditorText: () => composer.text, setEditorText: (t) => { composer.sets.push(t); composer.text = t; } },
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
if (["nonpending", "failed-send"].includes(process.env.SCENARIO)) {
  const dir = `${process.env.FM_HOME}/state/extensions/omp-primary-watch`;
  mkdirSync(dir, { recursive: true });
  writeFileSync(`${dir}/session-replacement-actionable.json`, "invalid");
  writeFileSync(`${process.env.FM_HOME}/state/.e2e-fired`, "");
}
// The vernant-d2-custody shape: the last turn ended, omp's advisor then posted
// its note as the context tail, and the composer is empty or holds a draft.
const advisorTail = { role: "custom", customType: "advisor", content: "advisor note posted after the turn" };
if (process.env.SCENARIO.startsWith("idle-")) transcript.push(advisorTail);
if (process.env.SCENARIO === "idle-draft") composer.text = "my unsent draft";
const editorBefore = composer.text;
await handlers.get("session_start")({ type: "session_start" }, ctx);
if (!["nonpending", "failed-send"].includes(process.env.SCENARIO)) await tool.execute();
if (["nonpending", "failed-send"].includes(process.env.SCENARIO)) {
  await sleep(50);
  if (sent.length !== 1 || !sent[0].m.includes("could not load a replacement-session actionable wake")) throw new Error("expected nonpending load-failure wake");
  const wake = sent[0].m;
  if (process.env.SCENARIO !== "failed-send") {
    await handlers.get("message_start")({ message: { role: "user", content: [{ type: "text", text: wake }] } }, ctx);
  }
  idle = true;
  composer.text = wake;
  await handlers.get("agent_end")({ type: "agent_end" }, ctx);
  await sleep(2500);
  if (sent.length !== 1 || composer.sets.length !== 0 || composer.text !== wake) throw new Error("failed or consumed nonpending wake was recovered");
  await handlers.get("session_shutdown")({}, ctx);
  process.exit(0);
}
const expectedWakes = process.env.SCENARIO.startsWith("duplicates") ? 2 : 1;
for (let i = 0; i < 60 && sent.length < expectedWakes; i += 1) await sleep(100);
if (sent.length !== expectedWakes) throw new Error(`expected ${expectedWakes} wakes, saw ${sent.length}`);
const wake = sent[0].m;
if (process.env.SCENARIO === "idle-stale-context") {
  if (sent[0].o?.deliverAs !== "followUp" || !queued || turns.length !== 0) throw new Error("a stale context must keep follow-up delivery");
  await handlers.get("session_shutdown")({}, ctx);
  process.exit(0);
}
if (process.env.SCENARIO.startsWith("idle-")) {
  if (sent[0].o?.deliverAs !== undefined || queued) throw new Error(`an idle wake was queued as a follow-up: ${JSON.stringify(sent[0].o)}`);
  if (turns.length !== 1 || turns[0].prompt !== wake || turns[0].tail !== advisorTail) throw new Error("an idle wake behind an advisor tail did not start its own turn");
  if (composer.sets.length !== 0 || composer.text !== editorBefore) throw new Error("idle delivery touched the composer");
  idle = true;
  await handlers.get("agent_end")({ type: "agent_end" }, ctx);
  await sleep(2500);
  if (sent.length !== 1 || composer.text !== editorBefore) throw new Error("a consumed idle wake was sent again");
  await handlers.get("session_shutdown")({}, ctx);
  process.exit(0);
}
// The running turn behind which the wake was queued has ended.
idle = true;
if (sent[0].o?.deliverAs !== "followUp") throw new Error("regular delivery must remain queued as a follow-up");
const bare = wake.startsWith("\u2063") ? wake.slice(1) : wake;
if (process.env.SCENARIO === "sync-consumed") {
  composer.text = wake;
  await handlers.get("agent_end")({ type: "agent_end" }, ctx);
  await sleep(2500);
  if (sent.length !== 1 || composer.sets.length !== 0 || composer.text !== wake) throw new Error("synchronously consumed wake was recovered");
  await handlers.get("session_shutdown")({}, ctx);
  process.exit(0);
}
const settle = async () => { await handlers.get("agent_end")({ type: "agent_end" }, ctx); await sleep(2500); };
const same = (item) => item.m === wake && item.o?.deliverAs === undefined;

switch (process.env.SCENARIO) {
  case "duplicates":
  case "duplicates-handoff":
  case "duplicates-streaming": {
    if (sent[1].m !== wake || sent[1].o?.deliverAs !== "followUp") throw new Error("expected two identical queued wakes");
    const consumePrompt = async () => {
      await handlers.get("before_agent_start")({ prompt: wake }, ctx);
      await handlers.get("message_start")({ message: { role: "user", content: [{ type: "text", text: wake }] } }, ctx);
    };
    if (process.env.SCENARIO === "duplicates-streaming") {
      await consumePrompt();
      await handlers.get("message_start")({ message: { role: "user", content: wake } }, ctx);
    } else {
      composer.text = `${wake}\n\n${wake}`;
      await settle();
      if (sent.length !== 3 || !same(sent[2]) || composer.text !== wake) throw new Error("first duplicate recovery did not preserve the second wake");
      await consumePrompt();
      if (process.env.SCENARIO === "duplicates-handoff") {
        const handoff = `${process.env.FM_HOME}/state/extensions/omp-primary-watch/session-replacement-actionable.json`;
        await handlers.get("session_shutdown")({}, ctx);
        const stored = JSON.parse(readFileSync(handoff, "utf8"));
        if (stored.pending.length !== 1 || stored.pending[0].delivered || !wake.includes(stored.pending[0].message)) throw new Error("unsubmitted duplicate did not retain its handoff record");
        await handlers.get("session_start")({}, ctx);
        for (let i = 0; i < 60 && sent.length < 4; i += 1) await sleep(100);
        if (sent.length !== 4 || sent[3].m !== wake || sent[3].o?.deliverAs !== undefined) throw new Error("idle replacement did not replay the unsubmitted duplicate as its own turn");
        await consumePrompt();
        await handlers.get("session_shutdown")({}, ctx);
        if (existsSync(handoff)) throw new Error("consumed duplicates retained a handoff record");
        process.exit(0);
      }
      await settle();
      if (sent.length !== 4 || !same(sent[3]) || composer.text !== "") throw new Error("second identical wake was no longer recoverable");
      await consumePrompt();
    }
    composer.text = wake;
    const count = sent.length;
    const sets = composer.sets.length;
    await settle();
    if (sent.length !== count || composer.sets.length !== sets || composer.text !== wake) throw new Error("consumed duplicates were recovered again");
    break;
  }
  case "editor-normalized":
  case "editor-normalized-message":
  case "editor-normalized-edited": {
    composer.text = wake;
    if (composer.text !== wake || !wake.includes("ready   detail\ncarriagecontrolverticalunit done")) throw new Error("emitted wake is not editor-stable");
    if (process.env.SCENARIO === "editor-normalized-edited") {
      composer.text = composer.text.replace("detail", "operator edit");
      const edited = composer.text;
      await settle();
      if (sent.length !== 1 || composer.sets.length !== 0 || composer.text !== edited) throw new Error("edited normalized wake was submitted or changed");
      break;
    }
    await settle();
    if (sent.length !== 2 || !same(sent[1]) || composer.text !== "") throw new Error("untouched normalized wake was not resubmitted");
    if (process.env.SCENARIO === "editor-normalized-message") {
      await handlers.get("message_start")({ message: { role: "user", content: [{ type: "text", text: sent[1].m }] } }, ctx);
    } else {
      await handlers.get("before_agent_start")({ prompt: sent[1].m }, ctx);
      await handlers.get("message_start")({ message: { role: "user", content: sent[1].m } }, ctx);
    }
    composer.text = wake;
    const sets = composer.sets.length;
    await settle();
    if (sent.length !== 2 || composer.sets.length !== sets || composer.text !== wake) throw new Error("consumed normalized wake was recovered again");
    break;
  }
  case "custom-tail": {
    if (!queued || turns.length !== 0) throw new Error("regular wake did not remain queued");
    queued = false;
    const tail = { role: "custom", customType: "advisor", content: "advisor transcript tail" };
    transcript.push(tail);
    const draft = "\noperator\u2063 draft\n\n";
    composer.text = `${wake}\n\n${draft}`;
    await settle();
    if (sent.length !== 2 || !same(sent[1])) throw new Error("idle custom-tail wake was not sent through prompt flow");
    if (turns.length !== 1 || turns[0].prompt !== wake || turns[0].tail !== tail) throw new Error("idle recovery did not start handling after the advisor tail");
    if (composer.text !== draft) throw new Error("custom-tail recovery changed operator draft bytes");
    idle = true;
    await settle();
    if (sent.length !== 2 || turns.length !== 1 || composer.text !== draft) throw new Error("consumed custom-tail wake was recovered again");
    break;
  }
  case "normalized-consumed": {
    const prompt = bare.replace(/\s/g, "").replace(/(.{17})/g, "$1\n \t");
    await handlers.get("before_agent_start")({ type: "before_agent_start", prompt }, ctx);
    await handlers.get("message_start")({ message: { role: "user", content: prompt } }, ctx);
    composer.text = wake;
    await settle();
    if (sent.length !== 2 || !same(sent[1]) || composer.text !== "") throw new Error("normalized text consumed an exact wake identity");
    await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: wake }, ctx);
    await handlers.get("message_start")({ message: { role: "user", content: wake } }, ctx);
    composer.text = wake;
    await settle();
    if (sent.length !== 2 || composer.text !== wake) throw new Error("exact wake consumption was not retained");
    break;
  }
  case "preparation-cancelled":
  case "preparation-handoff": {
    const draft = "\noperator\u2063 draft\n\n";
    composer.text = `${wake}\n\n${draft}`;
    await settle();
    if (sent.length !== 2 || !same(sent[1]) || composer.text !== draft) throw new Error("first recovery did not preserve the draft");
    await handlers.get("before_agent_start")({ prompt: wake }, ctx);
    const sets = composer.sets.length;
    await sleep(2500);
    if (sent.length !== 2 || composer.sets.length !== sets || composer.text !== draft) throw new Error("cancelled preparation resubmitted the wake or changed the preserved draft");
    if (process.env.SCENARIO === "preparation-cancelled") {
      composer.text = "";
      idle = false;
      await handlers.get("before_agent_start")({ prompt: draft }, ctx);
      await handlers.get("message_start")({ message: { role: "user", content: draft } }, ctx);
      idle = true;
      await settle();
      if (sent.length !== 2 || composer.sets.length !== sets || composer.text !== "") throw new Error("later completed draft turn recovered a wake absent from the editor");
    }
    const preservedEditor = composer.text;
    const handoff = `${process.env.FM_HOME}/state/extensions/omp-primary-watch/session-replacement-actionable.json`;
    await handlers.get("session_shutdown")({}, ctx);
    const stored = JSON.parse(readFileSync(handoff, "utf8"));
    if (stored.pending.length !== 1 || stored.pending[0].delivered || !wake.includes(stored.pending[0].message)) throw new Error("cancelled preparation retired its pending handoff");
    await handlers.get("session_start")({}, ctx);
    for (let i = 0; i < 60 && sent.length < 3; i += 1) await sleep(100);
    if (sent.length !== 3 || sent[2].m !== wake || sent[2].o?.deliverAs !== undefined) throw new Error("idle replacement lost the preparation-cancelled wake");
    await handlers.get("before_agent_start")({ prompt: wake }, ctx);
    if (JSON.parse(readFileSync(handoff, "utf8")).pending.length !== 1) throw new Error("replacement preparation retired its handoff");
    await handlers.get("message_start")({ message: { role: "assistant", content: wake } }, ctx);
    if (!existsSync(handoff)) throw new Error("assistant message retired the wake");
    await handlers.get("message_start")({ message: { role: "user", content: wake } }, ctx);
    await handlers.get("session_shutdown")({}, ctx);
    if (existsSync(handoff)) throw new Error("accepted replay retained its handoff");
    if (composer.text !== preservedEditor) throw new Error("replacement changed the preserved editor");
    process.exit(0);
  }
  case "consumed": {
    await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: wake }, ctx);
    await handlers.get("message_start")({ message: { role: "user", content: wake } }, ctx);
    composer.text = wake;
    await settle();
    if (sent.length !== 1) throw new Error(`a consumed wake was sent again: ${sent.length}`);
    if (composer.sets.length !== 0 || composer.text !== wake) throw new Error("a consumed wake changed the composer");
    break;
  }
  case "draft": {
    // omp joins restored messages and the operator's draft with a blank line.
    composer.text = `${wake}\n\nmy unsent draft`;
    await settle();
    if (sent.length !== 2 || !same(sent[1])) throw new Error(`the restored wake was not submitted again: ${JSON.stringify(sent)}`);
    if (composer.text !== "my unsent draft") throw new Error(`the operator draft was not preserved exactly: ${JSON.stringify(composer.text)}`);
    await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: wake }, ctx);
    await handlers.get("message_start")({ message: { role: "user", content: wake } }, ctx);
    await settle();
    if (sent.length !== 2) throw new Error(`a consumed resubmission was sent a third time: ${sent.length}`);
    if (composer.text !== "my unsent draft") throw new Error("the draft changed after the wake was consumed");
    break;
  }
  case "draft-before": {
    composer.text = `my unsent draft\n\n${bare}`;
    await settle();
    if (sent.length !== 2 || !same(sent[1])) throw new Error(`the restored wake was not submitted again: ${JSON.stringify(sent)}`);
    if (composer.text !== "my unsent draft") throw new Error(`the operator draft was not preserved exactly: ${JSON.stringify(composer.text)}`);
    break;
  }
  case "draft-after-bytes":
  case "draft-before-bytes":
  case "draft-both": {
    const before = "\n\nbefore\u2063 draft\n\n";
    const after = "\u2063\n\nafter draft\n\n";
    const scenario = process.env.SCENARIO;
    composer.text = scenario === "draft-after-bytes" ? `${wake}\n\n${after}` : scenario === "draft-before-bytes" ? `${before}\n\n${bare}` : `${before}\n\n${wake}\n\n${after}`;
    const expected = scenario === "draft-after-bytes" ? after : scenario === "draft-before-bytes" ? before : `${before}\n\n${after}`;
    await settle();
    if (sent.length !== 2 || !same(sent[1]) || composer.text !== expected) throw new Error(`draft bytes changed: ${JSON.stringify(composer.text)} expected ${JSON.stringify(expected)}`);
    break;
  }
  case "prepended":
  case "appended":
  case "appended-newline":
  case "prepended-mark":
  case "appended-mark":
  case "internal-mark":
  case "edited": {
    const scenario = process.env.SCENARIO;
    composer.text = scenario === "prepended" ? `Do not run: ${wake}`
      : scenario === "appended" ? `${wake} do not run`
      : scenario === "appended-newline" ? `${wake}\n`
      : scenario === "prepended-mark" ? `\u2063${wake}`
      : scenario === "appended-mark" ? `${wake}\u2063`
      : scenario === "internal-mark" ? wake.replace("signal:", "sig\u2063nal:")
      : wake.replace("signal:", "edited:");
    const original = composer.text;
    await settle();
    if (sent.length !== 1 || composer.sets.length !== 0 || composer.text !== original) throw new Error("edited wake was submitted or changed");
    break;
  }
  case "alone":
  case "alone-marked": {
    composer.text = process.env.SCENARIO === "alone" ? bare : wake;
    await settle();
    if (sent.length !== 2 || !same(sent[1])) throw new Error(`the restored wake was not submitted again: ${JSON.stringify(sent)}`);
    if (composer.text !== "") throw new Error(`the composer still holds text after the resubmission: ${JSON.stringify(composer.text)}`);
    break;
  }
  case "busy": {
    composer.text = wake; idle = false;
    await settle();
    if (sent.length !== 1 || composer.sets.length !== 0) throw new Error("a running turn was disturbed");
    break;
  }
  case "queued": {
    composer.text = wake; queued = true;
    await settle();
    if (sent.length !== 1 || composer.sets.length !== 0) throw new Error("a wake with messages still queued was submitted again");
    break;
  }
  case "elsewhere": {
    composer.text = "an unrelated operator draft";
    await settle();
    if (sent.length !== 1 || composer.sets.length !== 0) throw new Error("a composer without the wake was touched");
    break;
  }
  case "limit": {
    // An operator who keeps interrupting must not turn recovery into a loop.
    for (let i = 0; i < 6; i += 1) { composer.text = wake; await settle(); }
    if (sent.length !== 4) throw new Error(`recovery was not bounded to three resubmissions: ${sent.length}`);
    break;
  }
  default:
    throw new Error(`unknown scenario ${process.env.SCENARIO}`);
}
await handlers.get("session_shutdown")({}, ctx);
process.exit(0);
EOF
  local status=$?
  cat "$home/scenario.out"
  return "$status"
}

test_watch_extension_resubmits_a_wake_omp_restored_to_the_composer() {
  local scenario out status
  for scenario in duplicates duplicates-handoff duplicates-streaming preparation-cancelled preparation-handoff editor-normalized editor-normalized-message editor-normalized-edited nonpending failed-send sync-consumed consumed normalized-consumed draft custom-tail idle-empty idle-draft idle-stale-context draft-before draft-after-bytes draft-before-bytes draft-both prepended appended appended-newline prepended-mark appended-mark internal-mark edited alone alone-marked busy queued elsewhere limit; do
    out=$(run_watch_restore_scenario "$scenario")
    status=$?
    expect_code 0 "$status" "omp watch restore scenario $scenario: $out"
    [ -z "$out" ] || fail "omp watch restore scenario $scenario printed output: $out"
  done
  pass ".omp watch extension: an idle lane's wake starts its own turn behind an advisor tail; a wake omp restored to the composer is submitted again alone, bounded, and never over a draft or a running turn"
}

# Only the omp process that holds the session lock may record itself as the
# loaded session or arm a watcher. A descendant omp (an `omp -p` child a turn
# runs) auto-discovers the same extensions from the same directory; it used to
# overwrite the marker with its own pid, and its death left the dead pid in the
# marker, so the supervision proof read "not loaded" under a healthy session.
test_primary_extensions_ignore_a_descendant_session() {
  local repo home out status
  repo="$TMP_ROOT/descendant/repo"; home="$TMP_ROOT/descendant/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$repo/bin/fm-watch-arm.sh"
  chmod +x "$repo/bin/fm-watch-arm.sh"
  # The session lock names this shell, an ancestor of the node process below.
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" GUARD_EXT="$repo/.omp/extensions/fm-primary-turnend-guard.ts" \
    WATCH_EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" FM_SESSIONSTART_OFF=1 node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
writeFileSync(`${state}/.lock`, `${process.ppid}\n`);
const record = "sha256:parent-session-build\n" + process.ppid + "\n";
for (const marker of [".omp-turnend-extension-loaded", ".omp-watch-extension-loaded"]) writeFileSync(`${state}/${marker}`, record);
const load = async (file) => {
  const handlers = new Map(); let tool = null;
  const pi = { on(e, h) { handlers.set(e, h); }, registerCommand() {}, registerTool(t) { tool = t; }, sendUserMessage() {}, sendMessage() {} };
  (await import(pathToFileURL(file).href)).default(pi);
  return { handlers, tool };
};
const guard = await load(process.env.GUARD_EXT);
const watch = await load(process.env.WATCH_EXT);
const ctx = { sessionManager: { getSessionId: () => "child" } };
await guard.handlers.get("session_start")({ type: "session_start" }, ctx);
await watch.handlers.get("session_start")({ type: "session_start" }, ctx);
await guard.handlers.get("session_stop")({ type: "session_stop", stop_hook_active: true }, ctx);
await watch.handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "x" }, ctx);
for (const marker of [".omp-turnend-extension-loaded", ".omp-watch-extension-loaded"]) {
  if (readFileSync(`${state}/${marker}`, "utf8") !== record) throw new Error(`a descendant session overwrote ${marker}: ${readFileSync(`${state}/${marker}`, "utf8")}`);
}
const arm = await watch.tool.execute();
if (!/read-only/.test(arm.content[0].text)) throw new Error(`a descendant session armed a watcher: ${arm.content[0].text}`);
if (existsSync(`${state}/.watch.lock`)) throw new Error("a descendant session took the watcher lock");
await watch.handlers.get("session_shutdown")({}, ctx);
await guard.handlers.get("session_shutdown")({}, ctx);
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "descendant omp session must not claim the home: $out"
  [ -z "$out" ] || fail "descendant omp session test printed output: $out"
  pass ".omp extensions: a descendant omp session neither records itself as the loaded session nor arms a watcher"
}

# The turn-end guard used to record itself only while the extension loaded,
# before the session-start hook claimed the lock, so a lock that was foreign or
# absent at that moment left a marker naming a dead pid until the next restart.
test_turnend_marker_follows_the_lock_owner_at_turn_boundaries() {
  local repo home out status
  repo="$TMP_ROOT/marker-heal/repo"; home="$TMP_ROOT/marker-heal/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 0
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" GUARD_EXT="$repo/.omp/extensions/fm-primary-turnend-guard.ts" \
    node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { spawn } from "node:child_process";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
const marker = `${state}/.omp-turnend-extension-loaded`;
const pidOf = () => readFileSync(marker, "utf8").split("\n")[1];
// A live session that is not this process holds the lock while the extension loads.
const other = spawn("sleep", ["60"], { stdio: "ignore" });
writeFileSync(`${state}/.lock`, `${other.pid}\n`);
const handlers = new Map();
const pi = { on(e, h) { handlers.set(e, h); }, sendMessage() {} };
(await import(pathToFileURL(process.env.GUARD_EXT).href)).default(pi);
const ctx = { sessionManager: { getSessionId: () => "s1" } };
await handlers.get("session_start")({ type: "session_start" }, ctx);
if (existsSync(marker)) throw new Error("a foreign live lock holder must not be recorded as this session's marker");
// The session-start hook then claims the lock for this process.
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "hi" }, ctx);
if (pidOf() !== String(process.pid)) throw new Error(`the marker was not recorded once the lock was claimed: ${readFileSync(marker, "utf8")}`);
// A stale record (a dead build or pid) is repaired at the next turn boundary.
writeFileSync(marker, "sha256:stale\n999999\n");
await handlers.get("session_stop")({ type: "session_stop", stop_hook_active: true }, ctx);
if (pidOf() !== String(process.pid)) throw new Error(`the stale marker was not repaired at the turn boundary: ${readFileSync(marker, "utf8")}`);
other.kill();
await handlers.get("session_shutdown")({}, ctx);
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "turn-end marker self-repair: $out"
  [ -z "$out" ] || fail "turn-end marker self-repair test printed output: $out"
  pass ".omp turn-end guard: the loaded marker follows the lock owner at turn boundaries instead of only at load"
}

test_detection_anchored_name_and_marker_precedence
test_lock_identity_and_liveness_classification
test_spawn_launch_line_and_worker_wiring
test_spawn_model_validation_scoped_to_listed_providers
test_spawn_refuses_a_missing_or_unlisted_default_role
test_spawn_global_config_is_read_only_and_unlayered
test_spawn_raw_omp_guard_uses_the_launch_model
test_spawn_raw_omp_guard_uses_the_launch_agent_dir
test_spawn_omp_profiles_leave_directory_evidence_unreadable
test_secondmate_launch_relies_on_discovery
test_secondmate_config_pinned_model_is_validated
test_busy_extension_lifecycle
test_control_composer_and_model_tables
test_ownership_proof_is_omp_keyed
test_turnend_guard_extension_compels_one_continuation
test_watch_extension_arms_and_delivers
test_watch_extension_runs_the_supervision_host
test_watch_extension_runs_the_supervision_host quiet
test_watch_extension_keeps_the_arm_without_the_file_or_with_off
test_watch_extension_replays_a_host_only_boundary_across_replacement
test_watch_extension_delivers_a_split_host_close_whole
test_watch_extension_resubmits_a_wake_omp_restored_to_the_composer
test_primary_extensions_ignore_a_descendant_session
test_turnend_marker_follows_the_lock_owner_at_turn_boundaries
